#Requires -Version 5.1
<#
.SYNOPSIS
    Escalates stale delta cert certifications by reassigning them up the org tree.
.DESCRIPTION
    Wraps the SP.DeltaCert escalation workflow: finds active delta cert certifications
    that have had no reviewer action past a configurable threshold, then reassigns
    each stale certification to the current reviewer's manager.

    Designed to run on a separate schedule from the main delta cert script
    (e.g., every 4 hours, or daily after business hours) to catch stale certifications.

    ISC sends its own notification email to the new reviewer when a certification
    is reassigned -- no custom email logic is needed.

    Escalation events are logged to JSONL in the DeltaCert output directory
    for compliance evidence.

    SCOPE REQUIREMENT:
        The underlying stale cert detection uses Search-SPCampaigns and
        Get-SPAuditCertifications (idn:campaign:read, idn:campaign-report:read).
        Reassignment uses Invoke-SPReassign (sp:scopes:all or browser token).
        Use -Token with a JWT from the ISC admin console, or configure a PAT
        in settings.json.

.PARAMETER CampaignNamePrefix
    Prefix (starts-with) used to find delta cert campaigns. Defaults to the
    DeltaCert.Escalation.CampaignNamePrefix value in settings.json
    (fallback: 'AD Delta Cert').
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name. Highest precedence.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix (same as -CampaignNamePrefix; provided for parity with
    Invoke-SPCampaignDiff).
.PARAMETER CampaignNameContains
    Substring (contains) match on the campaign name. Use it when the distinguishing token is in the
    MIDDLE of the name, e.g. the weekday in 'Daily Attestation Manager Wednesday'
    (-CampaignNameContains 'Wednesday'). Pairs with -DaysBack to bound the campaign-creation window.
    Precedence when several are given: -CampaignName > -CampaignNameContains > -CampaignNameStartsWith
    > -CampaignNamePrefix.
.PARAMETER StaleHours
    Number of hours with no reviewer action before a certification is
    considered stale. Defaults to DeltaCert.Escalation.DefaultStaleHours
    in settings.json (fallback: 24).
.PARAMETER EscalateBeforeDeadlineHours
    Escalate if the campaign deadline is within this many hours, regardless
    of how long the cert has been open. 0 = disabled (default).
    Union with StaleHours: either condition triggers escalation.
    Recommended: run at noon with -EscalateBeforeDeadlineHours 11 so
    certifications closing at 11 PM get escalated with 11 hours remaining.
.PARAMETER DaysBack
    When > 0, searches ALL campaigns (active + completed + staged) created in
    the last N days and runs in ORG CHART AUDIT mode: every certification in
    those campaigns is returned regardless of signed/stale status. Designed
    for use with -WhatIf to validate that ISC's manager chain resolves
    correctly before enabling live escalation.
    Example: -DaysBack 30 -WhatIf
.PARAMETER MaxEscalationLevels
    Maximum number of escalation hops from the original reviewer (1-5).
    Level 2 = direct manager, 3 = director, 4 = VP, 5 = SVP/executive.
    Defaults to DeltaCert.Escalation.MaxEscalationLevels in settings.json
    (fallback: 4). Maximum allowed: 5.
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
.PARAMETER Csv
    When set, writes a structured CSV file to {DeltaCert.OutputPath}\escalation-audit-YYYYMMDD-HHmmss.csv
    containing one row per certification found, with the full reviewer-to-manager chain
    resolved. Columns include: CampaignName, CampaignStatus, CertificationId,
    ReviewerName, ReviewerIdentityId, SkipLevelName, SkipLevelIdentityId, SkipLevelResolved,
    HoursOpen, HoursUntilDeadline, EscalationReason, CertSigned, Outcome.
    Works in both -WhatIf and live modes. Combines well with -DaysBack for a full
    30-day org chart audit report: -DaysBack 30 -WhatIf -Csv
.PARAMETER CsvPath
    Override the auto-generated CSV path. When specified alongside -Csv, writes the
    CSV to this exact path instead of the auto-generated one in DeltaCert.OutputPath.
.PARAMETER EmailList
    When set, writes a plain-text email-queue file to
    {DeltaCert.OutputPath}\escalation-emails-YYYYMMDD-HHmmss.txt for queueing an email
    OUTSIDE the tool. It contains two ready-to-paste, semicolon-separated lines:
      1) the managers behind -- ONLY reviewers who have NOT completed their attestation
         (incomplete certs); fully-signed reviewers are excluded, and
      2) the manager escalation path -- each late reviewer's manager chain, walked UP TO
         MaxEscalationLevels levels (1 = direct manager, 2-3 = higher per config).
    Each list is de-duplicated and only includes resolvable emails. Like -Csv, it is a
    read-only reporting artifact and is produced even under -WhatIf. Combine with -Csv to
    get both the full chain spreadsheet (all rows + Outcome) and the late-only email lines.
.PARAMETER EmailListPath
    Override the auto-generated email-queue path. Implies -EmailList.
.PARAMETER EmailHtml
    When set, produces a self-contained HTML escalation report alongside the text file.
    Groups late reviewers by manager with formatted tables and color-coded
    status indicators. Designed for attaching to or embedding in an escalation email.
    Output: {DeltaCert.OutputPath}\escalation-report-YYYYMMDD-HHmmss.html
.PARAMETER EmailHtmlPath
    Override the auto-generated HTML report path. Implies -EmailHtml.
.PARAMETER EmailHtmlManagers
    When set, generates tiered HTML email templates organized by escalation level.
    For each late reviewer, the org tree is walked UP to MaxEscalationLevels levels using
    Get-SPDeltaIdentityDetail. At each level (2 = direct manager, 3 = director, 4+ = VP/SVP),
    a personalized HTML file is generated showing the outstanding reviewers rolling up under
    that manager.

    Level 2 (direct manager): lists the reviewer's direct reports who are behind.
    Level 3+ (higher levels): groups reviewers by their subordinate managers at the next
    level down, with sub-headings per manager.

    Output structure:
        {DeltaCert.OutputPath}\escalation-managers\{timestamp}\
            level2\jane-smith.html
            level3\vp-williams.html
            level4\svp-chen.html
            _manifest.json

    The _manifest.json contains recipient info for all levels, suitable for SMTP automation.
    Identity lookups are cached to avoid redundant API calls.
.PARAMETER EmailHtmlManagersPath
    Override the auto-generated per-manager HTML output base directory. Implies -EmailHtmlManagers.
    The timestamped run folder and level subfolders are created inside this directory.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf
    # Dry-run: show which stale certifications would be escalated.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 0 -EscalateBeforeDeadlineHours 11 -WhatIf
    # Deadline-aware dry-run: escalate certs whose campaign closes within 11 hours.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf
    # Org chart audit: show the reviewer->manager chain for ALL certs in last 30 days.
    # Validates that ISC can resolve the manager for every reviewer. No write calls.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv
    # Org chart audit + CSV report: all chain data in a reviewable spreadsheet.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailList
    # Dry-run + email queue: writes the two copy-paste email lines (managers behind,
    # and the manager escalation path) for sending a nudge from your email client.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv -EmailList
    # Full org-chart audit: the chain spreadsheet AND the copy-paste email lines.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -CampaignNamePrefix 'Daily Attestation' -DaysBack 30 -WhatIf -Csv
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -CampaignNameContains 'Wednesday' -DaysBack 1 -WhatIf -Csv -EmailList
    # Find the campaign whose name CONTAINS 'Wednesday' (weekday mid-name), created in the last
    # day, and produce the chain CSV + copy-paste email queue. No write calls (WhatIf).
    # Org chart audit against a peer's campaign name prefix with CSV output.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailHtml
    # Dry-run + HTML escalation report: a self-contained HTML file grouped by
    # manager, suitable for embedding in or attaching to an escalation email.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 7 -WhatIf -Csv -EmailList -EmailHtml
    # Full audit: CSV spreadsheet + copy-paste email lines + HTML report, all in one run.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -WhatIf -EmailHtmlManagers
    # Dry-run + tiered per-manager HTML emails: generates a timestamped run folder under
    # escalation-managers/ with level2/, level3/, etc. subfolders. Each level contains one
    # HTML file per manager at that org level. Level 2 = direct manager, Level 3 = director,
    # Level 4+ = VP/SVP. Also produces _manifest.json for SMTP automation.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 7 -WhatIf -Csv -EmailHtml -EmailHtmlManagers
    # Full audit: CSV spreadsheet + consolidated HTML report + tiered per-manager HTML
    # email templates across all escalation levels. The manifest covers all levels.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Csv
    # Live escalation with CSV evidence log of what was processed.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 24 -Token 'eyJhbGciOiJSUzI1...'
    # Escalate stale certifications using a browser token.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -StaleHours 12 -MaxEscalationLevels 1
    # Aggressive escalation: 12-hour threshold, max 1 hop.
.NOTES
    Script:  Invoke-SPDeltaCertEscalate.ps1
    Version: 1.0.0
    Exit codes:
        0 = Escalation completed (or WhatIf)
        1 = No stale certifications found
        3 = Authentication error
        4 = Configuration error
        5 = Escalation error (partial or full failure)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$CampaignNamePrefix,

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
    [int]$StaleHours = 0,

    [Parameter()]
    [int]$EscalateBeforeDeadlineHours = 0,

    [Parameter()]
    [int]$DaysBack = 0,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$MaxEscalationLevels = 0,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [switch]$Csv,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$EmailList,

    [Parameter()]
    [string]$EmailListPath,

    [Parameter()]
    [switch]$EmailHtml,

    [Parameter()]
    [string]$EmailHtmlPath,

    [Parameter()]
    [switch]$EmailHtmlManagers,

    [Parameter()]
    [string]$EmailHtmlManagersPath,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1';       Name = 'SP.Shared';      Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';           Name = 'SP.Core';        Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';             Name = 'SP.Api';         Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';         Name = 'SP.Audit';       Required = $true  }
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
Write-Host '  Delta Cert Escalation' -ForegroundColor Cyan
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

# Apply config defaults for parameters not explicitly provided
$effectivePrefix = $CampaignNamePrefix
if ([string]::IsNullOrWhiteSpace($effectivePrefix)) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['Escalation'] -and
        $null -ne $config.DeltaCert.Escalation -and
        $null -ne $config.DeltaCert.Escalation.PSObject.Properties['CampaignNamePrefix'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.Escalation.CampaignNamePrefix)) {
        $effectivePrefix = [string]$config.DeltaCert.Escalation.CampaignNamePrefix
    }
    elseif ($null -ne $config.PSObject.Properties['DeltaCert'] -and
            $null -ne $config.DeltaCert -and
            $null -ne $config.DeltaCert.PSObject.Properties['CampaignNamePrefix'] -and
            -not [string]::IsNullOrWhiteSpace($config.DeltaCert.CampaignNamePrefix)) {
        $effectivePrefix = [string]$config.DeltaCert.CampaignNamePrefix
    }
    else {
        $effectivePrefix = 'AD Delta Cert'
    }
}

# Human-readable description of the campaign-name filter actually in effect (precedence:
# exact > contains > startsWith > prefix) -- shown in the console / WhatIf output.
$nameFilterDesc =
    if     (-not [string]::IsNullOrWhiteSpace($CampaignName))           { "name is '$CampaignName'" }
    elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))   { "name contains '$CampaignNameContains'" }
    elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { "name starts with '$CampaignNameStartsWith'" }
    else   { "name starts with '$effectivePrefix'" }

$effectiveStaleHours = $StaleHours
if ($effectiveStaleHours -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['Escalation'] -and
        $null -ne $config.DeltaCert.Escalation -and
        $null -ne $config.DeltaCert.Escalation.PSObject.Properties['DefaultStaleHours'] -and
        [int]$config.DeltaCert.Escalation.DefaultStaleHours -gt 0) {
        $effectiveStaleHours = [int]$config.DeltaCert.Escalation.DefaultStaleHours
    }
    else {
        $effectiveStaleHours = 24
    }
}

$effectiveMaxLevels = $MaxEscalationLevels
if ($effectiveMaxLevels -le 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['Escalation'] -and
        $null -ne $config.DeltaCert.Escalation -and
        $null -ne $config.DeltaCert.Escalation.PSObject.Properties['MaxEscalationLevels'] -and
        [int]$config.DeltaCert.Escalation.MaxEscalationLevels -gt 0) {
        $effectiveMaxLevels = [int]$config.DeltaCert.Escalation.MaxEscalationLevels
    }
    else {
        $effectiveMaxLevels = 4
    }
}
# Cap at 5 regardless of source (param or config)
if ($effectiveMaxLevels -gt 5) { $effectiveMaxLevels = 5 }

Write-SPLog -Message "Invoke-SPDeltaCertEscalate started: Prefix='$effectivePrefix' StaleHours=$effectiveStaleHours EscalateBeforeDeadlineHours=$EscalateBeforeDeadlineHours DaysBack=$DaysBack MaxLevels=$effectiveMaxLevels" `
    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Dispatch

$runStart = Get-Date

# WhatIf short-circuit: describe what would run
if (($WhatIfPreference -eq $true)) {
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    if ($DaysBack -gt 0) {
        Write-Host '  ORG CHART AUDIT MODE' -ForegroundColor Cyan
        Write-Host '  All certifications in the window are checked.' -ForegroundColor DarkGray
        Write-Host '  Each reviewer is resolved to their manager to validate ISC manager chains.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Would run escalation with:' -ForegroundColor Cyan
    }
    Write-Host "    Campaign filter:             $nameFilterDesc"
    Write-Host "    StaleHours:                  $effectiveStaleHours"
    if ($EscalateBeforeDeadlineHours -gt 0) {
        Write-Host "    EscalateBeforeDeadlineHours: $EscalateBeforeDeadlineHours"
    }
    if ($DaysBack -gt 0) {
        Write-Host "    DaysBack:                    $DaysBack  (all campaign statuses)"
    }
    Write-Host "    MaxEscalationLevels:         $effectiveMaxLevels"
    $outputArtifacts = @()
    if ($Csv.IsPresent -or -not [string]::IsNullOrWhiteSpace($CsvPath))                               { $outputArtifacts += 'CSV' }
    if ($EmailList.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailListPath))                    { $outputArtifacts += 'EmailList' }
    if ($EmailHtml.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailHtmlPath))                    { $outputArtifacts += 'EmailHtml' }
    if ($EmailHtmlManagers.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailHtmlManagersPath))    { $outputArtifacts += 'EmailHtmlManagers' }
    if ($outputArtifacts.Count -gt 0) {
        Write-Host "    Output artifacts:            $($outputArtifacts -join ', ')"
    }
    Write-Host ''
}

if ($DaysBack -gt 0) {
    Write-Host "  Org chart audit: scanning campaigns from last $DaysBack days..." -ForegroundColor Cyan
}
else {
    Write-Host "  Detecting stale certifications (threshold: $effectiveStaleHours hours)..." -ForegroundColor Cyan
}

# Step 1: Find stale/in-scope certifications
$staleParams = @{
    CampaignNamePrefix = $effectivePrefix
    StaleHours         = $effectiveStaleHours
    CorrelationID      = $correlationID
}
if ($EscalateBeforeDeadlineHours -gt 0) {
    $staleParams['EscalateBeforeDeadlineHours'] = $EscalateBeforeDeadlineHours
}
if ($DaysBack -gt 0) {
    $staleParams['DaysBack'] = $DaysBack
}
# Pass through the explicit name filters; the function applies precedence
# (exact > contains > startsWith > prefix).
if (-not [string]::IsNullOrWhiteSpace($CampaignName))           { $staleParams['CampaignName'] = $CampaignName }
if (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { $staleParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))   { $staleParams['CampaignNameContains'] = $CampaignNameContains }
if ($Status -and $Status.Count -gt 0)                          { $staleParams['Status'] = $Status }

$staleResult = Get-SPDeltaCertStaleCertifications @staleParams

if (-not $staleResult.Success) {
    Write-Host "ERROR: Stale cert detection failed: $($staleResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Stale cert detection failed: $($staleResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDeltaCertEscalate' -Action 'Detect' -CorrelationID $correlationID
    exit 5
}

$staleCerts = @($staleResult.Data)

#region CSV + email-queue output (built before runner so -WhatIf and reporting can co-exist)

$effectiveCsvPath              = $CsvPath              # hoisted so the JSONL audit block can reference it
$effectiveEmailListPath        = $EmailListPath        # hoisted so the JSONL audit block can reference it
$effectiveEmailHtmlPath        = $EmailHtmlPath        # hoisted so the JSONL audit block can reference it
$effectiveEmailHtmlManagersPath = $EmailHtmlManagersPath # hoisted so the JSONL audit block can reference it

$wantCsv         = ($Csv.IsPresent       -or -not [string]::IsNullOrWhiteSpace($CsvPath))
$wantEmail       = ($EmailList.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailListPath))
$wantEmailHtml   = ($EmailHtml.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailHtmlPath))
$wantManagerHtml = ($EmailHtmlManagers.IsPresent -or -not [string]::IsNullOrWhiteSpace($EmailHtmlManagersPath))

# HTML-encode helper that works on both PS 5.1 (Desktop) and PS 7 (Core).
# System.Net.WebUtility may not be loaded on Windows PS 5.1.
function ConvertTo-EscHtml {
    param([Parameter()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try { return (ConvertTo-SPHtmlSafe $Value) }
    catch {
        # Fallback: manual replacement covers the critical characters.
        return $Value.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
    }
}

if (($wantCsv -or $wantEmail -or $wantEmailHtml -or $wantManagerHtml) -and $staleCerts.Count -gt 0) {

    # Shared DeltaCert output directory + stamp for any auto-generated artifact path.
    $reportOutputDir = '.\DeltaCert'
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
        $reportOutputDir = [string]$config.DeltaCert.OutputPath
    }
    if (-not (Test-Path -LiteralPath $reportOutputDir -PathType Container)) {
        # -WhatIf:$false: these are read-only reporting artifacts and must be produced even in
        # dry-run mode. Only the ISC reassignment calls are gated by WhatIf.
        New-Item -Path $reportOutputDir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    $reportStamp = (Get-Date -Format 'yyyyMMdd-HHmmss')

    # CSV path is only auto-generated when CSV output is requested.
    if ($wantCsv -and [string]::IsNullOrWhiteSpace($effectiveCsvPath)) {
        $effectiveCsvPath = Join-Path $reportOutputDir "escalation-audit-$reportStamp.csv"
    }

    # Resolve the reviewer -> skip-level chain ONCE; both the CSV and the email queue use it.
    Write-Host "  Resolving reviewer -> manager chain..." -ForegroundColor Cyan

    $csvRows = [System.Collections.Generic.List[object]]::new()

    foreach ($sc in $staleCerts) {
        $reviewerId    = $sc.ReviewerIdentityId
        $reviewerEmail = ''
        $skipName      = ''
        $skipId        = ''
        $skipEmail     = ''
        $skipFound     = $false
        $outcome       = 'Pending'

        # Determine skip-level (reviewer's manager) — same resolution the runner uses.
        # The reviewer + manager detail lookups also carry .Email, which we surface in the
        # CSV at no extra API cost. Captured into per-row variables (reset above) so a stale
        # $mgDetail from a prior iteration can never leak onto a row whose lookup didn't run.
        if (-not [string]::IsNullOrWhiteSpace($reviewerId)) {
            try {
                $detail = Get-SPDeltaIdentityDetail -IdentityId $reviewerId -CorrelationID $correlationID
                if ($detail.Found) { $reviewerEmail = [string]$detail.Email }
                if ($detail.Found -and -not [string]::IsNullOrWhiteSpace($detail.ManagerId)) {
                    $skipId    = $detail.ManagerId
                    $skipFound = $true
                    try {
                        $mgDetail = Get-SPDeltaIdentityDetail -IdentityId $detail.ManagerId -CorrelationID $correlationID
                        if ($mgDetail.Found) {
                            $skipName  = $mgDetail.DisplayName
                            $skipEmail = [string]$mgDetail.Email
                        }
                        else {
                            $skipName = $detail.ManagerId
                        }
                    } catch { $skipName = $detail.ManagerId }
                }
            } catch { }
        }

        # Determine what would/did happen
        $levelsConsumed  = if ($sc.ReviewerClassification -eq 'Reassigned') { 1 } else { 0 }
        $levelsRemaining = $effectiveMaxLevels - $levelsConsumed

        if ([bool]$sc.CertSigned) {
            # Already signed/complete -- no escalation needed (matches the runner's skip).
            $outcome = 'Skip-AlreadyComplete'
        }
        elseif ([string]::IsNullOrWhiteSpace($reviewerId)) {
            $outcome = 'Skip-NoReviewerId'
        }
        elseif ($levelsRemaining -le 0) {
            $outcome = 'Skip-MaxLevelsReached'
        }
        elseif (-not $skipFound) {
            $outcome = 'Skip-NoManagerInISC'
        }
        elseif (($WhatIfPreference -eq $true)) {
            $outcome = 'WouldEscalate'
        }
        else {
            $outcome = 'Escalated'
        }

        $reassignedFrom = if ($null -ne $sc.PSObject.Properties['ReassignedFromName']) { [string]$sc.ReassignedFromName } else { '' }

        $csvRows.Add([PSCustomObject]@{
            CampaignName         = $sc.CampaignName
            CampaignStatus       = $sc.CampaignStatus
            CertificationId      = $sc.CertificationId
            ReviewerName         = $sc.ReviewerName
            ReviewerEmail        = $reviewerEmail
            ReviewerIdentityId   = $sc.ReviewerIdentityId
            Classification       = $sc.ReviewerClassification
            ReassignedFrom       = $reassignedFrom
            SkipLevelName        = $skipName
            SkipLevelEmail       = $skipEmail
            SkipLevelIdentityId  = $skipId
            SkipLevelResolved    = $skipFound
            HoursOpen            = $sc.HoursOpen
            HoursUntilDeadline   = $sc.HoursUntilDeadline
            EscalationReason     = $sc.EscalationReason
            CertSigned           = $sc.CertSigned
            Outcome              = $outcome
        })
    }

    if ($wantCsv) {
        try {
            # -WhatIf:$false forces the write even under -WhatIf (Export-Csv supports ShouldProcess
            # and would otherwise be silently suppressed, yielding a false "CSV written" claim).
            $csvRows | Export-Csv -LiteralPath $effectiveCsvPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
            if (Test-Path -LiteralPath $effectiveCsvPath) {
                Write-Host "  CSV written: $effectiveCsvPath ($($csvRows.Count) row(s))" -ForegroundColor Green
                Write-SPLog -Message "Escalation audit CSV written: $effectiveCsvPath ($($csvRows.Count) rows)" `
                    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'CsvOutput' `
                    -CorrelationID $correlationID
            }
            else {
                # Defensive: never claim success when no file landed on disk.
                Write-Host "  WARNING: CSV export reported no error but file is missing: $effectiveCsvPath" -ForegroundColor Yellow
                Write-SPLog -Message "Escalation audit CSV missing after export: $effectiveCsvPath" `
                    -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'CsvOutput' `
                    -CorrelationID $correlationID
            }
        }
        catch {
            Write-Host "  WARNING: Failed to write CSV: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Failed to write escalation audit CSV '$effectiveCsvPath': $($_.Exception.Message)" `
                -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'CsvOutput' `
                -CorrelationID $correlationID
        }
    }

    # --- Shared late-row filtering: used by -EmailList, -EmailHtml, and -EmailHtmlManagers. ---
    # The email outputs are NUDGE lists -- they must contain ONLY the reviewers who are actually
    # behind (a signed/complete cert needs no email). In audit mode (-DaysBack) $csvRows
    # includes completed certs too, so without this filter the queue would list everyone. The
    # CSV deliberately keeps all rows (it has the Outcome column); the email views are late-only.
    $lateRows = $null
    $mgrEmails   = @()
    $skipEmails  = @()
    $scopeLabel  = ''
    $lvlLabel    = ''

    if ($wantEmail -or $wantEmailHtml -or $wantManagerHtml) {
        $lateRows = @($csvRows | Where-Object { -not [bool]$_.CertSigned })

        # Late reviewers themselves (managers who have not completed their attestation).
        $mgrEmails = @($lateRows | ForEach-Object { [string]$_.ReviewerEmail } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)

        # Escalation path -- walk each late reviewer's manager chain UP TO
        # MaxEscalationLevels levels (1 = direct manager, 2-3 = higher per config). De-duplicated.
        $skipSet = [ordered]@{}
        foreach ($row in $lateRows) {
            $curId = [string]$row.SkipLevelIdentityId
            $lvl = 0
            while (-not [string]::IsNullOrWhiteSpace($curId) -and $lvl -lt $effectiveMaxLevels) {
                $d = Get-SPDeltaIdentityDetail -IdentityId $curId -CorrelationID $correlationID
                if ($d.Found -and -not [string]::IsNullOrWhiteSpace([string]$d.Email)) {
                    $em = ([string]$d.Email).Trim()
                    if (-not $skipSet.Contains($em)) { $skipSet[$em] = $true }
                }
                $curId = if ($d.Found) { [string]$d.ManagerId } else { '' }
                $lvl++
            }
        }
        $skipEmails = @($skipSet.Keys | Sort-Object -Unique)

        $scopeLabel = if ($DaysBack -gt 0) { "org-chart audit, last $DaysBack day(s)" } else { "stale >= $effectiveStaleHours h" }
        $lvlLabel   = if ($effectiveMaxLevels -le 1) { 'direct manager' } else { "up to $effectiveMaxLevels levels" }
    }

    # --- Email-queue text artifact: semicolon-separated email lines + per-skip-level breakdown. ---
    if ($wantEmail) {
        if ([string]::IsNullOrWhiteSpace($effectiveEmailListPath)) {
            $effectiveEmailListPath = Join-Path $reportOutputDir "escalation-emails-$reportStamp.txt"
        }

        $mgrMissing  = @($lateRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.ReviewerEmail) }).Count
        $skipMissing = @($lateRows | Where-Object { -not $_.SkipLevelResolved }).Count
        $mgrNote  = if ($mgrMissing  -gt 0) { " ($mgrMissing with no email on file)" } else { '' }
        $skipNote = if ($skipMissing -gt 0) { " ($skipMissing with no manager in ISC)" } else { '' }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('# Delta Cert Escalation -- email queue')
        [void]$sb.AppendLine("# Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))  |  Prefix: '$effectivePrefix'  |  Scope: $scopeLabel")
        [void]$sb.AppendLine("# Managers behind (incomplete): $($mgrEmails.Count)$mgrNote  |  Escalation contacts ($lvlLabel): $($skipEmails.Count)$skipNote")
        [void]$sb.AppendLine("# Only reviewers who have NOT completed their attestation are listed. Copy the line beneath each heading into your client's To/CC field.")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Managers behind (reviewers who have NOT completed their attestation):')
        [void]$sb.AppendLine(($mgrEmails -join '; '))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Manager escalation path ($lvlLabel):")
        [void]$sb.AppendLine(($skipEmails -join '; '))

        # --- Per-manager breakdown ---
        # Group late reviewers by their manager so each escalation contact can see
        # exactly which of their direct reports is behind.
        [void]$sb.AppendLine('')

        # Build groups: key = SkipLevelEmail (or sentinel for unresolved), value = list of rows
        $skipGroups = [ordered]@{}
        foreach ($row in $lateRows) {
            $groupKey = if ($row.SkipLevelResolved -and -not [string]::IsNullOrWhiteSpace([string]$row.SkipLevelEmail)) {
                [string]$row.SkipLevelEmail
            } else {
                '__UNRESOLVED__'
            }
            if (-not $skipGroups.Contains($groupKey)) {
                $skipGroups[$groupKey] = [System.Collections.Generic.List[object]]::new()
            }
            $skipGroups[$groupKey].Add($row)
        }

        foreach ($groupKey in $skipGroups.Keys) {
            $groupRows = $skipGroups[$groupKey]
            [void]$sb.AppendLine('========================================')
            if ($groupKey -eq '__UNRESOLVED__') {
                [void]$sb.AppendLine('Manager: Unresolved')
            }
            else {
                $dispName = [string]($groupRows[0].SkipLevelName)
                if ([string]::IsNullOrWhiteSpace($dispName)) { $dispName = '(unknown)' }
                [void]$sb.AppendLine("Manager: $dispName")
            }
            [void]$sb.AppendLine("Reviewers still outstanding: $($groupRows.Count)")

            # Ready-to-paste email line: manager email; reviewer1 email; reviewer2 email; ...
            $groupEmailParts = [System.Collections.Generic.List[string]]::new()
            if ($groupKey -ne '__UNRESOLVED__' -and -not [string]::IsNullOrWhiteSpace($groupKey)) {
                $groupEmailParts.Add($groupKey)
            }
            foreach ($r in $groupRows) {
                $rEmail = [string]$r.ReviewerEmail
                if (-not [string]::IsNullOrWhiteSpace($rEmail) -and -not $groupEmailParts.Contains($rEmail.Trim())) {
                    $groupEmailParts.Add($rEmail.Trim())
                }
            }
            [void]$sb.AppendLine("To: $($groupEmailParts -join '; ')")
            [void]$sb.AppendLine('')

            # Reviewer detail table (name + campaign only)
            $colReviewer  = 'Reviewer'
            $colCampaign  = 'Campaign'
            $wReviewer = [Math]::Max($colReviewer.Length, ($groupRows | ForEach-Object { ([string]$_.ReviewerName).Length } | Measure-Object -Maximum).Maximum)
            $wCampaign = [Math]::Max($colCampaign.Length, ($groupRows | ForEach-Object { ([string]$_.CampaignName).Length } | Measure-Object -Maximum).Maximum)
            if ($wCampaign -gt 60) { $wCampaign = 60 }

            $fmtHeader = "  {0,-$wReviewer}  {1,-$wCampaign}"
            $fmtSep    = "  {0}  {1}"
            [void]$sb.AppendLine(($fmtHeader -f $colReviewer, $colCampaign))
            [void]$sb.AppendLine(($fmtSep -f ('-' * $wReviewer), ('-' * $wCampaign)))

            foreach ($r in ($groupRows | Sort-Object { [string]$_.ReviewerName })) {
                $rName = [string]$r.ReviewerName
                if ($rName.Length -gt $wReviewer) { $rName = $rName.Substring(0, $wReviewer) }
                $cName = [string]$r.CampaignName
                if ($cName.Length -gt $wCampaign) { $cName = $cName.Substring(0, $wCampaign - 3) + '...' }

                [void]$sb.AppendLine(($fmtHeader -f $rName, $cName))
            }
            [void]$sb.AppendLine('')
        }
        [void]$sb.AppendLine('========================================')

        try {
            # WriteAllText is not ShouldProcess-gated, so the queue is produced under -WhatIf too
            # (it is a read-only reporting artifact, like the CSV). UTF-8 no-BOM per repo convention.
            Write-SPHtmlFile -Path $effectiveEmailListPath -Content $sb.ToString()
            if (Test-Path -LiteralPath $effectiveEmailListPath) {
                Write-Host "  Email queue written: $effectiveEmailListPath ($($mgrEmails.Count) manager(s), $($skipEmails.Count) escalation contacts)" -ForegroundColor Green
                Write-SPLog -Message "Escalation email queue written: $effectiveEmailListPath (managers=$($mgrEmails.Count) skip=$($skipEmails.Count))" `
                    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailQueue' `
                    -CorrelationID $correlationID
            }
            else {
                Write-Host "  WARNING: email queue reported no error but file is missing: $effectiveEmailListPath" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  WARNING: Failed to write email queue: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Failed to write escalation email queue '$effectiveEmailListPath': $($_.Exception.Message)" `
                -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailQueue' `
                -CorrelationID $correlationID
        }
    }

    # --- HTML escalation report: self-contained, email-friendly HTML with per-manager tables. ---
    if ($wantEmailHtml) {
        if ([string]::IsNullOrWhiteSpace($effectiveEmailHtmlPath)) {
            $effectiveEmailHtmlPath = Join-Path $reportOutputDir "escalation-report-$reportStamp.html"
        }

        # Count distinct campaigns among late rows
        $lateCampaigns = @($lateRows | ForEach-Object { [string]$_.CampaignName } | Sort-Object -Unique)

        $html = New-Object System.Text.StringBuilder
        [void]$html.AppendLine('<!DOCTYPE html>')
        [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8">')
        [void]$html.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
        [void]$html.AppendLine('<title>Escalation Summary</title>')
        [void]$html.AppendLine('<style>')
        [void]$html.AppendLine('body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;padding:20px;background:#f5f5f5;color:#333}')
        [void]$html.AppendLine('.wrap{max-width:900px;margin:0 auto;background:#fff;border-radius:6px;box-shadow:0 1px 4px rgba(0,0,0,.12);padding:28px 32px}')
        [void]$html.AppendLine('h1{font-size:22px;color:#264d73;margin:0 0 6px;border-bottom:2px solid #264d73;padding-bottom:8px}')
        [void]$html.AppendLine('h2{font-size:17px;color:#264d73;margin:24px 0 6px;border-bottom:1px solid #ddd;padding-bottom:4px}')
        [void]$html.AppendLine('h2 small{font-size:13px;color:#777;font-weight:normal}')
        [void]$html.AppendLine('.meta{font-size:13px;color:#555;margin:4px 0 16px}')
        [void]$html.AppendLine('.summary{font-size:14px;margin:0 0 20px}')
        [void]$html.AppendLine('table{width:100%;border-collapse:collapse;margin:8px 0 16px;font-size:13px}')
        [void]$html.AppendLine('th{background:#264d73;color:#fff;text-align:left;padding:7px 10px;font-weight:600;white-space:nowrap}')
        [void]$html.AppendLine('td{padding:6px 10px;border-bottom:1px solid #e8e8e8;vertical-align:top}')
        [void]$html.AppendLine('tr:nth-child(even) td{background:#fafafa}')
        [void]$html.AppendLine('tr:hover td{background:#f0f4f8}')
        [void]$html.AppendLine('.s-red{color:#CC3333;font-weight:600}')
        [void]$html.AppendLine('.s-amber{color:#9a6700;font-weight:600}')
        [void]$html.AppendLine('.s-green{color:#339933;font-weight:600}')
        [void]$html.AppendLine('.s-gray{color:#777}')
        [void]$html.AppendLine('.badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:11px;font-weight:600}')
        [void]$html.AppendLine('.badge-red{background:#fdecea;color:#CC3333}')
        [void]$html.AppendLine('.badge-amber{background:#fff8e1;color:#9a6700}')
        [void]$html.AppendLine('.badge-green{background:#e8f5e9;color:#339933}')
        [void]$html.AppendLine('code{background:#f0f0f0;padding:3px 8px;border-radius:3px;font-size:12px;word-break:break-all}')
        [void]$html.AppendLine('.copy-section{background:#f8f9fa;border:1px solid #e0e0e0;border-radius:4px;padding:14px 18px;margin:16px 0}')
        [void]$html.AppendLine('.copy-section p{margin:6px 0}')
        [void]$html.AppendLine('@media print{body{background:#fff;padding:0}.wrap{box-shadow:none;padding:0}th{background:#264d73 !important;-webkit-print-color-adjust:exact;print-color-adjust:exact}}')
        [void]$html.AppendLine('</style></head><body><div class="wrap">')

        # Header
        $genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
        [void]$html.AppendLine('<h1>Escalation Summary</h1>')
        [void]$html.AppendLine("<p class='meta'>Generated: $genDate | Campaign prefix: <strong>$(ConvertTo-EscHtml $effectivePrefix)</strong> | Scope: $(ConvertTo-EscHtml $scopeLabel)</p>")
        [void]$html.AppendLine("<p class='summary'><strong>$($lateRows.Count) reviewer(s)</strong> have not completed their attestation across <strong>$($lateCampaigns.Count) campaign(s)</strong>.</p>")

        # Helper: HTML-encode with null safety
        $enc = { param($s) ConvertTo-EscHtml ([string]$s) }

        # Helper: determine status badge based on outcome
        $statusBadge = {
            param($row)
            $o = [string]$row.Outcome
            switch -Wildcard ($o) {
                'WouldEscalate' { "<span class='badge badge-amber'>Would Escalate</span>" }
                'Escalated'     { "<span class='badge badge-red'>Escalated</span>" }
                'Skip-*'        { "<span class='badge badge-green'>$(&$enc $o)</span>" }
                default         { "<span class='s-gray'>$(&$enc $o)</span>" }
            }
        }

        # Helper: reason display
        $reasonText = {
            param($row)
            $r = [string]$row.EscalationReason
            if ([string]::IsNullOrWhiteSpace($r)) { '-' }
            elseif ($r -match 'Stale')    { "<span class='s-red'>$(&$enc $r)</span>" }
            elseif ($r -match 'Deadline') { "<span class='s-amber'>$(&$enc $r)</span>" }
            else { &$enc $r }
        }

        # Build manager groups (reuse pattern from text section)
        $htmlSkipGroups = [ordered]@{}
        foreach ($row in $lateRows) {
            $gKey = if ($row.SkipLevelResolved -and -not [string]::IsNullOrWhiteSpace([string]$row.SkipLevelEmail)) {
                [string]$row.SkipLevelEmail
            } else {
                '__UNRESOLVED__'
            }
            if (-not $htmlSkipGroups.Contains($gKey)) {
                $htmlSkipGroups[$gKey] = [System.Collections.Generic.List[object]]::new()
            }
            $htmlSkipGroups[$gKey].Add($row)
        }

        # Render resolved groups first, unresolved last
        $sortedKeys = @($htmlSkipGroups.Keys | Where-Object { $_ -ne '__UNRESOLVED__' } | Sort-Object)
        if ($htmlSkipGroups.Contains('__UNRESOLVED__')) { $sortedKeys += '__UNRESOLVED__' }

        foreach ($gKey in $sortedKeys) {
            $gRows = $htmlSkipGroups[$gKey]
            if ($gKey -eq '__UNRESOLVED__') {
                [void]$html.AppendLine('<h2>Unresolved Manager Chain</h2>')
                [void]$html.AppendLine('<p>These reviewers have no manager resolved in ISC:</p>')
            }
            else {
                $gName = [string]($gRows[0].SkipLevelName)
                if ([string]::IsNullOrWhiteSpace($gName)) { $gName = '(unknown)' }
                [void]$html.AppendLine("<h2>$(&$enc $gName) <small>($(&$enc $gKey))</small></h2>")
                [void]$html.AppendLine("<p>$($gRows.Count) reviewer(s) outstanding</p>")
            }

            [void]$html.AppendLine('<table>')
            [void]$html.AppendLine('<tr><th>Reviewer</th><th>Email</th><th>Campaign</th><th>Hours Open</th><th>Reason</th><th>Status</th></tr>')

            foreach ($r in ($gRows | Sort-Object { [double]$_.HoursOpen } -Descending)) {
                $rName   = &$enc $r.ReviewerName
                $rEmail  = &$enc $r.ReviewerEmail
                $cName   = &$enc $r.CampaignName
                $hrsOpen = '{0:N1}' -f [double]$r.HoursOpen
                $reason  = &$reasonText $r
                $badge   = &$statusBadge $r

                [void]$html.AppendLine("<tr><td>$rName</td><td>$rEmail</td><td>$cName</td><td>$hrsOpen</td><td>$reason</td><td>$badge</td></tr>")
            }
            [void]$html.AppendLine('</table>')
        }

        # Footer: email quick-copy section
        [void]$html.AppendLine('<h2>Email Quick-Copy</h2>')
        [void]$html.AppendLine('<div class="copy-section">')
        [void]$html.AppendLine("<p><strong>Managers behind:</strong> <code>$(ConvertTo-EscHtml ($mgrEmails -join '; '))</code></p>")
        [void]$html.AppendLine("<p><strong>Manager escalation contacts:</strong> <code>$(ConvertTo-EscHtml ($skipEmails -join '; '))</code></p>")
        [void]$html.AppendLine('</div>')

        [void]$html.AppendLine('</div></body></html>')

        try {
            Write-SPHtmlFile -Path $effectiveEmailHtmlPath -Content $html.ToString()
            if (Test-Path -LiteralPath $effectiveEmailHtmlPath) {
                Write-Host "  HTML report written: $effectiveEmailHtmlPath ($($lateRows.Count) reviewer(s), $($htmlSkipGroups.Count) group(s))" -ForegroundColor Green
                Write-SPLog -Message "Escalation HTML report written: $effectiveEmailHtmlPath (reviewers=$($lateRows.Count) groups=$($htmlSkipGroups.Count))" `
                    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailHtml' `
                    -CorrelationID $correlationID
            }
            else {
                Write-Host "  WARNING: HTML report reported no error but file is missing: $effectiveEmailHtmlPath" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  WARNING: Failed to write HTML report: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Failed to write escalation HTML report '$effectiveEmailHtmlPath': $($_.Exception.Message)" `
                -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailHtml' `
                -CorrelationID $correlationID
        }
    }

    # --- Tiered per-manager HTML email templates: one file per manager per escalation level. ---
    if ($wantManagerHtml -and $null -ne $lateRows -and $lateRows.Count -gt 0) {
        # Determine base output directory
        $mgrHtmlBaseDir = $effectiveEmailHtmlManagersPath
        if ([string]::IsNullOrWhiteSpace($mgrHtmlBaseDir)) {
            $mgrHtmlBaseDir = Join-Path $reportOutputDir 'escalation-managers'
        }

        # Create timestamped run folder inside the base directory
        $runTimestamp = (Get-Date -Format 'yyyy-MM-ddTHHmmss')
        $mgrHtmlDir = Join-Path $mgrHtmlBaseDir $runTimestamp
        $effectiveEmailHtmlManagersPath = $mgrHtmlDir

        if (-not (Test-Path -LiteralPath $mgrHtmlDir -PathType Container)) {
            New-Item -Path $mgrHtmlDir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }

        # Helper: extract first name from a display name
        $getFirstName = {
            param([string]$fullName)
            if ([string]::IsNullOrWhiteSpace($fullName)) { return $fullName }
            $trimmed = $fullName.Trim()
            if ($trimmed -match ',') {
                # "Last, First" format
                $parts = $trimmed -split ',\s*'
                if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
                    return ($parts[1] -split '\s+')[0]
                }
            }
            # "First Last" format or single word
            $parts = $trimmed -split '\s+'
            return $parts[0]
        }

        # Helper: sanitize name to filename
        $sanitizeFilename = {
            param([string]$name)
            $safe = $name -replace '[\\/:*?"<>|\s,.]', '-'
            $safe = $safe -replace '-{2,}', '-'
            $safe = $safe.Trim('-').ToLower()
            return $safe
        }

        # --- Step 1: Build the full org chain for each late reviewer ---
        # For each late reviewer, walk UP the org tree to build a chain of identity IDs.
        # Chain index: 0 = reviewer (self), 1 = reviewer's manager (level 2 in output),
        # 2 = manager's manager (level 3), etc.
        # Identity detail cache avoids redundant API calls (Get-SPDeltaIdentityDetail
        # already has in-memory + disk caching, but we also cache locally for chain building).
        $identityCache = @{}

        # Helper: resolve identity detail with local cache layer
        $resolveIdentity = {
            param([string]$identityId)
            if ([string]::IsNullOrWhiteSpace($identityId)) { return $null }
            if ($identityCache.ContainsKey($identityId)) { return $identityCache[$identityId] }
            $d = Get-SPDeltaIdentityDetail -IdentityId $identityId -CorrelationID $correlationID
            $identityCache[$identityId] = $d
            return $d
        }

        # Structure: array of chains, each chain is an array of identity detail hashtables
        # chain[0] = reviewer, chain[1] = reviewer's manager (level 2), chain[2] = level 3, etc.
        $reviewerChains = [System.Collections.Generic.List[object]]::new()

        # Track reviewers that fall out of the chain (no manager in ISC)
        $noManagerReviewers = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $lateRows) {
            $reviewerId = [string]$row.ReviewerIdentityId
            if ([string]::IsNullOrWhiteSpace($reviewerId)) {
                $noManagerReviewers.Add($row)
                continue
            }
            if (-not $row.SkipLevelResolved) {
                $noManagerReviewers.Add($row)
                continue
            }

            $chain = [System.Collections.Generic.List[object]]::new()

            # Index 0: the reviewer themselves (use data from $row + identity detail)
            $reviewerDetail = & $resolveIdentity $reviewerId
            $chain.Add(@{
                IdentityId  = $reviewerId
                DisplayName = [string]$row.ReviewerName
                Email       = [string]$row.ReviewerEmail
                ManagerId   = if ($reviewerDetail -and $reviewerDetail.Found) { [string]$reviewerDetail.ManagerId } else { '' }
                Found       = ($null -ne $reviewerDetail -and $reviewerDetail.Found)
                Row         = $row
            })

            # Walk up: index 1 = level 2 (direct manager), index 2 = level 3, etc.
            # We need effectiveMaxLevels levels above the reviewer (indices 1..effectiveMaxLevels).
            $curId = if ($reviewerDetail -and $reviewerDetail.Found) { [string]$reviewerDetail.ManagerId } else { '' }
            for ($lvl = 1; $lvl -le $effectiveMaxLevels; $lvl++) {
                if ([string]::IsNullOrWhiteSpace($curId)) { break }
                $d = & $resolveIdentity $curId
                if ($null -eq $d -or -not $d.Found) { break }

                $chain.Add(@{
                    IdentityId  = [string]$d.IdentityId
                    DisplayName = [string]$d.DisplayName
                    Email       = [string]$d.Email
                    ManagerId   = [string]$d.ManagerId
                    Found       = $true
                })

                $curId = [string]$d.ManagerId
            }

            $reviewerChains.Add($chain)
        }

        # Track level 2 managers whose chain broke before reaching higher levels.
        # These managers have no manager in ISC and won't appear in level 3+ folders.
        $brokenChainManagers = [System.Collections.Generic.List[object]]::new()
        foreach ($chain in $reviewerChains) {
            # chain[0] = reviewer, chain[1] = level 2, chain[2] = level 3, etc.
            # If chain length is < effectiveMaxLevels + 1, it broke early
            if ($chain.Count -ge 2 -and $chain.Count -lt ($effectiveMaxLevels + 1)) {
                $topMgr = $chain[$chain.Count - 1]
                $brokenChainManagers.Add(@{
                    ManagerName = [string]$topMgr.DisplayName
                    ManagerEmail = [string]$topMgr.Email
                    ManagerId = [string]$topMgr.IdentityId
                    ChainDepth = $chain.Count - 1
                    ReviewerRow = $chain[0].Row
                })
            }
        }

        # --- Step 2: Build per-level aggregations ---
        # For each level N (2 through effectiveMaxLevels+1, but we use chain index N-1):
        #   levelData[N] = hashtable keyed by manager identity ID at level N
        #     -> each entry: Name, Email, FirstName, IdentityId
        #     -> For level 2 (chain index 1): DirectReviewers = list of reviewer rows
        #     -> For level 3+ (chain index 2+): Subordinates = hashtable keyed by
        #        subordinate manager ID -> { Name, Email, Reviewers = list of reviewer rows }
        $levelData = @{}

        foreach ($chain in $reviewerChains) {
            $reviewerRow = $chain[0].Row

            # Process each level above the reviewer (chain index 1 = level 2, etc.)
            for ($chainIdx = 1; $chainIdx -lt $chain.Count; $chainIdx++) {
                $levelNum = $chainIdx + 1  # chain index 1 -> level 2
                $mgrEntry = $chain[$chainIdx]
                $mgrId    = [string]$mgrEntry.IdentityId

                if (-not $levelData.ContainsKey($levelNum)) {
                    $levelData[$levelNum] = @{}
                }

                if (-not $levelData[$levelNum].ContainsKey($mgrId)) {
                    $levelData[$levelNum][$mgrId] = @{
                        IdentityId      = $mgrId
                        DisplayName     = [string]$mgrEntry.DisplayName
                        Email           = [string]$mgrEntry.Email
                        FirstName       = & $getFirstName ([string]$mgrEntry.DisplayName)
                        DirectReviewers = [System.Collections.Generic.List[object]]::new()
                        Subordinates    = [ordered]@{}
                    }
                }

                $mgrData = $levelData[$levelNum][$mgrId]

                if ($levelNum -eq 2) {
                    # Level 2: direct manager of the reviewer -- reviewers list directly
                    $mgrData.DirectReviewers.Add($reviewerRow)
                }
                else {
                    # Level 3+: group by the subordinate manager at the level below
                    # The subordinate is at chain index ($chainIdx - 1)
                    $subEntry = $chain[$chainIdx - 1]
                    $subId    = [string]$subEntry.IdentityId
                    if (-not $mgrData.Subordinates.Contains($subId)) {
                        $mgrData.Subordinates[$subId] = @{
                            IdentityId = $subId
                            DisplayName = [string]$subEntry.DisplayName
                            Email       = [string]$subEntry.Email
                            Reviewers   = [System.Collections.Generic.List[object]]::new()
                        }
                    }
                    $mgrData.Subordinates[$subId].Reviewers.Add($reviewerRow)
                }
            }
        }

        # --- Step 3: Generate HTML files per manager per level ---
        $genDateUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

        # Collect distinct campaign names for the greeting
        $allLateCampaignNames = @($lateRows | ForEach-Object { [string]$_.CampaignName } | Sort-Object -Unique)
        $campaignDisplayName = if ($allLateCampaignNames.Count -eq 1) {
            $allLateCampaignNames[0]
        } else {
            ($allLateCampaignNames -join ', ')
        }

        # Inline CSS styles shared across all generated HTML files (email-safe inline)
        $bodyStyle    = "font-family:'Segoe UI',Arial,sans-serif;color:#333;max-width:700px;margin:0 auto;padding:20px"
        $tableStyle   = "border-collapse:collapse;width:100%;margin:16px 0;font-size:13px"
        $thRowStyle   = "background:#264d73;color:#fff"
        $thCellStyle  = "padding:10px 12px;text-align:left"
        $thCenterStyle = "padding:10px 12px;text-align:center"
        $tdStyle      = "padding:8px 12px"
        $tdCenterStyle = "padding:8px 12px;text-align:center;font-weight:bold;color:#CC3333"
        $subHeadStyle = "margin:20px 0 8px;padding:8px 12px;background:#f0f4f8;border-left:4px solid #264d73;font-size:14px;color:#264d73"
        $hrStyle      = "border:none;border-top:1px solid #e0e0e0;margin:24px 0"
        $footerStyle  = "font-size:11px;color:#999"

        # Helper scriptblock: render a reviewer table given a list of rows
        $renderReviewerTable = {
            param(
                [System.Text.StringBuilder]$sb,
                [object[]]$rows
            )
            [void]$sb.AppendLine("<table style=`"$tableStyle`">")
            [void]$sb.AppendLine('<thead>')
            [void]$sb.AppendLine("<tr style=`"$thRowStyle`">")
            [void]$sb.AppendLine("  <th style=`"$thCellStyle`">Reviewer</th>")
            [void]$sb.AppendLine("  <th style=`"$thCellStyle`">Campaign</th>")
            [void]$sb.AppendLine("  <th style=`"$thCenterStyle`">Pending Items</th>")
            [void]$sb.AppendLine('</tr>')
            [void]$sb.AppendLine('</thead>')
            [void]$sb.AppendLine('<tbody>')

            $tblIdx = 0
            foreach ($r in ($rows | Sort-Object { [string]$_.ReviewerName })) {
                $rowBg = if ($tblIdx % 2 -eq 1) { "background:#f8f9fa;" } else { '' }
                $rName = ConvertTo-EscHtml ([string]$r.ReviewerName)
                $cName = ConvertTo-EscHtml ([string]$r.CampaignName)
                [void]$sb.AppendLine("<tr style=`"border-bottom:1px solid #e0e0e0;${rowBg}`">")
                [void]$sb.AppendLine("  <td style=`"$tdStyle`">$rName</td>")
                [void]$sb.AppendLine("  <td style=`"$tdStyle`">$cName</td>")
                [void]$sb.AppendLine("  <td style=`"$tdCenterStyle`">Pending</td>")
                [void]$sb.AppendLine('</tr>')
                $tblIdx++
            }

            [void]$sb.AppendLine('</tbody>')
            [void]$sb.AppendLine('</table>')
        }

        # Helper scriptblock: recursively render the full org subtree for a manager.
        # $mgrId = identity ID of the manager, $mgrLevel = their level number (2, 3, 4...),
        # $targetLevel = the level of the report recipient (determines heading depth),
        # $sb = StringBuilder. For the recipient's direct subordinates, uses <h2>; for
        # deeper nesting uses <h3>, <h4>, etc.
        # Render a subordinate manager and their reviewers recursively.
        # Uses the subordinate data from the PARENT node (not the global $levelData)
        # to ensure only reviewers that roll up through THIS specific path are shown.
        $renderSubTree = {
            param(
                [System.Text.StringBuilder]$sb,
                [string]$mgrId,
                [int]$mgrLevel,
                [int]$targetLevel
            )
            $hDepth = $targetLevel - $mgrLevel + 1
            if ($hDepth -lt 2) { $hDepth = 2 }
            if ($hDepth -gt 6) { $hDepth = 6 }
            $hTag = "h$hDepth"

            if (-not $levelData.ContainsKey($mgrLevel) -or -not $levelData[$mgrLevel].ContainsKey($mgrId)) {
                return 0
            }

            $mgrNode = $levelData[$mgrLevel][$mgrId]
            $totalReviewers = 0

            if ($mgrLevel -eq 2) {
                # Leaf level: render the reviewer table directly
                $directRows = @($mgrNode.DirectReviewers)
                if ($directRows.Count -eq 0) { return 0 }
                $totalReviewers = $directRows.Count
                $subName = [string]$mgrNode.DisplayName
                if ([string]::IsNullOrWhiteSpace($subName)) { $subName = '(unknown)' }
                $subWord = if ($directRows.Count -eq 1) { 'outstanding reviewer' } else { 'outstanding reviewers' }
                [void]$sb.AppendLine("<$hTag style=`"$subHeadStyle`"><strong>$(ConvertTo-EscHtml $subName)</strong> -- $($directRows.Count) $subWord</$hTag>")
                & $renderReviewerTable $sb $directRows
                [void]$sb.AppendLine('')
            }
            else {
                # Intermediate level: only render if subordinates have actual reviewers
                # First pass: collect children that have content
                $childContent = New-Object System.Text.StringBuilder
                $childTotal = 0
                foreach ($subId in $mgrNode.Subordinates.Keys) {
                    $childCount = & $renderSubTree $childContent $subId ($mgrLevel - 1) $targetLevel
                    $childTotal += $childCount
                }

                # Only render this manager heading if children had reviewers
                if ($childTotal -gt 0) {
                    $subName = [string]$mgrNode.DisplayName
                    if ([string]::IsNullOrWhiteSpace($subName)) { $subName = '(unknown)' }
                    [void]$sb.AppendLine("<$hTag style=`"$subHeadStyle`"><strong>$(ConvertTo-EscHtml $subName)</strong> -- $childTotal outstanding</$hTag>")
                    [void]$sb.Append($childContent.ToString())
                    $totalReviewers = $childTotal
                }
            }

            return $totalReviewers
        }

        $manifestLevels = [ordered]@{}
        $mgrFilesWritten = 0
        $totalReviewersPending = 0

        # Sort levels numerically for consistent output
        $sortedLevels = @($levelData.Keys | Sort-Object)

        foreach ($levelNum in $sortedLevels) {
            # Skip level 1 (that is the reviewer themselves, not a manager)
            if ($levelNum -lt 2) { continue }

            $levelLabel = "level$levelNum"
            $levelDir = Join-Path $mgrHtmlDir $levelLabel
            if (-not (Test-Path -LiteralPath $levelDir -PathType Container)) {
                New-Item -Path $levelDir -ItemType Directory -Force -WhatIf:$false | Out-Null
            }

            $levelManifest = [System.Collections.Generic.List[object]]::new()

            foreach ($mgrId in $levelData[$levelNum].Keys) {
                $mgrData   = $levelData[$levelNum][$mgrId]
                $mgrName   = [string]$mgrData.DisplayName
                $mgrEmail  = [string]$mgrData.Email
                $firstName = [string]$mgrData.FirstName
                if ([string]::IsNullOrWhiteSpace($mgrName)) { $mgrName = '(unknown)' }
                if ([string]::IsNullOrWhiteSpace($firstName)) { $firstName = $mgrName }

                $safeFile = "$(& $sanitizeFilename $mgrName).html"

                $mgrHtml = New-Object System.Text.StringBuilder
                [void]$mgrHtml.AppendLine('<!DOCTYPE html>')
                [void]$mgrHtml.AppendLine('<html><head>')
                [void]$mgrHtml.AppendLine('<meta charset="utf-8">')
                [void]$mgrHtml.AppendLine('<title>Attestation Action Required</title>')
                [void]$mgrHtml.AppendLine('</head>')
                [void]$mgrHtml.AppendLine("<body style=`"$bodyStyle`">")
                [void]$mgrHtml.AppendLine('')
                [void]$mgrHtml.AppendLine("<p style=`"font-size:15px`">Hi $(ConvertTo-EscHtml $firstName),</p>")
                [void]$mgrHtml.AppendLine('')

                $reviewerCount = 0
                $directReportMgrCount = 0

                if ($levelNum -eq 2) {
                    # Level 2: direct manager -- show direct reviewer list
                    $directRows = @($mgrData.DirectReviewers)
                    $reviewerCount = $directRows.Count

                    [void]$mgrHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">")
                    [void]$mgrHtml.AppendLine("You have direct reports who have not completed today's daily attestation")
                    [void]$mgrHtml.AppendLine("for the campaign <strong>$(ConvertTo-EscHtml $campaignDisplayName)</strong>.")
                    [void]$mgrHtml.AppendLine('</p>')
                    [void]$mgrHtml.AppendLine('')

                    & $renderReviewerTable $mgrHtml $directRows
                    [void]$mgrHtml.AppendLine('')

                    # Summary line
                    $reviewerWord = if ($reviewerCount -eq 1) { 'reviewer requires' } else { 'reviewers require' }
                    [void]$mgrHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">")
                    [void]$mgrHtml.AppendLine("<strong>$reviewerCount $reviewerWord</strong> follow-up.")
                    [void]$mgrHtml.AppendLine('</p>')
                }
                else {
                    # Level 3+: full rollup -- recursively render the entire org subtree
                    [void]$mgrHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">")
                    [void]$mgrHtml.AppendLine("Members of your organization have not completed today's daily attestation")
                    [void]$mgrHtml.AppendLine("for the campaign <strong>$(ConvertTo-EscHtml $campaignDisplayName)</strong>.")
                    [void]$mgrHtml.AppendLine('</p>')
                    [void]$mgrHtml.AppendLine('')

                    $subMgrCount = 0
                    foreach ($subId in $mgrData.Subordinates.Keys) {
                        $subMgrCount++
                        $childReviewerCount = & $renderSubTree $mgrHtml $subId ($levelNum - 1) $levelNum
                        $reviewerCount += $childReviewerCount
                    }

                    $directReportMgrCount = $subMgrCount

                    # Summary line
                    $mgrWord = if ($subMgrCount -eq 1) { 'manager' } else { 'managers' }
                    $reviewerWord = if ($reviewerCount -eq 1) { 'reviewer' } else { 'reviewers' }
                    [void]$mgrHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">")
                    [void]$mgrHtml.AppendLine("<strong>$reviewerCount $reviewerWord</strong> across <strong>$subMgrCount $mgrWord</strong> require follow-up.")
                    [void]$mgrHtml.AppendLine('</p>')
                }

                $totalReviewersPending += $reviewerCount

                [void]$mgrHtml.AppendLine('')
                [void]$mgrHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">")
                [void]$mgrHtml.AppendLine('Please follow up with your team to ensure timely attestation.')
                [void]$mgrHtml.AppendLine('</p>')

                # Footer
                [void]$mgrHtml.AppendLine('')
                [void]$mgrHtml.AppendLine("<hr style=`"$hrStyle`">")
                [void]$mgrHtml.AppendLine("<p style=`"$footerStyle`">")
                [void]$mgrHtml.AppendLine("This report was generated by the SailPoint ISC Governance Toolkit on $genDateUtc.")
                [void]$mgrHtml.AppendLine("Campaign scope: $(ConvertTo-EscHtml $nameFilterDesc). This is an automated notification.")
                [void]$mgrHtml.AppendLine('</p>')
                [void]$mgrHtml.AppendLine('')
                [void]$mgrHtml.AppendLine('</body></html>')

                # Write the file
                $mgrFilePath = Join-Path $levelDir $safeFile
                $relativeFile = "$levelLabel/$safeFile"
                try {
                    Write-SPHtmlFile -Path $mgrFilePath -Content $mgrHtml.ToString()
                    $mgrFilesWritten++
                }
                catch {
                    Write-Host "  WARNING: Failed to write manager HTML for '$mgrName' ($levelLabel): $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-SPLog -Message "Failed to write manager HTML '$mgrFilePath': $($_.Exception.Message)" `
                        -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailHtmlManagers' `
                        -CorrelationID $correlationID
                }

                # Add to level manifest
                $manifestEntry = [ordered]@{
                    ManagerName  = $mgrName
                    ManagerEmail = $mgrEmail
                    File         = $relativeFile
                    ReviewerCount = $reviewerCount
                }
                if ($levelNum -ge 3) {
                    $manifestEntry['DirectReportManagerCount'] = $directReportMgrCount
                }
                $levelManifest.Add([PSCustomObject]$manifestEntry)
            }

            $manifestLevels[$levelLabel] = $levelManifest
        }

        # --- Generate no-manager bucket for reviewers/managers with broken chains ---
        $noMgrItems = [System.Collections.Generic.List[object]]::new()
        # Add reviewers with no skip-level at all
        foreach ($r in $noManagerReviewers) { $noMgrItems.Add($r) }
        # Add reviewers under level 2 managers whose chain broke before the max level
        # (group by the top manager who has no manager above them)
        $brokenGrouped = @{}
        foreach ($bc in $brokenChainManagers) {
            $key = [string]$bc.ManagerId
            if (-not $brokenGrouped.ContainsKey($key)) {
                $brokenGrouped[$key] = @{
                    ManagerName  = $bc.ManagerName
                    ManagerEmail = $bc.ManagerEmail
                    ManagerId    = $bc.ManagerId
                    ChainDepth   = $bc.ChainDepth
                    Rows         = [System.Collections.Generic.List[object]]::new()
                }
            }
            $brokenGrouped[$key].Rows.Add($bc.ReviewerRow)
        }

        if ($noMgrItems.Count -gt 0 -or $brokenGrouped.Count -gt 0) {
            $noMgrDir = Join-Path $mgrHtmlDir 'no-manager'
            if (-not (Test-Path -LiteralPath $noMgrDir -PathType Container)) {
                New-Item -Path $noMgrDir -ItemType Directory -Force -WhatIf:$false | Out-Null
            }

            $noMgrHtml = New-Object System.Text.StringBuilder
            [void]$noMgrHtml.AppendLine('<!DOCTYPE html>')
            [void]$noMgrHtml.AppendLine('<html><head><meta charset="utf-8"><title>Unresolved Manager Chain</title></head>')
            [void]$noMgrHtml.AppendLine("<body style=`"$bodyStyle`">")
            [void]$noMgrHtml.AppendLine("<h1 style=`"color:#264d73;border-bottom:2px solid #264d73;padding-bottom:8px`">Unresolved Manager Chain</h1>")
            [void]$noMgrHtml.AppendLine("<p style=`"font-size:14px;color:#555`">The following reviewers or their managers do not have a complete manager chain in ISC. These individuals cannot be automatically escalated to higher levels and require manual follow-up.</p>")

            # Section 1: Reviewers with no skip-level at all
            if ($noMgrItems.Count -gt 0) {
                [void]$noMgrHtml.AppendLine("<h2 style=`"color:#264d73;margin-top:20px`">Reviewers with No Manager in ISC <span style=`"font-size:12px;background:#e8eef5;padding:2px 8px;border-radius:10px;color:#555`">$($noMgrItems.Count)</span></h2>")
                [void]$noMgrHtml.AppendLine("<p style=`"font-size:13px;color:#777`">These reviewers have no resolvable manager -- they cannot be escalated at any level.</p>")
                & $renderReviewerTable $noMgrHtml $noMgrItems.ToArray()
            }

            # Section 2: Managers whose chain broke (have a level 2 but no level 3+)
            if ($brokenGrouped.Count -gt 0) {
                [void]$noMgrHtml.AppendLine("<h2 style=`"color:#264d73;margin-top:20px`">Managers with Incomplete Chain <span style=`"font-size:12px;background:#e8eef5;padding:2px 8px;border-radius:10px;color:#555`">$($brokenGrouped.Count) manager(s)</span></h2>")
                [void]$noMgrHtml.AppendLine("<p style=`"font-size:13px;color:#777`">These managers appear at level 2 (or below) but have no manager above them in ISC. Their outstanding reviewers will not appear in higher-level reports.</p>")

                foreach ($mgr in ($brokenGrouped.Values | Sort-Object { $_.ManagerName })) {
                    $mName = ConvertTo-EscHtml $mgr.ManagerName
                    $mEmail = ConvertTo-EscHtml $mgr.ManagerEmail
                    [void]$noMgrHtml.AppendLine("<div style=`"$subHeadStyle`"><strong>$mName</strong> ($mEmail) -- chain stops at level $($mgr.ChainDepth), $($mgr.Rows.Count) outstanding reviewer(s)</div>")
                    & $renderReviewerTable $noMgrHtml $mgr.Rows.ToArray()
                }
            }

            [void]$noMgrHtml.AppendLine("<hr style=`"$hrStyle`">")
            [void]$noMgrHtml.AppendLine("<p style=`"$footerStyle`">Generated by SailPoint ISC Governance Toolkit on $genDateUtc. These entries require manual review of the ISC manager chain.</p>")
            [void]$noMgrHtml.AppendLine('</body></html>')

            $noMgrFilePath = Join-Path $noMgrDir 'unresolved-chains.html'
            try {
                Write-SPHtmlFile -Path $noMgrFilePath -Content $noMgrHtml.ToString()
                $mgrFilesWritten++
            }
            catch {
                Write-Host "  WARNING: Failed to write no-manager HTML: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            # Add to manifest
            $manifestLevels['no-manager'] = @(
                [ordered]@{
                    File                   = 'no-manager/unresolved-chains.html'
                    ReviewersNoSkipLevel   = $noMgrItems.Count
                    ManagersBrokenChain    = $brokenGrouped.Count
                    TotalAffectedReviewers = $noMgrItems.Count + ($brokenGrouped.Values | ForEach-Object { $_.Rows.Count } | Measure-Object -Sum).Sum
                }
            )
        }

        # --- Generate all-outstanding.html: every late reviewer grouped by level 2 manager ---
        $allOutstandingPath = Join-Path $mgrHtmlDir 'all-outstanding.html'
        try {
            $allHtml = New-Object System.Text.StringBuilder
            [void]$allHtml.AppendLine('<!DOCTYPE html>')
            [void]$allHtml.AppendLine('<html><head><meta charset="utf-8">')
            [void]$allHtml.AppendLine('<title>All Outstanding Attestation Reviews</title>')
            [void]$allHtml.AppendLine('</head>')
            [void]$allHtml.AppendLine("<body style=`"$bodyStyle`">")
            [void]$allHtml.AppendLine("<h1 style=`"color:#264d73;border-bottom:2px solid #264d73;padding-bottom:8px`">All Outstanding Attestation Reviews</h1>")

            # Count distinct campaigns and reviewers
            $allCampaignNames = @($lateRows | ForEach-Object { [string]$_.CampaignName } | Sort-Object -Unique)
            $allReviewerCount = $lateRows.Count
            $campaignWord = if ($allCampaignNames.Count -eq 1) { 'campaign' } else { 'campaigns' }
            [void]$allHtml.AppendLine("<p style=`"font-size:14px;line-height:1.6`">$allReviewerCount reviewer(s) across $($allCampaignNames.Count) $campaignWord have not completed their attestation.</p>")

            # Group by level 2 manager (use levelData[2] to iterate)
            if ($levelData.ContainsKey(2)) {
                foreach ($l2MgrId in ($levelData[2].Keys | Sort-Object { [string]$levelData[2][$_].DisplayName })) {
                    $l2Mgr = $levelData[2][$l2MgrId]
                    $l2Name = [string]$l2Mgr.DisplayName
                    if ([string]::IsNullOrWhiteSpace($l2Name)) { $l2Name = '(unknown)' }
                    [void]$allHtml.AppendLine("<h2 style=`"color:#264d73;margin-top:24px;border-bottom:1px solid #ddd;padding-bottom:4px`">$(ConvertTo-EscHtml $l2Name) (Manager)</h2>")
                    & $renderReviewerTable $allHtml @($l2Mgr.DirectReviewers)
                }
            }

            [void]$allHtml.AppendLine('')
            [void]$allHtml.AppendLine("<hr style=`"$hrStyle`">")
            [void]$allHtml.AppendLine("<p style=`"$footerStyle`">Generated by SailPoint ISC Governance Toolkit on $genDateUtc. Campaign scope: $(ConvertTo-EscHtml $nameFilterDesc).</p>")
            [void]$allHtml.AppendLine('</body></html>')

            Write-SPHtmlFile -Path $allOutstandingPath -Content $allHtml.ToString()
            $mgrFilesWritten++
            Write-Host "  All-outstanding HTML written: $allOutstandingPath" -ForegroundColor Green
        }
        catch {
            Write-Host "  WARNING: Failed to write all-outstanding HTML: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Add all-outstanding to manifest
        $manifestLevels['all-outstanding'] = @(
            [ordered]@{
                File          = 'all-outstanding.html'
                ReviewerCount = $lateRows.Count
            }
        )

        # --- Generate _email-routing.csv: who-sends-what-to-whom routing table ---
        $emailRoutingPath = Join-Path $mgrHtmlDir '_email-routing.csv'
        try {
            $routingRows = [System.Collections.Generic.List[object]]::new()

            foreach ($lvlNum in ($levelData.Keys | Sort-Object)) {
                if ($lvlNum -lt 2) { continue }
                foreach ($rMgrId in $levelData[$lvlNum].Keys) {
                    $rMgr = $levelData[$lvlNum][$rMgrId]
                    $rSafeFile = "$(& $sanitizeFilename ([string]$rMgr.DisplayName)).html"
                    $rRelPath  = "level$lvlNum/$rSafeFile"
                    # Reviewer count: for level 2 use DirectReviewers, for level 3+ count from subordinates
                    $rCount = 0
                    if ($lvlNum -eq 2) {
                        $rCount = $rMgr.DirectReviewers.Count
                    }
                    else {
                        foreach ($sKey in $rMgr.Subordinates.Keys) {
                            $rCount += $rMgr.Subordinates[$sKey].Reviewers.Count
                        }
                    }
                    # Collect reviewer emails for this manager
                    $rEmails = [System.Collections.Generic.List[string]]::new()
                    if ($lvlNum -eq 2) {
                        foreach ($dr in $rMgr.DirectReviewers) {
                            $e = [string]$dr.ReviewerEmail
                            if (-not [string]::IsNullOrWhiteSpace($e) -and -not $rEmails.Contains($e.Trim())) { $rEmails.Add($e.Trim()) }
                        }
                    }
                    else {
                        foreach ($sKey in $rMgr.Subordinates.Keys) {
                            foreach ($sr in $rMgr.Subordinates[$sKey].Reviewers) {
                                $e = [string]$sr.ReviewerEmail
                                if (-not [string]::IsNullOrWhiteSpace($e) -and -not $rEmails.Contains($e.Trim())) { $rEmails.Add($e.Trim()) }
                            }
                        }
                    }
                    $routingRows.Add([PSCustomObject]@{
                        Level          = $lvlNum
                        ManagerEmail   = [string]$rMgr.Email
                        ManagerName    = [string]$rMgr.DisplayName
                        HtmlFile       = $rRelPath
                        ReviewerCount  = $rCount
                        ReviewerEmails = ($rEmails -join '; ')
                    })
                }
            }

            # Collect all reviewer emails for the all-outstanding row
            $allRevEmails = @($lateRows | ForEach-Object { [string]$_.ReviewerEmail } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)

            # Add all-outstanding row
            $routingRows.Add([PSCustomObject]@{
                Level          = 'all'
                ManagerEmail   = ''
                ManagerName    = 'All Recipients'
                HtmlFile       = 'all-outstanding.html'
                ReviewerCount  = $lateRows.Count
                ReviewerEmails = ($allRevEmails -join '; ')
            })

            # Add no-manager row if applicable
            if ($noMgrItems.Count -gt 0 -or $brokenGrouped.Count -gt 0) {
                $noMgrTotal = $noMgrItems.Count + ($brokenGrouped.Values | ForEach-Object { $_.Rows.Count } | Measure-Object -Sum).Sum
                $noMgrEmails = @($noMgrItems | ForEach-Object { [string]$_.ReviewerEmail } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
                $routingRows.Add([PSCustomObject]@{
                    Level          = 'no-manager'
                    ManagerEmail   = ''
                    ManagerName    = ''
                    HtmlFile       = 'no-manager/unresolved-chains.html'
                    ReviewerCount  = $noMgrTotal
                    ReviewerEmails = ($noMgrEmails -join '; ')
                })
            }

            $routingRows | Export-Csv -LiteralPath $emailRoutingPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
            Write-Host "  Email routing CSV written: $emailRoutingPath ($($routingRows.Count) row(s))" -ForegroundColor Green
        }
        catch {
            Write-Host "  WARNING: Failed to write email routing CSV: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # De-duplicate totalReviewersPending: the same reviewer may appear at multiple levels.
        # Use the level-2 count as the canonical total since every late reviewer appears there once.
        $canonicalReviewerCount = 0
        if ($manifestLevels.Contains('level2')) {
            foreach ($entry in $manifestLevels['level2']) {
                $canonicalReviewerCount += $entry.ReviewerCount
            }
        }
        elseif ($lateRows.Count -gt 0) {
            # Fallback: count distinct reviewer identity IDs from late rows
            $canonicalReviewerCount = @($lateRows | ForEach-Object { [string]$_.ReviewerIdentityId } | Sort-Object -Unique).Count
        }

        # Write combined _manifest.json
        $manifestObj = [ordered]@{
            GeneratedAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            CampaignScope       = $campaignDisplayName
            MaxEscalationLevels = $effectiveMaxLevels
            Levels              = [ordered]@{}
            TotalFiles          = $mgrFilesWritten
            TotalReviewersPending = $canonicalReviewerCount
        }

        foreach ($lvlKey in $manifestLevels.Keys) {
            $lvlEntries = @($manifestLevels[$lvlKey])
            # Ensure array wrapper even for single entries
            $manifestObj.Levels[$lvlKey] = $lvlEntries
        }

        $manifestPath = Join-Path $mgrHtmlDir '_manifest.json'
        try {
            $manifestJson = $manifestObj | ConvertTo-Json -Depth 10
            Write-SPHtmlFile -Path $manifestPath -Content $manifestJson
        }
        catch {
            Write-Host "  WARNING: Failed to write manager manifest: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SPLog -Message "Failed to write manager manifest '$manifestPath': $($_.Exception.Message)" `
                -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailHtmlManagers' `
                -CorrelationID $correlationID
        }

        if ($mgrFilesWritten -gt 0) {
            $levelSummary = @($manifestLevels.Keys | ForEach-Object { "$_=$($manifestLevels[$_].Count)" }) -join ', '
            Write-Host "  Manager HTML emails written: $mgrHtmlDir ($mgrFilesWritten file(s) across $($manifestLevels.Count) level(s): $levelSummary)" -ForegroundColor Green
            Write-SPLog -Message "Per-manager HTML emails written: $mgrHtmlDir (files=$mgrFilesWritten levels=$($manifestLevels.Count) $levelSummary)" `
                -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'EmailHtmlManagers' `
                -CorrelationID $correlationID
        }
        else {
            Write-Host "  No manager HTML emails generated (all reviewers may have unresolved managers)." -ForegroundColor Yellow
        }
    }

    Write-Host ''
}

#endregion

if ($staleCerts.Count -eq 0) {
    Write-Host ''
    if ($DaysBack -gt 0) {
        Write-Host '  No certifications found in audit window.' -ForegroundColor Yellow
        Write-Host "  Filter:   $nameFilterDesc" -ForegroundColor DarkGray
        Write-Host "  DaysBack: $DaysBack days" -ForegroundColor DarkGray
    }
    else {
        Write-Host '  No stale certifications found.' -ForegroundColor Yellow
        Write-Host "  Filter:     $nameFilterDesc" -ForegroundColor DarkGray
        Write-Host "  Threshold:  $effectiveStaleHours hours" -ForegroundColor DarkGray
    }
    Write-Host ''

    Write-SPLog -Message "No stale certifications found" `
        -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Detect' -CorrelationID $correlationID
    exit 1
}

Write-Host "  Found $($staleCerts.Count) stale certification(s). Escalating..." -ForegroundColor Cyan

# Step 2: Escalate stale certifications.
# $WhatIfPreference does not reliably propagate across module boundaries in PS5.1:
# the runner (SP.DeltaCertRunner.psm1) runs in its own module scope and may not
# inherit $WhatIfPreference = $true from this script scope. Passing -WhatIf
# explicitly via splatting ensures the common parameter is honoured inside the
# runner, preventing live reassignment API calls in dry-run mode.
$escalateParams = @{
    StaleCertifications = $staleCerts
    MaxEscalationLevels = $effectiveMaxLevels
    CorrelationID       = $correlationID
}
if ($WhatIfPreference -eq $true) { $escalateParams['WhatIf'] = $true }
$escalateResult = Invoke-SPDeltaCertEscalate @escalateParams

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

#endregion

#region JSONL Audit

try {
    $outputPath = '.\DeltaCert'
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
        $outputPath = $config.DeltaCert.OutputPath
    }

    if (-not (Test-Path -Path $outputPath -PathType Container)) {
        # -WhatIf:$false: the JSONL is an audit log that records dry runs too (note the
        # WhatIf field below); its directory must exist or the AppendAllText call throws.
        New-Item -Path $outputPath -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    $escalatedIds = @()
    $skippedIds   = @()
    $errorMsgs    = @()
    if ($null -ne $escalateResult.Data) {
        $escalatedIds = @($escalateResult.Data.Escalated)
        $skippedIds   = @($escalateResult.Data.Skipped)
        $errorMsgs    = @($escalateResult.Data.Errors)
    }

    $auditEvent = [ordered]@{
        Timestamp                   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        CorrelationID               = $correlationID
        Action                      = 'DeltaCertEscalation'
        CampaignNamePrefix          = $effectivePrefix
        StaleHours                  = $effectiveStaleHours
        EscalateBeforeDeadlineHours = $EscalateBeforeDeadlineHours
        DaysBack                    = $DaysBack
        MaxEscalationLevels         = $effectiveMaxLevels
        CertsFound                  = $staleCerts.Count
        Escalated                   = $escalatedIds.Count
        Skipped                     = $skippedIds.Count
        Errors                      = $errorMsgs
        WhatIf                      = ($WhatIfPreference -eq $true)
        CsvPath                     = if (-not [string]::IsNullOrWhiteSpace($effectiveCsvPath)) { $effectiveCsvPath } else { $null }
        EmailListPath               = if (-not [string]::IsNullOrWhiteSpace($effectiveEmailListPath)) { $effectiveEmailListPath } else { $null }
        EmailHtmlPath               = if (-not [string]::IsNullOrWhiteSpace($effectiveEmailHtmlPath)) { $effectiveEmailHtmlPath } else { $null }
        EmailHtmlManagersPath       = if (-not [string]::IsNullOrWhiteSpace($effectiveEmailHtmlManagersPath)) { $effectiveEmailHtmlManagersPath } else { $null }
        EmailHtmlManagersFileCount  = if (-not [string]::IsNullOrWhiteSpace($effectiveEmailHtmlManagersPath)) { @(Get-ChildItem -LiteralPath $effectiveEmailHtmlManagersPath -Filter '*.html' -File -Recurse -ErrorAction SilentlyContinue).Count } else { 0 }
        EmailHtmlManagersLevels     = if (-not [string]::IsNullOrWhiteSpace($effectiveEmailHtmlManagersPath)) { @(Get-ChildItem -LiteralPath $effectiveEmailHtmlManagersPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^level\d+$' }).Count } else { 0 }
        DurationSeconds             = [math]::Round($runDuration, 2)
    }

    $jsonLine  = $auditEvent | ConvertTo-Json -Depth 5 -Compress
    $filePath  = Join-Path -Path $outputPath -ChildPath 'deltacert-escalation.jsonl'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($filePath, "$jsonLine`n", $utf8NoBom)

    Write-SPLog -Message "Escalation audit event written to $filePath" `
        -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Audit' -CorrelationID $correlationID
}
catch {
    Write-SPLog -Message "Failed to write escalation audit JSONL: $($_.Exception.Message)" `
        -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'Audit' -CorrelationID $correlationID
}

#endregion

#region Output

$escalatedCount = 0
$skippedCount   = 0
$errorCount     = 0
if ($null -ne $escalateResult.Data) {
    $escalatedCount = @($escalateResult.Data.Escalated).Count
    $skippedCount   = @($escalateResult.Data.Skipped).Count
    $errorCount     = @($escalateResult.Data.Errors).Count
}

$summary = [PSCustomObject]@{
    CorrelationID                = $correlationID
    StartedAt                    = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt                  = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds              = [math]::Round($runDuration, 2)
    CampaignNamePrefix           = $effectivePrefix
    StaleHours                   = $effectiveStaleHours
    EscalateBeforeDeadlineHours  = $EscalateBeforeDeadlineHours
    DaysBack                     = $DaysBack
    MaxEscalationLevels          = $effectiveMaxLevels
    CertsFound                   = $staleCerts.Count
    Escalated                    = $escalatedCount
    Skipped                      = $skippedCount
    Errors                       = $errorCount
    Success                      = $escalateResult.Success
    Environment                  = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        if (($WhatIfPreference -eq $true)) {
            Write-Host '  Escalation WhatIf Summary' -ForegroundColor Cyan
        }
        else {
            Write-Host '  Escalation Complete' -ForegroundColor Cyan
        }
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Certs found:       $($staleCerts.Count)" -ForegroundColor DarkGray
        Write-Host "  Escalated:         $escalatedCount" -ForegroundColor Green
        Write-Host "  Skipped:           $skippedCount" -ForegroundColor Yellow
        if ($errorCount -gt 0) {
            Write-Host "  Errors:            $errorCount" -ForegroundColor Red
            foreach ($err in @($escalateResult.Data.Errors)) {
                Write-Host "    $err" -ForegroundColor Red
            }
        }
        Write-Host "  Duration:          $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Environment:       $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $correlationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $summary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPDeltaCertEscalate completed: Escalated=$escalatedCount Skipped=$skippedCount Errors=$errorCount" `
    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Complete' -CorrelationID $correlationID

# Exit codes
if (-not $escalateResult.Success) {
    exit 5
}

exit 0

#endregion
