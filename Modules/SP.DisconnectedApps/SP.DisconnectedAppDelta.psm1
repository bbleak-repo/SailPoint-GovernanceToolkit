#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Disconnected App Delta Detection Engine
.DESCRIPTION
    Compares today's account CSV file against a previous snapshot to identify all
    changes at the account and entitlement level. Detects added/removed accounts,
    enabled/disabled status changes, entitlement grants/revocations, and attribute
    changes.

    Functions:
        1. Compare-SPDisconnectedAppFiles - compares two account CSV files and returns structured deltas
        2. Test-SPDisconnectedAppDeletionThreshold - guards against mass-removal from bad files

.NOTES
    Module: SP.DisconnectedAppDelta
    Version: 1.1.0
#>

#region Internal Functions

function Split-GroupsValue {
    <#
    .SYNOPSIS
        Splits a comma-separated groups string into a trimmed array.
    .PARAMETER GroupsRaw
        Raw groups column value (Import-Csv already strips outer quotes).
    .OUTPUTS
        [string[]] Array of trimmed, non-empty group IDs.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$GroupsRaw
    )

    if ([string]::IsNullOrWhiteSpace($GroupsRaw)) {
        return @()
    }

    return @($GroupsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

#endregion

#region Public Functions

function Compare-SPDisconnectedAppFiles {
    <#
    .SYNOPSIS
        Compares today's account CSV against a previous snapshot and detects all deltas.
    .DESCRIPTION
        Parses both files with Import-Csv, builds hashtables keyed by account ID for
        O(1) lookup, and detects seven change types:
            - AccountAdded: ID in current but not in previous
            - AccountRemoved: ID in previous but not in current
            - AccountDisabled: IIQDisabled changed from false to true
            - AccountEnabled: IIQDisabled changed from true to false
            - EntitlementGranted: groups in current not in previous for same ID
            - EntitlementRevoked: groups in previous not in current for same ID
            - AttributeChanged: any other column changed (name, email, department)

        When no previous file exists (first run), all current accounts are treated
        as Added.
    .PARAMETER CurrentFilePath
        Path to today's account CSV file.
    .PARAMETER PreviousFilePath
        Path to the previous snapshot CSV file. Pass $null for first run.
    .PARAMETER IdColumn
        Column name used as the unique account identifier. Default: 'id'.
    .PARAMETER GroupsColumn
        Column name containing comma-separated entitlement IDs. Default: 'groups'.
    .OUTPUTS
        [hashtable] @{Success; Data=@{Added; Removed; Disabled; Enabled;
            GrantedEntitlements; RevokedEntitlements; AttributeChanges;
            Unchanged; Summary}; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentFilePath,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PreviousFilePath,

        [Parameter()]
        [string]$IdColumn = 'id',

        [Parameter()]
        [string]$GroupsColumn = 'groups'
    )

    # --- Validate current file ---
    if (-not (Test-Path -Path $CurrentFilePath -PathType Leaf)) {
        return @{
            Success = $false
            Data    = $null
            Error   = "Current file not found: $CurrentFilePath"
        }
    }

    # --- Parse current file ---
    try {
        $currentRows = @(Import-Csv -Path $CurrentFilePath -Encoding UTF8)
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to parse current file: $($_.Exception.Message)"
        }
    }

    # --- Parse previous file (or treat as empty for first run) ---
    $previousRows = @()
    $isFirstRun = [string]::IsNullOrWhiteSpace($PreviousFilePath)

    if (-not $isFirstRun) {
        if (-not (Test-Path -Path $PreviousFilePath -PathType Leaf)) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Previous file not found: $PreviousFilePath"
            }
        }

        try {
            $previousRows = @(Import-Csv -Path $PreviousFilePath -Encoding UTF8)
        }
        catch {
            return @{
                Success = $false
                Data    = $null
                Error   = "Failed to parse previous file: $($_.Exception.Message)"
            }
        }
    }

    try {
        # --- Build hashtables keyed by ID for O(1) lookup ---
        $currentById  = @{}
        foreach ($row in $currentRows) {
            $id = $row.$IdColumn
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $currentById[$id] = $row
            }
        }

        $previousById = @{}
        foreach ($row in $previousRows) {
            $id = $row.$IdColumn
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $previousById[$id] = $row
            }
        }

        # --- Detect columns to compare for attribute changes ---
        # Exclude the ID column and groups column (handled separately)
        $compareColumns = @()
        if ($currentRows.Count -gt 0) {
            $compareColumns = @($currentRows[0].PSObject.Properties.Name |
                Where-Object { $_ -ne $IdColumn -and $_ -ne $GroupsColumn -and $_ -ne 'IIQDisabled' })
        }

        # --- Initialize result collections ---
        $added              = [System.Collections.Generic.List[hashtable]]::new()
        $removed            = [System.Collections.Generic.List[hashtable]]::new()
        $disabled           = [System.Collections.Generic.List[hashtable]]::new()
        $enabled            = [System.Collections.Generic.List[hashtable]]::new()
        $grantedEntitlements = [System.Collections.Generic.List[hashtable]]::new()
        $revokedEntitlements = [System.Collections.Generic.List[hashtable]]::new()
        $attributeChanges   = [System.Collections.Generic.List[hashtable]]::new()
        $unchangedCount     = 0

        # --- Process current accounts ---
        foreach ($id in $currentById.Keys) {
            $currentRow = $currentById[$id]

            if (-not $previousById.ContainsKey($id)) {
                # AccountAdded: new account not in previous
                $newGroups = Split-GroupsValue -GroupsRaw $currentRow.$GroupsColumn
                $added.Add(@{
                    Account   = $currentRow
                    NewGroups = $newGroups
                })
                continue
            }

            # Account exists in both files -- check for changes
            $previousRow = $previousById[$id]
            $accountChanged = $false

            # --- Status changes (IIQDisabled) ---
            $currentDisabled  = $currentRow.IIQDisabled
            $previousDisabled = $previousRow.IIQDisabled
            if ($null -ne $currentDisabled -and $null -ne $previousDisabled) {
                $curDisVal  = $currentDisabled.Trim().ToLower()
                $prevDisVal = $previousDisabled.Trim().ToLower()

                if ($prevDisVal -eq 'false' -and $curDisVal -eq 'true') {
                    $disabled.Add(@{ Account = $currentRow })
                    $accountChanged = $true
                }
                elseif ($prevDisVal -eq 'true' -and $curDisVal -eq 'false') {
                    $enabled.Add(@{ Account = $currentRow })
                    $accountChanged = $true
                }
            }

            # --- Entitlement changes ---
            $currentGroups  = Split-GroupsValue -GroupsRaw $currentRow.$GroupsColumn
            $previousGroups = Split-GroupsValue -GroupsRaw $previousRow.$GroupsColumn

            # Build sets for O(1) comparison
            $currentGroupSet  = @{}
            foreach ($g in $currentGroups)  { $currentGroupSet[$g] = $true }
            $previousGroupSet = @{}
            foreach ($g in $previousGroups) { $previousGroupSet[$g] = $true }

            # Granted: in current but not in previous
            $granted = @($currentGroups | Where-Object { -not $previousGroupSet.ContainsKey($_) })
            if ($granted.Count -gt 0) {
                $grantedEntitlements.Add(@{
                    AccountId    = $id
                    AccountEmail = $currentRow.'e-mail'
                    Entitlements = $granted
                })
                $accountChanged = $true
            }

            # Revoked: in previous but not in current
            $revoked = @($previousGroups | Where-Object { -not $currentGroupSet.ContainsKey($_) })
            if ($revoked.Count -gt 0) {
                $revokedEntitlements.Add(@{
                    AccountId    = $id
                    AccountEmail = $currentRow.'e-mail'
                    Entitlements = $revoked
                })
                $accountChanged = $true
            }

            # --- Attribute changes (non-groups, non-status columns) ---
            foreach ($col in $compareColumns) {
                $currentVal  = [string]$currentRow.$col
                $previousVal = [string]$previousRow.$col
                if ($currentVal -ne $previousVal) {
                    $attributeChanges.Add(@{
                        AccountId = $id
                        Field     = $col
                        OldValue  = $previousVal
                        NewValue  = $currentVal
                    })
                    $accountChanged = $true
                }
            }

            if (-not $accountChanged) {
                $unchangedCount++
            }
        }

        # --- Process removed accounts (in previous but not in current) ---
        foreach ($id in $previousById.Keys) {
            if (-not $currentById.ContainsKey($id)) {
                $removed.Add(@{ Account = $previousById[$id] })
            }
        }

        # --- Build summary ---
        $summary = @{
            TotalCurrent        = $currentById.Count
            TotalPrevious       = $previousById.Count
            Added               = $added.Count
            Removed             = $removed.Count
            Disabled            = $disabled.Count
            Enabled             = $enabled.Count
            EntitlementsGranted = $grantedEntitlements.Count
            EntitlementsRevoked = $revokedEntitlements.Count
            AttributeChanges   = $attributeChanges.Count
            Unchanged           = $unchangedCount
        }

        return @{
            Success = $true
            Data    = @{
                Added               = $added.ToArray()
                Removed             = $removed.ToArray()
                Disabled            = $disabled.ToArray()
                Enabled             = $enabled.ToArray()
                GrantedEntitlements = $grantedEntitlements.ToArray()
                RevokedEntitlements = $revokedEntitlements.ToArray()
                AttributeChanges   = $attributeChanges.ToArray()
                Unchanged           = $unchangedCount
                Summary             = $summary
            }
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Delta comparison failed: $($_.Exception.Message)"
        }
    }
}

function Test-SPDisconnectedAppDeletionThreshold {
    <#
    .SYNOPSIS
        Checks whether the percentage of removed accounts exceeds a safety threshold.
    .DESCRIPTION
        Prevents a bad file (empty, partial export, wrong app's data) from triggering
        mass-removal campaigns. Compares removed account count from the delta summary
        against the configured threshold percentage.

        Exceptions (always allowed):
        - First run (TotalPrevious = 0): no baseline to compare against
        - TotalPrevious < 5: too few accounts for percentage to be meaningful

    .PARAMETER DeltaSummary
        The Summary hashtable from Compare-SPDisconnectedAppFiles output
        (i.e., $deltaResult.Data.Summary). Must contain TotalPrevious and Removed keys.
    .PARAMETER ThresholdPct
        Maximum allowed removal percentage (0-100). Default: 20.
    .OUTPUTS
        [hashtable] @{Allowed; RemovedPct; RemovedCount; TotalPrevious; ThresholdPct; Reason}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DeltaSummary,

        [Parameter()]
        [int]$ThresholdPct = 20
    )

    $totalPrevious = 0
    if ($null -ne $DeltaSummary['TotalPrevious']) {
        $totalPrevious = [int]$DeltaSummary['TotalPrevious']
    }

    $removedCount = 0
    if ($null -ne $DeltaSummary['Removed']) {
        $removedCount = [int]$DeltaSummary['Removed']
    }

    # First run -- no previous file, always allow
    if ($totalPrevious -eq 0) {
        return @{
            Allowed       = $true
            RemovedPct    = [double]0
            RemovedCount  = $removedCount
            TotalPrevious = $totalPrevious
            ThresholdPct  = $ThresholdPct
            Reason        = 'FirstRun'
        }
    }

    # Too few accounts for percentage to be meaningful
    if ($totalPrevious -lt 5) {
        return @{
            Allowed       = $true
            RemovedPct    = [double]0
            RemovedCount  = $removedCount
            TotalPrevious = $totalPrevious
            ThresholdPct  = $ThresholdPct
            Reason        = 'TooFewAccounts'
        }
    }

    $removedPct = [math]::Round(($removedCount / $totalPrevious) * 100, 1)

    if ($removedPct -gt $ThresholdPct) {
        return @{
            Allowed       = $false
            RemovedPct    = $removedPct
            RemovedCount  = $removedCount
            TotalPrevious = $totalPrevious
            ThresholdPct  = $ThresholdPct
            Reason        = 'ThresholdExceeded'
        }
    }

    return @{
        Allowed       = $true
        RemovedPct    = $removedPct
        RemovedCount  = $removedCount
        TotalPrevious = $totalPrevious
        ThresholdPct  = $ThresholdPct
        Reason        = 'OK'
    }
}

#endregion
