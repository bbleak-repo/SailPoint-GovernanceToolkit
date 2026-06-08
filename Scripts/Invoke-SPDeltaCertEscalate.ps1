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
    Wall-clock hours since certification assignment with no reviewer action.
    Set to 0 to rely solely on -EscalateBeforeDeadlineHours.
    Defaults to DeltaCert.Escalation.DefaultStaleHours in settings.json (fallback: 24).
    TIP: For overnight campaigns (created 11pm, due 11pm+24h) with business-hours
    reviewers (6am-2pm), prefer -EscalateBeforeDeadlineHours 8 over -StaleHours 24.
    With -StaleHours 24 you'd only escalate at 11pm -- the deadline itself.
.PARAMETER EscalateBeforeDeadlineHours
    Escalate unsigned certifications whose campaign deadline is within this many
    hours. Use instead of (or alongside) StaleHours for campaigns with tight
    windows and reviewers who only work business hours.
    Example: -EscalateBeforeDeadlineHours 8 -StaleHours 0
      → runs at noon, finds campaigns due by 8pm, escalates anyone not signed off.
      → escalated reviewer has the remaining hours to act.
    Default: 0 (disabled -- StaleHours mode used).
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
    [int]$MaxEscalationLevels = 0,

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

Write-SPLog -Message "Invoke-SPDeltaCertEscalate started: Prefix='$effectivePrefix' StaleHours=$effectiveStaleHours MaxLevels=$effectiveMaxLevels" `
    -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Dispatch

$runStart = Get-Date

# WhatIf short-circuit: describe what would run
if (($WhatIfPreference -eq $true)) {
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Would run escalation with:' -ForegroundColor Cyan
    Write-Host "    CampaignPrefix:      $effectivePrefix"
    Write-Host "    StaleHours:          $effectiveStaleHours"
    Write-Host "    MaxEscalationLevels: $effectiveMaxLevels"
    Write-Host ''
}

$modeDesc = if ($EscalateBeforeDeadlineHours -gt 0 -and $effectiveStaleHours -gt 0) {
    "stale > $effectiveStaleHours h OR deadline within $EscalateBeforeDeadlineHours h"
} elseif ($EscalateBeforeDeadlineHours -gt 0) {
    "deadline within $EscalateBeforeDeadlineHours h"
} else {
    "stale > $effectiveStaleHours h"
}
Write-Host "  Detecting certifications needing escalation ($modeDesc)..." -ForegroundColor Cyan

# Step 1: Find stale/deadline-urgent certifications
$staleParams = @{
    CampaignNamePrefix           = $effectivePrefix
    StaleHours                   = $effectiveStaleHours
    EscalateBeforeDeadlineHours  = $EscalateBeforeDeadlineHours
    CorrelationID                = $correlationID
}
$staleResult = Get-SPDeltaCertStaleCertifications @staleParams

if (-not $staleResult.Success) {
    Write-Host "ERROR: Stale cert detection failed: $($staleResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Stale cert detection failed: $($staleResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPDeltaCertEscalate' -Action 'Detect' -CorrelationID $correlationID
    exit 5
}

$staleCerts = @($staleResult.Data)

if ($staleCerts.Count -eq 0) {
    Write-Host ''
    Write-Host '  No stale certifications found.' -ForegroundColor Yellow
    Write-Host "  Prefix:     $effectivePrefix" -ForegroundColor DarkGray
    Write-Host "  Threshold:  $effectiveStaleHours hours" -ForegroundColor DarkGray
    Write-Host ''

    Write-SPLog -Message "No stale certifications found" `
        -Severity INFO -Component 'Invoke-SPDeltaCertEscalate' -Action 'Detect' -CorrelationID $correlationID
    exit 1
}

Write-Host "  Found $($staleCerts.Count) stale certification(s). Escalating..." -ForegroundColor Cyan

# Step 2: Escalate stale certifications
$escalateResult = Invoke-SPDeltaCertEscalate `
    -StaleCertifications $staleCerts `
    -MaxEscalationLevels $effectiveMaxLevels `
    -CorrelationID $correlationID

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
        Timestamp           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        CorrelationID       = $correlationID
        Action              = 'DeltaCertEscalation'
        CampaignNamePrefix  = $effectivePrefix
        StaleHours          = $effectiveStaleHours
        MaxEscalationLevels = $effectiveMaxLevels
        StaleCertsFound     = $staleCerts.Count
        Escalated           = $escalatedIds.Count
        Skipped             = $skippedIds.Count
        Errors              = $errorMsgs
        WhatIf              = ($WhatIfPreference -eq $true)
        DurationSeconds     = [math]::Round($runDuration, 2)
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
    CorrelationID       = $correlationID
    StartedAt           = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt         = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds     = [math]::Round($runDuration, 2)
    CampaignNamePrefix  = $effectivePrefix
    StaleHours          = $effectiveStaleHours
    MaxEscalationLevels = $effectiveMaxLevels
    StaleCertsFound     = $staleCerts.Count
    Escalated           = $escalatedCount
    Skipped             = $skippedCount
    Errors              = $errorCount
    Success             = $escalateResult.Success
    Environment         = $config.Global.EnvironmentName
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
        Write-Host "  Stale certs found: $($staleCerts.Count)" -ForegroundColor DarkGray
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
