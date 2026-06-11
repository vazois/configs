#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Orchestrates mcluster start across multiple VMSS instances and optionally forms a cluster.

.DESCRIPTION
    SSHs into N remote VMs (derived from Endpoint + count), validates connectivity,
    runs mcluster start in parallel, and optionally forms a valkey/garnet cluster.

.EXAMPLE
    cluster-deploy.ps1 -Endpoint 10.5.1.4 -NodeCount 8 -System valkey -Template cache -InstanceCount 4
    cluster-deploy.ps1 -Endpoint 10.5.1.4 -NodeCount 8 -System valkey -Template cache -InstanceCount 4 -Clean -Setup -Replicas 1
    cluster-deploy.ps1 -Endpoint 10.5.1.4 -NodeCount 2 -System garnet -Template cache -InstanceCount 1 -Setup
    cluster-deploy.ps1 -Endpoint 10.5.1.4 -NodeCount 4 -System valkey -Template cache -InstanceCount 4 -NoCluster
#>
param(
    [string]$Endpoint,
    [Parameter(Mandatory)][int]$NodeCount,
    [Parameter(Mandatory)][ValidateSet("valkey","garnet")][string]$System,
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][int]$InstanceCount,
    [switch]$Clean,
    [switch]$Setup,
    [int]$Replicas = 0,
    [switch]$NoCluster,
    [string]$User = "guser",
    [int]$Port = 7000,
    [int]$SshTimeout = 10,
    [int]$TcpTimeout = 60
)

$ErrorActionPreference = "Stop"

# Auto-detect Endpoint from eth1 if not provided
if (-not $Endpoint) {
    $output = ip -4 addr show eth1 2>$null
    $inetLine = $output | Where-Object { $_ -match 'inet\s+([\d.]+)' } | Select-Object -First 1
    if ($inetLine -match 'inet\s+([\d.]+)') {
        $Endpoint = $Matches[1]
        Write-Host "Auto-detected Endpoint from eth1: $Endpoint" -ForegroundColor DarkGray
    } else {
        throw "ERROR: Could not detect eth1 IP. Provide -Endpoint manually."
    }
}

# --- Helper Functions ---

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

    # Extract VMSS prefix (hostname minus the trailing instance digits, e.g., "eps8v6vmss" from "eps8v6vmss000001")
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

function Start-ParallelMcluster {
    param([string[]]$Ips, [string]$SshUser, [string]$MclusterArgs)
    Write-Host ""
    Write-Host "Starting mcluster on $($Ips.Count) VMs in parallel..." -ForegroundColor Yellow
    Write-Host "  Command: mcluster $MclusterArgs" -ForegroundColor DarkGray

    $jobs = @()
    foreach ($ip in $Ips) {
        $job = Start-Job -ScriptBlock {
            param($ip, $user, $args_str)
            $output = ssh -o StrictHostKeyChecking=no -o BatchMode=yes "$user@$ip" "mcluster $args_str" 2>&1
            return @{ Ip = $ip; Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
        } -ArgumentList $ip, $SshUser, $MclusterArgs
        $jobs += @{ Ip = $ip; Job = $job }
    }

    # Wait for all jobs
    $results = @()
    foreach ($entry in $jobs) {
        $result = Receive-Job -Job $entry.Job -Wait
        Remove-Job -Job $entry.Job
        $results += $result
    }

    # Report results
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
        Write-Host "  All $($Ips.Count) VMs started successfully." -ForegroundColor Green
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
        throw "Aborting cluster setup: $($pending.Count) endpoint(s) not reachable"
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
        # Garnet uses redis-cli compatible protocol
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
    $clusterInfo = bash -c "valkey-cli -h $($firstEp[0]) -p $($firstEp[1]) CLUSTER INFO" 2>&1
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

# --- Main ---

Write-Host "==== cluster-deploy ====" -ForegroundColor Cyan
Write-Host "  Endpoint:      $Endpoint"
Write-Host "  NodeCount:     $NodeCount"
Write-Host "  System:      $System"
Write-Host "  Template:    $Template"
Write-Host "  InstanceCount:  $InstanceCount"
Write-Host "  Port:    $Port"
Write-Host "  Clean:       $Clean"
Write-Host "  Setup:       $Setup"
Write-Host "  Replicas:    $Replicas"
Write-Host "  NoCluster:   $NoCluster"
Write-Host ""

# 1. Generate IP list
$ips = Get-IpList -Base $Endpoint -Count $NodeCount

# 2. Validate SSH connectivity
Test-SshConnectivity -Ips $ips -SshUser $User -Timeout $SshTimeout

# 3. Validate VMSS family
$vmssPrefix = Test-VmssFamily -Ips $ips -SshUser $User -Timeout $SshTimeout

# 4. Build mcluster arguments
$mclusterArgs = "start $System $Template $InstanceCount"
if ($Clean) { $mclusterArgs += " --clean" }
if ($NoCluster) { $mclusterArgs += " --no-cluster" }

# 5. Parallel mcluster start
$failures = Start-ParallelMcluster -Ips $ips -SshUser $User -MclusterArgs $mclusterArgs

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: Some VMs failed. Cluster setup may be incomplete." -ForegroundColor Red
}

# 6. Cluster formation (if --setup and not --no-cluster)
if ($Setup -and -not $NoCluster) {
    # Build endpoint list
    $endpoints = @()
    foreach ($ip in $ips) {
        for ($p = 0; $p -lt $InstanceCount; $p++) {
            $endpoints += "${ip}:$($Port + $p)"
        }
    }

    # Wait for endpoints
    Wait-ForEndpoints -Endpoints $endpoints -Timeout $TcpTimeout

    # Form cluster
    New-Cluster -Endpoints $endpoints -ReplicaCount $Replicas -Sys $System
} elseif ($Setup -and $NoCluster) {
    Write-Host ""
    Write-Host "NOTE: --Setup ignored because --NoCluster was specified." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==== Done ====" -ForegroundColor Cyan
