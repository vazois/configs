#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs memtier_benchmark with load and benchmark phases.

.EXAMPLE
    memtier-bench.ps1 -Address 10.5.0.4 -Port 6379
    memtier-bench.ps1 -Address 10.5.0.4 -Port 6379 -Threads 64 -Clients 32 -SkipLoad
    memtier-bench.ps1 -Address 10.5.0.4 -Port 7000 -Pipeline 512 -DbSize 1000000 -DataSize 128 -TestTime 30
#>
param(
    [Parameter(Mandatory)][string]$Address,
    [Parameter(Mandatory)][int]$Port,
    [int]$Threads = 128,
    [int]$Clients = 64,
    [int]$Pipeline = 1024,
    [long]$DbSize = 268435456,
    [int]$DataSize = 8,
    [int]$TestTime = 15,
    [switch]$SkipLoad
)

$ErrorActionPreference = "Stop"

# Phase 1: Load keys
if (-not $SkipLoad) {
    Write-Host "==== Loading keys ====" -ForegroundColor Yellow
    memtier_benchmark -s $Address `
        --port=$Port `
        --ratio=1:0 `
        --pipeline=$Pipeline `
        --data-size=$DataSize `
        --clients=$Clients `
        --threads=$Threads `
        --key-minimum=1 `
        --key-maximum=$DbSize `
        --key-pattern=P:P `
        --run-count=1 `
        --hide-histogram `
        --requests=allkeys
    if ($LASTEXITCODE -ne 0) { throw "Load phase failed" }
} else {
    Write-Host "==== Skipping load phase ====" -ForegroundColor DarkGray
}

# Phase 2: Benchmark
Write-Host ""
Write-Host "==== Running benchmark ====" -ForegroundColor Yellow
$allResults = @()

for ($i = $Threads; $i -le $Threads; $i *= 2) {
    $output = memtier_benchmark -s $Address `
        --port=$Port `
        --ratio=1:9 `
        --pipeline=$Pipeline `
        --data-size=$DataSize `
        --clients=$Clients `
        --threads=$i `
        --test-time=$TestTime `
        --run-count=1 `
        --hide-histogram `
        --key-minimum=1 `
        --key-maximum=$DbSize `
        --key-pattern=R:R 2>&1 | Tee-Object -Variable rawOutput

    $rawOutput | ForEach-Object { Write-Host $_ }
    $totals = $rawOutput | Where-Object { $_ -match "Totals" } | Select-Object -Last 1
    if ($totals) {
        Write-Host "$i $totals" -ForegroundColor Cyan
        $allResults += "$i $totals"
    }
}

Write-Host ""
Write-Host "==== Final Summary ====" -ForegroundColor Green
Write-Host "pipeline: $Pipeline, threads: $Threads, clients: $Clients, payload: $DataSize, dbSize: $DbSize, testTime: $TestTime"
$allResults | ForEach-Object { Write-Host $_ }
