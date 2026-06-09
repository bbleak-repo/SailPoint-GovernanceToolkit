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
    Prefix used to find delta cert campaigns. Defaults to the
    DeltaCert.Escalation.CampaignNamePrefix value in settings.json
    (fallback: 'AD Delta Cert').
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
    Maximum number of escalation hops from the original reviewer.
    Defaults to DeltaCert.Escalation.MaxEscalationLevels in settings.json
    (fallback: 2).
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
    containing one row per certification found, with the full reviewer → skip-level chain
    resolved. Columns include: CampaignName, CampaignStatus, CertificationId,
    ReviewerName, ReviewerIdentityId, SkipLevelName, SkipLevelIdentityId, SkipLevelResolved,
    HoursOpen, HoursUntilDeadline, EscalationReason, CertSigned, Outcome.
    Works in both -WhatIf and live modes. Combines well with -DaysBack for a full
    30-day org chart audit report: -DaysBack 30 -WhatIf -Csv
.PARAMETER CsvPath
    Override the auto-generated CSV path. When specified alongside -Csv, writes the
    CSV to this exact path instead of the auto-generated one in DeltaCert.OutputPath.
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
    # Org chart audit: show the reviewer->skip-level chain for ALL certs in last 30 days.
    # Validates that ISC can resolve the skip-level for every reviewer. No write calls.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -DaysBack 30 -WhatIf -Csv
    # Org chart audit + CSV report: all chain data in a reviewable spreadsheet.
.EXAMPLE
    .\Invoke-SPDeltaCertEscalate.ps1 -CampaignNamePrefix 'Daily Attestation' -DaysBack 30 -WhatIf -Csv
    # Org chart audit against a peer's campaign name prefix with CSV output.
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
    [int]$StaleHours = 0,

    [Parameter()]
    [int]$EscalateBeforeDeadlineHours = 0,

    [Parameter()]
    [int]$DaysBack = 0,

    [Parameter()]
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
        $effectiveMaxLevels = 2
    }
}

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
        Write-Host '  Each reviewer is resolved to their skip-level to validate ISC manager chains.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Would run escalation with:' -ForegroundColor Cyan
    }
    Write-Host "    CampaignPrefix:              $effectivePrefix"
    Write-Host "    StaleHours:                  $effectiveStaleHours"
    if ($EscalateBeforeDeadlineHours -gt 0) {
        Write-Host "    EscalateBeforeDeadlineHours: $EscalateBeforeDeadlineHours"
    }
    if ($DaysBack -gt 0) {
        Write-Host "    DaysBack:                    $DaysBack  (all campaign statuses)"
    }
    Write-Host "    MaxEscalationLevels:         $effectiveMaxLevels"
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

$staleResult = Get-SPDeltaCertStaleCertifications @staleParams

if (-not $staleResult.Success) {
    Write-Host "ERROR: Stale cert detection failed: $($staleResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Stale cert detection failed: $($staleResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDeltaCertEscalate' -Action 'Detect' -CorrelationID $correlationID
    exit 5
}

$staleCerts = @($staleResult.Data)

#region CSV output (built before runner so -WhatIf and -Csv can co-exist)

$effectiveCsvPath = $CsvPath   # hoisted so the JSONL audit block can reference it

if (($Csv.IsPresent -or -not [string]::IsNullOrWhiteSpace($CsvPath)) -and $staleCerts.Count -gt 0) {

    # Resolve output path
    $effectiveCsvPath = $CsvPath
    if ([string]::IsNullOrWhiteSpace($effectiveCsvPath)) {
        $csvOutputDir = '.\DeltaCert'
        if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
            $null -ne $config.DeltaCert -and
            $null -ne $config.DeltaCert.PSObject.Properties['OutputPath'] -and
            -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
            $csvOutputDir = [string]$config.DeltaCert.OutputPath
        }
        if (-not (Test-Path -LiteralPath $csvOutputDir -PathType Container)) {
            New-Item -Path $csvOutputDir -ItemType Directory -Force | Out-Null
        }
        $csvStamp           = (Get-Date -Format 'yyyyMMdd-HHmmss')
        $effectiveCsvPath   = Join-Path $csvOutputDir "escalation-audit-$csvStamp.csv"
    }

    Write-Host "  Building CSV org chain report..." -ForegroundColor Cyan

    $csvRows = [System.Collections.Generic.List[object]]::new()

    foreach ($sc in $staleCerts) {
        $reviewerId  = $sc.ReviewerIdentityId
        $skipName    = ''
        $skipId      = ''
        $skipFound   = $false
        $outcome     = 'Pending'

        # Determine skip-level (reviewer's manager) — same resolution the runner uses
        if (-not [string]::IsNullOrWhiteSpace($reviewerId)) {
            try {
                $detail = Get-SPDeltaIdentityDetail -IdentityId $reviewerId -CorrelationID $correlationID
                if ($detail.Found -and -not [string]::IsNullOrWhiteSpace($detail.ManagerId)) {
                    $skipId    = $detail.ManagerId
                    $skipFound = $true
                    try {
                        $mgDetail  = Get-SPDeltaIdentityDetail -IdentityId $detail.ManagerId -CorrelationID $correlationID
                        $skipName  = if ($mgDetail.Found) { $mgDetail.DisplayName } else { $detail.ManagerId }
                    } catch { $skipName = $detail.ManagerId }
                }
            } catch { }
        }

        # Determine what would/did happen
        $levelsConsumed  = if ($sc.ReviewerClassification -eq 'Reassigned') { 1 } else { 0 }
        $levelsRemaining = $effectiveMaxLevels - $levelsConsumed

        if ([string]::IsNullOrWhiteSpace($reviewerId)) {
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

        $csvRows.Add([PSCustomObject]@{
            CampaignName         = $sc.CampaignName
            CampaignStatus       = $sc.CampaignStatus
            CertificationId      = $sc.CertificationId
            ReviewerName         = $sc.ReviewerName
            ReviewerIdentityId   = $sc.ReviewerIdentityId
            Classification       = $sc.ReviewerClassification
            SkipLevelName        = $skipName
            SkipLevelIdentityId  = $skipId
            SkipLevelResolved    = $skipFound
            HoursOpen            = $sc.HoursOpen
            HoursUntilDeadline   = $sc.HoursUntilDeadline
            EscalationReason     = $sc.EscalationReason
            CertSigned           = $sc.CertSigned
            Outcome              = $outcome
        })
    }

    try {
        $csvRows | Export-Csv -LiteralPath $effectiveCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  CSV written: $effectiveCsvPath ($($csvRows.Count) row(s))" -ForegroundColor Green
        Write-SPLog -Message "Escalation audit CSV written: $effectiveCsvPath ($($csvRows.Count) rows)" `
            -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'CsvOutput' `
            -CorrelationID $correlationID
    }
    catch {
        Write-Host "  WARNING: Failed to write CSV: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Failed to write escalation audit CSV '$effectiveCsvPath': $($_.Exception.Message)" `
            -Severity WARN -Component 'Invoke-SPDeltaCertEscalate' -Action 'CsvOutput' `
            -CorrelationID $correlationID
    }
    Write-Host ''
}

#endregion

if ($staleCerts.Count -eq 0) {
    Write-Host ''
    if ($DaysBack -gt 0) {
        Write-Host '  No certifications found in audit window.' -ForegroundColor Yellow
        Write-Host "  Prefix:   $effectivePrefix" -ForegroundColor DarkGray
        Write-Host "  DaysBack: $DaysBack days" -ForegroundColor DarkGray
    }
    else {
        Write-Host '  No stale certifications found.' -ForegroundColor Yellow
        Write-Host "  Prefix:     $effectivePrefix" -ForegroundColor DarkGray
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
        New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
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
