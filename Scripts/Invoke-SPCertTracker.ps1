#Requires -Version 5.1
<#
.SYNOPSIS
    Executive CERTIFICATION PROGRESS TRACKER -- a Domino's-style pipeline board showing
    where every active attestation campaign stands: stage, completion (two ways), decision
    velocity, projected close vs deadline, momentum, and where things are stalling.

.DESCRIPTION
    READ-ONLY. Campaigns are almost always active/incomplete, so this is pace-centric: it
    answers "is each campaign moving toward its deadline?" with signal from hour 8 to day 30,
    not just "did it hit 100%." For each active campaign it captures (or loads) a snapshot +
    the prior snapshot (for movement), then renders one executive board. Never reassigns,
    escalates, or mutates ISC.

.PARAMETER ConfigPath
    Path to settings.json (defaults to ..\Config\settings.json).
.PARAMETER Token
    Browser/PAT bearer token (bypasses OAuth).
.PARAMETER TokenExpiryMinutes
    Minutes until a browser token is treated as expired. Default 10.
.PARAMETER CampaignName / -CampaignNameStartsWith / -CampaignNameContains
    Optional name filters; default = all campaigns in the status/day window.
.PARAMETER Status
    Campaign statuses to track. Default ACTIVE, COMPLETING.
.PARAMETER DaysBack
    Resolution window (default 60).
.PARAMETER MaxCampaigns
    Safety cap on how many campaigns to capture in one run (default Safety.MaxCampaignsPerRun or 25).
.PARAMETER NoCapture
    Don't call ISC -- build the board from the most recent EXISTING snapshots per campaign.
.PARAMETER Cadence
    Which prior snapshot to measure movement against: Adjacent (default), IntraDay, Daily,
    Weekly, Monthly.
.PARAMETER OutputPath
    Directory for the HTML (default {Audit.OutputPath}\tracker).
.PARAMETER OutputMode
    Console (default) / JSON / HTML / Both. The HTML board is always written.
.PARAMETER Help
    Display full help and exit.
.EXAMPLE
    .\Invoke-SPCertTracker.ps1
.EXAMPLE
    .\Invoke-SPCertTracker.ps1 -CampaignNameContains 'Attestation' -Cadence Daily
.NOTES
    Exit codes: 0 ok | 1 no campaigns/data | 2 parameter | 3 auth | 4 config. Read-only (CLI-005).
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,
    [Parameter()][string]$CampaignName,
    [Parameter()][string]$CampaignNameStartsWith,
    [Parameter()][string]$CampaignNameContains,
    [Parameter()][ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')][string[]]$Status = @('ACTIVE', 'COMPLETING'),
    [Parameter()][int]$DaysBack = 60,
    [Parameter()][int]$MaxCampaigns = 0,
    [Parameter()][switch]$NoCapture,
    [Parameter()][ValidateSet('Adjacent', 'IntraDay', 'Daily', 'Weekly', 'Monthly')][string]$Cadence = 'Adjacent',
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

$correlationID = [guid]::NewGuid().ToString()
$startTime = Get-Date
try {
    if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }
    $config = Get-SPConfig -ConfigPath $ConfigPath
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { Write-Host "ERROR: configuration load failed: $($_.Exception.Message)" -ForegroundColor Red; exit 4 }

if (-not [string]::IsNullOrWhiteSpace($Token)) { $null = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -ErrorAction SilentlyContinue }

if ($MaxCampaigns -le 0) {
    $MaxCampaigns = 25
    try { if ($config.PSObject.Properties.Name -contains 'Safety' -and $config.Safety.PSObject.Properties.Name -contains 'MaxCampaignsPerRun') { $MaxCampaigns = [int]$config.Safety.MaxCampaignsPerRun } } catch { }
}

# Cadence -> previous-snapshot selection args
$cadExtra = @{}
switch ($Cadence) {
    'IntraDay' { $cadExtra['IntraDay'] = $true }
    'Daily'    { $cadExtra['TargetAgoHours'] = 24 }
    'Weekly'   { $cadExtra['TargetAgoHours'] = 168 }
    'Monthly'  { $cadExtra['TargetAgoHours'] = 730 }
    default    { }
}

# Provenance for any snapshot we capture
$prov = @{ CapturedBy = [string]$env:USERNAME }
try {
    if ($config.PSObject.Properties.Name -contains 'Global' -and $config.Global.PSObject.Properties.Name -contains 'ToolkitVersion') { $prov['ToolkitVersion'] = [string]$config.Global.ToolkitVersion }
    if ($config.PSObject.Properties.Name -contains 'Global' -and $config.Global.PSObject.Properties.Name -contains 'EnvironmentName') { $prov['Environment'] = [string]$config.Global.EnvironmentName }
    if ($config.PSObject.Properties.Name -contains 'Api' -and $config.Api.PSObject.Properties.Name -contains 'BaseUrl') { $prov['TenantUrl'] = [string]$config.Api.BaseUrl }
} catch { }

# Output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditBase = if ($config.PSObject.Properties.Name -contains 'Audit' -and $config.Audit.PSObject.Properties.Name -contains 'OutputPath') { [string]$config.Audit.OutputPath } else { 'Audit' }
    $effectiveOutputPath = Join-Path $auditBase 'tracker'
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) { $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath }
if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }

Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host "  Certification Progress Tracker (read-only) | cadence: $Cadence"
Write-Host ''

# Resolve campaigns
$campaigns = @()
try {
    $campArgs = @{ Status = $Status; DaysBack = $DaysBack; CorrelationID = $correlationID }
    if ($CampaignName)           { $campArgs['CampaignName']           = $CampaignName }
    if ($CampaignNameStartsWith) { $campArgs['CampaignNameStartsWith'] = $CampaignNameStartsWith }
    if ($CampaignNameContains)   { $campArgs['CampaignNameContains']   = $CampaignNameContains }
    $cr = Get-SPAuditCampaigns @campArgs
    if ($cr.Success -and $null -ne $cr.Data) { $campaigns = @($cr.Data) }
}
catch {
    if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
    Write-Host "ERROR: campaign query failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3
}
if ($campaigns.Count -eq 0) { Write-Host '  No campaigns matched -- nothing to track.' -ForegroundColor Yellow; exit 1 }
if ($campaigns.Count -gt $MaxCampaigns) { Write-Host "  NOTE: $($campaigns.Count) campaigns matched; capping at $MaxCampaigns (raise -MaxCampaigns to include more)." -ForegroundColor Yellow; $campaigns = @($campaigns | Select-Object -First $MaxCampaigns) }
Write-Host "  Campaigns: $($campaigns.Count)"

# Per-campaign: capture (or load) current snapshot + previous
$entries = New-Object System.Collections.Generic.List[object]
foreach ($camp in $campaigns) {
    try {
        $current = $null; $cutoff = $null
        if (-not $NoCapture) {
            $certResult = Get-SPAuditCertifications -CampaignId ([string]$camp.id) -CorrelationID $correlationID
            $certs = if ($certResult.Success -and $null -ne $certResult.Data) { @($certResult.Data) } else { @() }
            $certObjs = foreach ($c in $certs) {
                $rev = if ($null -ne $c.PSObject.Properties['EffectiveReviewer'] -and $null -ne $c.EffectiveReviewer) { $c.EffectiveReviewer } elseif ($null -ne $c.PSObject.Properties['reviewer']) { $c.reviewer } else { $null }
                [PSCustomObject]@{ id = [string]$c.id; reviewer = $rev
                    decisionsTotal = if ($null -ne $c.PSObject.Properties['decisionsTotal']) { $c.decisionsTotal } else { 0 }
                    decisionsMade  = if ($null -ne $c.PSObject.Properties['decisionsMade'])  { $c.decisionsMade }  else { 0 }
                    signed         = if ($null -ne $c.PSObject.Properties['signed'])         { $c.signed }         else { $false }
                    phase          = if ($null -ne $c.PSObject.Properties['phase'])          { $c.phase }          else { '' } }
            }
            $wrapped = New-Object System.Collections.Generic.List[object]
            $cacheResult = Get-SPCachedCampaignItems -Campaign $camp -CorrelationID $correlationID
            foreach ($wi in @(if ($cacheResult.Success) { $cacheResult.Data } else { @() })) { $wrapped.Add($wi) }
            $decisions = Group-SPAuditDecisions -Items $wrapped.ToArray() -CampaignMetadata @{ StartDate = [string]$camp.created; DueDate = [string]$camp.deadline; CompletionDate = '' }
            $current = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @($certObjs) -Decisions $decisions -Provenance $prov
            Save-SPCampaignSnapshot -Snapshot $current | Out-Null
            try { $cutoff = [datetime]::Parse([string]$current.Meta.CapturedAt) } catch { $cutoff = Get-Date }
        }
        else {
            $listR = Get-SPCampaignSnapshotList -CampaignId ([string]$camp.id)
            $existing = if ($listR.Success) { @($listR.Data) } else { @() }
            if ($existing.Count -eq 0) { Write-Host "    skip (no snapshot): $($camp.name)" -ForegroundColor DarkGray; continue }
            $loadCur = Get-SPCampaignSnapshot -Path $existing[0].Path
            if (-not $loadCur.Success) { continue }
            $current = $loadCur.Data
            $cutoff = $existing[0].CapturedAt
        }

        $prevArgs = @{ CampaignId = [string]$camp.id; Before = $cutoff } + $cadExtra
        $prevRef = Get-SPCampaignPreviousSnapshot @prevArgs
        $previous = $null
        if ($prevRef.Success -and $null -ne $prevRef.Data) { $lp = Get-SPCampaignSnapshot -Path $prevRef.Data.Path; if ($lp.Success) { $previous = $lp.Data } }

        $entries.Add(@{ Current = $current; Previous = $previous })
        Write-Host "    captured: $($camp.name)" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
        Write-Host "    WARN: $($camp.name): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($entries.Count -eq 0) { Write-Host '  No campaign snapshots to render.' -ForegroundColor Yellow; exit 1 }

$tk = Build-SPCertTrackerData -Campaigns $entries.ToArray()
if (-not $tk.Success) { Write-Host "ERROR: tracker build failed: $($tk.Error)" -ForegroundColor Red; exit 1 }
$ex = Export-SPCertTrackerHtml -TrackerData $tk.Data -OutputPath $effectiveOutputPath
$generated = @()
if ($ex.Success) { $generated += $ex.Data; Write-Host "  tracker board: $($ex.Data)" -ForegroundColor Green }
else { Write-Host "  WARN: tracker export failed: $($ex.Error)" -ForegroundColor Yellow }

$durationStr = '{0:N1}s' -f ((Get-Date) - $startTime).TotalSeconds
if ($OutputMode -in @('Console', 'HTML', 'Both')) {
    Write-Host ''
    $p = $tk.Data.Program
    Write-Host "  Program: $($p.ActiveCampaigns) active, $($p.AtRiskCampaigns) at-risk, $($p.OverdueCampaigns) overdue" -ForegroundColor Cyan
    foreach ($st in @('Launched','In Review','Decisions Done','Signed Off','Remediation','Closed')) { $c = if ($p.ByStage.Contains($st)) { $p.ByStage[$st] } else { 0 }; if ($c -gt 0) { Write-Host "    $st`: $c" } }
    Write-Host "  Generated $($generated.Count) report(s) in $durationStr -> $effectiveOutputPath" -ForegroundColor Cyan
}
if ($OutputMode -in @('JSON', 'Both')) {
    [ordered]@{
        CorrelationID = $correlationID
        Program       = $tk.Data.Program
        Campaigns     = @($tk.Data.Campaigns | ForEach-Object { [ordered]@{ Name = $_.CampaignName; Stage = $_.Stage; Rag = $_.Rag; CompletionByReviewer = $_.CompletionByReviewer; ProjectedVsDeadline = $_.ProjectedVsDeadline; Momentum = $_.Momentum } })
        Reports       = @($generated)
        OutputPath    = $effectiveOutputPath
        DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 6
}

exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
