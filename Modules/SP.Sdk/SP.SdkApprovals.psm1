#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Access Request Approval Queries
.DESCRIPTION
    Wraps the ISC V3 access-request-approvals endpoints:
    pending, completed, approval-summary, approve, reject, forward.
    Parity with PSSailpoint SDK AccessRequestApprovalsApi.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
    Auto-paginating wrappers delegate to Invoke-SPSdkPaginatedGet (SP.SdkCommon).
.NOTES
    Module: SP.SdkApprovals
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/AccessRequestApprovalsApi.ps1
#>

function Get-SPSdkPendingApprovals {
    <#
    .SYNOPSIS
        Lists pending access request approvals with optional filtering and sorting.
    .DESCRIPTION
        GETs /access-request-approvals/pending with standard collection parameters.
        Supported filters: id, requestedFor.id, modified, accessRequestId, created.
    .PARAMETER OwnerId
        Filter by approval owner identity ID. Passed as query param 'owner-id'.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression (e.g. 'requestedFor.id eq "abc123"').
    .PARAMETER Sorters
        Sort expression. Supported fields: id, requestedFor.id, modified, accessRequestId, created.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$Sorters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['owner-id'] = $OwnerId
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing pending approvals: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkPendingApprovals' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/access-request-approvals/pending' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) pending approvals" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkPendingApprovals' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllPendingApprovals {
    <#
    .SYNOPSIS
        Auto-paginating wrapper for pending access request approvals.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to fetch all pages from
        /access-request-approvals/pending.
    .PARAMETER OwnerId
        Filter by approval owner identity ID. Passed as query param 'owner-id'.
    .PARAMETER Filters
        ISC filter expression (e.g. 'requestedFor.id eq "abc123"').
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['owner-id'] = $OwnerId
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Fetching all pending approvals (auto-paginated)" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkAllPendingApprovals' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint '/access-request-approvals/pending' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if ($result.Success) {
        Write-SPLog -Message "Fetched $($result.Data.Count) total pending approvals" `
            -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkAllPendingApprovals' `
            -CorrelationID $CorrelationID
    }

    return $result
}

function Get-SPSdkCompletedApprovals {
    <#
    .SYNOPSIS
        Lists completed access request approvals with optional filtering and sorting.
    .DESCRIPTION
        GETs /access-request-approvals/completed with standard collection parameters.
        Supported filters: id, requestedFor.id, modified.
    .PARAMETER OwnerId
        Filter by approval owner identity ID. Passed as query param 'owner-id'.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression (e.g. 'requestedFor.id eq "abc123"').
    .PARAMETER Sorters
        Sort expression. Supported fields: id, requestedFor.id, modified.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$Sorters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['owner-id'] = $OwnerId
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing completed approvals: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkCompletedApprovals' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/access-request-approvals/completed' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) completed approvals" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkCompletedApprovals' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllCompletedApprovals {
    <#
    .SYNOPSIS
        Auto-paginating wrapper for completed access request approvals.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to fetch all pages from
        /access-request-approvals/completed.
    .PARAMETER OwnerId
        Filter by approval owner identity ID. Passed as query param 'owner-id'.
    .PARAMETER Filters
        ISC filter expression (e.g. 'requestedFor.id eq "abc123"').
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['owner-id'] = $OwnerId
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Fetching all completed approvals (auto-paginated)" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkAllCompletedApprovals' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint '/access-request-approvals/completed' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if ($result.Success) {
        Write-SPLog -Message "Fetched $($result.Data.Count) total completed approvals" `
            -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkAllCompletedApprovals' `
            -CorrelationID $CorrelationID
    }

    return $result
}

function Get-SPSdkApprovalSummary {
    <#
    .SYNOPSIS
        Gets the approval summary (pending/approved/rejected counts).
    .DESCRIPTION
        GETs /access-request-approvals/approval-summary.
        Returns a single summary object with pending, approved, and rejected counts.
        This endpoint is NOT paginated.
    .PARAMETER OwnerId
        Filter by approval owner identity ID. Passed as query param 'owner-id'.
    .PARAMETER FromDate
        ISO 8601 date string to filter approvals from (e.g. '2026-01-01T00:00:00Z').
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$FromDate,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['owner-id'] = $OwnerId
    }
    if (-not [string]::IsNullOrWhiteSpace($FromDate)) {
        $queryParams['from-date'] = $FromDate
    }

    Write-SPLog -Message "Getting approval summary" `
        -Severity DEBUG -Component 'SP.SdkApprovals' -Action 'Get-SPSdkApprovalSummary' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/access-request-approvals/approval-summary' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Approve-SPSdkAccessRequest {
    <#
    .SYNOPSIS
        Approves a pending access request approval.
    .DESCRIPTION
        POSTs to /access-request-approvals/{approvalId}/approve.
        Optionally includes a comment in the request body.
    .PARAMETER ApprovalId
        The approval ID to approve (mandatory).
    .PARAMETER Comment
        Optional comment to include with the approval.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalId,

        [Parameter()] [string]$Comment,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Access request approval '$ApprovalId'", 'Approve')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $body = $null
    if (-not [string]::IsNullOrWhiteSpace($Comment)) {
        $body = @{ comment = $Comment }
    }

    Write-SPLog -Message "Approving access request: $ApprovalId" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Approve-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/access-request-approvals/$ApprovalId/approve" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Approved access request: $ApprovalId" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Approve-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Deny-SPSdkAccessRequest {
    <#
    .SYNOPSIS
        Rejects a pending access request approval.
    .DESCRIPTION
        POSTs to /access-request-approvals/{approvalId}/reject.
        A comment is required when rejecting.
    .PARAMETER ApprovalId
        The approval ID to reject (mandatory).
    .PARAMETER Comment
        Reason for rejection (mandatory -- required by the ISC API on reject).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Comment,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Access request approval '$ApprovalId'", 'Reject')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $body = @{ comment = $Comment }

    Write-SPLog -Message "Rejecting access request: $ApprovalId" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Deny-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/access-request-approvals/$ApprovalId/reject" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Rejected access request: $ApprovalId" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Deny-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Forward-SPSdkAccessRequest {
    <#
    .SYNOPSIS
        Forwards a pending access request approval to a different owner.
    .DESCRIPTION
        POSTs to /access-request-approvals/{approvalId}/forward.
        Requires the new owner identity ID and a comment.
    .PARAMETER ApprovalId
        The approval ID to forward (mandatory).
    .PARAMETER NewOwnerId
        The identity ID to forward the approval to (mandatory).
    .PARAMETER Comment
        Reason for forwarding (mandatory).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NewOwnerId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Comment,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Access request approval '$ApprovalId' -> owner '$NewOwnerId'", 'Forward')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $body = @{
        newOwnerId = $NewOwnerId
        comment    = $Comment
    }

    Write-SPLog -Message "Forwarding access request '$ApprovalId' to owner '$NewOwnerId'" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Forward-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/access-request-approvals/$ApprovalId/forward" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Forwarded access request '$ApprovalId' to owner '$NewOwnerId'" `
        -Severity INFO -Component 'SP.SdkApprovals' -Action 'Forward-SPSdkAccessRequest' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-SPSdkPendingApprovals',
    'Get-SPSdkAllPendingApprovals',
    'Get-SPSdkCompletedApprovals',
    'Get-SPSdkAllCompletedApprovals',
    'Get-SPSdkApprovalSummary',
    'Approve-SPSdkAccessRequest',
    'Deny-SPSdkAccessRequest',
    'Forward-SPSdkAccessRequest'
)
