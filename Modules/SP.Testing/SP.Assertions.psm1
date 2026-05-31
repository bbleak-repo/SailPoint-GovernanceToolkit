#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Test Assertions
.DESCRIPTION
    Pass/fail evaluation functions for campaign test steps.
    Each assertion returns a consistent hashtable with Pass, Actual, Expected,
    and Message fields for use in step result recording and evidence writing.
.NOTES
    Module: SP.Testing / SP.Assertions
    Version: 1.0.0
    Component: Test Orchestration
#>

#region Assertion Functions

function Assert-SPCampaignStatus {
    <#
    .SYNOPSIS
        Assert that a campaign's current status matches the expected value.
    .DESCRIPTION
        Calls Get-SPCampaign to retrieve current campaign state and compares
        the status field against the expected value.
    .PARAMETER CampaignId
        The ISC campaign ID to check.
    .PARAMETER ExpectedStatus
        The status string expected (e.g., ACTIVE, COMPLETED).
    .PARAMETER CorrelationID
        Correlation ID for logging and tracing.
    .PARAMETER CampaignTestId
        Test case ID for log correlation.
    .OUTPUTS
        @{Pass=$true/$false; Actual="ACTIVE"; Expected="ACTIVE"; Message="..."}
    .EXAMPLE
        $result = Assert-SPCampaignStatus -CampaignId "camp-123" -ExpectedStatus "COMPLETED"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CampaignId,

        [Parameter(Mandatory)]
        [string]$ExpectedStatus,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    try {
        if (-not (Get-Command -Name Get-SPCampaign -ErrorAction SilentlyContinue)) {
            return @{
                Pass     = $false
                Actual   = $null
                Expected = $ExpectedStatus
                Message  = "Get-SPCampaign function not available - SP.Api module not loaded"
            }
        }

        $params = @{ CampaignId = $CampaignId }
        if ($CorrelationID)   { $params['CorrelationID']   = $CorrelationID }
        if ($CampaignTestId)  { $params['CampaignTestId']  = $CampaignTestId }

        $result = Get-SPCampaign @params

        if (-not $result.Success) {
            return @{
                Pass     = $false
                Actual   = $null
                Expected = $ExpectedStatus
                Message  = "Get-SPCampaign failed: $($result.Error)"
            }
        }

        $actualStatus = $result.Data.status
        if ([string]::IsNullOrWhiteSpace($actualStatus) -and $result.Data.PSObject.Properties.Name -contains 'Status') {
            $actualStatus = $result.Data.Status
        }
        $actualStatus = "$actualStatus".Trim().ToUpper()
        $expectedUpper = $ExpectedStatus.Trim().ToUpper()

        if ($actualStatus -eq $expectedUpper) {
            return @{
                Pass     = $true
                Actual   = $actualStatus
                Expected = $expectedUpper
                Message  = "Campaign status matches expected: $actualStatus"
            }
        }
        else {
            return @{
                Pass     = $false
                Actual   = $actualStatus
                Expected = $expectedUpper
                Message  = "Campaign status mismatch: expected '$expectedUpper', got '$actualStatus'"
            }
        }
    }
    catch {
        return @{
            Pass     = $false
            Actual   = $null
            Expected = $ExpectedStatus
            Message  = "Assert-SPCampaignStatus threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPCertificationCount {
    <#
    .SYNOPSIS
        Assert that a campaign has at least a minimum number of certifications.
    .DESCRIPTION
        Calls Get-SPAllCertifications and verifies the count meets or exceeds
        the MinimumCount threshold.
    .PARAMETER CampaignId
        The ISC campaign ID to check.
    .PARAMETER MinimumCount
        Minimum number of certifications expected. Defaults to 1.
    .PARAMETER CorrelationID
        Correlation ID for logging and tracing.
    .PARAMETER CampaignTestId
        Test case ID for log correlation.
    .OUTPUTS
        @{Pass=$true/$false; Actual=$count; Message="..."}
    .EXAMPLE
        $result = Assert-SPCertificationCount -CampaignId "camp-123" -MinimumCount 1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CampaignId,

        [Parameter()]
        [int]$MinimumCount = 1,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    try {
        if (-not (Get-Command -Name Get-SPAllCertifications -ErrorAction SilentlyContinue)) {
            return @{
                Pass    = $false
                Actual  = 0
                Message = "Get-SPAllCertifications function not available - SP.Api module not loaded"
            }
        }

        $params = @{ CampaignId = $CampaignId }
        if ($CorrelationID)  { $params['CorrelationID']  = $CorrelationID }
        if ($CampaignTestId) { $params['CampaignTestId'] = $CampaignTestId }

        $result = Get-SPAllCertifications @params

        if (-not $result.Success) {
            return @{
                Pass    = $false
                Actual  = 0
                Message = "Get-SPAllCertifications failed: $($result.Error)"
            }
        }

        $certArray = $result.Data
        $actualCount = 0
        if ($null -ne $certArray) {
            $actualCount = @($certArray).Count
        }

        if ($actualCount -ge $MinimumCount) {
            return @{
                Pass    = $true
                Actual  = $actualCount
                Message = "Certification count $actualCount meets minimum of $MinimumCount"
            }
        }
        else {
            return @{
                Pass    = $false
                Actual  = $actualCount
                Message = "Certification count $actualCount is below minimum of $MinimumCount"
            }
        }
    }
    catch {
        return @{
            Pass    = $false
            Actual  = 0
            Message = "Assert-SPCertificationCount threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPDecisionAccepted {
    <#
    .SYNOPSIS
        Assert that a bulk-decide operation produced the expected total decision count.
    .DESCRIPTION
        Inspects the result hashtable from Invoke-SPBulkDecide and verifies that
        TotalDecided matches the ExpectedTotal.
    .PARAMETER BulkDecideResult
        The result hashtable returned by Invoke-SPBulkDecide.
    .PARAMETER ExpectedTotal
        The number of decisions expected to have been accepted.
    .OUTPUTS
        @{Pass=$true/$false; Actual=$decidedCount; Message="..."}
    .EXAMPLE
        $result = Assert-SPDecisionAccepted -BulkDecideResult $decideResult -ExpectedTotal 25
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$BulkDecideResult,

        [Parameter(Mandatory)]
        [int]$ExpectedTotal
    )

    try {
        if (-not $BulkDecideResult.Success) {
            return @{
                Pass    = $false
                Actual  = 0
                Message = "BulkDecide operation was not successful: $($BulkDecideResult.Error)"
            }
        }

        $totalDecided = 0
        if ($null -ne $BulkDecideResult.Data -and
            $BulkDecideResult.Data.PSObject.Properties.Name -contains 'TotalDecided') {
            $totalDecided = [int]$BulkDecideResult.Data.TotalDecided
        }
        elseif ($null -ne $BulkDecideResult.Data -and
                $BulkDecideResult.Data -is [hashtable] -and
                $BulkDecideResult.Data.ContainsKey('TotalDecided')) {
            $totalDecided = [int]$BulkDecideResult.Data.TotalDecided
        }

        if ($totalDecided -eq $ExpectedTotal) {
            return @{
                Pass    = $true
                Actual  = $totalDecided
                Message = "BulkDecide accepted $totalDecided decisions, matching expected total of $ExpectedTotal"
            }
        }
        else {
            return @{
                Pass    = $false
                Actual  = $totalDecided
                Message = "BulkDecide accepted $totalDecided decisions, expected $ExpectedTotal"
            }
        }
    }
    catch {
        return @{
            Pass    = $false
            Actual  = 0
            Message = "Assert-SPDecisionAccepted threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPRemediationComplete {
    <#
    .SYNOPSIS
        Assert that all access review items in a remediation report are remediated.
    .DESCRIPTION
        Parses remediation report data to count remediated vs pending items.
        Passes when PendingCount is zero.
    .PARAMETER ReportData
        Hashtable containing remediation report data.
        Expected keys: RemediatedItems (array), PendingItems (array).
        Falls back to TotalItems/RemediatedCount integer fields.
    .OUTPUTS
        @{Pass=$true/$false; RemediatedCount=$n; PendingCount=$n; Message="..."}
    .EXAMPLE
        $result = Assert-SPRemediationComplete -ReportData $reportData
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReportData
    )

    try {
        $remediatedCount = 0
        $pendingCount    = 0

        # Support both array-based and count-based report structures
        if ($ReportData.ContainsKey('RemediatedItems') -and $ReportData.ContainsKey('PendingItems')) {
            $remediatedCount = if ($null -ne $ReportData.RemediatedItems) { @($ReportData.RemediatedItems).Count } else { 0 }
            $pendingCount    = if ($null -ne $ReportData.PendingItems) { @($ReportData.PendingItems).Count } else { 0 }
        }
        elseif ($ReportData.ContainsKey('RemediatedCount') -and $ReportData.ContainsKey('TotalItems')) {
            $remediatedCount = [int]$ReportData.RemediatedCount
            $totalItems      = [int]$ReportData.TotalItems
            $pendingCount    = $totalItems - $remediatedCount
            if ($pendingCount -lt 0) { $pendingCount = 0 }
        }
        elseif ($ReportData.ContainsKey('RemediatedCount')) {
            $remediatedCount = [int]$ReportData.RemediatedCount
            $pendingCount    = if ($ReportData.ContainsKey('PendingCount')) { [int]$ReportData.PendingCount } else { 0 }
        }
        else {
            return @{
                Pass            = $false
                RemediatedCount = 0
                PendingCount    = 0
                Message         = "ReportData does not contain recognizable remediation fields"
            }
        }

        if ($pendingCount -eq 0) {
            return @{
                Pass            = $true
                RemediatedCount = $remediatedCount
                PendingCount    = 0
                Message         = "All $remediatedCount items remediated, none pending"
            }
        }
        else {
            return @{
                Pass            = $false
                RemediatedCount = $remediatedCount
                PendingCount    = $pendingCount
                Message         = "$remediatedCount items remediated, $pendingCount items still pending"
            }
        }
    }
    catch {
        return @{
            Pass            = $false
            RemediatedCount = 0
            PendingCount    = 0
            Message         = "Assert-SPRemediationComplete threw exception: $($_.Exception.Message)"
        }
    }
}

#endregion

#region DeltaCert Assertions

function Assert-SPDeltaGrantEventCount {
    <#
    .SYNOPSIS
        Assert that a delta grant event query returned the expected number of events.
    .DESCRIPTION
        Validates the result hashtable from Get-SPDeltaGrantEvents. Checks that
        the query succeeded and the event count meets or exceeds MinimumCount.
    .PARAMETER GrantEventResult
        The result hashtable returned by Get-SPDeltaGrantEvents.
        Expected keys: Success, Data (array of events), Error.
    .PARAMETER MinimumCount
        Minimum number of grant events expected. Defaults to 1.
    .OUTPUTS
        @{Pass=$true/$false; Actual=$count; Expected=$min; Message="..."}
    .EXAMPLE
        $result = Assert-SPDeltaGrantEventCount -GrantEventResult $events -MinimumCount 5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$GrantEventResult,

        [Parameter()]
        [int]$MinimumCount = 1
    )

    try {
        if (-not $GrantEventResult.Success) {
            return @{
                Pass     = $false
                Actual   = 0
                Expected = $MinimumCount
                Message  = "Get-SPDeltaGrantEvents failed: $($GrantEventResult.Error)"
            }
        }

        $actualCount = 0
        if ($null -ne $GrantEventResult.Data) {
            $actualCount = @($GrantEventResult.Data).Count
        }

        if ($actualCount -ge $MinimumCount) {
            return @{
                Pass     = $true
                Actual   = $actualCount
                Expected = $MinimumCount
                Message  = "Grant event count $actualCount meets minimum of $MinimumCount"
            }
        }
        else {
            return @{
                Pass     = $false
                Actual   = $actualCount
                Expected = $MinimumCount
                Message  = "Grant event count $actualCount is below minimum of $MinimumCount"
            }
        }
    }
    catch {
        return @{
            Pass     = $false
            Actual   = 0
            Expected = $MinimumCount
            Message  = "Assert-SPDeltaGrantEventCount threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPDeltaManagerGrouping {
    <#
    .SYNOPSIS
        Assert that delta cert identities were grouped by manager correctly.
    .DESCRIPTION
        Validates the result from Group-SPDeltaByManager. Checks that the
        grouping succeeded and the number of manager groups meets expectations.
    .PARAMETER GroupResult
        The result hashtable from Group-SPDeltaByManager.
        Expected keys: Success, Data (hashtable keyed by manager ID), Error.
    .PARAMETER MinimumGroups
        Minimum number of manager groups expected. Defaults to 1.
    .PARAMETER MaximumGroups
        Maximum number of manager groups allowed. 0 means no upper limit. Defaults to 0.
    .OUTPUTS
        @{Pass=$true/$false; Actual=$groupCount; Message="..."}
    .EXAMPLE
        $result = Assert-SPDeltaManagerGrouping -GroupResult $groups -MinimumGroups 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$GroupResult,

        [Parameter()]
        [int]$MinimumGroups = 1,

        [Parameter()]
        [int]$MaximumGroups = 0
    )

    try {
        if (-not $GroupResult.Success) {
            return @{
                Pass    = $false
                Actual  = 0
                Message = "Group-SPDeltaByManager failed: $($GroupResult.Error)"
            }
        }

        $groupCount = 0
        if ($null -ne $GroupResult.Data) {
            if ($GroupResult.Data -is [hashtable]) {
                $groupCount = $GroupResult.Data.Count
            }
            else {
                $groupCount = @($GroupResult.Data).Count
            }
        }

        if ($groupCount -lt $MinimumGroups) {
            return @{
                Pass    = $false
                Actual  = $groupCount
                Message = "Manager group count $groupCount is below minimum of $MinimumGroups"
            }
        }

        if ($MaximumGroups -gt 0 -and $groupCount -gt $MaximumGroups) {
            return @{
                Pass    = $false
                Actual  = $groupCount
                Message = "Manager group count $groupCount exceeds maximum of $MaximumGroups"
            }
        }

        return @{
            Pass    = $true
            Actual  = $groupCount
            Message = "Manager group count $groupCount is within expected range"
        }
    }
    catch {
        return @{
            Pass    = $false
            Actual  = 0
            Message = "Assert-SPDeltaManagerGrouping threw exception: $($_.Exception.Message)"
        }
    }
}

#endregion

#region DisconnectedApps Assertions

function Assert-SPDisconnectedAppFileValid {
    <#
    .SYNOPSIS
        Assert that a disconnected app CSV file passed validation.
    .DESCRIPTION
        Validates the result from Test-SPDisconnectedAppAccountFile or
        Test-SPDisconnectedAppEntitlementFile. Checks that the validation
        succeeded with no errors.
    .PARAMETER ValidationResult
        The result hashtable from the file validation function.
        Expected keys: Success, Data (with Errors/Warnings arrays), Error.
    .PARAMETER MaxWarnings
        Maximum number of warnings allowed before failing. Defaults to 10.
    .OUTPUTS
        @{Pass=$true/$false; ErrorCount=$n; WarningCount=$n; Message="..."}
    .EXAMPLE
        $result = Assert-SPDisconnectedAppFileValid -ValidationResult $valResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ValidationResult,

        [Parameter()]
        [int]$MaxWarnings = 10
    )

    try {
        if (-not $ValidationResult.Success) {
            $errorMsg = if ($ValidationResult.Error) { $ValidationResult.Error } else { 'Validation failed' }
            $errorCount = 0
            $warningCount = 0

            if ($null -ne $ValidationResult.Data) {
                if ($ValidationResult.Data -is [hashtable]) {
                    if ($ValidationResult.Data.ContainsKey('Errors'))   { $errorCount   = @($ValidationResult.Data.Errors).Count }
                    if ($ValidationResult.Data.ContainsKey('Warnings')) { $warningCount  = @($ValidationResult.Data.Warnings).Count }
                }
                elseif ($ValidationResult.Data.PSObject.Properties.Name -contains 'Errors') {
                    $errorCount  = @($ValidationResult.Data.Errors).Count
                    $warningCount = if ($ValidationResult.Data.PSObject.Properties.Name -contains 'Warnings') { @($ValidationResult.Data.Warnings).Count } else { 0 }
                }
            }

            return @{
                Pass         = $false
                ErrorCount   = $errorCount
                WarningCount = $warningCount
                Message      = "File validation failed: $errorMsg (Errors=$errorCount, Warnings=$warningCount)"
            }
        }

        $warningCount = 0
        if ($null -ne $ValidationResult.Data) {
            if ($ValidationResult.Data -is [hashtable] -and $ValidationResult.Data.ContainsKey('Warnings')) {
                $warningCount = @($ValidationResult.Data.Warnings).Count
            }
            elseif ($null -ne $ValidationResult.Data.PSObject -and $ValidationResult.Data.PSObject.Properties.Name -contains 'Warnings') {
                $warningCount = @($ValidationResult.Data.Warnings).Count
            }
        }

        if ($warningCount -gt $MaxWarnings) {
            return @{
                Pass         = $false
                ErrorCount   = 0
                WarningCount = $warningCount
                Message      = "File validation passed but warning count $warningCount exceeds maximum of $MaxWarnings"
            }
        }

        return @{
            Pass         = $true
            ErrorCount   = 0
            WarningCount = $warningCount
            Message      = "File validation passed with $warningCount warning(s)"
        }
    }
    catch {
        return @{
            Pass         = $false
            ErrorCount   = 0
            WarningCount = 0
            Message      = "Assert-SPDisconnectedAppFileValid threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPDisconnectedAppDeltaDetected {
    <#
    .SYNOPSIS
        Assert that a disconnected app delta comparison found expected changes.
    .DESCRIPTION
        Validates the result from Compare-SPDisconnectedAppFiles. Checks that
        changes were detected and optionally validates specific change counts.
    .PARAMETER DeltaResult
        The result hashtable from Compare-SPDisconnectedAppFiles.
        Expected keys: Success, Data (with Added/Removed/Modified arrays), Error.
    .PARAMETER ExpectChanges
        If true (default), at least one change must be present. If false,
        zero changes is considered passing.
    .OUTPUTS
        @{Pass=$true/$false; Added=$n; Removed=$n; Modified=$n; Message="..."}
    .EXAMPLE
        $result = Assert-SPDisconnectedAppDeltaDetected -DeltaResult $delta
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$DeltaResult,

        [Parameter()]
        [bool]$ExpectChanges = $true
    )

    try {
        if (-not $DeltaResult.Success) {
            return @{
                Pass     = $false
                Added    = 0
                Removed  = 0
                Modified = 0
                Message  = "Compare-SPDisconnectedAppFiles failed: $($DeltaResult.Error)"
            }
        }

        $added    = 0
        $removed  = 0
        $modified = 0

        if ($null -ne $DeltaResult.Data) {
            $data = $DeltaResult.Data
            if ($data -is [hashtable]) {
                if ($data.ContainsKey('Added'))    { $added    = @($data.Added).Count }
                if ($data.ContainsKey('Removed'))  { $removed  = @($data.Removed).Count }
                if ($data.ContainsKey('Modified')) { $modified = @($data.Modified).Count }
            }
            else {
                if ($data.PSObject.Properties.Name -contains 'Added')    { $added    = @($data.Added).Count }
                if ($data.PSObject.Properties.Name -contains 'Removed')  { $removed  = @($data.Removed).Count }
                if ($data.PSObject.Properties.Name -contains 'Modified') { $modified = @($data.Modified).Count }
            }
        }

        $totalChanges = $added + $removed + $modified

        if ($ExpectChanges -and $totalChanges -eq 0) {
            return @{
                Pass     = $false
                Added    = $added
                Removed  = $removed
                Modified = $modified
                Message  = "Expected changes but delta comparison found none"
            }
        }

        if (-not $ExpectChanges -and $totalChanges -gt 0) {
            return @{
                Pass     = $false
                Added    = $added
                Removed  = $removed
                Modified = $modified
                Message  = "Expected no changes but found $totalChanges (Added=$added, Removed=$removed, Modified=$modified)"
            }
        }

        return @{
            Pass     = $true
            Added    = $added
            Removed  = $removed
            Modified = $modified
            Message  = "Delta comparison: Added=$added, Removed=$removed, Modified=$modified (total=$totalChanges)"
        }
    }
    catch {
        return @{
            Pass     = $false
            Added    = 0
            Removed  = 0
            Modified = 0
            Message  = "Assert-SPDisconnectedAppDeltaDetected threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPDeletionThresholdSafe {
    <#
    .SYNOPSIS
        Assert that a disconnected app deletion threshold check passed.
    .DESCRIPTION
        Validates the result from Test-SPDisconnectedAppDeletionThreshold.
        A passing result means the percentage of removed accounts is within
        the configured safety threshold.
    .PARAMETER ThresholdResult
        The result hashtable from Test-SPDisconnectedAppDeletionThreshold.
        Expected keys: Success, Data (with Percentage, Threshold, Safe), Error.
    .OUTPUTS
        @{Pass=$true/$false; Percentage=$n; Threshold=$n; Message="..."}
    .EXAMPLE
        $result = Assert-SPDeletionThresholdSafe -ThresholdResult $threshResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ThresholdResult
    )

    try {
        if (-not $ThresholdResult.Success) {
            return @{
                Pass       = $false
                Percentage = 0
                Threshold  = 0
                Message    = "Test-SPDisconnectedAppDeletionThreshold failed: $($ThresholdResult.Error)"
            }
        }

        $percentage = 0
        $threshold  = 0
        $safe       = $false

        if ($null -ne $ThresholdResult.Data) {
            $data = $ThresholdResult.Data
            if ($data -is [hashtable]) {
                if ($data.ContainsKey('Percentage')) { $percentage = [double]$data.Percentage }
                if ($data.ContainsKey('Threshold'))  { $threshold  = [double]$data.Threshold }
                if ($data.ContainsKey('Safe'))        { $safe       = [bool]$data.Safe }
            }
            else {
                if ($data.PSObject.Properties.Name -contains 'Percentage') { $percentage = [double]$data.Percentage }
                if ($data.PSObject.Properties.Name -contains 'Threshold')  { $threshold  = [double]$data.Threshold }
                if ($data.PSObject.Properties.Name -contains 'Safe')        { $safe       = [bool]$data.Safe }
            }
        }

        if ($safe) {
            return @{
                Pass       = $true
                Percentage = $percentage
                Threshold  = $threshold
                Message    = "Deletion percentage $($percentage)% is within threshold of $($threshold)%"
            }
        }
        else {
            return @{
                Pass       = $false
                Percentage = $percentage
                Threshold  = $threshold
                Message    = "Deletion percentage $($percentage)% exceeds safety threshold of $($threshold)%"
            }
        }
    }
    catch {
        return @{
            Pass       = $false
            Percentage = 0
            Threshold  = 0
            Message    = "Assert-SPDeletionThresholdSafe threw exception: $($_.Exception.Message)"
        }
    }
}

function Assert-SPAggregationComplete {
    <#
    .SYNOPSIS
        Assert that an ISC source aggregation task completed successfully.
    .DESCRIPTION
        Validates the result from Wait-SPISCAggregation. Checks that the
        aggregation task reached a completed state without errors.
    .PARAMETER AggregationResult
        The result hashtable from Wait-SPISCAggregation.
        Expected keys: Success, Data (with Status, TaskId), Error.
    .OUTPUTS
        @{Pass=$true/$false; Status=$string; TaskId=$string; Message="..."}
    .EXAMPLE
        $result = Assert-SPAggregationComplete -AggregationResult $aggResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$AggregationResult
    )

    try {
        if (-not $AggregationResult.Success) {
            return @{
                Pass    = $false
                Status  = 'FAILED'
                TaskId  = ''
                Message = "Wait-SPISCAggregation failed: $($AggregationResult.Error)"
            }
        }

        $status = 'UNKNOWN'
        $taskId = ''

        if ($null -ne $AggregationResult.Data) {
            $data = $AggregationResult.Data
            if ($data -is [hashtable]) {
                if ($data.ContainsKey('Status')) { $status = $data.Status }
                if ($data.ContainsKey('TaskId')) { $taskId = $data.TaskId }
            }
            else {
                if ($data.PSObject.Properties.Name -contains 'Status') { $status = $data.Status }
                if ($data.PSObject.Properties.Name -contains 'TaskId') { $taskId = $data.TaskId }
            }
        }

        $completedStatuses = @('COMPLETED', 'SUCCESS', 'COMPLETE')
        if ($completedStatuses -contains $status.ToUpper()) {
            return @{
                Pass    = $true
                Status  = $status
                TaskId  = $taskId
                Message = "Aggregation completed successfully (Status=$status, TaskId=$taskId)"
            }
        }
        else {
            return @{
                Pass    = $false
                Status  = $status
                TaskId  = $taskId
                Message = "Aggregation did not complete successfully (Status=$status, TaskId=$taskId)"
            }
        }
    }
    catch {
        return @{
            Pass    = $false
            Status  = 'ERROR'
            TaskId  = ''
            Message = "Assert-SPAggregationComplete threw exception: $($_.Exception.Message)"
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Assert-SPCampaignStatus',
    'Assert-SPCertificationCount',
    'Assert-SPDecisionAccepted',
    'Assert-SPRemediationComplete',
    'Assert-SPDeltaGrantEventCount',
    'Assert-SPDeltaManagerGrouping',
    'Assert-SPDisconnectedAppFileValid',
    'Assert-SPDisconnectedAppDeltaDetected',
    'Assert-SPDeletionThresholdSafe',
    'Assert-SPAggregationComplete'
)
