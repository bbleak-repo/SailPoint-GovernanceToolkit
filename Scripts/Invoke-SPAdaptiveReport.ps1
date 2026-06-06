#Requires -Version 5.1
<#
.SYNOPSIS
    Generates adaptive governance reports (composable RC components + baseline
    reports) from SailPoint ISC campaign data. ADDITIVE -- sits alongside the
    existing reports; nothing is replaced.
.DESCRIPTION
    Pulls campaign-audit data for a selected date window, pivots it into the RC
    GroupResults shape via Build-SPRCDataset (entitlement or campaign anchor), and
    renders:
      * a composable HTML report from -Components (KPI cards, heatmap, tree,
        top-N, group table), and/or
      * one or more baseline reports from -BaselineReport (inventory, privileged
        review, orphaned/disabled, exec summary, roster, access-cert, SoD).

    Read-only: it only reads ISC and writes HTML/JSONL locally. The optional
    leadership-distribution mode (per-band reports + WhatIf-SMTP preview + upper-
    leadership rollup) is provided separately (see AR-21) and reuses the existing
    Invoke-SPReportDistribution machinery.
.PARAMETER ConfigPath
    Path to settings.json (defaults to ..\Config\settings.json, honoring
    settings.local.json).
.PARAMETER Token
    Browser/PAT bearer token (bypasses OAuth).
.PARAMETER TokenExpiryMinutes
    Minutes until a browser token is treated as expired. Default 10.
.PARAMETER Anchor
    Data-mapping anchor: 'Entitlement' (group = entitlement, members = identities
    holding it) or 'Campaign' (group = certification campaign). Default Entitlement.
.PARAMETER Components
    Ordered RC component keys for the composable report (kpi-cards, heatmap, tree,
    top-n, group-table, diff; append ':half' for half-width). Default
    kpi-cards,top-n,group-table. Pass @() to skip the composable report.
.PARAMETER BaselineReport
    One or more baseline reports to render: inventory, privileged, orphaned,
    exec-summary, roster, access-cert, sod, or all. Default none.
.PARAMETER Theme
    'light' (default) or 'dark'.
.PARAMETER Status
    Campaign status filter. Default COMPLETED, ACTIVE.
.PARAMETER DaysBack
    Only include campaigns created within the last N days. Default 90.
.PARAMETER CreatedAfter
    Lower bound on campaign creation date (ISO 8601). Takes precedence over -DaysBack.
.PARAMETER CreatedBefore
    Upper bound on campaign creation date (ISO 8601).
.PARAMETER OutputPath
    Directory for the generated HTML (default {Audit.OutputPath}\adaptive).
.PARAMETER OutputMode
    Run-summary format: Console (default), JSON, HTML, or Both. The HTML report
    files are always written regardless.
.PARAMETER Help
    Display full help and exit.
.EXAMPLE
    .\Invoke-SPAdaptiveReport.ps1 -Anchor Entitlement -Components kpi-cards,top-n,group-table -DaysBack 180
.EXAMPLE
    .\Invoke-SPAdaptiveReport.ps1 -BaselineReport inventory,privileged,exec-summary -Theme dark -Status COMPLETED
.NOTES
    Exit codes: 0 ok | 1 no campaigns/data | 2 parameter | 3 auth | 4 config.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,

    [Parameter()][ValidateSet('Entitlement', 'Campaign')][string]$Anchor = 'Entitlement',
    [Parameter()][string[]]$Components = @('kpi-cards', 'top-n', 'group-table'),
    [Parameter()][ValidateSet('inventory', 'privileged', 'orphaned', 'exec-summary', 'roster', 'access-cert', 'sod', 'all')]
    [string[]]$BaselineReport = @(),
    [Parameter()][ValidateSet('light', 'dark')][string]$Theme = 'light',

    [Parameter()][ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')][string[]]$Status = @('COMPLETED', 'ACTIVE'),
    [Parameter()][int]$DaysBack = 90,
    [Parameter()][string]$CreatedAfter,
    [Parameter()][string]$CreatedBefore,

    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'JSON', 'HTML', 'Both')][string]$OutputMode = 'Console',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

#region Module load
$scriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @(
    'SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1',
    'SP.ReportComponents\SP.ReportComponents.psd1', 'SP.AdaptiveReports\SP.AdaptiveReports.psd1')) {
    $p = Join-Path $toolkitRoot "Modules\$mod"
    if (Test-Path $p) { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop }
    else { Write-Host "ERROR: required module not found: $p" -ForegroundColor Red; exit 4 }
}
#endregion

$correlationID = [guid]::NewGuid().ToString()
$startTime = Get-Date

# --- Config + logging + auth ------------------------------------------------
try {
    if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }
    $config = Get-SPConfig -ConfigPath $ConfigPath
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { Write-Host "ERROR: configuration load failed: $($_.Exception.Message)" -ForegroundColor Red; exit 4 }

if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $null = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -ErrorAction SilentlyContinue
}

# --- Resolve output path ----------------------------------------------------
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditBase = if ($config.PSObject.Properties.Name -contains 'Audit' -and $config.Audit.PSObject.Properties.Name -contains 'OutputPath') { [string]$config.Audit.OutputPath } else { 'Audit' }
    $effectiveOutputPath = Join-Path $auditBase 'adaptive'
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) { $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath }
if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }

Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Adaptive Report'
Write-Host "  Anchor: $Anchor | Theme: $Theme | Window: $(if ($CreatedAfter) { "$CreatedAfter..$CreatedBefore" } else { "$DaysBack days" })"
Write-Host "  CorrelationID: $correlationID"
Write-Host ''

# --- Pull campaigns for the date window + build audits ----------------------
$campaigns = @()
try {
    $campArgs = @{ Status = $Status; CorrelationID = $correlationID }
    if ($CreatedAfter)  { $campArgs['CreatedAfter']  = $CreatedAfter }
    if ($CreatedBefore) { $campArgs['CreatedBefore'] = $CreatedBefore }
    if (-not $CreatedAfter) { $campArgs['DaysBack'] = $DaysBack }
    $cr = Get-SPAuditCampaigns @campArgs
    if ($cr.Success -and $null -ne $cr.Data) { $campaigns = @($cr.Data) }
}
catch {
    if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
    Write-Host "ERROR: campaign query failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3
}
Write-Host "  Campaigns in window: $($campaigns.Count)"
if ($campaigns.Count -eq 0) { Write-Host '  No campaigns matched -- nothing to report.' -ForegroundColor Yellow; exit 1 }

$audits = New-Object System.Collections.Generic.List[hashtable]
foreach ($camp in $campaigns) {
    try {
        $wrapped = New-Object System.Collections.Generic.List[object]
        $certR = Get-SPAuditCertifications -CampaignId $camp.id -CorrelationID $correlationID
        foreach ($cert in @(if ($certR.Success) { $certR.Data } else { @() })) {
            $itemR = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $correlationID
            foreach ($item in @(if ($itemR.Success) { $itemR.Data } else { @() })) {
                $wrapped.Add(@{ Item = $item; CertificationId = [string]$cert.id; CertificationName = [string]$cert.name; CampaignName = [string]$camp.name })
            }
        }
        $dg = Group-SPAuditDecisions -Items $wrapped.ToArray() -CampaignMetadata @{ StartDate = [string]$camp.created; DueDate = ''; CompletionDate = '' }
        $audits.Add(@{ CampaignName = [string]$camp.name; CampaignId = [string]$camp.id; Decisions = $dg })
    }
    catch { Write-Host "  WARN: failed to process '$($camp.name)': $($_.Exception.Message)" -ForegroundColor Yellow }
}

# --- Adapt + generate -------------------------------------------------------
$ds = Build-SPRCDataset -CampaignAudits $audits.ToArray() -Anchor $Anchor -CorrelationID $correlationID
if (-not $ds.Success) { Write-Host "ERROR: adapter failed: $($ds.Error)" -ForegroundColor Red; exit 1 }
$gr = @($ds.Data.GroupResults)
Write-Host "  $Anchor groups: $($gr.Count)"
if ($gr.Count -eq 0) { Write-Host '  No groups produced from the window -- nothing to render.' -ForegroundColor Yellow; exit 1 }

$stamp = $startTime.ToString('yyyyMMdd-HHmmss')
$generated = New-Object System.Collections.Generic.List[string]

# Composable report
if (@($Components).Count -gt 0) {
    try {
        $ctx = New-RCContext -GroupResults $gr -StaleResults $ds.Data.StaleResults -Theme $Theme
        $outFile = Join-Path $effectiveOutputPath "adaptive-$Anchor-$stamp.html"
        New-ComposableReport -Components $Components -Context $ctx -Title "Adaptive $Anchor Report" -Theme $Theme -OutputPath $outFile | Out-Null
        $generated.Add($outFile)
        Write-Host "  composable report: $outFile" -ForegroundColor Green
    }
    catch { Write-Host "  WARN: composable report failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Baseline reports
$baselineMap = [ordered]@{
    'inventory'    = 'Export-GroupInventoryCatalogReport'
    'privileged'   = 'Export-PrivilegedGroupReviewReport'
    'orphaned'     = 'Export-OrphanedDisabledMembersReport'
    'exec-summary' = 'Export-GovernanceExecutiveSummaryReport'
    'roster'       = 'Export-MembershipSnapshotRosterReport'
    'access-cert'  = 'Export-AccessCertificationAttestationReport'
    'sod'          = 'Export-SodToxicComembershipReport'
}
$wanted = if ($BaselineReport -contains 'all') { @($baselineMap.Keys) } else { @($BaselineReport) }
foreach ($key in $wanted) {
    $fn = $baselineMap[$key]
    if (-not $fn) { continue }
    try {
        $outFile = Join-Path $effectiveOutputPath "$key-$stamp.html"
        & $fn -GroupResults $gr -OutputPath $outFile -Theme $Theme | Out-Null
        $generated.Add($outFile)
        Write-Host "  $key report: $outFile" -ForegroundColor Green
    }
    catch { Write-Host "  WARN: $key report failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# --- Summary ----------------------------------------------------------------
$durationStr = '{0:N1}s' -f ((Get-Date) - $startTime).TotalSeconds
if ($OutputMode -in @('Console', 'HTML', 'Both')) {
    Write-Host ''
    Write-Host "  Generated $($generated.Count) report(s) in $durationStr -> $effectiveOutputPath" -ForegroundColor Cyan
}
if ($OutputMode -in @('JSON', 'Both')) {
    [ordered]@{
        CorrelationID = $correlationID
        Anchor        = $Anchor
        Window        = if ($CreatedAfter) { "$CreatedAfter..$CreatedBefore" } else { "$DaysBack days" }
        Campaigns     = $campaigns.Count
        Groups        = $gr.Count
        Reports       = @($generated)
        OutputPath    = $effectiveOutputPath
        DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 5
}

exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
