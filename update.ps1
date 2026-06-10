#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull latest configs repo and copy scripts to their deployed locations.
    Reads manifest.json for source→destination mapping.

.EXAMPLE
    update.ps1 -Pull
    update.ps1
#>
param(
    [switch]$Pull
)

$ErrorActionPreference = "Stop"

$RepoDir = "$HOME/configs"
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

# Ensure target directories exist
sudo mkdir -p /tmp/deploy-actions 2>$null

$entries = Get-Content $Manifest -Raw | ConvertFrom-Json

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

Write-Host "Done. All scripts updated." -ForegroundColor Green
