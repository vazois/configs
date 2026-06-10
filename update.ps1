#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull latest configs repo, copy scripts, and optionally run deploy commands.
    Reads manifest.json for source→destination mapping and runcmd definitions.

.EXAMPLE
    update.ps1 -Pull
    update.ps1 -Run
    update.ps1 -Pull -Run
#>
param(
    [switch]$Pull,
    [switch]$Run
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = $ScriptDir
$Manifest = "$RepoDir/manifest.json"

if ($Pull) {
    Write-Host "Pulling latest from repo..."
    git -C $RepoDir pull --ff-only -q 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: git pull failed" -ForegroundColor Yellow }
}

if (-not (Test-Path $Manifest)) {
    throw "ERROR: $Manifest not found"
}

Write-Host "Copying scripts to deployed locations..."

$entries = Get-Content $Manifest -Raw | ConvertFrom-Json

# Ensure target directories exist (derive from manifest destinations)
$dirs = $entries.scripts | ForEach-Object { Split-Path $_.dst -Parent } | Sort-Object -Unique
foreach ($dir in $dirs) {
    sudo mkdir -p $dir 2>$null
}

foreach ($entry in $entries.scripts) {
    $src = "$RepoDir/$($entry.src)"
    $dst = $entry.dst
    $mode = $entry.mode

    if (Test-Path $src) {
        sudo cp $src $dst
        sudo chmod $mode $dst
        Write-Host "  $dst" -ForegroundColor DarkGray
    } else {
        Write-Host "  SKIP: $($entry.src) (not found)" -ForegroundColor Yellow
    }
}

Write-Host "Scripts updated." -ForegroundColor Green

# Execute runcmd section if -Run is passed
if ($Run) {
    if (-not $entries.runcmd) {
        Write-Host "No runcmd section in manifest. Skipping."
        return
    }

    Write-Host ""
    Write-Host "Executing runcmd from manifest..."

    foreach ($cmd in $entries.runcmd) {
        $scriptName = $cmd.run
        $useSudo = $cmd.sudo
        $args = $cmd.args
        $background = if ($cmd.PSObject.Properties['background']) { $cmd.background } else { $false }

        # Resolve script path from the scripts section by matching filename
        $scriptEntry = $entries.scripts | Where-Object { $_.src -like "*$scriptName" } | Select-Object -First 1
        if (-not $scriptEntry -or -not (Test-Path $scriptEntry.dst)) {
            Write-Host "  ERROR: Cannot resolve script '$scriptName' from manifest" -ForegroundColor Red
            continue
        }

        $scriptPath = $scriptEntry.dst
        $runCmd = if ($useSudo) { "sudo $scriptPath $args" } else { "$scriptPath $args" }

        Write-Host "  -> $runCmd"
        if ($background) {
            $logFile = "/var/log/$($scriptName -replace '\.sh$','').log"
            bash -c "nohup $runCmd > $logFile 2>&1 &"
        } else {
            bash -c $runCmd
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAILED: $runCmd" -ForegroundColor Red
            }
        }
    }

    Write-Host "All runcmd steps complete." -ForegroundColor Green
}
