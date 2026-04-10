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

Export-ModuleMember -Function @(
    'Assert-SPCampaignStatus',
    'Assert-SPCertificationCount',
    'Assert-SPDecisionAccepted',
    'Assert-SPRemediationComplete'
)
