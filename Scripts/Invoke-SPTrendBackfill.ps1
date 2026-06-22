#Requires -Version 5.1
<#
.SYNOPSIS
    Backfills campaign trend JSONL from existing snapshot files.
.DESCRIPTION
    Reads all campaign snapshots from Audit/Snapshots/ and generates trend
    points for each one via Save-SPCampaignTrendPoint. This populates the
    campaign-trend JSONL files that V5 uses for multi-day progression charts.

    Safe to run multiple times -- Save-SPCampaignTrendPoint uses atomic
    append with retention sweep, and the trend JSONL deduplicates by
    timestamp naturally (same timestamp = same record, overwritten on
    copy-append-rename cycle).

    Run this ONCE to backfill historical trend data from existing snapshots.
    After that, V3/V4/V5 daily runs automatically write trend points.
.PARAMETER SnapshotDir
    Override snapshot directory. Default: resolved from config.
.PARAMETER DaysBack
    Only backfill snapshots from the last N days. Default: 90.
.PARAMETER Help
    Display help.
.EXAMPLE
    .\Scripts\Invoke-SPTrendBackfill.ps1
    # Backfill from all snapshots within 90 days.
.EXAMPLE
    .\Scripts\Invoke-SPTrendBackfill.ps1 -DaysBack 30
    # Backfill from snapshots within 30 days only.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$SnapshotDir,
    [Parameter()] [int]$DaysBack = 90,
    [Parameter()] [switch]$Help
)

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true }
)
foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) { Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking }
    elseif ($mod.Required) { Write-Host "ERROR: Module '$($mod.Name)' not found." -ForegroundColor Red; exit 4 }
}

# Resolve snapshot directory
if ([string]::IsNullOrWhiteSpace($SnapshotDir)) {
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.Audit.PSObject.Properties['SnapshotPath'] -and
            -not [string]::IsNullOrWhiteSpace($cfg.Audit.SnapshotPath)) {
            $SnapshotDir = [string]$cfg.Audit.SnapshotPath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
            $SnapshotDir = Join-Path ([string]$cfg.Audit.OutputPath) 'Snapshots'
        }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Join-Path $toolkitRoot 'Audit\Snapshots' }
if (-not [System.IO.Path]::IsPathRooted($SnapshotDir)) {
    $SnapshotDir = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $SnapshotDir))
}

Write-Host ''
Write-Host '  Campaign Trend Backfill' -ForegroundColor Cyan
Write-Host '  =======================' -ForegroundColor Cyan
Write-Host "  Snapshot dir: $SnapshotDir" -ForegroundColor DarkGray
Write-Host "  DaysBack:     $DaysBack" -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $SnapshotDir)) {
    Write-Host "  ERROR: Snapshot directory does not exist: $SnapshotDir" -ForegroundColor Red
    exit 1
}

$cutoff = (Get-Date).AddDays(-$DaysBack)
$campaignDirs = @(Get-ChildItem -Path $SnapshotDir -Directory -ErrorAction SilentlyContinue)
Write-Host "  Found $($campaignDirs.Count) campaign folder(s)" -ForegroundColor White

$totalPoints = 0
$totalSkipped = 0
$totalErrors = 0

foreach ($cd in $campaignDirs) {
    $snapFiles = @(Get-ChildItem -Path $cd.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' -and $_.LastWriteTime -ge $cutoff } |
        Sort-Object LastWriteTime)

    if ($snapFiles.Count -eq 0) { continue }

    $firstName = ''
    foreach ($sf in $snapFiles) {
        try {
            $snapData = Get-Content $sf.FullName -Raw | ConvertFrom-Json

            if ($null -eq $snapData.Meta -or $null -eq $snapData.Items) {
                $totalSkipped++
                continue
            }

            if ([string]::IsNullOrWhiteSpace($firstName)) {
                $firstName = [string]$snapData.Meta.CampaignName
                Write-Host "  Campaign: $firstName ($($snapFiles.Count) snapshot(s))" -ForegroundColor White
            }

            $result = Save-SPCampaignTrendPoint -Snapshot $snapData
            if ($result.Success) {
                $totalPoints++
                Write-Host "    + $($sf.Name) -> trend point at $($result.Data.Timestamp)" -ForegroundColor DarkGreen
            }
            else {
                $totalErrors++
                Write-Host "    ! $($sf.Name) -> FAILED: $($result.Error)" -ForegroundColor Yellow
            }
        }
        catch {
            $totalErrors++
            Write-Host "    ! $($sf.Name) -> ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host "  Done: $totalPoints trend point(s) written, $totalSkipped skipped, $totalErrors error(s)" -ForegroundColor $(if ($totalErrors -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ''

# Show what trend files now exist
$trendDir = $null
try {
    $cfg = Get-SPConfig
    if ($null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendPath'] -and
        -not [string]::IsNullOrWhiteSpace($cfg.Metrics.CampaignTrendPath)) {
        $trendDir = [string]$cfg.Metrics.CampaignTrendPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($cfg.Metrics.Path)) {
        $trendDir = Join-Path ([string]$cfg.Metrics.Path) 'campaign-trend'
    }
} catch { }
if (-not [string]::IsNullOrWhiteSpace($trendDir) -and (Test-Path $trendDir)) {
    Write-Host '  Trend files:' -ForegroundColor White
    $searchDirs = @($trendDir)
    try { Get-ChildItem -Path $trendDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $searchDirs += $_.FullName } } catch { }
    foreach ($sd in $searchDirs) {
        Get-ChildItem -Path $sd -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $lines = (Get-Content $_.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            Write-Host "    $($_.Name): $lines data point(s)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}
