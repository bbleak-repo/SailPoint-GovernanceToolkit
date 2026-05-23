#Requires -Version 5.1
<#
.SYNOPSIS
    Generates post-campaign audit reports for SailPoint ISC certification campaigns.
.DESCRIPTION
    Queries completed or active certification campaigns from SailPoint ISC, retrieves all
    certifications and review items, collects decision outcomes and reviewer actions, fetches
    identity lifecycle events for revoked identities, and produces per-campaign HTML/text
    reports plus a combined summary and a JSONL audit trail.

    Campaign selection requires at least one filter: -CampaignName, -CampaignNameStartsWith,
    -CampaignNameContains, or -Status. Without a filter the script exits with code 2.

    Reports are written to the path specified by -OutputPath or Audit.OutputPath in
    settings.json (default: .\Audit relative to the toolkit root).
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the Scripts
    directory.
.PARAMETER CampaignName
    Filter campaigns by exact name match (case-insensitive).
.PARAMETER CampaignNameStartsWith
    Filter campaigns whose name begins with the specified prefix (case-insensitive).
.PARAMETER CampaignNameContains
    Filter campaigns whose name contains the specified keyword anywhere (case-insensitive).
    Uses the ISC 'co' (contains) filter operator. Recommended for fuzzy/substring searching.
.PARAMETER Status
    Filter campaigns by one or more status values. Valid values: STAGED, ACTIVE,
    COMPLETING, COMPLETED. Defaults to the Audit.DefaultStatuses list in settings.json
    when no other filter is provided.
.PARAMETER DaysBack
    Only include campaigns created within the last N days. Default: 30. Uses the
    Audit.DefaultDaysBack value from settings.json when not specified explicitly.
.PARAMETER IdentityEventDays
    Number of days before the campaign end date to search for identity lifecycle events
    for revoked identities. Default: 2.
.PARAMETER CampaignReportCsvPath
    Path to a locally exported campaign report CSV file. When provided, skips the live
    campaign-report API calls and reads decision data from this file instead.
.PARAMETER OutputPath
    Directory to write audit output files. Overrides Audit.OutputPath in settings.json.
    The directory will be created if it does not exist.
.PARAMETER OutputMode
    Output destination for console summary. Console (default) writes a formatted summary
    to the terminal. JSON writes a machine-parseable result object. Both writes console
    output followed by the JSON object.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    When provided, bypasses OAuth client_credentials authentication entirely.
    Obtain by: F12 dev tools > Network tab > copy Authorization header value.
    The "Bearer " prefix is stripped automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
    ISC browser tokens are typically valid for ~12 minutes (720 seconds).
.PARAMETER IncludeLeadershipRollup
    When specified, generates leadership rollup reports in addition to the standard
    campaign audit reports. Walks the ISC org tree (identity -> manager -> director ->
    VP) and produces per-leader HTML reports showing what their org accomplished.
    Output is written to a 'leadership' subdirectory under the main output path.
    Requires SP.DeltaCert module (for Build-SPOrgTree).
.PARAMETER LeadershipDepth
    Maximum number of levels to walk above the reviewed identities when building
    the org tree. Default: 3 (identity -> manager -> director -> VP). Use 2 for
    manager + director only (no VP-level executive summary).
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 7
    # Audit all campaigns that completed in the last 7 days.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -CampaignName 'Q1 2026 Access Review'
    # Audit a specific campaign by exact name.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -CampaignNameStartsWith 'Q1' -Status COMPLETED -OutputMode Both
    # Audit all Q1 completed campaigns, write console and JSON output.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -CampaignNameContains 'test' -DaysBack 90
    # Find all campaigns with 'test' anywhere in the name from the last 90 days.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Token 'eyJhbGciOiJSUzI1...' -Status COMPLETED -DaysBack 7
    # Use a browser token instead of OAuth credentials.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -CampaignName 'Annual Review' -CampaignReportCsvPath 'C:\Reports\annual.csv'
    # Use a locally exported CSV instead of calling the campaign report API.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -OutputPath 'D:\AuditReports'
    # Write output to a custom directory.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30 -IncludeLeadershipRollup
    # Generate audit reports plus leadership rollup (executive + director HTML).
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -IncludeLeadershipRollup -LeadershipDepth 2
    # Leadership rollup with 2 levels (manager + director only, no VP summary).
.NOTES
    Script:  Invoke-SPCampaignAudit.ps1
    Version: 1.0.0
    Exit codes:
        0 = Audit completed successfully
        1 = No campaigns matched the filter criteria
        2 = Parameter error (missing required filter or invalid parameter combination)
        3 = Authentication error (failed to acquire token)
        4 = Configuration error (settings.json missing, invalid, or first-run placeholders)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

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
    [int]$DaysBack = 30,

    [Parameter()]
    [int]$IdentityEventDays = 2,

    [Parameter()]
    [string]$CampaignReportCsvPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [switch]$IncludeLeadershipRollup,

    [Parameter()]
    [int]$LeadershipDepth = 3,

    [Parameter()]
    [Alias('?')]
    [switch]$Help
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

$coreModulePath      = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath       = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$auditModulePath     = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'
$deltaCertModulePath = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;      Name = 'SP.Core';      Required = $true },
    @{ Path = $apiModulePath;       Name = 'SP.Api';       Required = $true },
    @{ Path = $auditModulePath;     Name = 'SP.Audit';     Required = $true },
    @{ Path = $deltaCertModulePath; Name = 'SP.DeltaCert'; Required = $false }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop
    }
    else {
        # Attempt to load nested modules directly if psd1 not yet created
        $moduleDir  = Split-Path -Parent $moduleDef.Path
        $psm1Files  = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Validate that at least one campaign filter is specified
$hasFilter = $CampaignName -or $CampaignNameStartsWith -or $CampaignNameContains -or $Status
if (-not $hasFilter) {
    Write-Host "ERROR: At least one campaign filter is required: -CampaignName, -CampaignNameStartsWith, -CampaignNameContains, or -Status." -ForegroundColor Red
    Write-Host "       Example: .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30" -ForegroundColor Yellow
    exit 2
}

# Resolve config path (honors settings.local.json override)
if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

# Initialize logging (best-effort before config is loaded)
try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Campaign Audit Report' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
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

# Re-initialize logging with the loaded config
try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
}
catch { }

# Inject browser token if provided (bypasses OAuth client_credentials)
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

Write-SPLog -Message "Invoke-SPCampaignAudit started" `
    -Severity INFO -Component 'Invoke-SPCampaignAudit' -Action 'Start' -CorrelationID $correlationID

# Resolve output path: explicit parameter takes precedence over config
if (-not $OutputPath) {
    if ($config.Audit -and $config.Audit.OutputPath) {
        $OutputPath = $config.Audit.OutputPath
    }
    else {
        $OutputPath = '.\Audit'
    }
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = [System.IO.Path]::GetFullPath(
        (Join-Path $toolkitRoot $OutputPath.TrimStart('.\').TrimStart('./'))
    )
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# Apply config defaults for DaysBack when not explicitly provided
# (parameter default 30 covers the case where config has no Audit section)
$effectiveDaysBack = $DaysBack
if ($config.Audit -and $config.Audit.DefaultDaysBack -and $DaysBack -eq 30) {
    $effectiveDaysBack = [int]$config.Audit.DefaultDaysBack
}

$effectiveIdentityEventDays = $IdentityEventDays
if ($config.Audit -and $config.Audit.DefaultIdentityEventDays -and $IdentityEventDays -eq 2) {
    $effectiveIdentityEventDays = [int]$config.Audit.DefaultIdentityEventDays
}

# Apply config default for leadership rollup when not explicitly provided via switch
$effectiveLeadershipRollup = $IncludeLeadershipRollup
if (-not $IncludeLeadershipRollup -and $config.Audit -and
    $config.Audit.PSObject.Properties.Name -contains 'IncludeLeadershipRollup' -and
    $config.Audit.IncludeLeadershipRollup -eq $true) {
    $effectiveLeadershipRollup = $true
}

$effectiveLeadershipDepth = $LeadershipDepth
if ($config.Audit -and $config.Audit.PSObject.Properties.Name -contains 'LeadershipDepth' -and
    $LeadershipDepth -eq 3) {
    $effectiveLeadershipDepth = [int]$config.Audit.LeadershipDepth
}

#endregion

#region Dispatch

$runStart = Get-Date

# -WhatIf short-circuit: validate config + filters, describe what would be
# queried, and exit without any API calls. Useful for smoke-checking a new
# config or CI pipeline before it has OAuth credentials.
if (($WhatIfPreference -eq $true)) {
    Write-Host ''
    Write-Host '  [WhatIf] Dry-run mode enabled. No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Would query campaigns with the following filters:" -ForegroundColor Cyan
    Write-Host "    DaysBack:            $effectiveDaysBack"
    if ($Status)                 { Write-Host "    Status:              $($Status -join ', ')" }
    if ($CampaignName)           { Write-Host "    CampaignName:        $CampaignName" }
    if ($CampaignNameStartsWith) { Write-Host "    CampaignNameStartsWith: $CampaignNameStartsWith" }
    if ($CampaignNameContains)   { Write-Host "    CampaignNameContains: $CampaignNameContains" }
    if ($CampaignReportCsvPath)  { Write-Host "    CampaignReportCsvPath: $CampaignReportCsvPath (local, no API)" }
    if ($IncludeLeadershipRollup) {
        Write-Host "    IncludeLeadershipRollup: Yes" -ForegroundColor Cyan
        Write-Host "    LeadershipDepth:     $LeadershipDepth"
    }
    Write-Host ''
    Write-Host "  Would write output to: $OutputPath" -ForegroundColor Cyan
    Write-Host "  CorrelationID:         $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [WhatIf] Validation complete. Re-run without -WhatIf to execute the audit.' -ForegroundColor Yellow
    Write-SPLog -Message "Audit skipped: -WhatIf" -Severity INFO `
        -Component 'Invoke-SPCampaignAudit' -Action 'WhatIfSkip' -CorrelationID $correlationID
    exit 0
}

Write-Host "  Querying campaigns (DaysBack=$effectiveDaysBack)..." -ForegroundColor Cyan

# Build filter parameters for Get-SPAuditCampaigns
$auditCampaignParams = @{
    DaysBack      = $effectiveDaysBack
    CorrelationID = $correlationID
}

if ($CampaignName) {
    $auditCampaignParams['CampaignName'] = $CampaignName
}
if ($CampaignNameStartsWith) {
    $auditCampaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith
}
if ($CampaignNameContains) {
    $auditCampaignParams['CampaignNameContains'] = $CampaignNameContains
}
if ($Status) {
    $auditCampaignParams['Status'] = $Status
}

$campaignsResult = Get-SPAuditCampaigns @auditCampaignParams

if (-not $campaignsResult.Success) {
    Write-Host "ERROR: Failed to retrieve campaigns: $($campaignsResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Failed to retrieve campaigns: $($campaignsResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPCampaignAudit' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 3
}

$campaigns = $campaignsResult.Data

if (-not $campaigns -or $campaigns.Count -eq 0) {
    Write-Host "  No campaigns matched the specified filter criteria." -ForegroundColor Yellow
    Write-SPLog -Message "No campaigns matched filter criteria" `
        -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 1
}

Write-Host "  Found $($campaigns.Count) campaign(s)." -ForegroundColor Green
Write-Host ''

# Per-campaign audit data collection
$allCampaignAudits = [System.Collections.Generic.List[object]]::new()

foreach ($campaign in $campaigns) {
    $campId   = $campaign.id
    $campName = $campaign.name

    Write-Host "  Processing: $campName ($campId)" -ForegroundColor Cyan

    # --- Certifications ---
    Write-Host "    Getting certifications..." -ForegroundColor DarkGray
    $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
    $certifications = @()
    if ($certResult.Success) {
        $certifications = @($certResult.Data)
    }
    else {
        Write-Host "    WARN: Could not retrieve certifications: $($certResult.Error)" -ForegroundColor Yellow
        Write-SPLog -Message "Could not retrieve certifications for campaign ${campId}: $($certResult.Error)" `
            -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetCertifications' -CorrelationID $correlationID
    }

    # --- Certification items (wrapped with context for categorization functions) ---
    $wrappedAllItems = [System.Collections.Generic.List[object]]::new()
    $allItems        = [System.Collections.Generic.List[object]]::new()
    foreach ($cert in $certifications) {
        $certName   = if ($null -ne $cert.name) { $cert.name } else { '' }
        $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $correlationID
        if ($itemResult.Success -and $null -ne $itemResult.Data) {
            foreach ($rawItem in $itemResult.Data) {
                $allItems.Add($rawItem)
                $wrappedAllItems.Add(@{
                    Item              = $rawItem
                    CertificationId   = $cert.id
                    CertificationName = $certName
                    CampaignName      = $campName
                })
            }
        }
        else {
            Write-Host "    WARN: Could not retrieve items for certification $($cert.id): $($itemResult.Error)" -ForegroundColor Yellow
        }
    }
    Write-Host "    Collected $($allItems.Count) review items across $($certifications.Count) certification(s)." -ForegroundColor DarkGray

    # --- Campaign report (CSV) ---
    $campaignReportRows = $null
    if ($CampaignReportCsvPath) {
        Write-Host "    Importing campaign report from CSV: $CampaignReportCsvPath" -ForegroundColor DarkGray
        $csvResult = Import-SPAuditCampaignReport -CsvDirectoryPath $CampaignReportCsvPath -CorrelationID $correlationID
        if ($csvResult.Success) {
            # Convert from {StatusReport=; SignOffReport=} to {CAMPAIGN_STATUS_REPORT=; CERTIFICATION_SIGNOFF_REPORT=}
            $campaignReportRows = @{}
            if ($null -ne $csvResult.Data.StatusReport) {
                $campaignReportRows['CAMPAIGN_STATUS_REPORT'] = @($csvResult.Data.StatusReport)
            }
            if ($null -ne $csvResult.Data.SignOffReport) {
                $campaignReportRows['CERTIFICATION_SIGNOFF_REPORT'] = @($csvResult.Data.SignOffReport)
            }
            if ($campaignReportRows.Count -eq 0) { $campaignReportRows = $null }
        }
        else {
            Write-Host "    WARN: Could not import campaign report CSV: $($csvResult.Error)" -ForegroundColor Yellow
        }
    }
    elseif ($config.Audit -and $config.Audit.IncludeCampaignReports -ne $false) {
        Write-Host "    Fetching campaign reports from API..." -ForegroundColor DarkGray
        $campaignReportRows = @{}
        foreach ($reportType in @('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')) {
            $reportResult = Get-SPAuditCampaignReport -CampaignId $campId -ReportType $reportType `
                -CorrelationID $correlationID
            if ($reportResult.Success) {
                $campaignReportRows[$reportType] = @($reportResult.Data)
            }
            else {
                Write-Host "    WARN: $reportType unavailable: $($reportResult.Error)" -ForegroundColor Yellow
                Write-SPLog -Message "Campaign report '$reportType' unavailable for ${campId}: $($reportResult.Error)" `
                    -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetCampaignReport' -CorrelationID $correlationID
            }
        }
        if ($campaignReportRows.Count -eq 0) { $campaignReportRows = $null }
    }

    # --- Collect revoked identity IDs (from raw items using identitySummary, matching GUI bridge pattern) ---
    $revokedIdentityIds = @(
        $allItems | ForEach-Object {
            if ($null -ne $_.decision -and $_.decision -eq 'REVOKE' -and
                $null -ne $_.identitySummary -and $null -ne $_.identitySummary.id) {
                $_.identitySummary.id
            }
        } | Where-Object { $_ } | Sort-Object -Unique
    )

    # --- Identity lifecycle events (per-identity loop, matching GUI bridge pattern) ---
    $identityEvents = @()
    if ($revokedIdentityIds.Count -gt 0 -and ($config.Audit -and $config.Audit.IncludeIdentityEvents -ne $false)) {
        Write-Host "    Fetching identity events for $($revokedIdentityIds.Count) revoked identit(ies)..." -ForegroundColor DarkGray
        foreach ($identityId in $revokedIdentityIds) {
            $eventResult = Get-SPAuditIdentityEvents `
                -IdentityId $identityId `
                -DaysBack $effectiveIdentityEventDays `
                -CorrelationID $correlationID

            if ($eventResult.Success -and $null -ne $eventResult.Data) {
                foreach ($evt in $eventResult.Data) {
                    $identityEvents += $evt
                }
            }
            else {
                Write-Host "    WARN: Could not retrieve identity events for ${identityId}: $($eventResult.Error)" -ForegroundColor Yellow
                Write-SPLog -Message "Could not retrieve identity events for identity '${identityId}': $($eventResult.Error)" `
                    -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetIdentityEvents' -CorrelationID $correlationID
            }
        }
    }

    # --- Resolve identity accounts for UPN/sAMAccountName ---
    $uniqueIdentityIds = @($wrappedAllItems | ForEach-Object {
        $item = $_.Item
        $iid = if ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.identityId) { $item.identitySummary.identityId }
               elseif ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) { $item.identitySummary.id }
               else { $null }
        $iid
    } | Where-Object { $_ } | Sort-Object -Unique)

    $accountMap = @{}
    if ($uniqueIdentityIds.Count -gt 0) {
        Write-Host "    Resolving account attributes for $($uniqueIdentityIds.Count) unique identit(ies)..." -ForegroundColor DarkGray
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $uniqueIdentityIds -CorrelationID $correlationID
        if ($acctResult.Success) {
            $accountMap = $acctResult.Data
        }
        else {
            Write-Host "    WARN: Account resolution failed (non-fatal): $($acctResult.Error)" -ForegroundColor Yellow
            Write-SPLog -Message "Account resolution failed for campaign ${campId}: $($acctResult.Error)" `
                -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'ResolveAccounts' -CorrelationID $correlationID
        }
    }

    # --- Categorize decisions and actions ---
    $decisionGroups   = Group-SPAuditDecisions         -Items $wrappedAllItems.ToArray() -AccountMap $accountMap
    $reviewerActions  = Group-SPReviewerActions        -Certifications $certifications
    $reviewerMetrics  = Measure-SPAuditReviewerMetrics -Certifications $certifications
    $eventGroups      = Group-SPAuditIdentityEvents    -Events $identityEvents
    $remediationProof = Group-SPAuditRemediationProof  -Items $wrappedAllItems.ToArray() -Certifications $certifications -AccountMap $accountMap

    # --- Build per-campaign audit data (hashtable, keys match Build-SingleCampaignHtml) ---
    $campaignAudit = @{
        CampaignName             = $campName
        CampaignId               = $campId
        Status                   = if ($null -ne $campaign.status)              { [string]$campaign.status }              else { '' }
        Created                  = if ($null -ne $campaign.created)             { [string]$campaign.created }             else { '' }
        Completed                = if ($null -ne $campaign.completed)           { [string]$campaign.completed }           else { '' }
        Deadline                 = if ($null -ne $campaign.deadline)            { [string]$campaign.deadline }
                                   elseif ($null -ne $campaign.due)             { [string]$campaign.due }                 else { '' }
        TotalCertifications      = if ($null -ne $campaign.totalCertifications) { [int]$campaign.totalCertifications }    else { 0 }
        Decisions                = $decisionGroups
        Reviewers                = $reviewerActions
        ReviewerMetrics          = $reviewerMetrics
        Events                   = $eventGroups
        RemediationProof         = $remediationProof
        CampaignReports          = $campaignReportRows
        CampaignReportsAvailable = ($null -ne $campaignReportRows)
    }
    $allCampaignAudits.Add($campaignAudit)

    # --- Per-campaign output ---
    $safeFileName = ($campName -replace '[\\/:*?"<>|]', '_').TrimEnd('.')
    $campOutputDir = Join-Path $OutputPath $safeFileName
    if (-not (Test-Path $campOutputDir)) {
        $null = New-Item -ItemType Directory -Path $campOutputDir -Force
    }

    Write-Host "    Generating reports..." -ForegroundColor DarkGray

    # HTML report
    Export-SPAuditHtml `
        -CampaignAudits @($campaignAudit) `
        -OutputPath $campOutputDir `
        -CorrelationID $correlationID

    # Text summary
    Export-SPAuditText `
        -CampaignAudits @($campaignAudit) `
        -OutputPath $campOutputDir `
        -CorrelationID $correlationID

    Write-Host "    Done. Output: $campOutputDir" -ForegroundColor Green
}

# --- Combined HTML report ---
Write-Host ''
Write-Host '  Generating combined audit report...' -ForegroundColor Cyan

Export-SPAuditHtml `
    -CampaignAudits $allCampaignAudits.ToArray() `
    -OutputPath $OutputPath `
    -Combined `
    -CorrelationID $correlationID

# --- JSONL audit trail ---
$jsonlEvents = foreach ($audit in $allCampaignAudits) {
    $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
    @{
        Action           = 'CampaignAudited'
        CampaignId       = $audit['CampaignId']
        CampaignName     = $audit['CampaignName']
        DecisionsApproved = if ($null -ne $d -and $null -ne $d['Approved']) { @($d['Approved']).Count } else { 0 }
        DecisionsRevoked  = if ($null -ne $d -and $null -ne $d['Revoked'])  { @($d['Revoked']).Count  } else { 0 }
        DecisionsPending  = if ($null -ne $d -and $null -ne $d['Pending'])  { @($d['Pending']).Count  } else { 0 }
    }
}
Export-SPAuditJsonl `
    -Events @($jsonlEvents) `
    -OutputPath $OutputPath `
    -CorrelationID $correlationID

# --- Leadership rollup reports (supplementary) ---
if ($effectiveLeadershipRollup) {
    $leadershipOutputPath = Join-Path $OutputPath 'leadership'
    if (-not (Test-Path $leadershipOutputPath)) {
        $null = New-Item -ItemType Directory -Path $leadershipOutputPath -Force
    }

    # Verify Build-SPOrgTree is available (SP.DeltaCert module required)
    if (-not (Get-Command -Name Build-SPOrgTree -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host '  WARN: SP.DeltaCert module not loaded -- cannot generate leadership rollup.' -ForegroundColor Yellow
        Write-Host '        Ensure SP.DeltaCert module is available in the Modules directory.' -ForegroundColor Yellow
        Write-SPLog -Message "Leadership rollup skipped: Build-SPOrgTree not available (SP.DeltaCert not loaded)" `
            -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'LeadershipRollup' -CorrelationID $correlationID
    }
    else {
        Write-Host ''
        Write-Host '  Generating leadership rollup reports...' -ForegroundColor Cyan

        # Collect all unique identity IDs from all campaigns
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
            Write-Host '    No identity IDs found in decisions -- skipping leadership rollup.' -ForegroundColor Yellow
            Write-SPLog -Message "Leadership rollup skipped: no identity IDs in decisions" `
                -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'LeadershipRollup' -CorrelationID $correlationID
        }
        else {
            Write-Host "    Building org tree for $($allIdentityIds.Count) unique identit(ies) (depth=$effectiveLeadershipDepth)..." -ForegroundColor DarkGray
            $orgTreeResult = Build-SPOrgTree -IdentityIds $allIdentityIds.ToArray() -MaxDepth $effectiveLeadershipDepth -CorrelationID $correlationID

            if (-not $orgTreeResult.Success) {
                Write-Host "    WARN: Org tree build failed: $($orgTreeResult.Error)" -ForegroundColor Yellow
                Write-SPLog -Message "Leadership rollup: org tree build failed: $($orgTreeResult.Error)" `
                    -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'LeadershipRollup' -CorrelationID $correlationID
            }
            else {
                $orgTree = $orgTreeResult.Data
                Write-Host "    Org tree: $($orgTree.LeafCount) leaves, $(@($orgTree.Managers).Count) managers, $(@($orgTree.Directors).Count) directors, $(@($orgTree.TopLeaders).Count) top leader(s)" -ForegroundColor DarkGray

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
                            foreach ($item in @($d[$category])) {
                                $mergedDecisions[$category].Add($item)
                            }
                        }
                    }
                }
                # Convert lists to arrays for Group-SPAuditByLeadership
                $mergedDecisionsHt = @{
                    Approved = $mergedDecisions['Approved'].ToArray()
                    Revoked  = $mergedDecisions['Revoked'].ToArray()
                    Pending  = $mergedDecisions['Pending'].ToArray()
                }

                # Merge reviewer metrics across all campaigns
                $mergedReviewerMetrics = $null
                if ($allCampaignAudits.Count -eq 1 -and $allCampaignAudits[0].ContainsKey('ReviewerMetrics')) {
                    $mergedReviewerMetrics = $allCampaignAudits[0]['ReviewerMetrics']
                }
                elseif ($allCampaignAudits.Count -gt 1) {
                    # For multi-campaign, combine ReviewerMetrics arrays
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
                }

                Write-Host '    Grouping decisions by leadership level...' -ForegroundColor DarkGray
                $groupParams = @{
                    Decisions = $mergedDecisionsHt
                    OrgTree   = $orgTree
                }
                if ($null -ne $mergedReviewerMetrics) {
                    $groupParams['ReviewerMetrics'] = $mergedReviewerMetrics
                }
                $leadershipData = Group-SPAuditByLeadership @groupParams

                # Build campaign name and date range for report headers
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
                Write-Host '    Generating executive summary...' -ForegroundColor DarkGray
                $execPath = Export-SPLeadershipExecutiveHtml `
                    -LeadershipData $leadershipData `
                    -CampaignName $leadershipCampaignName `
                    -DateRange $leadershipDateRange `
                    -OutputPath $leadershipOutputPath `
                    -CorrelationID $correlationID
                Write-Host "    Executive summary: $execPath" -ForegroundColor Green

                # Generate per-director reports
                $directorCount = @($leadershipData.Directors.Keys | Where-Object { $_ -ne '__unmanaged__' }).Count
                if ($directorCount -gt 0) {
                    Write-Host "    Generating $directorCount director report(s)..." -ForegroundColor DarkGray
                    $dirPaths = Export-SPLeadershipDirectorHtml `
                        -LeadershipData $leadershipData `
                        -Decisions $mergedDecisionsHt `
                        -OrgTree $orgTree `
                        -CampaignName $leadershipCampaignName `
                        -DateRange $leadershipDateRange `
                        -OutputPath $leadershipOutputPath `
                        -CorrelationID $correlationID
                    foreach ($dp in @($dirPaths)) {
                        Write-Host "    Director report: $dp" -ForegroundColor Green
                    }
                }

                Write-Host "    Leadership rollup complete. Output: $leadershipOutputPath" -ForegroundColor Green
                Write-SPLog -Message "Leadership rollup generated: exec summary + $directorCount director report(s)" `
                    -Severity INFO -Component 'Invoke-SPCampaignAudit' -Action 'LeadershipRollup' -CorrelationID $correlationID
            }
        }
    }
}

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

$summary = [PSCustomObject]@{
    CorrelationID         = $correlationID
    StartedAt             = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt           = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds       = [math]::Round($runDuration, 2)
    CampaignsAudited      = $allCampaignAudits.Count
    LeadershipRollup      = $effectiveLeadershipRollup
    OutputPath            = $OutputPath
    Environment           = $config.Global.EnvironmentName
}

#endregion

#region Output

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    'Console' {
        Write-Host ''
        Write-Host '  Audit Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Campaigns audited: $($summary.CampaignsAudited)" -ForegroundColor Green
        Write-Host "  Duration:          $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Output path:       $($summary.OutputPath)" -ForegroundColor DarkGray
        Write-Host "  Environment:       $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $correlationID" -ForegroundColor DarkGray
        Write-Host ''
    }
    'Both' {
        Write-Host ''
        Write-Host '  Audit Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Campaigns audited: $($summary.CampaignsAudited)" -ForegroundColor Green
        Write-Host "  Duration:          $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Output path:       $($summary.OutputPath)" -ForegroundColor DarkGray
        Write-Host "  Environment:       $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $correlationID" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  JSON Output:' -ForegroundColor Cyan
        $summary | ConvertTo-Json -Depth 10
    }
}

Write-SPLog -Message "Invoke-SPCampaignAudit completed: $($summary.CampaignsAudited) campaign(s) audited" `
    -Severity INFO -Component 'Invoke-SPCampaignAudit' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
