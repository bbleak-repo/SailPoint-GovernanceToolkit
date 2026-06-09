#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a comprehensive weekly governance digest combining campaign
    activity, health status, identity risk, reviewer performance, remediation
    tracking, and orchestrator reliability into one report.
.DESCRIPTION
    Designed for weekly distribution to governance leadership. Combines data
    from multiple toolkit functions into a single consolidated view.

    Report sections:
      1. Campaign Activity Summary   (Get-SPAuditCampaigns, Measure-SPCampaignMetrics)
      2. Current Campaign Health      (Get-SPCampaignHealth)
      3. Identity Risk Highlights     (Measure-SPIdentityRisk)
      4. Reviewer Performance         (Measure-SPReviewerReputation)
      5. Remediation Tracking         (Get-SPRemediationStatus)
      6. Orchestrator Health           (Get-SPOrchestratorHistory)

    Each section can be individually skipped. Output supports Console, HTML,
    JSON, or Both (console + HTML) modes.

.PARAMETER DaysBack
    Number of days to include in the digest. Default: 7 (weekly).
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Config\settings.json relative to toolkit root.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER SourceId
    One or more SailPoint ISC source IDs for context display.
.PARAMETER SkipCampaignSummary
    Skip Section 1: Campaign Activity Summary.
.PARAMETER SkipIdentityRisk
    Skip Section 3: Identity Risk Highlights.
.PARAMETER SkipReviewerAnalysis
    Skip Section 4: Reviewer Performance.
.PARAMETER SkipOrchestratorHealth
    Skip Section 6: Orchestrator Health.
.PARAMETER SkipRemediationTracking
    Skip Section 5: Remediation Tracking.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    HTML: self-contained HTML report file.
    JSON: machine-parseable result object.
    Both: console output and HTML file.
.PARAMETER OutputPath
    Directory for output files. Defaults to Audit output path from config.
.PARAMETER SendNotification
    Send the digest via configured notification backends (P12-06).
.PARAMETER NotifyRecipients
    Email addresses for SMTP notification backend.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPWeeklyDigest.ps1 -Token $token
    # Weekly digest with default 7-day window.
.EXAMPLE
    .\Invoke-SPWeeklyDigest.ps1 -Token $token -OutputMode Both -SendNotification
    # Console + HTML output with notification dispatch.
.EXAMPLE
    .\Invoke-SPWeeklyDigest.ps1 -DaysBack 14 -SkipIdentityRisk -Token $token
    # Two-week digest, skip identity risk section.
.EXAMPLE
    .\Invoke-SPWeeklyDigest.ps1 -WhatIf
    # Dry run -- shows what sections would be generated.
.NOTES
    Script:  Invoke-SPWeeklyDigest.ps1
    Version: 1.0.0
    Exit codes:
        0 = Digest generated successfully
        1 = One or more sections had warnings (partial data)
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical section failed
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [int]$DaysBack = 7,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    # Section toggles
    [Parameter()]
    [switch]$SkipCampaignSummary,

    [Parameter()]
    [switch]$SkipIdentityRisk,

    [Parameter()]
    [switch]$SkipReviewerAnalysis,

    [Parameter()]
    [switch]$SkipOrchestratorHealth,

    [Parameter()]
    [switch]$SkipRemediationTracking,

    # Output
    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    # Notification
    [Parameter()]
    [switch]$SendNotification,

    [Parameter()]
    [string[]]$NotifyRecipients,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';           Name = 'SP.Core';     Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';             Name = 'SP.Api';      Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';         Name = 'SP.Audit';    Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert'; Required = $false }
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

# ---------------------------------------------------------------------------
# Local HTML-encode helper. The digest builds its HTML inline (rather than via
# the SP.Audit report module), and SP.Audit's ConvertTo-SafeHtml is an internal,
# non-exported helper -- so define a self-contained copy here. Without it the
# HTML/Both output block threw "ConvertTo-SafeHtml is not recognized" and no
# report file was written.
# ---------------------------------------------------------------------------
function ConvertTo-SafeHtml {
    [OutputType([string])]
    param([Parameter()]$Value)
    if ($null -eq $Value) { return '' }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($str)
}

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')
$periodStart = $startTime.AddDays(-$DaysBack)
$periodLabel = '{0} to {1}' -f $periodStart.ToString('yyyy-MM-dd'), $todayLabel

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Weekly Governance Digest' -ForegroundColor Cyan
Write-Host "  Period:        $periodLabel" -ForegroundColor DarkGray
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

Write-SPLog -Message "Invoke-SPWeeklyDigest started: CorrelationID=$correlationID DaysBack=$DaysBack" `
    -Severity INFO -Component 'WeeklyDigest' -Action 'Start' -CorrelationID $correlationID

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

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true)

#endregion

#region Section Tracking

$sectionResults = [ordered]@{
    CampaignActivity    = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    CampaignHealth      = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    IdentityRisk        = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    ReviewerPerformance = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    Remediation         = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    OrchestratorHealth  = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
}

$worstExitCode = 0

function Set-SectionResult {
    param([string]$Section, [string]$Status, [string]$Detail, [double]$Duration)
    $sectionResults[$Section] = @{ Status = $Status; Detail = $Detail; Duration = $Duration }
}

# Digest data (populated by sections, used for output)
$digestData = [ordered]@{
    Period              = $periodLabel
    GeneratedAt         = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DaysBack            = $DaysBack
    CampaignActivity    = $null
    CampaignHealth      = $null
    IdentityRisk        = $null
    ReviewerPerformance = $null
    Remediation         = $null
    OrchestratorHealth  = $null
}

#endregion

#region WhatIf Mode

if ($isWhatIf) {
    Write-Host '  [WHATIF] The following sections would be generated:' -ForegroundColor Yellow
    Write-Host ''
    if (-not $SkipCampaignSummary)     { Write-Host '    1. Campaign Activity Summary' -ForegroundColor White }
    Write-Host '    2. Current Campaign Health' -ForegroundColor White
    if (-not $SkipIdentityRisk)        { Write-Host '    3. Identity Risk Highlights' -ForegroundColor White }
    if (-not $SkipReviewerAnalysis)    { Write-Host '    4. Reviewer Performance' -ForegroundColor White }
    if (-not $SkipRemediationTracking) { Write-Host '    5. Remediation Tracking' -ForegroundColor White }
    if (-not $SkipOrchestratorHealth)  { Write-Host '    6. Orchestrator Health' -ForegroundColor White }
    Write-Host ''
    Write-Host "    Period:  $periodLabel" -ForegroundColor DarkGray
    Write-Host "    Output:  $OutputMode" -ForegroundColor DarkGray
    if ($SendNotification) {
        Write-Host '    Notify:  Yes' -ForegroundColor DarkGray
    }
    Write-Host ''

    Write-SPLog -Message "Invoke-SPWeeklyDigest completed: WhatIf mode" `
        -Severity INFO -Component 'WeeklyDigest' -Action 'Complete' -CorrelationID $correlationID
    exit 0
}

#endregion

#region Data Collection

Write-Host '  Collecting governance data...' -ForegroundColor Cyan

# --- Get campaigns for current and previous periods ---
$currentCampaigns = @()
$prevCampaigns    = @()
$campaignAudits   = @()

try {
    Write-Host '    Fetching campaigns...' -ForegroundColor DarkGray
    $campaignResult = Get-SPAuditCampaigns -DaysBack $DaysBack -CorrelationID $correlationID
    if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
        $currentCampaigns = @($campaignResult.Data)
    }
    Write-Host "    Found $($currentCampaigns.Count) campaign(s) in current period." -ForegroundColor DarkGray

    # Previous period for comparison
    $prevStart = $startTime.AddDays(-($DaysBack * 2))
    $prevEnd   = $startTime.AddDays(-$DaysBack)
    $prevResult = Get-SPAuditCampaigns -CreatedAfter $prevStart -CreatedBefore $prevEnd `
        -CorrelationID $correlationID
    if ($prevResult.Success -and $null -ne $prevResult.Data) {
        $prevCampaigns = @($prevResult.Data)
    }
}
catch {
    Write-Host "    WARN: Failed to fetch campaigns: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Campaign fetch failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'WeeklyDigest' -Action 'CampaignFetchError' -CorrelationID $correlationID
    if ($worstExitCode -lt 1) { $worstExitCode = 1 }
}

# --- Build campaign audit data (certs + items) if any section needs it ---
$needsAuditData = (-not $SkipIdentityRisk) -or (-not $SkipReviewerAnalysis) -or `
                  (-not $SkipRemediationTracking) -or (-not $SkipCampaignSummary)

if ($needsAuditData -and $currentCampaigns.Count -gt 0) {
    Write-Host '    Building campaign audit data...' -ForegroundColor DarkGray
    $auditList = [System.Collections.Generic.List[object]]::new()

    foreach ($campaign in $currentCampaigns) {
        $campId   = $campaign.id
        $campName = $campaign.name
        Write-Host "      Processing: $campName" -ForegroundColor DarkGray

        try {
            # Get certifications for this campaign
            $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
            $certifications = @()
            if ($certResult.Success -and $null -ne $certResult.Data) {
                $certifications = @($certResult.Data)
            }

            # Get access review items (cached). Pass the certs already fetched so the cache
            # reuses them; items come back pre-wrapped for Group-SPAuditDecisions.
            $wrappedItems = [System.Collections.Generic.List[object]]::new()
            $cacheResult = Get-SPCachedCampaignItems -Campaign $campaign -Certifications $certifications -CorrelationID $correlationID
            if ($cacheResult.Success) {
                foreach ($wi in $cacheResult.Data) { $wrappedItems.Add($wi) }
            }

            # Build decision groups and metrics
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
            Write-Host "      WARN: Failed to process $campName : $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Campaign audit build failed for ${campName}: $($_.Exception.Message)" `
                -Severity WARN -Component 'WeeklyDigest' -Action 'AuditBuildError' -CorrelationID $correlationID
        }
    }

    $campaignAudits = $auditList.ToArray()
    Write-Host "    Built audit data for $($campaignAudits.Count) campaign(s)." -ForegroundColor DarkGray
}

Write-Host ''

#endregion

#region Section 1: Campaign Activity Summary

if (-not $SkipCampaignSummary) {
    Write-Host '  Section 1: Campaign Activity Summary' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Count campaigns by status
        $createdCount   = $currentCampaigns.Count
        $completedCount = @($currentCampaigns | Where-Object { $_.status -eq 'COMPLETED' }).Count
        $activeCount    = @($currentCampaigns | Where-Object {
            $_.status -eq 'ACTIVE' -or $_.status -eq 'ACTIVATING'
        }).Count

        # Calculate item metrics from audit data
        $totalItems = 0; $approvedCount = 0; $revokedCount = 0; $pendingCount = 0

        if ($campaignAudits.Count -gt 0) {
            foreach ($audit in $campaignAudits) {
                if ($null -ne $audit.Decisions) {
                    $d = $audit.Decisions
                    if ($null -ne $d.Approved) { $approvedCount += @($d.Approved).Count }
                    if ($null -ne $d.Revoked)  { $revokedCount  += @($d.Revoked).Count }
                    if ($null -ne $d.Pending)  { $pendingCount  += @($d.Pending).Count }
                }
            }
            $totalItems = $approvedCount + $revokedCount + $pendingCount
        }
        elseif ($currentCampaigns.Count -gt 0) {
            # Fallback to Measure-SPCampaignMetrics if no audit data was built
            $metricsResult = Measure-SPCampaignMetrics -Campaigns $currentCampaigns `
                -CorrelationID $correlationID
            if ($metricsResult.Success -and $null -ne $metricsResult.Data) {
                foreach ($m in @($metricsResult.Data)) {
                    $totalItems    += $m.TotalItems
                    $approvedCount += $m.ApprovedCount
                    $revokedCount  += $m.RevokedCount
                    $pendingCount  += $m.PendingCount
                }
            }
        }

        $approvalRate   = if ($totalItems -gt 0) { [math]::Round(($approvedCount / $totalItems) * 100, 0) } else { 0 }
        $revocationRate = if ($totalItems -gt 0) { [math]::Round(($revokedCount / $totalItems) * 100, 0) } else { 0 }

        # Previous period comparison
        $prevCreatedCount = $prevCampaigns.Count
        $campaignDelta    = $createdCount - $prevCreatedCount
        $campaignDeltaStr = if ($campaignDelta -ge 0) { "+$campaignDelta" } else { "$campaignDelta" }

        $approvalRateDelta = ''
        if ($prevCampaigns.Count -gt 0) {
            try {
                $prevMetrics = Measure-SPCampaignMetrics -Campaigns $prevCampaigns `
                    -CorrelationID $correlationID
                if ($prevMetrics.Success -and $null -ne $prevMetrics.Data) {
                    $prevTotal = 0; $prevApproved = 0
                    foreach ($pm in @($prevMetrics.Data)) {
                        $prevTotal    += $pm.TotalItems
                        $prevApproved += $pm.ApprovedCount
                    }
                    if ($prevTotal -gt 0) {
                        $prevApprovalRate = [math]::Round(($prevApproved / $prevTotal) * 100, 0)
                        $rateDelta = $approvalRate - $prevApprovalRate
                        $approvalRateDelta = if ($rateDelta -ge 0) { "+${rateDelta}%" } else { "${rateDelta}%" }
                    }
                }
            }
            catch {
                # Non-fatal: skip approval rate comparison
            }
        }

        $digestData.CampaignActivity = @{
            Created           = $createdCount
            Completed         = $completedCount
            Active            = $activeCount
            TotalItems        = $totalItems
            Approved          = $approvedCount
            Revoked           = $revokedCount
            Pending           = $pendingCount
            ApprovalRate      = $approvalRate
            RevocationRate    = $revocationRate
            CampaignDelta     = $campaignDeltaStr
            ApprovalRateDelta = $approvalRateDelta
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $detail = "$createdCount created, $completedCount completed, $activeCount active"
        Set-SectionResult -Section 'CampaignActivity' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 1: $detail" -ForegroundColor Green
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'CampaignActivity' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Section 1: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Campaign activity section failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'CampaignActivityError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Section 1: Campaign Activity [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Section 2: Campaign Health

Write-Host '  Section 2: Current Campaign Health' -ForegroundColor Cyan
$stepStart = Get-Date

try {
    $healthResult = Get-SPCampaignHealth -CorrelationID $correlationID
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

    if ($healthResult.Success) {
        $red = 0; $yellow = 0; $green = 0; $total = 0
        $staleReviewers  = @()
        $healthCampaigns = @()

        if ($null -ne $healthResult.Data) {
            if ($null -ne $healthResult.Data.Summary) {
                $red    = $healthResult.Data.Summary.Red
                $yellow = $healthResult.Data.Summary.Yellow
                $green  = $healthResult.Data.Summary.Green
                $total  = $healthResult.Data.Summary.Total
            }
            if ($null -ne $healthResult.Data.Campaigns) {
                $healthCampaigns = @($healthResult.Data.Campaigns)
                foreach ($hc in $healthCampaigns) {
                    if ($null -ne $hc.StaleReviewers -and @($hc.StaleReviewers).Count -gt 0) {
                        $staleReviewers += @($hc.StaleReviewers)
                    }
                }
            }
        }

        $digestData.CampaignHealth = @{
            Red            = $red
            Yellow         = $yellow
            Green          = $green
            Total          = $total
            StaleReviewers = $staleReviewers
            Campaigns      = $healthCampaigns
        }

        $detail = "$total active ($green Green, $yellow Yellow, $red Red)"
        Set-SectionResult -Section 'CampaignHealth' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 2: $detail" -ForegroundColor Green
    }
    else {
        $detail = "WARN - $($healthResult.Error)"
        Set-SectionResult -Section 'CampaignHealth' -Status 'Warning' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 2: $detail" -ForegroundColor Yellow
        Write-SPLog -Message "Campaign health warning: $($healthResult.Error)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'HealthWarn' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    Set-SectionResult -Section 'CampaignHealth' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
    Write-Host "  Section 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Campaign health section failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'WeeklyDigest' -Action 'HealthError' -CorrelationID $correlationID
    if ($worstExitCode -lt 1) { $worstExitCode = 1 }
}
Write-Host ''

#endregion

#region Section 3: Identity Risk Highlights

if (-not $SkipIdentityRisk) {
    Write-Host '  Section 3: Identity Risk Highlights' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        if ($campaignAudits.Count -gt 0) {
            $riskResult = Measure-SPIdentityRisk -CampaignAudits $campaignAudits `
                -CorrelationID $correlationID

            if ($null -ne $riskResult -and $null -ne $riskResult.Summary) {
                $topRisk = @()
                if ($null -ne $riskResult.Identities) {
                    $topRisk = @($riskResult.Identities | Select-Object -First 10)
                }

                $digestData.IdentityRisk = @{
                    Summary    = $riskResult.Summary
                    TopRisk    = $topRisk
                    Identities = if ($null -ne $riskResult.Identities) { @($riskResult.Identities) } else { @() }
                }

                $high = $riskResult.Summary.High
                $med  = $riskResult.Summary.Medium
                $low  = $riskResult.Summary.Low
                $detail = "$($riskResult.Summary.TotalIdentities) identities ($high High, $med Medium, $low Low)"
            }
            else {
                $digestData.IdentityRisk = @{
                    Summary = @{ TotalIdentities = 0; High = 0; Medium = 0; Low = 0; AvgRiskScore = 0 }
                    TopRisk = @(); Identities = @()
                }
                $detail = 'No identity risk data available'
            }
        }
        else {
            $digestData.IdentityRisk = @{
                Summary = @{ TotalIdentities = 0; High = 0; Medium = 0; Low = 0; AvgRiskScore = 0 }
                TopRisk = @(); Identities = @()
            }
            $detail = 'No campaign audit data to analyze'
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'IdentityRisk' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 3: $detail" -ForegroundColor Green
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'IdentityRisk' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Section 3: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Identity risk section failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'IdentityRiskError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Section 3: Identity Risk [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Section 4: Reviewer Performance

if (-not $SkipReviewerAnalysis) {
    Write-Host '  Section 4: Reviewer Performance' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        if ($campaignAudits.Count -gt 0) {
            $reputationResult = Measure-SPReviewerReputation -CampaignAudits $campaignAudits `
                -MinCampaigns 1 -CorrelationID $correlationID

            if ($null -ne $reputationResult -and $null -ne $reputationResult.Reviewers) {
                $reviewers      = @($reputationResult.Reviewers)
                $bestReviewers  = @($reviewers | Sort-Object -Property ReputationScore -Descending |
                    Select-Object -First 5)
                $worstReviewers = @($reviewers | Sort-Object -Property ReputationScore |
                    Select-Object -First 5)

                $digestData.ReviewerPerformance = @{
                    Summary      = $reputationResult.Summary
                    Best         = $bestReviewers
                    Worst        = $worstReviewers
                    AllReviewers = $reviewers
                }

                $totalReviewers = $reputationResult.Summary.TotalReviewers
                $atRisk = if ($null -ne $reputationResult.Summary.AtRisk) { $reputationResult.Summary.AtRisk } else { 0 }
                $detail = "$totalReviewers reviewers ($atRisk at risk)"
            }
            else {
                $digestData.ReviewerPerformance = @{
                    Summary = @{ TotalReviewers = 0 }; Best = @(); Worst = @(); AllReviewers = @()
                }
                $detail = 'No reviewer data available'
            }
        }
        else {
            $digestData.ReviewerPerformance = @{
                Summary = @{ TotalReviewers = 0 }; Best = @(); Worst = @(); AllReviewers = @()
            }
            $detail = 'No campaign audit data to analyze'
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'ReviewerPerformance' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 4: $detail" -ForegroundColor Green
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'ReviewerPerformance' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Section 4: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Reviewer performance section failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'ReviewerError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Section 4: Reviewer Performance [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Section 5: Remediation Tracking

if (-not $SkipRemediationTracking) {
    Write-Host '  Section 5: Remediation Tracking' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Extract revocation decisions from campaign audit data
        $revocations = [System.Collections.Generic.List[object]]::new()
        foreach ($audit in $campaignAudits) {
            if ($null -ne $audit.Decisions -and $null -ne $audit.Decisions.Revoked) {
                foreach ($rev in @($audit.Decisions.Revoked)) {
                    $revocations.Add($rev)
                }
            }
        }

        if ($revocations.Count -gt 0) {
            $remediationResult = Get-SPRemediationStatus -RevocationDecisions $revocations.ToArray() `
                -CorrelationID $correlationID

            if ($remediationResult.Success -and $null -ne $remediationResult.Data) {
                $remData = $remediationResult.Data
                $slaRate = 0
                if ($remData.Summary.Total -gt 0) {
                    $slaRate = [math]::Round(($remData.Summary.Provisioned / $remData.Summary.Total) * 100, 0)
                }

                $overdueItems = @()
                if ($null -ne $remData.Items) {
                    $overdueItems = @($remData.Items | Where-Object { $_.Status -eq 'Overdue' })
                }

                $digestData.Remediation = @{
                    Summary      = $remData.Summary
                    SlaRate      = $slaRate
                    OverdueItems = $overdueItems
                }

                $detail = "SLA: ${slaRate}% ($($remData.Summary.Provisioned) of $($remData.Summary.Total) within SLA)"
                if ($remData.Summary.Overdue -gt 0) {
                    $detail += ", $($remData.Summary.Overdue) overdue"
                }
            }
            else {
                $digestData.Remediation = @{
                    Summary = @{ Total = 0; Provisioned = 0; Overdue = 0; Pending = 0 }
                    SlaRate = 0; OverdueItems = @()
                }
                $errMsg = if ($null -ne $remediationResult.Error) { $remediationResult.Error } else { 'unknown error' }
                $detail = "WARN - $errMsg"
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
        }
        else {
            $digestData.Remediation = @{
                Summary = @{ Total = 0; Provisioned = 0; Overdue = 0; Pending = 0 }
                SlaRate = 0; OverdueItems = @()
            }
            $detail = 'No revocation decisions to track'
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'Remediation' -Status 'Success' -Detail $detail -Duration $stepDuration
        Write-Host "  Section 5: $detail" -ForegroundColor Green
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'Remediation' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Section 5: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Remediation section failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'RemediationError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Section 5: Remediation Tracking [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Section 6: Orchestrator Health

if (-not $SkipOrchestratorHealth) {
    Write-Host '  Section 6: Orchestrator Health' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $orchResult = Get-SPOrchestratorHistory -DaysBack $DaysBack -CorrelationID $correlationID
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($null -ne $orchResult -and $null -ne $orchResult.Metrics) {
            $metrics     = $orchResult.Metrics
            $runCount    = $metrics.RunCount
            $successRate = $metrics.SuccessRate
            $avgDuration = $metrics.AvgDurationSeconds
            $trend       = $metrics.DurationTrend

            # Format duration
            $avgDurMin = [int][math]::Floor($avgDuration / 60)
            $avgDurSec = [int]($avgDuration % 60)
            $avgDurStr = '{0}m {1:00}s' -f $avgDurMin, $avgDurSec

            $failCount    = 0
            $successCount = $runCount
            if ($null -ne $orchResult.Runs) {
                $failCount    = @($orchResult.Runs | Where-Object { $_.ExitCode -ne 0 }).Count
                $successCount = $runCount - $failCount
            }

            $digestData.OrchestratorHealth = @{
                RunCount            = $runCount
                SuccessCount        = $successCount
                FailCount           = $failCount
                SuccessRate         = $successRate
                AvgDuration         = $avgDurStr
                Trend               = $trend
                StepReliability     = $metrics.StepReliability
                ConsecutiveFailures = $metrics.ConsecutiveFailures
            }

            $detail = "Runs: ${successCount}/${runCount} successful | Avg: $avgDurStr | Trend: $trend"
            Set-SectionResult -Section 'OrchestratorHealth' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Section 6: $detail" -ForegroundColor Green
        }
        else {
            $digestData.OrchestratorHealth = @{
                RunCount = 0; SuccessCount = 0; FailCount = 0; SuccessRate = 0
                AvgDuration = 'N/A'; Trend = 'N/A'
            }
            $detail = 'No orchestrator history available'
            Set-SectionResult -Section 'OrchestratorHealth' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Section 6: $detail" -ForegroundColor Green
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-SectionResult -Section 'OrchestratorHealth' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Section 6: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Orchestrator health section failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'OrchestratorError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Section 6: Orchestrator Health [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Output

$endTime       = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr   = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

$overallResult = 'SUCCESS'
if ($worstExitCode -eq 1) { $overallResult = 'SUCCESS (with warnings)' }
if ($worstExitCode -ge 2) { $overallResult = 'FAILED' }

# --- Console output ---
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host ''
    Write-Host '  === Weekly Governance Digest ===' -ForegroundColor Cyan
    Write-Host "  Period:         $periodLabel"
    Write-Host "  Generated:      $($digestData.GeneratedAt)"
    Write-Host ''

    # Section 1
    if ($null -ne $digestData.CampaignActivity) {
        $ca = $digestData.CampaignActivity
        Write-Host '  --- Campaign Activity ---' -ForegroundColor Cyan
        Write-Host "    Created: $($ca.Created) | Completed: $($ca.Completed) | Active: $($ca.Active)"
        if ($ca.TotalItems -gt 0) {
            # NOTE: "Items in Scope" = total items needing a decision (Approved + Revoked + still Pending).
            # Approval% and Revoke% are percentages of ALL items, so a fresh campaign with few decisions
            # will show 0% even with some approvals -- that is correct (e.g. 46 of 10577 = 0.4% rounds to 0%).
            $decided = $ca.Approved + $ca.Revoked
            $pending = $ca.TotalItems - $decided
            $completionPct = if ($ca.TotalItems -gt 0) { [math]::Round(($decided / $ca.TotalItems) * 100, 1) } else { 0 }
            Write-Host "    Items in Scope: $($ca.TotalItems) | Decided: $decided ($completionPct% complete) | Pending: $pending"
            Write-Host "    Approved: $($ca.Approved) ($($ca.ApprovalRate)%) | Revoked: $($ca.Revoked) ($($ca.RevocationRate)%)"
        }
        $compStr = "    vs Last Week: $($ca.CampaignDelta) campaigns"
        if (-not [string]::IsNullOrWhiteSpace($ca.ApprovalRateDelta)) {
            $compStr += ", $($ca.ApprovalRateDelta) approval rate"
        }
        Write-Host $compStr

        # Per-campaign breakdown -- shows which campaigns are stalled vs. active,
        # so you can identify which manager groups need a nudge.
        if ($campaignAudits.Count -gt 0) {
            Write-Host ''
            Write-Host '    Per-Campaign Detail:' -ForegroundColor DarkGray

            # Build a lookup: campaign name -> deadline/status from $currentCampaigns
            $campLookup = @{}
            foreach ($c in $currentCampaigns) {
                $n = if ($null -ne $c.name) { [string]$c.name } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($n)) {
                    $campLookup[$n] = $c
                }
            }

            foreach ($audit in ($campaignAudits | Sort-Object { $_.CampaignName })) {
                $cName = [string]$audit.CampaignName
                $shortName = if ($cName.Length -gt 45) { $cName.Substring(0, 42) + '...' } else { $cName }

                $cApproved = 0; $cRevoked = 0; $cPending = 0
                if ($null -ne $audit.Decisions) {
                    $d = $audit.Decisions
                    if ($null -ne $d.Approved) { $cApproved = @($d.Approved).Count }
                    if ($null -ne $d.Revoked)  { $cRevoked  = @($d.Revoked).Count }
                    if ($null -ne $d.Pending)  { $cPending  = @($d.Pending).Count }
                }
                $cTotal   = $cApproved + $cRevoked + $cPending
                $cDecided = $cApproved + $cRevoked
                $cPct     = if ($cTotal -gt 0) { [math]::Round(($cDecided / $cTotal) * 100, 0) } else { 0 }

                # Deadline from campaign object
                $deadlineStr = ''
                if ($campLookup.ContainsKey($cName)) {
                    $campObj = $campLookup[$cName]
                    $dl = if ($null -ne $campObj.deadline) { $campObj.deadline }
                          elseif ($null -ne $campObj.deadlineDate) { $campObj.deadlineDate }
                          else { $null }
                    if ($null -ne $dl) {
                        try {
                            $dlDate  = [datetime]::Parse($dl.ToString(),
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::RoundtripKind)
                            $daysLeft = [int]($dlDate.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays
                            $deadlineStr = " | Due in ${daysLeft}d"
                            if ($daysLeft -le 0) { $deadlineStr = ' | OVERDUE' }
                        } catch { }
                    }
                }

                $pctColor = if ($cPct -ge 80) { 'Green' } elseif ($cPct -ge 40) { 'Yellow' } else { 'Red' }
                $line = "      {0,-47} {1,5} in scope  {2,3}% done  ({3}A {4}R {5}P){6}" -f `
                    $shortName, $cTotal, $cPct, $cApproved, $cRevoked, $cPending, $deadlineStr
                Write-Host $line -ForegroundColor $pctColor
            }
        }
        Write-Host ''
    }

    # Section 2
    if ($null -ne $digestData.CampaignHealth) {
        $ch = $digestData.CampaignHealth
        Write-Host '  --- Active Campaign Health ---' -ForegroundColor Cyan
        Write-Host "    Red: $($ch.Red) | Yellow: $($ch.Yellow) | Green: $($ch.Green)"
        Write-Host ''
    }

    # Section 3
    if ($null -ne $digestData.IdentityRisk -and $digestData.IdentityRisk.TopRisk.Count -gt 0) {
        Write-Host '  --- Top Identity Risks ---' -ForegroundColor Cyan
        $rank = 0
        foreach ($identity in $digestData.IdentityRisk.TopRisk) {
            $rank++
            $iName   = $identity.IdentityName
            $iScore  = $identity.RiskScore
            $iTier   = $identity.RiskTier
            $factors = if ($null -ne $identity.TopRiskFactors) { ($identity.TopRiskFactors -join ', ') } else { '' }
            $line    = "    ${rank}. " + ('{0,-20}' -f $iName) + " Score: $iScore ($iTier)"
            if ($factors) { $line += " - $factors" }
            Write-Host $line
        }
        Write-Host ''
    }

    # Section 4
    if ($null -ne $digestData.ReviewerPerformance -and $digestData.ReviewerPerformance.Best.Count -gt 0) {
        Write-Host '  --- Reviewer Performance ---' -ForegroundColor Cyan
        $best  = $digestData.ReviewerPerformance.Best
        $worst = $digestData.ReviewerPerformance.Worst
        if ($best.Count -gt 0) {
            $b      = $best[0]
            $avgHrs = if ($null -ne $b.AvgResponseHours) { '{0:F1}h' -f $b.AvgResponseHours } else { 'N/A' }
            Write-Host "    Best:  $($b.Name)  (Score: $($b.ReputationScore), Avg $avgHrs)"
        }
        if ($worst.Count -gt 0) {
            $w      = $worst[0]
            $avgHrs = if ($null -ne $w.AvgResponseHours) { '{0:F1}h' -f $w.AvgResponseHours } else { 'N/A' }
            $rsFlag = if ($w.RubberStampCount -gt 0) { ', Rubber-stamp' } else { '' }
            Write-Host "    Worst: $($w.Name)  (Score: $($w.ReputationScore), Avg $avgHrs$rsFlag)"
        }
        Write-Host ''
    }

    # Section 5
    if ($null -ne $digestData.Remediation -and $digestData.Remediation.Summary.Total -gt 0) {
        Write-Host '  --- Remediation SLA ---' -ForegroundColor Cyan
        $rem = $digestData.Remediation
        Write-Host "    Compliance: $($rem.SlaRate)% ($($rem.Summary.Provisioned) of $($rem.Summary.Total) within SLA)"
        if ($rem.OverdueItems.Count -gt 0) {
            Write-Host "    Overdue: $($rem.OverdueItems.Count) items requiring attention"
        }
        Write-Host ''
    }

    # Section 6
    if ($null -ne $digestData.OrchestratorHealth -and $digestData.OrchestratorHealth.RunCount -gt 0) {
        Write-Host '  --- Orchestrator Health ---' -ForegroundColor Cyan
        $oh = $digestData.OrchestratorHealth
        Write-Host "    Runs: $($oh.SuccessCount)/$($oh.RunCount) successful | Avg: $($oh.AvgDuration) | Trend: $($oh.Trend)"
        Write-Host ''
    }

    Write-Host "  Duration: $durationStr"
    Write-Host "  Result:   $overallResult" -ForegroundColor $(
        if ($worstExitCode -eq 0) { 'Green' }
        elseif ($worstExitCode -eq 1) { 'Yellow' }
        else { 'Red' }
    )
    Write-Host ''
}

# --- HTML output ---
$htmlPath    = $null
$htmlContent = ''

if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<title>Weekly Governance Digest - ' + (ConvertTo-SafeHtml $periodLabel) + '</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;margin:0;padding:20px;color:#333}')
    [void]$sb.AppendLine('.container{max-width:960px;margin:0 auto}')
    [void]$sb.AppendLine('.header{background:linear-gradient(135deg,#1a237e,#283593);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}')
    [void]$sb.AppendLine('.header h1{margin:0 0 8px 0;font-size:22px}.header .meta{font-size:13px;opacity:.85}')
    [void]$sb.AppendLine('.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}')
    [void]$sb.AppendLine('.section:last-of-type{border-radius:0 0 8px 8px}')
    [void]$sb.AppendLine('.section h2{color:#1a237e;font-size:16px;border-bottom:2px solid #e8eaf6;padding-bottom:8px;margin-top:0}')
    [void]$sb.AppendLine('.kpi-row{display:flex;gap:16px;flex-wrap:wrap;margin:12px 0}')
    [void]$sb.AppendLine('.kpi{background:#f5f5f5;border-radius:6px;padding:12px 16px;min-width:120px;flex:1}')
    [void]$sb.AppendLine('.kpi .label{font-size:11px;color:#666;text-transform:uppercase}.kpi .value{font-size:24px;font-weight:600;color:#1a237e}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:12px 0;font-size:13px}')
    [void]$sb.AppendLine('th{background:#e8eaf6;padding:8px 12px;text-align:left;font-weight:600}')
    [void]$sb.AppendLine('td{padding:8px 12px;border-bottom:1px solid #eee}tr:nth-child(even){background:#fafafa}')
    [void]$sb.AppendLine('.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600}')
    [void]$sb.AppendLine('.badge-red{background:#ffcdd2;color:#b71c1c}.badge-orange{background:#ffe0b2;color:#e65100}')
    [void]$sb.AppendLine('.badge-green{background:#c8e6c9;color:#1b5e20}.badge-yellow{background:#fff9c4;color:#f57f17}')
    [void]$sb.AppendLine('.delta{font-size:12px;color:#666;margin-top:4px}')
    [void]$sb.AppendLine('.footer{text-align:center;font-size:11px;color:#999;padding:16px}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<div class="container">')

    # Header
    [void]$sb.AppendLine('<div class="header">')
    [void]$sb.AppendLine('<h1>Weekly Governance Digest</h1>')
    [void]$sb.AppendLine('<div class="meta">Period: ' + (ConvertTo-SafeHtml $periodLabel) + ' | Generated: ' + (ConvertTo-SafeHtml $digestData.GeneratedAt) + '</div>')
    [void]$sb.AppendLine('</div>')

    # Section 1: Campaign Activity
    if ($null -ne $digestData.CampaignActivity) {
        $ca = $digestData.CampaignActivity
        [void]$sb.AppendLine('<div class="section"><h2>Campaign Activity</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Created</div><div class="value">' + $ca.Created + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Completed</div><div class="value">' + $ca.Completed + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Active</div><div class="value">' + $ca.Active + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Items Reviewed</div><div class="value">' + $ca.TotalItems + '</div></div>')
        [void]$sb.AppendLine('</div><div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Approved</div><div class="value">' + $ca.Approved + ' (' + $ca.ApprovalRate + '%)</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Revoked</div><div class="value">' + $ca.Revoked + ' (' + $ca.RevocationRate + '%)</div></div>')
        [void]$sb.AppendLine('</div>')
        $compHtml = 'vs Previous Period: ' + (ConvertTo-SafeHtml $ca.CampaignDelta) + ' campaigns'
        if (-not [string]::IsNullOrWhiteSpace($ca.ApprovalRateDelta)) {
            $compHtml += ', ' + (ConvertTo-SafeHtml $ca.ApprovalRateDelta) + ' approval rate'
        }
        [void]$sb.AppendLine('<div class="delta">' + $compHtml + '</div>')
        [void]$sb.AppendLine('</div>')
    }

    # Section 2: Campaign Health
    if ($null -ne $digestData.CampaignHealth) {
        $ch = $digestData.CampaignHealth
        [void]$sb.AppendLine('<div class="section"><h2>Active Campaign Health</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Red</div><div class="value" style="color:#b71c1c">' + $ch.Red + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Yellow</div><div class="value" style="color:#f57f17">' + $ch.Yellow + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Green</div><div class="value" style="color:#1b5e20">' + $ch.Green + '</div></div>')
        [void]$sb.AppendLine('</div>')
        if ($ch.Campaigns.Count -gt 0) {
            [void]$sb.AppendLine('<table><thead><tr><th>Campaign</th><th>Health</th><th>Completion</th><th>Stale Reviewers</th></tr></thead><tbody>')
            foreach ($hc in $ch.Campaigns) {
                $hBadge = switch ($hc.OverallHealth) {
                    'Red'    { '<span class="badge badge-red">Red</span>' }
                    'Yellow' { '<span class="badge badge-yellow">Yellow</span>' }
                    default  { '<span class="badge badge-green">Green</span>' }
                }
                $compPct = if ($null -ne $hc.CompletionPct) { '{0:F0}%' -f $hc.CompletionPct } else { 'N/A' }
                $stale   = if ($null -ne $hc.StaleReviewerCount) { $hc.StaleReviewerCount } else { 0 }
                [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $hc.CampaignName) + '</td><td>' + $hBadge + '</td><td>' + $compPct + '</td><td>' + $stale + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        [void]$sb.AppendLine('</div>')
    }

    # Section 3: Identity Risk
    if ($null -ne $digestData.IdentityRisk -and $digestData.IdentityRisk.TopRisk.Count -gt 0) {
        $ir = $digestData.IdentityRisk
        [void]$sb.AppendLine('<div class="section"><h2>Identity Risk Highlights</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Total Identities</div><div class="value">' + $ir.Summary.TotalIdentities + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">High Risk</div><div class="value" style="color:#b71c1c">' + $ir.Summary.High + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Medium Risk</div><div class="value" style="color:#e65100">' + $ir.Summary.Medium + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Low Risk</div><div class="value" style="color:#1b5e20">' + $ir.Summary.Low + '</div></div>')
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<table><thead><tr><th>#</th><th>Identity</th><th>Score</th><th>Tier</th><th>Top Risk Factors</th></tr></thead><tbody>')
        $rank = 0
        foreach ($identity in $ir.TopRisk) {
            $rank++
            $tierBadge = switch ($identity.RiskTier) {
                'High'   { '<span class="badge badge-red">High</span>' }
                'Medium' { '<span class="badge badge-orange">Medium</span>' }
                default  { '<span class="badge badge-green">Low</span>' }
            }
            $factors = if ($null -ne $identity.TopRiskFactors) {
                (($identity.TopRiskFactors | ForEach-Object { ConvertTo-SafeHtml $_ }) -join ', ')
            } else { '' }
            [void]$sb.AppendLine('<tr><td>' + $rank + '</td><td>' + (ConvertTo-SafeHtml $identity.IdentityName) + '</td><td>' + $identity.RiskScore + '</td><td>' + $tierBadge + '</td><td>' + $factors + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table></div>')
    }

    # Section 4: Reviewer Performance
    if ($null -ne $digestData.ReviewerPerformance -and $digestData.ReviewerPerformance.AllReviewers.Count -gt 0) {
        $rp = $digestData.ReviewerPerformance
        [void]$sb.AppendLine('<div class="section"><h2>Reviewer Performance</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Total Reviewers</div><div class="value">' + $rp.Summary.TotalReviewers + '</div></div>')
        $excellent = if ($null -ne $rp.Summary.Excellent) { $rp.Summary.Excellent } else { 0 }
        $atRisk    = if ($null -ne $rp.Summary.AtRisk)    { $rp.Summary.AtRisk }    else { 0 }
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Excellent</div><div class="value" style="color:#1b5e20">' + $excellent + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">At Risk</div><div class="value" style="color:#b71c1c">' + $atRisk + '</div></div>')
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<table><thead><tr><th>Reviewer</th><th>Score</th><th>Tier</th><th>Avg Response</th><th>Rubber-Stamp</th></tr></thead><tbody>')
        $allSorted = @($rp.AllReviewers | Sort-Object -Property ReputationScore -Descending)
        foreach ($rev in $allSorted) {
            $tierBadge = switch ($rev.ReputationTier) {
                'Excellent'       { '<span class="badge badge-green">Excellent</span>' }
                'Good'            { '<span class="badge badge-green">Good</span>' }
                'Needs Attention' { '<span class="badge badge-orange">Needs Attention</span>' }
                'At Risk'         { '<span class="badge badge-red">At Risk</span>' }
                default           { '<span class="badge">' + (ConvertTo-SafeHtml $rev.ReputationTier) + '</span>' }
            }
            $avgHrs  = if ($null -ne $rev.AvgResponseHours) { '{0:F1}h' -f $rev.AvgResponseHours } else { 'N/A' }
            $rsCount = if ($null -ne $rev.RubberStampCount) { $rev.RubberStampCount } else { 0 }
            [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $rev.Name) + '</td><td>' + $rev.ReputationScore + '</td><td>' + $tierBadge + '</td><td>' + $avgHrs + '</td><td>' + $rsCount + '</td></tr>')
        }
        [void]$sb.AppendLine('</tbody></table></div>')
    }

    # Section 5: Remediation
    if ($null -ne $digestData.Remediation -and $digestData.Remediation.Summary.Total -gt 0) {
        $rem = $digestData.Remediation
        [void]$sb.AppendLine('<div class="section"><h2>Remediation Tracking</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">SLA Compliance</div><div class="value">' + $rem.SlaRate + '%</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Provisioned</div><div class="value">' + $rem.Summary.Provisioned + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Overdue</div><div class="value" style="color:#b71c1c">' + $rem.Summary.Overdue + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Pending</div><div class="value">' + $rem.Summary.Pending + '</div></div>')
        [void]$sb.AppendLine('</div>')
        if ($rem.OverdueItems.Count -gt 0) {
            [void]$sb.AppendLine('<table><thead><tr><th>Identity</th><th>Entitlement</th><th>Decision Date</th><th>Status</th></tr></thead><tbody>')
            foreach ($item in $rem.OverdueItems) {
                [void]$sb.AppendLine('<tr><td>' + (ConvertTo-SafeHtml $item.IdentityName) + '</td><td>' + (ConvertTo-SafeHtml $item.EntitlementName) + '</td><td>' + (ConvertTo-SafeHtml $item.DecisionDate) + '</td><td><span class="badge badge-red">Overdue</span></td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table>')
        }
        [void]$sb.AppendLine('</div>')
    }

    # Section 6: Orchestrator Health
    if ($null -ne $digestData.OrchestratorHealth -and $digestData.OrchestratorHealth.RunCount -gt 0) {
        $oh = $digestData.OrchestratorHealth
        [void]$sb.AppendLine('<div class="section"><h2>Orchestrator Health</h2>')
        [void]$sb.AppendLine('<div class="kpi-row">')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Total Runs</div><div class="value">' + $oh.RunCount + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Successful</div><div class="value" style="color:#1b5e20">' + $oh.SuccessCount + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Failed</div><div class="value" style="color:#b71c1c">' + $oh.FailCount + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Avg Duration</div><div class="value">' + (ConvertTo-SafeHtml $oh.AvgDuration) + '</div></div>')
        [void]$sb.AppendLine('<div class="kpi"><div class="label">Trend</div><div class="value">' + (ConvertTo-SafeHtml $oh.Trend) + '</div></div>')
        [void]$sb.AppendLine('</div></div>')
    }

    # Footer
    [void]$sb.AppendLine('<div class="footer">SailPoint ISC Governance Toolkit - Weekly Digest - Generated ' + (ConvertTo-SafeHtml $digestData.GeneratedAt) + '</div>')
    [void]$sb.AppendLine('</div></body></html>')

    $htmlContent = $sb.ToString()
    $htmlFileName = "digest-$todayLabel.html"
    $htmlPath     = Join-Path $effectiveOutputPath $htmlFileName

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlPath, $htmlContent, $utf8NoBom)
    Write-Host "  HTML report: $htmlPath" -ForegroundColor Green
}

# --- JSON output ---
if ($OutputMode -eq 'JSON') {
    $summaryObject = [ordered]@{
        Period          = $periodLabel
        GeneratedAt     = $digestData.GeneratedAt
        CorrelationID   = $correlationID
        DaysBack        = $DaysBack
        DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
        Result          = $overallResult
        ExitCode        = $worstExitCode
        Sections        = $sectionResults
        Data            = $digestData
    }
    $summaryObject | ConvertTo-Json -Depth 10
}

#endregion

#region Notification

if ($SendNotification) {
    Write-Host ''
    Write-Host '  Sending notification...' -ForegroundColor Cyan

    try {
        # Build text summary for notification body
        $bodyLines = [System.Collections.Generic.List[string]]::new()
        $bodyLines.Add("Weekly Governance Digest")
        $bodyLines.Add("Period: $periodLabel")
        $bodyLines.Add("")
        foreach ($secName in $sectionResults.Keys) {
            $sr = $sectionResults[$secName]
            if ($sr.Status -ne 'Skipped') {
                $bodyLines.Add("${secName}: $($sr.Detail)")
            }
        }
        $notifyBody = $bodyLines -join "`n"

        $notifyParams = @{
            Subject       = "Weekly Governance Digest - $todayLabel"
            Body          = $notifyBody
            Severity      = 'Info'
            Category      = 'Digest'
            CorrelationID = $correlationID
        }
        if ($NotifyRecipients -and $NotifyRecipients.Count -gt 0) {
            $notifyParams['Recipients'] = $NotifyRecipients
        }
        if (-not [string]::IsNullOrWhiteSpace($htmlPath) -and (Test-Path $htmlPath)) {
            $notifyParams['Attachments'] = @($htmlPath)
        }

        $notifyResult = Send-SPNotification @notifyParams

        if ($notifyResult.Success) {
            Write-Host '  Notification sent successfully.' -ForegroundColor Green
        }
        else {
            Write-Host '  WARN: Notification partially failed - check logs.' -ForegroundColor Yellow
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        Write-Host "  WARN: Notification failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Notification failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'WeeklyDigest' -Action 'NotificationError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
}

#endregion

Write-SPLog -Message "Invoke-SPWeeklyDigest completed: ExitCode=$worstExitCode Duration=$durationStr" `
    -Severity INFO -Component 'WeeklyDigest' -Action 'Complete' -CorrelationID $correlationID

exit $worstExitCode
