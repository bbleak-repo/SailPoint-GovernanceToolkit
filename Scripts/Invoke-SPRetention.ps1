#Requires -Version 5.1
<#
.SYNOPSIS
    Runs log and report retention cleanup on toolkit output directories.
.DESCRIPTION
    Standalone CLI entry point for Invoke-SPLogRetention. Archives files older
    than ArchiveDays into monthly ZIP files, then deletes archive ZIPs older
    than DeleteDays. Only processes known toolkit file extensions (.html, .csv,
    .jsonl, .txt, .log, .json).

    By default, reads retention settings from the Retention section in
    settings.json. All parameters can be overridden on the command line.
    Retention.Enabled must be true in config OR explicit -ArchiveDays /
    -DeleteDays must be provided for any action to occur.

    Use -WhatIf to preview what would be archived and deleted without making
    changes.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to
    the Scripts directory.
.PARAMETER ArchiveDays
    Files older than this many days are archived. Minimum 7.
    Overrides Retention.ArchiveDays in config.
.PARAMETER DeleteDays
    Archive ZIPs older than this many days are deleted. Minimum 30.
    Must be greater than ArchiveDays. Overrides Retention.DeleteDays in config.
.PARAMETER ArchivePath
    Directory for archive ZIPs. Created if absent.
    Overrides Retention.ArchivePath in config.
.PARAMETER Paths
    Array of directory names (relative to toolkit root) to process.
    Overrides Retention.Paths in config.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPRetention.ps1 -WhatIf
    # Preview retention actions without making changes.
.EXAMPLE
    .\Invoke-SPRetention.ps1 -ArchiveDays 30 -DeleteDays 90
    # Run retention with explicit thresholds (overrides config).
.EXAMPLE
    .\Invoke-SPRetention.ps1 -OutputMode JSON
    # Run retention and output results as JSON.
.EXAMPLE
    .\Invoke-SPRetention.ps1 -Paths @('Audit','DeltaCert','Logs','Reports')
    # Run retention on specific directories.
.NOTES
    Script:  Invoke-SPRetention.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success
        1 = Retention disabled (no action taken)
        2 = Parameter / validation error
        4 = Configuration error
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [int]$ArchiveDays,

    [Parameter()]
    [int]$DeleteDays,

    [Parameter()]
    [string]$ArchivePath,

    [Parameter()]
    [string[]]$Paths,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';   Name = 'SP.Core';  Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'; Name = 'SP.Audit'; Required = $true }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue
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
Write-Host '  Log & Report Retention' -ForegroundColor Cyan
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

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

Write-SPLog -Message 'Invoke-SPRetention CLI started' `
    -Severity INFO -Component 'Invoke-SPRetention' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Run Retention

$runStart = Get-Date
$isWhatIf = $WhatIfPreference -eq $true

$retentionParams = @{
    CorrelationID = $correlationID
}
if ($isWhatIf) { $retentionParams['WhatIf'] = $true }
if ($PSBoundParameters.ContainsKey('ArchiveDays') -and $ArchiveDays -gt 0) {
    $retentionParams['ArchiveDays'] = $ArchiveDays
}
if ($PSBoundParameters.ContainsKey('DeleteDays') -and $DeleteDays -gt 0) {
    $retentionParams['DeleteDays'] = $DeleteDays
}
if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
    $retentionParams['ArchivePath'] = $ArchivePath
}
if ($null -ne $Paths -and $Paths.Count -gt 0) {
    $retentionParams['Paths'] = $Paths
}

if ($isWhatIf) {
    Write-Host '  [WhatIf] Dry-run mode enabled. No files will be modified.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host '  Running retention cleanup...' -ForegroundColor Cyan

try {
    $retentionResult = Invoke-SPLogRetention @retentionParams
}
catch {
    Write-Host "ERROR: Retention failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-SPLog -Message "Invoke-SPRetention failed: $($_.Exception.Message)" `
        -Severity ERROR -Component 'Invoke-SPRetention' -Action 'Execute' -CorrelationID $correlationID
    exit 2
}

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

#endregion

#region Output

if (-not $retentionResult.Success) {
    Write-Host "ERROR: Retention returned error: $($retentionResult.Data.Error)" -ForegroundColor Red
    Write-SPLog -Message "Invoke-SPRetention error: $($retentionResult.Data.Error)" `
        -Severity ERROR -Component 'Invoke-SPRetention' -Action 'Execute' -CorrelationID $correlationID
    exit 2
}

$archived = 0
$deleted  = 0
$skipped  = 0
$archiveList = @()
$deleteList  = @()
$skipReasons = @()

if ($null -ne $retentionResult.Data) {
    if ($null -ne $retentionResult.Data.Archived) {
        $archived    = $retentionResult.Data.Archived.FileCount
        $archiveList = @($retentionResult.Data.Archived.Archives)
    }
    if ($null -ne $retentionResult.Data.Deleted) {
        $deleted    = $retentionResult.Data.Deleted.FileCount
        $deleteList = @($retentionResult.Data.Deleted.Files)
    }
    if ($null -ne $retentionResult.Data.Skipped) {
        $skipped     = $retentionResult.Data.Skipped.FileCount
        $skipReasons = @($retentionResult.Data.Skipped.Reasons)
    }
}

$noAction = ($archived -eq 0 -and $deleted -eq 0 -and $skipped -eq 0)

$summary = [PSCustomObject]@{
    CorrelationID   = $correlationID
    StartedAt       = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt     = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds = [math]::Round($runDuration, 2)
    WhatIf          = $isWhatIf
    Archived        = $archived
    Deleted         = $deleted
    Skipped         = $skipped
    Archives        = $archiveList
    DeletedFiles    = $deleteList
    SkipReasons     = $skipReasons
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        Write-Host '  Retention Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        if ($isWhatIf) {
            Write-Host '  Mode:              WhatIf (no changes made)' -ForegroundColor Yellow
        }
        Write-Host "  Files archived:    $archived" -ForegroundColor $(if ($archived -gt 0) { 'Green' } else { 'DarkGray' })
        Write-Host "  Archives deleted:  $deleted" -ForegroundColor $(if ($deleted -gt 0) { 'Yellow' } else { 'DarkGray' })
        Write-Host "  Files skipped:     $skipped" -ForegroundColor $(if ($skipped -gt 0) { 'Yellow' } else { 'DarkGray' })

        if ($archiveList.Count -gt 0) {
            Write-Host ''
            Write-Host '  Archive files:' -ForegroundColor Cyan
            foreach ($a in $archiveList) {
                Write-Host "    $a" -ForegroundColor DarkCyan
            }
        }

        if ($skipReasons.Count -gt 0) {
            Write-Host ''
            Write-Host '  Skip reasons:' -ForegroundColor Yellow
            foreach ($r in $skipReasons) {
                Write-Host "    $r" -ForegroundColor DarkGray
            }
        }

        if ($noAction) {
            Write-Host ''
            Write-Host '  No files matched retention criteria (or Retention.Enabled is false).' -ForegroundColor DarkGray
        }

        Write-Host ''
        Write-Host "  Duration:      $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $summary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPRetention completed: Archived=$archived Deleted=$deleted Skipped=$skipped WhatIf=$isWhatIf" `
    -Severity INFO -Component 'Invoke-SPRetention' -Action 'Complete' -CorrelationID $correlationID

if ($noAction) {
    exit 1
}

exit 0

#endregion
