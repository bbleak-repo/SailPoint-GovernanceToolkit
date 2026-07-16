#Requires -Version 5.1
<#
.SYNOPSIS
    Updates entitlement-state.jsonl and reviewer-state.jsonl from the rich audit cache.
.DESCRIPTION
    Reads the cached campaign data (items-*.jsonl, roster-*.json, meta-*.json) via
    Get-SPCachedCampaignSeries, runs the SP.CampaignSeries honest classifier on each
    item, and updates both state files via Invoke-SPStateTracking.

    Delta mode (default): only processes campaign instances not already recorded in the
    state files' processedInstances set. Daily runs complete in ~30 seconds.

    Bootstrap mode (-Force): reprocesses ALL cached campaigns from scratch. Use on
    first run or to rebuild state after cache changes. Takes 2-5 minutes depending
    on cache size.

    This script is independent of V4/V4b/V4c/V4d/V4e/V7/V7c. It reads the same
    cache those scripts populate but does not modify any existing files except the
    two state JSONL files in the metrics directory.
.PARAMETER CachePath
    Override the cache directory. Defaults to the configured cache path.
.PARAMETER MetricsPath
    Override the metrics directory. Defaults to Metrics.Path from settings.json.
.PARAMETER Force
    Ignore processedInstances and reprocess all cached campaigns (bootstrap/rebuild).
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Help
    Display detailed help.
.EXAMPLE
    .\Update-SPStateFiles.ps1
    # Delta update -- process only new campaign instances.
.EXAMPLE
    .\Update-SPStateFiles.ps1 -Force
    # Bootstrap -- reprocess all cached campaigns from scratch.
.NOTES
    Script:  Update-SPStateFiles.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$CachePath,

    [Parameter()]
    [string]$MetricsPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $false }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true  }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif ($mod.Required) {
        Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
        exit 4
    }
}

#endregion

#region Setup

$startTime = Get-Date
$todayLabel = $startTime.ToString('yyyy-MM-dd')

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

$config = $null
try { $config = Get-SPConfig -ConfigPath $ConfigPath } catch {
    Write-Host "ERROR: Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

# Resolve metrics path
if ([string]::IsNullOrWhiteSpace($MetricsPath)) {
    $MetricsPath = '.\Audit\metrics'
    try {
        if ($null -ne $config.PSObject.Properties['Metrics'] -and
            $null -ne $config.Metrics.PSObject.Properties['Path'] -and
            -not [string]::IsNullOrWhiteSpace($config.Metrics.Path)) {
            $MetricsPath = [string]$config.Metrics.Path
        }
    } catch { }
}
if (-not [System.IO.Path]::IsPathRooted($MetricsPath)) {
    $MetricsPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $MetricsPath))
}
if (-not (Test-Path $MetricsPath)) {
    New-Item -ItemType Directory -Path $MetricsPath -Force | Out-Null
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  State File Update' -ForegroundColor Cyan
Write-Host "  Date:       $todayLabel" -ForegroundColor DarkGray
$modeLabel = if ($Force) { 'BOOTSTRAP (reprocessing all cached campaigns)' } else { 'Delta (new instances only)' }
$modeColor = if ($Force) { 'Yellow' } else { 'DarkGray' }
Write-Host "  Mode:       $modeLabel" -ForegroundColor $modeColor
Write-Host "  Metrics:    $MetricsPath" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region State Tracking

try {
    $trackingParams = @{
        MetricsPath = $MetricsPath
        TodayLabel  = $todayLabel
    }
    if ($Force) { $trackingParams['Force'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) { $trackingParams['CachePath'] = $CachePath }

    $tracking = Invoke-SPStateTracking @trackingParams

    $duration = ((Get-Date) - $startTime).TotalSeconds

    Write-Host ''
    Write-Host '  State Update Complete' -ForegroundColor Green
    Write-Host "    Entitlement: $($tracking.Entitlement.Total) records ($($tracking.Entitlement.StateNew) new, $($tracking.Entitlement.StateChanged) changed, $($tracking.Entitlement.NewlyDecided.Count) decided)" -ForegroundColor White
    Write-Host "    Reviewer:    $($tracking.Reviewer.Total) reviewers ($($tracking.Reviewer.ReviewersNew) new, $($tracking.Reviewer.ReviewersUpdated) updated)" -ForegroundColor White

    # File sizes
    $entFile = $tracking.Entitlement.FilePath
    $rvFile  = $tracking.Reviewer.FilePath
    $entSize = if (Test-Path $entFile) { '{0:N0} KB' -f ((Get-Item $entFile).Length / 1024) } else { 'N/A' }
    $rvSize  = if (Test-Path $rvFile)  { '{0:N0} KB' -f ((Get-Item $rvFile).Length / 1024) } else { 'N/A' }
    Write-Host "    State files: $entFile ($entSize)" -ForegroundColor DarkGray
    Write-Host "                 $rvFile ($rvSize)" -ForegroundColor DarkGray

    # Series detected
    if ($tracking.Reviewer.SeriesDetected.Count -gt 0) {
        $seriesLabels = @($tracking.Reviewer.SeriesDetected.Keys | Sort-Object | ForEach-Object { "$_ ($($tracking.Reviewer.SeriesDetected[$_]))" })
        Write-Host "    Series:      $($seriesLabels -join ', ')" -ForegroundColor DarkGray
    }

    Write-Host "    Duration:    $([math]::Round($duration, 1)) seconds" -ForegroundColor DarkGray
    Write-Host ''
}
catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 5
}

#endregion
