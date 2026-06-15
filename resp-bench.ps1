#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Spawns background SSH sessions to run Resp.benchmark on remote VMs.

.DESCRIPTION
    Reads benchmark parameters from a config file and launches SSH sessions
    via Start-Process. Supports multiple client VMs by specifying a base hostname
    and count. Each spawned window stays open after the benchmark completes.

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
$sshKey       = $config["SshKey"]       ?? "$env:USERPROFILE\.ssh\id_ed121824_notebook"
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
foreach ($h in ($sshHosts | Select-Object -Unique)) {
    Write-Host "    $h"
}
Write-Host "  Command    : $benchCmd"
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""

# --- Spawn panes in Windows Terminal (horizontal stack, max 5 per tab) ---
Write-Host "Launching $sshCount pane(s) in Windows Terminal..." -ForegroundColor Yellow

$maxPerTab = 2
$wtArgs = @()
for ($i = 0; $i -lt $sshHosts.Count; $i++) {
    $host_ = $sshHosts[$i]
    $sshCmd = "ssh -i `"$sshKey`" -o StrictHostKeyChecking=no $sshUser@$host_ `"$benchCmd`""

    if ($i % $maxPerTab -eq 0) {
        if ($i -eq 0) {
            $wtArgs += "new-tab --title `"$host_`" cmd /k $sshCmd"
        } else {
            $wtArgs += "; new-tab --title `"$host_`" cmd /k $sshCmd"
        }
    } else {
        $paneIndex = $i % $maxPerTab
        $wtArgs += "; split-pane -H --title `"$host_`" cmd /k $sshCmd"
    }
}

$tabs = [math]::Ceiling($sshHosts.Count / $maxPerTab)
$wtArgString = $wtArgs -join " "
Start-Process -FilePath "wt" -ArgumentList $wtArgString -Wait:$false

Write-Host ""
Write-Host "$sshCount benchmark pane(s) launched across $tabs tab(s)." -ForegroundColor Green
