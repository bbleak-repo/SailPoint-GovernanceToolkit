#Requires -Version 5.1
<#
.SYNOPSIS
    Lists and inspects SailPoint ISC workflows and their executions.
.DESCRIPTION
    CLI wrapper for the SP.Sdk workflow functions. Supports three actions:

      - List:       List workflows with optional filters.
      - Get:        Get a single workflow by ID, showing full details.
      - Executions: List execution history for a specific workflow.

    Uses the standard toolkit module chain: SP.Core -> SP.Api -> SP.Sdk.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Resolve-SPConfigPath.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials authentication entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER Filters
    ISC filter expression for List or Executions action.
    List supports: enabled, connectorInstanceId, triggerId.
    Executions supports: start_time, status.
.PARAMETER Action
    The operation to perform: List (default), Get, or Executions.
.PARAMETER WorkflowId
    Workflow ID. Required for Get and Executions actions.
.PARAMETER OutputMode
    Output format: Console (default), JSON, or Both.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPSdkWorkflows.ps1 -Action List
    # List all workflows.
.EXAMPLE
    .\Invoke-SPSdkWorkflows.ps1 -Action List -Filters 'enabled eq true'
    # List only enabled workflows.
.EXAMPLE
    .\Invoke-SPSdkWorkflows.ps1 -Action Get -WorkflowId 'wf-abc123'
    # Get full details for a specific workflow.
.EXAMPLE
    .\Invoke-SPSdkWorkflows.ps1 -Action Executions -WorkflowId 'wf-abc123'
    # Show execution history for a workflow.
.EXAMPLE
    .\Invoke-SPSdkWorkflows.ps1 -Action List -Token 'eyJhbGciOiJSUzI1...'
    # List workflows using a browser token.
.NOTES
    Script:  Invoke-SPSdkWorkflows.ps1
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

    # --- Action ---
    [Parameter()]
    [ValidateSet('List', 'Get', 'Executions')]
    [string]$Action = 'List',

    [Parameter()]
    [string]$WorkflowId,

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

if ($Action -in @('Get', 'Executions') -and [string]::IsNullOrWhiteSpace($WorkflowId)) {
    Write-Host "ERROR: -WorkflowId is required for Action '$Action'." -ForegroundColor Red
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
Write-Host '  Workflows' -ForegroundColor Cyan
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

Write-SPLog -Message 'Invoke-SPSdkWorkflows started' `
    -Severity INFO -Component 'Invoke-SPSdkWorkflows' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Execute

$startTime = Get-Date

switch ($Action) {
    'List' {
        Write-Host '  Listing workflows...' -ForegroundColor Gray

        $listParams = @{ CorrelationID = $correlationID }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) {
            $listParams['Filters'] = $Filters
        }

        $result = Get-SPSdkWorkflows @listParams

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to list workflows: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $workflows = @($result.Data)

        if ($workflows.Count -eq 0) {
            Write-Host '  No workflows found.' -ForegroundColor Yellow
            exit 1
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        Write-Host "  Found $($workflows.Count) workflow(s) ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  $('Workflow Name'.PadRight(35)) $('ID'.PadRight(38)) $('Enabled'.PadRight(9)) Modified"
            Write-Host "  $('-' * 92)"

            foreach ($wf in $workflows) {
                $wName = "$($wf.name)".PadRight(35)
                if ($wName.Length -gt 35) { $wName = $wName.Substring(0, 32) + '...' }
                $wId = "$($wf.id)".PadRight(38)
                if ($wId.Length -gt 38) { $wId = $wId.Substring(0, 35) + '...' }
                $wEnabled = if ($null -ne $wf.enabled) { "$($wf.enabled)".PadRight(9) } else { ''.PadRight(9) }
                $wModified = ''
                if ($null -ne $wf.modified) {
                    if ($wf.modified -is [datetime]) {
                        $wModified = ([datetime]$wf.modified).ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $parsedDate = [datetime]::MinValue
                        if ([datetime]::TryParse($wf.modified.ToString(), [ref]$parsedDate)) {
                            $wModified = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                        }
                        else {
                            $wModified = $wf.modified.ToString()
                        }
                    }
                }
                Write-Host "  $wName $wId $wEnabled $wModified"
            }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'List'
                ResultCount   = $workflows.Count
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = $workflows
            } | ConvertTo-Json -Depth 10
        }
    }

    'Get' {
        Write-Host "  Getting workflow '$WorkflowId'..." -ForegroundColor Gray

        $result = Get-SPSdkWorkflow -WorkflowId $WorkflowId -CorrelationID $correlationID

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to get workflow: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $workflow = $result.Data

        if ($null -eq $workflow) {
            Write-Host "  Workflow '$WorkflowId' not found." -ForegroundColor Yellow
            exit 1
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        Write-Host "  Workflow retrieved ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  Name:        $($workflow.name)" -ForegroundColor White
            Write-Host "  ID:          $($workflow.id)"
            if ($null -ne $workflow.description) {
                Write-Host "  Description: $($workflow.description)"
            }
            Write-Host "  Enabled:     $($workflow.enabled)"
            if ($null -ne $workflow.created) {
                Write-Host "  Created:     $($workflow.created)"
            }
            if ($null -ne $workflow.modified) {
                Write-Host "  Modified:    $($workflow.modified)"
            }
            if ($null -ne $workflow.owner) {
                $ownerName = if ($null -ne $workflow.owner.name) { $workflow.owner.name } else { $workflow.owner.id }
                Write-Host "  Owner:       $ownerName"
            }

            # Show trigger info
            if ($null -ne $workflow.trigger) {
                Write-Host ''
                Write-Host '  Trigger:' -ForegroundColor White
                if ($null -ne $workflow.trigger.type) {
                    Write-Host "    Type:      $($workflow.trigger.type)"
                }
                if ($null -ne $workflow.trigger.attributes) {
                    $trigAttrs = $workflow.trigger.attributes
                    if ($null -ne $trigAttrs.cronString) {
                        Write-Host "    Cron:      $($trigAttrs.cronString)"
                    }
                    if ($null -ne $trigAttrs.id) {
                        Write-Host "    TriggerID: $($trigAttrs.id)"
                    }
                }
            }

            # Show definition step count if available
            if ($null -ne $workflow.definition -and $null -ne $workflow.definition.steps) {
                $stepCount = 0
                if ($workflow.definition.steps -is [hashtable]) {
                    $stepCount = $workflow.definition.steps.Count
                }
                elseif ($workflow.definition.steps.PSObject.Properties) {
                    $stepCount = @($workflow.definition.steps.PSObject.Properties).Count
                }
                Write-Host "  Steps:       $stepCount"
            }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'Get'
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = $workflow
            } | ConvertTo-Json -Depth 10
        }
    }

    'Executions' {
        Write-Host "  Listing executions for workflow '$WorkflowId'..." -ForegroundColor Gray

        $execParams = @{
            WorkflowId    = $WorkflowId
            CorrelationID = $correlationID
        }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) {
            $execParams['Filters'] = $Filters
        }

        $result = Get-SPSdkWorkflowExecutions @execParams

        if (-not $result.Success) {
            Write-Host "ERROR: Failed to list workflow executions: $($result.Error)" -ForegroundColor Red
            exit 1
        }

        $executions = @($result.Data)

        if ($executions.Count -eq 0) {
            Write-Host '  No executions found for this workflow.' -ForegroundColor Yellow
            exit 1
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        Write-Host "  Found $($executions.Count) execution(s) ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
        Write-Host ''

        if ($OutputMode -in @('Console', 'Both')) {
            Write-Host "  $('Execution ID'.PadRight(38)) $('Status'.PadRight(12)) Started"
            Write-Host "  $('-' * 70)"

            foreach ($exec in $executions) {
                $eId = "$($exec.id)".PadRight(38)
                if ($eId.Length -gt 38) { $eId = $eId.Substring(0, 35) + '...' }
                $eStatus = if ($null -ne $exec.status) { "$($exec.status)".PadRight(12) } else { ''.PadRight(12) }
                $eStarted = ''
                if ($null -ne $exec.startTime) {
                    if ($exec.startTime -is [datetime]) {
                        $eStarted = ([datetime]$exec.startTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
                    }
                    else {
                        $parsedDate = [datetime]::MinValue
                        if ([datetime]::TryParse($exec.startTime.ToString(), [ref]$parsedDate)) {
                            $eStarted = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
                        }
                        else {
                            $eStarted = $exec.startTime.ToString()
                        }
                    }
                }
                Write-Host "  $eId $eStatus $eStarted"
            }
        }

        if ($OutputMode -in @('JSON', 'Both')) {
            Write-Host ''
            @{
                CorrelationID = $correlationID
                Action        = 'Executions'
                WorkflowId    = $WorkflowId
                ResultCount   = $executions.Count
                ElapsedSec    = [Math]::Round($elapsed, 2)
                Data          = $executions
            } | ConvertTo-Json -Depth 10
        }
    }
}

#endregion

#region Completion

Write-Host ''
Write-SPLog -Message "Invoke-SPSdkWorkflows completed (Action=$Action)" `
    -Severity INFO -Component 'Invoke-SPSdkWorkflows' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
