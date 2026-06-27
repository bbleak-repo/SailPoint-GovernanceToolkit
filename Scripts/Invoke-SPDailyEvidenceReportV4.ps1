#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily certification evidence report (v4) -- a focused accountability and
    delta-aware evidence artifact (output: daily-evidence-v4-*.html).
.DESCRIPTION
    V4 is a focused evidence report showing only pending reviewer accountability, revoked
    decisions, and newly approved access from the scope-diff engine. It strips the completed
    reviewer section and the approved/pending decision subsections to produce a compact
    action-oriented artifact:

      Header                       report-generated date, period, aggregate decisions made
      Certification Scope          distinct users reviewed, entitlements tracked,
                                   privileged-access users, reviewers involved, sources evaluated
      Executive Summary (per campaign)
                                   status badge, reviewers signed-off, items decided, a
                                   decision-distribution donut, "Revoked Access -- Removal Status"
                                   (Deprovisioned on connected AD vs Queued elsewhere vs Pending)
                                   (de-provisioning), and Key Indicators
      A. Campaign Completion Evidence   cross-campaign table incl. Approved / Revoked / Pending
      B. Pending Reviewer Accountability  only reviewers who have NOT signed off (+ Reassigned)
      Decision Summary             Revoked register (open) + Newly Approved Access from scope-diff

    V4 integrates the scope-diff engine (same as V3) to capture today's campaign snapshot and
    diff it against the prior campaign, extracting newly added items with APPROVE decisions.
    Use -NoCapture to re-render from existing snapshots without capturing a new one.

    This is a CLONE of Invoke-SPDailyEvidenceReportV2.ps1; V2 remains available unchanged.
    Use V1 for the standalone KPI dashboard, V2 for full evidence detail, V3 for day-over-day
    delta tracking. All four are complementary and produce separate output files.

    Designed for daily scheduled execution after the daily orchestrator. Consolidates
    data from multiple toolkit analytics functions into the format required by
    Step 6: Evidence and Reporting of the IAM governance program.
.PARAMETER DaysBack
    Campaign lookback window in days. Default: 1.
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name filter.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (ISC 'co' filter).
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication.
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER SourceId
    Source IDs to scope analytics. If omitted, uses configured sources.
.PARAMETER SlaHours
    Hours before a revocation is considered overdue. Default 48.
.PARAMETER HighRiskThreshold
    Risk score threshold for high-risk classification. Default 70.
.PARAMETER OutputMode
    Console: formatted summary to terminal.
    HTML: self-contained HTML report file.
    JSON: machine-parseable result object.
    Both (default): console output and HTML file.
.PARAMETER OutputPath
    Directory for output files. Defaults to daily-evidence subdirectory.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be executed without making API calls.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReport.ps1 -Token $token
    # Daily evidence report with default 1-day window.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReport.ps1 -DaysBack 7 -OutputMode Both -Token $token
    # Weekly evidence report with console + HTML output.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReport.ps1 -WhatIf
    # Dry run -- shows what steps would execute.
.PARAMETER NoCapture
    Re-render from existing snapshots without capturing a new one (offline mode).
.PARAMETER NoCache
    Bypass the items cache and fetch fresh data from ISC for all campaigns in scope.
    Does NOT clear existing cache files -- other scripts and future runs still benefit
    from the cache. Use this when you need real-time item counts (e.g., reviewers have
    been signing off and you want the latest decided items).
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV4.ps1
    Version: 1.0.0
    Exit codes:
        0 = All KPIs Green, confidence A or B
        1 = Any KPI Yellow or confidence C
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Any KPI Red, confidence D/F, or critical failure
.LINK
    Invoke-SPDailyEvidenceReportV3.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [int]$DaysBack = 1,

    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    [Parameter()]
    [int]$SlaHours = 48,

    [Parameter()]
    [int]$HighRiskThreshold = 70,

    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Both',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$NoCapture,

    [Parameter()]
    [switch]$NoCache,

    [Parameter()]
    [switch]$RefreshCache,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)
# -WhatIf is provided automatically by [CmdletBinding(SupportsShouldProcess)]
# and read below via $WhatIfPreference.

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true  }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($mod.Required) {
            Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '$ConfigPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host "ERROR: Configuration validation failed. Check settings.json for required values." -ForegroundColor Red
    exit 4
}

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

# Browser token injection
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

# Resolve effective DaysBack from config if needed
$effectiveDaysBack = $DaysBack
if ($effectiveDaysBack -le 0) { $effectiveDaysBack = 1 }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Evidence Report (v4)' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  Period:        Last $effectiveDaysBack day(s)" -ForegroundColor DarkGray
$cacheLabel = if ($RefreshCache) { 'REFRESH (fresh fetch + update cache)' } elseif ($NoCache) { 'DISABLED (fresh fetch, cache preserved)' } else { 'Enabled (use -NoCache or -RefreshCache)' }
$cacheColor = if ($RefreshCache -or $NoCache) { 'Yellow' } else { 'DarkGray' }
Write-Host "  Item Cache:    $cacheLabel" -ForegroundColor $cacheColor
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

Write-SPLog -Message "Invoke-SPDailyEvidenceReport started: CorrelationID=$correlationID DaysBack=$effectiveDaysBack" `
    -Severity INFO -Component 'DailyEvidenceV4' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    # Check DailyEvidence.OutputPath first
    $deOutputPath = $null
    if ($null -ne $config.PSObject.Properties['DailyEvidence'] -and
        $null -ne $config.DailyEvidence -and
        $null -ne $config.DailyEvidence.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.DailyEvidence.OutputPath)) {
        $deOutputPath = [string]$config.DailyEvidence.OutputPath
    }

    if ($null -ne $deOutputPath) {
        $effectiveOutputPath = $deOutputPath
    }
    elseif ($null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = Join-Path ([string]$config.Audit.OutputPath) 'daily-evidence'
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'daily-evidence')
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}
if (-not (Test-Path $effectiveOutputPath)) {
    New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
}

# Resolve effective source IDs from config
$effectiveSourceIds = $SourceId
if (-not $effectiveSourceIds -or $effectiveSourceIds.Count -eq 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['SourceIds'] -and
        $config.DeltaCert.SourceIds.Count -gt 0) {
        $effectiveSourceIds = @($config.DeltaCert.SourceIds)
    }
}

#endregion

#region Threshold Loading

$thresholds = @{
    CompletionRate      = @{ Green = 95; Yellow = 80 }
    OverdueAttestations = @{ Green = 0;  Yellow = 2  }
    RevocationExecution = @{ Green = 95; Yellow = 80 }
    RemediationSla      = @{ Green = 95; Yellow = 80 }
    HighRiskPending     = @{ Green = 0;  Yellow = 3  }
    ReviewerHealth      = @{ GreenMaxAtRisk = 0; YellowMaxAtRisk = 2 }
}
$confidenceGrades = @{ A = 90; B = 80; C = 70; D = 60 }
$evidenceDetailLimit = 50

# Override from config if DailyEvidence.Thresholds exists
if ($null -ne $config.PSObject.Properties['DailyEvidence'] -and
    $null -ne $config.DailyEvidence -and
    $null -ne $config.DailyEvidence.PSObject.Properties['Thresholds'] -and
    $null -ne $config.DailyEvidence.Thresholds) {
    $ct = $config.DailyEvidence.Thresholds
    if ($null -ne $ct.PSObject.Properties['CompletionRate'] -and $null -ne $ct.CompletionRate) {
        if ($null -ne $ct.CompletionRate.PSObject.Properties['Green']) { $thresholds.CompletionRate.Green = [int]$ct.CompletionRate.Green }
        if ($null -ne $ct.CompletionRate.PSObject.Properties['Yellow']) { $thresholds.CompletionRate.Yellow = [int]$ct.CompletionRate.Yellow }
    }
    if ($null -ne $ct.PSObject.Properties['OverdueAttestations'] -and $null -ne $ct.OverdueAttestations) {
        if ($null -ne $ct.OverdueAttestations.PSObject.Properties['Green']) { $thresholds.OverdueAttestations.Green = [int]$ct.OverdueAttestations.Green }
        if ($null -ne $ct.OverdueAttestations.PSObject.Properties['Yellow']) { $thresholds.OverdueAttestations.Yellow = [int]$ct.OverdueAttestations.Yellow }
    }
    if ($null -ne $ct.PSObject.Properties['RevocationExecution'] -and $null -ne $ct.RevocationExecution) {
        if ($null -ne $ct.RevocationExecution.PSObject.Properties['Green']) { $thresholds.RevocationExecution.Green = [int]$ct.RevocationExecution.Green }
        if ($null -ne $ct.RevocationExecution.PSObject.Properties['Yellow']) { $thresholds.RevocationExecution.Yellow = [int]$ct.RevocationExecution.Yellow }
    }
    if ($null -ne $ct.PSObject.Properties['RemediationSla'] -and $null -ne $ct.RemediationSla) {
        if ($null -ne $ct.RemediationSla.PSObject.Properties['Green']) { $thresholds.RemediationSla.Green = [int]$ct.RemediationSla.Green }
        if ($null -ne $ct.RemediationSla.PSObject.Properties['Yellow']) { $thresholds.RemediationSla.Yellow = [int]$ct.RemediationSla.Yellow }
    }
    if ($null -ne $ct.PSObject.Properties['HighRiskPending'] -and $null -ne $ct.HighRiskPending) {
        if ($null -ne $ct.HighRiskPending.PSObject.Properties['Green']) { $thresholds.HighRiskPending.Green = [int]$ct.HighRiskPending.Green }
        if ($null -ne $ct.HighRiskPending.PSObject.Properties['Yellow']) { $thresholds.HighRiskPending.Yellow = [int]$ct.HighRiskPending.Yellow }
    }
    if ($null -ne $ct.PSObject.Properties['ReviewerHealth'] -and $null -ne $ct.ReviewerHealth) {
        if ($null -ne $ct.ReviewerHealth.PSObject.Properties['GreenMaxAtRisk']) { $thresholds.ReviewerHealth.GreenMaxAtRisk = [int]$ct.ReviewerHealth.GreenMaxAtRisk }
        if ($null -ne $ct.ReviewerHealth.PSObject.Properties['YellowMaxAtRisk']) { $thresholds.ReviewerHealth.YellowMaxAtRisk = [int]$ct.ReviewerHealth.YellowMaxAtRisk }
    }
    if ($null -ne $ct.PSObject.Properties['ConfidenceGrades'] -and $null -ne $ct.ConfidenceGrades) {
        if ($null -ne $ct.ConfidenceGrades.PSObject.Properties['A']) { $confidenceGrades.A = [int]$ct.ConfidenceGrades.A }
        if ($null -ne $ct.ConfidenceGrades.PSObject.Properties['B']) { $confidenceGrades.B = [int]$ct.ConfidenceGrades.B }
        if ($null -ne $ct.ConfidenceGrades.PSObject.Properties['C']) { $confidenceGrades.C = [int]$ct.ConfidenceGrades.C }
        if ($null -ne $ct.ConfidenceGrades.PSObject.Properties['D']) { $confidenceGrades.D = [int]$ct.ConfidenceGrades.D }
    }
    if ($null -ne $ct.PSObject.Properties['EvidenceDetailLimit'] -and $null -ne $ct.EvidenceDetailLimit) {
        $evidenceDetailLimit = [int]$ct.EvidenceDetailLimit
    }
}

#endregion

#region WhatIf

$isWhatIf = ($WhatIfPreference -eq $true)

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following steps would be executed:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  [1] Campaign Fetch: last $effectiveDaysBack day(s)" -ForegroundColor Gray
    $nameFilterDesc = ''
    if ($CampaignName)           { $nameFilterDesc += " Name='$CampaignName'" }
    if ($CampaignNameStartsWith) { $nameFilterDesc += " StartsWith='$CampaignNameStartsWith'" }
    if ($CampaignNameContains)   { $nameFilterDesc += " Contains='$CampaignNameContains'" }
    if ($nameFilterDesc) { Write-Host "      Filters:$nameFilterDesc" -ForegroundColor Gray }
    Write-Host '      -> Get-SPAuditCampaigns, Get-SPAuditCertifications,' -ForegroundColor Gray
    Write-Host '         Get-SPCachedCampaignItems, Group-SPAuditDecisions,' -ForegroundColor Gray
    Write-Host '         Measure-SPAuditReviewerMetrics, Measure-SPAuditRubberStampRisk' -ForegroundColor Gray
    Write-Host "  [2] KPI 1 - Campaign Completion: Measure-SPCampaignMetrics" -ForegroundColor Gray
    Write-Host "  [3] KPI 2 - Overdue Reviews: Get-SPCampaignHealth, Get-SPCampaignCompletionForecast" -ForegroundColor Gray
    Write-Host "  [4] KPI 3 - Revocations Executed: Group-SPAuditRemediationProof (SLA=${SlaHours}h)" -ForegroundColor Gray
    Write-Host "  [5] KPI 4 - Remediation Timeliness: aging bucket analysis" -ForegroundColor Gray
    Write-Host "  [6] KPI 5 - High-Risk Exposure: Measure-SPIdentityRisk (threshold=$HighRiskThreshold)" -ForegroundColor Gray
    Write-Host '  [7] KPI 6 - Reviewer Health: Measure-SPReviewerReputation' -ForegroundColor Gray
    Write-Host '  [8] Governance Confidence Score: Measure-SPGovernanceMaturity' -ForegroundColor Gray
    Write-Host ''
    Write-Host "  Output mode:  $OutputMode" -ForegroundColor DarkGray
    Write-Host "  Output path:  $effectiveOutputPath" -ForegroundColor DarkGray
    Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

#endregion

#region Helper Functions

function ConvertTo-SafeHtml {
    [OutputType([string])]
    param([Parameter()]$Value)
    if ($null -eq $Value) { return '' }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return '' }
    return (ConvertTo-SPHtmlSafe $str)
}

function Get-KpiStatus {
    # For "higher is better" KPIs (completion rate, SLA %)
    param([double]$Value, [double]$GreenThreshold, [double]$YellowThreshold)
    if ($Value -ge $GreenThreshold) { return 'Green' }
    elseif ($Value -ge $YellowThreshold) { return 'Yellow' }
    else { return 'Red' }
}

function Get-KpiStatusInverse {
    # For "lower is better" KPIs (overdue count, high-risk count)
    param([double]$Value, [double]$GreenMax, [double]$YellowMax)
    if ($Value -le $GreenMax) { return 'Green' }
    elseif ($Value -le $YellowMax) { return 'Yellow' }
    else { return 'Red' }
}

#endregion

#region Step Tracking

$stepResults = [ordered]@{
    CampaignFetch      = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    CampaignCompletion = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    OverdueReviews     = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    Revocations        = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    RemediationSla     = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    HighRiskExposure   = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    ReviewerHealth     = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
    ConfidenceScore    = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
}
$worstExitCode = 0

# Data holders
$campaignAudits          = @()
$currentCampaigns        = @()
$campaignMetricsData     = $null
$healthResult            = $null
$forecastData            = $null
$identityRiskData        = $null
$reviewerReputationData  = $null
$governanceMaturityData  = $null
$trendData               = $null

# KPI values (set during steps)
$avgCompletionRate       = 0
$kpi1Status              = 'Green'
$overdueCount            = 0
$atRiskCount             = 0
$kpi2Status              = 'Green'
$revocationTotal         = 0
$revocationProvisioned   = 0
$revocationExecutionRate = 0
$kpi3Status              = 'Green'
$slaComplianceRate       = 0
$kpi4Status              = 'Green'
$highRiskPendingCount    = 0
$kpi5Status              = 'Green'
$reviewerAtRiskCount     = 0
$reviewerTotalCount      = 0
$kpi6Status              = 'Green'
$confidenceScore         = 0
$confidenceGrade         = 'N/A'
$confidenceLevel         = 'N/A'

# Evidence data
$allRemediationProof     = [System.Collections.Generic.List[object]]::new()
$agingBuckets            = [ordered]@{ '0-24h' = 0; '24-48h' = 0; '2-5d' = 0; '5-10d' = 0; '>10d' = 0 }
$agingDetails            = [System.Collections.Generic.List[object]]::new()
$highRiskPending         = [System.Collections.Generic.List[PSCustomObject]]::new()
$highRiskPendingIdentityIds = @{}
$overdueAtRiskCampaigns  = [System.Collections.Generic.List[object]]::new()

#endregion

#region Step 1: Campaign Fetch & Audit Build

Write-Host '  Step 1: Campaign Fetch & Audit Build' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    # Fetch campaigns
    Write-Host '    Fetching campaigns...' -ForegroundColor DarkGray
    $campaignParams = @{ DaysBack = $effectiveDaysBack; CorrelationID = $correlationID }
    if ($CampaignName)           { $campaignParams['CampaignName']           = $CampaignName }
    if ($CampaignNameStartsWith) { $campaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
    if ($CampaignNameContains)   { $campaignParams['CampaignNameContains']   = $CampaignNameContains }
    if ($Status)                 { $campaignParams['Status']                 = $Status }
    $campaignResult = Get-SPAuditCampaigns @campaignParams
    if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
        $currentCampaigns = @($campaignResult.Data)
    }
    Write-Host "    Found $($currentCampaigns.Count) campaign(s) in last $effectiveDaysBack day(s)." -ForegroundColor DarkGray

    if ($currentCampaigns.Count -eq 0) {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $stepResults['CampaignFetch'] = @{ Status = 'Warning'; Detail = 'No campaigns found in lookback window'; Duration = [math]::Round($stepDuration, 2) }
        Write-Host '  Step 1: No campaigns found. Report cannot continue.' -ForegroundColor Yellow
        Write-SPLog -Message "No campaigns found in last $effectiveDaysBack day(s)" `
            -Severity WARN -Component 'DailyEvidenceV4' -Action 'NoCampaigns' -CorrelationID $correlationID
        Write-Host ''
        exit 1
    }

    # Build campaign audit data
    Write-Host '    Building campaign audit data...' -ForegroundColor DarkGray
    $auditList = [System.Collections.Generic.List[object]]::new()

    foreach ($campaign in $currentCampaigns) {
        $campId   = $campaign.id
        $campName = $campaign.name

        try {
            $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
            $certifications = @()
            if ($certResult.Success -and $null -ne $certResult.Data) {
                $certifications = @($certResult.Data)
            }

            $wrappedItems = [System.Collections.Generic.List[object]]::new()
            $itemParams = @{ Campaign = $campaign; Certifications = $certifications; CorrelationID = $correlationID }
            if ($NoCache -or $RefreshCache) { $itemParams['NoCache'] = $true }
            if ($RefreshCache) { $itemParams['RefreshCache'] = $true }
            $cacheResult = Get-SPCachedCampaignItems @itemParams
            if ($cacheResult.Success) {
                foreach ($wi in $cacheResult.Data) { $wrappedItems.Add($wi) }
            }
            $itemsFromCache = if ($cacheResult.ContainsKey('FromCache')) { [bool]$cacheResult.FromCache } else { $false }

            $campaignMetadata = @{
                StartDate      = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
                DueDate        = if ($null -ne $campaign.deadline)  { [string]$campaign.deadline }
                                 elseif ($null -ne $campaign.due)   { [string]$campaign.due }       else { '' }
                CompletionDate = if ($null -ne $campaign.completed) { [string]$campaign.completed } else { '' }
            }

            $decisionGroups  = Group-SPAuditDecisions -Items $wrappedItems.ToArray() `
                -CampaignMetadata $campaignMetadata
            $dgA = @($decisionGroups['Approved']).Count; $dgR = @($decisionGroups['Revoked']).Count; $dgP = @($decisionGroups['Pending']).Count
            Write-Verbose "    [Decisions] $campName : Approved=$dgA Revoked=$dgR Pending=$dgP (from $(if($itemsFromCache){'cache'}else{'ISC'}) items=$($wrappedItems.Count))"
            $reviewerMetrics = Measure-SPAuditReviewerMetrics -Certifications $certifications
            $rubberStampRisk = Measure-SPAuditRubberStampRisk -Decisions $decisionGroups `
                -Certifications $certifications

            $reviewerActions = Group-SPReviewerActions -Certifications $certifications

            # Seal the cert -> assigned-reviewer roster (WI-2). Prefers the ACTIVE-state
            # sealed roster; falls back to these live certs when no seal exists. The
            # COMPLETED accountability path uses this to attribute undecided items to the
            # ASSIGNED reviewer (item.CertificationId -> roster), not item.reviewedBy.
            $rosterResult = Get-SPCachedCampaignRoster -Campaign $campaign -Certifications $certifications -CorrelationID $correlationID
            $certRoster = if ($rosterResult.Success) { @($rosterResult.Data) } else { @() }

            $campaignAudit = @{
                CampaignName    = $campName
                CampaignId      = $campId
                Status          = if ($null -ne $campaign.status)    { [string]$campaign.status }    else { '' }
                Created         = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
                Completed       = if ($null -ne $campaign.completed) { [string]$campaign.completed } else { '' }
                Deadline        = if ($null -ne $campaign.deadline)  { [string]$campaign.deadline }
                                  elseif ($null -ne $campaign.due)   { [string]$campaign.due }       else { '' }
                Decisions       = $decisionGroups
                ReviewerMetrics = $reviewerMetrics
                RubberStampRisk = $rubberStampRisk
                WrappedItems    = $wrappedItems.ToArray()
                Certifications  = $certifications
                ReviewerActions = $reviewerActions
                CertRoster      = $certRoster
                ItemsFromCache  = $itemsFromCache
                # WI-4 (G1): capture-provenance so the COMPLETED render can warn when a
                # campaign was sealed WITHOUT a prior ACTIVE-state snapshot (unverified).
                CaptureCapturedWhileActive = [bool]$rosterResult.CapturedWhileActive
                CaptureSealed              = [bool]$rosterResult.Sealed
                CaptureSource              = [string]$rosterResult.Source
            }
            $auditList.Add($campaignAudit)
        }
        catch {
            Write-Host "    WARN: Failed to process $campName : $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Campaign audit build failed for ${campName}: $($_.Exception.Message)" `
                -Severity WARN -Component 'DailyEvidenceV4' -Action 'AuditBuildError' -CorrelationID $correlationID
        }
    }

    # Sort campaigns by created date descending (newest first) for consistent report ordering
    $campaignAudits = @($auditList.ToArray() | Sort-Object @{ Expression = {
        $c = [string]$_['Created']; if ([string]::IsNullOrWhiteSpace($c)) { [datetime]::MinValue } else { try { [datetime]::Parse($c) } catch { [datetime]::MinValue } }
    } } -Descending)
    Write-Host "    Built audit data for $($campaignAudits.Count) campaign(s)." -ForegroundColor DarkGray

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['CampaignFetch'] = @{ Status = 'Success'; Detail = "$($campaignAudits.Count) campaigns audited"; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 1: $($campaignAudits.Count) campaigns fetched and audited" -ForegroundColor Green

}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['CampaignFetch'] = @{ Status = 'Error'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 1: ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Write-SPLog -Message "Campaign fetch exception: $($_.Exception.Message)" `
        -Severity ERROR -Component 'DailyEvidenceV4' -Action 'CampaignFetchError' -CorrelationID $correlationID
    $worstExitCode = 5
}
Write-Host ''

#endregion

#region Step 1b: Scope-diff snapshot (newly approved access)

Write-Host '  Step 1b: Scope-diff snapshot (newly approved access)' -ForegroundColor Cyan
$stepStart = Get-Date

# Newly approved items extracted from the scope-diff engine.
$v4NewlyApproved = [System.Collections.Generic.List[object]]::new()
$v4NewlyDecided  = [System.Collections.Generic.List[object]]::new()
$v4SeenKeys      = @{}
$v4HasPrior      = $false
$v4PriorLabels   = [System.Collections.Generic.List[string]]::new()

# Thin wrapper -- canonical implementation is Get-SPObjectProperty (SP.HtmlHelpers).
function Get-V4Prop { param($o, [string]$n, $def = '')
    return (Get-SPObjectProperty -Object $o -Name $n -Default $def)
}

try {
    # Same name filter the user passed, so the snapshot set is scoped to this recurring series.
    $setParams = @{}
    if ($CampaignName)           { $setParams['CampaignName']           = $CampaignName }
    if ($CampaignNameStartsWith) { $setParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
    if ($CampaignNameContains)   { $setParams['CampaignNameContains']   = $CampaignNameContains }

    # Pass 1: build + persist today's snapshot for each campaign.
    foreach ($audit in $campaignAudits) {
        $campObj = [PSCustomObject]@{
            id = $audit['CampaignId']; name = $audit['CampaignName']
            status = $audit['Status']; created = $audit['Created']; deadline = $audit['Deadline']
        }
        $todaySnap = $null
        try { $todaySnap = Build-SPCampaignSnapshotData -Campaign $campObj -Certifications @($audit['Certifications']) -Decisions $audit['Decisions'] }
        catch { Write-Host "    WARN: snapshot build failed for $($audit['CampaignName']): $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($null -eq $todaySnap) { continue }
        $audit['TodaySnapshot'] = $todaySnap
        if (-not $NoCapture) {
            try { $sv = Save-SPCampaignSnapshot -Snapshot $todaySnap; if (-not $sv.Success) { Write-Host "    WARN: snapshot save: $($sv.Error)" -ForegroundColor Yellow } }
            catch { Write-Host "    WARN: snapshot save failed: $($_.Exception.Message)" -ForegroundColor Yellow }
            # Write trend point for V5 trend charts (lightweight, no extra API calls)
            try { Save-SPCampaignTrendPoint -Snapshot $todaySnap | Out-Null }
            catch { Write-Host "    WARN: trend point save failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    # Resolve the cross-campaign snapshot set once.
    $snapSet = @()
    try { $ss = Get-SPCampaignSnapshotSet @setParams; if ($ss.Success) { $snapSet = @($ss.Data) } } catch { }

    # Pass 2: per campaign, diff today vs the most-recent DIFFERENT campaign (cross-campaign).
    foreach ($audit in $campaignAudits) {
        $todaySnap = $audit['TodaySnapshot']
        if ($null -eq $todaySnap) { continue }
        $others = @($snapSet | Where-Object { [string]$_.Meta.CampaignId -ne [string]$audit['CampaignId'] })
        if ($others.Count -eq 0) { continue }
        $priorSnap = @($others | Sort-Object @{ Expression = {
            $d = [string]$_.Meta.StartDate; if ([string]::IsNullOrWhiteSpace($d)) { $d = [string]$_.Meta.CapturedAt }
            try { [datetime]$d } catch { [datetime]::MinValue }
        } } -Descending)[0]
        if ($null -eq $priorSnap) { continue }

        $v4HasPrior = $true
        $pLabel = [string]$priorSnap.Meta.CampaignName
        if ($pLabel -and -not $v4PriorLabels.Contains($pLabel)) { $v4PriorLabels.Add($pLabel) }

        $cmp = $null
        try { $cmp = Compare-SPCampaignSnapshots -Current $todaySnap -Previous $priorSnap -CrossCampaign }
        catch { Write-Host "    WARN: compare failed for $($audit['CampaignName']): $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($null -eq $cmp -or -not $cmp.Success) { continue }
        $diff = $cmp.Data

        # Extract newly approved items from the Added scope.
        # If DecisionDate is empty, fall back to the campaign's sign-off or creation date
        # (the manager's sign-off on the campaign is sufficient for audit).
        $fallbackDate = [string]$audit['Created']
        $ra2 = $audit['ReviewerActions']
        if ($null -ne $ra2 -and $null -ne $ra2['Primary']) {
            $signedReviewers = @($ra2['Primary'] | Where-Object { $_.Phase -eq 'SIGNED' -and -not [string]::IsNullOrWhiteSpace($_.SignOffDate) })
            if ($signedReviewers.Count -gt 0) {
                $fallbackDate = [string]$signedReviewers[0].SignOffDate
            }
        }

        # Collect truly-new scope items (Added = in current but NOT in prior campaign).
        # For COMPLETED campaigns, new scope items with APPROVE may be auto-decided.
        # Still collect them (scope change is real) but the decision may not be genuine.
        foreach ($a in @($diff.Scope.Added)) {
            $aKey = [string](Get-V4Prop $a 'Key' '')
            if (-not [string]::IsNullOrWhiteSpace($aKey) -and $v4SeenKeys.ContainsKey($aKey)) { continue }
            $dec = [string](Get-V4Prop $a 'Decision' '')
            if ($dec -eq 'APPROVE' -or $dec -eq 'Approved') {
                $itemDate = [string](Get-V4Prop $a 'DecisionDate' '')
                if ([string]::IsNullOrWhiteSpace($itemDate)) {
                    $a | Add-Member -NotePropertyName 'DecisionDate' -NotePropertyValue $fallbackDate -Force -ErrorAction SilentlyContinue
                }
                $v4NewlyApproved.Add($a)
                if (-not [string]::IsNullOrWhiteSpace($aKey)) { $v4SeenKeys[$aKey] = $true }
            }
        }

        # NewlyDecided: PENDING in prior → APPROVE/REVOKE in current.
        # DISABLED for daily recurring campaigns (same scope re-reviewed each day).
        # For recurring campaigns, PENDING→APPROVE is always a timing artifact:
        #   - Pre-sign-off: ISC shows items as PENDING even if reviewer clicked approve
        #   - Auto-closed: idNowAutoApproved items are PENDING but were never truly undecided
        #   - Reviewer absence: one-day gap doesn't mean items were never reviewed
        # The V7 Reviewer Compliance Accountability section handles genuine accountability.
        # NewlyDecided only renders for non-recurring campaigns (mixed types/scopes).
        $campStatus = ([string]$audit['Status']).ToUpperInvariant()
        $isRecurring = $true
        if ($campaignAudits.Count -le 1) { $isRecurring = $false }
        else {
            $firstTotal = @($campaignAudits[0]['Decisions']['Approved']).Count + @($campaignAudits[0]['Decisions']['Revoked']).Count + @($campaignAudits[0]['Decisions']['Pending']).Count
            $thisDecisions = $audit['Decisions']
            $thisTotal = @($thisDecisions['Approved']).Count + @($thisDecisions['Revoked']).Count + @($thisDecisions['Pending']).Count
            if ([math]::Abs($firstTotal - $thisTotal) -gt ($firstTotal * 0.1)) { $isRecurring = $false }
        }
        if (-not $isRecurring -and $campStatus -notin @('COMPLETED', 'COMPLETING')) {
            foreach ($nd in @($diff.Scope.NewlyDecided)) {
                $ndKey = [string](Get-V4Prop $nd 'Key' '')
                if (-not [string]::IsNullOrWhiteSpace($ndKey) -and $v4SeenKeys.ContainsKey($ndKey)) { continue }
                $ndDec = [string](Get-V4Prop $nd 'CurrDecision' '')
                if ($ndDec -eq 'APPROVE' -or $ndDec -eq 'Approved') {
                    $ndDate = [string](Get-V4Prop $nd 'CurrDecisionDate' '')
                    if ([string]::IsNullOrWhiteSpace($ndDate)) {
                        $nd | Add-Member -NotePropertyName 'CurrDecisionDate' -NotePropertyValue $fallbackDate -Force -ErrorAction SilentlyContinue
                    }
                    $v4NewlyDecided.Add($nd)
                    if (-not [string]::IsNullOrWhiteSpace($ndKey)) { $v4SeenKeys[$ndKey] = $true }
                }
            }
        }
    }

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['ScopeDiff'] = @{ Status = 'Success'; Detail = "new-scope=$($v4NewlyApproved.Count) newly-decided=$($v4NewlyDecided.Count) hasPrior=$v4HasPrior"; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 1b: new-scope=$($v4NewlyApproved.Count) newly-decided=$($v4NewlyDecided.Count) hasPrior=$v4HasPrior" -ForegroundColor Green
}
catch {
    Write-Host "  Step 1b: ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Write-SPLog -Message "Scope-diff exception: $($_.Exception.Message)" -Severity ERROR -Component 'DailyEvidenceV4' -Action 'ScopeDiffError' -CorrelationID $correlationID
}
Write-Host ''

#endregion

#region Write daily-metrics.jsonl for V6 visualization

try {
    $metricsPath = '.\Audit\metrics'
    try {
        $mcfg = Get-SPConfig
        if ($null -ne $mcfg.PSObject.Properties['Metrics'] -and
            $null -ne $mcfg.Metrics.PSObject.Properties['Path'] -and
            -not [string]::IsNullOrWhiteSpace($mcfg.Metrics.Path)) {
            $metricsPath = [string]$mcfg.Metrics.Path
        }
    } catch { }
    if (-not [System.IO.Path]::IsPathRooted($metricsPath)) {
        $metricsPath = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $metricsPath))
    }
    if (-not (Test-Path $metricsPath)) { New-Item -ItemType Directory -Path $metricsPath -Force -WhatIf:$false | Out-Null }

    $dailyMetricsFile = Join-Path $metricsPath 'daily-metrics.jsonl'
    Write-Host "  [Metrics] Path: $dailyMetricsFile" -ForegroundColor DarkGray
    $captureTs = (Get-Date).ToString('o')
    $metricsWritten = 0
    $metricsSkipped = 0

    # Pre-load existing JSONL records to avoid overwriting ACTIVE-state data with
    # COMPLETED-state data. An ACTIVE record captured honest reviewer metrics; a
    # COMPLETED record has inflated numbers from ISC auto-approving remaining items.
    $existingRecords = @{}
    if (Test-Path $dailyMetricsFile) {
        try {
            $utf8Read = New-Object System.Text.UTF8Encoding($false)
            foreach ($ln in [System.IO.File]::ReadAllLines($dailyMetricsFile, $utf8Read)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                try {
                    $existing = $ln | ConvertFrom-Json
                    $eKey = "$([string]$existing.captureDate)|$([string]$existing.campaign.id)"
                    $existingRecords[$eKey] = [string]$existing.campaign.status
                } catch { }
            }
        } catch { }
    }

    foreach ($audit in $campaignAudits) {
        # captureDate = the campaign's own date (from created), NOT the run date.
        $campaignCreated = [string]$audit['Created']
        $captureDate = (Get-Date).ToString('yyyy-MM-dd')
        if (-not [string]::IsNullOrWhiteSpace($campaignCreated)) {
            try { $captureDate = ([datetime]::Parse($campaignCreated, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToString('yyyy-MM-dd') }
            catch { }
        }
        # Don't overwrite an ACTIVE-state JSONL record with COMPLETED data.
        # ACTIVE records have honest reviewer metrics; COMPLETED records are inflated by auto-approve.
        $metricsStatus = ([string]$audit['Status']).ToUpperInvariant()
        $metricsDedupKey = "${captureDate}|$([string]$audit['CampaignId'])"
        if ($metricsStatus -in @('COMPLETED', 'COMPLETING') -and
            $existingRecords.ContainsKey($metricsDedupKey) -and
            $existingRecords[$metricsDedupKey] -eq 'ACTIVE') {
            Write-Host "    [Metrics] Skipping $($audit['CampaignName']) -- ACTIVE record already exists (not overwriting)" -ForegroundColor DarkGray
            $metricsSkipped++
            continue
        }

        $d = $audit['Decisions']
        $apprItems = @($d['Approved']); $revItems2 = @($d['Revoked']); $pendItems = @($d['Pending'])
        $apprCount = $apprItems.Count; $revCount2 = $revItems2.Count; $pendCount = $pendItems.Count
        $totalCount = $apprCount + $revCount2 + $pendCount
        $decidedCount = $apprCount + $revCount2
        $compPct = if ($totalCount -gt 0) { [math]::Round($decidedCount / $totalCount * 100, 1) } else { 0 }

        # Reviewer breakdown
        $ra = $audit['ReviewerActions']
        $primary = if ($null -ne $ra -and $null -ne $ra['Primary']) { @($ra['Primary']) } else { @() }
        $reassigned = if ($null -ne $ra -and $null -ne $ra['Reassigned']) { @($ra['Reassigned']) } else { @() }
        $allReviewers = @($primary) + @($reassigned)
        $signedCount = @($allReviewers | Where-Object { $_.Phase -eq 'SIGNED' }).Count
        $notStartedCount = @($allReviewers | Where-Object { $_.Phase -eq 'NOT_STARTED' -or $_.DecisionsMade -eq 0 }).Count
        $rvCompPct = if ($allReviewers.Count -gt 0) { [math]::Round($signedCount / $allReviewers.Count * 100, 1) } else { 0 }

        # Per-reviewer detail -- computed from ITEM data, not cert-level DecisionsMade.
        # Cert-level data is inflated by ISC on force-completion (DecisionsMade = DecisionsTotal
        # even for reviewers who never logged in). The item data, with idNowAutoApproved
        # detection in Group-SPAuditDecisions, tells the truth.
        #
        # ISC items carry reviewedBy only when the reviewer acted. For unreviewed items,
        # reviewedBy is null. Use the CertificationId -> reviewer mapping from the
        # certifications to attribute orphaned items to their assigned reviewer.
        $certToReviewer = @{}
        foreach ($cert in @($audit['Certifications'])) {
            if ($null -eq $cert) { continue }
            $cid = [string]$cert.id
            $crn = ''
            if ($null -ne $cert.reviewer -and $null -ne $cert.reviewer.name) { $crn = [string]$cert.reviewer.name }
            if (-not [string]::IsNullOrWhiteSpace($cid) -and -not [string]::IsNullOrWhiteSpace($crn)) {
                $certToReviewer[$cid] = $crn
            }
        }

        $rvItemCounts = @{}
        foreach ($grp in @('Approved', 'Revoked', 'Pending')) {
            foreach ($item in @($d[$grp])) {
                if ($null -eq $item) { continue }
                $rn = [string]$item.ReviewerName
                if ([string]::IsNullOrWhiteSpace($rn) -or $rn -eq 'N/A') {
                    $mapped = $false
                    # Fallback 1: CertificationId -> reviewer name
                    $cid = if ($item.PSObject.Properties['CertificationId']) { [string]$item.CertificationId } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($cid) -and $certToReviewer.ContainsKey($cid)) {
                        $rn = $certToReviewer[$cid]; $mapped = $true
                    }
                    # Fallback 2: CertificationName "Cert for {Name}" -> extract name
                    if (-not $mapped) {
                        $cn = if ($item.PSObject.Properties['CertificationName']) { [string]$item.CertificationName } else { '' }
                        if ($cn -match '^Cert for (.+)$') { $rn = $Matches[1] }
                    }
                }
                if ([string]::IsNullOrWhiteSpace($rn)) { $rn = 'N/A' }
                if (-not $rvItemCounts.ContainsKey($rn)) {
                    $rvItemCounts[$rn] = @{ Approved = 0; Revoked = 0; Pending = 0; Total = 0 }
                }
                $rvItemCounts[$rn].Total++
                switch ($grp) {
                    'Approved' { $rvItemCounts[$rn].Approved++ }
                    'Revoked'  { $rvItemCounts[$rn].Revoked++ }
                    default    { $rvItemCounts[$rn].Pending++ }
                }
            }
        }

        $reviewerRecords = [System.Collections.Generic.List[object]]::new()
        foreach ($rv in $allReviewers) {
            $rvName = [string]$rv.Name
            $rvClass = if ($rv.PSObject.Properties['Classification'] -and -not [string]::IsNullOrWhiteSpace($rv.Classification)) { [string]$rv.Classification } else { 'Primary' }
            # Use item-level counts (honest) instead of cert-level DecisionsMade (inflated)
            $ic = if ($rvItemCounts.ContainsKey($rvName)) { $rvItemCounts[$rvName] } else { @{ Approved = 0; Revoked = 0; Pending = 0; Total = 0 } }
            $rvTotal = [int]$ic.Total
            $rvAppr = [int]$ic.Approved
            $rvRev = [int]$ic.Revoked
            $rvPend = [int]$ic.Pending
            $rvComp = if ($rvTotal -gt 0) { [math]::Round(($rvAppr + $rvRev) / $rvTotal * 100, 1) } else { 0 }
            $reviewerRecords.Add([ordered]@{
                name           = $rvName
                identityId     = if ($rv.PSObject.Properties['ReviewerId']) { [string]$rv.ReviewerId } else { '' }
                email          = if ($rv.PSObject.Properties['Email']) { [string]$rv.Email } else { '' }
                classification = $rvClass
                total          = $rvTotal
                approved       = $rvAppr
                revoked        = $rvRev
                pending        = $rvPend
                completionPct  = $rvComp
                signed         = ($rv.Phase -eq 'SIGNED')
                phase          = [string]$rv.Phase
            })
        }

        # Store reviewer records on the audit for the HTML section to reference per-campaign
        $audit['ReviewerRecords'] = @($reviewerRecords)

        # Per-source breakdown
        $sourceRecords = [System.Collections.Generic.List[object]]::new()
        $sourceMap = @{}
        foreach ($item in @($apprItems) + @($revItems2) + @($pendItems)) {
            $sn = if ($item.PSObject.Properties['SourceName']) { [string]$item.SourceName } else { 'Unknown' }
            if (-not $sourceMap.ContainsKey($sn)) { $sourceMap[$sn] = @{ total = 0; approved = 0; revoked = 0; pending = 0 } }
            $sourceMap[$sn].total++
            $dec = if ($item.PSObject.Properties['Decision']) { [string]$item.Decision } else { '' }
            switch ($dec.ToUpperInvariant()) {
                'APPROVE'  { $sourceMap[$sn].approved++ }
                'APPROVED' { $sourceMap[$sn].approved++ }
                'REVOKE'   { $sourceMap[$sn].revoked++ }
                'REVOKED'  { $sourceMap[$sn].revoked++ }
                default    { $sourceMap[$sn].pending++ }
            }
        }
        foreach ($sn in ($sourceMap.Keys | Sort-Object)) {
            $s = $sourceMap[$sn]
            $sourceRecords.Add([ordered]@{ name = $sn; total = $s.total; approved = $s.approved; revoked = $s.revoked; pending = $s.pending })
        }

        # Privileged counts
        $privTotal = 0; $privAppr = 0; $privRev = 0; $privPend = 0
        foreach ($item in @($apprItems) + @($revItems2) + @($pendItems)) {
            $isPriv = $false
            try { if ($item.PSObject.Properties['Privileged']) { $isPriv = [bool]$item.Privileged } } catch { }
            if ($isPriv) {
                $privTotal++
                $dec = if ($item.PSObject.Properties['Decision']) { [string]$item.Decision } else { '' }
                switch ($dec.ToUpperInvariant()) {
                    'APPROVE'  { $privAppr++ }
                    'APPROVED' { $privAppr++ }
                    'REVOKE'   { $privRev++ }
                    'REVOKED'  { $privRev++ }
                    default    { $privPend++ }
                }
            }
        }

        # Distinct identities
        $identSet = @{}
        foreach ($item in @($apprItems) + @($revItems2) + @($pendItems)) {
            $iid = if ($item.PSObject.Properties['IdentityId']) { [string]$item.IdentityId } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($iid)) { $identSet[$iid] = $true }
        }

        # Diff data
        $diffData = [ordered]@{ hasPrior = $v4HasPrior; priorCampaignName = ''; scopeAdded = 0; scopeRemoved = 0; scopeChanged = 0; newlyApprovedCount = 0; newlyDecidedCount = 0 }
        if ($null -ne $audit['Diff']) {
            $df = $audit['Diff']
            if ($null -ne $df.Scope) {
                $diffData.scopeAdded   = [int]$df.Scope.AddedCount
                $diffData.scopeRemoved = [int]$df.Scope.RemovedCount
                $diffData.scopeChanged = [int]$df.Scope.ChangedCount
            }
            if ($null -ne $df.Meta -and $null -ne $df.Meta.PSObject.Properties['PreviousCampaignName']) {
                $diffData.priorCampaignName = [string]$df.Meta.PreviousCampaignName
            }
        }
        $diffData.newlyApprovedCount = $v4NewlyApproved.Count
        $diffData.newlyDecidedCount = $v4NewlyDecided.Count

        $metricsRecord = [ordered]@{
            captureDate      = $captureDate
            captureTimestamp  = $captureTs
            correlationId    = $correlationID
            campaign         = [ordered]@{
                id        = [string]$audit['CampaignId']
                name      = [string]$audit['CampaignName']
                status    = [string]$audit['Status']
                created   = [string]$audit['Created']
                deadline  = [string]$audit['Deadline']
                completed = [string]$audit['Completed']
            }
            summary          = [ordered]@{
                totalItems              = $totalCount
                approved                = $apprCount
                revoked                 = $revCount2
                pending                 = $pendCount
                completionPct           = $compPct
                completionPctByReviewer = $rvCompPct
                reviewersTotal          = $allReviewers.Count
                reviewersSigned         = $signedCount
                reviewersNotStarted     = $notStartedCount
                reviewersInProgress     = $allReviewers.Count - $signedCount - $notStartedCount
                privilegedTotal         = $privTotal
                privilegedApproved      = $privAppr
                privilegedRevoked       = $privRev
                privilegedPending       = $privPend
                distinctIdentities      = $identSet.Count
                distinctSources         = $sourceMap.Count
            }
            reviewers        = @($reviewerRecords)
            sources          = @($sourceRecords)
            diff             = $diffData
        }

        $jsonLine = $metricsRecord | ConvertTo-Json -Depth 5 -Compress
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($dailyMetricsFile, "$jsonLine`n", $utf8NoBom)
        $metricsWritten++
    }

    Write-Host "  [Metrics] Wrote $metricsWritten, skipped $metricsSkipped of $($campaignAudits.Count) campaign(s) to: $dailyMetricsFile" -ForegroundColor DarkGreen
}
catch {
    Write-Host "  [Metrics] WARN: daily-metrics write failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

#endregion

#region Step 2: KPI 1 - Campaign Completion

Write-Host '  Step 2: KPI 1 - Campaign Completion' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    if ($currentCampaigns.Count -gt 0) {
        $campaignMetricsData = Measure-SPCampaignMetrics -Campaigns $currentCampaigns -CorrelationID $correlationID

        if ($campaignMetricsData.Success -and $null -ne $campaignMetricsData.Data) {
            $totalDecided = 0
            $totalItems   = 0
            foreach ($m in @($campaignMetricsData.Data)) {
                $totalDecided += ($m.ApprovedCount + $m.RevokedCount)
                $totalItems   += $m.TotalItems
            }
            $avgCompletionRate = if ($totalItems -gt 0) { [math]::Round(($totalDecided / $totalItems) * 100, 0) } else { 0 }
        }
        else {
            # Fallback: compute from audit data
            $totalDecided = 0; $totalItems = 0
            foreach ($audit in $campaignAudits) {
                $d = $audit['Decisions']
                if ($null -eq $d) { continue }
                $approved = if ($null -ne $d['Approved']) { @($d['Approved']).Count } else { 0 }
                $revoked  = if ($null -ne $d['Revoked'])  { @($d['Revoked']).Count }  else { 0 }
                $pending  = if ($null -ne $d['Pending'])  { @($d['Pending']).Count }  else { 0 }
                $totalDecided += ($approved + $revoked)
                $totalItems   += ($approved + $revoked + $pending)
            }
            $avgCompletionRate = if ($totalItems -gt 0) { [math]::Round(($totalDecided / $totalItems) * 100, 0) } else { 0 }
        }
    }

    $kpi1Status = Get-KpiStatus -Value $avgCompletionRate `
        -GreenThreshold $thresholds.CompletionRate.Green `
        -YellowThreshold $thresholds.CompletionRate.Yellow

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "Completion: $avgCompletionRate% ($totalDecided of $totalItems decided)"
    $stepResults['CampaignCompletion'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 2: $detail [$kpi1Status]" -ForegroundColor $(if ($kpi1Status -eq 'Green') { 'Green' } elseif ($kpi1Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['CampaignCompletion'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Campaign completion KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'CompletionError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 3: KPI 2 - Overdue Reviews

Write-Host '  Step 3: KPI 2 - Overdue Reviews' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    $healthResult = Get-SPCampaignHealth -DaysBack $effectiveDaysBack -CorrelationID $correlationID

    # Count overdue from health data
    $overdueCount = 0
    $atRiskCount  = 0
    if ($healthResult.Success -and $null -ne $healthResult.Data -and $null -ne $healthResult.Data.Campaigns) {
        foreach ($hc in @($healthResult.Data.Campaigns)) {
            $hStatus = if ($null -ne $hc.OverallHealth) { [string]$hc.OverallHealth } else { '' }
            if ($hStatus -eq 'Red') {
                $overdueCount++
                $overdueAtRiskCampaigns.Add([PSCustomObject]@{
                    CampaignName   = if ($null -ne $hc.CampaignName) { $hc.CampaignName } else { '' }
                    HealthStatus   = 'Overdue'
                    ProjectedStatus = ''
                    DaysToDeadline = ''
                    CompletionPct  = if ($null -ne $hc.CompletionPct) { [math]::Round($hc.CompletionPct, 0) } else { 0 }
                    BottleneckReviewers = ''
                })
            }
        }
    }

    # Try completion forecast for at-risk detection
    $forecastData = $null
    try {
        $forecastParams = @{ CampaignAudits = $campaignAudits; CorrelationID = $correlationID }
        if ($healthResult.Success -and $null -ne $healthResult.Data -and $null -ne $healthResult.Data.Campaigns) {
            $forecastParams['CampaignHealthData'] = @($healthResult.Data.Campaigns)
        }
        $forecastData = Get-SPCampaignCompletionForecast @forecastParams
    }
    catch {
        Write-Host "    WARN: Forecast: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($null -ne $forecastData -and $null -ne $forecastData.Forecasts) {
        foreach ($fc in @($forecastData.Forecasts)) {
            $willMeet = $fc.WillMeetDeadline
            if ($willMeet -eq $false) {
                $fcStatus = if ($fc.ProjectedCompletionDate -eq 'Unknown') { 'Stalled' } else { 'AtRisk' }
                $atRiskCount++

                $bottleneck = ''
                if ($null -ne $fc.BottleneckReviewers -and @($fc.BottleneckReviewers).Count -gt 0) {
                    $bottleneck = (@($fc.BottleneckReviewers) | ForEach-Object { $_.ReviewerName }) -join ', '
                }

                # Check if not already in the list from health data
                $alreadyListed = $false
                foreach ($existing in $overdueAtRiskCampaigns) {
                    if ($existing.CampaignName -eq $fc.CampaignName) { $alreadyListed = $true; break }
                }
                if (-not $alreadyListed) {
                    $daysToDeadline = ''
                    if ($null -ne $fc.DeadlineDate -and $fc.DeadlineDate -ne '') {
                        try {
                            $dl = [datetime]::Parse($fc.DeadlineDate)
                            $daysToDeadline = [math]::Round(($dl.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays, 0)
                        } catch { }
                    }
                    $overdueAtRiskCampaigns.Add([PSCustomObject]@{
                        CampaignName    = $fc.CampaignName
                        HealthStatus    = $fcStatus
                        ProjectedStatus = $fcStatus
                        DaysToDeadline  = $daysToDeadline
                        CompletionPct   = if ($null -ne $fc.CompletionPct) { [math]::Round($fc.CompletionPct, 0) } else { 0 }
                        BottleneckReviewers = $bottleneck
                    })
                }
            }
        }
    }

    $totalOverdueAtRisk = $overdueCount + $atRiskCount
    $kpi2Status = Get-KpiStatusInverse -Value $totalOverdueAtRisk `
        -GreenMax $thresholds.OverdueAttestations.Green `
        -YellowMax $thresholds.OverdueAttestations.Yellow

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "$overdueCount overdue, $atRiskCount at-risk"
    $stepResults['OverdueReviews'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 3: $detail [$kpi2Status]" -ForegroundColor $(if ($kpi2Status -eq 'Green') { 'Green' } elseif ($kpi2Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['OverdueReviews'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 3: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Overdue reviews KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'OverdueError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 4: KPI 3 - Revocations Executed

Write-Host '  Step 4: KPI 3 - Revocations Executed' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    # Build remediation proof from cached review items (no additional API calls)
    $totalRevoked = 0
    $totalRemediated = 0
    $totalRemediationPending = 0

    foreach ($audit in $campaignAudits) {
        $items = $audit['WrappedItems']
        $certs = $audit['Certifications']
        if ($null -eq $items -or $null -eq $certs) { continue }

        $proof = Group-SPAuditRemediationProof -Items $items -Certifications $certs
        if ($null -ne $proof) {
            $totalRevoked += $proof.TotalRevoked
            $totalRemediated += $proof.RemediationCompleteCount
            $totalRemediationPending += $proof.RemediationPendingCount
            foreach ($ri in $proof.RevokedItems) { $allRemediationProof.Add($ri) }
        }
    }

    $revocationTotal = $totalRevoked
    $revocationProvisioned = $totalRemediated
    $revocationExecutionRate = if ($totalRevoked -gt 0) {
        [math]::Round(($totalRemediated / $totalRevoked) * 100, 0)
    } else { 100 }

    $kpi3Status = Get-KpiStatus -Value $revocationExecutionRate `
        -GreenThreshold $thresholds.RevocationExecution.Green `
        -YellowThreshold $thresholds.RevocationExecution.Yellow

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "$revocationProvisioned of $revocationTotal remediated ($revocationExecutionRate%)"
    $stepResults['Revocations'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 4: $detail [$kpi3Status]" -ForegroundColor $(if ($kpi3Status -eq 'Green') { 'Green' } elseif ($kpi3Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['Revocations'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 4: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Revocations KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'RevocationError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 5: KPI 4 - Remediation SLA + Aging Buckets

Write-Host '  Step 5: KPI 4 - Remediation Timeliness' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    $slaComplianceRate = $revocationExecutionRate

    # Compute aging buckets from remediation proof data (pending items only)
    $now = [datetime]::UtcNow
    foreach ($item in $allRemediationProof) {
        if ($item.RemediationComplete) { continue }
        $decDate = [datetime]::MinValue
        if (-not [datetime]::TryParse($item.DecisionDate, [ref]$decDate)) { continue }
        $ageHours = ($now - $decDate.ToUniversalTime()).TotalHours
        $bucket = if ($ageHours -le 24)  { '0-24h' }
                  elseif ($ageHours -le 48)  { '24-48h' }
                  elseif ($ageHours -le 120) { '2-5d' }
                  elseif ($ageHours -le 240) { '5-10d' }
                  else { '>10d' }
        $agingBuckets[$bucket]++
        $agingDetails.Add([PSCustomObject]@{
            IdentityName    = $item.IdentityName
            EntitlementName = $item.AccessName
            DecisionDate    = $item.DecisionDate
            Status          = 'Pending'
            AgeHours        = [math]::Round($ageHours, 1)
            AgeBucket       = $bucket
        })
    }

    # Additional RED trigger: any item in >10d bucket or 5+ items in 5-10d
    $hasAgingCrisis = ($agingBuckets['>10d'] -gt 0) -or ($agingBuckets['5-10d'] -ge 5)

    $kpi4Status = Get-KpiStatus -Value $slaComplianceRate `
        -GreenThreshold $thresholds.RemediationSla.Green `
        -YellowThreshold $thresholds.RemediationSla.Yellow
    if ($hasAgingCrisis -and $kpi4Status -ne 'Red') {
        $kpi4Status = 'Red'
    }

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $pendingTotal = ($agingBuckets.Values | Measure-Object -Sum).Sum
    $detail = "SLA: $slaComplianceRate%, $pendingTotal pending remediation(s)"
    if ($hasAgingCrisis) { $detail += ' [aging crisis]' }
    $stepResults['RemediationSla'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 5: $detail [$kpi4Status]" -ForegroundColor $(if ($kpi4Status -eq 'Green') { 'Green' } elseif ($kpi4Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['RemediationSla'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 5: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Remediation SLA KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'SlaError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 6: KPI 5 - High-Risk Exposure

Write-Host '  Step 6: KPI 5 - High-Risk Exposure' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    if ($campaignAudits.Count -gt 0) {
        $identityRiskData = Measure-SPIdentityRisk -CampaignAudits $campaignAudits `
            -HighRiskThreshold $HighRiskThreshold -CorrelationID $correlationID
    }

    # Cross-reference: high-risk identities with pending reviews
    if ($null -ne $identityRiskData -and $null -ne $identityRiskData.Identities) {
        $highRiskIds = @{}
        foreach ($identity in $identityRiskData.Identities) {
            if ($identity.RiskTier -eq 'High') { $highRiskIds[$identity.IdentityId] = $identity }
        }

        foreach ($audit in $campaignAudits) {
            $d = $audit['Decisions']
            if ($null -eq $d -or $null -eq $d['Pending']) { continue }
            foreach ($pending in @($d['Pending'])) {
                $pId = $pending.IdentityId
                if ($null -ne $pId -and $highRiskIds.ContainsKey($pId)) {
                    $highRiskPending.Add([PSCustomObject]@{
                        IdentityId   = $pId
                        IdentityName = $pending.IdentityName
                        RiskScore    = $highRiskIds[$pId].RiskScore
                        AccessName   = $pending.AccessName
                        SourceName   = if ($null -ne $pending.SourceName) { $pending.SourceName } else { '' }
                        CampaignName = $audit['CampaignName']
                    })
                    $highRiskPendingIdentityIds[$pId] = $true
                }
            }
        }
    }

    $highRiskPendingCount = $highRiskPendingIdentityIds.Count
    $kpi5Status = Get-KpiStatusInverse -Value $highRiskPendingCount `
        -GreenMax $thresholds.HighRiskPending.Green `
        -YellowMax $thresholds.HighRiskPending.Yellow

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "$highRiskPendingCount high-risk identities with undecided reviews ($($highRiskPending.Count) items)"
    $stepResults['HighRiskExposure'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 6: $detail [$kpi5Status]" -ForegroundColor $(if ($kpi5Status -eq 'Green') { 'Green' } elseif ($kpi5Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['HighRiskExposure'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 6: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "High-risk exposure KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'HighRiskError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 7: KPI 6 - Reviewer Health

Write-Host '  Step 7: KPI 6 - Reviewer Health' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    if ($campaignAudits.Count -gt 0) {
        $reviewerReputationData = Measure-SPReviewerReputation -CampaignAudits $campaignAudits `
            -MinCampaigns 1 -CorrelationID $correlationID
    }

    $reviewerAtRiskCount = 0
    $reviewerTotalCount  = 0
    $rubberStampTotal    = 0
    if ($null -ne $reviewerReputationData -and $null -ne $reviewerReputationData.Summary) {
        $reviewerTotalCount  = if ($null -ne $reviewerReputationData.Summary.TotalReviewers) { $reviewerReputationData.Summary.TotalReviewers } else { 0 }
        $reviewerAtRiskCount = if ($null -ne $reviewerReputationData.Summary.AtRisk) { $reviewerReputationData.Summary.AtRisk } else { 0 }
    }

    # Count rubber-stamp flags from audit data
    foreach ($audit in $campaignAudits) {
        $rs = $audit['RubberStampRisk']
        if ($null -ne $rs -and $null -ne $rs.FlaggedReviewers) {
            $rubberStampTotal += @($rs.FlaggedReviewers).Count
        }
    }

    $goodStandingCount = $reviewerTotalCount - $reviewerAtRiskCount
    $reviewerHealthPct = if ($reviewerTotalCount -gt 0) { [math]::Round(($goodStandingCount / $reviewerTotalCount) * 100, 0) } else { 100 }

    $kpi6Status = Get-KpiStatusInverse -Value $reviewerAtRiskCount `
        -GreenMax $thresholds.ReviewerHealth.GreenMaxAtRisk `
        -YellowMax $thresholds.ReviewerHealth.YellowMaxAtRisk

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "$goodStandingCount of $reviewerTotalCount in good standing ($reviewerHealthPct%)"
    if ($rubberStampTotal -gt 0) { $detail += ", $rubberStampTotal rubber-stamp flag(s)" }
    $stepResults['ReviewerHealth'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 7: $detail [$kpi6Status]" -ForegroundColor $(if ($kpi6Status -eq 'Green') { 'Green' } elseif ($kpi6Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['ReviewerHealth'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 7: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Reviewer health KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'ReviewerHealthError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 8: Governance Confidence Score

Write-Host '  Step 8: Governance Confidence Score' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    $maturityParams = @{ CorrelationID = $correlationID }
    if ($null -ne $identityRiskData)       { $maturityParams['IdentityRisk']       = $identityRiskData }
    if ($null -ne $reviewerReputationData) { $maturityParams['ReviewerReputation']  = $reviewerReputationData }
    if ($null -ne $campaignMetricsData -and $campaignMetricsData.Success) { $maturityParams['CampaignMetrics'] = $campaignMetricsData }
    $governanceMaturityData = Measure-SPGovernanceMaturity @maturityParams

    if ($null -ne $governanceMaturityData) {
        $confidenceScore = if ($governanceMaturityData.ContainsKey('OverallScore')) { $governanceMaturityData['OverallScore'] } else { 0 }
        $confidenceLevel = if ($governanceMaturityData.ContainsKey('OverallLevel')) { $governanceMaturityData['OverallLevel'] } else { 'N/A' }
    }

    # Map score to grade
    $confidenceGrade = if ($confidenceScore -ge $confidenceGrades.A) { 'A' }
                       elseif ($confidenceScore -ge $confidenceGrades.B) { 'B' }
                       elseif ($confidenceScore -ge $confidenceGrades.C) { 'C' }
                       elseif ($confidenceScore -ge $confidenceGrades.D) { 'D' }
                       else { 'F' }

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "Score: $confidenceScore, Grade: $confidenceGrade, Level: $confidenceLevel"
    $stepResults['ConfidenceScore'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 8: $detail" -ForegroundColor $(if ($confidenceGrade -in @('A','B')) { 'Green' } elseif ($confidenceGrade -eq 'C') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['ConfidenceScore'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 8: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Confidence score exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'ConfidenceError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 9: Trend Data

$trendData = $null
try {
    $trendData = Get-SPGovernanceMetricsTrend -DaysBack 30 -Granularity Daily -CorrelationID $correlationID
}
catch {
    Write-Host "  WARN: Trend data unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
}

#endregion

#region KPI Summary & Domino Chain

# Helper: get trend direction
function Get-TrendArrow {
    param([string]$MetricName, $TrendResult)
    if ($null -eq $TrendResult -or $null -eq $TrendResult.Trends) { return @{ Arrow = ''; Delta = '' } }
    if (-not $TrendResult.Trends.Contains($MetricName)) { return @{ Arrow = ''; Delta = '' } }
    $mt = $TrendResult.Trends[$MetricName]
    $periods = @($mt.Periods)
    if ($periods.Count -lt 2) { return @{ Arrow = ''; Delta = '' } }
    $prev = $periods[$periods.Count - 2].Avg
    $curr = $periods[$periods.Count - 1].Avg
    if ($prev -eq 0) { return @{ Arrow = ''; Delta = '' } }
    $delta = [math]::Round($curr - $prev, 1)
    $sign = if ($delta -ge 0) { '+' } else { '' }
    $arrow = if ($delta -gt 0) { 'up' } elseif ($delta -lt 0) { 'down' } else { 'flat' }
    return @{ Arrow = $arrow; Delta = "$sign$delta" }
}

# Build KPI summary
$revExecDisplay = if ($revocationTotal -gt 0) { "$revocationExecutionRate%" } else { 'N/A (0 revocations)' }
$reviewerDisplay = if ($reviewerTotalCount -gt 0) { "$reviewerHealthPct%" } else { 'N/A' }

$kpiSummary = @(
    @{
        Name = 'Campaign Completion'; Value = "$avgCompletionRate%"; Status = $kpi1Status
        Detail = "$totalDecided of $totalItems decided"
        TrendMetric = 'campaigns.avgApprovalRate'
    }
    @{
        Name = 'Past-Due Reviews'; Value = $totalOverdueAtRisk; Status = $kpi2Status
        Detail = "$overdueCount overdue, $atRiskCount at-risk"
        TrendMetric = ''
    }
    @{
        Name = 'Revocations Executed'; Value = $revExecDisplay; Status = $kpi3Status
        Detail = "$revocationProvisioned of $revocationTotal provisioned"
        TrendMetric = ''
    }
    @{
        Name = 'Remediation Timeliness'; Value = "$slaComplianceRate%"; Status = $kpi4Status
        Detail = "$($agingDetails.Count) pending remediation(s)"
        TrendMetric = ''
    }
    @{
        Name = 'High-Risk Exposure'; Value = $highRiskPendingCount; Status = $kpi5Status
        Detail = "$($highRiskPending.Count) high-risk undecided items"
        TrendMetric = 'identityRisk.avgScore'
    }
    @{
        Name = 'Reviewer Health'; Value = $reviewerDisplay; Status = $kpi6Status
        Detail = "$goodStandingCount of $reviewerTotalCount in good standing"
        TrendMetric = 'reviewers.avgScore'
    }
)

# Domino chain: Reviewer -> Completion -> Overdue -> Revocations -> Remediation -> Risk
$dominoChain = @(
    @{ Name = 'Reviewer';    ShortName = 'Reviewer';  Status = $kpi6Status }
    @{ Name = 'Completion';  ShortName = 'Complete';   Status = $kpi1Status }
    @{ Name = 'Overdue';     ShortName = 'Overdue';    Status = $kpi2Status }
    @{ Name = 'Revocations'; ShortName = 'Revoke';     Status = $kpi3Status }
    @{ Name = 'Remediation'; ShortName = 'Remediate';  Status = $kpi4Status }
    @{ Name = 'Risk';        ShortName = 'Risk';       Status = $kpi5Status }
)

# Walk left to right for cascade detection
$dominoWorstUpstream = 'Green'
$dominoCascadeStart  = -1
$statusOrder = @{ 'Green' = 0; 'Yellow' = 1; 'Red' = 2 }
foreach ($i in 0..($dominoChain.Count - 1)) {
    $box = $dominoChain[$i]
    $boxSeverity = $statusOrder[$box.Status]

    if ($boxSeverity -gt $statusOrder[$dominoWorstUpstream]) {
        $dominoWorstUpstream = $box.Status
        if ($dominoCascadeStart -eq -1) { $dominoCascadeStart = $i }
    }

    $box['CascadeHighlight'] = ($dominoCascadeStart -ge 0 -and $i -gt $dominoCascadeStart -and $dominoWorstUpstream -ne 'Green')
}

# Domino narrative
$dominoWorstStatus = $dominoWorstUpstream
$dominoNarrative = 'All governance areas are operating within target thresholds.'
if ($dominoWorstStatus -ne 'Green' -and $dominoCascadeStart -ge 0) {
    $triggerName = $dominoChain[$dominoCascadeStart].Name
    $downstreamNames = @()
    foreach ($i in ($dominoCascadeStart + 1)..($dominoChain.Count - 1)) {
        if ($dominoChain[$i]['CascadeHighlight']) {
            $downstreamNames += $dominoChain[$i].Name
        }
    }
    if ($downstreamNames.Count -gt 0) {
        $downstreamStr = $downstreamNames -join ' and '
        $dominoNarrative = "$triggerName is below target, which may impact downstream $downstreamStr performance."
    }
    else {
        $dominoNarrative = "$triggerName is below target; monitor downstream areas for potential impact."
    }
}

# Collect source names from decision data for Sources in Scope section
$sourceCountMap = [ordered]@{}
foreach ($audit in $campaignAudits) {
    $d = $audit['Decisions']
    if ($null -eq $d) { continue }
    foreach ($cat in @('Approved', 'Revoked', 'Pending')) {
        if ($null -ne $d[$cat]) {
            foreach ($item in @($d[$cat])) {
                $src = if ($null -ne $item.SourceName -and -not [string]::IsNullOrWhiteSpace($item.SourceName)) { $item.SourceName } else { 'Unknown' }
                if (-not $sourceCountMap.Contains($src)) { $sourceCountMap[$src] = 0 }
                $sourceCountMap[$src]++
            }
        }
    }
}

#endregion

#region Output

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# --- Console output ---
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host ''
    Write-Host '  === Daily Evidence Report ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Governance Confidence: $confidenceGrade ($confidenceScore/100)" -ForegroundColor $(
        if ($confidenceGrade -in @('A','B')) { 'Green' }
        elseif ($confidenceGrade -eq 'C') { 'Yellow' }
        else { 'Red' }
    )
    Write-Host ''
    Write-Host '  --- KPI Dashboard ---' -ForegroundColor Cyan

    foreach ($kpi in $kpiSummary) {
        $statusTag   = "[$($kpi.Status.ToUpper())]"
        $nameDisplay = ($kpi.Name + ':').PadRight(26)
        $valueDisplay = ([string]$kpi.Value).PadRight(8)
        $color = switch ($kpi.Status) {
            'Green'  { 'Green' }
            'Yellow' { 'Yellow' }
            'Red'    { 'Red' }
            default  { 'Gray' }
        }
        Write-Host "    $($statusTag.PadRight(8)) $nameDisplay $valueDisplay ($($kpi.Detail))" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '  --- Domino Chain ---' -ForegroundColor Cyan
    $chainStr = ''
    foreach ($i in 0..($dominoChain.Count - 1)) {
        $box = $dominoChain[$i]
        $letter = $box.Status.Substring(0, 1)
        $cascade = if ($box['CascadeHighlight']) { '*' } else { '' }
        if ($i -gt 0) { $chainStr += ' -> ' }
        $chainStr += "$($box.ShortName)[$letter]$cascade"
    }
    Write-Host "    $chainStr"
    Write-Host "    Note: $dominoNarrative"
    Write-Host ''
    Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray
    Write-Host "  Output: $effectiveOutputPath" -ForegroundColor DarkGray
    Write-Host ''
}

# --- HTML output ---
if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    $sb = [System.Text.StringBuilder]::new()
# ===================== Daily Evidence v4 builder =====================
$fmtDt = {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return '-' }
    try { return ([datetime]::Parse($s)).ToString('yyyy-MM-dd HH:mm') } catch { return $s }
}
$remDone = {
    param($st)
    if ($null -eq $st) { return $false }
    return ([string]$st -match 'Provision|Removed|Complete|Deprovision|Done')
}
$donut = {
    param($ap, $rp, $pp, $tot)
    if ($tot -le 0) { return '<div style="color:#999;font-size:11px;padding:48px 0">No items</div>' }
    $o2 = -$ap
    $o3 = -([math]::Round($ap + $rp, 1))
    $ar1 = [math]::Round(100 - $ap, 1); $ar2 = [math]::Round(100 - $rp, 1); $ar3 = [math]::Round(100 - $pp, 1)
    $tf = '{0:N0}' -f $tot
    return @"
<svg width="140" height="140" viewBox="0 0 42 42" style="display:block;margin:0 auto">
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#e0e0e0" stroke-width="3.2"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#339933" stroke-width="3.2" stroke-dasharray="$ap $ar1" stroke-dashoffset="0" transform="rotate(-90 21 21)"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#CC3333" stroke-width="3.2" stroke-dasharray="$rp $ar2" stroke-dashoffset="$o2" transform="rotate(-90 21 21)"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#FF8800" stroke-width="3.2" stroke-dasharray="$pp $ar3" stroke-dashoffset="$o3" transform="rotate(-90 21 21)"></circle>
<text x="21" y="19.5" text-anchor="middle" style="font-size:5px;font-weight:bold;fill:#2c3e50">$tf</text>
<text x="21" y="24" text-anchor="middle" style="font-size:2.8px;fill:#777">items</text>
</svg>
"@
}

# ---- aggregate scope + decision rollups ----
$usersSet = @{}; $entSet = @{}; $privUserSet = @{}; $mgrSet = @{}; $srcSet = @{}
# CertificationId -> { Name (the manager/certifier), SignOff (signed/completed date) }. The
# per-item reviewedBy/decisionDate are often empty on real ISC items; the reviewer + a
# signoff-date fallback live on the certification, so resolve them here for the Decision Summary.
$certReviewerMap = @{}
# Aggregate counts use counters for Approved/Pending (only need .Count).
# Revoked items are stored in a list because the Decision Summary iterates them.
$allApprovedCount = 0
$allRevoked = [System.Collections.Generic.List[object]]::new()
$allPendingCount = 0
foreach ($audit in $campaignAudits) {
    $d = $audit['Decisions']
    foreach ($grp in @('Approved', 'Revoked', 'Pending')) {
        foreach ($it in @($d[$grp])) {
            if ($null -eq $it) { continue }
            $iid = if ($it.PSObject.Properties['IdentityId'] -and $it.IdentityId) { [string]$it.IdentityId } else { [string]$it.IdentityName }
            if ($iid) { $usersSet[$iid] = $true }
            $aid = if ($it.PSObject.Properties['AccessId'] -and $it.AccessId) { [string]$it.AccessId } else { [string]$it.AccessName }
            if ($aid) { $entSet[$aid] = $true }
            $src = [string]$it.SourceName
            if ($src) { $srcSet[$src] = $true }
            $isPriv = $false; try { $isPriv = [bool]$it.Privileged } catch { }
            if ($isPriv -and $iid) { $privUserSet[$iid] = $true }
            switch ($grp) { 'Approved' { $allApprovedCount++ } 'Revoked' { $allRevoked.Add($it) } default { $allPendingCount++ } }
        }
    }
    foreach ($cert in @($audit['Certifications'])) {
        if ($null -eq $cert -or $null -eq $cert.reviewer) { continue }
        $rvId = ''
        if ($cert.reviewer.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace($cert.reviewer.id)) {
            $rvId = [string]$cert.reviewer.id
        } elseif ($cert.reviewer.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace($cert.reviewer.name)) {
            $rvId = [string]$cert.reviewer.name
        }
        if ($rvId) { $mgrSet[$rvId] = $true }
    }
    foreach ($cert in @($audit['Certifications'])) {
        if ($null -eq $cert) { continue }
        $cid = if ($cert.PSObject.Properties['id'] -and $cert.id) { [string]$cert.id } else { '' }
        if (-not $cid -or $certReviewerMap.ContainsKey($cid)) { continue }
        $rn = ''
        if ($cert.PSObject.Properties['reviewer'] -and $null -ne $cert.reviewer -and $cert.reviewer.PSObject.Properties['name'] -and $cert.reviewer.name) { $rn = [string]$cert.reviewer.name }
        $sd = ''
        if ($cert.PSObject.Properties['signed'] -and -not [string]::IsNullOrWhiteSpace([string]$cert.signed)) { $sd = [string]$cert.signed }
        elseif ($cert.PSObject.Properties['completed'] -and -not [string]::IsNullOrWhiteSpace([string]$cert.completed)) { $sd = [string]$cert.completed }
        $certReviewerMap[$cid] = @{ Name = $rn; SignOff = $sd }
    }
}
$aggAppr = $allApprovedCount; $aggRev = $allRevoked.Count; $aggPend = $allPendingCount
$aggTotal = $aggAppr + $aggRev + $aggPend
$aggDecided = $aggAppr + $aggRev
$aggPct = if ($aggTotal -gt 0) { [math]::Round($aggDecided / $aggTotal * 100, 0) } else { 0 }
$activeCount = @($campaignAudits | Where-Object { ([string]$_['Status']).ToUpperInvariant() -notin @('COMPLETED', 'COMPLETING') }).Count
$genStr = $startTime.ToString('yyyy-MM-dd HH:mm')
$envName2 = ''
if ($null -ne $config.PSObject.Properties['Environment'] -and -not [string]::IsNullOrWhiteSpace($config.Environment)) { $envName2 = ' | Env: ' + (ConvertTo-SafeHtml $config.Environment) }

# ---- HEAD + CSS ----
[void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
[void]$sb.AppendLine('<title>Daily Evidence Report - ' + (ConvertTo-SafeHtml $todayLabel) + '</title>')
[void]$sb.AppendLine('<style>')
[void]$sb.AppendLine(@'
*{box-sizing:border-box}
body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}
.container{max-width:1100px;margin:0 auto}
.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}
.header h1{margin:0 0 6px;font-size:22px}.header .meta{font-size:12px;opacity:.85}
.header .status-line{margin-top:8px;font-size:13px;opacity:.9}
.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}
.section h2{color:#264d73;font-size:15px;border-bottom:2px solid #e8eef5;padding-bottom:6px;margin-top:0}
.scope-inline{display:flex;flex-wrap:wrap;gap:12px 26px;font-size:13px;color:#555;margin-top:4px}
.scope-inline .n{font-size:22px;font-weight:700;color:#264d73;display:block;line-height:1.1}
.scope-inline .t{font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:#777}
.execbox{background:#f8f9fa;border:1px solid #e0e0e0;border-top:none;padding:20px 32px;font-family:-apple-system,'Segoe UI',system-ui,sans-serif}
.execbox h3{color:#2c3e50;margin:0 0 16px;font-size:16px;border-bottom:2px solid #336699;padding-bottom:6px}
table.report{border-collapse:collapse;width:100%;margin:12px 0;font-size:12px}
table.report th{background:#e8eef5;padding:8px 10px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;color:#555}
table.report td{padding:7px 10px;border-bottom:1px solid #eee}table.report tr:nth-child(even){background:#fafafa}
.s-green{color:#339933;font-weight:600}.s-amber{color:#9a6700;font-weight:600}.s-red{color:#CC3333;font-weight:600}.s-gray{color:#777}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}
.badge-priv{background:#ffcdd2;color:#b71c1c}
summary{cursor:pointer}
.subhead{font-size:13px;color:#264d73;margin:16px 0 4px;font-weight:bold}
.footer{text-align:center;color:#999;font-size:11px;padding:16px;border-top:1px solid #eee}
.section:last-of-type{border-radius:0 0 8px 8px}
@media print{body{background:#fff;padding:0}.container{max-width:100%}.header{border-radius:0}}
'@)
[void]$sb.AppendLine('</style></head><body><div class="container">')

# ---- HEADER ----
[void]$sb.AppendLine('<div class="header">')
[void]$sb.AppendLine('<h1>Daily Evidence Report</h1>')
[void]$sb.AppendLine('<div class="meta">SailPoint ISC Governance Toolkit | Report generated: ' + (ConvertTo-SafeHtml $genStr) + ' | Period: Last ' + $effectiveDaysBack + ' day(s)' + $envName2 + '</div>')
$cachedCampaigns = @($campaignAudits | Where-Object { $_['ItemsFromCache'] -eq $true })
$cacheNote = if ($NoCache) { ' | Items: fresh (no-cache mode)' } elseif ($cachedCampaigns.Count -gt 0) { " | Items: $($cachedCampaigns.Count) of $($campaignAudits.Count) from cache" } else { ' | Items: all fresh' }
[void]$sb.AppendLine('<div class="status-line">' + ('{0:N0}' -f $aggDecided) + ' / ' + ('{0:N0}' -f $aggTotal) + ' decisions made (' + $aggPct + '%) &middot; ' + $activeCount + ' active campaign(s)' + (ConvertTo-SafeHtml $cacheNote) + '</div>')
[void]$sb.AppendLine('</div>')

# ---- Certification Scope ----
[void]$sb.AppendLine('<div class="section"><h2>Certification Scope</h2><div class="scope-inline">')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $usersSet.Count) + '</span><span class="t">distinct users reviewed</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $entSet.Count) + '</span><span class="t">entitlements tracked</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $privUserSet.Count) + '</span><span class="t">privileged-access users</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + $mgrSet.Count + '</span><span class="t">reviewers involved</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + $srcSet.Count + '</span><span class="t">sources evaluated</span></div>')
[void]$sb.AppendLine('</div></div>')

# ---- Per-campaign Executive Summary ----
foreach ($audit in $campaignAudits) {
    $cName = ConvertTo-SafeHtml $audit['CampaignName']
    $cStatusRaw = ([string]$audit['Status']).ToUpperInvariant()
    $cStatusUp = ConvertTo-SafeHtml $cStatusRaw
    $d = $audit['Decisions']
    $appr = @($d['Approved']).Count; $rev = @($d['Revoked']).Count; $pend = @($d['Pending']).Count
    $tot = $appr + $rev + $pend; $decided = $appr + $rev
    $pct = if ($tot -gt 0) { [math]::Round($decided / $tot * 100, 0) } else { 0 }
    $apct = if ($tot -gt 0) { [math]::Round($appr / $tot * 100, 1) } else { 0 }
    $rpct = if ($tot -gt 0) { [math]::Round($rev / $tot * 100, 1) } else { 0 }
    $ppct = if ($tot -gt 0) { [math]::Round($pend / $tot * 100, 1) } else { 0 }
    if ($tot -gt 0 -and ($apct + $rpct + $ppct) -ne 100) { $apct = [math]::Round(100 - $rpct - $ppct, 1) }
    $ra = $audit['ReviewerActions']
    $primary = if ($null -ne $ra -and $null -ne $ra['Primary']) { @($ra['Primary']) } else { @() }
    $reassigned = if ($null -ne $ra -and $null -ne $ra['Reassigned']) { @($ra['Reassigned']) } else { @() }
    $allRevw = @($primary) + @($reassigned)
    $signed = @($allRevw | Where-Object { $_.Phase -eq 'SIGNED' }).Count
    $totRev = @($allRevw).Count
    $revCompPct = if ($totRev -gt 0) { [math]::Round($signed / $totRev * 100, 0) } else { 0 }
    $reassignCnt = @($reassigned).Count
    $revItems = @($d['Revoked'])
    $totRevoked = $revItems.Count
    # Source-aware split: 'Removed' = revoke completed on a connected AD source (truly de-provisioned);
    # 'Queued' = revoke completed on a disconnected/other source (recorded, removal not confirmed);
    # remainder = pending. The deprovision rate counts ONLY confirmed AD removals.
    $removed = @($revItems | Where-Object { ([string]$_.RemediationDisposition) -eq 'Removed' }).Count
    $queued  = @($revItems | Where-Object { ([string]$_.RemediationDisposition) -eq 'Queued' }).Count
    $remPend = $totRevoked - $removed - $queued
    if ($remPend -lt 0) { $remPend = 0 }
    $remPct = if ($totRevoked -gt 0) { [math]::Round($removed / $totRevoked * 100, 0) } else { 0 }
    $qPct   = if ($totRevoked -gt 0) { [math]::Round($queued / $totRevoked * 100, 0) } else { 0 }
    $remPendPct = 100 - $remPct - $qPct; if ($remPendPct -lt 0) { $remPendPct = 0 }
    $stColor = switch ($cStatusRaw) { 'COMPLETED' { '#339933' } 'COMPLETING' { '#339933' } default { '#336699' } }
    $revCompColor = if ($revCompPct -ge 100) { '#339933' } elseif ($revCompPct -ge 50) { '#FF9900' } else { '#CC3333' }
    $pendColor = if ($pend -eq 0) { '#339933' } else { '#FF9900' }
    $remColor = if ($totRevoked -eq 0) { '#777777' } elseif ($remPct -ge 100) { '#339933' } elseif ($remPct -ge 50) { '#FF9900' } else { '#CC3333' }
    $donutSvg = & $donut $apct $rpct $ppct $tot
    $createdFmt = & $fmtDt ([string]$audit['Created'])
    if ($totRevoked -gt 0) {
        $remBlock = @"
<div style="text-align:center;margin-bottom:10px"><span style="font-size:36px;font-weight:bold;color:$remColor">$remPct%</span><br><span style="font-size:12px;color:#777">$removed of $totRevoked deprovisioned (connected AD)</span></div>
<table style="width:100%;border-collapse:collapse;height:18px;margin-bottom:6px"><tr><td style="width:$remPct%;background:#339933;height:18px;border-radius:4px 0 0 4px"></td><td style="width:$qPct%;background:#336699;height:18px"></td><td style="width:$remPendPct%;background:#FF8800;height:18px;border-radius:0 4px 4px 0"></td></tr></table>
<table style="width:100%;font-size:11px;border-collapse:collapse"><tr><td style="color:#339933;font-weight:bold;padding:2px 0">$removed Deprovisioned</td><td style="color:#264d73;font-weight:bold;text-align:center;padding:2px 0">$queued Queued</td><td style="color:#FF8800;font-weight:bold;text-align:right;padding:2px 0">$remPend Pending</td></tr></table>
<p style="font-size:10px;color:#999;margin:6px 0 0;text-align:center;font-style:italic">Deprovisioned = revoke completed on a connected Active Directory source. Queued = revoke recorded on a disconnected / other source; actual removal is fulfilled downstream and not confirmed here.</p>
"@
    }
    else {
        $remBlock = '<div style="text-align:center;color:#777;font-size:13px;padding:18px 0">No revocations in this campaign.</div>'
    }
    $execHtml = @"
<div class="execbox">
<h3>Executive Summary &mdash; $cName</h3>
<table style="width:100%;border-collapse:collapse;margin-bottom:18px"><tr>
<td style="width:50%;vertical-align:top;padding-right:16px">
<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr><td colspan="2" style="padding:12px 16px;background:$stColor;border-radius:6px;text-align:center"><span style="color:#fff;font-size:22px;font-weight:bold;letter-spacing:1px">$cStatusUp</span></td></tr>
<tr>
<td style="padding:10px 4px;text-align:center;color:#555;font-size:12px"><span style="font-weight:bold;font-size:16px;color:#2c3e50">$signed / $totRev</span><br>Reviewers Signed Off</td>
<td style="padding:10px 4px;text-align:center;color:#555;font-size:12px"><span style="font-weight:bold;font-size:16px;color:#2c3e50">$('{0:N0}' -f $decided) / $('{0:N0}' -f $tot)</span><br>Items Decided ($pct%)</td>
</tr>
</table>
</td>
<td style="width:50%;vertical-align:top;padding-left:16px">
<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr><td style="padding:6px 8px;font-weight:bold;color:#555;width:120px">Campaign</td><td style="padding:6px 8px;color:#2c3e50">$cName</td></tr>
<tr><td style="padding:6px 8px;font-weight:bold;color:#555">Created</td><td style="padding:6px 8px;color:#2c3e50">$createdFmt</td></tr>
<tr><td style="padding:6px 8px;font-weight:bold;color:#555">Reviewers</td><td style="padding:6px 8px;color:#2c3e50">$totRev ($($primary.Count) primary, $reassignCnt reassigned)</td></tr>
</table>
</td>
</tr></table>
<table style="width:100%;border-collapse:collapse"><tr>
<td style="width:33%;vertical-align:top;padding-right:12px;text-align:center">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Decision Distribution</p>
$donutSvg
<table style="margin:8px auto 0;font-size:11px;border-collapse:collapse">
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#339933"/></svg></td><td style="padding:2px 6px;color:#555">Approved: $('{0:N0}' -f $appr) ($apct%)</td></tr>
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#CC3333"/></svg></td><td style="padding:2px 6px;color:#555">Revoked: $('{0:N0}' -f $rev) ($rpct%)</td></tr>
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#FF8800"/></svg></td><td style="padding:2px 6px;color:#555">Undecided: $('{0:N0}' -f $pend) ($ppct%)</td></tr>
</table>
</td>
<td style="width:34%;vertical-align:top;padding:0 12px">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Revoked Access &mdash; Removal Status</p>
$remBlock
</td>
<td style="width:33%;vertical-align:top;padding-left:12px">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Key Indicators</p>
<table style="width:100%;border-collapse:collapse;font-size:12px">
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;width:20px"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$revCompColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Reviewer Completion</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$revCompColor">$revCompPct%</td></tr>
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$pendColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Pending Items</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$pendColor">$('{0:N0}' -f $pend)</td></tr>
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$remColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Deprovisioned (AD)</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$remColor">$remPct%</td></tr>
<tr><td style="padding:5px 4px"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#336699"/></svg></td><td style="padding:5px 4px;color:#555">Reassignments</td><td style="padding:5px 4px;font-weight:bold;text-align:right;color:#264d73">$reassignCnt</td></tr>
</table>
</td>
</tr></table>
</div>
"@
    [void]$sb.AppendLine($execHtml)
}

# ---- A. Campaign Completion Evidence ----
[void]$sb.AppendLine('<div class="section"><h2>A. Campaign Completion Evidence</h2>')
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Approved</th><th>Revoked</th><th>Undecided</th><th>Items Decided %</th><th>Reviewer %</th><th>Created</th><th>Completed</th></tr></thead><tbody>')
foreach ($audit in $campaignAudits) {
    $cn = ConvertTo-SafeHtml $audit['CampaignName']
    $cs = ConvertTo-SafeHtml ([string]$audit['Status'])
    $d = $audit['Decisions']
    $a = @($d['Approved']).Count; $r = @($d['Revoked']).Count; $p = @($d['Pending']).Count
    $t = $a + $r + $p; $dec = $a + $r
    $pc = if ($t -gt 0) { [math]::Round($dec / $t * 100, 0) } else { 0 }
    $pcCls = if ($pc -ge 80) { 's-green' } elseif ($pc -ge 50) { 's-amber' } else { 's-red' }
    # Reviewer completion: % of primary reviewers who have SIGNED
    # Reviewer completion: match executive summary -- Primary + Reassigned
    # Reviewer completion: item-level (honest), not cert Phase (ISC inflates on close).
    # Use per-campaign ReviewerRecords stored on the audit (not the loop variable which holds the last campaign).
    $rvPct = 0; $rvLabel = '-'
    $campReviewerRecs = if ($audit.ContainsKey('ReviewerRecords')) { @($audit['ReviewerRecords']) } else { @() }
    $rvCompletedCount2 = @($campReviewerRecs | Where-Object { [int]$_.total -gt 0 -and [int]$_.pending -eq 0 }).Count
    $rvTotalCount2 = @($campReviewerRecs).Count
    if ($rvTotalCount2 -gt 0) {
        $rvPct = [math]::Round($rvCompletedCount2 / $rvTotalCount2 * 100, 0)
        $rvLabel = "$rvPct% ($rvCompletedCount2/$rvTotalCount2)"
    }
    $rvCls = if ($rvPct -ge 80) { 's-green' } elseif ($rvPct -ge 50) { 's-amber' } else { 's-red' }
    $cr = & $fmtDt ([string]$audit['Created'])
    $cmp = & $fmtDt ([string]$audit['Completed'])
    [void]$sb.AppendLine("<tr><td>$cn</td><td>$cs</td><td>$('{0:N0}' -f $t)</td><td>$('{0:N0}' -f $a)</td><td class='s-red'>$('{0:N0}' -f $r)</td><td>$('{0:N0}' -f $p)</td><td class='$pcCls'>$pc%</td><td class='$rvCls'>$rvLabel</td><td>$cr</td><td>$cmp</td></tr>")
}
[void]$sb.AppendLine('</tbody></table></div>')

# ---- B. Reviewer Accountability (Undecided / Pending) ----
[void]$sb.AppendLine('<div class="section"><h2>B. Reviewer Accountability</h2>')
$anyRev = $false
foreach ($audit in $campaignAudits) {
    $ra = $audit['ReviewerActions']
    if ($null -eq $ra) { continue }
    $primary = if ($null -ne $ra['Primary']) { @($ra['Primary']) } else { @() }
    $reassigned = if ($null -ne $ra['Reassigned']) { @($ra['Reassigned']) } else { @() }
    if ($primary.Count -eq 0 -and $reassigned.Count -eq 0) { continue }
    $isCompleted = ([string]$audit['Status']).ToUpperInvariant() -in @('COMPLETED', 'COMPLETING')
    # Build a set of names whose certs were reassigned away -- they legitimately
    # show as signed because their items moved to the reassignee.
    $reassignedAwayNames = @{}
    foreach ($rr in $reassigned) {
        $rfName = ''
        if ($null -ne $rr.PSObject.Properties['ReassignedFrom']) { $rfName = [string]$rr.ReassignedFrom }
        if (-not [string]::IsNullOrWhiteSpace($rfName)) { $reassignedAwayNames[$rfName] = $true }
    }
    if ($isCompleted) {
        # COMPLETED campaigns: ISC lies about cert-level data (force-signs everyone,
        # inflates decisionsMade). But the ITEM data from cache tells the truth --
        # items that were PENDING when the cache was written are genuinely unreviewed.
        # Derive the pending reviewer list from the items, not from cert metadata.
        $d = $audit['Decisions']
        # Attribute undecided items to the cert-ASSIGNED reviewer (item.CertificationId ->
        # sealed/live roster), not item.reviewedBy (null for pending items, which used to
        # collapse every undecided item into a single (Unassigned) row). DECIDED items still
        # carry their reviewedBy attribution for the TotalCount context. (cache-honesty R0)
        $certRoster = if ($audit.ContainsKey('CertRoster')) { @($audit['CertRoster']) } else { @() }
        $pendingByReviewer = Group-SPCompletedPendingByReviewer `
            -PendingItems @($d['Pending']) `
            -DecidedItems (@($d['Approved']) + @($d['Revoked'])) `
            -Roster $certRoster `
            -PrimaryReviewers $primary `
            -ReassignedAwayNames $reassignedAwayNames
        $pendingR = @($pendingByReviewer.Values | Sort-Object { $_.Name })
        if ($pendingR.Count -eq 0 -and $reassigned.Count -eq 0) { continue }
        $anyRev = $true
        [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml $audit['CampaignName']) + '</div>')
        # WI-4 (G1): visible provenance banner. When the campaign was sealed WITHOUT a
        # prior ACTIVE-state capture, the COMPLETED item data is ISC post-completion data
        # being trusted without an honest snapshot -- mark the completion unverified.
        $capActive = if ($audit.ContainsKey('CaptureCapturedWhileActive')) { [bool]$audit['CaptureCapturedWhileActive'] } else { $false }
        if (-not $capActive) { [void]$sb.AppendLine('<div class="s-red" style="border:1px solid #c0392b;background:#fdecea;padding:6px 8px;margin:4px 0;font-size:12px;font-weight:600">&#9888; No active-state capture -- completion unverified. ISC post-completion data is being trusted without a sealed ACTIVE-state snapshot.</div>') }
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:12px;margin-bottom:4px'>Undecided Items by Reviewer ($($pendingR.Count) reviewer(s) with undecided items)</summary>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th style="text-align:right">Undecided Items</th><th style="text-align:right">Total Items</th><th>Note</th></tr></thead><tbody>')
        if ($pendingR.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="5" style="color:#777;font-style:italic">No undecided items found (all items were decided before close).</td></tr>') }
        else { foreach ($rr in $pendingR) {
            $pCnt = $rr.PendingCount; $tCnt = $rr.TotalCount
            $phCls = if ($pCnt -eq $tCnt) { 's-red' } else { 's-amber' }
            $note = if ($pCnt -eq $tCnt) { 'No decisions made' } else { "$($tCnt - $pCnt) of $tCnt decided" }
            [void]$sb.AppendLine("<tr><td style='font-weight:600'>" + (ConvertTo-SafeHtml $rr.Name) + "</td><td>" + (ConvertTo-SafeHtml $rr.Email) + "</td><td style='text-align:right;font-weight:600' class='$phCls'>$pCnt</td><td style='text-align:right'>$tCnt</td><td>$note</td></tr>")
        } }
        [void]$sb.AppendLine('</tbody></table></details>')
    }
    else {
        # ACTIVE campaigns: use cert-level Phase to detect unsigned reviewers
        $pendingR = @($primary | Where-Object { $_.Phase -ne 'SIGNED' } | Sort-Object Name)
        if ($pendingR.Count -eq 0 -and $reassigned.Count -eq 0) { continue }
        $anyRev = $true
        [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml $audit['CampaignName']) + '</div>')
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:12px;margin-bottom:4px'>Undecided ($($pendingR.Count))</summary>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th>Certs Assigned</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th></tr></thead><tbody>')
        if ($pendingR.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">No undecided reviewers.</td></tr>') }
        else { foreach ($rr in $pendingR) {
            $phCls = if ([int]$rr.DecisionsMade -gt 0) { 's-amber' } else { 's-red' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $rr.Name) + '</td><td>' + (ConvertTo-SafeHtml $rr.Email) + '</td><td>' + $rr.CertsAssigned + '</td><td>' + [int]$rr.DecisionsMade + '</td><td>-</td><td class="' + $phCls + '">' + (ConvertTo-SafeHtml ([string]$rr.Phase)) + '</td></tr>')
        } }
        [void]$sb.AppendLine('</tbody></table></details>')
    }
    if ($reassigned.Count -gt 0) {
        [void]$sb.AppendLine('<details><summary style="font-weight:bold;font-size:12px;margin:8px 0 4px">Reassigned (' + $reassigned.Count + ')</summary>')
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th>Reassigned From</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th><th>Proof of Action</th></tr></thead><tbody>')
        foreach ($rr in @($reassigned | Sort-Object Name)) {
            $so = & $fmtDt ([string]$rr.SignOffDate)
            $proof = if ($rr.ProofOfAction) { '<span class="s-green">Yes</span>' } else { '<span class="s-red">No</span>' }
            $phCls2 = if ($rr.Phase -eq 'SIGNED') { 's-green' } else { 's-amber' }
            $rf = if ($rr.PSObject.Properties['ReassignedFrom']) { ConvertTo-SafeHtml $rr.ReassignedFrom } else { '' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $rr.Name) + '</td><td>' + (ConvertTo-SafeHtml $rr.Email) + '</td><td>' + $rf + '</td><td>' + $rr.DecisionsMade + '</td><td>' + (ConvertTo-SafeHtml $so) + '</td><td class="' + $phCls2 + '">' + (ConvertTo-SafeHtml ([string]$rr.Phase)) + '</td><td>' + $proof + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table></details>')
    }
}
if (-not $anyRev) { [void]$sb.AppendLine('<p style="color:#777">No undecided reviewer accountability data available.</p>') }
[void]$sb.AppendLine('</div>')

# ---- Decision Summary (Revoked only + Newly Approved Access from scope-diff) ----
[void]$sb.AppendLine('<div class="section"><h2>Decision Summary</h2>')

# -- Revoked subsection (kept as-is from v2) --
$revItems = @($allRevoked); $revCnt = $revItems.Count
[void]$sb.AppendLine("<details><summary class='s-red' style='font-size:13px;margin:12px 0 6px'>Revoked ($revCnt items)</summary>")
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Account</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th><th>Justification</th><th>Remediation</th></tr></thead><tbody>')
if ($revCnt -eq 0) { [void]$sb.AppendLine('<tr><td colspan="8" style="color:#777;font-style:italic">None.</td></tr>') }
else {
    # Sort revoked items by DecisionDate descending (most recent first)
    $revItems = @($revItems | Sort-Object @{ Expression = {
        $dd = if ($_.PSObject.Properties['DecisionDate']) { [string]$_.DecisionDate } else { '' }
        if ([string]::IsNullOrWhiteSpace($dd)) { [datetime]::MinValue } else { try { [datetime]::Parse($dd) } catch { [datetime]::MinValue } }
    } } -Descending)
    foreach ($it in $revItems) {
        $cid = if ($it.PSObject.Properties['CertificationId']) { [string]$it.CertificationId } else { '' }
        $just = 'N/A'
        if ($it.PSObject.Properties['Justification'] -and -not [string]::IsNullOrWhiteSpace($it.Justification)) { $just = [string]$it.Justification }
        $rem = '<span class="s-gray">N/A</span>'
        $disp = if ($it.PSObject.Properties['RemediationDisposition']) { [string]$it.RemediationDisposition } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($disp) -and $disp -ne 'NA') {
            $rsDisp = if ($it.PSObject.Properties['RemediationLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$it.RemediationLabel)) { [string]$it.RemediationLabel } else { $disp }
            $cls = switch ($disp) { 'Removed' { 's-green' } 'Queued' { 's-amber' } 'Pending' { 's-amber' } default { 's-gray' } }
            $rem = '<span class="' + $cls + '">' + (ConvertTo-SafeHtml $rsDisp) + '</span>'
        }
        $priv = $false; try { $priv = [bool]$it.Privileged } catch { }
        $pb = if ($priv) { ' <span class="badge badge-priv">PRIV</span>' } else { '' }
        $acct = if ($it.PSObject.Properties['AccountIdentifier']) { ConvertTo-SafeHtml $it.AccountIdentifier } else { '' }
        $rvwName = ''
        if ($it.PSObject.Properties['ReviewerName'] -and -not [string]::IsNullOrWhiteSpace([string]$it.ReviewerName) -and ([string]$it.ReviewerName) -ne 'N/A') { $rvwName = [string]$it.ReviewerName }
        elseif ($cid -and $certReviewerMap.ContainsKey($cid)) { $rvwName = [string]$certReviewerMap[$cid].Name }
        $rvw = ConvertTo-SafeHtml $rvwName
        $ddRaw = [string]$it.DecisionDate
        if ([string]::IsNullOrWhiteSpace($ddRaw) -and $cid -and $certReviewerMap.ContainsKey($cid)) { $ddRaw = [string]$certReviewerMap[$cid].SignOff }
        $dd = & $fmtDt $ddRaw
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $it.IdentityName) + '</td><td>' + $acct + '</td><td>' + (ConvertTo-SafeHtml $it.AccessName) + $pb + '</td><td>' + (ConvertTo-SafeHtml $it.SourceName) + '</td><td>' + $rvw + '</td><td>' + (ConvertTo-SafeHtml $dd) + '</td><td>' + (ConvertTo-SafeHtml $just) + '</td><td>' + $rem + '</td></tr>')
    }
}
[void]$sb.AppendLine('</tbody></table></details>')

# -- Newly Decided: Approved Since Prior Campaign (was PENDING, now APPROVED) --
$ndCnt = $v4NewlyDecided.Count
$ndLabel = if ($v4HasPrior) { "Newly Decided -- Approved Since Prior Campaign ($ndCnt items)" } else { "Newly Decided ($ndCnt items) -- no prior campaign for comparison" }
[void]$sb.AppendLine("<details><summary class='s-green' style='font-size:13px;margin:12px 0 6px'>$ndLabel</summary>")
[void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:2px 0 6px">Items that existed in both the current and prior campaign, were PENDING in the prior, and are now APPROVED. These represent reviewer decisions made since the last campaign.</p>')
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th><th>Privileged</th></tr></thead><tbody>')
if ($ndCnt -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">None.</td></tr>') }
else {
    $ndSorted = @($v4NewlyDecided | Sort-Object @{ Expression = {
        $dd = [string](Get-V4Prop $_ 'CurrDecisionDate' '')
        if ([string]::IsNullOrWhiteSpace($dd)) { [datetime]::MinValue } else { try { [datetime]::Parse($dd) } catch { [datetime]::MinValue } }
    } } -Descending)
    foreach ($nd in $ndSorted) {
        $ndIdent  = ConvertTo-SafeHtml ([string](Get-V4Prop $nd 'IdentityName' ''))
        $ndAccess = ConvertTo-SafeHtml ([string](Get-V4Prop $nd 'AccessName' ''))
        $ndSource = ConvertTo-SafeHtml ([string](Get-V4Prop $nd 'SourceName' ''))
        $ndReview = ConvertTo-SafeHtml ([string](Get-V4Prop $nd 'ReviewerName' ''))
        $ndDateRaw = [string](Get-V4Prop $nd 'CurrDecisionDate' '')
        $ndDate   = & $fmtDt $ndDateRaw
        $ndPriv   = $false; try { $ndPriv = [bool](Get-V4Prop $nd 'Privileged' $false) } catch { }
        $ndPrivBadge = if ($ndPriv) { '<span class="badge badge-priv">PRIV</span>' } else { '' }
        [void]$sb.AppendLine('<tr><td>' + $ndIdent + '</td><td>' + $ndAccess + '</td><td>' + $ndSource + '</td><td>' + $ndReview + '</td><td>' + (ConvertTo-SafeHtml $ndDate) + '</td><td>' + $ndPrivBadge + '</td></tr>')
    }
}
[void]$sb.AppendLine('</tbody></table></details>')

# -- New Scope: Approved Access subsection (truly new items not in prior campaign) --
$naCnt = $v4NewlyApproved.Count
$naLabel = if ($v4HasPrior) { "New Scope -- Approved Access ($naCnt items)" } else { "New Scope -- Approved Access ($naCnt items) -- no prior campaign snapshot available" }
[void]$sb.AppendLine("<details><summary class='s-green' style='font-size:13px;margin:12px 0 6px'>$naLabel</summary>")
if (-not $v4HasPrior) {
    [void]$sb.AppendLine('<p style="color:#777;font-size:12px;font-style:italic;margin:4px 0 8px">No prior campaign snapshot was found for comparison. Run the report again after a second campaign to see newly approved access.</p>')
}
[void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:2px 0 6px">Items that appeared in the current campaign scope but were NOT present in the prior campaign, and were approved.</p>')
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th><th>Privileged</th></tr></thead><tbody>')
if ($naCnt -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">None.</td></tr>') }
else {
    $naSorted = @($v4NewlyApproved | Sort-Object @{ Expression = {
        $dd = [string](Get-V4Prop $_ 'DecisionDate' '')
        if ([string]::IsNullOrWhiteSpace($dd)) { [datetime]::MinValue } else { try { [datetime]::Parse($dd) } catch { [datetime]::MinValue } }
    } } -Descending)
    foreach ($na in $naSorted) {
        $naIdent  = ConvertTo-SafeHtml ([string](Get-V4Prop $na 'IdentityName' ''))
        $naAccess = ConvertTo-SafeHtml ([string](Get-V4Prop $na 'AccessName' ''))
        $naSource = ConvertTo-SafeHtml ([string](Get-V4Prop $na 'SourceName' ''))
        $naReview = ConvertTo-SafeHtml ([string](Get-V4Prop $na 'ReviewerName' ''))
        $naDateRaw = [string](Get-V4Prop $na 'DecisionDate' '')
        $naDate   = & $fmtDt $naDateRaw
        $naPriv   = $false; try { $naPriv = [bool](Get-V4Prop $na 'Privileged' $false) } catch { }
        $naPrivBadge = if ($naPriv) { '<span class="badge badge-priv">PRIV</span>' } else { '' }
        [void]$sb.AppendLine('<tr><td>' + $naIdent + '</td><td>' + $naAccess + '</td><td>' + $naSource + '</td><td>' + $naReview + '</td><td>' + (ConvertTo-SafeHtml $naDate) + '</td><td>' + $naPrivBadge + '</td></tr>')
    }
}
[void]$sb.AppendLine('</tbody></table></details>')

[void]$sb.AppendLine('</div>')

# ---- Footer ----
[void]$sb.AppendLine('<div class="footer">SailPoint ISC Governance Toolkit &middot; Daily Evidence Report v4 &middot; Generated: ' + (ConvertTo-SafeHtml $genStr) + ' &middot; CorrelationID: ' + (ConvertTo-SafeHtml $correlationID) + ' &middot; ' + $campaignAudits.Count + ' campaign(s)</div>')
[void]$sb.AppendLine('</div></body></html>')
    $htmlContent = $sb.ToString()
    $freshTag = if ($NoCache) { '_fresh' } else { '' }
    $htmlFileName = 'daily-evidence-v4-{0}{1}.html' -f $startTime.ToString('yyyyMMdd-HHmmss'), $freshTag
    $htmlFilePath = Join-Path $effectiveOutputPath $htmlFileName

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFilePath, $htmlContent, $utf8NoBom)
    Write-Host "  HTML report: $htmlFilePath" -ForegroundColor Green
}

# --- JSON output ---
if ($OutputMode -eq 'JSON') {
    $summaryObject = [ordered]@{
        Timestamp         = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        CorrelationID     = $correlationID
        DaysBack          = $effectiveDaysBack
        CampaignsAnalyzed = $campaignAudits.Count
        ConfidenceScore   = [ordered]@{
            Score = $confidenceScore
            Grade = $confidenceGrade
            Level = $confidenceLevel
        }
        KPIs              = [ordered]@{
            CampaignCompletion   = [ordered]@{ Value = $avgCompletionRate; Status = $kpi1Status; Detail = "$totalDecided of $totalItems decided" }
            PastDueReviews       = [ordered]@{ Value = $totalOverdueAtRisk; Status = $kpi2Status; Detail = "$overdueCount overdue, $atRiskCount at-risk" }
            RevocationsExecuted  = [ordered]@{ Value = $revocationExecutionRate; Status = $kpi3Status; Detail = "$revocationProvisioned of $revocationTotal provisioned" }
            RemediationTimeliness = [ordered]@{ Value = $slaComplianceRate; Status = $kpi4Status; Detail = "$($agingDetails.Count) pending" }
            HighRiskExposure     = [ordered]@{ Value = $highRiskPendingCount; Status = $kpi5Status; Detail = "$($highRiskPending.Count) items" }
            ReviewerHealth       = [ordered]@{ Value = $reviewerHealthPct; Status = $kpi6Status; Detail = "$reviewerAtRiskCount at-risk of $reviewerTotalCount" }
        }
        DominoChainStatus = $dominoWorstStatus
        AgingBuckets      = $agingBuckets
        HighRiskPending   = $highRiskPendingCount
        Steps             = $stepResults
        DurationSeconds   = [math]::Round($totalDuration.TotalSeconds, 1)
        ExitCode          = $worstExitCode
    }
    $summaryObject | ConvertTo-Json -Depth 10
}

# --- JSONL Audit Trail (ALWAYS written) ---
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'DailyEvidenceReport'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            DaysBack          = $effectiveDaysBack
            CampaignsAnalyzed = $campaignAudits.Count
            KPIs              = [ordered]@{
                CampaignCompletion = [ordered]@{ Value = $avgCompletionRate; Status = $kpi1Status }
                PastDueReviews     = [ordered]@{ Value = $totalOverdueAtRisk; Status = $kpi2Status }
                RevocationsExecuted = [ordered]@{ Value = $revocationExecutionRate; Status = $kpi3Status }
                RemediationSla     = [ordered]@{ Value = $slaComplianceRate; Status = $kpi4Status }
                HighRiskExposure   = [ordered]@{ Value = $highRiskPendingCount; Status = $kpi5Status }
                ReviewerHealth     = [ordered]@{ Value = $reviewerHealthPct; Status = $kpi6Status }
            }
            ConfidenceScore   = [ordered]@{ Score = $confidenceScore; Grade = $confidenceGrade }
            DominoChainStatus = $dominoWorstStatus
            DurationSeconds   = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode          = $worstExitCode
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditFile = Join-Path $effectiveOutputPath 'daily-evidence-v4-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidenceV4' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPDailyEvidenceReport completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'DailyEvidenceV4' -Action 'Complete' -CorrelationID $correlationID

#endregion

#region Exit Code

# Determine final exit code:
#   0: All KPIs Green AND confidence A or B
#   1: Any KPI Yellow OR confidence C
#   5: Any KPI Red OR confidence D/F OR critical failure

$allStatuses = @($kpi1Status, $kpi2Status, $kpi3Status, $kpi4Status, $kpi5Status, $kpi6Status)
$hasRed    = ($allStatuses -contains 'Red')
$hasYellow = ($allStatuses -contains 'Yellow')

if ($hasRed -or $confidenceGrade -in @('D', 'F')) {
    $worstExitCode = [math]::Max($worstExitCode, 5)
}
elseif ($hasYellow -or $confidenceGrade -eq 'C') {
    $worstExitCode = [math]::Max($worstExitCode, 1)
}

# Check for step-level warnings that might not have been counted
foreach ($stepName in $stepResults.Keys) {
    if ($stepResults[$stepName].Status -eq 'Error') {
        $worstExitCode = [math]::Max($worstExitCode, 5)
    }
    elseif ($stepResults[$stepName].Status -eq 'Warning') {
        $worstExitCode = [math]::Max($worstExitCode, 1)
    }
}

exit $worstExitCode

#endregion
