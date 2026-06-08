#Requires -Version 5.1
<#
.SYNOPSIS
    Lists work items with summary from SailPoint ISC.
.DESCRIPTION
    CLI wrapper for the SP.Sdk work item functions. Shows the work items summary
    (open, completed, total counts) followed by a listing of work items.

    By default shows open work items. Use -ShowCompleted to show completed items
    instead. Optionally filter by owner identity ID.

    Uses the standard toolkit module chain: SP.Core -> SP.Api -> SP.Sdk.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Resolve-SPConfigPath.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials authentication entirely.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER OwnerId
    Filter work items by owner identity ID. When omitted, returns all work items
    visible to the authenticated user.
.PARAMETER ShowCompleted
    When specified, shows completed work items instead of open ones.
.PARAMETER OutputMode
    Output format: Console (default), JSON, or Both.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPSdkWorkItems.ps1
    # Show work items summary and list open items.
.EXAMPLE
    .\Invoke-SPSdkWorkItems.ps1 -OwnerId 'id-mgr-001'
    # Show work items owned by a specific identity.
.EXAMPLE
    .\Invoke-SPSdkWorkItems.ps1 -ShowCompleted
    # Show completed work items.
.EXAMPLE
    .\Invoke-SPSdkWorkItems.ps1 -Token 'eyJhbGciOiJSUzI1...' -OutputMode Both
    # Use browser token and output both console and JSON.
.NOTES
    Script:  Invoke-SPSdkWorkItems.ps1
    Version: 1.0.0
    Exit codes:
        0 = Completed successfully
        1 = No results matched
        2 = Parameter validation error
        3 = Authentication error
        4 = Configuration error
#>
[CmdletBinding()]
param(
    # --- Filters ---
    [Parameter()]
    [string]$OwnerId,

    [Parameter()]
    [switch]$ShowCompleted,

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
Write-Host '  Work Items' -ForegroundColor Cyan
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

Write-SPLog -Message 'Invoke-SPSdkWorkItems started' `
    -Severity INFO -Component 'Invoke-SPSdkWorkItems' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Execute

$startTime = Get-Date

# --- Step 1: Get work items summary ---
Write-Host '  Fetching work items summary...' -ForegroundColor Gray

$summaryParams = @{ CorrelationID = $correlationID }
if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
    $summaryParams['OwnerId'] = $OwnerId
}

$summaryResult = Get-SPSdkWorkItemsSummary @summaryParams

if (-not $summaryResult.Success) {
    Write-Host "ERROR: Failed to get work items summary: $($summaryResult.Error)" -ForegroundColor Red
    if ($summaryResult.Error -match '403|forbidden') {
        Write-Host ''
        Write-Host '  SCOPE: This endpoint requires the idn:work-item:read scope (or sp:scopes:all).' -ForegroundColor Yellow
        Write-Host '  Fix:   ISC Admin Console → Security Settings → Personal Access Tokens → edit your token → add sp:scopes:all' -ForegroundColor Yellow
        Write-Host '         Then re-run New-SPVault.ps1 with the new ClientSecret.' -ForegroundColor Yellow
    }
    exit 1
}

$summary = $summaryResult.Data

# --- Step 2: List work items ---
$listLabel = if ($ShowCompleted) { 'completed' } else { 'open' }
Write-Host "  Listing $listLabel work items..." -ForegroundColor Gray

$listParams = @{ CorrelationID = $correlationID }
if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
    $listParams['OwnerId'] = $OwnerId
}

if ($ShowCompleted) {
    $listResult = Get-SPSdkCompletedWorkItems @listParams
}
else {
    $listResult = Get-SPSdkWorkItems @listParams
}

if (-not $listResult.Success) {
    Write-Host "ERROR: Failed to list work items: $($listResult.Error)" -ForegroundColor Red
    if ($listResult.Error -match '403|forbidden') {
        Write-Host ''
        Write-Host '  SCOPE: This endpoint requires the idn:work-item:read scope (or sp:scopes:all).' -ForegroundColor Yellow
        Write-Host '  Fix:   ISC Admin Console → Security Settings → Personal Access Tokens → edit your token → add sp:scopes:all' -ForegroundColor Yellow
        Write-Host '         Then re-run New-SPVault.ps1 with the new ClientSecret.' -ForegroundColor Yellow
    }
    exit 1
}

$items = @($listResult.Data)
$elapsed = ((Get-Date) - $startTime).TotalSeconds

Write-Host "  Found $($items.Count) $listLabel work item(s) ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Green
Write-Host ''

#endregion

#region Output

if ($OutputMode -in @('Console', 'Both')) {
    # Summary section
    Write-Host '  Work Items Summary' -ForegroundColor White
    Write-Host "  $('-' * 40)"
    if ($null -ne $summary) {
        $openCount = if ($null -ne $summary.open) { $summary.open } else { 'N/A' }
        $completedCount = if ($null -ne $summary.completed) { $summary.completed } else { 'N/A' }
        $totalCount = if ($null -ne $summary.total) { $summary.total } else { 'N/A' }
        Write-Host "  Open:      $openCount"
        Write-Host "  Completed: $completedCount"
        Write-Host "  Total:     $totalCount"
    }
    else {
        Write-Host '  (summary data unavailable)'
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        Write-Host "  Owner:     $OwnerId"
    }
    Write-Host ''

    # Items table
    if ($items.Count -gt 0) {
        Write-Host "  $('Type'.PadRight(20)) $('ID'.PadRight(38)) $('Created'.PadRight(12)) State"
        Write-Host "  $('-' * 80)"

        foreach ($item in $items) {
            $iType = if ($null -ne $item.type) { "$($item.type)".PadRight(20) } else { ''.PadRight(20) }
            if ($iType.Length -gt 20) { $iType = $iType.Substring(0, 17) + '...' }
            $iId = "$($item.id)".PadRight(38)
            if ($iId.Length -gt 38) { $iId = $iId.Substring(0, 35) + '...' }
            $iCreated = ''
            if ($null -ne $item.created) {
                if ($item.created -is [datetime]) {
                    $iCreated = ([datetime]$item.created).ToUniversalTime().ToString('yyyy-MM-dd')
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($item.created.ToString(), [ref]$parsedDate)) {
                        $iCreated = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $iCreated = $item.created.ToString()
                    }
                }
            }
            $iCreated = $iCreated.PadRight(12)
            $iState = if ($null -ne $item.state) { $item.state } else { '' }
            Write-Host "  $iType $iId $iCreated $iState"
        }
    }
    else {
        Write-Host "  No $listLabel work items found." -ForegroundColor Yellow
    }
}

if ($OutputMode -in @('JSON', 'Both')) {
    Write-Host ''
    @{
        CorrelationID = $correlationID
        Mode          = $listLabel
        Summary       = $summary
        ResultCount   = $items.Count
        ElapsedSec    = [Math]::Round($elapsed, 2)
        Data          = $items
    } | ConvertTo-Json -Depth 10
}

#endregion

#region Completion

Write-Host ''
Write-SPLog -Message "Invoke-SPSdkWorkItems completed ($listLabel, $($items.Count) items, ${elapsed}s)" `
    -Severity INFO -Component 'Invoke-SPSdkWorkItems' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
