#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the KPI TREND report for a recurring attestation campaign -- how its rates
    (privileged approval rate, revoke rate, privileged share of scope, completion %) move
    over days / weeks / months. Answers "is privileged access trending in a direction?"

.DESCRIPTION
    READ-ONLY. Reads the per-campaign KPI time-series accumulated by Invoke-SPCampaignDiff
    (each diff run appends one rate row) and rolls it up Daily / Weekly / Monthly with a
    direction-neutral arrow and a data-completeness strip. Writes an HTML report; never
    calls ISC and never mutates anything.

    The trend is a MANAGEMENT / maturity view -- aggregate, lossy, and explicitly NOT the
    certification evidence (the immutable snapshots are). Run Invoke-SPCampaignDiff on the
    campaign's cadence first to accumulate the series.

.PARAMETER ConfigPath
    Path to settings.json (defaults to ..\Config\settings.json).
.PARAMETER CampaignId
    Campaign id whose series to report (the stable id used by the diff runs).
.PARAMETER Granularity
    Daily | Weekly | Monthly rollup. Default Weekly.
.PARAMETER DaysBack
    Window in days. Default 365.
.PARAMETER Environment
    Environment subfolder the series was captured under (defaults to Global.EnvironmentName).
.PARAMETER OutputPath
    Directory for the HTML (default {Audit.OutputPath}\trend).
.PARAMETER OutputMode
    Run-summary format: Console (default), JSON, HTML, or Both. The HTML is always written.
.PARAMETER Help
    Display full help and exit.
.EXAMPLE
    .\Invoke-SPCampaignTrendReport.ps1 -CampaignId 'camp-7f3a...' -Granularity Weekly
.NOTES
    Exit codes: 0 ok | 1 no data | 2 parameter | 4 config. Read-only (CLI-005).
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$CampaignId,
    # Cross-campaign PROGRAM trend (throughput + privileged-approval direction across all
    # campaigns) instead of a single campaign's series. -CampaignId is not required with -Program.
    [Parameter()][switch]$Program,
    [Parameter()][ValidateSet('Daily', 'Weekly', 'Monthly')][string]$Granularity = 'Weekly',
    [Parameter()][int]$DaysBack = 365,
    [Parameter()][string]$Environment,
    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'JSON', 'HTML', 'Both')][string]$OutputMode = 'Console',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

$scriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @('SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1')) {
    $p = Join-Path $toolkitRoot "Modules\$mod"
    if (Test-Path $p) { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop }
    else { Write-Host "ERROR: required module not found: $p" -ForegroundColor Red; exit 4 }
}

if (-not $Program -and [string]::IsNullOrWhiteSpace($CampaignId)) { Write-Host 'ERROR: -CampaignId is required (or use -Program for the cross-campaign trend).' -ForegroundColor Red; exit 2 }

$startTime = Get-Date
try {
    if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }
    $config = Get-SPConfig -ConfigPath $ConfigPath
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { Write-Host "ERROR: configuration load failed: $($_.Exception.Message)" -ForegroundColor Red; exit 4 }

if ([string]::IsNullOrWhiteSpace($Environment)) {
    try { if ($config.PSObject.Properties.Name -contains 'Global' -and $config.Global.PSObject.Properties.Name -contains 'EnvironmentName') { $Environment = [string]$config.Global.EnvironmentName } } catch { }
}

$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditBase = if ($config.PSObject.Properties.Name -contains 'Audit' -and $config.Audit.PSObject.Properties.Name -contains 'OutputPath') { [string]$config.Audit.OutputPath } else { 'Audit' }
    $effectiveOutputPath = Join-Path $auditBase 'trend'
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) { $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath }
if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }

Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host ''

if ($Program) {
    Write-Host "  Program Governance Trend (read-only) | $Granularity | last $DaysBack days"
    $pr = Get-SPProgramTrend -DaysBack $DaysBack -Granularity $Granularity -Environment ([string]$Environment)
    if (-not $pr.Success) { Write-Host "ERROR: $($pr.Error)" -ForegroundColor Red; exit 1 }
    if ([int]$pr.Data.RowCount -eq 0) { Write-Host '  No program trend data yet -- it accumulates as diff/tracker runs append per-campaign KPI rows.' -ForegroundColor Yellow; exit 1 }
    $ex = Export-SPProgramTrendHtml -Trend $pr.Data -OutputPath $effectiveOutputPath
    $generated = @()
    if ($ex.Success) { $generated += $ex.Data; Write-Host "  program trend: $($ex.Data)" -ForegroundColor Green }
    Write-Host ''
    Write-Host "  Across $($pr.Data.CampaignCount) campaign(s): priv-approval $($pr.Data.Direction.PrivApprovalRate), closings $($pr.Data.Direction.Closed), completion $($pr.Data.Direction.Completion)" -ForegroundColor Cyan
    if ($OutputMode -in @('JSON', 'Both')) { [ordered]@{ Program = $true; Granularity = $Granularity; CampaignCount = $pr.Data.CampaignCount; Direction = $pr.Data.Direction; Reports = @($generated); OutputPath = $effectiveOutputPath } | ConvertTo-Json -Depth 6 }
    exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
}

Write-Host "  Campaign KPI Trend (read-only) | Campaign: $CampaignId | $Granularity | last $DaysBack days"

$tr = Get-SPCampaignTrend -CampaignId $CampaignId -DaysBack $DaysBack -Granularity $Granularity -Environment ([string]$Environment)
if (-not $tr.Success) { Write-Host "ERROR: $($tr.Error)" -ForegroundColor Red; exit 1 }
$trend = $tr.Data
if ([int]$trend.PointCount -eq 0) {
    Write-Host '  No trend data for this campaign yet -- run Invoke-SPCampaignDiff on the campaign cadence to accumulate the series.' -ForegroundColor Yellow
    exit 1
}

$ex = Export-SPCampaignTrendHtml -Trend $trend -OutputPath $effectiveOutputPath
$generated = @()
if ($ex.Success) { $generated += $ex.Data; Write-Host "  trend report: $($ex.Data)" -ForegroundColor Green }
else { Write-Host "  WARN: trend report failed: $($ex.Error)" -ForegroundColor Yellow }

$durationStr = '{0:N1}s' -f ((Get-Date) - $startTime).TotalSeconds
if ($OutputMode -in @('Console', 'HTML', 'Both')) {
    Write-Host ''
    $pa = if ($trend.Trends.ContainsKey('rates.privApprovalRate')) { $trend.Trends['rates.privApprovalRate'] } else { $null }
    if ($pa) { Write-Host "  Privileged approval rate: $($pa.Direction) ($($pa.ChangePercent)%) over $($trend.PointCount) capture(s)" -ForegroundColor Cyan }
    Write-Host "  Generated $($generated.Count) report(s) in $durationStr -> $effectiveOutputPath" -ForegroundColor Cyan
}
if ($OutputMode -in @('JSON', 'Both')) {
    $directions = [ordered]@{}
    foreach ($k in $trend.Trends.Keys) { $directions[$k] = @{ Direction = $trend.Trends[$k].Direction; ChangePercent = $trend.Trends[$k].ChangePercent } }
    [ordered]@{
        CampaignId  = $trend.CampaignId
        Granularity = $trend.Granularity
        PointCount  = $trend.PointCount
        Directions  = $directions
        Reports     = @($generated)
        OutputPath  = $effectiveOutputPath
        DurationSec = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 6
}

exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
