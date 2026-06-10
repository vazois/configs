#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Manage valkey/garnet cluster instances: start, stop, or update configs.

.EXAMPLE
    mcluster.ps1 -Action start -System valkey -Template cache -Nodes 16
    mcluster.ps1 -Action start -System garnet -Template cache -Nodes 1 -NoCluster
    mcluster.ps1 -Action stop -System valkey -Nodes 16
    mcluster.ps1 -Action stop
    mcluster.ps1 -Action update -System garnet -Template cache
    mcluster.ps1 -Action update -System valkey -Template cache -Nodes 16 -NoCluster
#>
param(
    [Parameter(Mandatory)][ValidateSet("start","stop","update")][string]$Action,
    [string]$System,
    [string]$Template,
    [int]$Nodes = 0,
    [switch]$NoCluster
)

$ErrorActionPreference = "Stop"

# Load config
$configFile = "/opt/deploy-actions/config.env"
if (Test-Path $configFile) {
    Get-Content $configFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)="?([^"]*)"?\s*$' -and $_ -notmatch '^\s*#') {
            Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
        }
    }
}

# Defaults if config.env not loaded
if (-not $IFACE) { $IFACE = "eth1" }
if (-not $BASE_PORT) { $BASE_PORT = 7000 } else { $BASE_PORT = [int]$BASE_PORT }
if (-not $DEPLOY_USER) { $DEPLOY_USER = "guser" }

$ConfDir = "$HOME/configs"
$ClusterMode = if ($NoCluster) { "false" } else { "true" }

function Pull-Configs {
    if (Test-Path "$ConfDir/.git") {
        Write-Host "Pulling latest configs..."
        git -C $ConfDir pull --ff-only -q 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: git pull failed, using cached configs" -ForegroundColor Yellow }
    }
}

function Get-Eth1Ip {
    $output = ip -4 addr show $IFACE 2>$null
    $inetLine = $output | Where-Object { $_ -match 'inet\s+([\d.]+)' } | Select-Object -First 1
    if ($inetLine -match 'inet\s+([\d.]+)') { return $Matches[1] }
    throw "ERROR: Could not determine $IFACE IP"
}

function Resolve-Template {
    param([string]$Sys, [string]$Tmpl, [int]$Count)

    $tmplFile = "$ConfDir/${Sys}-${Tmpl}.conf"
    if (-not (Test-Path $tmplFile)) {
        $available = Get-ChildItem "$ConfDir/*.conf" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
        throw "ERROR: Template not found: $tmplFile`nAvailable: $($available -join ', ')"
    }

    $eth1Ip = Get-Eth1Ip
    $clusterDir = if ($Sys -eq "garnet") { "$HOME/garnet-cluster" } else { "$HOME/valkey-cluster" }
    New-Item -ItemType Directory -Path $clusterDir -Force | Out-Null

    for ($i = 0; $i -lt $Count; $i++) {
        $port = $BASE_PORT + $i
        $portDir = "$clusterDir/$port"
        New-Item -ItemType Directory -Path $portDir -Force | Out-Null

        $content = Get-Content $tmplFile -Raw
        $content = $content -replace '\$eth1', $eth1Ip
        $content = $content -replace '\$port', $port

        if ($Sys -eq "garnet") {
            $content = $content -replace '"EnableCluster":\s*true', "`"EnableCluster`": $ClusterMode"
            Set-Content -Path "$portDir/garnet.conf" -Value $content -NoNewline
        } else {
            # Handle cluster-enabled for valkey
            if ($content -match '(?m)^cluster-enabled') {
                $clusterVal = if ($ClusterMode -eq "true") { "cluster-enabled yes" } else { "cluster-enabled no" }
                $content = $content -replace '(?m)^cluster-enabled.*', $clusterVal
            } else {
                $clusterVal = if ($ClusterMode -eq "true") { "cluster-enabled yes" } else { "cluster-enabled no" }
                $content += "`n$clusterVal`n"
            }
            Set-Content -Path "$portDir/valkey.conf" -Value $content -NoNewline
        }
    }
    Write-Host "Resolved $Count config(s) from ${Sys}-${Tmpl}.conf (cluster=$ClusterMode) -> $clusterDir/" -ForegroundColor Green
}

function Start-Valkey {
    param([int]$Count)
    $clusterDir = "$HOME/valkey-cluster"
    Write-Host "Starting $Count valkey-server instances (ports ${BASE_PORT}-$($BASE_PORT + $Count - 1))..."
    for ($i = 0; $i -lt $Count; $i++) {
        $port = $BASE_PORT + $i
        $dir = "$clusterDir/$port"
        $conf = "$dir/valkey.conf"
        if (-not (Test-Path $conf)) { throw "ERROR: $conf not found" }

        $running = bash -c "pgrep -f 'valkey-server.*:${port}'" 2>$null
        if ($running) { Write-Host "  Port ${port}: already running (skipped)" -ForegroundColor DarkGray; continue }

        Set-Location $dir
        bash -c "valkey-server '$conf' --daemonize yes --logfile '$dir/valkey.log' --pidfile '$dir/valkey.pid'"
        Write-Host "  Port ${port}: started" -ForegroundColor Cyan
    }
}

function Start-Garnet {
    param([int]$Count)
    $clusterDir = "$HOME/garnet-cluster"
    Write-Host "Starting $Count GarnetServer instance(s)..."
    for ($i = 0; $i -lt $Count; $i++) {
        $port = $BASE_PORT + $i
        $dir = "$clusterDir/$port"
        $conf = "$dir/garnet.conf"
        if (-not (Test-Path $conf)) { throw "ERROR: $conf not found" }

        $running = bash -c "pgrep -f 'GarnetServer.*--port ${port}'" 2>$null
        if ($running) { Write-Host "  Port ${port}: already running (skipped)" -ForegroundColor DarkGray; continue }

        bash -c "GarnetServer --config-import-path='$conf' &"
        Write-Host "  Port ${port}: started" -ForegroundColor Cyan
    }
}

function Stop-System {
    param([string]$Sys, [int]$Count)
    if ($Sys -eq "garnet") {
        if ($Count -gt 0) {
            for ($i = 0; $i -lt $Count; $i++) {
                $port = $BASE_PORT + $i
                $procId = bash -c "pgrep -f 'GarnetServer.*--port ${port}'" 2>$null
                if ($procId) { bash -c "kill $procId"; Write-Host "  Garnet port ${port}: stopped (pid $procId)" }
                else { Write-Host "  Garnet port ${port}: not running" -ForegroundColor DarkGray }
            }
        } else {
            bash -c "pkill -f GarnetServer" 2>$null
            Write-Host "All GarnetServer instances stopped."
        }
    } else {
        if ($Count -gt 0) {
            for ($i = 0; $i -lt $Count; $i++) {
                $port = $BASE_PORT + $i
                $procId = bash -c "pgrep -f 'valkey-server.*:${port}'" 2>$null
                if ($procId) { bash -c "kill $procId"; Write-Host "  Valkey port ${port}: stopped (pid $procId)" }
                else { Write-Host "  Valkey port ${port}: not running" -ForegroundColor DarkGray }
            }
        } else {
            bash -c "pkill -f valkey-server" 2>$null
            Write-Host "All valkey-server instances stopped."
        }
    }
}

# Main logic
switch ($Action) {
    "start" {
        if (-not $System) { throw "Usage: mcluster.ps1 -Action start -System <system> -Template <template> -Nodes <n>" }
        if (-not $Template) { throw "Usage: mcluster.ps1 -Action start -System <system> -Template <template> -Nodes <n>" }
        if ($Nodes -le 0) { throw "Usage: mcluster.ps1 -Action start -System <system> -Template <template> -Nodes <n>" }

        Pull-Configs
        Resolve-Template -Sys $System -Tmpl $Template -Count $Nodes

        if ($System -eq "garnet") { Start-Garnet -Count $Nodes }
        else { Start-Valkey -Count $Nodes }
        Write-Host "Done." -ForegroundColor Green
    }

    "stop" {
        if (-not $System) {
            Write-Host "Stopping all instances..."
            bash -c "pkill -f valkey-server" 2>$null; Write-Host "  valkey-server stopped." -ForegroundColor Cyan
            bash -c "pkill -f GarnetServer" 2>$null; Write-Host "  GarnetServer stopped." -ForegroundColor Cyan
            Write-Host "Done." -ForegroundColor Green
        } else {
            Stop-System -Sys $System -Count $Nodes
        }
    }

    "update" {
        if (-not $System) { throw "Usage: mcluster.ps1 -Action update -System <system> -Template <template> [-Nodes <n>]" }
        if (-not $Template) { throw "Usage: mcluster.ps1 -Action update -System <system> -Template <template> [-Nodes <n>]" }

        Pull-Configs

        # Auto-detect node count if not specified
        if ($Nodes -le 0) {
            $clusterDir = if ($System -eq "garnet") { "$HOME/garnet-cluster" } else { "$HOME/valkey-cluster" }
            $dirs = Get-ChildItem -Path $clusterDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' }
            $Nodes = ($dirs | Measure-Object).Count
            if ($Nodes -eq 0) { throw "ERROR: No existing cluster dir found and no -Nodes specified" }
        }

        Resolve-Template -Sys $System -Tmpl $Template -Count $Nodes
        Write-Host "Updated configs in place. Restart instances to apply." -ForegroundColor Yellow
    }
}
