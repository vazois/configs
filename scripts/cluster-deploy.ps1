#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Orchestrates cluster lifecycle across VMSS instances with automatic peer discovery.

.DESCRIPTION
    Discovers peer VMs on the accelerated subnet, then performs actions:
    discover, start, setup, or stop.

.EXAMPLE
    cluster-deploy.ps1 -Action discover -InstanceCount 4
    cluster-deploy.ps1 -Action start -System valkey -Template cache -InstanceCount 4
    cluster-deploy.ps1 -Action start -System valkey -Template cache -InstanceCount 4 -Clean
    cluster-deploy.ps1 -Action setup -System valkey -InstanceCount 4 -Replicas 1
    cluster-deploy.ps1 -Action stop -System valkey -InstanceCount 4
    cluster-deploy.ps1 -Action start -System garnet -Template cache -InstanceCount 1 -NoCluster
    cluster-deploy.ps1 -Action start -Endpoint 10.5.1.4 -NodeCount 6 -System valkey -Template cache -InstanceCount 4
#>
param(
    [ValidateSet("discover","start","setup","stop")][string]$Action,
    [ValidateSet("valkey","garnet")][string]$System,
    [string]$Template,
    [int]$InstanceCount,
    [string]$Endpoint,
    [int]$NodeCount,
    [switch]$Clean,
    [int]$Replicas = 0,
    [switch]$NoCluster,
    [string]$User = "guser",
    [int]$Port = 7000,
    [int]$SshTimeout = 10,
    [int]$TcpTimeout = 60,
    [switch]$Help
)

if ($Help -or -not $Action) {
    Write-Host "Usage: cluster-deploy.ps1 -Action <discover|start|setup|stop> [options]"
    Write-Host ""
    Write-Host "Orchestrates cluster lifecycle across VMSS instances with automatic peer discovery."
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  discover   Scan subnet for peers and probe ports for running instances"
    Write-Host "  start      Discover peers, SSH mcluster start on each, wait for endpoints"
    Write-Host "  setup      Discover peers, verify endpoints, form cluster (assign slots)"
    Write-Host "  stop       Discover peers, SSH mcluster stop on each"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -System         Target system: valkey or garnet (required for start/setup/stop)"
    Write-Host "  -Template       Config template name (required for start)"
    Write-Host "  -InstanceCount  Number of instances per VM (required)"
    Write-Host "  -Endpoint       Base IP (skip discovery, use sequential IPs)"
    Write-Host "  -NodeCount      Number of VMs (with -Endpoint, or as expected count validation)"
    Write-Host "  -Clean          Clean cluster directories before starting"
    Write-Host "  -Replicas       Number of replicas per primary (default: 0)"
    Write-Host "  -NoCluster      Disable cluster mode in configs"
    Write-Host "  -User           SSH user (default: guser)"
    Write-Host "  -Port           Base port (default: 7000)"
    Write-Host "  -SshTimeout     SSH connection timeout in seconds (default: 10)"
    Write-Host "  -TcpTimeout     TCP endpoint wait timeout in seconds (default: 60)"
    Write-Host "  -Help           Show this help message"
    return
}

$ErrorActionPreference = "Stop"

# --- Helper Functions ---

function Get-OwnEth1Info {
    $output = ip -4 addr show eth1 2>$null
    $inetLine = $output | Where-Object { $_ -match 'inet\s+([\d.]+)/([\d]+)' } | Select-Object -First 1
    if ($inetLine -match 'inet\s+([\d.]+)/([\d]+)') {
        return @{ Ip = $Matches[1]; Prefix = [int]$Matches[2] }
    }
    throw "ERROR: Could not detect eth1 IP/subnet."
}

function Get-SubnetIps {
    param([string]$Ip, [int]$Prefix)
    $parts = $Ip -split '\.'
    $ipInt = ([int]$parts[0] -shl 24) + ([int]$parts[1] -shl 16) + ([int]$parts[2] -shl 8) + [int]$parts[3]
    $mask = -bnot ((1 -shl (32 - $Prefix)) - 1)
    $network = $ipInt -band $mask
    $hostCount = (1 -shl (32 - $Prefix)) - 2  # exclude network and broadcast

    $ips = @()
    # Skip first 4 (Azure reserved: network, gateway, DNS x2) and last (broadcast)
    $start = $network + 4
    $end = $network + (1 -shl (32 - $Prefix)) - 2
    for ($i = $start; $i -le $end; $i++) {
        $o1 = ($i -shr 24) -band 0xFF
        $o2 = ($i -shr 16) -band 0xFF
        $o3 = ($i -shr 8) -band 0xFF
        $o4 = $i -band 0xFF
        $ips += "$o1.$o2.$o3.$o4"
    }
    return $ips
}

function Find-Peers {
    param([string]$OwnIp, [int]$Prefix, [string]$SshUser, [int]$Timeout)
    Write-Host "Discovering peers on eth1 subnet ($OwnIp/$Prefix)..." -ForegroundColor Yellow

    $candidateIps = Get-SubnetIps -Ip $OwnIp -Prefix $Prefix
    Write-Host "  Scanning $($candidateIps.Count) candidate IPs..." -ForegroundColor DarkGray

    $peers = @()
    foreach ($ip in $candidateIps) {
        # Quick TCP probe on port 22
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $task = $tcp.ConnectAsync($ip, 22)
            if ($task.Wait([TimeSpan]::FromSeconds($Timeout))) {
                $tcp.Close()
                $peers += $ip
                Write-Host "  $ip : alive" -ForegroundColor DarkGray
            } else {
                $tcp.Dispose()
            }
        } catch {
            # not reachable
        }
    }

    if ($peers.Count -eq 0) {
        throw "ERROR: No peers found on subnet."
    }

    Write-Host "  Found $($peers.Count) peer(s)." -ForegroundColor Green
    return $peers
}

function Test-Ports {
    param([string[]]$Ips, [int]$BasePort, [int]$Count)
    $results = @()
    foreach ($ip in $Ips) {
        $portStatus = @()
        for ($i = 0; $i -lt $Count; $i++) {
            $p = $BasePort + $i
            $listening = $false
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $task = $tcp.ConnectAsync($ip, $p)
                if ($task.Wait([TimeSpan]::FromSeconds(2))) {
                    $listening = $true
                }
                $tcp.Close()
            } catch { }
            $portStatus += @{ Port = $p; Listening = $listening }
        }
        $results += @{ Ip = $ip; Ports = $portStatus }
    }
    return $results
}

function Show-Discovery {
    param($ProbeResults, [int]$BasePort, [int]$Count)
    # Header
    $header = "  {0,-16}" -f "IP"
    for ($i = 0; $i -lt $Count; $i++) {
        $header += " {0,-10}" -f "Port $($BasePort + $i)"
    }
    Write-Host $header -ForegroundColor Cyan

    $totalListening = 0
    $totalPorts = 0
    foreach ($r in $ProbeResults) {
        $line = "  {0,-16}" -f $r.Ip
        foreach ($ps in $r.Ports) {
            $totalPorts++
            if ($ps.Listening) {
                $totalListening++
                $line += " {0,-10}" -f "listening"
            } else {
                $line += " {0,-10}" -f "---"
            }
        }
        $color = if ($r.Ports | Where-Object { $_.Listening }) { "Green" } else { "White" }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  Peers: $($ProbeResults.Count) | Listening: $totalListening/$totalPorts" -ForegroundColor Yellow
}

function Get-IpList {
    param([string]$Base, [int]$Count)
    $parts = $Base -split '\.'
    $lastOctet = [int]$parts[3]
    $prefix = "$($parts[0]).$($parts[1]).$($parts[2])"
    $ips = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $ips += "$prefix.$($lastOctet + $i)"
    }
    return $ips
}

function Test-SshConnectivity {
    param([string[]]$Ips, [string]$SshUser, [int]$Timeout)
    Write-Host "Validating SSH connectivity to $($Ips.Count) VMs..." -ForegroundColor Yellow
    $failed = @()
    foreach ($ip in $Ips) {
        $result = ssh -o ConnectTimeout=$Timeout -o StrictHostKeyChecking=no -o BatchMode=yes "$SshUser@$ip" "echo ok" 2>$null
        if ($result -ne "ok") {
            $failed += $ip
        } else {
            Write-Host "  $ip : reachable" -ForegroundColor DarkGray
        }
    }
    if ($failed.Count -gt 0) {
        Write-Host "ERROR: SSH failed for the following VMs:" -ForegroundColor Red
        $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "Aborting: $($failed.Count) VM(s) unreachable"
    }
    Write-Host "  All $($Ips.Count) VMs reachable." -ForegroundColor Green
}

function Test-VmssFamily {
    param([string[]]$Ips, [string]$SshUser, [int]$Timeout)
    Write-Host "Validating VMSS family membership..." -ForegroundColor Yellow
    $hostnames = @()
    foreach ($ip in $Ips) {
        $hostname = ssh -o ConnectTimeout=$Timeout -o StrictHostKeyChecking=no -o BatchMode=yes "$SshUser@$ip" "hostname" 2>$null
        if (-not $hostname) {
            throw "ERROR: Could not get hostname from $ip"
        }
        $hostnames += @{ Ip = $ip; Hostname = $hostname }
    }

    $prefixes = $hostnames | ForEach-Object {
        if ($_.Hostname -match '^(.+?)\d{6}$') { $Matches[1] } else { $_.Hostname }
    } | Sort-Object -Unique

    if ($prefixes.Count -ne 1) {
        Write-Host "ERROR: VMs belong to different VMSS families:" -ForegroundColor Red
        $hostnames | ForEach-Object { Write-Host "  $($_.Ip) -> $($_.Hostname)" -ForegroundColor Red }
        throw "Aborting: Mixed VMSS families detected ($($prefixes -join ', '))"
    }

    Write-Host "  All VMs belong to VMSS: $($prefixes[0]) ✓" -ForegroundColor Green
    return $prefixes[0]
}

function Invoke-ParallelMcluster {
    param([string[]]$Ips, [string]$SshUser, [string]$MclusterArgs, [string]$OwnIp)
    Write-Host ""
    Write-Host "Running mcluster on $($Ips.Count) VMs in parallel..." -ForegroundColor Yellow
    Write-Host "  Command: mcluster $MclusterArgs" -ForegroundColor DarkGray

    $jobs = @()
    foreach ($ip in $Ips) {
        if ($ip -eq $OwnIp) {
            # Run locally
            $job = Start-Job -ScriptBlock {
                param($args_str)
                $output = bash -c "mcluster $args_str" 2>&1
                return @{ Ip = $Using:ip; Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
            } -ArgumentList $MclusterArgs
        } else {
            $job = Start-Job -ScriptBlock {
                param($ip, $user, $args_str)
                $output = ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$user@$ip" "mcluster $args_str" 2>&1
                return @{ Ip = $ip; Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
            } -ArgumentList $ip, $SshUser, $MclusterArgs
        }
        $jobs += @{ Ip = $ip; Job = $job }
    }

    $results = @()
    foreach ($entry in $jobs) {
        $result = Receive-Job -Job $entry.Job -Wait
        Remove-Job -Job $entry.Job
        $results += $result
    }

    $failures = @()
    foreach ($r in $results) {
        if ($r.ExitCode -eq 0) {
            Write-Host "  $($r.Ip): success" -ForegroundColor Green
        } else {
            Write-Host "  $($r.Ip): FAILED (exit code $($r.ExitCode))" -ForegroundColor Red
            Write-Host $r.Output -ForegroundColor DarkGray
            $failures += $r.Ip
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "WARNING: mcluster failed on $($failures.Count) VM(s): $($failures -join ', ')" -ForegroundColor Red
    } else {
        Write-Host "  All $($Ips.Count) VMs completed successfully." -ForegroundColor Green
    }

    return $failures
}

function Wait-ForEndpoints {
    param([string[]]$Endpoints, [int]$Timeout)
    Write-Host ""
    Write-Host "Waiting for $($Endpoints.Count) endpoints to be reachable (timeout: ${Timeout}s)..." -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds($Timeout)
    $pending = [System.Collections.Generic.List[string]]::new($Endpoints)

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $stillPending = [System.Collections.Generic.List[string]]::new()
        foreach ($ep in $pending) {
            $parts = $ep -split ':'
            $ip = $parts[0]; $port = [int]$parts[1]
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $tcp.Connect($ip, $port)
                $tcp.Close()
            } catch {
                $stillPending.Add($ep)
            }
        }
        if ($stillPending.Count -gt 0) {
            Start-Sleep -Seconds 2
        }
        $pending = $stillPending
    }

    if ($pending.Count -gt 0) {
        Write-Host "ERROR: Timed out waiting for endpoints:" -ForegroundColor Red
        $pending | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "Aborting: $($pending.Count) endpoint(s) not reachable"
    }

    Write-Host "  All $($Endpoints.Count) endpoints responding." -ForegroundColor Green
}

function New-Cluster {
    param([string[]]$Endpoints, [int]$ReplicaCount, [string]$Sys)
    Write-Host ""
    Write-Host "Forming cluster ($($Endpoints.Count) nodes, $ReplicaCount replica(s) per primary)..." -ForegroundColor Yellow

    $endpointStr = $Endpoints -join " "

    if ($Sys -eq "valkey") {
        $cmd = "valkey-cli --cluster create $endpointStr --cluster-replicas $ReplicaCount --cluster-yes"
    } else {
        $cmd = "redis-cli --cluster create $endpointStr --cluster-replicas $ReplicaCount --cluster-yes"
    }

    Write-Host "  -> $cmd" -ForegroundColor DarkGray
    $output = bash -c $cmd 2>&1
    $output | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "Cluster creation failed (exit code $LASTEXITCODE)"
    }

    # Verify cluster state
    $firstEp = $Endpoints[0] -split ':'
    Write-Host ""
    Write-Host "Verifying cluster state..." -ForegroundColor Yellow
    $verifyCmd = if ($Sys -eq "valkey") { "valkey-cli" } else { "redis-cli" }
    $clusterInfo = bash -c "$verifyCmd -h $($firstEp[0]) -p $($firstEp[1]) CLUSTER INFO" 2>&1
    $stateLine = $clusterInfo | Where-Object { $_ -match "cluster_state" }
    $slotsLine = $clusterInfo | Where-Object { $_ -match "cluster_slots_ok" }

    Write-Host "  $stateLine"
    Write-Host "  $slotsLine"

    if ($stateLine -match "cluster_state:ok") {
        Write-Host "  Cluster formed successfully ✓" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Cluster state is not 'ok'" -ForegroundColor Red
    }
}

# --- Peer Cache ---

$PeerCacheFile = "$HOME/.cluster-deploy-peers.json"

function Save-PeerCache {
    param([string[]]$Ips, [string]$OwnIp)
    $cache = @{ Ips = $Ips; OwnIp = $OwnIp; Timestamp = (Get-Date -Format "o") }
    $cache | ConvertTo-Json | Set-Content $PeerCacheFile
    Write-Host "  Peer cache saved to $PeerCacheFile" -ForegroundColor DarkGray
}

function Get-PeerCache {
    if (-not (Test-Path $PeerCacheFile)) { return $null }
    $cache = Get-Content $PeerCacheFile -Raw | ConvertFrom-Json
    Write-Host "  Using cached peers from $($cache.Timestamp)" -ForegroundColor DarkGray
    Write-Host "  (run '-Action discover' to refresh)" -ForegroundColor DarkGray
    Write-Host "  Peers: $($cache.Ips -join ', ')" -ForegroundColor Cyan
    return @{ Ips = @($cache.Ips); OwnIp = $cache.OwnIp }
}

# --- Resolve Peers ---

function Resolve-Peers {
    param([string]$Endpoint, [int]$NodeCount, [string]$User, [int]$SshTimeout, [switch]$ForceDiscover)

    if ($Endpoint -and $NodeCount -gt 0) {
        # Legacy mode: sequential IPs from base
        Write-Host "Using provided Endpoint + NodeCount (sequential IPs)..." -ForegroundColor DarkGray
        $ips = Get-IpList -Base $Endpoint -Count $NodeCount
        Test-SshConnectivity -Ips $ips -SshUser $User -Timeout $SshTimeout
        return @{ Ips = $ips; OwnIp = $null }
    }

    # Try cache first (unless forced)
    if (-not $ForceDiscover) {
        $cached = Get-PeerCache
        if ($cached) { return $cached }
    }

    # Discovery mode
    $eth1 = Get-OwnEth1Info
    $peers = Find-Peers -OwnIp $eth1.Ip -Prefix $eth1.Prefix -SshUser $User -Timeout $SshTimeout

    # Validate VMSS family
    Test-VmssFamily -Ips $peers -SshUser $User -Timeout $SshTimeout

    # If NodeCount given, validate expected count
    if ($NodeCount -gt 0 -and $peers.Count -ne $NodeCount) {
        Write-Host "WARNING: Expected $NodeCount peers but found $($peers.Count)" -ForegroundColor Yellow
    }

    # Save to cache
    Save-PeerCache -Ips $peers -OwnIp $eth1.Ip

    return @{ Ips = $peers; OwnIp = $eth1.Ip }
}

# --- Main ---

Write-Host "==== cluster-deploy ($Action) ====" -ForegroundColor Cyan

switch ($Action) {
    "discover" {
        $peerInfo = Resolve-Peers -Endpoint $Endpoint -NodeCount $NodeCount -User $User -SshTimeout $SshTimeout -ForceDiscover
        $ips = $peerInfo.Ips

        if ($InstanceCount -gt 0) {
            Write-Host ""
            Write-Host "Probing ports on discovered peers..." -ForegroundColor Yellow
            $probeResults = Test-Ports -Ips $ips -BasePort $Port -Count $InstanceCount

            Write-Host ""
            Show-Discovery -ProbeResults $probeResults -BasePort $Port -Count $InstanceCount
        } else {
            Write-Host ""
            Write-Host "Discovered peers:" -ForegroundColor Yellow
            $ips | ForEach-Object { Write-Host "  $_" }
            Write-Host ""
            Write-Host "  Total: $($ips.Count) peer(s)" -ForegroundColor Green
            Write-Host "  (use -InstanceCount to probe ports)" -ForegroundColor DarkGray
        }
    }

    "start" {
        if (-not $System) { throw "ERROR: -System is required for start." }
        if (-not $Template) { throw "ERROR: -Template is required for start." }
        if (-not $InstanceCount) { throw "ERROR: -InstanceCount is required for start." }

        $peerInfo = Resolve-Peers -Endpoint $Endpoint -NodeCount $NodeCount -User $User -SshTimeout $SshTimeout
        $ips = $peerInfo.Ips
        $ownIp = $peerInfo.OwnIp

        Write-Host ""
        Write-Host "  Peers:         $($ips -join ', ')"
        Write-Host "  System:        $System"
        Write-Host "  Template:      $Template"
        Write-Host "  InstanceCount: $InstanceCount"
        Write-Host "  Port:          $Port"
        Write-Host "  Clean:         $Clean"
        Write-Host "  NoCluster:     $NoCluster"
        Write-Host ""

        # Build mcluster arguments
        $mclusterArgs = "-Action start -System $System -Template $Template -Nodes $InstanceCount"
        if ($Clean) { $mclusterArgs += " -Clean" }
        if ($NoCluster) { $mclusterArgs += " -NoCluster" }

        # Run on all peers
        $failures = Invoke-ParallelMcluster -Ips $ips -SshUser $User -MclusterArgs $mclusterArgs -OwnIp $ownIp

        if ($failures.Count -gt 0) {
            Write-Host ""
            Write-Host "WARNING: Some VMs failed. Cluster may be incomplete." -ForegroundColor Red
        }

        # Wait for all endpoints
        $endpoints = @()
        foreach ($ip in $ips) {
            for ($p = 0; $p -lt $InstanceCount; $p++) {
                $endpoints += "${ip}:$($Port + $p)"
            }
        }
        Wait-ForEndpoints -Endpoints $endpoints -Timeout $TcpTimeout
    }

    "setup" {
        if (-not $System) { throw "ERROR: -System is required for setup." }
        if (-not $InstanceCount) { throw "ERROR: -InstanceCount is required for setup." }

        $peerInfo = Resolve-Peers -Endpoint $Endpoint -NodeCount $NodeCount -User $User -SshTimeout $SshTimeout
        $ips = $peerInfo.Ips

        # Build endpoint list
        $endpoints = @()
        foreach ($ip in $ips) {
            for ($p = 0; $p -lt $InstanceCount; $p++) {
                $endpoints += "${ip}:$($Port + $p)"
            }
        }

        # Verify all endpoints are listening
        Write-Host ""
        Write-Host "Verifying all endpoints are listening..." -ForegroundColor Yellow
        $probeResults = Test-Ports -Ips $ips -BasePort $Port -Count $InstanceCount
        $notListening = @()
        foreach ($r in $probeResults) {
            foreach ($ps in $r.Ports) {
                if (-not $ps.Listening) {
                    $notListening += "$($r.Ip):$($ps.Port)"
                }
            }
        }

        if ($notListening.Count -gt 0) {
            Write-Host "ERROR: The following endpoints are not listening:" -ForegroundColor Red
            $notListening | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            throw "Aborting setup: $($notListening.Count) endpoint(s) not ready. Run 'start' first."
        }

        Write-Host "  All $($endpoints.Count) endpoints listening ✓" -ForegroundColor Green

        # Form cluster
        if ($NoCluster) {
            Write-Host ""
            Write-Host "NOTE: -NoCluster specified, skipping cluster formation." -ForegroundColor Yellow
        } else {
            New-Cluster -Endpoints $endpoints -ReplicaCount $Replicas -Sys $System
        }
    }

    "stop" {
        if (-not $System) { throw "ERROR: -System is required for stop." }

        $peerInfo = Resolve-Peers -Endpoint $Endpoint -NodeCount $NodeCount -User $User -SshTimeout $SshTimeout
        $ips = $peerInfo.Ips
        $ownIp = $peerInfo.OwnIp

        Write-Host ""
        Write-Host "  Peers:  $($ips -join ', ')"
        Write-Host "  System: $System"
        Write-Host ""

        $mclusterArgs = "-Action stop -System $System"
        $failures = Invoke-ParallelMcluster -Ips $ips -SshUser $User -MclusterArgs $mclusterArgs -OwnIp $ownIp
    }
}

Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Cyan
