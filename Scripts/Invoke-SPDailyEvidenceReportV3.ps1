#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily certification evidence report (v3) -- a DAY-OVER-DAY DELTA view that
    hybridizes the v2 layout with the campaign scope-diff (output: daily-evidence-v3-*.html).
.DESCRIPTION
    v3 keeps v2's executive context up top, then re-frames the body as "what changed since the
    previous day's campaign" by capturing today's campaign snapshot and diffing it CROSS-CAMPAIGN
    against the most-recent DIFFERENT campaign in the same series (new-campaign-per-day model).

      Header                       report-generated date + "vs <prior campaign>"
      Certification Scope          distinct users / entitlements / priv users / managers / sources
      Executive Summary (per campaign)
                                   status badge, reviewers signed-off, items decided, donut,
                                   "Revoked Access -- Removal Status" (Deprovisioned on connected AD
                                   vs Queued elsewhere vs Pending), and Key Indicators
      A. Campaign Completion Evidence   cross-campaign table incl. Approved / Revoked / Pending
      Access Changes Since Last Campaign (NEW -- the scope-diff hybrid):
        * Newly added access      net-new to SailPoint (identity was NOT in the entitlement before)
        * Removed entirely        disappeared from ISC without being formally revoked
        * Revoked but still present  not getting removed; split connected-AD (removal FAILED) vs
                                   disconnected/other (queued, manual fulfilment)
      B. Reviewer Accountability   net-new items only, grouped by reviewer: Completed / Pending /
                                   Reassigned
      Decision Summary             net-new items only -- Approved / Revoked / Pending -- PLUS a
                                   Changed register (APPROVE<->REVOKE flips on existing items)
      Footnote                     entitlements persistently PENDING across >= 2 campaigns

    v3 captures its own snapshot each run (-NoCapture to re-render offline). This is a CLONE of
    Invoke-SPDailyEvidenceReportV2.ps1; v2 remains available unchanged. The day-over-day engine is
    the same one Invoke-SPCampaignDiff.ps1 uses (Build/Save/Compare campaign snapshots).

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
.NOTES
    Script:  Invoke-SPDailyEvidenceReport.ps1
    Version: 1.0.0
    Exit codes:
        0 = All KPIs Green, confidence A or B
        1 = Any KPI Yellow or confidence C
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Any KPI Red, confidence D/F, or critical failure
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
Write-Host '  Daily Evidence Report' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  Period:        Last $effectiveDaysBack day(s)" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

Write-SPLog -Message "Invoke-SPDailyEvidenceReport started: CorrelationID=$correlationID DaysBack=$effectiveDaysBack" `
    -Severity INFO -Component 'DailyEvidence' -Action 'Start' -CorrelationID $correlationID

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
    ReviewerTimeliness   = @{ Green = 0;  Yellow = 3  }
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
    if ($null -ne $ct.PSObject.Properties['ReviewerTimeliness'] -and $null -ne $ct.ReviewerTimeliness) {
        if ($null -ne $ct.ReviewerTimeliness.PSObject.Properties['Green']) { $thresholds.ReviewerTimeliness.Green = [int]$ct.ReviewerTimeliness.Green }
        if ($null -ne $ct.ReviewerTimeliness.PSObject.Properties['Yellow']) { $thresholds.ReviewerTimeliness.Yellow = [int]$ct.ReviewerTimeliness.Yellow }
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
    Write-Host "  [5] KPI 4 - Reviewer Timeliness: manager aging analysis" -ForegroundColor Gray
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
    ReviewerTimeliness = @{ Status = 'Pending'; Detail = ''; Duration = 0 }
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
$totalDecided            = 0
$totalItems              = 0
$kpi1Status              = 'Green'
$overdueCount            = 0
$atRiskCount             = 0
$totalOverdueAtRisk      = 0
$kpi2Status              = 'Green'
$revocationTotal         = 0
$revocationProvisioned   = 0
$revocationExecutionRate = 0
$kpi3Status              = 'Green'
$slowReviewerCount       = 0
$kpi4Status              = 'Green'
$highRiskPendingCount    = 0
$kpi5Status              = 'Green'
$reviewerAtRiskCount     = 0
$reviewerTotalCount      = 0
$goodStandingCount       = 0
$reviewerHealthPct       = 100
$rubberStampTotal        = 0
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
            -Severity WARN -Component 'DailyEvidence' -Action 'NoCampaigns' -CorrelationID $correlationID
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
            $cacheResult = Get-SPCachedCampaignItems -Campaign $campaign -Certifications $certifications -CorrelationID $correlationID
            if ($cacheResult.Success) {
                foreach ($wi in $cacheResult.Data) { $wrappedItems.Add($wi) }
            }

            $campaignMetadata = @{
                StartDate      = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
                DueDate        = if ($null -ne $campaign.deadline)  { [string]$campaign.deadline }
                                 elseif ($null -ne $campaign.due)   { [string]$campaign.due }       else { '' }
                CompletionDate = if ($null -ne $campaign.completed) { [string]$campaign.completed } else { '' }
            }

            $decisionGroups  = Group-SPAuditDecisions -Items $wrappedItems.ToArray() `
                -CampaignMetadata $campaignMetadata
            $reviewerMetrics = Measure-SPAuditReviewerMetrics -Certifications $certifications
            $rubberStampRisk = Measure-SPAuditRubberStampRisk -Decisions $decisionGroups `
                -Certifications $certifications

            $reviewerActions = Group-SPReviewerActions -Certifications $certifications

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
            }
            $auditList.Add($campaignAudit)
        }
        catch {
            Write-Host "    WARN: Failed to process $campName : $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Campaign audit build failed for ${campName}: $($_.Exception.Message)" `
                -Severity WARN -Component 'DailyEvidence' -Action 'AuditBuildError' -CorrelationID $correlationID
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
        -Severity ERROR -Component 'DailyEvidence' -Action 'CampaignFetchError' -CorrelationID $correlationID
    $worstExitCode = 5
}
Write-Host ''

#endregion

#region Step 1b: Day-over-day delta (cross-campaign snapshot diff)

Write-Host '  Step 1b: Day-over-day delta (cross-campaign snapshot diff)' -ForegroundColor Cyan
$stepStart = Get-Date

# Aggregated delta buckets across all of today's campaigns.
$v3Added         = [System.Collections.Generic.List[object]]::new()   # net-new keys (current items)
$v3RemovedSilent = [System.Collections.Generic.List[object]]::new()   # gone, prior decision != REVOKE
$v3Persisted     = [System.Collections.Generic.List[object]]::new()   # revoked before, still present
$v3Changed       = [System.Collections.Generic.List[object]]::new()   # APPROVE<->REVOKE flips
$v3KeyToDecision = @{}                                                 # Key -> full current decision object
$v3HasPrior      = $false
$v3PriorLabels   = [System.Collections.Generic.List[string]]::new()
$v3CrossPending  = @()

# Read a property off either a hashtable/ordered-dict (in-memory snapshot/diff items) or a
# PSCustomObject (snapshot loaded back from JSON on disk) -- the two shapes both occur here.
# Thin wrapper -- canonical implementation is Get-SPObjectProperty (SP.HtmlHelpers).
function Get-V3Prop { param($o, [string]$n, $def = '')
    return (Get-SPObjectProperty -Object $o -Name $n -Default $def)
}
# Stable scope key, identical to Build-SPCampaignSnapshotData (prefers immutable IDs).
function Get-V3Key { param($o)
    $iid = [string](Get-V3Prop $o 'IdentityId' '')
    $aid = [string](Get-V3Prop $o 'AccessId' ''); if ([string]::IsNullOrWhiteSpace($aid)) { $aid = [string](Get-V3Prop $o 'AccessName' '') }
    $sid = [string](Get-V3Prop $o 'SourceId' ''); if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string](Get-V3Prop $o 'SourceName' '') }
    return ('{0}|{1}|{2}' -f $iid, $aid, $sid)
}

try {
    # Key -> current decision object map (for full-column enrichment of diff items).
    foreach ($audit in $campaignAudits) {
        $dg = $audit['Decisions']
        foreach ($grp in @('Approved', 'Revoked', 'Pending')) {
            foreach ($it in @($dg[$grp])) {
                if ($null -eq $it) { continue }
                $k = Get-V3Key $it
                if (-not $v3KeyToDecision.ContainsKey($k)) { $v3KeyToDecision[$k] = $it }
            }
        }
    }

    # Same name filter the user passed, so the snapshot set is scoped to this recurring series.
    $setParams = @{}
    if ($CampaignName)           { $setParams['CampaignName']           = $CampaignName }
    if ($CampaignNameStartsWith) { $setParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
    if ($CampaignNameContains)   { $setParams['CampaignNameContains']   = $CampaignNameContains }

    # Pass 1: build + persist today's snapshot for each campaign (so the disk set includes today).
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

    # Resolve the cross-campaign snapshot set once (latest capture per matching campaign, on disk).
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

        $v3HasPrior = $true
        $pLabel = [string]$priorSnap.Meta.CampaignName
        $pDate  = if ($priorSnap.Meta.StartDate) { [string]$priorSnap.Meta.StartDate } else { [string]$priorSnap.Meta.CapturedAt }
        if ($pLabel -and -not $v3PriorLabels.Contains($pLabel)) { $v3PriorLabels.Add($pLabel) }

        $cmp = $null
        try { $cmp = Compare-SPCampaignSnapshots -Current $todaySnap -Previous $priorSnap -CrossCampaign }
        catch { Write-Host "    WARN: compare failed for $($audit['CampaignName']): $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($null -eq $cmp -or -not $cmp.Success) { continue }
        $diff = $cmp.Data
        $audit['Diff'] = $diff

        foreach ($a in @($diff.Scope.Added))   { $v3Added.Add($a) }
        foreach ($r in @($diff.Scope.Removed)) { if ([string](Get-V3Prop $r 'Decision' '') -ne 'REVOKE') { $v3RemovedSilent.Add($r) } }
        foreach ($p in @($diff.Scope.PersistedRevokes)) { $v3Persisted.Add($p) }
        foreach ($c in @($diff.Scope.Changed)) { $v3Changed.Add($c) }
    }

    # Persistently pending across >= 2 DISTINCT campaigns (not captures): overlay the latest
    # snapshot of each matching campaign and count keys PENDING in >= 2 of them.
    if (@($snapSet).Count -ge 2) {
        $pendCount = @{}; $pendInfo = @{}
        foreach ($snap in @($snapSet)) {
            $seen = @{}
            foreach ($it in @($snap.Items)) {
                if ([string](Get-V3Prop $it 'Decision' '') -ne 'PENDING') { continue }
                $k = [string](Get-V3Prop $it 'Key' '')
                if ([string]::IsNullOrWhiteSpace($k) -or $seen.ContainsKey($k)) { continue }
                $seen[$k] = $true
                if (-not $pendCount.ContainsKey($k)) { $pendCount[$k] = 0; $pendInfo[$k] = $it }
                $pendCount[$k]++
            }
        }
        $v3CrossPending = @($pendCount.Keys | Where-Object { $pendCount[$_] -ge 2 } | ForEach-Object { @{ Item = $pendInfo[$_]; Campaigns = $pendCount[$_] } })
    }

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['DeltaDiff'] = @{ Status = 'Success'; Detail = "net-new=$($v3Added.Count), silently-removed=$($v3RemovedSilent.Count), stuck-revokes=$($v3Persisted.Count), changed=$($v3Changed.Count)"; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 1b: net-new=$($v3Added.Count) removed-silent=$($v3RemovedSilent.Count) stuck-revokes=$($v3Persisted.Count) changed=$($v3Changed.Count) hasPrior=$v3HasPrior" -ForegroundColor Green
}
catch {
    Write-Host "  Step 1b: ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Write-SPLog -Message "Delta diff exception: $($_.Exception.Message)" -Severity ERROR -Component 'DailyEvidenceV3' -Action 'DeltaDiffError' -CorrelationID $correlationID
}
Write-Host ''

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
        -Severity WARN -Component 'DailyEvidence' -Action 'CompletionError' -CorrelationID $correlationID
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
        -Severity WARN -Component 'DailyEvidence' -Action 'OverdueError' -CorrelationID $correlationID
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
        -Severity WARN -Component 'DailyEvidence' -Action 'RevocationError' -CorrelationID $correlationID
    $worstExitCode = [math]::Max($worstExitCode, 1)
}
Write-Host ''

#endregion

#region Step 5: KPI 4 - Reviewer Timeliness + Aging Buckets

Write-Host '  Step 5: KPI 4 - Reviewer Timeliness' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    # Compute reviewer aging buckets: how long since campaign creation for reviewers
    # who have NOT yet signed off (Phase != 'SIGNED').
    $now = [datetime]::UtcNow
    foreach ($audit in $campaignAudits) {
        $campCreated = [string]$audit['Created']
        $createdDate = [datetime]::MinValue
        if ([string]::IsNullOrWhiteSpace($campCreated) -or
            -not [datetime]::TryParse($campCreated, [ref]$createdDate)) { continue }

        $ra = $audit['ReviewerActions']
        if ($null -eq $ra) { continue }
        $primaryReviewers = @($ra['Primary'])

        foreach ($r in $primaryReviewers) {
            if ($null -eq $r) { continue }
            $phase = if ($null -ne $r.PSObject.Properties['Phase'] -and $null -ne $r.Phase) { [string]$r.Phase } else { '' }
            if ($phase.ToUpperInvariant() -eq 'SIGNED') { continue }

            $ageHours = ($now - $createdDate.ToUniversalTime()).TotalHours
            $bucket = if ($ageHours -le 24)  { '0-24h' }
                      elseif ($ageHours -le 48)  { '24-48h' }
                      elseif ($ageHours -le 120) { '2-5d' }
                      elseif ($ageHours -le 240) { '5-10d' }
                      else { '>10d' }
            $agingBuckets[$bucket]++

            $rName  = if ($null -ne $r.PSObject.Properties['Name']  -and $r.Name)  { [string]$r.Name }  else { '' }
            $rEmail = if ($null -ne $r.PSObject.Properties['Email'] -and $r.Email) { [string]$r.Email } else { '' }
            $rCerts = 0; try { $rCerts = [int]$r.CertsAssigned } catch { $rCerts = 0 }
            $rDec   = 0; try { $rDec   = [int]$r.DecisionsMade } catch { $rDec   = 0 }

            $agingDetails.Add([PSCustomObject]@{
                ReviewerName  = $rName
                ReviewerEmail = $rEmail
                CampaignName  = $audit['CampaignName']
                CertsAssigned = $rCerts
                DecisionsMade = $rDec
                HoursOpen     = [math]::Round($ageHours, 1)
                AgeBucket     = $bucket
            })
        }
    }

    # Count reviewers in concerning buckets (2-5d or worse)
    $slowReviewerCount = $agingBuckets['2-5d'] + $agingBuckets['5-10d'] + $agingBuckets['>10d']

    # KPI status: GREEN = 0 slow, YELLOW = 1-3 slow, RED = 4+ or any in 5-10d/10d+
    $hasAgingCrisis = ($agingBuckets['>10d'] -gt 0) -or ($agingBuckets['5-10d'] -gt 0) -or ($agingBuckets['2-5d'] -ge 4)

    $kpi4Status = Get-KpiStatusInverse -Value $slowReviewerCount `
        -GreenMax $thresholds.ReviewerTimeliness.Green `
        -YellowMax $thresholds.ReviewerTimeliness.Yellow
    if ($hasAgingCrisis -and $kpi4Status -ne 'Red') {
        $kpi4Status = 'Red'
    }

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $pendingTotal = ($agingBuckets.Values | Measure-Object -Sum).Sum
    $detail = "$slowReviewerCount slow reviewer(s), $pendingTotal unsigned total"
    if ($hasAgingCrisis) { $detail += ' [aging crisis]' }
    $stepResults['ReviewerTimeliness'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 5: $detail [$kpi4Status]" -ForegroundColor $(if ($kpi4Status -eq 'Green') { 'Green' } elseif ($kpi4Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['ReviewerTimeliness'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 5: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Reviewer Timeliness KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidence' -Action 'ReviewerTimelinessError' -CorrelationID $correlationID
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
    $detail = "$highRiskPendingCount high-risk identities with pending reviews ($($highRiskPending.Count) items)"
    $stepResults['HighRiskExposure'] = @{ Status = 'Success'; Detail = $detail; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 6: $detail [$kpi5Status]" -ForegroundColor $(if ($kpi5Status -eq 'Green') { 'Green' } elseif ($kpi5Status -eq 'Yellow') { 'Yellow' } else { 'Red' })
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $stepResults['HighRiskExposure'] = @{ Status = 'Warning'; Detail = $_.Exception.Message; Duration = [math]::Round($stepDuration, 2) }
    Write-Host "  Step 6: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "High-risk exposure KPI exception: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidence' -Action 'HighRiskError' -CorrelationID $correlationID
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
        -Severity WARN -Component 'DailyEvidence' -Action 'ReviewerHealthError' -CorrelationID $correlationID
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
        -Severity WARN -Component 'DailyEvidence' -Action 'ConfidenceError' -CorrelationID $correlationID
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
        Name = 'Reviewer Timeliness'; Value = $slowReviewerCount; Status = $kpi4Status
        Detail = "$($agingDetails.Count) unsigned reviewer(s)"
        TrendMetric = ''
    }
    @{
        Name = 'High-Risk Exposure'; Value = $highRiskPendingCount; Status = $kpi5Status
        Detail = "$($highRiskPending.Count) high-risk pending items"
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
# ===================== Daily Evidence v2 builder =====================
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
$allApproved = [System.Collections.Generic.List[object]]::new()
$allRevoked = [System.Collections.Generic.List[object]]::new()
$allPending = [System.Collections.Generic.List[object]]::new()
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
            switch ($grp) { 'Approved' { $allApproved.Add($it) } 'Revoked' { $allRevoked.Add($it) } default { $allPending.Add($it) } }
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
$aggAppr = $allApproved.Count; $aggRev = $allRevoked.Count; $aggPend = $allPending.Count
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
$v3VsLabel = if ($v3HasPrior -and $v3PriorLabels.Count -gt 0) { ' &middot; vs ' + (ConvertTo-SafeHtml (($v3PriorLabels | Select-Object -Unique) -join ', ')) } elseif (-not $v3HasPrior) { ' &middot; baseline (no prior campaign to compare)' } else { '' }
[void]$sb.AppendLine('<div class="header">')
[void]$sb.AppendLine('<h1>Daily Evidence Report &mdash; Day-over-Day</h1>')
[void]$sb.AppendLine('<div class="meta">SailPoint ISC Governance Toolkit | Report generated: ' + (ConvertTo-SafeHtml $genStr) + ' | Period: Last ' + $effectiveDaysBack + ' day(s)' + $envName2 + '</div>')
[void]$sb.AppendLine('<div class="status-line">' + ('{0:N0}' -f $aggDecided) + ' / ' + ('{0:N0}' -f $aggTotal) + ' decisions made (' + $aggPct + '%) &middot; ' + $activeCount + ' active campaign(s)' + $v3VsLabel + '</div>')
[void]$sb.AppendLine('</div>')

# ---- Certification Scope ----
[void]$sb.AppendLine('<div class="section"><h2>Certification Scope</h2><div class="scope-inline">')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $usersSet.Count) + '</span><span class="t">distinct users reviewed</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $entSet.Count) + '</span><span class="t">entitlements tracked</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $privUserSet.Count) + '</span><span class="t">privileged-access users</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + $mgrSet.Count + '</span><span class="t">reviewers involved</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + $srcSet.Count + '</span><span class="t">sources evaluated</span></div>')
[void]$sb.AppendLine('</div></div>')

# ---- Sources in Scope ----
[void]$sb.AppendLine('<div class="section"><h2>Sources in Scope</h2><div class="scope-inline">')
foreach ($srcName in $sourceCountMap.Keys) {
    $srcCount = $sourceCountMap[$srcName]
    [void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $srcCount) + '</span><span class="t">' + (ConvertTo-SafeHtml $srcName) + '</span></div>')
}
if ($sourceCountMap.Count -eq 0) {
    [void]$sb.AppendLine('<div style="color:#777;font-style:italic;font-size:12px">No source data available.</div>')
}
[void]$sb.AppendLine('</div></div>')

# ---- KPI Dashboard ----
$gradeColor = switch ($confidenceGrade) {
    'A' { '#339933' } 'B' { '#339933' } 'C' { '#e65100' } default { '#CC3333' }
}
[void]$sb.AppendLine('<div class="section"><h2>KPI Dashboard</h2>')

# Governance Confidence Score badge
[void]$sb.AppendLine('<div style="text-align:center;margin-bottom:16px">')
[void]$sb.AppendLine('<span style="display:inline-block;font-size:42px;font-weight:700;border:4px solid ' + $gradeColor + ';border-radius:12px;padding:6px 20px;color:' + $gradeColor + '">' + (ConvertTo-SafeHtml $confidenceGrade) + '</span>')
[void]$sb.AppendLine('<div style="font-size:14px;color:#555;margin-top:4px">' + $confidenceScore + ' / 100 (Level: ' + (ConvertTo-SafeHtml $confidenceLevel) + ')</div>')
[void]$sb.AppendLine('<div style="font-size:11px;color:#777;margin-top:6px;max-width:500px;margin-left:auto;margin-right:auto">Computed across six dimensions: Coverage, Timeliness, Enforcement, Accountability, Documentation, and Automation. Grade: A (90+), B (80-89), C (70-79), D (60-69), F (below 60).</div>')
[void]$sb.AppendLine('</div>')

# KPI summary table
[void]$sb.AppendLine('<table class="report"><thead><tr><th>KPI</th><th>Value</th><th>Status</th><th>Detail</th></tr></thead><tbody>')
foreach ($kpi in $kpiSummary) {
    $kpiStatusCls = switch ($kpi.Status) { 'Green' { 's-green' } 'Yellow' { 's-amber' } 'Red' { 's-red' } default { 's-gray' } }
    [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $kpi.Name) + '</td><td style="font-weight:bold">' + (ConvertTo-SafeHtml ([string]$kpi.Value)) + '</td><td class="' + $kpiStatusCls + '">' + (ConvertTo-SafeHtml $kpi.Status) + '</td><td>' + (ConvertTo-SafeHtml $kpi.Detail) + '</td></tr>')
}
[void]$sb.AppendLine('</tbody></table>')

# Domino Chain
[void]$sb.AppendLine('<div style="display:flex;align-items:center;justify-content:center;gap:0;flex-wrap:wrap;margin:16px 0">')
for ($di = 0; $di -lt $dominoChain.Count; $di++) {
    $box = $dominoChain[$di]
    $boxBg = switch ($box.Status) { 'Green' { '#e8f5e9' } 'Yellow' { '#fff3e0' } 'Red' { '#ffebee' } default { '#f5f5f5' } }
    $boxFg = switch ($box.Status) { 'Green' { '#2e7d32' } 'Yellow' { '#e65100' } 'Red' { '#c62828' } default { '#555' } }
    $boxBorder = $boxFg
    $cascadeNote = if ($box['CascadeHighlight']) { 'border-style:dashed;' } else { '' }
    [void]$sb.AppendLine('<div style="padding:8px 12px;border-radius:6px;text-align:center;min-width:90px;background:' + $boxBg + ';color:' + $boxFg + ';border:2px solid ' + $boxBorder + ';' + $cascadeNote + '">')
    [void]$sb.AppendLine('<div style="font-size:11px;font-weight:600;text-transform:uppercase">' + (ConvertTo-SafeHtml $box.ShortName) + '</div>')
    [void]$sb.AppendLine('<div style="font-size:16px;font-weight:700">' + (ConvertTo-SafeHtml $box.Status) + '</div>')
    [void]$sb.AppendLine('</div>')
    if ($di -lt ($dominoChain.Count - 1)) {
        [void]$sb.AppendLine('<div style="font-size:18px;color:#999;padding:0 4px">&rarr;</div>')
    }
}
[void]$sb.AppendLine('</div>')
[void]$sb.AppendLine('<div style="text-align:center;font-size:12px;color:#555;font-style:italic;margin-top:6px">' + (ConvertTo-SafeHtml $dominoNarrative) + '</div>')
[void]$sb.AppendLine('</div>')

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
    $primary = if ($null -ne $ra) { @($ra['Primary']) } else { @() }
    $reassigned = if ($null -ne $ra) { @($ra['Reassigned']) } else { @() }
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
    $pPct   = 100 - $remPct - $qPct; if ($pPct -lt 0) { $pPct = 0 }
    $stColor = switch ($cStatusRaw) { 'COMPLETED' { '#339933' } 'COMPLETING' { '#339933' } default { '#336699' } }
    $revCompColor = if ($revCompPct -ge 100) { '#339933' } elseif ($revCompPct -ge 50) { '#FF9900' } else { '#CC3333' }
    $pendColor = if ($pend -eq 0) { '#339933' } else { '#FF9900' }
    $remColor = if ($totRevoked -eq 0) { '#777777' } elseif ($remPct -ge 100) { '#339933' } elseif ($remPct -ge 50) { '#FF9900' } else { '#CC3333' }
    $donutSvg = & $donut $apct $rpct $ppct $tot
    $createdFmt = & $fmtDt ([string]$audit['Created'])
    if ($totRevoked -gt 0) {
        $remBlock = @"
<div style="text-align:center;margin-bottom:10px"><span style="font-size:36px;font-weight:bold;color:$remColor">$remPct%</span><br><span style="font-size:12px;color:#777">$removed of $totRevoked deprovisioned (connected AD)</span></div>
<table style="width:100%;border-collapse:collapse;height:18px;margin-bottom:6px"><tr><td style="width:$remPct%;background:#339933;height:18px;border-radius:4px 0 0 4px"></td><td style="width:$qPct%;background:#336699;height:18px"></td><td style="width:$pPct%;background:#FF8800;height:18px;border-radius:0 4px 4px 0"></td></tr></table>
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
<td style="padding:10px 4px;text-align:center;color:#555;font-size:12px"><span style="font-weight:bold;font-size:16px;color:#2c3e50">$signed / $totRev</span><br>Reviewers Decided</td>
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
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#FF8800"/></svg></td><td style="padding:2px 6px;color:#555">Pending: $('{0:N0}' -f $pend) ($ppct%)</td></tr>
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
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Approved</th><th>Revoked</th><th>Pending</th><th>Items Decided %</th><th>Created</th><th>Completed</th></tr></thead><tbody>')
foreach ($audit in $campaignAudits) {
    $cn = ConvertTo-SafeHtml $audit['CampaignName']
    $cs = ConvertTo-SafeHtml ([string]$audit['Status'])
    $d = $audit['Decisions']
    $a = @($d['Approved']).Count; $r = @($d['Revoked']).Count; $p = @($d['Pending']).Count
    $t = $a + $r + $p; $dec = $a + $r
    $pc = if ($t -gt 0) { [math]::Round($dec / $t * 100, 0) } else { 0 }
    $pcCls = if ($pc -ge 80) { 's-green' } elseif ($pc -ge 50) { 's-amber' } else { 's-red' }
    $cr = & $fmtDt ([string]$audit['Created'])
    $cmp = & $fmtDt ([string]$audit['Completed'])
    [void]$sb.AppendLine("<tr><td>$cn</td><td>$cs</td><td>$('{0:N0}' -f $t)</td><td>$('{0:N0}' -f $a)</td><td class='s-red'>$('{0:N0}' -f $r)</td><td>$('{0:N0}' -f $p)</td><td class='$pcCls'>$pc%</td><td>$cr</td><td>$cmp</td></tr>")
}
[void]$sb.AppendLine('</tbody></table></div>')

# ---- Overdue / At-Risk Campaigns ----
[void]$sb.AppendLine('<div class="section"><h2>Overdue / At-Risk Campaigns</h2>')
if ($overdueAtRiskCampaigns.Count -eq 0) {
    [void]$sb.AppendLine('<p class="s-green" style="font-weight:bold">No overdue or at-risk campaigns detected.</p>')
}
else {
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Campaign</th><th>Health Status</th><th>Projected</th><th>Days to Deadline</th><th>Completion %</th><th>Bottleneck Reviewers</th></tr></thead><tbody>')
    foreach ($orc in $overdueAtRiskCampaigns) {
        $orcHealthCls = switch ([string]$orc.HealthStatus) { 'Overdue' { 's-red' } 'AtRisk' { 's-amber' } 'Stalled' { 's-red' } default { 's-gray' } }
        $orcProjCls = switch ([string]$orc.ProjectedStatus) { 'AtRisk' { 's-amber' } 'Stalled' { 's-red' } default { 's-gray' } }
        $orcDtd = if ([string]::IsNullOrWhiteSpace([string]$orc.DaysToDeadline)) { '-' } else { [string]$orc.DaysToDeadline }
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string]$orc.CampaignName)) + '</td><td class="' + $orcHealthCls + '">' + (ConvertTo-SafeHtml ([string]$orc.HealthStatus)) + '</td><td class="' + $orcProjCls + '">' + (ConvertTo-SafeHtml ([string]$orc.ProjectedStatus)) + '</td><td>' + (ConvertTo-SafeHtml $orcDtd) + '</td><td>' + $orc.CompletionPct + '%</td><td>' + (ConvertTo-SafeHtml ([string]$orc.BottleneckReviewers)) + '</td></tr>')
    }
    [void]$sb.AppendLine('</tbody></table>')
}
[void]$sb.AppendLine('</div>')

# ---- Net-new joined lists (shared by Access Changes, Section B, and Decision Summary) ----
# Each diff "Added" item is net-new (its identity|access|source key was ABSENT in the prior
# campaign). Resolve it back to the full current decision object so the detail tables keep the
# v2 columns (Account, Justification, source-aware Remediation) the lean snapshot items lack.
$v3NetNewItems = [System.Collections.Generic.List[object]]::new()
foreach ($a in $v3Added) {
    $k = [string](Get-V3Prop $a 'Key' '')
    $full = if ($k -and $v3KeyToDecision.ContainsKey($k)) { $v3KeyToDecision[$k] } else { $a }
    $v3NetNewItems.Add($full)
}
$v3NewApproved = @($v3NetNewItems | Where-Object { ([string](Get-V3Prop $_ 'Decision' '')).ToUpperInvariant() -eq 'APPROVE' })
$v3NewRevoked  = @($v3NetNewItems | Where-Object { ([string](Get-V3Prop $_ 'Decision' '')).ToUpperInvariant() -eq 'REVOKE' })
$v3NewPending  = @($v3NetNewItems | Where-Object { ([string](Get-V3Prop $_ 'Decision' '')).ToUpperInvariant() -notin @('APPROVE', 'REVOKE') })

# ---- Access Changes Since Last Campaign (the scope-diff hybrid) ----
[void]$sb.AppendLine('<div class="section"><h2>Access Changes Since Last Campaign</h2>')
if (-not $v3HasPrior) {
    [void]$sb.AppendLine('<p style="color:#777;font-style:italic">Baseline run &mdash; no prior campaign in this series to compare against yet. Change tracking begins on the next campaign.</p>')
}
else {
    # (a) Newly added access -- net-new to SailPoint, approved or pending (not revoked-on-arrival).
    $newAccess = @($v3NetNewItems | Where-Object { ([string](Get-V3Prop $_ 'Decision' '')).ToUpperInvariant() -in @('APPROVE', 'PENDING', '') })
    [void]$sb.AppendLine('<details><summary class="s-green" style="font-size:13px;margin:12px 0 6px">Newly added access &mdash; net-new to SailPoint (' + $newAccess.Count + ')</summary>')
    [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 6px">The identity was NOT in this entitlement in the prior campaign. Status is the current decision (approved or still pending).</p>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision</th><th>Decision Date</th></tr></thead><tbody>')
    if ($newAccess.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">None.</td></tr>') }
    else { foreach ($it in @($newAccess | Sort-Object @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})) {
        $priv = $false; try { $priv = [bool](Get-V3Prop $it 'Privileged' $false) } catch { }
        $pb = if ($priv) { ' <span class="badge badge-priv">PRIV</span>' } else { '' }
        $dec = ([string](Get-V3Prop $it 'Decision' '')).ToUpperInvariant(); if (-not $dec) { $dec = 'PENDING' }
        $decCls = if ($dec -eq 'APPROVE') { 's-green' } else { 's-amber' }
        $dd = & $fmtDt ([string](Get-V3Prop $it 'DecisionDate' ''))
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'IdentityName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'AccessName' ''))) + $pb + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'SourceName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'ReviewerName' ''))) + '</td><td class="' + $decCls + '">' + (ConvertTo-SafeHtml $dec) + '</td><td>' + (ConvertTo-SafeHtml $dd) + '</td></tr>')
    } }
    [void]$sb.AppendLine('</tbody></table></details>')

    # (b) Removed entirely -- disappeared from ISC and was NOT revoked in the prior campaign.
    [void]$sb.AppendLine('<details><summary style="font-size:13px;margin:12px 0 6px;color:#9a6700;font-weight:bold">Removed entirely &mdash; disappeared, not a revoke (' + $v3RemovedSilent.Count + ')</summary>')
    [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 6px">Present in the prior campaign, gone now, and it was NOT formally revoked &mdash; the access left SailPoint outside the certification (deleted grant, scope change, or upstream removal).</p>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Prior Decision</th><th>Prior Date</th></tr></thead><tbody>')
    if ($v3RemovedSilent.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">None.</td></tr>') }
    else { foreach ($it in @($v3RemovedSilent | Sort-Object @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})) {
        $pd = ([string](Get-V3Prop $it 'Decision' '')).ToUpperInvariant(); if (-not $pd) { $pd = 'PENDING' }
        $pdd = & $fmtDt ([string](Get-V3Prop $it 'DecisionDate' ''))
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'IdentityName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'AccessName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'SourceName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'ReviewerName' ''))) + '</td><td>' + (ConvertTo-SafeHtml $pd) + '</td><td>' + (ConvertTo-SafeHtml $pdd) + '</td></tr>')
    } }
    [void]$sb.AppendLine('</tbody></table></details>')

    # (c) Revoked but still present -- the revoke is not getting fulfilled. Split connected-AD
    # (removal FAILED) from disconnected/other (queued, awaiting manual fulfilment).
    $stuckAD    = @($v3Persisted | Where-Object { [bool](Get-V3Prop $_ 'IsConnectedAD' $false) })
    $stuckOther = @($v3Persisted | Where-Object { -not [bool](Get-V3Prop $_ 'IsConnectedAD' $false) })
    [void]$sb.AppendLine('<details><summary class="s-red" style="font-size:13px;margin:12px 0 6px">Revoked but still present &mdash; not getting removed (' + $v3Persisted.Count + ')</summary>')
    [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 6px">The manager revoked this in the prior campaign and it is STILL in SailPoint.</p>')
    # Render closure for a stuck-revoke table.
    $renderStuck = {
        param($rows, $heading, $headClass, $note)
        [void]$sb.AppendLine('<div class="subhead ' + $headClass + '">' + $heading + ' (' + @($rows).Count + ')</div>')
        if ($note) { [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 4px">' + $note + '</p>') }
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Revoked On</th><th>Days Stuck</th></tr></thead><tbody>')
        if (@($rows).Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">None.</td></tr>') }
        else { foreach ($it in @($rows | Sort-Object @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})) {
            $priv = $false; try { $priv = [bool](Get-V3Prop $it 'Privileged' $false) } catch { }
            $pb = if ($priv) { ' <span class="badge badge-priv">PRIV</span>' } else { '' }
            $stype = [string](Get-V3Prop $it 'SourceType' '')
            $srcDisp = (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'SourceName' ''))) + $(if ($stype) { ' <span style="color:#999;font-size:10px">(' + (ConvertTo-SafeHtml $stype) + ')</span>' } else { '' })
            $revRaw = [string](Get-V3Prop $it 'PrevDecisionDate' '')
            $revOn = & $fmtDt $revRaw
            $daysStuck = ''
            if (-not [string]::IsNullOrWhiteSpace($revRaw)) { try { $daysStuck = [string][math]::Round(((Get-Date) - [datetime]$revRaw).TotalDays, 0) } catch { $daysStuck = '' } }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'IdentityName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'AccessName' ''))) + $pb + '</td><td>' + $srcDisp + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'ReviewerName' ''))) + '</td><td>' + (ConvertTo-SafeHtml $revOn) + '</td><td>' + (ConvertTo-SafeHtml $daysStuck) + '</td></tr>')
        } }
        [void]$sb.AppendLine('</tbody></table>')
    }
    & $renderStuck $stuckAD 'Removal failed (connected Active Directory)' 's-red' 'Connected AD performs the removal &mdash; still present means the de-provisioning did not happen. Investigate.'
    & $renderStuck $stuckOther 'Queued &mdash; disconnected / other source' 's-amber' 'Fulfilled downstream / manually; recorded but removal is not confirmed here.'
    [void]$sb.AppendLine('</details>')
}
[void]$sb.AppendLine('</div>')

# ---- B. Reviewer Accountability (scoped to net-new items) ----
[void]$sb.AppendLine('<div class="section"><h2>B. Reviewer Accountability</h2>')
[void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 8px">Scoped to the NET-NEW items above (access new to SailPoint this campaign), grouped by the reviewer (manager) who owns each item. Reassigned reflects all reassigned certs.</p>')
if (-not $v3HasPrior) {
    [void]$sb.AppendLine('<p style="color:#777;font-style:italic">Baseline run &mdash; no prior campaign; net-new accountability begins on the next campaign.</p>')
}
else {
    $bReviewer = { param($it) $n = [string](Get-V3Prop $it 'ReviewerName' ''); if ([string]::IsNullOrWhiteSpace($n) -or $n -eq 'N/A') { '(unassigned)' } else { $n } }
    $bRow = {
        param($it)
        $dec = ([string](Get-V3Prop $it 'Decision' '')).ToUpperInvariant(); if (-not $dec) { $dec = 'PENDING' }
        $decCls = switch ($dec) { 'APPROVE' { 's-green' } 'REVOKE' { 's-red' } default { 's-amber' } }
        $dd = & $fmtDt ([string](Get-V3Prop $it 'DecisionDate' ''))
        '<tr><td>' + (ConvertTo-SafeHtml (& $bReviewer $it)) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'IdentityName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'AccessName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'SourceName' ''))) + '</td><td class="' + $decCls + '">' + (ConvertTo-SafeHtml $dec) + '</td><td>' + (ConvertTo-SafeHtml $dd) + '</td></tr>'
    }
    $bDecided = @($v3NetNewItems | Where-Object { ([string](Get-V3Prop $_ 'Decision' '')).ToUpperInvariant() -in @('APPROVE', 'REVOKE') } | Sort-Object @{Expression={& $bReviewer $_}}, @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})
    [void]$sb.AppendLine('<details><summary style="font-weight:bold;font-size:12px;margin-bottom:4px">Completed &mdash; net-new items decided (' + $bDecided.Count + ')</summary>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Decision</th><th>Decision Date</th></tr></thead><tbody>')
    if ($bDecided.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">No net-new items have been decided yet.</td></tr>') }
    else { foreach ($it in $bDecided) { [void]$sb.AppendLine((& $bRow $it)) } }
    [void]$sb.AppendLine('</tbody></table></details>')

    $bPending = @($v3NewPending | Sort-Object @{Expression={& $bReviewer $_}}, @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})
    [void]$sb.AppendLine('<details><summary style="font-weight:bold;font-size:12px;margin:8px 0 4px">Pending &mdash; net-new items not yet decided (' + $bPending.Count + ')</summary>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Identity</th><th>Access Name</th><th>Source</th><th>Decision</th><th>Decision Date</th></tr></thead><tbody>')
    if ($bPending.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="6" style="color:#777;font-style:italic">No net-new items pending.</td></tr>') }
    else { foreach ($it in $bPending) { [void]$sb.AppendLine((& $bRow $it)) } }
    [void]$sb.AppendLine('</tbody></table></details>')

    # Reassigned -- all reassigned certs (per campaign), unchanged from v2.
    $allReassigned = [System.Collections.Generic.List[object]]::new()
    foreach ($audit in $campaignAudits) {
        $ra = $audit['ReviewerActions']; if ($null -eq $ra) { continue }
        foreach ($rr in @($ra['Reassigned'])) { if ($null -ne $rr) { $allReassigned.Add($rr) } }
    }
    [void]$sb.AppendLine('<details><summary style="font-weight:bold;font-size:12px;margin:8px 0 4px">Reassigned (' + $allReassigned.Count + ')</summary>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th>Reassigned From</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th><th>Proof of Action</th></tr></thead><tbody>')
    if ($allReassigned.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="7" style="color:#777;font-style:italic">No reassignments recorded.</td></tr>') }
    else { foreach ($rr in @($allReassigned | Sort-Object Name)) {
        $so = & $fmtDt ([string]$rr.SignOffDate)
        $proof = if ($rr.ProofOfAction) { '<span class="s-green">Yes</span>' } else { '<span class="s-red">No</span>' }
        $phCls2 = if ($rr.Phase -eq 'SIGNED') { 's-green' } else { 's-amber' }
        $rf = if ($rr.PSObject.Properties['ReassignedFrom']) { ConvertTo-SafeHtml $rr.ReassignedFrom } else { '' }
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $rr.Name) + '</td><td>' + (ConvertTo-SafeHtml $rr.Email) + '</td><td>' + $rf + '</td><td>' + $rr.DecisionsMade + '</td><td>' + (ConvertTo-SafeHtml $so) + '</td><td class="' + $phCls2 + '">' + (ConvertTo-SafeHtml ([string]$rr.Phase)) + '</td><td>' + $proof + '</td></tr>')
    } }
    [void]$sb.AppendLine('</tbody></table></details>')
}
[void]$sb.AppendLine('</div>')

# ---- Reviewer Timeliness (aging buckets) ----
[void]$sb.AppendLine('<div class="section"><h2>Reviewer Timeliness</h2>')
[void]$sb.AppendLine('<p style="font-size:12px;color:#555">Managers who have not signed off on their certification, bucketed by time since campaign creation.</p>')
# Bar chart
$agingTotal = ($agingBuckets.Values | Measure-Object -Sum).Sum
if ($agingTotal -gt 0) {
    $agingBarColors = [ordered]@{ '0-24h' = '#339933'; '24-48h' = '#8BC34A'; '2-5d' = '#FF9800'; '5-10d' = '#FF5722'; '>10d' = '#CC3333' }
    [void]$sb.AppendLine('<div style="margin:12px 0">')
    [void]$sb.AppendLine('<table style="width:100%;border-collapse:collapse;height:28px"><tr>')
    foreach ($bk in $agingBuckets.Keys) {
        $bkCount = $agingBuckets[$bk]
        if ($bkCount -le 0) { continue }
        $bkPct = [math]::Round($bkCount / $agingTotal * 100, 1)
        $bkColor = $agingBarColors[$bk]
        [void]$sb.AppendLine('<td style="width:' + $bkPct + '%;background:' + $bkColor + ';height:28px;text-align:center;color:#fff;font-size:11px;font-weight:600">' + $bkCount + '</td>')
    }
    [void]$sb.AppendLine('</tr></table>')
    [void]$sb.AppendLine('<table style="width:100%;border-collapse:collapse;font-size:11px;margin-top:4px"><tr>')
    foreach ($bk in $agingBuckets.Keys) {
        $bkCount = $agingBuckets[$bk]
        $bkColor = $agingBarColors[$bk]
        [void]$sb.AppendLine('<td style="text-align:center;padding:2px 4px"><span style="color:' + $bkColor + ';font-weight:bold">' + $bk + '</span> (' + $bkCount + ')</td>')
    }
    [void]$sb.AppendLine('</tr></table>')
    [void]$sb.AppendLine('</div>')
}
else {
    [void]$sb.AppendLine('<p class="s-green" style="font-weight:bold">All reviewers have signed off. No aging concerns.</p>')
}
# Aging detail table
if ($agingDetails.Count -gt 0) {
    [void]$sb.AppendLine('<details><summary style="font-weight:bold;font-size:12px;margin:8px 0 4px">Detail: unsigned reviewers (' + $agingDetails.Count + ')</summary>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Entitlement</th><th>Decision Date</th><th>Hours Open</th><th>Bucket</th></tr></thead><tbody>')
    foreach ($ad in @($agingDetails | Sort-Object -Property AgeHours -Descending)) {
        $adBucketCls = switch ($ad.AgeBucket) { '0-24h' { 's-green' } '24-48h' { 's-green' } '2-5d' { 's-amber' } '5-10d' { 's-red' } '>10d' { 's-red' } default { 's-gray' } }
        $adDate = & $fmtDt ([string]$ad.DecisionDate)
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string]$ad.IdentityName)) + '</td><td>' + (ConvertTo-SafeHtml ([string]$ad.EntitlementName)) + '</td><td>' + (ConvertTo-SafeHtml $adDate) + '</td><td>' + $ad.AgeHours + '</td><td class="' + $adBucketCls + '">' + (ConvertTo-SafeHtml $ad.AgeBucket) + '</td></tr>')
    }
    [void]$sb.AppendLine('</tbody></table></details>')
}
[void]$sb.AppendLine('</div>')

# ---- High-Risk Pending Review ----
[void]$sb.AppendLine('<div class="section"><h2>High-Risk Pending Review</h2>')
if ($highRiskPending.Count -eq 0) {
    [void]$sb.AppendLine('<p class="s-green" style="font-weight:bold">No high-risk identities with pending reviews.</p>')
}
else {
    [void]$sb.AppendLine('<p style="font-size:12px;color:#555">' + $highRiskPendingIdentityIds.Count + ' high-risk identit' + $(if ($highRiskPendingIdentityIds.Count -eq 1) { 'y' } else { 'ies' }) + ' with ' + $highRiskPending.Count + ' pending review item(s) (risk threshold: ' + $HighRiskThreshold + ').</p>')
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Risk Score</th><th>Access</th><th>Source</th><th>Campaign</th></tr></thead><tbody>')
    foreach ($hrp in @($highRiskPending | Sort-Object -Property RiskScore -Descending)) {
        $hrScoreCls = if ($hrp.RiskScore -ge 90) { 's-red' } elseif ($hrp.RiskScore -ge $HighRiskThreshold) { 's-amber' } else { 's-gray' }
        [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string]$hrp.IdentityName)) + '</td><td class="' + $hrScoreCls + '">' + $hrp.RiskScore + '</td><td>' + (ConvertTo-SafeHtml ([string]$hrp.AccessName)) + '</td><td>' + (ConvertTo-SafeHtml ([string]$hrp.SourceName)) + '</td><td>' + (ConvertTo-SafeHtml ([string]$hrp.CampaignName)) + '</td></tr>')
    }
    [void]$sb.AppendLine('</tbody></table>')
}
[void]$sb.AppendLine('</div>')

# ---- Decision Summary (net-new items + Changed register) ----
[void]$sb.AppendLine('<div class="section"><h2>Decision Summary</h2>')
[void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 8px">Approved / Revoked / Pending show only NET-NEW items (access new to SailPoint this campaign). The Changed register below lists existing access whose decision flipped between campaigns.</p>')
$cats = @(
    @{ Label = 'Approved (net-new)'; Cls = 's-green'; Items = $v3NewApproved; Open = $false },
    @{ Label = 'Revoked (net-new)'; Cls = 's-red'; Items = $v3NewRevoked; Open = $true },
    @{ Label = 'Pending (net-new)'; Cls = 's-amber'; Items = $v3NewPending; Open = $false }
)
foreach ($cat in $cats) {
    $items = @($cat.Items); $cnt = $items.Count
    $oa = if ($cat.Open) { ' open' } else { '' }
    [void]$sb.AppendLine("<details$oa><summary class='$($cat.Cls)' style='font-size:13px;margin:12px 0 6px'>$($cat.Label) ($cnt items)</summary>")
    [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Account</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Decision Date</th><th>Justification</th><th>Remediation</th></tr></thead><tbody>')
    if ($cnt -eq 0) { [void]$sb.AppendLine('<tr><td colspan="8" style="color:#777;font-style:italic">None.</td></tr>') }
    else {
        $isRevoked = ($cat.Label -match '^Revoked')
        foreach ($it in $items) {
            $cid = if ($it.PSObject.Properties['CertificationId']) { [string]$it.CertificationId } else { '' }
            $just = 'N/A'
            if ($it.PSObject.Properties['Justification'] -and -not [string]::IsNullOrWhiteSpace($it.Justification)) { $just = [string]$it.Justification }
            # Remediation: a completed revoke is only "Deprovisioned" on a connected Active Directory
            # source; on any other (disconnected/manual) source it is "Queued for removal" -- recorded
            # but fulfilled downstream and not confirmed here. The source-aware disposition is computed
            # once in Group-SPAuditDecisions (RemediationDisposition/RemediationLabel).
            $rem = '<span class="s-gray">N/A</span>'
            $disp = if ($it.PSObject.Properties['RemediationDisposition']) { [string]$it.RemediationDisposition } else { '' }
            if ($isRevoked -and -not [string]::IsNullOrWhiteSpace($disp) -and $disp -ne 'NA') {
                $rsDisp = if ($it.PSObject.Properties['RemediationLabel'] -and -not [string]::IsNullOrWhiteSpace([string]$it.RemediationLabel)) { [string]$it.RemediationLabel } else { $disp }
                $cls = switch ($disp) { 'Removed' { 's-green' } 'Queued' { 's-amber' } 'Pending' { 's-amber' } default { 's-gray' } }
                $rem = '<span class="' + $cls + '">' + (ConvertTo-SafeHtml $rsDisp) + '</span>'
            }
            elseif (-not $isRevoked -and $it.PSObject.Properties['RemediationStatus'] -and -not [string]::IsNullOrWhiteSpace($it.RemediationStatus) -and ([string]$it.RemediationStatus) -ne 'N/A') {
                $rem = '<span class="s-gray">' + (ConvertTo-SafeHtml ([string]$it.RemediationStatus)) + '</span>'
            }
            # PRIV badge is item-driven (the entitlement's privileged attribute) -> kept, so it stays
            # adaptive for quarterly mixed campaigns where only some access is privileged.
            $priv = $false; try { $priv = [bool]$it.Privileged } catch { }
            $pb = if ($priv) { ' <span class="badge badge-priv">PRIV</span>' } else { '' }
            $acct = if ($it.PSObject.Properties['AccountIdentifier']) { ConvertTo-SafeHtml $it.AccountIdentifier } else { '' }
            # Reviewer (the manager): item-level reviewedBy is usually empty -> fall back to the cert's reviewer.
            $rvwName = ''
            if ($it.PSObject.Properties['ReviewerName'] -and -not [string]::IsNullOrWhiteSpace([string]$it.ReviewerName) -and ([string]$it.ReviewerName) -ne 'N/A') { $rvwName = [string]$it.ReviewerName }
            elseif ($cid -and $certReviewerMap.ContainsKey($cid)) { $rvwName = [string]$certReviewerMap[$cid].Name }
            $rvw = ConvertTo-SafeHtml $rvwName
            # Decision date: item DecisionDate, else the cert's signoff/completed date.
            $ddRaw = [string]$it.DecisionDate
            if ([string]::IsNullOrWhiteSpace($ddRaw) -and $cid -and $certReviewerMap.ContainsKey($cid)) { $ddRaw = [string]$certReviewerMap[$cid].SignOff }
            $dd = & $fmtDt $ddRaw
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $it.IdentityName) + '</td><td>' + $acct + '</td><td>' + (ConvertTo-SafeHtml $it.AccessName) + $pb + '</td><td>' + (ConvertTo-SafeHtml $it.SourceName) + '</td><td>' + $rvw + '</td><td>' + (ConvertTo-SafeHtml $dd) + '</td><td>' + (ConvertTo-SafeHtml $just) + '</td><td>' + $rem + '</td></tr>')
        }
    }
    [void]$sb.AppendLine('</tbody></table></details>')
}
# Changed register -- existing access whose decision flipped APPROVE<->REVOKE (a legitimate change).
$chCount = $v3Changed.Count
[void]$sb.AppendLine("<details><summary class='s-amber' style='font-size:13px;margin:12px 0 6px'>Changed &mdash; decision flipped on existing access ($chCount)</summary>")
[void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:0 0 6px">Existing grants (NOT net-new) whose decision changed between campaigns &mdash; e.g. previously approved, now revoked. A legitimate change in access; the user acted in the prior campaign and the decision then flipped.</p>')
[void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access Name</th><th>Source</th><th>Reviewer</th><th>Was</th><th>Now</th><th>Prev Date</th><th>Curr Date</th></tr></thead><tbody>')
if ($chCount -eq 0) { [void]$sb.AppendLine('<tr><td colspan="8" style="color:#777;font-style:italic">No decision changes since the prior campaign.</td></tr>') }
else { foreach ($c in @($v3Changed | Sort-Object @{Expression={[string](Get-V3Prop $_ 'IdentityName' '')}})) {
    $priv = $false; try { $priv = [bool](Get-V3Prop $c 'Privileged' $false) } catch { }
    $pb = if ($priv) { ' <span class="badge badge-priv">PRIV</span>' } else { '' }
    $was = ([string](Get-V3Prop $c 'PrevDecision' '')).ToUpperInvariant()
    $now = ([string](Get-V3Prop $c 'CurrDecision' '')).ToUpperInvariant()
    $wasCls = if ($was -eq 'APPROVE') { 's-green' } else { 's-red' }
    $nowCls = if ($now -eq 'APPROVE') { 's-green' } else { 's-red' }
    $pdd = & $fmtDt ([string](Get-V3Prop $c 'PrevDecisionDate' ''))
    $cdd = & $fmtDt ([string](Get-V3Prop $c 'CurrDecisionDate' ''))
    [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $c 'IdentityName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $c 'AccessName' ''))) + $pb + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $c 'SourceName' ''))) + '</td><td>' + (ConvertTo-SafeHtml ([string](Get-V3Prop $c 'ReviewerName' ''))) + '</td><td class="' + $wasCls + '">' + (ConvertTo-SafeHtml $was) + '</td><td class="' + $nowCls + '">' + (ConvertTo-SafeHtml $now) + '</td><td>' + (ConvertTo-SafeHtml $pdd) + '</td><td>' + (ConvertTo-SafeHtml $cdd) + '</td></tr>')
} }
[void]$sb.AppendLine('</tbody></table></details>')
[void]$sb.AppendLine('</div>')

# ---- Footnote: persistently pending across >= 2 campaigns ----
$ppCount = @($v3CrossPending).Count
[void]$sb.AppendLine('<div class="section" style="margin-top:18px">')
[void]$sb.AppendLine('<p style="font-size:11px;color:#777;border-top:1px solid #e0e0e0;padding-top:10px"><b>Note &mdash; persistently pending across campaigns:</b> ' + $(
    if ($ppCount -gt 0) {
        $rows = @($v3CrossPending | Sort-Object @{Expression={ - [int]$_.Campaigns }} | Select-Object -First 50 | ForEach-Object {
            $it = $_.Item
            (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'IdentityName' ''))) + ' &middot; ' + (ConvertTo-SafeHtml ([string](Get-V3Prop $it 'AccessName' ''))) + ' (' + $_.Campaigns + ' campaigns)'
        })
        [string]$ppCount + ' entitlement(s) have stayed PENDING across at least two separate campaigns (not just captures) &mdash; never actioned across review cycles:<br>' + ($rows -join '<br>')
    }
    elseif (@($snapSet).Count -lt 2) { 'needs at least two campaigns in this series on disk to evaluate (only ' + @($snapSet).Count + ' found).' }
    else { 'none &mdash; no entitlement has stayed pending across two or more campaigns.' }
) + '</p>')
[void]$sb.AppendLine('</div>')

# ---- Footer ----
[void]$sb.AppendLine('<div class="footer">SailPoint ISC Governance Toolkit &middot; Daily Evidence Report v3 &middot; Generated: ' + (ConvertTo-SafeHtml $genStr) + ' &middot; CorrelationID: ' + (ConvertTo-SafeHtml $correlationID) + ' &middot; ' + $campaignAudits.Count + ' campaign(s)</div>')
[void]$sb.AppendLine('</div></body></html>')
    $htmlContent = $sb.ToString()
    $htmlFileName = 'daily-evidence-v3-{0}.html' -f $startTime.ToString('yyyyMMdd-HHmmss')
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
            ReviewerTimeliness = [ordered]@{ Value = $slowReviewerCount; Status = $kpi4Status; Detail = "$($agingDetails.Count) unsigned reviewers" }
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
                ReviewerTimeliness = [ordered]@{ Value = $slowReviewerCount; Status = $kpi4Status }
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
    $auditFile = Join-Path $effectiveOutputPath 'daily-evidence-v3-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'DailyEvidence' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPDailyEvidenceReport completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'DailyEvidence' -Action 'Complete' -CorrelationID $correlationID

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
