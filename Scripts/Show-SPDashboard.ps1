#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the SailPoint ISC Governance Toolkit WPF dashboard.
.DESCRIPTION
    Loads the SP.Core and SP.Gui modules, then calls Show-SPDashboard to display
    the WPF interactive interface. The dashboard provides campaign management,
    evidence review, and settings configuration through a tabbed UI.

    Requirements:
      - Windows with .NET Framework 4.5 or later (WPF)
      - PowerShell 5.1 Desktop edition (not Core/6+)
      - Configured settings.json (run Invoke-GovernanceTest.ps1 once to generate)
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the
    Scripts directory. Passed through to the GUI module.
.EXAMPLE
    .\Show-SPDashboard.ps1
    # Launch the GUI with default settings
.EXAMPLE
    .\Show-SPDashboard.ps1 -ConfigPath 'C:\Toolkit\Config\prod-settings.json'
    # Launch the GUI pointed at a specific configuration file
.NOTES
    Script:  Show-SPDashboard.ps1
    Version: 1.0.0
    Note:    WPF requires a Single-Threaded Apartment (STA) thread. This script
             detects the current apartment state and re-launches in STA if needed.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

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

#region STA Thread Check

# WPF requires STA. PowerShell ISE runs STA by default; console host is MTA.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host "  INFO: Relaunching in STA thread for WPF compatibility..." -ForegroundColor Cyan

    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        Write-Host "ERROR: Cannot determine script path for STA relaunch." -ForegroundColor Red
        exit 1
    }

    $relaunchArgs = @('-STA', '-NonInteractive', '-File', "`"$scriptPath`"")
    if ($ConfigPath) {
        $relaunchArgs += @('-ConfigPath', "`"$ConfigPath`"")
    }

    Start-Process powershell.exe -ArgumentList $relaunchArgs -Wait -NoNewWindow
    exit $LASTEXITCODE
}

#endregion

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$toolkitRoot = Split-Path -Parent $scriptRoot

$coreModulePath = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath  = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$guiModulePath  = Join-Path $toolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath; Name = 'SP.Core'; Required = $true },
    @{ Path = $apiModulePath;  Name = 'SP.Api';  Required = $true },
    @{ Path = $guiModulePath;  Name = 'SP.Gui';  Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop
    }
    else {
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 1
        }
    }
}

#endregion

#region Launch GUI

$dashboardParams = @{}
if ($ConfigPath) {
    $dashboardParams['ConfigPath'] = $ConfigPath
}

try {
    Show-SPDashboard @dashboardParams
}
catch {
    Write-Host ''
    Write-Host "ERROR: Dashboard failed to launch: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}

#endregion
