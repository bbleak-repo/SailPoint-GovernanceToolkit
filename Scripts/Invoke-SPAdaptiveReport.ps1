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

    # --- Leadership distribution (additive; off by default) ---
    [Parameter()][switch]$DistributeToLeadership,
    [Parameter()][string[]]$TargetBands,
    [Parameter()][int]$LeadershipDepth = 4,
    [Parameter()][string]$OrgSupplementPath,
    [Parameter()][switch]$PreviewOnly,
    [Parameter()][switch]$SendReports,
    [Parameter()][ValidateSet('Summary', 'Detailed', 'Verbose')][string]$DetailLevel = 'Verbose',

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
    'SP.DeltaCert\SP.DeltaCert.psd1',  # org-tree / band / preview functions (leadership mode)
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
        # Cached items: fetched from ISC once per campaign, then served from disk/memory on
        # later runs. The cache enumerates the campaign's certs itself and returns items
        # pre-wrapped as @{Item;CertificationId;CertificationName;CampaignName}.
        $cacheResult = Get-SPCachedCampaignItems -Campaign $camp -CorrelationID $correlationID
        foreach ($wi in @(if ($cacheResult.Success) { $cacheResult.Data } else { @() })) {
            $wrapped.Add($wi)
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

# --- Optional: tiered leadership distribution (additive; WhatIf/simulate by default) ---
# Reuses the EXISTING distribution machinery -- no rebuild, no edits to
# Invoke-SPReportDistribution. Default = generate + SIMULATE (resolve recipients,
# print "WOULD send", send NOTHING). -PreviewOnly = plan only. -SendReports calls
# Send-SPReport, which itself only emails when Audit.Smtp.Enabled=$true (else logs).
$distSummary = $null
if ($DistributeToLeadership) {
    Write-Host ''
    Write-Host '  Leadership distribution' -ForegroundColor Cyan
    if (-not (Get-Command Build-SPOrgTree -ErrorAction SilentlyContinue)) {
        Write-Host '    WARN: SP.DeltaCert leadership functions unavailable -- skipping.' -ForegroundColor Yellow
    }
    else {
        # Reviewed identity IDs from the decision items
        $idSet = @{}
        foreach ($a in $audits) {
            foreach ($cat in 'Approved', 'Revoked', 'Pending') {
                foreach ($it in @($a.Decisions.$cat)) {
                    if ($null -eq $it) { continue }
                    $iid = if ($it -is [System.Collections.IDictionary]) { [string]$it['IdentityId'] } else { [string]$it.IdentityId }
                    if (-not [string]::IsNullOrWhiteSpace($iid)) { $idSet[$iid] = $true }
                }
            }
        }
        $identityIds = @($idSet.Keys)
        Write-Host "    Reviewed identities: $($identityIds.Count)"

        $orgTreeResult = if ($identityIds.Count -gt 0) { Build-SPOrgTree -IdentityIds $identityIds -MaxDepth $LeadershipDepth -CorrelationID $correlationID } else { @{ Success = $false; Error = 'no identities' } }
        if (-not $orgTreeResult.Success) { Write-Host "    WARN: org tree unavailable ($($orgTreeResult.Error)) -- skipping distribution." -ForegroundColor Yellow }
        else {
            $orgTree = $orgTreeResult.Data
            Write-Host "    Org tree: $($orgTree.LeafCount) leaves, $(@($orgTree.Managers).Count) mgr, $(@($orgTree.Directors).Count) dir, $(@($orgTree.TopLeaders).Count) top"

            if ($OrgSupplementPath -and (Test-Path $OrgSupplementPath)) {
                $sup = Import-SPOrgChartSupplement -FilePath $OrgSupplementPath -CorrelationID $correlationID
                if ($sup.Success) {
                    $emailMap = @{}
                    foreach ($nid in $orgTree.Nodes.Keys) { $n = $orgTree.Nodes[$nid]; if ($null -ne $n.Identity -and -not [string]::IsNullOrWhiteSpace([string]$n.Identity.Email)) { $emailMap[$nid] = $n.Identity.Email } }
                    $orgTree = Merge-SPOrgTreeWithSupplement -OrgTree $orgTree -Supplement $sup.Data.Entries -IdentityEmailMap $emailMap -CorrelationID $correlationID
                }
            }

            $bandR = Resolve-SPIdentityBand -OrgTree $orgTree
            $bandData = if ($bandR.Success) { $bandR.Data } else { @{ Bands = @{}; Sources = @{}; Summary = @{ A = 0; B = 0; C = 0; D = 0; E = 0 } } }
            Write-Host "    Bands: A=$($bandData.Summary.A) B=$($bandData.Summary.B) C=$($bandData.Summary.C) D=$($bandData.Summary.D) E=$($bandData.Summary.E)"

            $merged = @{ Approved = @(); Revoked = @(); Pending = @() }
            foreach ($a in $audits) { foreach ($cat in 'Approved', 'Revoked', 'Pending') { $merged[$cat] = @($merged[$cat]) + @($a.Decisions.$cat) } }
            $leadershipData = Group-SPAuditByLeadership -Decisions $merged -OrgTree $orgTree

            $dateRange = if ($CreatedAfter) { "$CreatedAfter to $CreatedBefore" } else { "last $DaysBack days" }
            $campaignLabel = "Adaptive ($Anchor) -- $($campaigns.Count) campaign(s)"

            if ($PreviewOnly) {
                Write-Host ''
                Show-SPReportDistributionPreview -OrgTree $orgTree -LeadershipData $leadershipData -IncludeEmail | ForEach-Object { Write-Host "    $_" }
                Write-Host ''
                Write-Host '  (Preview only -- no reports generated or sent.)' -ForegroundColor Yellow
                exit 0
            }

            $leadershipOut = Join-Path $effectiveOutputPath 'leadership'
            if (-not (Test-Path $leadershipOut)) { New-Item -ItemType Directory -Path $leadershipOut -Force | Out-Null }

            # Upper-leadership main report (director/VP chains broken down)
            try {
                $execFile = Export-SPLeadershipExecutiveHtml -LeadershipData $leadershipData -CampaignName $campaignLabel -DateRange $dateRange -OutputPath $leadershipOut -CorrelationID $correlationID
                if ($execFile) { $generated.Add([string]$execFile); Write-Host "    upper-leadership rollup: $execFile" -ForegroundColor Green }
            }
            catch { Write-Host "    WARN: exec rollup failed: $($_.Exception.Message)" -ForegroundColor Yellow }

            # Per-band leader reports
            $bandP = @{ LeadershipData = $leadershipData; Decisions = $merged; OrgTree = $orgTree; BandData = $bandData; CampaignName = $campaignLabel; DateRange = $dateRange; OutputPath = $leadershipOut; CorrelationID = $correlationID; DetailLevel = $DetailLevel }
            if ($TargetBands -and $TargetBands.Count -gt 0) { $bandP['TargetBands'] = $TargetBands }
            $bandRep = Export-SPLeadershipBandHtml @bandP
            $bandFiles = if ($bandRep.Success) { @($bandRep.Data.Files) } else { @() }
            foreach ($bf in $bandFiles) { $generated.Add([string]$bf) }
            Write-Host "    per-band reports: $($bandFiles.Count) (bands: $(@($bandRep.Data.BandsIncluded) -join ', '))" -ForegroundColor Green

            # Resolve leader recipients
            $leaderIds = New-Object System.Collections.Generic.List[string]
            foreach ($lvl in $leadershipData.Levels.Keys) { foreach ($lid in $leadershipData.Levels[$lvl].Leaders.Keys) { if ($lid -ne '__unmanaged__' -and -not $leaderIds.Contains($lid)) { $leaderIds.Add($lid) } } }
            $emailMap = @{}; $nameMap = @{}
            if ($leaderIds.Count -gt 0) {
                $acct = Resolve-SPAuditIdentityAccounts -IdentityIds $leaderIds.ToArray() -CorrelationID $correlationID
                if ($acct.Success -and $null -ne $acct.Data) { foreach ($lid in $acct.Data.Keys) { $e = $acct.Data[$lid].Email; if (-not [string]::IsNullOrWhiteSpace([string]$e)) { $emailMap[$lid] = [string]$e } } }
            }
            foreach ($lid in $leaderIds) { if ($orgTree.Nodes.ContainsKey($lid)) { $nm = $orgTree.Nodes[$lid].Identity.Name; if (-not [string]::IsNullOrWhiteSpace([string]$nm)) { $nameMap[$lid] = $nm } } }

            # Distribution: simulate (WhatIf) by default; -SendReports -> Send-SPReport
            Write-Host ''
            Write-Host "  Distribution $(if ($SendReports) { '(send)' } else { '(simulate / WhatIf -- no email sent)' }):" -ForegroundColor Cyan
            $sent = 0; $simulated = 0; $skipped = 0
            foreach ($rf in $bandFiles) {
                $fn = Split-Path $rf -Leaf
                $mLid = $null
                $fnCompact = ($fn -replace '[^A-Za-z0-9]', '')
                foreach ($lid in $nameMap.Keys) {
                    $safe = (($nameMap[$lid] -replace '[\\/:*?"<>|]', '_').TrimEnd('.') -replace '\s+', '_')
                    $compact = ($nameMap[$lid] -replace '[^A-Za-z0-9]', '')
                    if (($fn -match [regex]::Escape($safe)) -or ($compact.Length -ge 3 -and $fnCompact -match [regex]::Escape($compact))) { $mLid = $lid; break }
                }
                $rEmail = if ($mLid -and $emailMap.ContainsKey($mLid)) { $emailMap[$mLid] } else { '' }
                $rName  = if ($mLid -and $nameMap.ContainsKey($mLid)) { $nameMap[$mLid] } else { $fn }
                $band   = if ($mLid -and $bandData.Bands.ContainsKey($mLid)) { $bandData.Bands[$mLid] } else { '?' }
                if ([string]::IsNullOrWhiteSpace($rEmail)) { Write-Host "    skip (no email): $fn ($rName)" -ForegroundColor Yellow; $skipped++; continue }
                if ($SendReports) {
                    $sr = Send-SPReport -ReportPath $rf -RecipientEmail $rEmail -RecipientName $rName -CorrelationID $correlationID
                    $act = if ($sr.Success) { $sr.Data.Action } else { 'Failed' }
                    Write-Host "    [$band] $act -> $rEmail ($rName)" -ForegroundColor $(if ($act -eq 'Sent') { 'Green' } elseif ($act -eq 'Logged') { 'DarkGray' } else { 'Red' })
                    if ($act -eq 'Sent') { $sent++ } else { $simulated++ }
                }
                else {
                    Write-Host "    [$band] WOULD send -> $rEmail ($rName) : $fn" -ForegroundColor DarkGray
                    $simulated++
                }
            }
            Write-Host "    => $(if ($SendReports) { "$sent sent, $simulated logged" } else { "$simulated simulated (no email sent)" }), $skipped skipped" -ForegroundColor Cyan
            $distSummary = [ordered]@{ Leaders = $leaderIds.Count; Sent = $sent; Simulated = $simulated; Skipped = $skipped; Bands = @($bandRep.Data.BandsIncluded) }
        }
    }
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
        Distribution  = $distSummary
        DurationSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    } | ConvertTo-Json -Depth 5
}

exit $(if ($generated.Count -gt 0) { 0 } else { 1 })
