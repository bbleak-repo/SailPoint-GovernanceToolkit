#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App File Snapshot Manager
.DESCRIPTION
    Provides functions to store date-stamped copies of imported CSV files and
    retrieve the most recent previous snapshot for delta comparison. Handles
    snapshot retention cleanup.

    Functions:
        1. Save-SPDisconnectedAppSnapshot           - saves today's file as a date-stamped snapshot
        2. Get-SPDisconnectedAppPreviousSnapshot     - finds the most recent snapshot before today
        3. Remove-SPDisconnectedAppOldSnapshots      - deletes snapshots older than retention period

.NOTES
    Module: SP.DisconnectedAppSnapshot
    Version: 1.0.0
#>

#region Public Functions

function Save-SPDisconnectedAppSnapshot {
    <#
    .SYNOPSIS
        Saves a date-stamped copy of an imported CSV file to the snapshot directory.
    .DESCRIPTION
        Copies the current import file to {SnapshotDir}/{AppName}/{YYYY-MM-DD}-{FileType}.csv.
        Creates the app snapshot directory if it does not exist. Overwrites any existing
        snapshot for today's date (idempotent for re-runs).
    .PARAMETER FilePath
        Path to today's import file (accounts.csv or entitlements.csv).
    .PARAMETER AppName
        Application name (used as subdirectory name under SnapshotDir).
    .PARAMETER FileType
        Type of file: 'accounts' or 'entitlements'.
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to .\DisconnectedApps\Snapshots.
    .OUTPUTS
        [hashtable] @{Success; Data=<path to saved snapshot>; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateSet('accounts', 'entitlements')]
        [string]$FileType,

        [Parameter()]
        [string]$SnapshotDir = '.\DisconnectedApps\Snapshots'
    )

    # Validate source file exists
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Source file not found: $FilePath"
        }
    }

    try {
        # Build destination path
        $appDir = Join-Path -Path $SnapshotDir -ChildPath $AppName
        if (-not (Test-Path -Path $appDir)) {
            $null = New-Item -Path $appDir -ItemType Directory -Force
        }

        $dateStamp = (Get-Date).ToString('yyyy-MM-dd')
        $snapshotName = "${dateStamp}-${FileType}.csv"
        $destinationPath = Join-Path -Path $appDir -ChildPath $snapshotName

        Copy-Item -Path $FilePath -Destination $destinationPath -Force

        return @{
            Success = $true
            Data    = $destinationPath
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to save snapshot: $($_.Exception.Message)"
        }
    }
}

function Get-SPDisconnectedAppPreviousSnapshot {
    <#
    .SYNOPSIS
        Finds the most recent snapshot BEFORE today for the given app and file type.
    .DESCRIPTION
        Scans the snapshot directory for date-stamped CSV files matching the pattern
        {YYYY-MM-DD}-{FileType}.csv, excludes today's date, and returns the path
        to the most recent one. Returns $null in Data if no previous snapshot exists
        (first run scenario).
    .PARAMETER AppName
        Application name (subdirectory under SnapshotDir).
    .PARAMETER FileType
        Type of file: 'accounts' or 'entitlements'.
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to .\DisconnectedApps\Snapshots.
    .OUTPUTS
        [hashtable] @{Success; Data=<path or $null>; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateSet('accounts', 'entitlements')]
        [string]$FileType,

        [Parameter()]
        [string]$SnapshotDir = '.\DisconnectedApps\Snapshots'
    )

    $appDir = Join-Path -Path $SnapshotDir -ChildPath $AppName

    if (-not (Test-Path -Path $appDir)) {
        # No snapshot directory yet -- first run
        return @{
            Success = $true
            Data    = $null
            Error   = $null
        }
    }

    try {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $pattern = "*-${FileType}.csv"

        # Get all matching snapshot files
        $snapshots = @(Get-ChildItem -Path $appDir -Filter $pattern -File |
            Where-Object {
                # Parse the date prefix from filename (first 10 chars = YYYY-MM-DD)
                $datePart = $_.Name.Substring(0, 10)
                # Validate it looks like a date and is before today
                $datePart -match '^\d{4}-\d{2}-\d{2}$' -and $datePart -lt $today
            } |
            Sort-Object -Property Name -Descending)

        if ($snapshots.Count -eq 0) {
            # No previous snapshots found
            return @{
                Success = $true
                Data    = $null
                Error   = $null
            }
        }

        # Return the most recent (first after descending sort by name)
        return @{
            Success = $true
            Data    = $snapshots[0].FullName
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to find previous snapshot: $($_.Exception.Message)"
        }
    }
}

function Remove-SPDisconnectedAppOldSnapshots {
    <#
    .SYNOPSIS
        Deletes snapshots older than the retention period.
    .DESCRIPTION
        Scans the snapshot directory for a given app and removes any date-stamped
        CSV files whose date prefix is older than the specified retention period.
        Does not remove the directory itself even if empty after cleanup.
    .PARAMETER AppName
        Application name (subdirectory under SnapshotDir).
    .PARAMETER SnapshotDir
        Root snapshot directory. Defaults to .\DisconnectedApps\Snapshots.
    .PARAMETER RetentionDays
        Number of days to retain snapshots. Files older than this are deleted. Default 30.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Removed; Kept; Errors}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppName,

        [Parameter()]
        [string]$SnapshotDir = '.\DisconnectedApps\Snapshots',

        [Parameter()]
        [ValidateRange(1, 3650)]
        [int]$RetentionDays = 30
    )

    $appDir = Join-Path -Path $SnapshotDir -ChildPath $AppName

    if (-not (Test-Path -Path $appDir)) {
        return @{
            Success = $true
            Data    = @{ Removed = 0; Kept = 0; Errors = @() }
            Error   = $null
        }
    }

    try {
        $cutoffDate = (Get-Date).AddDays(-$RetentionDays).ToString('yyyy-MM-dd')
        $allFiles = @(Get-ChildItem -Path $appDir -Filter '*.csv' -File)
        $removed = 0
        $kept = 0
        $deleteErrors = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $allFiles) {
            # Extract date prefix (YYYY-MM-DD) from filename
            $datePart = $file.Name.Substring(0, 10)
            if ($datePart -notmatch '^\d{4}-\d{2}-\d{2}$') {
                # Not a date-stamped snapshot file, skip
                $kept++
                continue
            }

            if ($datePart -lt $cutoffDate) {
                try {
                    Remove-Item -Path $file.FullName -Force
                    $removed++
                }
                catch {
                    $deleteErrors.Add("Failed to delete $($file.Name): $($_.Exception.Message)")
                    $kept++
                }
            }
            else {
                $kept++
            }
        }

        $success = ($deleteErrors.Count -eq 0)
        return @{
            Success = $success
            Data    = @{
                Removed = $removed
                Kept    = $kept
                Errors  = $deleteErrors.ToArray()
            }
            Error   = if ($success) { $null } else { $deleteErrors -join '; ' }
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to clean up old snapshots: $($_.Exception.Message)"
        }
    }
}

#endregion
