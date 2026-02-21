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
    or -Status. Without a filter the script exits with code 2.

    Reports are written to the path specified by -OutputPath or Audit.OutputPath in
    settings.json (default: .\Audit relative to the toolkit root).
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the Scripts
    directory.
.PARAMETER CampaignName
    Filter campaigns by exact name match (case-insensitive).
.PARAMETER CampaignNameStartsWith
    Filter campaigns whose name begins with the specified prefix (case-insensitive).
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
    .\Invoke-SPCampaignAudit.ps1 -CampaignName 'Annual Review' -CampaignReportCsvPath 'C:\Reports\annual.csv'
    # Use a locally exported CSV instead of calling the campaign report API.
.EXAMPLE
    .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -OutputPath 'D:\AuditReports'
    # Write output to a custom directory.
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
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

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

$coreModulePath  = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath   = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$auditModulePath = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;  Name = 'SP.Core';  Required = $true },
    @{ Path = $apiModulePath;   Name = 'SP.Api';   Required = $true },
    @{ Path = $auditModulePath; Name = 'SP.Audit'; Required = $true }
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
$hasFilter = $CampaignName -or $CampaignNameStartsWith -or $Status
if (-not $hasFilter) {
    Write-Host "ERROR: At least one campaign filter is required: -CampaignName, -CampaignNameStartsWith, or -Status." -ForegroundColor Red
    Write-Host "       Example: .\Invoke-SPCampaignAudit.ps1 -Status COMPLETED -DaysBack 30" -ForegroundColor Yellow
    exit 2
}

# Resolve config path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $toolkitRoot 'Config\settings.json'
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

#endregion

#region Dispatch

$runStart = Get-Date

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

    # --- Certification items ---
    $allItems = [System.Collections.Generic.List[object]]::new()
    foreach ($cert in $certifications) {
        $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $correlationID
        if ($itemResult.Success) {
            foreach ($item in $itemResult.Data) {
                $allItems.Add($item)
            }
        }
        else {
            Write-Host "    WARN: Could not retrieve items for certification $($cert.id): $($itemResult.Error)" -ForegroundColor Yellow
        }
    }
    Write-Host "    Collected $($allItems.Count) review items across $($certifications.Count) certification(s)." -ForegroundColor DarkGray

    # --- Campaign report (CSV) ---
    $campaignReportRows = @()
    if ($CampaignReportCsvPath) {
        Write-Host "    Importing campaign report from CSV: $CampaignReportCsvPath" -ForegroundColor DarkGray
        $csvResult = Import-SPAuditCampaignReport -CsvPath $CampaignReportCsvPath -CorrelationID $correlationID
        if ($csvResult.Success) {
            $campaignReportRows = @($csvResult.Data)
        }
        else {
            Write-Host "    WARN: Could not import campaign report CSV: $($csvResult.Error)" -ForegroundColor Yellow
        }
    }
    elseif ($config.Audit -and $config.Audit.IncludeCampaignReports -ne $false) {
        Write-Host "    Fetching campaign reports from API..." -ForegroundColor DarkGray
        $reportResult = Get-SPAuditCampaignReport -CampaignId $campId -CorrelationID $correlationID
        if ($reportResult.Success) {
            $campaignReportRows = @($reportResult.Data)
        }
        else {
            Write-Host "    WARN: Campaign report API unavailable: $($reportResult.Error)" -ForegroundColor Yellow
            Write-SPLog -Message "Campaign report API unavailable for ${campId}: $($reportResult.Error)" `
                -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetCampaignReport' -CorrelationID $correlationID
        }
    }

    # --- Collect revoked identity IDs ---
    $revokedIdentityIds = @(
        $allItems |
            Where-Object { $_.decision -eq 'REVOKE' } |
            ForEach-Object { $_.accessSummary.identity.id } |
            Where-Object { $_ }
    )
    $revokedIdentityIds = @($revokedIdentityIds | Sort-Object -Unique)

    # --- Identity lifecycle events ---
    $identityEvents = @()
    if ($revokedIdentityIds.Count -gt 0 -and ($config.Audit -and $config.Audit.IncludeIdentityEvents -ne $false)) {
        Write-Host "    Fetching identity events for $($revokedIdentityIds.Count) revoked identit(ies)..." -ForegroundColor DarkGray
        $eventResult = Get-SPAuditIdentityEvents `
            -IdentityIds $revokedIdentityIds `
            -DaysBack $effectiveIdentityEventDays `
            -CorrelationID $correlationID

        if ($eventResult.Success) {
            $identityEvents = @($eventResult.Data)
        }
        else {
            Write-Host "    WARN: Could not retrieve identity events: $($eventResult.Error)" -ForegroundColor Yellow
            Write-SPLog -Message "Could not retrieve identity events for campaign ${campId}: $($eventResult.Error)" `
                -Severity WARN -Component 'Invoke-SPCampaignAudit' -Action 'GetIdentityEvents' -CorrelationID $correlationID
        }
    }

    # --- Categorize decisions and actions ---
    $decisionGroups  = Group-SPAuditDecisions -Items $allItems.ToArray()
    $reviewerActions = Group-SPReviewerActions -Certifications $certifications
    $eventGroups     = Group-SPAuditIdentityEvents -Events $identityEvents

    # --- Build per-campaign audit data ---
    $campaignAudit = [PSCustomObject]@{
        CorrelationID    = $correlationID
        Campaign         = $campaign
        Certifications   = $certifications
        Items            = $allItems.ToArray()
        CampaignReport   = $campaignReportRows
        DecisionGroups   = $decisionGroups
        ReviewerActions  = $reviewerActions
        EventGroups      = $eventGroups
        RevokedCount     = $revokedIdentityIds.Count
        AuditedAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
        -CampaignAudit $campaignAudit `
        -OutputPath $campOutputDir `
        -CorrelationID $correlationID

    # Text summary
    Export-SPAuditText `
        -CampaignAudit $campaignAudit `
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
Export-SPAuditJsonl `
    -CampaignAudits $allCampaignAudits.ToArray() `
    -OutputPath $OutputPath `
    -CorrelationID $correlationID

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

$summary = [PSCustomObject]@{
    CorrelationID    = $correlationID
    StartedAt        = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = [math]::Round($runDuration, 2)
    CampaignsAudited = $allCampaignAudits.Count
    OutputPath       = $OutputPath
    Environment      = $config.Global.EnvironmentName
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
