#Requires -Version 5.1
<#
.SYNOPSIS
    Day-over-day (or intra-day / weekly / monthly) diff reporting for a recurring
    attestation campaign. Captures an immutable snapshot of the campaign now, finds the
    prior snapshot, and renders two read-only reports:

      * Completion diff -- who is doing their attestations (progress since the prior
        capture, newly completed, stalled, not started).
      * Scope diff -- what access is NEW / GONE in the campaign, decision changes, and a
        compliance summary (newly-added privileged, stalled reviewers, overdue undecided,
        privileged-approved advisory).

.DESCRIPTION
    READ-ONLY. This tool never reassigns, escalates, or completes anything in ISC -- the
    immediate ask is to inform leadership WITHOUT touching the delta-escalation chain. It
    only captures snapshots and writes HTML/CSV locally.

    The snapshot is the single source of truth (SP.CampaignDelta); "yesterday vs today",
    "before noon vs now", "this week vs last" all reduce to "which two snapshots". Run this
    on the campaign's cadence (e.g. daily) so each run has a prior capture to diff against.

    Snapshots are stored under Audit.SnapshotPath (toolkit-root anchored) and pruned by
    Audit.SnapshotRetentionDays. Long-term trend lives in the separate KPI time-series, not
    these full snapshots.

.PARAMETER ConfigPath
    Path to settings.json (defaults to ..\Config\settings.json, honoring settings.local.json).
.PARAMETER Token
    Browser/PAT bearer token (bypasses OAuth).
.PARAMETER TokenExpiryMinutes
    Minutes until a browser token is treated as expired. Default 10.
.PARAMETER CampaignId
    Resolve the campaign by exact id (skips the name search). Most precise for a recurring
    campaign whose id is stable.
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (client-side contains; ISC rejects bare 'name co').
.PARAMETER Status
    Campaign status filter for resolution. Default ACTIVE (recurring attestations are live).
.PARAMETER DaysBack
    Only consider campaigns created within the last N days when resolving by name. Default 30.
.PARAMETER NoCapture
    Do NOT capture a fresh snapshot from ISC. Compare the two most recent EXISTING snapshots
    for the campaign instead (re-render a report offline without hitting the API).
.PARAMETER CompareBefore
    ISO-8601 cutoff: pick the "previous" snapshot as the most recent one strictly before this
    time. Default = the current capture time (i.e. the immediately prior snapshot).
.PARAMETER IncludeCsv
    Also write flat completion + scope CSVs (for Excel / leadership).
.PARAMETER PruneOldSnapshots
    Run the retention sweep (Audit.SnapshotRetentionDays) after capturing.
.PARAMETER OutputPath
    Directory for the generated reports (default {Audit.OutputPath}\diff).
.PARAMETER OutputMode
    Run-summary format: Console (default), JSON, HTML, Both, or CSV. HTML diff files are
    always written regardless; CSV is written when -IncludeCsv or -OutputMode CSV/Both.
.PARAMETER Help
    Display full help and exit.
.EXAMPLE
    .\Invoke-SPCampaignDiff.ps1 -CampaignNameContains 'Daily Attestation' -IncludeCsv
.EXAMPLE
    # Re-render this morning's vs yesterday's capture without calling ISC:
    .\Invoke-SPCampaignDiff.ps1 -CampaignId 'camp-123' -NoCapture
.NOTES
    Exit codes: 0 ok | 1 no campaign/data | 2 parameter | 3 auth | 4 config.
    Read-only: CLI-005 (no SupportsShouldProcess).
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$Token,
    [Parameter()][int]$TokenExpiryMinutes = 10,

    [Parameter()][string]$CampaignId,
    [Parameter()][string]$CampaignName,
    [Parameter()][string]$CampaignNameStartsWith,
    [Parameter()][string]$CampaignNameContains,
    [Parameter()][ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')][string[]]$Status = @('ACTIVE'),
    [Parameter()][int]$DaysBack = 30,

    [Parameter()][switch]$NoCapture,
    [Parameter()][string]$CompareBefore,
    [Parameter()][switch]$IncludeCsv,
    [Parameter()][switch]$PruneOldSnapshots,

    [Parameter()][string]$OutputPath,
    [Parameter()][ValidateSet('Console', 'JSON', 'HTML', 'Both', 'CSV')][string]$OutputMode = 'Console',
    [Parameter()][Alias('?')][switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

#region Module load
$scriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot
foreach ($mod in @('SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1')) {
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

if (-not $CampaignId -and -not $CampaignName -and -not $CampaignNameStartsWith -and -not $CampaignNameContains) {
    Write-Host 'ERROR: specify -CampaignId or a -CampaignName* filter.' -ForegroundColor Red; exit 2
}

# --- Resolve output path ----------------------------------------------------
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditBase = if ($config.PSObject.Properties.Name -contains 'Audit' -and $config.Audit.PSObject.Properties.Name -contains 'OutputPath') { [string]$config.Audit.OutputPath } else { 'Audit' }
    $effectiveOutputPath = Join-Path $auditBase 'diff'
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) { $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath }
if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }

Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Campaign Diff (read-only -- no reassignment / escalation)'
Write-Host "  CorrelationID: $correlationID"
Write-Host ''

# --- Resolve the campaign ---------------------------------------------------
$campaign = $null
try {
    $campArgs = @{ Status = $Status; DaysBack = $DaysBack; CorrelationID = $correlationID }
    if ($CampaignName)           { $campArgs['CampaignName']           = $CampaignName }
    if ($CampaignNameStartsWith) { $campArgs['CampaignNameStartsWith'] = $CampaignNameStartsWith }
    if ($CampaignNameContains)   { $campArgs['CampaignNameContains']   = $CampaignNameContains }
    $cr = Get-SPAuditCampaigns @campArgs
    $campaigns = if ($cr.Success -and $null -ne $cr.Data) { @($cr.Data) } else { @() }
    if ($CampaignId) { $campaigns = @($campaigns | Where-Object { [string]$_.id -eq $CampaignId }) }
    if ($campaigns.Count -eq 0 -and $CampaignId) {
        # Direct-id fallback: a known recurring campaign may be outside the status/day window.
        $crAll = Get-SPAuditCampaigns -Status @('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED') -DaysBack 3650 -CorrelationID $correlationID
        if ($crAll.Success) { $campaigns = @(@($crAll.Data) | Where-Object { [string]$_.id -eq $CampaignId }) }
    }
}
catch {
    if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
    Write-Host "ERROR: campaign query failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3
}
if ($campaigns.Count -eq 0) { Write-Host '  No campaign matched -- nothing to diff.' -ForegroundColor Yellow; exit 1 }
if ($campaigns.Count -gt 1) {
    # A recurring attestation should resolve to one campaign; if several match, take the
    # most recently created and note the ambiguity.
    $campaign = @($campaigns | Sort-Object { try { [datetime]$_.created } catch { [datetime]::MinValue } } -Descending)[0]
    Write-Host "  WARN: $($campaigns.Count) campaigns matched; using most recent: '$($campaign.name)' ($($campaign.id))" -ForegroundColor Yellow
}
else { $campaign = $campaigns[0] }
Write-Host "  Campaign: $($campaign.name) [$($campaign.id)] status=$($campaign.status)"

$snapshotDir = $null  # use config default (toolkit-root anchored)
$currentSnapshot = $null

# --- Capture a fresh snapshot (unless -NoCapture) ---------------------------
if (-not $NoCapture) {
    try {
        $certResult = Get-SPAuditCertifications -CampaignId ([string]$campaign.id) -CorrelationID $correlationID
        $certs = if ($certResult.Success -and $null -ne $certResult.Data) { @($certResult.Data) } else { @() }
        # Project to the shape Build-SPCampaignSnapshotData expects, using the EFFECTIVE
        # (reassignment-aware) reviewer so completion tracks who must actually attest.
        $certObjs = foreach ($c in $certs) {
            $rev = if ($null -ne $c.PSObject.Properties['EffectiveReviewer'] -and $null -ne $c.EffectiveReviewer) { $c.EffectiveReviewer } elseif ($null -ne $c.PSObject.Properties['reviewer']) { $c.reviewer } else { $null }
            [PSCustomObject]@{
                id             = [string]$c.id
                reviewer       = $rev
                decisionsTotal = if ($null -ne $c.PSObject.Properties['decisionsTotal']) { $c.decisionsTotal } else { 0 }
                decisionsMade  = if ($null -ne $c.PSObject.Properties['decisionsMade'])  { $c.decisionsMade }  else { 0 }
                signed         = if ($null -ne $c.PSObject.Properties['signed'])         { $c.signed }         else { $false }
                phase          = if ($null -ne $c.PSObject.Properties['phase'])          { $c.phase }          else { '' }
            }
        }

        $wrapped = New-Object System.Collections.Generic.List[object]
        $cacheResult = Get-SPCachedCampaignItems -Campaign $campaign -CorrelationID $correlationID
        foreach ($wi in @(if ($cacheResult.Success) { $cacheResult.Data } else { @() })) { $wrapped.Add($wi) }
        $decisions = Group-SPAuditDecisions -Items $wrapped.ToArray() -CampaignMetadata @{ StartDate = [string]$campaign.created; DueDate = ''; CompletionDate = '' }

        # Evidence provenance: operator/tenant/version/environment stamped into the snapshot.
        $prov = @{ CapturedBy = [string]$env:USERNAME }
        try {
            if ($config.PSObject.Properties.Name -contains 'Global' -and $config.Global.PSObject.Properties.Name -contains 'ToolkitVersion') { $prov['ToolkitVersion'] = [string]$config.Global.ToolkitVersion }
            if ($config.PSObject.Properties.Name -contains 'Global' -and $config.Global.PSObject.Properties.Name -contains 'EnvironmentName') { $prov['Environment'] = [string]$config.Global.EnvironmentName }
            if ($config.PSObject.Properties.Name -contains 'Api' -and $config.Api.PSObject.Properties.Name -contains 'BaseUrl') { $prov['TenantUrl'] = [string]$config.Api.BaseUrl }
        } catch { }

        $currentSnapshot = Build-SPCampaignSnapshotData -Campaign $campaign -Certifications @($certObjs) -Decisions $decisions -Provenance $prov
        $saveResult = Save-SPCampaignSnapshot -Snapshot $currentSnapshot -SnapshotDir $snapshotDir
        if ($saveResult.Success) { Write-Host "  Snapshot captured: $($saveResult.Data)" -ForegroundColor Green }
        else { Write-Host "  WARN: snapshot save failed: $($saveResult.Error)" -ForegroundColor Yellow }
    }
    catch {
        if ($_.Exception.Message -match 'token|auth|401|403') { Write-Host "ERROR: authentication failed: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
        Write-Host "ERROR: snapshot capture failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1
    }
}

# --- Determine current + previous snapshots ---------------------------------
$cutoff = if ($CompareBefore) { try { [datetime]::Parse($CompareBefore) } catch { Get-Date } } else { $null }

if ($null -eq $currentSnapshot) {
    # -NoCapture: take the most recent existing snapshot as "current".
    $listR = Get-SPCampaignSnapshotList -CampaignId ([string]$campaign.id) -SnapshotDir $snapshotDir
    $existing = if ($listR.Success) { @($listR.Data) } else { @() }
    if ($existing.Count -eq 0) { Write-Host '  No existing snapshots to compare -- run once without -NoCapture first.' -ForegroundColor Yellow; exit 1 }
    $curRef = $existing[0]
    $loadCur = Get-SPCampaignSnapshot -Path $curRef.Path
    if (-not $loadCur.Success) { Write-Host "  ERROR: could not load current snapshot: $($loadCur.Error)" -ForegroundColor Red; exit 1 }
    $currentSnapshot = $loadCur.Data
    if (-not $cutoff) { $cutoff = $curRef.CapturedAt }
}
else {
    if (-not $cutoff) {
        try { $cutoff = [datetime]::Parse([string]$currentSnapshot.Meta.CapturedAt) } catch { $cutoff = Get-Date }
    }
}

$prevRef = Get-SPCampaignPreviousSnapshot -CampaignId ([string]$campaign.id) -SnapshotDir $snapshotDir -Before $cutoff
$previousSnapshot = $null
if ($prevRef.Success -and $null -ne $prevRef.Data) {
    $loadPrev = Get-SPCampaignSnapshot -Path $prevRef.Data.Path
    if ($loadPrev.Success) { $previousSnapshot = $loadPrev.Data; Write-Host "  Previous snapshot: $($prevRef.Data.Path)" }
}
if ($null -eq $previousSnapshot) { Write-Host '  No prior snapshot -- reporting baseline (first capture).' -ForegroundColor Yellow }

# --- Compare + report -------------------------------------------------------
$cmp = Compare-SPCampaignSnapshots -Current $currentSnapshot -Previous $previousSnapshot
if (-not $cmp.Success) { Write-Host "ERROR: comparison failed: $($cmp.Error)" -ForegroundColor Red; exit 1 }
$diff = $cmp.Data

# Zero-item / mass-removal guard: a capture that returns no items (API hiccup / partial auth)
# would otherwise report the entire campaign as "removed from scope". Warn loudly.
$curItemCount = [int](if ($null -ne $currentSnapshot.Meta) { $currentSnapshot.Meta.ItemCount } else { 0 })
if ($curItemCount -eq 0 -and $diff.Meta.HasPrevious) {
    Write-Host "  WARNING: current capture has 0 items but a prior capture existed -- possible API/auth issue. Scope 'removed' counts may be spurious; not treating as real removals." -ForegroundColor Yellow
}
elseif ($diff.Meta.HasPrevious -and $diff.Scope.RemovedCount -gt 0 -and $curItemCount -gt 0) {
    $prevItemCount = $curItemCount + $diff.Scope.RemovedCount - $diff.Scope.AddedCount
    if ($prevItemCount -gt 0 -and ($diff.Scope.RemovedCount / [double]$prevItemCount) -gt 0.5) {
        Write-Host "  WARNING: >50% of prior scope is reported removed ($($diff.Scope.RemovedCount) items) -- verify this is a real scope reduction and not a data-quality issue." -ForegroundColor Yellow
    }
}

$generated = New-Object System.Collections.Generic.List[string]
$completion = Export-SPCampaignCompletionDiffHtml -Diff $diff -OutputPath $effectiveOutputPath
if ($completion.Success) { $generated.Add([string]$completion.Data); Write-Host "  completion diff: $($completion.Data)" -ForegroundColor Green }
else { Write-Host "  WARN: completion report failed: $($completion.Error)" -ForegroundColor Yellow }

$scope = Export-SPCampaignScopeDiffHtml -Diff $diff -OutputPath $effectiveOutputPath
if ($scope.Success) { $generated.Add([string]$scope.Data); Write-Host "  scope diff: $($scope.Data)" -ForegroundColor Green }
else { Write-Host "  WARN: scope report failed: $($scope.Error)" -ForegroundColor Yellow }

$csvInfo = $null
if ($IncludeCsv -or $OutputMode -in @('CSV', 'Both')) {
    $csvR = Export-SPCampaignDiffCsv -Diff $diff -OutputDir $effectiveOutputPath
    if ($csvR.Success) {
        $csvInfo = $csvR.Data
        $generated.Add([string]$csvR.Data.CompletionCsv); $generated.Add([string]$csvR.Data.ScopeCsv)
        Write-Host "  CSVs: $($csvR.Data.CompletionCsv); $($csvR.Data.ScopeCsv)" -ForegroundColor Green
    }
    else { Write-Host "  WARN: CSV export failed: $($csvR.Error)" -ForegroundColor Yellow }
}

if ($PruneOldSnapshots) {
    $pr = Remove-SPCampaignOldSnapshots -SnapshotDir $snapshotDir
    if ($pr.Success) { Write-Host "  Retention sweep: removed $($pr.Data.Removed) old snapshot(s)." }
}

# --- Summary ----------------------------------------------------------------
$durationStr = '{0:N1}s' -f ((Get-Date) - $startTime).TotalSeconds
if ($OutputMode -in @('Console', 'HTML', 'Both', 'CSV')) {
    Write-Host ''
    Write-Host "  Completion: $($diff.Completion.NewlyCompletedCount) newly done, $($diff.Completion.OutstandingCount) outstanding, $($diff.Completion.NotStartedCount) not started, $($diff.Completion.StalledCount) stalled" -ForegroundColor Cyan
    Write-Host "  Scope: +$($diff.Scope.AddedCount) added ($($diff.Scope.AddedPrivilegedCount) privileged), -$($diff.Scope.RemovedCount) removed, $($diff.Scope.ChangedCount) changed" -ForegroundColor Cyan
    Write-Host "  Compliance: $(@($diff.Compliance.NewlyAddedPrivileged).Count) new-priv, $(@($diff.Compliance.StalledReviewers).Count) stalled, $(@($diff.Compliance.Overdue).Count) overdue(past-due), $(@($diff.Compliance.PersistentlyPending).Count) persistently-pending, $(@($diff.Compliance.PrivilegedApproved).Count) priv-approved (advisory)" -ForegroundColor Cyan
    Write-Host "  Generated $($generated.Count) file(s) in $durationStr -> $effectiveOutputPath" -ForegroundColor Cyan
}
if ($OutputMode -in @('JSON', 'Both')) {
    [ordered]@{
        CorrelationID = $correlationID
        Campaign      = [ordered]@{ Id = [string]$campaign.id; Name = [string]$campaign.name; Status = [string]$campaign.status }
        HasPrevious   = $diff.Meta.HasPrevious
        IntervalHours = $diff.Meta.IntervalHours
        Completion    = [ordered]@{ NewlyCompleted = $diff.Completion.NewlyCompletedCount; Outstanding = $diff.Completion.OutstandingCount; NotStarted = $diff.Completion.NotStartedCount; Stalled = $diff.Completion.StalledCount; CompletionPct = $diff.Completion.CurrCompletionPct }
        Scope         = [ordered]@{ Added = $diff.Scope.AddedCount; AddedPrivileged = $diff.Scope.AddedPrivilegedCount; Removed = $diff.Scope.RemovedCount; Changed = $diff.Scope.ChangedCount }
        Compliance    = [ordered]@{ NewlyAddedPrivileged = @($diff.Compliance.NewlyAddedPrivileged).Count; StalledReviewers = @($diff.Compliance.StalledReviewers).Count; Overdue = @($diff.Compliance.Overdue).Count; PersistentlyPending = @($diff.Compliance.PersistentlyPending).Count; PrivilegedApproved = @($diff.Compliance.PrivilegedApproved).Count }
        Reports       = @($generated)
        OutputPath    = $effectiveOutputPath
        DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 6
}

exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
