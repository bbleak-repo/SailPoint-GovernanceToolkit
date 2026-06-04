#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Work Item Operations
.DESCRIPTION
    Wraps the ISC V3 work-items endpoints:
    list, get, summary, count, completed, approve, reject, forward,
    bulk-approve, bulk-reject, submit-account-selection.
    Parity with PSSailpoint SDK WorkItemsApi.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
.NOTES
    Module: SP.SdkWorkItems
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/WorkItemsApi.ps1
#>

function Get-SPSdkWorkItems {
    <#
    .SYNOPSIS
        Lists work items with optional owner filter and pagination.
    .DESCRIPTION
        GETs /work-items with standard collection parameters.
        Supports filtering by owner ID.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
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
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Listing work items: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkWorkItems' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/work-items' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) work items" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkWorkItems' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllWorkItems {
    <#
    .SYNOPSIS
        Auto-paginating retrieval of all work items.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to fetch all pages from /work-items.
        Supports optional owner filter.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Fetching all work items (paginated)" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkAllWorkItems' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint '/work-items' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if ($result.Success) {
        Write-SPLog -Message "Fetched $($result.Data.Count) total work items" `
            -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkAllWorkItems' `
            -CorrelationID $CorrelationID
    }

    return $result
}

function Get-SPSdkWorkItem {
    <#
    .SYNOPSIS
        Gets a single work item by ID.
    .PARAMETER WorkItemId
        The work item ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkItemId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting work item: $WorkItemId" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkWorkItem' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/work-items/$WorkItemId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkWorkItemsSummary {
    <#
    .SYNOPSIS
        Gets the work items summary (open, completed, total counts).
    .DESCRIPTION
        GETs /work-items/summary. Returns a single object with open, completed,
        and total counts.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Getting work items summary" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkWorkItemsSummary' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/work-items/summary' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkWorkItemCount {
    <#
    .SYNOPSIS
        Gets the count of open work items.
    .DESCRIPTION
        GETs /work-items/count. Returns a single object with a count property.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Getting work item count" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkWorkItemCount' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/work-items/count' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkCompletedWorkItems {
    <#
    .SYNOPSIS
        Lists completed work items with optional owner filter and pagination.
    .DESCRIPTION
        GETs /work-items/completed with standard collection parameters.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
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
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Listing completed work items: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkCompletedWorkItems' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/work-items/completed' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) completed work items" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkCompletedWorkItems' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllCompletedWorkItems {
    <#
    .SYNOPSIS
        Auto-paginating retrieval of all completed work items.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to fetch all pages from /work-items/completed.
        Supports optional owner filter.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Fetching all completed work items (paginated)" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkAllCompletedWorkItems' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint '/work-items/completed' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if ($result.Success) {
        Write-SPLog -Message "Fetched $($result.Data.Count) total completed work items" `
            -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkAllCompletedWorkItems' `
            -CorrelationID $CorrelationID
    }

    return $result
}

function Get-SPSdkCompletedWorkItemCount {
    <#
    .SYNOPSIS
        Gets the count of completed work items.
    .DESCRIPTION
        GETs /work-items/completed/count. Returns a single object with a count property.
    .PARAMETER OwnerId
        Filter by work item owner identity ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$OwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
        $queryParams['ownerId'] = $OwnerId
    }

    Write-SPLog -Message "Getting completed work item count" `
        -Severity DEBUG -Component 'SP.SdkWorkItems' -Action 'Get-SPSdkCompletedWorkItemCount' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/work-items/completed/count' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Complete-SPSdkWorkItem {
    <#
    .SYNOPSIS
        Completes a work item.
    .DESCRIPTION
        POSTs to /work-items/{id}. Optional body for form definition data.
    .PARAMETER WorkItemId
        The work item ID to complete.
    .PARAMETER Body
        Optional form definition body (string).
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
        [string]$WorkItemId,

        [Parameter()] [string]$Body,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Work item '$WorkItemId'", 'Complete')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Completing work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Complete-SPSdkWorkItem' `
        -CorrelationID $CorrelationID

    $apiParams = @{
        Method        = 'POST'
        Endpoint      = "/work-items/$WorkItemId"
        CorrelationID = $CorrelationID
    }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $apiParams['Body'] = $Body
    }

    $result = Invoke-SPApiRequest @apiParams

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Completed work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Complete-SPSdkWorkItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Approve-SPSdkApprovalItem {
    <#
    .SYNOPSIS
        Approves a specific approval item within a work item.
    .DESCRIPTION
        POSTs to /work-items/{id}/approve/{approvalItemId}. No body required.
    .PARAMETER WorkItemId
        The work item ID containing the approval.
    .PARAMETER ApprovalItemId
        The specific approval item ID to approve.
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
        [string]$WorkItemId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalItemId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Approval item '$ApprovalItemId' in work item '$WorkItemId'", 'Approve')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Approving approval item '$ApprovalItemId' in work item '$WorkItemId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Approve-SPSdkApprovalItem' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/work-items/$WorkItemId/approve/$ApprovalItemId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Approved approval item '$ApprovalItemId' in work item '$WorkItemId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Approve-SPSdkApprovalItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Deny-SPSdkApprovalItem {
    <#
    .SYNOPSIS
        Rejects a specific approval item within a work item.
    .DESCRIPTION
        POSTs to /work-items/{id}/reject/{approvalItemId}. No body required.
    .PARAMETER WorkItemId
        The work item ID containing the approval.
    .PARAMETER ApprovalItemId
        The specific approval item ID to reject.
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
        [string]$WorkItemId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalItemId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Approval item '$ApprovalItemId' in work item '$WorkItemId'", 'Reject')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Rejecting approval item '$ApprovalItemId' in work item '$WorkItemId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Deny-SPSdkApprovalItem' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/work-items/$WorkItemId/reject/$ApprovalItemId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Rejected approval item '$ApprovalItemId' in work item '$WorkItemId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Deny-SPSdkApprovalItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Forward-SPSdkWorkItem {
    <#
    .SYNOPSIS
        Forwards a work item to a new owner.
    .DESCRIPTION
        POSTs to /work-items/{id}/forward with target owner, comment, and
        notification preference.
    .PARAMETER WorkItemId
        The work item ID to forward.
    .PARAMETER TargetOwnerId
        The identity ID of the new owner.
    .PARAMETER Comment
        Comment explaining why the work item is being forwarded.
    .PARAMETER SendNotifications
        Whether to send email notifications. Default: $true.
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
        [string]$WorkItemId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetOwnerId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Comment,

        [Parameter()] [bool]$SendNotifications = $true,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Work item '$WorkItemId' -> owner '$TargetOwnerId'", 'Forward')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Forwarding work item '$WorkItemId' to '$TargetOwnerId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Forward-SPSdkWorkItem' `
        -CorrelationID $CorrelationID

    $body = @{
        targetOwnerId     = $TargetOwnerId
        comment            = $Comment
        sendNotifications  = $SendNotifications
    }

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/work-items/$WorkItemId/forward" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Forwarded work item '$WorkItemId' to '$TargetOwnerId'" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Forward-SPSdkWorkItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Invoke-SPSdkBulkApproveWorkItem {
    <#
    .SYNOPSIS
        Bulk-approves all approval items within a work item.
    .DESCRIPTION
        POSTs to /work-items/bulk-approve/{id}. No body required.
        Approves ALL pending approval items in the work item at once.
    .PARAMETER WorkItemId
        The work item ID to bulk-approve.
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
        [string]$WorkItemId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Work item '$WorkItemId'", 'Bulk Approve')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Bulk-approving work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Invoke-SPSdkBulkApproveWorkItem' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/work-items/bulk-approve/$WorkItemId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Bulk-approved work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Invoke-SPSdkBulkApproveWorkItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Invoke-SPSdkBulkRejectWorkItem {
    <#
    .SYNOPSIS
        Bulk-rejects all approval items within a work item.
    .DESCRIPTION
        POSTs to /work-items/bulk-reject/{id}. No body required.
        Rejects ALL pending approval items in the work item at once.
    .PARAMETER WorkItemId
        The work item ID to bulk-reject.
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
        [string]$WorkItemId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Work item '$WorkItemId'", 'Bulk Reject')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Bulk-rejecting work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Invoke-SPSdkBulkRejectWorkItem' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/work-items/bulk-reject/$WorkItemId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Bulk-rejected work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Invoke-SPSdkBulkRejectWorkItem' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Submit-SPSdkAccountSelection {
    <#
    .SYNOPSIS
        Submits account selection data for a work item.
    .DESCRIPTION
        POSTs to /work-items/{id}/submit-account-selection.
        Body is the selection data hashtable keyed on field name.
    .PARAMETER WorkItemId
        The work item ID to submit account selection for.
    .PARAMETER SelectionData
        Hashtable of account selection data keyed on field name.
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
        [string]$WorkItemId,

        [Parameter(Mandatory)]
        [hashtable]$SelectionData,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Work item '$WorkItemId'", 'Submit Account Selection')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Submitting account selection for work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Submit-SPSdkAccountSelection' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST `
        -Endpoint "/work-items/$WorkItemId/submit-account-selection" `
        -Body $SelectionData -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Submitted account selection for work item: $WorkItemId" `
        -Severity INFO -Component 'SP.SdkWorkItems' -Action 'Submit-SPSdkAccountSelection' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-SPSdkWorkItems',
    'Get-SPSdkAllWorkItems',
    'Get-SPSdkWorkItem',
    'Get-SPSdkWorkItemsSummary',
    'Get-SPSdkWorkItemCount',
    'Get-SPSdkCompletedWorkItems',
    'Get-SPSdkAllCompletedWorkItems',
    'Get-SPSdkCompletedWorkItemCount',
    'Complete-SPSdkWorkItem',
    'Approve-SPSdkApprovalItem',
    'Deny-SPSdkApprovalItem',
    'Forward-SPSdkWorkItem',
    'Invoke-SPSdkBulkApproveWorkItem',
    'Invoke-SPSdkBulkRejectWorkItem',
    'Submit-SPSdkAccountSelection'
)
