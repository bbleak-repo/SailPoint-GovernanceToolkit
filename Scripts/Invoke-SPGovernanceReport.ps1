#Requires -Version 5.1
<#
.SYNOPSIS
    Produces a complete governance report package in a single command.
.DESCRIPTION
    Orchestrates multiple governance analysis dimensions into one output
    directory with a manifest file:
    - Campaign Audit: certifications, decisions, reviewer metrics, rubber-stamp risk
    - Policy Compliance (DF-01): pass/fail per governance policy
    - Data Quality (P16-08): orphan accounts, aggregation health, identity quality
    - Dashboard Data Export (DF-02): flat CSV/JSON for Power BI / Splunk
    - Leadership Rollup: per-level director/VP/exec roll-ups (optional)

    Designed as the single script an auditor or governance lead runs to get
    a complete picture of the ISC governance posture.
.PARAMETER Status
    Campaign status filter. One or more of: STAGED, ACTIVE, COMPLETING, COMPLETED.
.PARAMETER DaysBack
    Campaign lookback window in days. Default 30.
.PARAMETER CampaignName
    Exact campaign name filter (eq match).
.PARAMETER CampaignNameStartsWith
    Campaign name prefix filter (sw match).
.PARAMETER CampaignNameContains
    Campaign name substring filter (co match).
.PARAMETER IncludeLeadershipRollup
    Include leadership-level roll-up reports.
.PARAMETER LeadershipDepth
    Org tree depth for leadership rollup. Default 3.
.PARAMETER IncludePolicyCheck
    Include governance policy compliance evaluation.
.PARAMETER IncludeDataQuality
    Include data quality assessment (orphans, aggregation health, identity quality).
.PARAMETER IdentityLimit
    Maximum identities for data quality scoring. Default 500.
.PARAMETER MaxStalenessHours
    Hours after which a source is considered stale. Default 48.
.PARAMETER SkipDashboardExport
    Skip the dashboard data export step.
.PARAMETER OutputPath
    Root directory for report output. Auto-resolved from config if omitted.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication.
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER OutputMode
    Output format: Console, JSON, or Both. Default Console.
.PARAMETER DetailLevel
    Report detail level: Summary, Detailed, or Verbose. Default Verbose.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be generated without making API calls.
.EXAMPLE
    .\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -DaysBack 90 -Token $token
    # Full governance report for completed campaigns in the last 90 days.
.EXAMPLE
    .\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -IncludePolicyCheck -IncludeDataQuality -Token $token
    # Full report with policy compliance and data quality sections.
.EXAMPLE
    .\Invoke-SPGovernanceReport.ps1 -Status COMPLETED -IncludeLeadershipRollup -OutputMode Both -Token $token
    # Full report with leadership rollup, console + JSON output.
.EXAMPLE
    .\Invoke-SPGovernanceReport.ps1 -WhatIf
    # Dry run -- shows what would be generated without API calls.
.NOTES
    Script:  Invoke-SPGovernanceReport.ps1
    Version: 1.0.0
    Phase:   P13-09 (DF-03)
    Exit codes:
        0 = Success, all sections completed
        1 = No campaigns matched filter criteria
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Partial failure (one or more sections failed)
#>
[CmdletBinding()]
param(
    # Campaign filters
    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [int]$DaysBack = 30,

    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    # Section toggles
    [Parameter()]
    [switch]$IncludeLeadershipRollup,

    [Parameter()]
    [int]$LeadershipDepth = 3,

    [Parameter()]
    [switch]$IncludePolicyCheck,

    [Parameter()]
    [switch]$IncludeDataQuality,

    [Parameter()]
    [int]$IdentityLimit = 500,

    [Parameter()]
    [int]$MaxStalenessHours = 48,

    [Parameter()]
    [switch]$SkipDashboardExport,

    # Output
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [ValidateSet('Summary', 'Detailed', 'Verbose')]
    [string]$DetailLevel = 'Verbose',

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';       Name = 'SP.Core';     Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';         Name = 'SP.Api';      Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';     Name = 'SP.Audit';    Required = $true  }
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
Write-Host '  Comprehensive Governance Report' -ForegroundColor Cyan
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

Write-SPLog -Message "Invoke-SPGovernanceReport started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'GovernanceReport' -Action 'Start' -CorrelationID $correlationID

# Validate: at least one campaign filter must be provided
if (-not $CampaignName -and -not $CampaignNameStartsWith -and
    -not $CampaignNameContains -and (-not $Status -or $Status.Count -eq 0)) {
    Write-Host 'ERROR: At least one campaign filter is required: -Status, -CampaignName, -CampaignNameStartsWith, or -CampaignNameContains' -ForegroundColor Red
    exit 2
}

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

# Create a timestamped report package directory
$packageName = "GovernanceReport-$($startTime.ToString('yyyyMMdd-HHmmss'))"
$packagePath = Join-Path $effectiveOutputPath $packageName
if (-not (Test-Path $packagePath)) {
    New-Item -ItemType Directory -Path $packagePath -Force | Out-Null
}

# Apply config defaults for optional params
$effectiveDaysBack = $DaysBack
if ($DaysBack -eq 30 -and $null -ne $config.PSObject.Properties['Audit'] -and
    $null -ne $config.Audit -and $null -ne $config.Audit.PSObject.Properties['DefaultDaysBack'] -and
    $config.Audit.DefaultDaysBack) {
    $effectiveDaysBack = [int]$config.Audit.DefaultDaysBack
}

$effectiveLeadershipRollup = [bool]$IncludeLeadershipRollup
if (-not $IncludeLeadershipRollup -and $null -ne $config.PSObject.Properties['Audit'] -and
    $null -ne $config.Audit -and $null -ne $config.Audit.PSObject.Properties['IncludeLeadershipRollup'] -and
    $config.Audit.IncludeLeadershipRollup) {
    $effectiveLeadershipRollup = $true
}

# Resolve source IDs from config for data quality
$effectiveSourceIds = @()
if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['SourceIds'] -and
    $config.DeltaCert.SourceIds.Count -gt 0) {
    $effectiveSourceIds = @($config.DeltaCert.SourceIds)
}

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true) -or $WhatIf

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following sections would be generated:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  [1] Campaign Audit: DaysBack=$effectiveDaysBack" -ForegroundColor Gray
    if ($Status) { Write-Host "      Status filter: $($Status -join ', ')" -ForegroundColor Gray }
    if ($CampaignName) { Write-Host "      Name filter (eq): $CampaignName" -ForegroundColor Gray }
    if ($CampaignNameStartsWith) { Write-Host "      Name filter (sw): $CampaignNameStartsWith" -ForegroundColor Gray }
    if ($CampaignNameContains) { Write-Host "      Name filter (co): $CampaignNameContains" -ForegroundColor Gray }

    if ($IncludePolicyCheck) {
        Write-Host '  [2] Policy Compliance: governance policy evaluation' -ForegroundColor Gray
    }
    else {
        Write-Host '  [2] Policy Compliance: SKIPPED (use -IncludePolicyCheck)' -ForegroundColor DarkGray
    }

    if ($IncludeDataQuality) {
        $srcDisplay = if ($effectiveSourceIds.Count -gt 0) { $effectiveSourceIds -join ', ' } else { 'all enabled sources' }
        Write-Host "  [3] Data Quality: $srcDisplay (staleness: ${MaxStalenessHours}h, limit: $IdentityLimit)" -ForegroundColor Gray
    }
    else {
        Write-Host '  [3] Data Quality: SKIPPED (use -IncludeDataQuality)' -ForegroundColor DarkGray
    }

    if (-not $SkipDashboardExport) {
        Write-Host '  [4] Dashboard Data Export: CSV + JSON for BI tools' -ForegroundColor Gray
    }
    else {
        Write-Host '  [4] Dashboard Data Export: SKIPPED (-SkipDashboardExport)' -ForegroundColor DarkGray
    }

    if ($effectiveLeadershipRollup) {
        Write-Host "  [5] Leadership Rollup: depth=$LeadershipDepth" -ForegroundColor Gray
    }
    else {
        Write-Host '  [5] Leadership Rollup: SKIPPED (use -IncludeLeadershipRollup)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "  Would write output to: $packagePath" -ForegroundColor Cyan
    Write-Host "  CorrelationID:         $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [WhatIf] Validation complete. Re-run without -WhatIf to execute.' -ForegroundColor Yellow
    exit 0
}

#endregion

#region Step Tracking

$stepResults = [ordered]@{
    CampaignAudit    = @{ Status = 'Pending'; Detail = ''; Duration = 0; Files = @() }
    PolicyCompliance = @{ Status = 'Skipped'; Detail = ''; Duration = 0; Files = @() }
    DataQuality      = @{ Status = 'Skipped'; Detail = ''; Duration = 0; Files = @() }
    DashboardExport  = @{ Status = 'Skipped'; Detail = ''; Duration = 0; Files = @() }
    LeadershipRollup = @{ Status = 'Skipped'; Detail = ''; Duration = 0; Files = @() }
}

function Set-StepResult {
    param([string]$Step, [string]$Status, [string]$Detail, [double]$Duration, [string[]]$Files)
    $stepResults[$Step]['Status']   = $Status
    $stepResults[$Step]['Detail']   = $Detail
    $stepResults[$Step]['Duration'] = [math]::Round($Duration, 2)
    if ($Files) { $stepResults[$Step]['Files'] = $Files }
}

$worstExitCode = 0

#endregion

#region Step 1: Campaign Audit

Write-Host '  Step 1: Campaign Audit' -ForegroundColor Cyan
$stepStart = Get-Date

$auditCampaignParams = @{
    DaysBack      = $effectiveDaysBack
    CorrelationID = $correlationID
}
if ($CampaignName)           { $auditCampaignParams['CampaignName']           = $CampaignName }
if ($CampaignNameStartsWith) { $auditCampaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
if ($CampaignNameContains)   { $auditCampaignParams['CampaignNameContains']   = $CampaignNameContains }
if ($Status)                 { $auditCampaignParams['Status']                 = $Status }

$campaignsResult = Get-SPAuditCampaigns @auditCampaignParams

if (-not $campaignsResult.Success) {
    Write-Host "    ERROR: Failed to retrieve campaigns: $($campaignsResult.Error)" -ForegroundColor Red
    Set-StepResult -Step 'CampaignAudit' -Status 'Failed' -Detail $campaignsResult.Error `
        -Duration ((Get-Date) - $stepStart).TotalSeconds
    Write-SPLog -Message "Failed to retrieve campaigns: $($campaignsResult.Error)" `
        -Severity ERROR -Component 'GovernanceReport' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 3
}

$campaigns = $campaignsResult.Data

if (-not $campaigns -or $campaigns.Count -eq 0) {
    Write-Host '    No campaigns matched the specified filter criteria.' -ForegroundColor Yellow
    Set-StepResult -Step 'CampaignAudit' -Status 'NoData' -Detail 'No campaigns matched filter' `
        -Duration ((Get-Date) - $stepStart).TotalSeconds
    Write-SPLog -Message "No campaigns matched filter criteria" `
        -Severity WARN -Component 'GovernanceReport' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 1
}

Write-Host "    Found $($campaigns.Count) campaign(s)." -ForegroundColor Green

# Per-campaign audit data collection
$allCampaignAudits = [System.Collections.Generic.List[object]]::new()
$campaignOutputFiles = [System.Collections.Generic.List[string]]::new()

foreach ($campaign in $campaigns) {
    $campId   = $campaign.id
    $campName = $campaign.name

    Write-Host "    Processing: $campName ($campId)" -ForegroundColor DarkGray

    # Certifications
    $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
    $certifications = @()
    if ($certResult.Success) {
        $certifications = @($certResult.Data)
    }
    else {
        Write-Host "      WARN: Could not retrieve certifications: $($certResult.Error)" -ForegroundColor Yellow
    }

    # Certification items (cached). Fetched from ISC once per campaign, then served from
    # disk/memory on later runs (COMPLETED campaigns are cached permanently). We pass the
    # certs already fetched above so the cache doesn't re-enumerate them. The cache returns
    # items pre-wrapped as @{Item;CertificationId;CertificationName;CampaignName}; the raw
    # $allItems list (used below for revoked-identity extraction) is rebuilt from .Item.
    $wrappedAllItems = [System.Collections.Generic.List[object]]::new()
    $allItems        = [System.Collections.Generic.List[object]]::new()
    $cacheResult = Get-SPCachedCampaignItems -Campaign $campaign -Certifications $certifications -CorrelationID $correlationID
    if ($cacheResult.Success) {
        foreach ($wi in $cacheResult.Data) {
            $wrappedAllItems.Add($wi)
            $allItems.Add($wi.Item)
        }
        $srcLabel = if ($cacheResult.FromCache) { 'cache' } else { 'ISC' }
        Write-Host "      $($allItems.Count) review items across $($certifications.Count) certification(s) [from $srcLabel]." -ForegroundColor DarkGray
    }
    else {
        Write-Host "      WARN: Could not retrieve items: $($cacheResult.Error)" -ForegroundColor Yellow
    }

    # Campaign reports (API)
    $campaignReportRows = $null
    if ($config.Audit -and $config.Audit.IncludeCampaignReports -ne $false) {
        $campaignReportRows = @{}
        foreach ($reportType in @('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')) {
            $reportResult = Get-SPAuditCampaignReport -CampaignId $campId -ReportType $reportType `
                -CorrelationID $correlationID
            if ($reportResult.Success) {
                $campaignReportRows[$reportType] = @($reportResult.Data)
            }
        }
        if ($campaignReportRows.Count -eq 0) { $campaignReportRows = $null }
    }

    # Resolve identity accounts for UPN/sAMAccountName
    $uniqueIdentityIds = @($wrappedAllItems | ForEach-Object {
        $item = $_.Item
        $iid = if ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.identityId) { $item.identitySummary.identityId }
               elseif ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) { $item.identitySummary.id }
               else { $null }
        $iid
    } | Where-Object { $_ } | Sort-Object -Unique)

    $accountMap = @{}
    if ($uniqueIdentityIds.Count -gt 0) {
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $uniqueIdentityIds -CorrelationID $correlationID
        if ($acctResult.Success) { $accountMap = $acctResult.Data }
    }

    # Campaign metadata
    $campaignMetadata = @{
        StartDate      = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
        DueDate        = if ($null -ne $campaign.deadline)   { [string]$campaign.deadline }
                         elseif ($null -ne $campaign.due)    { [string]$campaign.due }       else { '' }
        CompletionDate = if ($null -ne $campaign.completed)  { [string]$campaign.completed } else { '' }
    }

    # Cert reviewer email map
    $certReviewerEmailMap = @{}
    foreach ($cert in $certifications) {
        if ($null -ne $cert.id -and $null -ne $cert.reviewer -and
            $null -ne $cert.reviewer.email -and
            -not [string]::IsNullOrWhiteSpace([string]$cert.reviewer.email)) {
            $certReviewerEmailMap[[string]$cert.id] = [string]$cert.reviewer.email
        }
    }

    # Identity lifecycle events for revoked identities
    $revokedIdentityIds = @(
        $allItems | ForEach-Object {
            if ($null -ne $_.decision -and $_.decision -eq 'REVOKE' -and
                $null -ne $_.identitySummary -and $null -ne $_.identitySummary.id) {
                $_.identitySummary.id
            }
        } | Where-Object { $_ } | Sort-Object -Unique
    )

    $identityEvents = @()
    if ($revokedIdentityIds.Count -gt 0 -and ($config.Audit -and $config.Audit.IncludeIdentityEvents -ne $false)) {
        foreach ($identityId in $revokedIdentityIds) {
            $eventResult = Get-SPAuditIdentityEvents -IdentityId $identityId -DaysBack 2 -CorrelationID $correlationID
            if ($eventResult.Success -and $null -ne $eventResult.Data) {
                foreach ($evt in $eventResult.Data) { $identityEvents += $evt }
            }
        }
    }

    # Analytics
    $decisionGroups   = Group-SPAuditDecisions         -Items $wrappedAllItems.ToArray() -AccountMap $accountMap -CampaignMetadata $campaignMetadata -CertReviewerEmailMap $certReviewerEmailMap
    $reviewerActions  = Group-SPReviewerActions        -Certifications $certifications
    $reviewerMetrics  = Measure-SPAuditReviewerMetrics -Certifications $certifications
    $eventGroups      = Group-SPAuditIdentityEvents    -Events $identityEvents
    $remediationProof = Group-SPAuditRemediationProof  -Items $wrappedAllItems.ToArray() -Certifications $certifications -AccountMap $accountMap
    $rubberStampRisk  = Measure-SPAuditRubberStampRisk -Decisions $decisionGroups -Certifications $certifications

    # Build per-campaign audit hashtable
    $campaignAudit = @{
        CampaignName             = $campName
        CampaignId               = $campId
        Status                   = if ($null -ne $campaign.status)              { [string]$campaign.status }           else { '' }
        Created                  = if ($null -ne $campaign.created)             { [string]$campaign.created }          else { '' }
        Completed                = if ($null -ne $campaign.completed)           { [string]$campaign.completed }        else { '' }
        Deadline                 = if ($null -ne $campaign.deadline)            { [string]$campaign.deadline }
                                   elseif ($null -ne $campaign.due)             { [string]$campaign.due }              else { '' }
        TotalCertifications      = if ($null -ne $campaign.totalCertifications) { [int]$campaign.totalCertifications } else { 0 }
        Decisions                = $decisionGroups
        Reviewers                = $reviewerActions
        ReviewerMetrics          = $reviewerMetrics
        Events                   = $eventGroups
        RemediationProof         = $remediationProof
        RubberStampRisk          = $rubberStampRisk
        CampaignReports          = $campaignReportRows
        CampaignReportsAvailable = ($null -ne $campaignReportRows)
    }
    $allCampaignAudits.Add($campaignAudit)

    # Per-campaign HTML + text.
    # Truncate to 40 chars MAX to avoid Windows MAX_PATH (260) violations when the
    # campaign name is long (e.g. "Daily Attestation Manager Campaign - Monday, June 08 2026").
    # Replace all chars unsafe in filesystem names + spaces/commas with hyphens,
    # collapse runs, strip leading/trailing hyphens, then trim to 40.
    $safeFileName = ($campName -replace '[\\/:*?"<>|\s,.]', '-' -replace '-{2,}', '-').Trim('-')
    if ($safeFileName.Length -gt 40) { $safeFileName = $safeFileName.Substring(0, 40).TrimEnd('-') }
    if ([string]::IsNullOrWhiteSpace($safeFileName)) { $safeFileName = 'campaign' }
    $campOutputDir = Join-Path $packagePath $safeFileName
    if (-not (Test-Path $campOutputDir)) {
        $null = New-Item -ItemType Directory -Path $campOutputDir -Force
    }

    Export-SPAuditHtml -CampaignAudits @($campaignAudit) -OutputPath $campOutputDir `
        -CorrelationID $correlationID -DetailLevel $DetailLevel
    Export-SPAuditText -CampaignAudits @($campaignAudit) -OutputPath $campOutputDir `
        -CorrelationID $correlationID

    $campaignOutputFiles.Add($campOutputDir)
}

# Combined HTML report
$combinedHtmlPaths = Export-SPAuditHtml -CampaignAudits $allCampaignAudits.ToArray() `
    -OutputPath $packagePath -Combined -CorrelationID $correlationID -DetailLevel $DetailLevel

# JSONL audit trail
$jsonlEvents = foreach ($audit in $allCampaignAudits) {
    $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
    @{
        Action            = 'CampaignAudited'
        CampaignId        = $audit['CampaignId']
        CampaignName      = $audit['CampaignName']
        DecisionsApproved = if ($null -ne $d -and $null -ne $d['Approved']) { @($d['Approved']).Count } else { 0 }
        DecisionsRevoked  = if ($null -ne $d -and $null -ne $d['Revoked'])  { @($d['Revoked']).Count  } else { 0 }
        DecisionsPending  = if ($null -ne $d -and $null -ne $d['Pending'])  { @($d['Pending']).Count  } else { 0 }
    }
}
Export-SPAuditJsonl -Events @($jsonlEvents) -OutputPath $packagePath -CorrelationID $correlationID

$stepDuration = ((Get-Date) - $stepStart).TotalSeconds
Set-StepResult -Step 'CampaignAudit' -Status 'Success' `
    -Detail "$($campaigns.Count) campaign(s) audited" -Duration $stepDuration `
    -Files @($campaignOutputFiles.ToArray())
Write-Host "    Step 1 complete: $($campaigns.Count) campaign(s) audited ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green
Write-Host ''

#endregion

#region Step 2: Policy Compliance

if ($IncludePolicyCheck) {
    Write-Host '  Step 2: Policy Compliance' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $policyParams = @{ CorrelationID = $correlationID }

        # Pass campaign audits as hashtable array
        $auditHts = @($allCampaignAudits | ForEach-Object {
            if ($_ -is [hashtable]) { $_ } else { @{} }
        })
        if ($auditHts.Count -gt 0) { $policyParams['CampaignAudits'] = $auditHts }

        $policyResults = Test-SPGovernancePolicy @policyParams

        if ($null -ne $policyResults) {
            # Generate HTML report
            $policyHtmlPath = Export-SPPolicyComplianceHtml `
                -PolicyResults $policyResults -OutputPath $packagePath `
                -CorrelationID $correlationID

            $compliantLabel = if ($policyResults.OverallCompliant) { 'COMPLIANT' } else { 'NON-COMPLIANT' }
            $passed = $policyResults.Summary.Passed
            $failed = $policyResults.Summary.Failed
            $detail = "$compliantLabel ($passed passed, $failed failed)"

            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'PolicyCompliance' -Status 'Success' -Detail $detail `
                -Duration $stepDuration -Files @($policyHtmlPath)
            Write-Host "    $detail ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green
        }
        else {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'PolicyCompliance' -Status 'NoData' `
                -Detail 'No policy results returned' -Duration $stepDuration
            Write-Host '    No policy results returned.' -ForegroundColor Yellow
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'PolicyCompliance' -Status 'Failed' `
            -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "    WARN: Policy check failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Policy check failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceReport' -Action 'PolicyCheck' -CorrelationID $correlationID
        if ($worstExitCode -lt 5) { $worstExitCode = 5 }
    }
    Write-Host ''
}

#endregion

#region Step 3: Data Quality

if ($IncludeDataQuality) {
    Write-Host '  Step 3: Data Quality Assessment' -ForegroundColor Cyan
    $stepStart = Get-Date
    $dqFiles = [System.Collections.Generic.List[string]]::new()
    $dqSections = 0
    $dqFailed = 0

    try {
        # 3a: Source aggregation health
        Write-Host '    3a: Source Aggregation Health...' -ForegroundColor DarkGray
        $aggParams = @{ CorrelationID = $correlationID; MaxStalenessHours = $MaxStalenessHours }
        if ($effectiveSourceIds.Count -gt 0) { $aggParams['SourceIds'] = $effectiveSourceIds }
        $aggHealthResult = Get-SPSourceAggregationHealth @aggParams
        $aggHealthData = $null
        if ($aggHealthResult.Success) {
            $aggHealthData = $aggHealthResult.Data
            $dqSections++
            try {
                $htmlPath = Export-SPSourceAggregationHealthHtml -HealthData $aggHealthData `
                    -OutputPath $packagePath -CorrelationID $correlationID
                $dqFiles.Add($htmlPath)
            }
            catch {
                Write-Host "      WARN: Aggregation health HTML: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "      WARN: Aggregation health: $($aggHealthResult.Error)" -ForegroundColor Yellow
            $dqFailed++
        }

        # 3b: Orphan accounts
        Write-Host '    3b: Orphan Account Detection...' -ForegroundColor DarkGray
        $orphanParams = @{ CorrelationID = $correlationID }
        if ($effectiveSourceIds.Count -gt 0) { $orphanParams['SourceIds'] = $effectiveSourceIds }
        $orphanResult = Get-SPOrphanAccounts @orphanParams
        $orphanData = $null
        if ($orphanResult.Success) {
            $orphanData = $orphanResult.Data
            $dqSections++
            try {
                $htmlPath = Export-SPOrphanAccountHtml -OrphanData $orphanData `
                    -OutputPath $packagePath -CorrelationID $correlationID
                $dqFiles.Add($htmlPath)
            }
            catch {
                Write-Host "      WARN: Orphan account HTML: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "      WARN: Orphan accounts: $($orphanResult.Error)" -ForegroundColor Yellow
            $dqFailed++
        }

        # 3c: Identity attribute quality
        Write-Host '    3c: Identity Attribute Quality...' -ForegroundColor DarkGray
        $qualityResult = Measure-SPIdentityDataQuality -Limit $IdentityLimit -ActiveOnly -CorrelationID $correlationID
        $qualityData = $null
        if ($null -ne $qualityResult -and $null -ne $qualityResult.Summary) {
            $qualityData = $qualityResult
            $dqSections++
            try {
                $htmlPath = Export-SPIdentityDataQualityHtml -QualityData $qualityData `
                    -OutputPath $packagePath -CorrelationID $correlationID
                $dqFiles.Add($htmlPath)
            }
            catch {
                Write-Host "      WARN: Identity quality HTML: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host '      WARN: Identity quality returned no data.' -ForegroundColor Yellow
            $dqFailed++
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        $dqDetail = "$dqSections/3 sections completed"
        if ($dqFailed -gt 0) { $dqDetail += ", $dqFailed failed" }
        $dqStatus = if ($dqFailed -eq 0) { 'Success' } elseif ($dqSections -gt 0) { 'Partial' } else { 'Failed' }
        Set-StepResult -Step 'DataQuality' -Status $dqStatus -Detail $dqDetail `
            -Duration $stepDuration -Files $dqFiles.ToArray()
        Write-Host "    $dqDetail ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green

        if ($dqStatus -eq 'Failed' -and $worstExitCode -lt 5) { $worstExitCode = 5 }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DataQuality' -Status 'Failed' `
            -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "    WARN: Data quality failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Data quality failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceReport' -Action 'DataQuality' -CorrelationID $correlationID
        if ($worstExitCode -lt 5) { $worstExitCode = 5 }
    }
    Write-Host ''
}

#endregion

#region Step 4: Dashboard Data Export

if (-not $SkipDashboardExport) {
    Write-Host '  Step 4: Dashboard Data Export' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $dashParams = @{
            CampaignAudits = $allCampaignAudits.ToArray()
            OutputPath     = $packagePath
            Format         = 'Both'
            CorrelationID  = $correlationID
        }

        # Pass policy results if available
        if ($IncludePolicyCheck -and $null -ne $policyResults) {
            $dashParams['PolicyResults'] = $policyResults
        }

        $dashResult = Export-SPGovernanceDashboardData @dashParams

        if ($dashResult.Success) {
            $dashFiles = @()
            if ($dashResult.Data.CsvFile)  { $dashFiles += $dashResult.Data.CsvFile }
            if ($dashResult.Data.JsonFile) { $dashFiles += $dashResult.Data.JsonFile }
            $detail = "$($dashResult.Data.RowCount) rows exported ($($dashResult.Data.Columns) columns)"

            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'DashboardExport' -Status 'Success' -Detail $detail `
                -Duration $stepDuration -Files $dashFiles
            Write-Host "    $detail ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green
        }
        else {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'DashboardExport' -Status 'Failed' `
                -Detail $dashResult.Error -Duration $stepDuration
            Write-Host "    WARN: Dashboard export failed: $($dashResult.Error)" -ForegroundColor Yellow
            if ($worstExitCode -lt 5) { $worstExitCode = 5 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'DashboardExport' -Status 'Failed' `
            -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "    WARN: Dashboard export failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Dashboard export failed: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceReport' -Action 'DashboardExport' -CorrelationID $correlationID
        if ($worstExitCode -lt 5) { $worstExitCode = 5 }
    }
    Write-Host ''
}

#endregion

#region Step 5: Leadership Rollup

if ($effectiveLeadershipRollup) {
    Write-Host '  Step 5: Leadership Rollup' -ForegroundColor Cyan
    $stepStart = Get-Date

    if (-not (Get-Command -Name Build-SPOrgTree -ErrorAction SilentlyContinue)) {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'LeadershipRollup' -Status 'Skipped' `
            -Detail 'SP.DeltaCert module not loaded (Build-SPOrgTree unavailable)' -Duration $stepDuration
        Write-Host '    WARN: SP.DeltaCert module not loaded -- cannot generate leadership rollup.' -ForegroundColor Yellow
    }
    else {
        try {
            $leadershipOutputPath = Join-Path $packagePath 'leadership'
            if (-not (Test-Path $leadershipOutputPath)) {
                $null = New-Item -ItemType Directory -Path $leadershipOutputPath -Force
            }

            # Collect all unique identity IDs from decisions
            $allIdentityIds = [System.Collections.Generic.List[string]]::new()
            foreach ($audit in $allCampaignAudits) {
                $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
                if ($null -eq $d) { continue }
                foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                    if (-not $d.ContainsKey($category) -or $null -eq $d[$category]) { continue }
                    foreach ($item in @($d[$category])) {
                        if ($null -ne $item.IdentityId -and -not [string]::IsNullOrWhiteSpace($item.IdentityId)) {
                            if (-not $allIdentityIds.Contains($item.IdentityId)) {
                                $allIdentityIds.Add($item.IdentityId)
                            }
                        }
                    }
                }
            }

            if ($allIdentityIds.Count -eq 0) {
                $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
                Set-StepResult -Step 'LeadershipRollup' -Status 'NoData' `
                    -Detail 'No identity IDs found in decisions' -Duration $stepDuration
                Write-Host '    No identity IDs found in decisions -- skipping.' -ForegroundColor Yellow
            }
            else {
                Write-Host "    Building org tree for $($allIdentityIds.Count) identit(ies) (depth=$LeadershipDepth)..." -ForegroundColor DarkGray
                $orgTreeResult = Build-SPOrgTree -IdentityIds $allIdentityIds.ToArray() `
                    -MaxDepth $LeadershipDepth -CorrelationID $correlationID

                if (-not $orgTreeResult.Success) {
                    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
                    Set-StepResult -Step 'LeadershipRollup' -Status 'Failed' `
                        -Detail "Org tree build failed: $($orgTreeResult.Error)" -Duration $stepDuration
                    Write-Host "    WARN: Org tree build failed: $($orgTreeResult.Error)" -ForegroundColor Yellow
                    if ($worstExitCode -lt 5) { $worstExitCode = 5 }
                }
                else {
                    $orgTree = $orgTreeResult.Data

                    # Merge decisions across all campaigns
                    $mergedDecisions = @{
                        Approved = [System.Collections.Generic.List[object]]::new()
                        Revoked  = [System.Collections.Generic.List[object]]::new()
                        Pending  = [System.Collections.Generic.List[object]]::new()
                    }
                    foreach ($audit in $allCampaignAudits) {
                        $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
                        if ($null -eq $d) { continue }
                        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                            if ($d.ContainsKey($category) -and $null -ne $d[$category]) {
                                foreach ($item in @($d[$category])) { $mergedDecisions[$category].Add($item) }
                            }
                        }
                    }
                    $mergedDecisionsHt = @{
                        Approved = $mergedDecisions['Approved'].ToArray()
                        Revoked  = $mergedDecisions['Revoked'].ToArray()
                        Pending  = $mergedDecisions['Pending'].ToArray()
                    }

                    # Merge reviewer metrics
                    $mergedReviewerMetrics = $null
                    $combinedMetrics = [System.Collections.Generic.List[object]]::new()
                    foreach ($audit in $allCampaignAudits) {
                        if ($audit.ContainsKey('ReviewerMetrics') -and $null -ne $audit['ReviewerMetrics'] -and
                            $null -ne $audit['ReviewerMetrics']['ReviewerMetrics']) {
                            foreach ($rm in @($audit['ReviewerMetrics']['ReviewerMetrics'])) {
                                $combinedMetrics.Add($rm)
                            }
                        }
                    }
                    if ($combinedMetrics.Count -gt 0) {
                        $mergedReviewerMetrics = @{ ReviewerMetrics = $combinedMetrics.ToArray() }
                    }

                    $groupParams = @{
                        Decisions = $mergedDecisionsHt
                        OrgTree   = $orgTree
                    }
                    if ($null -ne $mergedReviewerMetrics) { $groupParams['ReviewerMetrics'] = $mergedReviewerMetrics }
                    $leadershipData = Group-SPAuditByLeadership @groupParams

                    $leadershipCampaignName = if ($allCampaignAudits.Count -eq 1) {
                        $allCampaignAudits[0]['CampaignName']
                    }
                    else {
                        "$($allCampaignAudits.Count) Campaigns (Combined)"
                    }
                    $leadershipDateRange = ''
                    $allCreated = @($allCampaignAudits | ForEach-Object {
                        if ($_['Created']) { $_['Created'] }
                    } | Where-Object { $_ } | Sort-Object)
                    if ($allCreated.Count -gt 0) {
                        $startDate = ($allCreated[0] -split 'T')[0]
                        $endDate   = ((Get-Date).ToString('yyyy-MM-dd'))
                        $leadershipDateRange = "$startDate to $endDate"
                    }

                    # Generate executive summary
                    $execPath = Export-SPLeadershipExecutiveHtml `
                        -LeadershipData $leadershipData `
                        -CampaignName $leadershipCampaignName `
                        -DateRange $leadershipDateRange `
                        -OutputPath $leadershipOutputPath `
                        -CorrelationID $correlationID

                    # Generate per-level reports
                    $topLevel = $leadershipData.TopLevel
                    $resolvedStartLevel = $topLevel
                    $resolvedLowestLevel = 2
                    $leadershipFiles = [System.Collections.Generic.List[string]]::new()
                    $leadershipFiles.Add($execPath)

                    for ($lvl = $resolvedStartLevel; $lvl -ge $resolvedLowestLevel; $lvl--) {
                        if (-not $leadershipData.Levels.ContainsKey($lvl)) { continue }
                        $lvlPaths = Export-SPLeadershipLevelHtml `
                            -LeadershipData $leadershipData `
                            -Decisions $mergedDecisionsHt `
                            -OrgTree $orgTree `
                            -Level $lvl `
                            -StartLevel $resolvedStartLevel `
                            -LowestLevel $resolvedLowestLevel `
                            -CampaignName $leadershipCampaignName `
                            -DateRange $leadershipDateRange `
                            -OutputPath $leadershipOutputPath `
                            -CorrelationID $correlationID `
                            -DetailLevel $DetailLevel
                        foreach ($lp in @($lvlPaths)) { $leadershipFiles.Add($lp) }
                    }

                    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
                    Set-StepResult -Step 'LeadershipRollup' -Status 'Success' `
                        -Detail "$($leadershipFiles.Count) report(s) generated" -Duration $stepDuration `
                        -Files $leadershipFiles.ToArray()
                    Write-Host "    $($leadershipFiles.Count) leadership report(s) generated ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green
                }
            }
        }
        catch {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'LeadershipRollup' -Status 'Failed' `
                -Detail $_.Exception.Message -Duration $stepDuration
            Write-Host "    WARN: Leadership rollup failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Leadership rollup failed: $($_.Exception.Message)" `
                -Severity WARN -Component 'GovernanceReport' -Action 'LeadershipRollup' -CorrelationID $correlationID
            if ($worstExitCode -lt 5) { $worstExitCode = 5 }
        }
    }
    Write-Host ''
}

#endregion

#region Manifest

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# Collect all generated files
$allFiles = @()
foreach ($step in $stepResults.Keys) {
    if ($stepResults[$step]['Files'] -and $stepResults[$step]['Files'].Count -gt 0) {
        $allFiles += $stepResults[$step]['Files']
    }
}

$manifest = [ordered]@{
    ReportPackage   = $packageName
    GeneratedAt     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CorrelationID   = $correlationID
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    Duration        = $durationStr
    Environment     = if ($config.Global -and $config.Global.EnvironmentName) { $config.Global.EnvironmentName } else { 'unknown' }
    CampaignFilter  = [ordered]@{
        Status              = $Status
        DaysBack            = $effectiveDaysBack
        CampaignName        = $CampaignName
        CampaignNameStartsWith = $CampaignNameStartsWith
        CampaignNameContains   = $CampaignNameContains
    }
    CampaignsAudited = $allCampaignAudits.Count
    Sections         = [ordered]@{}
    TotalFiles       = $allFiles.Count
    ExitCode         = $worstExitCode
}

foreach ($step in $stepResults.Keys) {
    $manifest['Sections'][$step] = [ordered]@{
        Status   = $stepResults[$step]['Status']
        Detail   = $stepResults[$step]['Detail']
        Duration = $stepResults[$step]['Duration']
        Files    = $stepResults[$step]['Files'].Count
    }
}

# Write manifest
$manifestPath = Join-Path $packagePath 'manifest.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

# JSONL audit trail event
try {
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'GovernanceReport'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            CampaignsAudited = $allCampaignAudits.Count
            Sections         = @($stepResults.Keys | ForEach-Object { @{ Name = $_; Status = $stepResults[$_]['Status'] } })
            DurationSeconds  = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode         = $worstExitCode
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditFile = Join-Path $effectiveOutputPath 'governance-report-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
}

#endregion

#region Summary Output

$summaryObject = [PSCustomObject]@{
    CorrelationID    = $correlationID
    StartedAt        = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = [math]::Round($totalDuration.TotalSeconds, 2)
    Duration         = $durationStr
    CampaignsAudited = $allCampaignAudits.Count
    Sections         = $stepResults
    OutputPath       = $packagePath
    ManifestPath     = $manifestPath
    TotalFiles       = $allFiles.Count
    Environment      = if ($config.Global -and $config.Global.EnvironmentName) { $config.Global.EnvironmentName } else { 'unknown' }
    ExitCode         = $worstExitCode
}

switch ($OutputMode) {
    'JSON' {
        $summaryObject | ConvertTo-Json -Depth 10
    }
    'Console' {
        Write-Host '  === Governance Report Complete ===' -ForegroundColor Cyan
        Write-Host "  $('=' * 55)" -ForegroundColor DarkGray
        Write-Host ''
        foreach ($step in $stepResults.Keys) {
            $s = $stepResults[$step]
            $icon = switch ($s['Status']) {
                'Success' { 'PASS' }
                'Partial' { 'WARN' }
                'Failed'  { 'FAIL' }
                'Skipped' { 'SKIP' }
                'NoData'  { 'NONE' }
                default   { '----' }
            }
            $color = switch ($s['Status']) {
                'Success' { 'Green' }
                'Partial' { 'Yellow' }
                'Failed'  { 'Red' }
                'Skipped' { 'DarkGray' }
                'NoData'  { 'Yellow' }
                default   { 'Gray' }
            }
            $stepLabel = $step.PadRight(20)
            Write-Host "  [$icon] $stepLabel $($s['Detail'])" -ForegroundColor $color
        }
        Write-Host ''
        Write-Host "  Campaigns:     $($allCampaignAudits.Count)" -ForegroundColor Green
        Write-Host "  Output:        $packagePath" -ForegroundColor DarkGray
        Write-Host "  Manifest:      $manifestPath" -ForegroundColor DarkGray
        Write-Host "  Total files:   $($allFiles.Count)" -ForegroundColor DarkGray
        Write-Host "  Duration:      $durationStr" -ForegroundColor DarkGray
        Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
        Write-Host ''
    }
    'Both' {
        Write-Host '  === Governance Report Complete ===' -ForegroundColor Cyan
        Write-Host "  $('=' * 55)" -ForegroundColor DarkGray
        Write-Host ''
        foreach ($step in $stepResults.Keys) {
            $s = $stepResults[$step]
            $icon = switch ($s['Status']) {
                'Success' { 'PASS' }
                'Partial' { 'WARN' }
                'Failed'  { 'FAIL' }
                'Skipped' { 'SKIP' }
                'NoData'  { 'NONE' }
                default   { '----' }
            }
            $color = switch ($s['Status']) {
                'Success' { 'Green' }
                'Partial' { 'Yellow' }
                'Failed'  { 'Red' }
                'Skipped' { 'DarkGray' }
                'NoData'  { 'Yellow' }
                default   { 'Gray' }
            }
            $stepLabel = $step.PadRight(20)
            Write-Host "  [$icon] $stepLabel $($s['Detail'])" -ForegroundColor $color
        }
        Write-Host ''
        Write-Host "  Campaigns:     $($allCampaignAudits.Count)" -ForegroundColor Green
        Write-Host "  Output:        $packagePath" -ForegroundColor DarkGray
        Write-Host "  Manifest:      $manifestPath" -ForegroundColor DarkGray
        Write-Host "  Total files:   $($allFiles.Count)" -ForegroundColor DarkGray
        Write-Host "  Duration:      $durationStr" -ForegroundColor DarkGray
        Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  JSON Output:' -ForegroundColor Cyan
        $summaryObject | ConvertTo-Json -Depth 10
    }
}

Write-SPLog -Message "Invoke-SPGovernanceReport completed: $($allCampaignAudits.Count) campaign(s), ExitCode=$worstExitCode, Duration=$durationStr" `
    -Severity INFO -Component 'GovernanceReport' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $worstExitCode
