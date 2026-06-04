#Requires -Version 5.1
<#
.SYNOPSIS
    Lists, inspects, and shows schedules for SailPoint ISC campaign templates.
.DESCRIPTION
    CLI wrapper for the SP.Sdk campaign template functions. Supports three actions:

      - List:     List campaign templates with optional filters and sorters.
      - Get:      Get a single campaign template by ID, showing full details.
      - Schedule: Get the schedule for a specific campaign template.

    Uses the standard toolkit module chain: SP.Core -> SP.Api -> SP.Sdk.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Resolve-SPConfigPath.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials authentication entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER Filters
    ISC filter expression for List action (e.g. 'name co "quarterly"').
.PARAMETER Sorters
    Sort expression for List action. Supported fields: name, created, modified.
.PARAMETER Action
    The operation to perform: List (default), Get, or Schedule.
.PARAMETER TemplateId
    Campaign template ID. Required for Get and Schedule actions.
.PARAMETER OutputMode
    Output format: Console (default), JSON, or Both.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPSdkCampaignTemplates.ps1 -Action List
    # List all campaign templates.
.EXAMPLE
    .\Invoke-SPSdkCampaignTemplates.ps1 -Action List -Filters 'name co "quarterly"' -Sorters 'name'
    # List templates with name containing "quarterly", sorted by name.
.EXAMPLE
    .\Invoke-SPSdkCampaignTemplates.ps1 -Action Get -TemplateId 'tmpl-abc123'
    # Get full details for a specific template.
.EXAMPLE
    .\Invoke-SPSdkCampaignTemplates.ps1 -Action Schedule -TemplateId 'tmpl-abc123'
    # Show the schedule for a specific template.
.EXAMPLE
    .\Invoke-SPSdkCampaignTemplates.ps1 -Action List -Token 'eyJhbGciOiJSUzI1...'
    # List templates using a browser token.
.NOTES
    Script:  Invoke-SPSdkCampaignTemplates.ps1
    Version: 1.0.0
    Exit codes:
        0 = Completed successfully
        1 = No results matched
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
#>
[CmdletBinding()]
param(
    # --- Filters ---
    [Parameter()]
    [string]$Filters,

    [Parameter()]
    [string]$Sorters,

    # --- Action ---
    [Parameter()]
    [ValidateSet('List', 'Get', 'Schedule')]
    [string]$Action = 'List',

    [Parameter()]
    [string]$TemplateId,

    # --- Output ---
    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    # --- Standard ---
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

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

$coreModulePath = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath  = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$sdkModulePath  = Join-Path $toolkitRoot 'Modules\SP.Sdk\SP.Sdk.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath; Name = 'SP.Core'; Required = $true },
    @{ Path = $apiModulePath;  Name = 'SP.Api';  Required = $true },
    @{ Path = $sdkModulePath;  Name = 'SP.Sdk';  Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Parameter Validation

if ($Action -in @('Get', 'Schedule') -and [string]::IsNullOrWhiteSpace($TemplateId)) {
    Write-Host "ERROR: -TemplateId is required for Action '$Action'." -ForegroundColor Red
    exit 2
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Resolve config
if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

# Initialize logging (best-effort before config load)
try { Initialize-SPLogging -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Campaign Templates' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '${ConfigPath}': $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host 'INFO: First-run configuration detected. Update settings.json and run again.' -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host 'ERROR: Configuration validation failed. Check settings.json for required values.' -ForegroundColor Red
    exit 4
}

# Re-initialize logging with config
try { Initialize-SPLogging -Force -ErrorAction SilentlyContinue } catch { }

# Inject browser token if provided
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

Write-SPLog -Message 'Invoke-SPSdkCampaignTemplates started' `
    -Severity INFO -Component 'Invoke-SPSdkCampaignTemplates' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Execute

$startTime = Get-Date

switch ($Action) {
    'List' {
        Write-Host '  Listing campaign templates...' -ForegroundColor Gray

        $listParams = @{ CorrelationID = $correlationID }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) {
            $listParams['Filters'] = $Filters
        }
        if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
            $listParams['Sorters'] = $Sorters
        }

        $result = Get-SPSdkCampaignTemplates @listParams

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to list campaign templates: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $templates = @($result.Data)

        if ($templates.Count -eq 0) {
            Write-Host '  No campaign templates found.' -ForegroundColor Yellow
            exit 1
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        Write-Host "  Found $($templates.Count) template(s) ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  $('Template Name'.PadRight(35)) $('ID'.PadRight(38)) Modified"
            Write-Host "  $('-' * 85)"

            foreach ($tmpl in $templates) {
                $tName = "$($tmpl.name)".PadRight(35)
                if ($tName.Length -gt 35) { $tName = $tName.Substring(0, 32) + '...' }
                $tId = "$($tmpl.id)".PadRight(38)
                if ($tId.Length -gt 38) { $tId = $tId.Substring(0, 35) + '...' }
                $tModified = ''
                if ($null -ne $tmpl.modified) {
                    if ($tmpl.modified -is [datetime]) {
                        $tModified = ([datetime]$tmpl.modified).ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $parsedDate = [datetime]::MinValue
                        if ([datetime]::TryParse($tmpl.modified.ToString(), [ref]$parsedDate)) {
                            $tModified = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                        }
                        else {
                            $tModified = $tmpl.modified.ToString()
                        }
                    }
                }
                Write-Host "  $tName $tId $tModified"
            }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'List'
                ResultCount   = $templates.Count
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = $templates
            } | ConvertTo-Json -Depth 10
        }
    }

    'Get' {
        Write-Host "  Getting campaign template '$TemplateId'..." -ForegroundColor Gray

        $result = Get-SPSdkCampaignTemplate -TemplateId $TemplateId -CorrelationID $correlationID

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to get template: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $template = $result.Data

        if ($null -eq $template) {
            Write-Host "  Template '$TemplateId' not found." -ForegroundColor Yellow
            exit 1
        }

        # Also fetch the schedule
        $schedResult = Get-SPSdkTemplateSchedule -TemplateId $TemplateId -CorrelationID $correlationID

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        Write-Host "  Template retrieved ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  Name:        $($template.name)" -ForegroundColor White
            Write-Host "  ID:          $($template.id)"
            if ($null -ne $template.description) {
                Write-Host "  Description: $($template.description)"
            }
            if ($null -ne $template.created) {
                Write-Host "  Created:     $($template.created)"
            }
            if ($null -ne $template.modified) {
                Write-Host "  Modified:    $($template.modified)"
            }
            if ($null -ne $template.deadlineDuration) {
                Write-Host "  Deadline:    $($template.deadlineDuration)"
            }
            if ($null -ne $template.ownerRef) {
                Write-Host "  Owner:       $($template.ownerRef.name) ($($template.ownerRef.id))"
            }

            # Show campaign type if available
            if ($null -ne $template.campaign -and $null -ne $template.campaign.type) {
                Write-Host "  Camp. Type:  $($template.campaign.type)"
            }

            # Show schedule info
            Write-Host ''
            if ($schedResult.Success -and $null -ne $schedResult.Data) {
                $sched = $schedResult.Data
                Write-Host '  Schedule:' -ForegroundColor White
                if ($null -ne $sched.type)       { Write-Host "    Type:       $($sched.type)" }
                if ($null -ne $sched.hours)      { Write-Host "    Hours:      $($sched.hours | ConvertTo-Json -Compress)" }
                if ($null -ne $sched.days)       { Write-Host "    Days:       $($sched.days | ConvertTo-Json -Compress)" }
                if ($null -ne $sched.months)     { Write-Host "    Months:     $($sched.months | ConvertTo-Json -Compress)" }
                if ($null -ne $sched.timeZoneId) { Write-Host "    TimeZone:   $($sched.timeZoneId)" }
                if ($null -ne $sched.expiration) { Write-Host "    Expiration: $($sched.expiration)" }
            }
            else {
                Write-Host '  Schedule:    (none configured)' -ForegroundColor DarkGray
            }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'Get'
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = @{
                    Template = $template
                    Schedule = $schedResult.Data
                }
            } | ConvertTo-Json -Depth 10
        }
    }

    'Schedule' {
        Write-Host "  Getting schedule for template '$TemplateId'..." -ForegroundColor Gray

        $result = Get-SPSdkTemplateSchedule -TemplateId $TemplateId -CorrelationID $correlationID

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to get template schedule: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        if ($null -eq $result.Data) {
            Write-Host "  No schedule configured for template '$TemplateId'. ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Yellow

            if ($OutputMode -in @('JSON', 'Both')) {
                Write-Host ''
                @{
                    CorrelationID = $correlationID
                    Action        = 'Schedule'
                    ElapsedSec    = [Math]::Round($elapsed, 2)
                    Data          = $null
                } | ConvertTo-Json -Depth 10
            }

            exit 0
        }

        $sched = $result.Data

        Write-Host "  Schedule retrieved ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  Template ID: $TemplateId" -ForegroundColor White
            if ($null -ne $sched.type)       { Write-Host "  Type:        $($sched.type)" }
            if ($null -ne $sched.hours)      { Write-Host "  Hours:       $($sched.hours | ConvertTo-Json -Compress)" }
            if ($null -ne $sched.days)       { Write-Host "  Days:        $($sched.days | ConvertTo-Json -Compress)" }
            if ($null -ne $sched.months)     { Write-Host "  Months:      $($sched.months | ConvertTo-Json -Compress)" }
            if ($null -ne $sched.timeZoneId) { Write-Host "  TimeZone:    $($sched.timeZoneId)" }
            if ($null -ne $sched.expiration) { Write-Host "  Expiration:  $($sched.expiration)" }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'Schedule'
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = $sched
            } | ConvertTo-Json -Depth 10
        }
    }
}

#endregion

#region Completion

Write-Host ''
Write-SPLog -Message "Invoke-SPSdkCampaignTemplates completed (Action=$Action)" `
    -Severity INFO -Component 'Invoke-SPSdkCampaignTemplates' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
