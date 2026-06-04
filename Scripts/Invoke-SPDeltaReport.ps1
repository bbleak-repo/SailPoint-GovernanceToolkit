#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a daily delta certification report showing what changed since the last run.
.DESCRIPTION
    Queries SailPoint ISC for account-activity events (grants and revocations),
    recently created delta cert campaigns, pending certifications, and anomalies
    within a configurable time window. Produces a lightweight 1-2 page HTML report
    and a JSONL audit trail for SIEM ingestion.

    This is NOT a full campaign audit -- it shows only changes in the time window
    for quick daily operations review.

    SCOPE REQUIREMENT:
        GET /v3/account-activities requires sp:scopes:all or a browser token.
        Use -Token with a JWT from the ISC admin console, or configure a PAT with
        sp:scopes:all in settings.json / the vault.

.PARAMETER SourceId
    One or more SailPoint ISC source IDs to monitor for access events.
    Obtain from: ISC Admin > Sources > select source > URL contains the source ID.
    Example: -SourceId 'src-abc123', @('src-1','src-2')
.PARAMETER HoursBack
    Look-back window in hours. Default: 24 (one full day).
    Increase to 48+ for catch-up after a missed day.
.PARAMETER OutputPath
    Directory for output files (HTML + JSONL). Created if absent.
    Default: DeltaCert\reports\ relative to the toolkit root.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials entirely. Obtain via:
    F12 > Network tab > any ISC API call > Authorization header value.
    The "Bearer " prefix is stripped automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
    ISC browser tokens are typically valid for ~12 minutes.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 24
    # Daily delta report for the last 24 hours.
.EXAMPLE
    .\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -HoursBack 48 -OutputPath 'C:\Reports'
    # Catch-up report for the last 48 hours, output to a custom directory.
.EXAMPLE
    .\Invoke-SPDeltaReport.ps1 -SourceId 'src-ad-001' -Token 'eyJhbGciOiJSUzI1...'
    # Use a browser token instead of OAuth credentials.
.NOTES
    Script:  Invoke-SPDeltaReport.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success -- report generated
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Report generation error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceId,

    [Parameter()]
    [int]$HoursBack = 24,

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

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';           Name = 'SP.Core';       Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';             Name = 'SP.Api';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert';   Required = $true  }
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

$correlationID = [guid]::NewGuid().ToString()

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Delta Certification Report' -ForegroundColor Cyan
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

# Resolve output path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot 'DeltaCert\reports'
}

Write-SPLog -Message "Invoke-SPDeltaReport started: SourceIds='$($SourceId -join ',')' HoursBack=$HoursBack OutputPath='$OutputPath'" `
    -Severity INFO -Component 'Invoke-SPDeltaReport' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Generate Report

$runStart = Get-Date

Write-Host "  Gathering delta data (last $HoursBack hours)..." -ForegroundColor Cyan

$dataResult = Get-SPDeltaReportData -SourceIds $SourceId -HoursBack $HoursBack `
    -CorrelationID $correlationID

if (-not $dataResult.Success) {
    Write-Host "ERROR: Failed to gather delta data: $($dataResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Invoke-SPDeltaReport failed: $($dataResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDeltaReport' -Action 'GatherData' -CorrelationID $correlationID
    exit 5
}

$reportData = $dataResult.Data

Write-Host '  Generating HTML report...' -ForegroundColor Cyan

$exportResult = Export-SPDeltaReportHtml -ReportData $reportData -OutputPath $OutputPath `
    -CorrelationID $correlationID

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

#endregion

#region Output

$summary = [PSCustomObject]@{
    CorrelationID    = $correlationID
    StartedAt        = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = [math]::Round($runDuration, 2)
    HtmlPath         = $exportResult.HtmlPath
    JsonlPath        = $exportResult.JsonlPath
    NewGrants        = @($reportData.NewGrants).Count
    Revocations      = @($reportData.Revocations).Count
    CampaignsCreated = @($reportData.CampaignsCreated).Count
    PendingReviews   = @($reportData.PendingReviews).Count
    Anomalies        = @($reportData.Anomalies).Count
    Sources          = $SourceId
    Environment      = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        Write-Host '  Delta Report Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  New Grants:        $($summary.NewGrants)" -ForegroundColor $(if ($summary.NewGrants -gt 0) { 'Yellow' } else { 'DarkGray' })
        Write-Host "  Revocations:       $($summary.Revocations)" -ForegroundColor $(if ($summary.Revocations -gt 0) { 'Green' } else { 'DarkGray' })
        Write-Host "  Campaigns Created: $($summary.CampaignsCreated)" -ForegroundColor DarkGray
        Write-Host "  Pending Reviews:   $($summary.PendingReviews)" -ForegroundColor $(if ($summary.PendingReviews -gt 0) { 'Yellow' } else { 'DarkGray' })
        Write-Host "  Anomalies:         $($summary.Anomalies)" -ForegroundColor $(if ($summary.Anomalies -gt 0) { 'Red' } else { 'DarkGray' })
        Write-Host ''
        Write-Host "  HTML:    $($exportResult.HtmlPath)" -ForegroundColor DarkCyan
        Write-Host "  JSONL:   $($exportResult.JsonlPath)" -ForegroundColor DarkCyan
        Write-Host "  Duration:      $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Environment:   $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $summary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPDeltaReport completed: Grants=$($summary.NewGrants) Revocations=$($summary.Revocations) Pending=$($summary.PendingReviews)" `
    -Severity INFO -Component 'Invoke-SPDeltaReport' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
