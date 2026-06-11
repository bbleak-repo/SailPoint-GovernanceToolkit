#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a daily governance evidence report with executive KPI dashboard,
    domino risk tracker, and compliance evidence sections.
.DESCRIPTION
    Produces a single-page executive dashboard (above the fold) with six governance
    KPIs, a Governance Confidence Score, and a cascading risk "Domino Tracker",
    plus detailed evidence registers (below the fold) for audit/IAG compliance.

    Designed for daily scheduled execution after the daily orchestrator. Consolidates
    data from multiple toolkit analytics functions into the format required by
    Step 6: Evidence and Reporting of the IAM governance program.

    KPI Dashboard:
      1. Campaign Completion Rate    (% of review items decided)
      2. Past-Due Reviews            (overdue/at-risk campaign count)
      3. Revocations Executed        (% of revocations provisioned)
      4. Remediation Timeliness      (SLA compliance % + aging buckets)
      5. High-Risk Exposure          (high-risk identities with pending reviews)
      6. Reviewer Health             (reviewer reputation distribution)

    Evidence Sections:
      A. Campaign Completion Evidence
      B. Certifier Decision Register
      C. Revocation & Remediation Register (with aging chart)
      D. Past-Due / At-Risk Campaign Register
      E. High-Risk Pending Review Register
      F. Reviewer Performance Register
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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';   Name = 'SP.Core';  Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';     Name = 'SP.Api';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'; Name = 'SP.Audit'; Required = $true  }
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
    return [System.Net.WebUtility]::HtmlEncode($str)
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
$revocationQueued        = 0
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

    $campaignAudits = $auditList.ToArray()
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
    # Build remediation proof from cached review items (no additional API calls).
    # "Provisioned" here means confirmed de-provisioned -- ONLY connected-AD removals count; a
    # completed revoke on a disconnected/other source is queued (recorded, removal not confirmed).
    $totalRevoked = 0
    $totalRemediated = 0
    $totalRemediationQueued = 0
    $totalRemediationPending = 0

    foreach ($audit in $campaignAudits) {
        $items = $audit['WrappedItems']
        $certs = $audit['Certifications']
        if ($null -eq $items -or $null -eq $certs) { continue }

        $proof = Group-SPAuditRemediationProof -Items $items -Certifications $certs
        if ($null -ne $proof) {
            $totalRevoked += $proof.TotalRevoked
            $totalRemediated += $(if ($proof.ContainsKey('RemediationRemovedCount')) { $proof.RemediationRemovedCount } else { $proof.RemediationCompleteCount })
            $totalRemediationQueued += $(if ($proof.ContainsKey('RemediationQueuedCount')) { $proof.RemediationQueuedCount } else { 0 })
            $totalRemediationPending += $proof.RemediationPendingCount
            foreach ($ri in $proof.RevokedItems) { $allRemediationProof.Add($ri) }
        }
    }

    $revocationTotal = $totalRevoked
    $revocationProvisioned = $totalRemediated
    $revocationQueued = $totalRemediationQueued
    $revocationExecutionRate = if ($totalRevoked -gt 0) {
        [math]::Round(($totalRemediated / $totalRevoked) * 100, 0)
    } else { 100 }

    $kpi3Status = Get-KpiStatus -Value $revocationExecutionRate `
        -GreenThreshold $thresholds.RevocationExecution.Green `
        -YellowThreshold $thresholds.RevocationExecution.Yellow

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    $detail = "$revocationProvisioned of $revocationTotal deprovisioned on AD ($revocationExecutionRate%); $revocationQueued queued elsewhere"
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
        -Severity WARN -Component 'DailyEvidence' -Action 'SlaError' -CorrelationID $correlationID
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
        Detail = "$revocationProvisioned of $revocationTotal deprovisioned on AD ($revocationQueued queued elsewhere)"
        TrendMetric = ''
    }
    @{
        Name = 'Remediation Timeliness'; Value = "$slaComplianceRate%"; Status = $kpi4Status
        Detail = "$($agingDetails.Count) pending remediation(s)"
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

    # Status color helper (returns CSS color)
    $statusColor = {
        param([string]$s)
        switch ($s) {
            'Green'  { '#339933' }
            'Yellow' { '#FF9900' }
            'Red'    { '#CC3333' }
            default  { '#777777' }
        }
    }
    $statusBg = {
        param([string]$s)
        switch ($s) {
            'Green'  { '#f0f9f0' }
            'Yellow' { '#fff8f0' }
            'Red'    { '#fdf0f0' }
            default  { '#f5f5f5' }
        }
    }
    $gradeColor = {
        param([string]$g)
        switch ($g) {
            'A' { '#339933' }
            'B' { '#339933' }
            'C' { '#FF9900' }
            'D' { '#CC3333' }
            'F' { '#CC3333' }
            default { '#777777' }
        }
    }

    # DOCTYPE and head
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<title>Daily Evidence Report - ' + (ConvertTo-SafeHtml $todayLabel) + '</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('*{box-sizing:border-box}')
    [void]$sb.AppendLine('body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}')
    [void]$sb.AppendLine('.container{max-width:1100px;margin:0 auto}')
    [void]$sb.AppendLine('.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}')
    [void]$sb.AppendLine('.header h1{margin:0 0 6px;font-size:22px}.header .meta{font-size:12px;opacity:.85}')
    [void]$sb.AppendLine('.header .status-line{margin-top:8px;font-size:13px;opacity:.9}')
    [void]$sb.AppendLine('.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}')
    [void]$sb.AppendLine('.section:last-of-type{border-radius:0 0 8px 8px}')
    [void]$sb.AppendLine('.section h2{color:#264d73;font-size:16px;border-bottom:2px solid #e8eef5;padding-bottom:8px;margin-top:0}')
    [void]$sb.AppendLine('.confidence-section{text-align:center;padding:24px 32px}')
    [void]$sb.AppendLine('.confidence-badge{display:inline-block;font-size:56px;font-weight:700;border:5px solid;border-radius:14px;padding:10px 28px;margin:8px 0}')
    [void]$sb.AppendLine('.confidence-score{font-size:18px;color:#555;margin-top:4px}')
    [void]$sb.AppendLine('.confidence-trend{font-size:13px;color:#777;margin-top:4px}')
    [void]$sb.AppendLine('.domino-section{padding:16px 32px}')
    [void]$sb.AppendLine('.domino-row{display:flex;align-items:center;justify-content:center;gap:0;flex-wrap:wrap;margin:12px 0}')
    [void]$sb.AppendLine('.domino-box{width:120px;padding:10px 6px;border-radius:6px;text-align:center;border:2px solid transparent}')
    [void]$sb.AppendLine('.domino-box.cascade{border-style:dashed;opacity:.85}')
    [void]$sb.AppendLine('.domino-label{font-size:11px;font-weight:600;text-transform:uppercase;margin-bottom:4px}')
    [void]$sb.AppendLine('.domino-status{font-size:20px;font-weight:700}')
    [void]$sb.AppendLine('.domino-arrow{font-size:20px;color:#999;padding:0 4px}')
    [void]$sb.AppendLine('.domino-Green{background:#e8f5e9;color:#2e7d32;border-color:#a5d6a7}')
    [void]$sb.AppendLine('.domino-Yellow{background:#fff3e0;color:#e65100;border-color:#ffcc80}')
    [void]$sb.AppendLine('.domino-Red{background:#ffebee;color:#c62828;border-color:#ef9a9a}')
    [void]$sb.AppendLine('.domino-narrative{font-size:13px;color:#555;text-align:center;margin-top:8px;font-style:italic}')
    [void]$sb.AppendLine('.kpi-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:16px 0}')
    [void]$sb.AppendLine('.kpi-tile{padding:16px;border-radius:6px;border-left:4px solid;position:relative}')
    [void]$sb.AppendLine('.kpi-title{font-size:12px;font-weight:600;text-transform:uppercase;color:#555;margin-bottom:6px}')
    [void]$sb.AppendLine('.kpi-value{font-size:28px;font-weight:700;margin-bottom:4px}')
    [void]$sb.AppendLine('.kpi-trend{font-size:12px;color:#777;margin-bottom:4px}')
    [void]$sb.AppendLine('.kpi-detail{font-size:12px;color:#666}')
    [void]$sb.AppendLine('.kpi-Green{border-left-color:#339933;background:#f0f9f0}.kpi-Green .kpi-value{color:#339933}')
    [void]$sb.AppendLine('.kpi-Yellow{border-left-color:#FF9900;background:#fff8f0}.kpi-Yellow .kpi-value{color:#FF9900}')
    [void]$sb.AppendLine('.kpi-Red{border-left-color:#CC3333;background:#fdf0f0}.kpi-Red .kpi-value{color:#CC3333}')
    [void]$sb.AppendLine('.evidence-section{padding:20px 32px}')
    [void]$sb.AppendLine('.evidence-section h2{color:#264d73;font-size:15px;border-bottom:2px solid #e8eef5;padding-bottom:6px;margin-top:0}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:12px 0;font-size:12px}')
    [void]$sb.AppendLine('th{background:#e8eef5;padding:8px 10px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;color:#555}')
    [void]$sb.AppendLine('td{padding:7px 10px;border-bottom:1px solid #eee}tr:nth-child(even){background:#fafafa}')
    [void]$sb.AppendLine('.status-green{color:#339933;font-weight:600}.status-yellow{color:#FF9900;font-weight:600}')
    [void]$sb.AppendLine('.status-red{color:#CC3333;font-weight:600}.status-gray{color:#777}')
    [void]$sb.AppendLine('.aging-bar{height:14px;border-radius:3px;display:inline-block;min-width:2px}')
    [void]$sb.AppendLine('.aging-bar-ok{background:#339933}.aging-bar-warn{background:#FF9900}.aging-bar-crit{background:#CC3333}')
    [void]$sb.AppendLine('.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}')
    [void]$sb.AppendLine('.badge-green{background:#c8e6c9;color:#1b5e20}.badge-yellow{background:#fff9c4;color:#f57f17}')
    [void]$sb.AppendLine('.badge-red{background:#ffcdd2;color:#b71c1c}.badge-gray{background:#eee;color:#555}')
    [void]$sb.AppendLine('.footer{text-align:center;color:#999;font-size:11px;padding:16px;border-top:1px solid #eee;margin-top:0}')
    [void]$sb.AppendLine('@media print{body{background:#fff;padding:0}.container{max-width:100%}.header{border-radius:0}}')
    [void]$sb.AppendLine('@media (max-width:768px){.kpi-grid{grid-template-columns:1fr}.domino-row{flex-direction:column}.domino-arrow{transform:rotate(90deg)}}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<div class="container">')

    # Header
    $envName = ''
    if ($null -ne $config.PSObject.Properties['Environment'] -and -not [string]::IsNullOrWhiteSpace($config.Environment)) {
        $envName = ' | Env: ' + (ConvertTo-SafeHtml $config.Environment)
    }
    $kpiRedCount    = @($kpiSummary | Where-Object { $_.Status -eq 'Red' }).Count
    $kpiYellowCount = @($kpiSummary | Where-Object { $_.Status -eq 'Yellow' }).Count
    $kpiGreenCount  = @($kpiSummary | Where-Object { $_.Status -eq 'Green' }).Count
    $statusSummary  = "$kpiGreenCount Green, $kpiYellowCount Yellow, $kpiRedCount Red"

    [void]$sb.AppendLine('<div class="header">')
    [void]$sb.AppendLine('<h1>Daily Evidence Report</h1>')
    [void]$sb.AppendLine('<div class="meta">SailPoint ISC Governance Toolkit | ' + (ConvertTo-SafeHtml $todayLabel) + ' | Period: Last ' + $effectiveDaysBack + ' day(s)' + $envName + '</div>')
    [void]$sb.AppendLine('<div class="status-line">KPIs: ' + (ConvertTo-SafeHtml $statusSummary) + ' | Confidence: ' + (ConvertTo-SafeHtml $confidenceGrade) + ' (' + $confidenceScore + '/100)</div>')
    [void]$sb.AppendLine('</div>')

    # Confidence section
    $cGradeColor = & $gradeColor $confidenceGrade
    [void]$sb.AppendLine('<div class="section confidence-section">')
    [void]$sb.AppendLine('<h2>Governance Confidence Score</h2>')
    [void]$sb.AppendLine('<div class="confidence-badge" style="color:' + $cGradeColor + ';border-color:' + $cGradeColor + '">' + (ConvertTo-SafeHtml $confidenceGrade) + '</div>')
    [void]$sb.AppendLine('<div class="confidence-score">' + $confidenceScore + ' / 100 (Level: ' + (ConvertTo-SafeHtml $confidenceLevel) + ')</div>')

    # Trend line for confidence
    $confTrend = Get-TrendArrow -MetricName 'maturity.overallScore' -TrendResult $trendData
    if ($confTrend.Arrow -ne '') {
        $arrowHtml = switch ($confTrend.Arrow) {
            'up'   { '&#9650;' }
            'down' { '&#9660;' }
            default { '&#9654;' }
        }
        [void]$sb.AppendLine('<div class="confidence-trend">' + $arrowHtml + ' ' + (ConvertTo-SafeHtml $confTrend.Delta) + ' vs prior period</div>')
    }
    [void]$sb.AppendLine('<div style="font-size:12px;color:#777;margin-top:10px;max-width:600px;margin-left:auto;margin-right:auto;line-height:1.5">')
    [void]$sb.AppendLine('The Governance Confidence Score is computed across six dimensions: Coverage (are all entitlements reviewed?), Timeliness (are reviews completed on schedule?), Enforcement (are revocations carried out?), Accountability (are reviewers performing responsibly?), Documentation (is evidence being captured?), and Automation (is the governance process automated?). Each dimension contributes equally to the overall score. Grade: A (90+), B (80-89), C (70-79), D (60-69), F (below 60).')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div>')

    # Domino section
    [void]$sb.AppendLine('<div class="section domino-section">')
    [void]$sb.AppendLine('<h2>Cascading Risk Tracker</h2>')
    [void]$sb.AppendLine('<div style="text-align:center;font-size:11px;color:#777;margin-bottom:4px"><span style="color:#339933">Green = On Target</span> &nbsp;|&nbsp; <span style="color:#FF9900">Yellow = Needs Attention</span> &nbsp;|&nbsp; <span style="color:#CC3333">Red = Action Required</span></div>')
    [void]$sb.AppendLine('<div class="domino-row">')
    foreach ($i in 0..($dominoChain.Count - 1)) {
        $box = $dominoChain[$i]
        $cascadeClass = if ($box['CascadeHighlight']) { ' cascade' } else { '' }
        $statusWord = $box.Status
        if ($i -gt 0) {
            [void]$sb.AppendLine('<div class="domino-arrow">&rarr;</div>')
        }
        [void]$sb.AppendLine('<div class="domino-box domino-' + $box.Status + $cascadeClass + '">')
        [void]$sb.AppendLine('<div class="domino-label">' + (ConvertTo-SafeHtml $box.ShortName) + '</div>')
        [void]$sb.AppendLine('<div class="domino-status" style="font-size:14px">' + (ConvertTo-SafeHtml $statusWord) + '</div>')
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<div class="domino-narrative">' + (ConvertTo-SafeHtml $dominoNarrative) + '</div>')
    [void]$sb.AppendLine('</div>')

    # KPI grid
    [void]$sb.AppendLine('<div class="section">')
    [void]$sb.AppendLine('<h2>KPI Dashboard</h2>')
    [void]$sb.AppendLine('<div class="kpi-grid">')
    foreach ($kpi in $kpiSummary) {
        $trend = Get-TrendArrow -MetricName $kpi.TrendMetric -TrendResult $trendData
        $trendHtml = ''
        if ($trend.Arrow -ne '') {
            $tArrow = switch ($trend.Arrow) {
                'up'   { '&#9650;' }
                'down' { '&#9660;' }
                default { '&#9654;' }
            }
            $trendHtml = "$tArrow $($trend.Delta)"
        }
        [void]$sb.AppendLine('<div class="kpi-tile kpi-' + $kpi.Status + '">')
        [void]$sb.AppendLine('<div class="kpi-title">' + (ConvertTo-SafeHtml $kpi.Name) + '</div>')
        [void]$sb.AppendLine('<div class="kpi-value">' + (ConvertTo-SafeHtml ([string]$kpi.Value)) + '</div>')
        if ($trendHtml) {
            [void]$sb.AppendLine('<div class="kpi-trend">' + $trendHtml + '</div>')
        }
        [void]$sb.AppendLine('<div class="kpi-detail">' + (ConvertTo-SafeHtml $kpi.Detail) + '</div>')
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div>')

    # Sources in Scope section
    if ($sourceCountMap.Count -gt 0) {
        [void]$sb.AppendLine('<div class="section">')
        [void]$sb.AppendLine('<h2>Sources in Scope</h2>')
        [void]$sb.AppendLine('<div style="display:flex;flex-wrap:wrap;gap:12px">')
        foreach ($srcName in $sourceCountMap.Keys) {
            $srcCount = $sourceCountMap[$srcName]
            $srcCountFormatted = '{0:N0}' -f $srcCount
            [void]$sb.AppendLine('<div style="background:#f8f9fa;border:1px solid #e0e0e0;border-radius:6px;padding:10px 16px;min-width:150px">')
            [void]$sb.AppendLine('<div style="font-size:11px;font-weight:600;text-transform:uppercase;color:#555">' + (ConvertTo-SafeHtml $srcName) + '</div>')
            [void]$sb.AppendLine('<div style="font-size:20px;font-weight:700;color:#264d73">' + $srcCountFormatted + '</div>')
            [void]$sb.AppendLine('<div style="font-size:11px;color:#777">access items</div>')
            [void]$sb.AppendLine('</div>')
        }
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('</div>')
    }

    # Evidence Section A: Campaign Completion Evidence
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>A. Campaign Completion Evidence</h2>')
    [void]$sb.AppendLine('<table><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Completion %</th><th>Deadline Status</th><th>Created</th><th>Completed</th></tr></thead><tbody>')
    foreach ($audit in $campaignAudits) {
        $cName   = ConvertTo-SafeHtml $audit['CampaignName']
        $cStatus = ConvertTo-SafeHtml $audit['Status']
        $d = $audit['Decisions']
        $cApproved = if ($null -ne $d -and $null -ne $d['Approved']) { @($d['Approved']).Count } else { 0 }
        $cRevoked  = if ($null -ne $d -and $null -ne $d['Revoked'])  { @($d['Revoked']).Count }  else { 0 }
        $cPending  = if ($null -ne $d -and $null -ne $d['Pending'])  { @($d['Pending']).Count }  else { 0 }
        $cTotal    = $cApproved + $cRevoked + $cPending
        $cDecided  = $cApproved + $cRevoked
        $cPct      = if ($cTotal -gt 0) { [math]::Round(($cDecided / $cTotal) * 100, 0) } else { 0 }

        # Deadline status
        $deadlineStatus = 'N/A'
        $deadlineClass  = 'status-gray'
        $deadlineStr    = $audit['Deadline']
        if (-not [string]::IsNullOrWhiteSpace($deadlineStr)) {
            try {
                $dl = [datetime]::Parse($deadlineStr)
                $hoursLeft = ($dl.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalHours
                if ($audit['Status'] -eq 'COMPLETED') { $deadlineStatus = 'Completed'; $deadlineClass = 'status-green' }
                elseif ($hoursLeft -le 0) { $deadlineStatus = 'Overdue'; $deadlineClass = 'status-red' }
                elseif ($hoursLeft -le 24) {
                    $hrsDisplay = [math]::Round($hoursLeft, 0)
                    $deadlineStatus = "Due in ${hrsDisplay}h"; $deadlineClass = 'status-yellow'
                }
                else {
                    $daysDisplay = [math]::Round($hoursLeft / 24, 0)
                    $deadlineStatus = "Due in ${daysDisplay}d"; $deadlineClass = 'status-green'
                }
            } catch { }
        }
        if ($audit['Status'] -eq 'COMPLETED') { $deadlineStatus = 'Completed'; $deadlineClass = 'status-green' }

        $pctClass = if ($cPct -ge 80) { 'status-green' } elseif ($cPct -ge 50) { 'status-yellow' } else { 'status-red' }
        $createdDisplay   = ConvertTo-SafeHtml $audit['Created']
        $completedDisplay = ConvertTo-SafeHtml $audit['Completed']
        if ([string]::IsNullOrWhiteSpace($completedDisplay)) { $completedDisplay = '-' }

        [void]$sb.AppendLine("<tr><td>$cName</td><td>$cStatus</td><td>$cTotal</td><td class=`"$pctClass`">${cPct}%</td><td class=`"$deadlineClass`">$deadlineStatus</td><td>$createdDisplay</td><td>$completedDisplay</td></tr>")
    }
    [void]$sb.AppendLine('</tbody></table>')
    [void]$sb.AppendLine('</div>')

    # Evidence Section B: Reviewer Accountability
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>B. Reviewer Accountability</h2>')

    $hasAnyReviewerData = $false
    foreach ($audit in $campaignAudits) {
        $ra = $audit['ReviewerActions']
        if ($null -eq $ra) { continue }

        $primaryRows = $ra['Primary']
        $reassignedRows = $ra['Reassigned']
        $primaryCount = if ($null -ne $primaryRows) { @($primaryRows).Count } else { 0 }
        $reassignedCount = if ($null -ne $reassignedRows) { @($reassignedRows).Count } else { 0 }
        if ($primaryCount -eq 0 -and $reassignedCount -eq 0) { continue }
        $hasAnyReviewerData = $true

        [void]$sb.AppendLine('<h3 style="font-size:13px;color:#264d73;margin:16px 0 8px 0">' + (ConvertTo-SafeHtml $audit['CampaignName']) + '</h3>')

        # Split primary reviewers into Signed Off and Active
        $signedOff = @()
        $active = @()
        if ($primaryCount -gt 0) {
            $signedOff = @($primaryRows | Where-Object { $_.Phase -eq 'SIGNED' } | Sort-Object -Property Name)
            $active = @($primaryRows | Where-Object { $_.Phase -ne 'SIGNED' } | Sort-Object -Property Name)
        }

        # Signed Off Reviewers
        [void]$sb.AppendLine('<details open>')
        [void]$sb.AppendLine('<summary style="font-weight:bold;font-size:12px;margin-bottom:4px;cursor:pointer">Signed Off (' + $signedOff.Count + ')</summary>')
        if ($signedOff.Count -eq 0) {
            [void]$sb.AppendLine('<p style="color:#777;font-size:12px;font-style:italic">No reviewers have signed off yet.</p>')
        }
        else {
            [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Email</th><th>Certs Assigned</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th></tr></thead><tbody>')
            foreach ($r in $signedOff) {
                $soDate = if (-not [string]::IsNullOrWhiteSpace($r.SignOffDate)) { ConvertTo-SafeHtml $r.SignOffDate } else { '-' }
                [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $r.Name) + '</td><td>' + (ConvertTo-SafeHtml $r.Email) + '</td><td>' + $r.CertsAssigned + '</td><td>' + $r.DecisionsMade + '</td><td>' + $soDate + '</td><td class="status-green">' + (ConvertTo-SafeHtml $r.Phase) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        [void]$sb.AppendLine('</details>')

        # Active Reviewers
        [void]$sb.AppendLine('<details open>')
        [void]$sb.AppendLine('<summary style="font-weight:bold;font-size:12px;margin-bottom:4px;margin-top:8px;cursor:pointer">Active (' + $active.Count + ')</summary>')
        if ($active.Count -eq 0) {
            [void]$sb.AppendLine('<p style="color:#777;font-size:12px;font-style:italic">No active reviewers.</p>')
        }
        else {
            [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Email</th><th>Certs Assigned</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th></tr></thead><tbody>')
            foreach ($r in $active) {
                $soDate = if (-not [string]::IsNullOrWhiteSpace($r.SignOffDate)) { ConvertTo-SafeHtml $r.SignOffDate } else { '-' }
                [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $r.Name) + '</td><td>' + (ConvertTo-SafeHtml $r.Email) + '</td><td>' + $r.CertsAssigned + '</td><td>' + $r.DecisionsMade + '</td><td>' + $soDate + '</td><td class="status-yellow">' + (ConvertTo-SafeHtml $r.Phase) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        [void]$sb.AppendLine('</details>')

        # Reassigned Reviewers (if any)
        if ($reassignedCount -gt 0) {
            [void]$sb.AppendLine('<details>')
            [void]$sb.AppendLine('<summary style="font-weight:bold;font-size:12px;margin-bottom:4px;margin-top:8px;cursor:pointer">Reassigned (' + $reassignedCount + ')</summary>')
            [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Email</th><th>Reassigned From</th><th>Decisions Made</th><th>Sign-Off Date</th><th>Phase</th></tr></thead><tbody>')
            foreach ($r in @($reassignedRows | Sort-Object -Property Name)) {
                $soDate = if (-not [string]::IsNullOrWhiteSpace($r.SignOffDate)) { ConvertTo-SafeHtml $r.SignOffDate } else { '-' }
                $phaseClass = if ($r.Phase -eq 'SIGNED') { 'status-green' } else { 'status-yellow' }
                [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $r.Name) + '</td><td>' + (ConvertTo-SafeHtml $r.Email) + '</td><td>' + (ConvertTo-SafeHtml $r.ReassignedFrom) + '</td><td>' + $r.DecisionsMade + '</td><td>' + $soDate + '</td><td class="' + $phaseClass + '">' + (ConvertTo-SafeHtml $r.Phase) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
            [void]$sb.AppendLine('</details>')
        }
    }

    if (-not $hasAnyReviewerData) {
        [void]$sb.AppendLine('<p style="color:#777">No reviewer accountability data available.</p>')
    }
    [void]$sb.AppendLine('</div>')

    # Evidence Section C: Revocation & Remediation Register with Aging Chart
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>C. Revocation &amp; Remediation Register</h2>')

    # Aging bucket chart (CSS-only horizontal bars)
    $maxBucketCount = ($agingBuckets.Values | Measure-Object -Maximum).Maximum
    if ($null -eq $maxBucketCount -or $maxBucketCount -eq 0) { $maxBucketCount = 1 }
    [void]$sb.AppendLine('<div style="margin:12px 0 20px 0">')
    [void]$sb.AppendLine('<p style="font-size:12px;font-weight:600;color:#555;margin-bottom:8px">Remediation Aging</p>')
    foreach ($bucketName in $agingBuckets.Keys) {
        $count = $agingBuckets[$bucketName]
        $barWidth = [math]::Round(($count / $maxBucketCount) * 200, 0)
        if ($barWidth -lt 2 -and $count -gt 0) { $barWidth = 2 }
        $barClass = switch ($bucketName) {
            '0-24h'  { 'aging-bar-ok' }
            '24-48h' { 'aging-bar-ok' }
            '2-5d'   { 'aging-bar-warn' }
            '5-10d'  { 'aging-bar-warn' }
            '>10d'   { 'aging-bar-crit' }
            default  { 'aging-bar-ok' }
        }
        [void]$sb.AppendLine('<div style="display:flex;align-items:center;margin:3px 0"><span style="width:60px;font-size:11px;color:#555">' + (ConvertTo-SafeHtml $bucketName) + '</span><div class="aging-bar ' + $barClass + '" style="width:' + $barWidth + 'px"></div><span style="font-size:11px;color:#777;margin-left:6px">' + $count + '</span></div>')
    }
    [void]$sb.AppendLine('</div>')

    # Remediation detail table
    if ($allRemediationProof.Count -gt 0) {
        $remItems = @($allRemediationProof | Select-Object -First $evidenceDetailLimit)
        [void]$sb.AppendLine('<table><thead><tr><th>Identity</th><th>Access</th><th>Decision Date</th><th>Status</th><th>Days Since Decision</th><th>Source</th></tr></thead><tbody>')
        foreach ($item in $remItems) {
            $remDisp = if ($item.PSObject.Properties['RemediationDisposition']) { [string]$item.RemediationDisposition } else { '' }
            $remLabel = switch ($remDisp) {
                'Removed' { 'Deprovisioned' }
                'Queued'  { 'Queued for removal' }
                'Pending' { 'Pending removal' }
                default   { if ($item.RemediationComplete) { 'Deprovisioned' } else { 'Pending removal' } }
            }
            $remStatusClass = switch ($remDisp) { 'Removed' { 'status-green' } 'Queued' { 'status-yellow' } 'Pending' { 'status-yellow' } default { if ($item.RemediationComplete) { 'status-green' } else { 'status-yellow' } } }
            $daysToRemediate = ''
            if ($null -ne $item.DecisionDate -and -not [string]::IsNullOrWhiteSpace($item.DecisionDate)) {
                try {
                    $dd = [datetime]::Parse($item.DecisionDate)
                    $ageD = [math]::Round(([datetime]::UtcNow - $dd.ToUniversalTime()).TotalDays, 1)
                    $daysToRemediate = "$ageD"
                } catch { }
            }
            $sourceName = if ($null -ne $item.SourceName) { ConvertTo-SafeHtml $item.SourceName } else { '' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $item.IdentityName) + '</td><td>' + (ConvertTo-SafeHtml $item.AccessName) + '</td><td>' + (ConvertTo-SafeHtml $item.DecisionDate) + '</td><td class="' + $remStatusClass + '">' + $remLabel + '</td><td>' + $daysToRemediate + '</td><td>' + $sourceName + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
        if ($allRemediationProof.Count -gt $evidenceDetailLimit) {
            [void]$sb.AppendLine('<p style="color:#777;font-size:11px">Showing ' + $evidenceDetailLimit + ' of ' + $allRemediationProof.Count + ' records.</p>')
        }
    }
    else {
        [void]$sb.AppendLine('<p style="color:#777">No revocation decisions in this period.</p>')
    }
    [void]$sb.AppendLine('</div>')

    # Evidence Section D: Past-Due / At-Risk Campaign Register
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>D. Past-Due / At-Risk Campaign Register</h2>')
    if ($overdueAtRiskCampaigns.Count -eq 0) {
        [void]$sb.AppendLine('<p style="color:#339933;font-weight:600">No overdue or at-risk campaigns detected.</p>')
    }
    else {
        [void]$sb.AppendLine('<table><thead><tr><th>Campaign</th><th>Health Status</th><th>Projected</th><th>Days to Deadline</th><th>Completion %</th><th>Bottleneck Reviewers</th></tr></thead><tbody>')
        foreach ($c in $overdueAtRiskCampaigns) {
            $hClass = switch ($c.HealthStatus) {
                'Overdue'  { 'status-red' }
                'AtRisk'   { 'status-yellow' }
                'Stalled'  { 'status-red' }
                default    { 'status-gray' }
            }
            $projClass = switch ($c.ProjectedStatus) {
                'AtRisk'  { 'status-yellow' }
                'Stalled' { 'status-red' }
                default   { 'status-gray' }
            }
            $projDisplay = if ([string]::IsNullOrWhiteSpace($c.ProjectedStatus)) { '-' } else { ConvertTo-SafeHtml $c.ProjectedStatus }
            $daysDisplay = if ([string]::IsNullOrWhiteSpace("$($c.DaysToDeadline)")) { '-' } else { "$($c.DaysToDeadline)" }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $c.CampaignName) + '</td><td class="' + $hClass + '">' + (ConvertTo-SafeHtml $c.HealthStatus) + '</td><td class="' + $projClass + '">' + $projDisplay + '</td><td>' + $daysDisplay + '</td><td>' + $c.CompletionPct + '%</td><td>' + (ConvertTo-SafeHtml $c.BottleneckReviewers) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</div>')

    # Evidence Section E: High-Risk Pending Review Register
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>E. High-Risk Pending Review Register</h2>')
    if ($highRiskPending.Count -eq 0) {
        [void]$sb.AppendLine('<p style="color:#339933;font-weight:600">No high-risk identities with pending reviews.</p>')
    }
    else {
        $limitedHighRisk = @($highRiskPending | Select-Object -First $evidenceDetailLimit)
        [void]$sb.AppendLine('<table><thead><tr><th>Identity</th><th>Risk Score</th><th>Access</th><th>Source</th><th>Campaign</th></tr></thead><tbody>')
        foreach ($hr in $limitedHighRisk) {
            $scoreClass = if ($hr.RiskScore -ge 80) { 'status-red' } else { 'status-yellow' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $hr.IdentityName) + '</td><td class="' + $scoreClass + '">' + $hr.RiskScore + '</td><td>' + (ConvertTo-SafeHtml $hr.AccessName) + '</td><td>' + (ConvertTo-SafeHtml $hr.SourceName) + '</td><td>' + (ConvertTo-SafeHtml $hr.CampaignName) + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
        if ($highRiskPending.Count -gt $evidenceDetailLimit) {
            [void]$sb.AppendLine('<p style="color:#777;font-size:11px">Showing ' + $evidenceDetailLimit + ' of ' + $highRiskPending.Count + ' records.</p>')
        }
    }
    [void]$sb.AppendLine('</div>')

    # Evidence Section F: Reviewer Performance Register
    [void]$sb.AppendLine('<div class="section evidence-section">')
    [void]$sb.AppendLine('<h2>F. Reviewer Performance Register</h2>')
    if ($null -ne $reviewerReputationData -and $null -ne $reviewerReputationData.Reviewers -and @($reviewerReputationData.Reviewers).Count -gt 0) {
        $sortedReviewers = @($reviewerReputationData.Reviewers | Sort-Object -Property ReviewerName)
        $limitedReviewers = @($sortedReviewers | Select-Object -First $evidenceDetailLimit)
        [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Score</th><th>Tier</th><th>Avg Response (hrs)</th><th>Rubber-Stamp Count</th></tr></thead><tbody>')
        foreach ($rev in $limitedReviewers) {
            $tierBadge = switch ($rev.ReputationTier) {
                'Excellent'       { '<span class="badge badge-green">Excellent</span>' }
                'Good'            { '<span class="badge badge-green">Good</span>' }
                'Needs Attention' { '<span class="badge badge-yellow">Needs Attention</span>' }
                'At Risk'         { '<span class="badge badge-red">At Risk</span>' }
                default           { '<span class="badge badge-gray">' + (ConvertTo-SafeHtml $rev.ReputationTier) + '</span>' }
            }
            $avgHrs  = if ($null -ne $rev.AvgResponseHours) { '{0:F1}' -f $rev.AvgResponseHours } else { 'N/A' }
            $rsCount = if ($null -ne $rev.RubberStampCount) { $rev.RubberStampCount } else { 0 }
            $scoreColor = if ($rev.ReputationScore -ge 80) { 'status-green' } elseif ($rev.ReputationScore -ge 60) { 'status-yellow' } else { 'status-red' }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $rev.ReviewerName) + '</td><td class="' + $scoreColor + '">' + $rev.ReputationScore + '</td><td>' + $tierBadge + '</td><td>' + $avgHrs + '</td><td>' + $rsCount + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    else {
        [void]$sb.AppendLine('<p style="color:#777">No reviewer data available.</p>')
    }
    [void]$sb.AppendLine('</div>')

    # Footer
    [void]$sb.AppendLine('<div class="footer">')
    [void]$sb.AppendLine('SailPoint ISC Governance Toolkit - Daily Evidence Report v1.0.0<br>')
    [void]$sb.AppendLine('CorrelationID: ' + (ConvertTo-SafeHtml $correlationID) + ' | Generated: ' + (ConvertTo-SafeHtml $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) + ' | Duration: ' + (ConvertTo-SafeHtml $durationStr))
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('</div></body></html>')

    $htmlContent = $sb.ToString()
    $htmlFileName = 'daily-evidence-{0}.html' -f $startTime.ToString('yyyyMMdd-HHmmss')
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
            RevocationsExecuted  = [ordered]@{ Value = $revocationExecutionRate; Status = $kpi3Status; Detail = "$revocationProvisioned of $revocationTotal deprovisioned on AD ($revocationQueued queued elsewhere)" }
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
    $auditFile = Join-Path $effectiveOutputPath 'daily-evidence-audit.jsonl'
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
