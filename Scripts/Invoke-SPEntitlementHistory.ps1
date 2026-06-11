#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a per-entitlement decision HISTORY across many campaign snapshots -- the full timeline
    for each identity+entitlement (e.g. admin_xyz / John Doe: APPROVE 6/8 -> APPROVE 6/9 ->
    REVOKE 6/11). Read-only, no API: it reads the immutable snapshots already on disk.
.DESCRIPTION
    Resolves a set of snapshots (Get-SPCampaignSnapshotSet) and walks them
    (Get-SPEntitlementHistory) to produce a timeline per identity|access|source, then renders an
    HTML report (by entitlement and/or by identity) and an optional CSV. By default it shows only
    timelines that CHANGED (a decision flip, a first-time grant, or a drop from scope).

    Two timeline modes:
      * default        -- one point per campaign whose snapshots match the name filter (the
                          "separate daily campaigns" view: admin_xyz across Mon/Tue/Wed).
      * -WithinCampaign -- every capture of ONE long-lived campaign (how it evolved as laggards
                          and reviewers acted). Requires the filter to resolve to one campaign.

    Snapshots are produced by Invoke-SPCampaignDiff.ps1 (capture one per active campaign on a
    schedule so each builds a timeline). Validate captures first with Invoke-SPCacheValidate.ps1.
.PARAMETER SnapshotDir
    Snapshot root. Defaults to the toolkit's configured snapshot directory (Audit\snapshots).
.PARAMETER CampaignId
    Pin a single campaign by id.
.PARAMETER CampaignName / -CampaignNameStartsWith / -CampaignNameContains
    Match campaigns by their snapshot CampaignName (exact -> starts-with -> contains).
.PARAMETER WithinCampaign
    Walk every capture of ONE campaign instead of one-per-campaign.
.PARAMETER AccessName / -AccessId / -IdentityName / -IdentityId
    Focus the report on one entitlement and/or identity (name = substring, id = exact).
.PARAMETER GroupBy
    Entitlement | Identity | Both (default Both).
.PARAMETER IncludeUnchanged
    Also include timelines whose decision never changed.
.PARAMETER MaxTimelines
    Cap the number of timelines (most-changed first). 0 = no cap (default). When it truncates,
    it prints how many were dropped (no silent cap).
.PARAMETER OutputPath
    Output directory (default Audit\history). One HTML (+ CSV with -IncludeCsv) is written.
.PARAMETER IncludeCsv
    Also write the flat per-observation CSV.
.PARAMETER OutputMode
    Console (default) / JSON / Both.
.PARAMETER Help
    Show full help and exit.
.EXAMPLE
    .\Invoke-SPEntitlementHistory.ps1 -CampaignNameContains 'Daily Attestation Manager' -AccessName 'admin_xyz'
    # admin_xyz's decision timeline across every matching daily campaign.
.EXAMPLE
    .\Invoke-SPEntitlementHistory.ps1 -CampaignId 'camp-7f3a...' -WithinCampaign -IncludeCsv
    # How one long-lived campaign's decisions evolved across its captures, with a CSV.
.NOTES
    Script:  Invoke-SPEntitlementHistory.ps1
    Version: 1.0.0
    Read-only (no -WhatIf / SupportsShouldProcess by policy: CLI-005). No ISC API calls.
    Exit codes: 0 = report written | 2 = parameter / no matching snapshots | 5 = generation error.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$SnapshotDir,
    [Parameter()][string]$CampaignId,
    [Parameter()][string]$CampaignName,
    [Parameter()][string]$CampaignNameStartsWith,
    [Parameter()][string]$CampaignNameContains,
    [Parameter()][switch]$WithinCampaign,
    [Parameter()][string]$AccessName,
    [Parameter()][string]$AccessId,
    [Parameter()][string]$IdentityName,
    [Parameter()][string]$IdentityId,
    [Parameter()][ValidateSet('Entitlement', 'Identity', 'Both')][string]$GroupBy = 'Both',
    [Parameter()][switch]$IncludeUnchanged,
    [Parameter()][int]$MaxTimelines = 0,
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$IncludeCsv,
    [Parameter()][ValidateSet('Console', 'JSON', 'Both')][string]$OutputMode = 'Console',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

#region Module load
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @('SP.Core', 'SP.Audit')) {
    $manifest = Join-Path $toolkitRoot (Join-Path 'Modules' (Join-Path $mod "$mod.psd1"))
    if (Test-Path $manifest) { Import-Module $manifest -Force -DisableNameChecking -ErrorAction Stop }
    elseif ($mod -eq 'SP.Audit') { Write-Host "ERROR: Required module '$mod' not found at: $manifest" -ForegroundColor Red; exit 2 }
}
#endregion

#region Resolve snapshot set
$setArgs = @{}
if ($SnapshotDir)            { $setArgs['SnapshotDir'] = $SnapshotDir }
if ($CampaignId)            { $setArgs['CampaignId'] = $CampaignId }
if ($CampaignName)          { $setArgs['CampaignName'] = $CampaignName }
if ($CampaignNameStartsWith){ $setArgs['CampaignNameStartsWith'] = $CampaignNameStartsWith }
if ($CampaignNameContains)  { $setArgs['CampaignNameContains'] = $CampaignNameContains }
if ($WithinCampaign)        { $setArgs['WithinCampaign'] = $true }

$setR = Get-SPCampaignSnapshotSet @setArgs
if (-not $setR.Success) { Write-Host "ERROR: $($setR.Error)" -ForegroundColor Red; exit 2 }
$snapshots = @($setR.Data)
if ($snapshots.Count -eq 0) {
    Write-Host "  No snapshots matched. Capture some first with Invoke-SPCampaignDiff.ps1, or widen the filters." -ForegroundColor Yellow
    exit 2
}
if ($snapshots.Count -lt 2 -and -not $IncludeUnchanged) {
    Write-Host "  Only 1 snapshot resolved -- a history needs >=2 to show change. Showing it anyway." -ForegroundColor Yellow
}
#endregion

#region Build + render
$histR = Get-SPEntitlementHistory -Snapshots $snapshots -AccessName $AccessName -AccessId $AccessId `
    -IdentityName $IdentityName -IdentityId $IdentityId -IncludeUnchanged:$IncludeUnchanged
if (-not $histR.Success) { Write-Host "ERROR: $($histR.Error)" -ForegroundColor Red; exit 5 }
$history = $histR.Data

$droppedTimelines = 0
if ($MaxTimelines -gt 0 -and @($history.Timelines).Count -gt $MaxTimelines) {
    $all = @($history.Timelines | Sort-Object -Property @{ Expression = { [int]$_.ChangeCount } } -Descending)
    $droppedTimelines = $all.Count - $MaxTimelines
    $history.Timelines = @($all | Select-Object -First $MaxTimelines)
    Write-Host "  NOTE: capped to $MaxTimelines timeline(s); $droppedTimelines with fewer changes were omitted (raise -MaxTimelines to see them)." -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'history') }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$htmlPath = Join-Path $OutputPath "entitlement-history-$stamp.html"

$expR = Export-SPEntitlementHistoryHtml -History $history -OutputPath $htmlPath -GroupBy $GroupBy
if (-not $expR.Success) { Write-Host "ERROR: $($expR.Error)" -ForegroundColor Red; exit 5 }

$csvPath = ''
if ($IncludeCsv) {
    $csvPath = Join-Path $OutputPath "entitlement-history-$stamp.csv"
    $csvR = Export-SPEntitlementHistoryCsv -History $history -OutputPath $csvPath
    if (-not $csvR.Success) { Write-Host "  WARN: CSV export failed: $($csvR.Error)" -ForegroundColor Yellow; $csvPath = '' }
}
#endregion

#region Output
$summary = [PSCustomObject]@{
    Snapshots         = [int]$history.Meta.SnapshotCount
    Timelines         = @($history.Timelines).Count
    Changed           = @($history.Timelines | Where-Object { $_.HasChange }).Count
    DroppedByCap      = $droppedTimelines
    Mode              = if ($WithinCampaign) { 'WithinCampaign' } else { 'CrossCampaign' }
    GroupBy           = $GroupBy
    Window            = @($history.Meta.CampaignNames)
    HtmlPath          = $expR.Data
    CsvPath           = $csvPath
}

if ($OutputMode -ne 'JSON') {
    Write-Host ''
    Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
    Write-Host '  Per-Entitlement Decision History' -ForegroundColor Cyan
    Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
    Write-Host "  Mode:        $($summary.Mode)  (GroupBy=$GroupBy)" -ForegroundColor Gray
    Write-Host "  Snapshots:   $($summary.Snapshots)" -ForegroundColor Gray
    Write-Host "  Timelines:   $($summary.Timelines)  (with a change: $($summary.Changed))" -ForegroundColor Gray
    if ($droppedTimelines -gt 0) { Write-Host "  Omitted:     $droppedTimelines (by -MaxTimelines)" -ForegroundColor Yellow }
    Write-Host "  HTML:        $($summary.HtmlPath)" -ForegroundColor DarkCyan
    if ($csvPath) { Write-Host "  CSV:         $csvPath" -ForegroundColor DarkCyan }
    Write-Host ''
    if ($OutputMode -eq 'Both') { Write-Host '  JSON Output:' -ForegroundColor Cyan; $summary | ConvertTo-Json -Depth 6 }
}
elseif ($OutputMode -eq 'JSON') { $summary | ConvertTo-Json -Depth 6 }
#endregion

exit 0
