#Requires -Version 5.1
<#
.SYNOPSIS
    Captures governance KPIs to the time-series store, generates trend reports,
    and optionally checks active campaign completion forecasts.
.DESCRIPTION
    Orchestrates governance metrics capture, trend analysis, and campaign
    completion forecasting into a single CLI command:
    - Current Analytics: computes identity risk, source governance, campaign
      metrics, reviewer reputation, stale access, governance maturity, and
      orchestrator history, then saves to the JSONL time-series store (P16-06).
    - Campaign Completion Forecast (P16-05): predicts whether active campaigns
      will finish before their deadlines based on decision velocity.
    - Trend Analysis: reads historical metrics and computes period-over-period
      direction for each KPI.

    Designed for scheduled execution (cron/Task Scheduler) after the daily
    orchestrator and weekly digest. Captures governance state at regular
    intervals so long-term trends are preserved even after raw audit data
    is archived by retention policies.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication.
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER SourceId
    Source IDs to scope analytics. If omitted, uses configured sources.
.PARAMETER DaysBack
    Campaign lookback window in days for current analytics. Default 90.
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name filter. Combined with the DaysBack window.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix.
.PARAMETER CampaignNameContains
    Campaign name contains this substring (ISC 'co' filter).
.PARAMETER CaptureOnly
    Save metrics without generating trend report.
.PARAMETER TrendOnly
    Generate trend report without computing new analytics.
.PARAMETER IncludeCompletionForecast
    Add campaign completion forecasts to output.
.PARAMETER TrendDaysBack
    Number of days of historical data for trend analysis. Default 180.
.PARAMETER TrendGranularity
    Grouping period for trend analysis: Daily, Weekly, or Monthly. Default Weekly.
.PARAMETER OutputMode
    Output format: Console, HTML, JSON, or Both (Console + HTML). Default Console.
.PARAMETER OutputPath
    Directory for HTML/JSON output files.
.PARAMETER AlertOnDecline
    Send notification when metrics decline >5% over last 4 periods.
.PARAMETER AlertRecipients
    Email addresses for decline alert delivery.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be captured without making API calls.
.EXAMPLE
    .\Invoke-SPGovernanceMetrics.ps1 -Token $token
    # Capture current metrics and display trend summary.
.EXAMPLE
    .\Invoke-SPGovernanceMetrics.ps1 -IncludeCompletionForecast -TrendGranularity Weekly -Token $token
    # Full capture with campaign forecasts and weekly trends.
.EXAMPLE
    .\Invoke-SPGovernanceMetrics.ps1 -TrendOnly -TrendDaysBack 180 -OutputMode Console
    # Trend report only, no new capture.
.EXAMPLE
    .\Invoke-SPGovernanceMetrics.ps1 -CaptureOnly -Token $token
    # Capture metrics only, no trend report.
.EXAMPLE
    .\Invoke-SPGovernanceMetrics.ps1 -WhatIf
    # Dry run -- shows what would be captured without API calls.
.NOTES
    Script:  Invoke-SPGovernanceMetrics.ps1
    Version: 1.0.0
    Phase:   P16-09
    Exit codes:
        0 = Metrics captured, no declining trends
        1 = Metrics captured, declining metrics detected
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical failure (cannot compute or save metrics)
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    [Parameter()]
    [int]$DaysBack = 90,

    # Campaign name filters (optional; combined with the DaysBack window)
    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    # Modes
    [Parameter()]
    [switch]$CaptureOnly,

    [Parameter()]
    [switch]$TrendOnly,

    [Parameter()]
    [switch]$IncludeCompletionForecast,

    # Trend options
    [Parameter()]
    [int]$TrendDaysBack = 180,

    [Parameter()]
    [ValidateSet('Daily', 'Weekly', 'Monthly')]
    [string]$TrendGranularity = 'Weekly',

    # Output
    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    # Alerting
    [Parameter()]
    [switch]$AlertOnDecline,

    [Parameter()]
    [string[]]$AlertRecipients,

    [Parameter()]
    [Alias('?')]
    [switch]$Help,

    # Note: -WhatIf is provided automatically by SupportsShouldProcess
    [Parameter()]
    [switch]$WhatIf
)

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

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Governance Metrics Capture & Trend' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

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

Write-SPLog -Message "Invoke-SPGovernanceMetrics started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'GovernanceMetrics' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    if ($null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = [string]$config.Audit.OutputPath
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot 'Audit'
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

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true) -or $WhatIf

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following actions would be performed:' -ForegroundColor Yellow
    Write-Host ''
    if (-not $TrendOnly) {
        Write-Host "  [1] Current Analytics: campaigns from last $DaysBack days" -ForegroundColor Gray
        Write-Host '      -> Measure-SPIdentityRisk, Measure-SPSourceGovernance,' -ForegroundColor Gray
        Write-Host '         Measure-SPCampaignMetrics, Measure-SPReviewerReputation,' -ForegroundColor Gray
        Write-Host '         Get-SPStaleAccess, Measure-SPGovernanceMaturity,' -ForegroundColor Gray
        Write-Host '         Get-SPOrchestratorHistory' -ForegroundColor Gray
        Write-Host '      -> Save-SPGovernanceMetrics' -ForegroundColor Gray
    }
    else {
        Write-Host '  [1] Current Analytics: SKIPPED (TrendOnly mode)' -ForegroundColor DarkGray
    }
    if ($IncludeCompletionForecast -and -not $TrendOnly) {
        Write-Host '  [2] Campaign Completion Forecast: active campaigns' -ForegroundColor Gray
    }
    else {
        Write-Host '  [2] Campaign Completion Forecast: SKIPPED' -ForegroundColor DarkGray
    }
    if (-not $CaptureOnly) {
        Write-Host "  [3] Trend Analysis: $TrendDaysBack days, $TrendGranularity granularity" -ForegroundColor Gray
    }
    else {
        Write-Host '  [3] Trend Analysis: SKIPPED (CaptureOnly mode)' -ForegroundColor DarkGray
    }
    if ($AlertOnDecline) {
        Write-Host '  [4] Decline Alerting: >5% decline over 4 periods' -ForegroundColor Gray
    }
    else {
        Write-Host '  [4] Decline Alerting: SKIPPED' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

#endregion

#region Step Tracking

$stepResults = [ordered]@{
    CurrentAnalytics     = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    MetricsSave          = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    CompletionForecast   = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    TrendAnalysis        = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    DeclineDetection     = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
}

$worstExitCode = 0

function Set-StepResult {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Detail,
        [double]$Duration
    )
    $stepResults[$Step] = @{ Status = $Status; Detail = $Detail; Duration = $Duration }
}

# Data holders
$identityRiskData       = $null
$sourceGovernanceData   = $null
$campaignMetricsData    = $null
$reviewerReputationData = $null
$staleAccessData        = $null
$governanceMaturityData = $null
$orchestratorData       = $null
$saveResult             = $null
$forecastData           = $null
$trendData              = $null
$campaignAudits         = @()
$currentCampaigns       = @()
$decliningMetrics       = @()

#endregion

#region Step 1: Current Analytics (unless -TrendOnly)

if (-not $TrendOnly) {
    Write-Host '  Step 1: Current Analytics' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Fetch campaigns
        Write-Host '    Fetching campaigns...' -ForegroundColor DarkGray
        $campaignParams = @{ DaysBack = $DaysBack; CorrelationID = $correlationID }
        if ($CampaignName)           { $campaignParams['CampaignName']           = $CampaignName }
        if ($CampaignNameStartsWith) { $campaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
        if ($CampaignNameContains)   { $campaignParams['CampaignNameContains']   = $CampaignNameContains }
        $campaignResult = Get-SPAuditCampaigns @campaignParams
        if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
            $currentCampaigns = @($campaignResult.Data)
        }
        Write-Host "    Found $($currentCampaigns.Count) campaign(s) in last $DaysBack days." -ForegroundColor DarkGray

        # Build campaign audit data for analytics functions
        if ($currentCampaigns.Count -gt 0) {
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

                    # Cached items: pass the certs already fetched; items return pre-wrapped.
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
                    }
                    $auditList.Add($campaignAudit)
                }
                catch {
                    Write-Host "    WARN: Failed to process $campName : $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-SPLog -Message "Campaign audit build failed for ${campName}: $($_.Exception.Message)" `
                        -Severity WARN -Component 'GovernanceMetrics' -Action 'AuditBuildError' -CorrelationID $correlationID
                }
            }

            $campaignAudits = $auditList.ToArray()
            Write-Host "    Built audit data for $($campaignAudits.Count) campaign(s)." -ForegroundColor DarkGray
        }

        # Compute analytics
        Write-Host '    Computing analytics...' -ForegroundColor DarkGray

        # Identity Risk
        if ($campaignAudits.Count -gt 0) {
            try {
                $identityRiskData = Measure-SPIdentityRisk -CampaignAudits $campaignAudits `
                    -CorrelationID $correlationID
            }
            catch {
                Write-Host "    WARN: Measure-SPIdentityRisk: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Source Governance
        if ($campaignAudits.Count -gt 0) {
            try {
                $sourceGovernanceData = Measure-SPSourceGovernance -CampaignAudits $campaignAudits `
                    -CorrelationID $correlationID
            }
            catch {
                Write-Host "    WARN: Measure-SPSourceGovernance: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Campaign Metrics
        if ($currentCampaigns.Count -gt 0) {
            try {
                $metricsResult = Measure-SPCampaignMetrics -Campaigns $currentCampaigns `
                    -CorrelationID $correlationID
                if ($metricsResult.Success -and $null -ne $metricsResult.Data) {
                    $campaignMetricsData = $metricsResult
                }
            }
            catch {
                Write-Host "    WARN: Measure-SPCampaignMetrics: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Reviewer Reputation
        if ($campaignAudits.Count -gt 0) {
            try {
                $reviewerReputationData = Measure-SPReviewerReputation -CampaignAudits $campaignAudits `
                    -MinCampaigns 1 -CorrelationID $correlationID
            }
            catch {
                Write-Host "    WARN: Measure-SPReviewerReputation: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Stale Access
        if ($campaignAudits.Count -gt 0) {
            try {
                $staleAccessData = Get-SPStaleAccess -CampaignAudits $campaignAudits `
                    -CorrelationID $correlationID
            }
            catch {
                Write-Host "    WARN: Get-SPStaleAccess: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # Governance Maturity
        try {
            $maturityParams = @{ CorrelationID = $correlationID }
            if ($null -ne $sourceGovernanceData)   { $maturityParams['SourceGovernance']   = $sourceGovernanceData }
            if ($null -ne $identityRiskData)        { $maturityParams['IdentityRisk']       = $identityRiskData }
            if ($null -ne $reviewerReputationData)  { $maturityParams['ReviewerReputation']  = $reviewerReputationData }
            if ($null -ne $campaignMetricsData)      { $maturityParams['CampaignMetrics']     = $campaignMetricsData }
            if ($null -ne $staleAccessData)          { $maturityParams['StaleAccess']         = $staleAccessData }
            $governanceMaturityData = Measure-SPGovernanceMaturity @maturityParams
        }
        catch {
            Write-Host "    WARN: Measure-SPGovernanceMaturity: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Orchestrator History
        try {
            $orchestratorData = Get-SPOrchestratorHistory -DaysBack $DaysBack -CorrelationID $correlationID
        }
        catch {
            Write-Host "    WARN: Get-SPOrchestratorHistory: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $analyticsCount = @(
            $identityRiskData, $sourceGovernanceData, $campaignMetricsData,
            $reviewerReputationData, $staleAccessData, $governanceMaturityData,
            $orchestratorData
        ) | Where-Object { $null -ne $_ } | Measure-Object | Select-Object -ExpandProperty Count
        $detail = "$analyticsCount/7 analytics computed from $($campaignAudits.Count) campaign(s)"
        Set-StepResult -Step 'CurrentAnalytics' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Step 1: $detail" -ForegroundColor Green

        # Save metrics
        Write-Host '    Saving metrics...' -ForegroundColor DarkGray
        $saveStart = Get-Date
        try {
            $saveParams = @{
                Label         = "metrics-$todayLabel"
                CorrelationID = $correlationID
            }
            if ($null -ne $identityRiskData)        { $saveParams['IdentityRisk']       = $identityRiskData }
            if ($null -ne $sourceGovernanceData)     { $saveParams['SourceGovernance']   = $sourceGovernanceData }
            if ($null -ne $campaignMetricsData)      { $saveParams['CampaignMetrics']    = $campaignMetricsData }
            if ($null -ne $reviewerReputationData)   { $saveParams['ReviewerReputation'] = $reviewerReputationData }
            if ($null -ne $staleAccessData)          { $saveParams['StaleAccess']        = $staleAccessData }
            if ($null -ne $governanceMaturityData)   { $saveParams['GovernanceMaturity'] = $governanceMaturityData }
            if ($null -ne $orchestratorData)          { $saveParams['OrchestratorHistory'] = $orchestratorData }

            $saveResult = Save-SPGovernanceMetrics @saveParams
            $saveDuration = ((Get-Date) - $saveStart).TotalSeconds

            if ($saveResult.Success) {
                $saveDetail = "Saved $($saveResult.Data.MetricCount) metrics to $($saveResult.Data.FilePath)"
                Set-StepResult -Step 'MetricsSave' -Status 'Success' -Detail $saveDetail -Duration $saveDuration
                Write-Host "    $saveDetail" -ForegroundColor Green
            }
            else {
                Set-StepResult -Step 'MetricsSave' -Status 'Warning' -Detail 'Save returned unsuccessful' -Duration $saveDuration
                Write-Host '    WARN: Metrics save returned unsuccessful' -ForegroundColor Yellow
                if ($worstExitCode -lt 5) { $worstExitCode = 5 }
            }
        }
        catch {
            $saveDuration = ((Get-Date) - $saveStart).TotalSeconds
            Set-StepResult -Step 'MetricsSave' -Status 'Error' -Detail $_.Exception.Message -Duration $saveDuration
            Write-Host "    ERROR: Metrics save failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-SPLog -Message "Metrics save exception: $($_.Exception.Message)" `
                -Severity ERROR -Component 'GovernanceMetrics' -Action 'MetricsSaveError' -CorrelationID $correlationID
            $worstExitCode = 5
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'CurrentAnalytics' -Status 'Error' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 1: ERROR - $($_.Exception.Message)" -ForegroundColor Red
        Write-SPLog -Message "Current analytics exception: $($_.Exception.Message)" `
            -Severity ERROR -Component 'GovernanceMetrics' -Action 'AnalyticsError' -CorrelationID $correlationID
        $worstExitCode = 5
    }
    Write-Host ''
}
else {
    Write-Host '  Step 1: Current Analytics [SKIPPED - TrendOnly mode]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 2: Campaign Completion Forecast (if -IncludeCompletionForecast)

if ($IncludeCompletionForecast -and -not $TrendOnly) {
    Write-Host '  Step 2: Campaign Completion Forecast' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        if ($campaignAudits.Count -eq 0) {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'CompletionForecast' -Status 'Warning' -Detail 'No campaign audit data available' -Duration $stepDuration
            Write-Host '  Step 2: WARN - No campaign audit data for forecasting' -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
        else {
            $forecastParams = @{
                CampaignAudits = $campaignAudits
                CorrelationID  = $correlationID
            }

            # Get campaign health data for deadline info
            try {
                $healthResult = Get-SPCampaignHealth -DaysBack $DaysBack -CorrelationID $correlationID
                if ($healthResult.Success -and $null -ne $healthResult.Data -and
                    $null -ne $healthResult.Data.Campaigns) {
                    $forecastParams['CampaignHealthData'] = @($healthResult.Data.Campaigns)
                }
            }
            catch {
                Write-Host '    WARN: Could not fetch campaign health for deadline data' -ForegroundColor Yellow
            }

            $forecastData = Get-SPCampaignCompletionForecast @forecastParams
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

            if ($null -ne $forecastData -and $null -ne $forecastData.Summary) {
                $fs = $forecastData.Summary
                $detail = "Active: $($fs.ActiveCampaigns) | On Track: $($fs.OnTrack) | At Risk: $($fs.AtRisk) | Will Miss: $($fs.WillMiss)"
                Set-StepResult -Step 'CompletionForecast' -Status 'Success' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 2: $detail" -ForegroundColor Green
            }
            else {
                Set-StepResult -Step 'CompletionForecast' -Status 'Warning' -Detail 'No forecast data returned' -Duration $stepDuration
                Write-Host '  Step 2: WARN - No forecast data returned' -ForegroundColor Yellow
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'CompletionForecast' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Campaign completion forecast exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceMetrics' -Action 'ForecastError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    $skipReason = if ($TrendOnly) { 'TrendOnly mode' } else { 'not requested' }
    Write-Host "  Step 2: Campaign Completion Forecast [SKIPPED - $skipReason]" -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 3: Trend Analysis (unless -CaptureOnly)

if (-not $CaptureOnly) {
    Write-Host '  Step 3: Trend Analysis' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $trendData = Get-SPGovernanceMetricsTrend -DaysBack $TrendDaysBack `
            -Granularity $TrendGranularity -CorrelationID $correlationID
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($null -ne $trendData -and $null -ne $trendData.Summary) {
            $ts = $trendData.Summary
            $detail = "Metrics: $($ts.MetricsTracked) | Points: $($ts.DataPointCount) | " +
                "Improving: $($ts.ImprovingMetrics) | Declining: $($ts.DecliningMetrics) | Stable: $($ts.StableMetrics)"
            Set-StepResult -Step 'TrendAnalysis' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 3: $detail" -ForegroundColor Green
        }
        else {
            Set-StepResult -Step 'TrendAnalysis' -Status 'Warning' -Detail 'No trend data available' -Duration $stepDuration
            Write-Host '  Step 3: WARN - No trend data available (insufficient history)' -ForegroundColor Yellow
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'TrendAnalysis' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 3: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Trend analysis exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceMetrics' -Action 'TrendError' -CorrelationID $correlationID
    }
    Write-Host ''
}
else {
    Write-Host '  Step 3: Trend Analysis [SKIPPED - CaptureOnly mode]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 4: Decline Detection (if -AlertOnDecline)

if ($AlertOnDecline -and $null -ne $trendData -and $null -ne $trendData.Trends) {
    Write-Host '  Step 4: Decline Detection' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Check for metrics declining >5% over last 4 periods
        foreach ($metricName in $trendData.Trends.Keys) {
            $metricTrend = $trendData.Trends[$metricName]
            if ($null -eq $metricTrend -or $null -eq $metricTrend.Periods) { continue }

            $periods = @($metricTrend.Periods)
            if ($periods.Count -lt 4) { continue }

            # Compare last 4 periods: first of 4 vs last of 4
            $recentPeriods = $periods[($periods.Count - 4)..($periods.Count - 1)]
            $startAvg = $recentPeriods[0].Avg
            $endAvg   = $recentPeriods[3].Avg

            if ($startAvg -gt 0) {
                $changePct = (($endAvg - $startAvg) / $startAvg) * 100
                if ($changePct -lt -5) {
                    $decliningMetrics += @{
                        MetricName = $metricName
                        StartAvg   = $startAvg
                        EndAvg     = $endAvg
                        ChangePct  = [math]::Round($changePct, 1)
                    }
                }
            }
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($decliningMetrics.Count -gt 0) {
            $detail = "$($decliningMetrics.Count) metric(s) declining >5%"
            Set-StepResult -Step 'DeclineDetection' -Status 'Warning' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 4: $detail" -ForegroundColor Yellow

            foreach ($dm in $decliningMetrics) {
                Write-Host "    - $($dm.MetricName): $($dm.ChangePct)% ($($dm.StartAvg) -> $($dm.EndAvg))" -ForegroundColor Yellow
            }

            if ($worstExitCode -lt 1) { $worstExitCode = 1 }

            # Send notification
            try {
                $declineBody = "Governance metrics declining >5% over last 4 periods:`n"
                foreach ($dm in $decliningMetrics) {
                    $declineBody += "  - $($dm.MetricName): $($dm.ChangePct)% ($($dm.StartAvg) -> $($dm.EndAvg))`n"
                }

                $notifyParams = @{
                    Subject   = "Governance Metrics Decline Alert: $($decliningMetrics.Count) metric(s)"
                    Body      = $declineBody
                    Severity  = 'Warning'
                    Category  = 'GovernanceMetrics'
                    CorrelationID = $correlationID
                }
                if ($AlertRecipients -and $AlertRecipients.Count -gt 0) {
                    $notifyParams['Recipients'] = $AlertRecipients
                }

                $notifyResult = Send-SPNotification @notifyParams
                if ($notifyResult.Success) {
                    Write-Host "    Alert sent via $($notifyResult.Data.Backends -join ', ')" -ForegroundColor Green
                }
                else {
                    Write-Host "    WARN: Alert notification: $($notifyResult.Error)" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "    WARN: Alert notification failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Set-StepResult -Step 'DeclineDetection' -Status 'Success' -Detail 'No declining metrics detected' -Duration $stepDuration
            Write-Host '  Step 4: No declining metrics detected' -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DeclineDetection' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 4: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Decline detection exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceMetrics' -Action 'DeclineError' -CorrelationID $correlationID
    }
    Write-Host ''
}
elseif ($AlertOnDecline) {
    Write-Host '  Step 4: Decline Detection [SKIPPED - no trend data]' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  Step 4: Decline Detection [SKIPPED - not requested]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 5: Output

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# Helper to get directional indicator
function Get-DirectionStr {
    param([string]$MetricName, [hashtable]$TrendResult)
    if ($null -eq $TrendResult -or $null -eq $TrendResult.Trends) { return '' }
    # $TrendResult.Trends is an [ordered] dictionary, which exposes .Contains()
    # (key lookup) but not .ContainsKey(). .Contains() works for hashtables too.
    if (-not $TrendResult.Trends.Contains($MetricName)) { return '' }
    $mt = $TrendResult.Trends[$MetricName]
    $periods = @($mt.Periods)
    if ($periods.Count -lt 2) { return '' }
    $prev = $periods[$periods.Count - 2].Avg
    $curr = $periods[$periods.Count - 1].Avg
    if ($prev -eq 0) { return '' }
    $delta = [math]::Round($curr - $prev, 1)
    $sign = if ($delta -ge 0) { '+' } else { '' }
    return "[$sign$delta vs last $TrendGranularity]"
}

# Console summary
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host '  === Governance Metrics Capture ===' -ForegroundColor Cyan
    Write-Host "  Timestamp:   $($startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "  Period:      $DaysBack days | Trend: $TrendDaysBack days ($TrendGranularity)"
    Write-Host ''

    # Current KPIs section
    if (-not $TrendOnly) {
        Write-Host '  --- Current KPIs ---'

        # Maturity
        if ($null -ne $governanceMaturityData) {
            $matScore = if ($governanceMaturityData.ContainsKey('OverallScore')) { $governanceMaturityData['OverallScore'] } else { 'N/A' }
            $matLevel = if ($governanceMaturityData.ContainsKey('OverallLevel')) { $governanceMaturityData['OverallLevel'] } else { 'N/A' }
            $dir = Get-DirectionStr -MetricName 'maturity.overallScore' -TrendResult $trendData
            Write-Host "    Maturity Score:    $matScore (Level $matLevel)   $dir"
        }

        # Identity Risk
        if ($null -ne $identityRiskData -and $null -ne $identityRiskData.Summary) {
            $irs = $identityRiskData.Summary
            $highCount = if ($irs.ContainsKey('HighRiskCount')) { $irs['HighRiskCount'] } else { 0 }
            $avgScore  = if ($irs.ContainsKey('AvgRiskScore'))  { $irs['AvgRiskScore'] }  else { 'N/A' }
            $dir = Get-DirectionStr -MetricName 'identityRisk.avgScore' -TrendResult $trendData
            Write-Host "    Identity Risk:     $highCount High, $avgScore avg $dir"
        }

        # Source Coverage
        if ($null -ne $sourceGovernanceData -and $null -ne $sourceGovernanceData.Summary) {
            $sgs = $sourceGovernanceData.Summary
            $covPct = if ($sgs.ContainsKey('OverallCoveragePct')) { "$($sgs['OverallCoveragePct'])%" } else { 'N/A' }
            $dir = Get-DirectionStr -MetricName 'sourceGovernance.coveragePct' -TrendResult $trendData
            Write-Host "    Source Coverage:   $covPct            $dir"
        }

        # Campaign Approval
        if ($null -ne $campaignMetricsData -and $null -ne $campaignMetricsData.Data) {
            $totalApproved = 0; $totalItems = 0
            foreach ($m in @($campaignMetricsData.Data)) {
                $totalApproved += $m.ApprovedCount
                $totalItems    += $m.TotalItems
            }
            $avgApproval = if ($totalItems -gt 0) { [math]::Round(($totalApproved / $totalItems) * 100, 0) } else { 0 }
            $dir = Get-DirectionStr -MetricName 'campaigns.avgApprovalRate' -TrendResult $trendData
            Write-Host "    Campaign Approval: $avgApproval%           $dir"
        }

        # Reviewer Score
        if ($null -ne $reviewerReputationData -and $null -ne $reviewerReputationData.Summary) {
            $rrs = $reviewerReputationData.Summary
            $avgRep = if ($rrs.ContainsKey('AvgReputationScore')) { $rrs['AvgReputationScore'] } else { 'N/A' }
            $dir = Get-DirectionStr -MetricName 'reviewers.avgScore' -TrendResult $trendData
            Write-Host "    Reviewer Avg:      $avgRep            $dir"
        }

        # Stale Access
        if ($null -ne $staleAccessData -and $null -ne $staleAccessData.Summary) {
            $sas = $staleAccessData.Summary
            $totalStale = if ($sas.ContainsKey('TotalStaleItems')) { $sas['TotalStaleItems'] } else { 0 }
            $dir = Get-DirectionStr -MetricName 'staleAccess.totalItems' -TrendResult $trendData
            Write-Host "    Stale Access:      $totalStale items        $dir"
        }

        # Orchestrator
        if ($null -ne $orchestratorData -and $null -ne $orchestratorData.Metrics) {
            $orchMetrics = $orchestratorData.Metrics
            $successRate = if ($orchMetrics.ContainsKey('SuccessRate')) { "$($orchMetrics['SuccessRate'])% success" } else { 'N/A' }
            $dir = Get-DirectionStr -MetricName 'orchestrator.successRate' -TrendResult $trendData
            Write-Host "    Orchestrator:      $successRate   $dir"
        }

        Write-Host ''
    }

    # Campaign Completion Forecast section
    if ($null -ne $forecastData -and $null -ne $forecastData.Forecasts) {
        Write-Host '  --- Campaign Completion Forecast ---'
        foreach ($fc in @($forecastData.Forecasts)) {
            $statusLabel = if ($fc.WillMeetDeadline -eq $true) { 'ON TRACK' }
                elseif ($fc.WillMeetDeadline -eq $false -and $fc.ProjectedCompletionDate -eq 'Unknown') { 'STALLED' }
                elseif ($fc.WillMeetDeadline -eq $false) { 'AT RISK' }
                else { 'UNKNOWN' }

            $statusColor = switch ($statusLabel) {
                'ON TRACK' { 'Green' }
                'AT RISK'  { 'Yellow' }
                'STALLED'  { 'Red' }
                default    { 'Gray' }
            }

            $detailParts = @()
            if ($null -ne $fc.SlackHours -and $fc.SlackHours -ne 0) {
                $detailParts += "$([math]::Abs($fc.SlackHours))h slack"
            }
            if ($null -ne $fc.DeadlineDate -and $fc.DeadlineDate -ne '') {
                try {
                    $dl = [datetime]::Parse($fc.DeadlineDate)
                    $detailParts += "deadline $($dl.ToString('MMM d'))"
                }
                catch {
                    $detailParts += "deadline $($fc.DeadlineDate)"
                }
            }
            if ($null -ne $fc.BottleneckReviewers -and @($fc.BottleneckReviewers).Count -gt 0) {
                $topBlocker = @($fc.BottleneckReviewers)[0]
                $detailParts += "reviewer $($topBlocker.ReviewerName) bottleneck"
            }

            $detailStr = if ($detailParts.Count -gt 0) { " ($($detailParts -join ', '))" } else { '' }
            Write-Host "    $($fc.CampaignName): " -ForegroundColor Gray -NoNewline
            Write-Host "$statusLabel$detailStr" -ForegroundColor $statusColor
        }
        Write-Host ''
    }

    # Trend summary section
    if ($null -ne $trendData -and $null -ne $trendData.Summary -and $trendData.Summary.DataPointCount -gt 0) {
        $ts = $trendData.Summary
        $periodCount = if ($null -ne $ts.OldestRecord -and $null -ne $ts.NewestRecord) {
            try {
                $oldest = [datetime]::Parse($ts.OldestRecord)
                $newest = [datetime]::Parse($ts.NewestRecord)
                $weeks = [math]::Ceiling(($newest - $oldest).TotalDays / 7)
                "$weeks weeks"
            }
            catch { "$($ts.DataPointCount) points" }
        }
        else { "$($ts.DataPointCount) points" }

        Write-Host "  --- Trend Summary ($periodCount) ---"

        # Show improving metrics
        $improving = @()
        $declining = @()
        $stable    = 0
        if ($null -ne $trendData.Trends) {
            foreach ($mn in $trendData.Trends.Keys) {
                $mt = $trendData.Trends[$mn]
                if ($null -eq $mt) { continue }
                $dir = if ($mt.ContainsKey('OverallDirection')) { $mt['OverallDirection'] } else { 'Stable' }
                switch ($dir) {
                    'Improving' {
                        $chg = if ($mt.ContainsKey('TotalChange')) { $mt['TotalChange'] } else { '' }
                        $improving += "$mn ($( if ([double]$chg -ge 0) { '+' } )$chg)"
                    }
                    'Declining' {
                        $chg = if ($mt.ContainsKey('TotalChange')) { $mt['TotalChange'] } else { '' }
                        $declining += "$mn ($chg)"
                    }
                    default { $stable++ }
                }
            }
        }

        if ($improving.Count -gt 0) {
            Write-Host "    Improving: $($improving -join ', ')" -ForegroundColor Green
        }
        if ($declining.Count -gt 0) {
            Write-Host "    Declining: $($declining -join ', ')" -ForegroundColor Yellow
        }
        Write-Host "    Stable:    $stable of $($ts.MetricsTracked) metrics"
        Write-Host ''
    }

    # Metrics save confirmation
    if ($null -ne $saveResult -and $saveResult.Success) {
        Write-Host "  Metrics saved to $($saveResult.Data.FilePath)"
    }

    Write-Host "  Duration: $durationStr"
    Write-Host ''
}

# JSON output
$summaryObject = [ordered]@{
    Timestamp       = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CorrelationID   = $correlationID
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    Duration        = $durationStr
    Period          = $DaysBack
    TrendPeriod     = $TrendDaysBack
    TrendGranularity = $TrendGranularity
    Sources         = $effectiveSourceIds
    Analytics       = [ordered]@{
        IdentityRisk       = if ($null -ne $identityRiskData -and $null -ne $identityRiskData.Summary) { $identityRiskData.Summary } else { $null }
        SourceGovernance   = if ($null -ne $sourceGovernanceData -and $null -ne $sourceGovernanceData.Summary) { $sourceGovernanceData.Summary } else { $null }
        CampaignMetrics    = if ($null -ne $campaignMetricsData -and $null -ne $campaignMetricsData.Data) { @($campaignMetricsData.Data).Count } else { $null }
        ReviewerReputation = if ($null -ne $reviewerReputationData -and $null -ne $reviewerReputationData.Summary) { $reviewerReputationData.Summary } else { $null }
        StaleAccess        = if ($null -ne $staleAccessData -and $null -ne $staleAccessData.Summary) { $staleAccessData.Summary } else { $null }
        GovernanceMaturity = if ($null -ne $governanceMaturityData) {
            [ordered]@{
                OverallScore = if ($governanceMaturityData.ContainsKey('OverallScore')) { $governanceMaturityData['OverallScore'] } else { $null }
                OverallLevel = if ($governanceMaturityData.ContainsKey('OverallLevel')) { $governanceMaturityData['OverallLevel'] } else { $null }
            }
        } else { $null }
        Orchestrator       = if ($null -ne $orchestratorData -and $null -ne $orchestratorData.Metrics) { $orchestratorData.Metrics } else { $null }
    }
    MetricsSave     = if ($null -ne $saveResult) { $saveResult } else { $null }
    Forecast        = if ($null -ne $forecastData) { $forecastData.Summary } else { $null }
    Trend           = if ($null -ne $trendData) { $trendData.Summary } else { $null }
    DecliningMetrics = $decliningMetrics
    Steps           = $stepResults
    ExitCode        = $worstExitCode
}

# HTML output. -OutputMode HTML is in the ValidateSet but previously had no
# implementation (only Console + JSON existed), so it silently produced nothing.
# Render the captured KPIs (mirrors the Console block's data) plus a trend summary.
if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    $enc = { param($v) if ($null -eq $v) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$v) } }
    $addRow = {
        param($label, $value, $dir)
        $dirHtml = if ([string]::IsNullOrWhiteSpace($dir)) { '' } else { '<span style="color:#666;font-size:12px">' + (& $enc $dir) + '</span>' }
        '<tr><td style="padding:8px 12px;border-bottom:1px solid #eee">' + (& $enc $label) +
        '</td><td style="padding:8px 12px;border-bottom:1px solid #eee"><strong>' + (& $enc $value) +
        '</strong></td><td style="padding:8px 12px;border-bottom:1px solid #eee">' + $dirHtml + '</td></tr>'
    }

    $rowsHtml = ''
    if ($null -ne $governanceMaturityData) {
        $matScore = if ($governanceMaturityData.ContainsKey('OverallScore')) { $governanceMaturityData['OverallScore'] } else { 'N/A' }
        $matLevel = if ($governanceMaturityData.ContainsKey('OverallLevel')) { $governanceMaturityData['OverallLevel'] } else { 'N/A' }
        $rowsHtml += & $addRow 'Maturity Score' "$matScore (Level $matLevel)" (Get-DirectionStr -MetricName 'maturity.overallScore' -TrendResult $trendData)
    }
    if ($null -ne $identityRiskData -and $null -ne $identityRiskData.Summary) {
        $irs = $identityRiskData.Summary
        $highCount = if ($irs.ContainsKey('HighRiskCount')) { $irs['HighRiskCount'] } else { 0 }
        $avgScore  = if ($irs.ContainsKey('AvgRiskScore'))  { $irs['AvgRiskScore'] }  else { 'N/A' }
        $rowsHtml += & $addRow 'Identity Risk' "$highCount High, $avgScore avg" (Get-DirectionStr -MetricName 'identityRisk.avgScore' -TrendResult $trendData)
    }
    if ($null -ne $sourceGovernanceData -and $null -ne $sourceGovernanceData.Summary) {
        $sgs = $sourceGovernanceData.Summary
        $covPct = if ($sgs.ContainsKey('OverallCoveragePct')) { "$($sgs['OverallCoveragePct'])%" } else { 'N/A' }
        $rowsHtml += & $addRow 'Source Coverage' $covPct (Get-DirectionStr -MetricName 'sourceGovernance.coveragePct' -TrendResult $trendData)
    }
    if ($null -ne $campaignMetricsData -and $null -ne $campaignMetricsData.Data) {
        $tA = 0; $tI = 0
        foreach ($m in @($campaignMetricsData.Data)) { $tA += $m.ApprovedCount; $tI += $m.TotalItems }
        $avgApproval = if ($tI -gt 0) { [math]::Round(($tA / $tI) * 100, 0) } else { 0 }
        $rowsHtml += & $addRow 'Campaign Approval' "$avgApproval%" (Get-DirectionStr -MetricName 'campaigns.avgApprovalRate' -TrendResult $trendData)
    }
    if ($null -ne $reviewerReputationData -and $null -ne $reviewerReputationData.Summary) {
        $rrs = $reviewerReputationData.Summary
        $avgRep = if ($rrs.ContainsKey('AvgReputationScore')) { $rrs['AvgReputationScore'] } else { 'N/A' }
        $rowsHtml += & $addRow 'Reviewer Avg' $avgRep (Get-DirectionStr -MetricName 'reviewers.avgScore' -TrendResult $trendData)
    }
    if ($null -ne $staleAccessData -and $null -ne $staleAccessData.Summary) {
        $sas = $staleAccessData.Summary
        $totalStale = if ($sas.ContainsKey('TotalStaleItems')) { $sas['TotalStaleItems'] } else { 0 }
        $rowsHtml += & $addRow 'Stale Access' "$totalStale items" (Get-DirectionStr -MetricName 'staleAccess.totalItems' -TrendResult $trendData)
    }
    if ($null -ne $orchestratorData -and $null -ne $orchestratorData.Metrics) {
        $orchMetrics = $orchestratorData.Metrics
        $successRate = if ($orchMetrics.ContainsKey('SuccessRate')) { "$($orchMetrics['SuccessRate'])% success" } else { 'N/A' }
        $rowsHtml += & $addRow 'Orchestrator' $successRate (Get-DirectionStr -MetricName 'orchestrator.successRate' -TrendResult $trendData)
    }
    if ([string]::IsNullOrEmpty($rowsHtml)) { $rowsHtml = '<tr><td colspan="3" style="padding:8px 12px;color:#999">No analytics captured for this run.</td></tr>' }

    # Trend summary (defensive -- never let a trend-shape issue break the report).
    $trendHtml = ''
    try {
        if ($null -ne $trendData -and $null -ne $trendData.Trends) {
            $improving = @(); $declining = @(); $stable = 0
            foreach ($mn in $trendData.Trends.Keys) {
                $mt = $trendData.Trends[$mn]
                if ($null -eq $mt) { continue }
                $hasDir = if ($mt -is [System.Collections.IDictionary]) { $mt.Contains('OverallDirection') } else { $mt.PSObject.Properties.Name -contains 'OverallDirection' }
                $dir = if ($hasDir) { $mt['OverallDirection'] } else { 'Stable' }
                switch ($dir) { 'Improving' { $improving += $mn } 'Declining' { $declining += $mn } default { $stable++ } }
            }
            $trendHtml = '<div class="section"><h2>Trend Summary</h2><p style="font-size:13px">' +
                '<strong style="color:#1b5e20">Improving:</strong> ' + (& $enc ($(if ($improving.Count) { $improving -join ', ' } else { 'none' }))) + '<br>' +
                '<strong style="color:#e65100">Declining:</strong> ' + (& $enc ($(if ($declining.Count) { $declining -join ', ' } else { 'none' }))) + '<br>' +
                '<strong>Stable:</strong> ' + (& $enc $stable) + ' metric(s)</p></div>'
        }
    } catch { $trendHtml = '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<title>Governance Metrics - ' + (& $enc $startTime.ToString('yyyy-MM-dd')) + '</title>')
    [void]$sb.AppendLine('<style>body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}.container{max-width:880px;margin:0 auto}.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:22px 28px;border-radius:8px 8px 0 0}.header h1{margin:0 0 6px;font-size:20px}.header .meta{font-size:12px;opacity:.85}.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:18px 28px}.section:last-of-type{border-radius:0 0 8px 8px}h2{color:#264d73;font-size:15px;border-bottom:2px solid #e8eef5;padding-bottom:6px;margin-top:0}table{border-collapse:collapse;width:100%;font-size:13px}th{background:#e8eef5;padding:8px 12px;text-align:left}.footer{text-align:center;color:#999;font-size:11px;padding:14px}</style></head><body><div class="container">')
    [void]$sb.AppendLine('<div class="header"><h1>Governance Metrics Capture &amp; Trend</h1><div class="meta">Generated: ' + (& $enc $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) + ' | Period: ' + (& $enc $DaysBack) + ' days | Trend: ' + (& $enc $TrendDaysBack) + ' days (' + (& $enc $TrendGranularity) + ')</div></div>')
    [void]$sb.AppendLine('<div class="section"><h2>Current KPIs</h2><table><thead><tr><th>Metric</th><th>Value</th><th>Trend</th></tr></thead><tbody>' + $rowsHtml + '</tbody></table></div>')
    [void]$sb.AppendLine($trendHtml)
    [void]$sb.AppendLine('<div class="footer">SailPoint ISC Governance Toolkit - Governance Metrics - ' + (& $enc $correlationID) + '</div></div></body></html>')

    if (-not (Test-Path $effectiveOutputPath)) { New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null }
    $metricsHtmlPath = Join-Path $effectiveOutputPath ('governance-metrics-{0}.html' -f $startTime.ToString('yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($metricsHtmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  HTML report: $metricsHtmlPath" -ForegroundColor Green
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $summaryObject | ConvertTo-Json -Depth 5
}

# JSONL audit trail event
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'GovernanceMetricsCapture'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            AnalyticsComputed = $stepResults['CurrentAnalytics'].Status
            MetricsSaved      = $stepResults['MetricsSave'].Status
            ForecastRun       = $stepResults['CompletionForecast'].Status
            TrendAnalysis     = $stepResults['TrendAnalysis'].Status
            DecliningMetrics  = $decliningMetrics.Count
            DurationSeconds   = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode          = $worstExitCode
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditFile = Join-Path $effectiveOutputPath 'governance-metrics-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'GovernanceMetrics' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPGovernanceMetrics completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'GovernanceMetrics' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $worstExitCode
