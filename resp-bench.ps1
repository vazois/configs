#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Spawns background SSH sessions to run Resp.benchmark on remote VMs.

.DESCRIPTION
    Reads benchmark parameters from a config file and launches SSH sessions
    via Start-Process with Tee-Object for local capture. Supports multiple
    client VMs by specifying a base hostname and count. Automatically aggregates
    results when all instances complete.

.EXAMPLE
    .\resp-bench.ps1
    .\resp-bench.ps1 -ConfigFile .\my-bench.conf
#>
param(
    [string]$ConfigFile = "$PSScriptRoot\bench.conf",
    [switch]$Help
)

if ($Help) {
    Write-Host "Usage: resp-bench.ps1 [-ConfigFile <path>]"
    Write-Host ""
    Write-Host "Reads parameters from a key=value config file and spawns"
    Write-Host "SSH sessions to run Resp.benchmark in background windows."
    Write-Host ""
    Write-Host "Config file keys:"
    Write-Host "  SshKey       - Path to SSH private key"
    Write-Host "  SshUser      - SSH username"
    Write-Host "  SshHost      - Base remote hostname (vm prefix before index)"
    Write-Host "  SshCount     - Number of client VMs (generates vm0, vm1, ...)"
    Write-Host "  Multiplier   - Instances per host (default: 1)"
    Write-Host "  Host         - Benchmark target host (--host)"
    Write-Host "  Port         - Benchmark target port (--port)"
    Write-Host "  Threads      - Number of threads (--threads)"
    Write-Host "  Runtime      - Runtime in seconds (--runtime)"
    Write-Host "  DbSize       - Database size (--dbsize)"
    Write-Host "  KeyLength    - Key length in bytes (--keylength)"
    Write-Host "  ValueLength  - Value length in bytes (--valuelength)"
    Write-Host "  BatchSize    - Batch size (--batchsize)"
    Write-Host "  ClusterBench - Enable cluster bench mode (true/false)"
    Write-Host "  ExtraArgs    - Additional arguments to pass"
    return
}

# --- Parse config file ---
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

$config = @{}
Get-Content $ConfigFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $config[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

# --- Resolve parameters ---
$sshKeyRaw    = $config["SshKey"]       ?? "$env:USERPROFILE\.ssh\id_ed121824_notebook"
# Support array syntax: [key1, key2, ...] — use first that exists
if ($sshKeyRaw -match '^\[(.+)\]$') {
    $candidates = $Matches[1] -split ',\s*'
    $sshKey = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sshKey) {
        Write-Error "None of the SSH keys exist: $($candidates -join ', ')"
        exit 1
    }
} else {
    $sshKey = $sshKeyRaw
}
$sshUser      = $config["SshUser"]      ?? "guser"
$sshHostBase  = $config["SshHost"]      ?? "vm0.dps8v6vmss.southcentralus.cloudapp.azure.com"
$sshCount     = [int]($config["SshCount"] ?? "1")
$multiplier   = [int]($config["Multiplier"] ?? "1")
$benchHost    = $config["Host"]         ?? "10.5.1.4"
$benchPort    = $config["Port"]         ?? "7000"
$threads      = $config["Threads"]      ?? "4"
$runtime      = $config["Runtime"]      ?? "60"
$dbSize       = $config["DbSize"]       ?? ""
$keyLength    = $config["KeyLength"]    ?? ""
$valueLength  = $config["ValueLength"]  ?? ""
$batchSize    = $config["BatchSize"]    ?? ""
$clusterBench = $config["ClusterBench"] ?? "true"
$extraArgs    = $config["ExtraArgs"]    ?? ""

# --- Derive host list from base + count ---
$sshHosts = @()

# Support array syntax: [host1, host2, ...]
if ($sshHostBase -match '^\[(.+)\]$') {
    $baseHosts = $Matches[1] -split ',\s*'
    foreach ($base in $baseHosts) {
        if ($base -match '^([a-zA-Z]+)(\d+)\.(.+)$') {
            $prefix = $Matches[1]
            $startIndex = [int]$Matches[2]
            $domain = $Matches[3]
            for ($i = $startIndex; $i -lt ($startIndex + $sshCount); $i++) {
                for ($m = 0; $m -lt $multiplier; $m++) {
                    $sshHosts += "$prefix$i.$domain"
                }
            }
        } else {
            Write-Error "Invalid host in array: $base (expected <prefix><index>.<domain>)"
            exit 1
        }
    }
} else {
    # Single host pattern
    if ($sshHostBase -match '^([a-zA-Z]+)(\d+)\.(.+)$') {
        $prefix = $Matches[1]
        $startIndex = [int]$Matches[2]
        $domain = $Matches[3]
    } else {
        Write-Error "SshHost must follow pattern: <prefix><index>.<domain> (e.g., vm0.example.com)"
        exit 1
    }
    for ($i = $startIndex; $i -lt ($startIndex + $sshCount); $i++) {
        for ($m = 0; $m -lt $multiplier; $m++) {
            $sshHosts += "$prefix$i.$domain"
        }
    }
}

# --- Build benchmark command ---
$benchCmd = "Resp.benchmark --host $benchHost --port $benchPort --threads $threads --runtime $runtime"
if ($dbSize)       { $benchCmd += " --dbsize $dbSize" }
if ($keyLength)    { $benchCmd += " --keylength $keyLength" }
if ($valueLength)  { $benchCmd += " --valuelength $valueLength" }
if ($batchSize)    { $benchCmd += " --batchsize $batchSize" }
if ($clusterBench -eq "true") {
    $benchCmd += " --cluster-bench"
}
if ($extraArgs) {
    $benchCmd += " $extraArgs"
}

# --- Print summary ---
$instances = $sshHosts.Count
$uniqueHosts = ($sshHosts | Select-Object -Unique).Count
$clientsPerShard = [int]$threads * $instances
Write-Host "=== Benchmark Configuration ===" -ForegroundColor Cyan
Write-Host "  SSH Key    : $sshKey"
Write-Host "  SSH User   : $sshUser"
Write-Host "  Instances  : $instances ($multiplier x $uniqueHosts hosts)"
Write-Host "  Clients    : $clientsPerShard per shard ($threads threads x $instances instances)"
# foreach ($h in ($sshHosts | Select-Object -Unique)) {
#     Write-Host "    $h"
# }
Write-Host "  Command    : $benchCmd"
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""

# --- Results directory ---
$resultsDir = "$PSScriptRoot\results"

# --- Launch benchmark panes ---

# Create timestamped results folder
$runTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = "$resultsDir\$runTimestamp"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
Write-Host "Results will be saved to: $runDir" -ForegroundColor DarkGray
Write-Host ""

# --- Spawn panes in Windows Terminal with Tee-Object ---
Write-Host "Launching $($sshHosts.Count) pane(s) in Windows Terminal..." -ForegroundColor Yellow

$maxPerTab = 2
$wtArgs = @()
$logFiles = @()
for ($i = 0; $i -lt $sshHosts.Count; $i++) {
    $host_ = $sshHosts[$i]
    $logFile = "$runDir\$($host_ -replace '\.', '-')-$i.log"
    $logFiles += $logFile
    $paneCmd = "powershell -NoExit -Command `"ssh -i '$sshKey' -o StrictHostKeyChecking=no $sshUser@$host_ '$benchCmd' 2>&1 | Tee-Object -FilePath '$logFile'`""

    if ($i % $maxPerTab -eq 0) {
        if ($i -eq 0) {
            $wtArgs += "new-tab --title `"$host_`" $paneCmd"
        } else {
            $wtArgs += "; new-tab --title `"$host_`" $paneCmd"
        }
    } else {
        $wtArgs += "; split-pane -H --title `"$host_`" $paneCmd"
    }
}

$tabs = [math]::Ceiling($sshHosts.Count / $maxPerTab)
$wtArgString = $wtArgs -join " "
Start-Process -FilePath "wt" -ArgumentList $wtArgString -Wait:$false

Write-Host "$($sshHosts.Count) benchmark pane(s) launched across $tabs tab(s)." -ForegroundColor Green
Write-Host ""

# --- Wait for all benchmarks to complete ---
Write-Host "Waiting for benchmarks to complete (runtime: ${runtime}s)..." -ForegroundColor Yellow

$timeout = [int]$runtime + 120
$elapsed = 0
$pollInterval = 5

while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval

    $completed = 0
    foreach ($lf in $logFiles) {
        if (Test-Path $lf) {
            $content = Get-Content $lf -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'Total throughput:') {
                $completed++
            }
        }
    }

    Write-Host "`r  Progress: $completed/$($logFiles.Count) complete | ${elapsed}s elapsed" -NoNewline
    if ($completed -eq $logFiles.Count) { break }
}

Write-Host ""
Write-Host ""

# --- Aggregate results ---
Write-Host "=== Aggregate Results ($runTimestamp) ===" -ForegroundColor Cyan
$totalKops = 0.0
$totalData = 0.0
$totalWire = 0.0

$maxHostLen = ($logFiles | ForEach-Object { (Split-Path $_ -Leaf).Replace('.log','').Length } | Measure-Object -Maximum).Maximum

foreach ($lf in $logFiles) {
    $name = (Split-Path $lf -Leaf).Replace('.log','')
    if (Test-Path $lf) {
        $content = Get-Content $lf
        $kopsLine = $content | Where-Object { $_ -match 'Total throughput:.*?([\d,.]+)\s*Kops/sec' } | Select-Object -Last 1
        $dataLine = $content | Where-Object { $_ -match 'Data throughput:.*?([\d.]+)\s*GB/sec' } | Select-Object -Last 1
        $wireLine = $content | Where-Object { $_ -match 'Wire throughput:.*?([\d.]+)\s*GB/sec' } | Select-Object -Last 1

        $kops = 0.0; $data = 0.0; $wire = 0.0
        if ($kopsLine -match '([\d,.]+)\s*Kops/sec') { $kops = [double]($Matches[1] -replace ',', '') }
        if ($dataLine -match '([\d.]+)\s*GB/sec') { $data = [double]$Matches[1] }
        if ($wireLine -match '([\d.]+)\s*GB/sec') { $wire = [double]$Matches[1] }

        $totalKops += $kops
        $totalData += $data
        $totalWire += $wire
        Write-Host ("  {0}  {1,12:N2} Kops/sec | {2,6:N3} GB/s data | {3,6:N3} GB/s wire" -f $name.PadRight($maxHostLen), $kops, $data, $wire)
    } else {
        Write-Host "  $($name.PadRight($maxHostLen))  (no results)" -ForegroundColor DarkGray
    }
}
Write-Host ("  " + ("-" * 70))
Write-Host ("  {0}  {1,12:N2} Kops/sec | {2,6:N3} GB/s data | {3,6:N3} GB/s wire" -f "TOTAL".PadRight($maxHostLen), $totalKops, $totalData, $totalWire) -ForegroundColor Green
