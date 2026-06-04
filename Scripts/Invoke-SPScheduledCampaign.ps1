#Requires -Version 5.1
<#
.SYNOPSIS
    Runs campaigns from saved templates on a recurring schedule.
.DESCRIPTION
    Reads campaign template JSON files, determines which are due based on cadence
    and last-run tracking, and creates certification campaigns for due templates.
    Designed for cron / scheduled task execution alongside the daily orchestrator.

    Execution steps:
      1. Load template(s) from Config/campaign-templates/
      2. Check last-run tracking via .schedule-state.json
      3. Load governance exceptions (if -ExcludeExceptions)
      4. Run due campaigns via Invoke-SPDeltaCertRun
      5. Update schedule state and produce summary

    Template JSON format (Config/campaign-templates/{name}.json):
      {
          "name": "quarterly-ad-review",
          "description": "Quarterly review of Corporate AD access",
          "cadence": "Quarterly",
          "sourceIds": ["src-ad-001"],
          "reviewerMode": "Manager",
          "hoursBack": 2160,
          "deadlineDays": 14,
          "campaignNamePrefix": "Q Review AD"
      }

.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to this script.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER TemplateName
    Run a specific template by name. If omitted, loads all templates and
    filters by cadence.
.PARAMETER Cadence
    Filter templates by cadence. Default: Quarterly.
    Only applies when TemplateName is not specified.
.PARAMETER MinDaysSinceLastRun
    Minimum days since a template was last run before it is considered due.
    Default: 80.
.PARAMETER ExcludeExceptions
    When set, loads the governance exception register and excludes identities
    with active exceptions from campaign scope.
.PARAMETER OutputMode
    Console (default), JSON, or Both.
.PARAMETER OutputPath
    Directory for output files. Defaults to DeltaCert output path from config.
.PARAMETER WhatIf
    Show which templates are due without creating campaigns.
.PARAMETER Help
    Display full help and exit.
.EXAMPLE
    .\Invoke-SPScheduledCampaign.ps1 -Cadence Quarterly -MinDaysSinceLastRun 80 -Token $token
.EXAMPLE
    .\Invoke-SPScheduledCampaign.ps1 -TemplateName 'quarterly-ad-review' -Token $token
.EXAMPLE
    .\Invoke-SPScheduledCampaign.ps1 -Cadence Monthly -ExcludeExceptions -WhatIf
.NOTES
    Script:  Invoke-SPScheduledCampaign.ps1
    Version: 1.0.0
    Exit codes:
        0 = All due campaigns run successfully (or none due)
        1 = One or more campaigns had warnings
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical campaign creation failure
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string]$TemplateName,

    # Schedule
    [Parameter()]
    [ValidateSet('Daily', 'Weekly', 'Monthly', 'Quarterly')]
    [string]$Cadence = 'Quarterly',

    [Parameter()]
    [int]$MinDaysSinceLastRun = 80,

    # Exception handling
    [Parameter()]
    [switch]$ExcludeExceptions,

    # Output
    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    # Safety
    [Parameter()]
    [switch]$WhatIf,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';           Name = 'SP.Core';     Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';             Name = 'SP.Api';      Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';         Name = 'SP.Audit';    Required = $false }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert'; Required = $true  }
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

$startTime     = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel    = $startTime.ToString('yyyy-MM-dd')
$exitCode      = 0

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Scheduled Campaign Runner' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

$config = $null
try {
    $config = Get-SPConfig
} catch {
    Write-Host "ERROR: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

# Token setup
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    try {
        Set-SPAuthToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -ErrorAction Stop
        Write-Host "  Auth:          Browser token set (${TokenExpiryMinutes}m expiry)" -ForegroundColor DarkGray
    } catch {
        Write-Host "ERROR: Failed to set auth token: $($_.Exception.Message)" -ForegroundColor Red
        exit 3
    }
}

# Resolve template directory
$templateDir = Join-Path $toolkitRoot 'Config\campaign-templates'
if ($null -ne $config -and $null -ne $config.PSObject.Properties['CampaignTemplates']) {
    $ct = $config.CampaignTemplates
    if ($null -ne $ct.PSObject.Properties['Path'] -and
        -not [string]::IsNullOrWhiteSpace($ct.Path)) {
        $templateDir = if ([System.IO.Path]::IsPathRooted($ct.Path)) {
            $ct.Path
        } else {
            Join-Path $toolkitRoot $ct.Path
        }
    }
}

# Resolve output directory
if (-not $OutputPath) {
    if ($null -ne $config -and $null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert.PSObject.Properties['OutputPath']) {
        $OutputPath = if ([System.IO.Path]::IsPathRooted($config.DeltaCert.OutputPath)) {
            $config.DeltaCert.OutputPath
        } else {
            Join-Path $toolkitRoot $config.DeltaCert.OutputPath
        }
    } else {
        $OutputPath = Join-Path $toolkitRoot 'DeltaCert'
    }
}

$scheduleStatePath = Join-Path $templateDir '.schedule-state.json'

#endregion

#region Step 1: Load Templates

Write-Host '--- Step 1: Load Templates ---' -ForegroundColor White

if (-not (Test-Path -Path $templateDir -PathType Container)) {
    Write-Host "  Template directory not found: $templateDir" -ForegroundColor Yellow
    Write-Host '  No templates to process. Create JSON files in Config/campaign-templates/' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Summary: 0 campaigns run, 0 skipped, 0 failed' -ForegroundColor Cyan
    exit 0
}

$templateFiles = Get-ChildItem -Path $templateDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.schedule-state.json' }

if (-not $templateFiles -or $templateFiles.Count -eq 0) {
    Write-Host '  No template files found.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Summary: 0 campaigns run, 0 skipped, 0 failed' -ForegroundColor Cyan
    exit 0
}

$templates = [System.Collections.Generic.List[hashtable]]::new()

foreach ($tf in $templateFiles) {
    try {
        $raw = Get-Content -Path $tf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        $tplName = if ($null -ne $raw.PSObject.Properties['name'] -and
                       -not [string]::IsNullOrWhiteSpace($raw.name)) {
            [string]$raw.name
        } else {
            [System.IO.Path]::GetFileNameWithoutExtension($tf.Name)
        }

        # Filter by TemplateName if specified
        if (-not [string]::IsNullOrWhiteSpace($TemplateName) -and $tplName -ne $TemplateName) {
            continue
        }

        # Filter by cadence if TemplateName not specified
        $tplCadence = if ($null -ne $raw.PSObject.Properties['cadence'] -and
                         -not [string]::IsNullOrWhiteSpace($raw.cadence)) {
            [string]$raw.cadence
        } else { 'Quarterly' }

        if ([string]::IsNullOrWhiteSpace($TemplateName) -and
            $tplCadence -ne $Cadence) {
            continue
        }

        $templates.Add(@{
            Name              = $tplName
            Description       = if ($null -ne $raw.PSObject.Properties['description'])       { [string]$raw.description }       else { '' }
            Cadence           = $tplCadence
            SourceIds         = if ($null -ne $raw.PSObject.Properties['sourceIds'])          { @($raw.sourceIds) }              else { @() }
            ReviewerMode      = if ($null -ne $raw.PSObject.Properties['reviewerMode'])       { [string]$raw.reviewerMode }      else { 'Manager' }
            HoursBack         = if ($null -ne $raw.PSObject.Properties['hoursBack'])          { [int]$raw.hoursBack }            else { 2160 }
            DeadlineDays      = if ($null -ne $raw.PSObject.Properties['deadlineDays'])       { [int]$raw.deadlineDays }         else { 14 }
            CampaignNamePrefix = if ($null -ne $raw.PSObject.Properties['campaignNamePrefix']) { [string]$raw.campaignNamePrefix } else { 'Scheduled Campaign' }
            FilePath          = $tf.FullName
        })
    }
    catch {
        Write-Host "  WARNING: Failed to parse template '$($tf.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        $exitCode = [Math]::Max($exitCode, 1)
    }
}

Write-Host "  Found $($templates.Count) template(s) matching criteria" -ForegroundColor DarkGray

if ($templates.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($TemplateName)) {
        Write-Host "  Template '$TemplateName' not found in $templateDir" -ForegroundColor Yellow
    } else {
        Write-Host "  No templates with cadence '$Cadence' found." -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Summary: 0 campaigns run, 0 skipped, 0 failed' -ForegroundColor Cyan
    exit 0
}

#endregion

#region Step 2: Check Last-Run Tracking

Write-Host '--- Step 2: Check Schedule State ---' -ForegroundColor White

$scheduleState = @{}
if (Test-Path -Path $scheduleStatePath -PathType Leaf) {
    try {
        $stateRaw = Get-Content -Path $scheduleStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($prop in $stateRaw.PSObject.Properties) {
            $scheduleState[$prop.Name] = @{
                lastRunDate     = if ($null -ne $prop.Value.PSObject.Properties['lastRunDate'])     { [string]$prop.Value.lastRunDate }     else { '' }
                lastCorrelationId = if ($null -ne $prop.Value.PSObject.Properties['lastCorrelationId']) { [string]$prop.Value.lastCorrelationId } else { '' }
                lastResult      = if ($null -ne $prop.Value.PSObject.Properties['lastResult'])      { [string]$prop.Value.lastResult }      else { '' }
                runCount        = if ($null -ne $prop.Value.PSObject.Properties['runCount'])         { [int]$prop.Value.runCount }           else { 0 }
            }
        }
        Write-Host "  Loaded schedule state: $($scheduleState.Count) entries" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  WARNING: Failed to read schedule state, treating all as never-run: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host '  No schedule state file found -- all templates treated as never-run' -ForegroundColor DarkGray
}

# Classify each template as DUE or SKIPPED
$nowUtc    = (Get-Date).ToUniversalTime()
$dueList   = [System.Collections.Generic.List[hashtable]]::new()
$skipList  = [System.Collections.Generic.List[hashtable]]::new()

foreach ($tpl in $templates) {
    $tplName   = $tpl.Name
    $lastRun   = $null
    $daysSince = -1

    if ($scheduleState.ContainsKey($tplName) -and
        -not [string]::IsNullOrWhiteSpace($scheduleState[$tplName].lastRunDate)) {
        try {
            $lastRun   = [datetime]::Parse($scheduleState[$tplName].lastRunDate).ToUniversalTime()
            $daysSince = [int][Math]::Floor(($nowUtc - $lastRun).TotalDays)
        } catch {
            $daysSince = -1
        }
    }

    if ($daysSince -ge 0 -and $daysSince -lt $MinDaysSinceLastRun) {
        $skipList.Add(@{
            Template   = $tpl
            DaysSince  = $daysSince
            LastRun    = $lastRun
            Reason     = 'too recent'
        })
    } else {
        $dueList.Add(@{
            Template   = $tpl
            DaysSince  = $daysSince
            LastRun    = $lastRun
        })
    }
}

Write-Host "  Due: $($dueList.Count) | Skipped: $($skipList.Count)" -ForegroundColor DarkGray

#endregion

#region Step 3: Load Exceptions

$exclusionIdentities = @{}

if ($ExcludeExceptions) {
    Write-Host '--- Step 3: Load Governance Exceptions ---' -ForegroundColor White

    try {
        if (Get-Command -Name Get-SPGovernanceExceptionList -ErrorAction SilentlyContinue) {
            $excResult = Get-SPGovernanceExceptionList -IncludeExpired:$false -CorrelationID $correlationID
            if ($excResult.Success -and $null -ne $excResult.Data) {
                foreach ($exc in @($excResult.Data)) {
                    $excIdentityId = ''
                    if ($exc -is [hashtable] -and $exc.ContainsKey('identityId')) {
                        $excIdentityId = $exc.identityId
                    } elseif ($null -ne $exc.PSObject -and $null -ne $exc.PSObject.Properties['identityId']) {
                        $excIdentityId = [string]$exc.identityId
                    }
                    if (-not [string]::IsNullOrWhiteSpace($excIdentityId)) {
                        $exclusionIdentities[$excIdentityId] = $true
                    }
                }
                Write-Host "  Loaded $($exclusionIdentities.Count) identity exclusion(s) from exception register" -ForegroundColor DarkGray
            } else {
                Write-Host '  No active exceptions found' -ForegroundColor DarkGray
            }
        } else {
            Write-Host '  WARNING: Get-SPGovernanceExceptionList not available -- skipping exception filter' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  WARNING: Failed to load exceptions: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host '--- Step 3: Exceptions ---' -ForegroundColor White
    Write-Host '  Skipped (-ExcludeExceptions not set)' -ForegroundColor DarkGray
}

#endregion

#region Step 4: Run Due Campaigns

Write-Host '--- Step 4: Run Campaigns ---' -ForegroundColor White

$runCount    = 0
$failCount   = 0
$results     = [System.Collections.Generic.List[hashtable]]::new()

foreach ($entry in $dueList) {
    $tpl       = $entry.Template
    $tplName   = $tpl.Name
    $daysSince = $entry.DaysSince
    $lastRun   = $entry.LastRun

    $lastRunDisplay = if ($null -ne $lastRun) {
        "$($lastRun.ToString('yyyy-MM-dd')) ($daysSince days ago)"
    } else { 'never' }

    Write-Host ''
    Write-Host "  Template: $tplName" -ForegroundColor White
    Write-Host "    Last Run:  $lastRunDisplay" -ForegroundColor DarkGray
    Write-Host "    Cadence:   $($tpl.Cadence) (MinDays: $MinDaysSinceLastRun)" -ForegroundColor DarkGray

    if ($WhatIf) {
        Write-Host '    Status:    DUE -- WhatIf (dry run, no campaigns created)' -ForegroundColor Yellow
        $results.Add(@{
            Template    = $tplName
            Status      = 'DUE'
            Action      = 'WhatIf'
            LastRun     = $lastRunDisplay
        })
        continue
    }

    Write-Host '    Status:    DUE -- running' -ForegroundColor Green

    try {
        # Build parameters for Invoke-SPDeltaCertRun
        $runParams = @{
            CorrelationID = $correlationID
        }

        if ($tpl.SourceIds.Count -gt 0) {
            $runParams['SourceIds'] = $tpl.SourceIds
        }
        if ($tpl.HoursBack -gt 0) {
            $runParams['HoursBack'] = $tpl.HoursBack
        }
        if ($tpl.DeadlineDays -gt 0) {
            $runParams['DeadlineDays'] = $tpl.DeadlineDays
        }
        if (-not [string]::IsNullOrWhiteSpace($tpl.CampaignNamePrefix)) {
            $runParams['CampaignNamePrefix'] = $tpl.CampaignNamePrefix
        }
        if (-not [string]::IsNullOrWhiteSpace($tpl.ReviewerMode)) {
            $runParams['ReviewerMode'] = $tpl.ReviewerMode
        }

        # Add ExcludeIdentityIds if exceptions loaded
        if ($exclusionIdentities.Count -gt 0) {
            $runParams['ExcludeIdentityIds'] = @($exclusionIdentities.Keys)
        }

        $campaignResult = Invoke-SPDeltaCertRun @runParams

        if ($campaignResult.Success) {
            $created   = if ($null -ne $campaignResult.Data) { $campaignResult.Data.CampaignsCreated } else { 0 }
            $idCount   = if ($null -ne $campaignResult.Data) { $campaignResult.Data.IdentityCount }    else { 0 }

            Write-Host "    Result:    Created $created campaigns for $idCount identities" -ForegroundColor Green

            if ($exclusionIdentities.Count -gt 0) {
                Write-Host "    Exceptions: $($exclusionIdentities.Count) identities excluded (active exceptions)" -ForegroundColor DarkGray
            }

            # Update schedule state
            $scheduleState[$tplName] = @{
                lastRunDate     = $nowUtc.ToString('o')
                lastCorrelationId = $correlationID
                lastResult      = 'Success'
                runCount        = if ($scheduleState.ContainsKey($tplName)) {
                    $scheduleState[$tplName].runCount + 1
                } else { 1 }
            }
            $runCount++

            $results.Add(@{
                Template         = $tplName
                Status           = 'DUE'
                Action           = 'Run'
                Result           = 'Success'
                CampaignsCreated = $created
                IdentityCount    = $idCount
                ExceptionsApplied = $exclusionIdentities.Count
                LastRun          = $lastRunDisplay
            })
        } else {
            $errDetail = if ($null -ne $campaignResult.Error) { $campaignResult.Error } else { 'Unknown error' }
            Write-Host "    Result:    FAILED -- $errDetail" -ForegroundColor Red
            $failCount++
            $exitCode = [Math]::Max($exitCode, 5)

            $scheduleState[$tplName] = @{
                lastRunDate     = if ($scheduleState.ContainsKey($tplName)) { $scheduleState[$tplName].lastRunDate } else { '' }
                lastCorrelationId = $correlationID
                lastResult      = "Failed: $errDetail"
                runCount        = if ($scheduleState.ContainsKey($tplName)) { $scheduleState[$tplName].runCount } else { 0 }
            }

            $results.Add(@{
                Template = $tplName
                Status   = 'DUE'
                Action   = 'Run'
                Result   = 'Failed'
                Error    = $errDetail
                LastRun  = $lastRunDisplay
            })
        }
    }
    catch {
        Write-Host "    Result:    FAILED -- $($_.Exception.Message)" -ForegroundColor Red
        $failCount++
        $exitCode = [Math]::Max($exitCode, 5)

        $results.Add(@{
            Template = $tplName
            Status   = 'DUE'
            Action   = 'Run'
            Result   = 'Failed'
            Error    = $_.Exception.Message
            LastRun  = $lastRunDisplay
        })
    }
}

# Show skipped templates
foreach ($entry in $skipList) {
    $tpl       = $entry.Template
    $tplName   = $tpl.Name
    $daysSince = $entry.DaysSince

    Write-Host ''
    Write-Host "  Template: $tplName" -ForegroundColor White
    Write-Host "    Last Run:  $($entry.LastRun.ToString('yyyy-MM-dd')) ($daysSince days ago)" -ForegroundColor DarkGray
    Write-Host "    Cadence:   $($tpl.Cadence) (MinDays: $MinDaysSinceLastRun)" -ForegroundColor DarkGray
    Write-Host '    Status:    SKIPPED -- too recent' -ForegroundColor Yellow

    $results.Add(@{
        Template  = $tplName
        Status    = 'SKIPPED'
        Reason    = 'too recent'
        DaysSince = $daysSince
        LastRun   = "$($entry.LastRun.ToString('yyyy-MM-dd')) ($daysSince days ago)"
    })
}

#endregion

#region Step 5: Save Schedule State and Summary

Write-Host ''
Write-Host '--- Step 5: Summary ---' -ForegroundColor White

# Write schedule state atomically
if (-not $WhatIf -and $scheduleState.Count -gt 0) {
    try {
        if (-not (Test-Path -Path $templateDir -PathType Container)) {
            New-Item -Path $templateDir -ItemType Directory -Force | Out-Null
        }

        $stateObj = [ordered]@{}
        foreach ($key in ($scheduleState.Keys | Sort-Object)) {
            $stateObj[$key] = [ordered]@{
                lastRunDate       = $scheduleState[$key].lastRunDate
                lastCorrelationId = $scheduleState[$key].lastCorrelationId
                lastResult        = $scheduleState[$key].lastResult
                runCount          = $scheduleState[$key].runCount
            }
        }

        $stateJson = $stateObj | ConvertTo-Json -Depth 4
        $tempPath  = "${scheduleStatePath}.tmp"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, $stateJson, $utf8NoBom)
        Move-Item -Path $tempPath -Destination $scheduleStatePath -Force
    }
    catch {
        Write-Host "  WARNING: Failed to save schedule state: $($_.Exception.Message)" -ForegroundColor Yellow
        $exitCode = [Math]::Max($exitCode, 1)
    }
}

$summaryLine = "Summary: $runCount campaigns run, $($skipList.Count) skipped, $failCount failed"
Write-Host ''
Write-Host "  $summaryLine" -ForegroundColor Cyan

# Elapsed
$elapsed = (Get-Date) - $startTime
Write-Host "  Elapsed: $([Math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
Write-Host ''

# JSON output
$jsonOutput = @{
    Timestamp     = $nowUtc.ToString('o')
    CorrelationID = $correlationID
    Cadence       = $Cadence
    MinDaysSinceLastRun = $MinDaysSinceLastRun
    ExcludeExceptions   = [bool]$ExcludeExceptions
    ExceptionCount      = $exclusionIdentities.Count
    WhatIf        = [bool]$WhatIf
    Results       = @($results)
    Summary       = @{
        Run     = $runCount
        Skipped = $skipList.Count
        Failed  = $failCount
    }
    ElapsedSeconds = [Math]::Round($elapsed.TotalSeconds, 1)
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $jsonOutput | ConvertTo-Json -Depth 5
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    try {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        $outFile  = Join-Path $OutputPath "scheduled-campaign-$todayLabel.json"
        $outJson  = $jsonOutput | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($outFile, $outJson, $utf8NoBom)
        Write-Host "  Output written: $outFile" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  WARNING: Failed to write output file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-SPLog -Message "Scheduled campaign runner complete: $summaryLine" `
    -Severity INFO -Component 'ScheduledCampaign' -Action 'Invoke-SPScheduledCampaign' `
    -CorrelationID $correlationID

#endregion

exit $exitCode
