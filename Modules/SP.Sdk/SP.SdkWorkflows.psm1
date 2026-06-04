#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Workflow Management
.DESCRIPTION
    Wraps the ISC V3 workflows endpoints (18 endpoints):
    CRUD, test, execute, execution history, library (triggers, actions, operators).
    Includes composite OOO fallback reviewer pattern.
    Parity with PSSailpoint SDK WorkflowsApi.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
    PATCH operations use application/json-patch+json per RFC 6902.
.NOTES
    Module: SP.SdkWorkflows
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/WorkflowsApi.ps1
#>

#region CRUD Operations

function New-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Creates a new ISC workflow.
    .DESCRIPTION
        POSTs to /workflows. The workflow body must include at minimum:
        name (string). Optional: owner, description, definition, enabled, trigger.
    .PARAMETER Workflow
        Hashtable with workflow properties.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Workflow,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $wfName = if ($Workflow.ContainsKey('name')) { $Workflow['name'] } else { '(unnamed)' }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$wfName'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating workflow: '$wfName'" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'New-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint '/workflows' `
        -Body $Workflow -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Created workflow: id=$($result.Data.id)" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'New-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkWorkflows {
    <#
    .SYNOPSIS
        Lists workflows with optional filtering and sorting.
    .DESCRIPTION
        GETs /workflows. Supports filters on: enabled, connectorInstanceId, triggerId.
        Sort by: modified, name.
    .PARAMETER Filters
        ISC filter expression.
    .PARAMETER Sorters
        Sort expression.
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
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$Sorters,
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
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing workflows: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflows' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/workflows' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) workflows" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflows' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllWorkflows {
    <#
    .SYNOPSIS
        Auto-paginating retrieval of all workflows.
    .PARAMETER Filters
        ISC filter expression.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Fetching all workflows (paginated)" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkAllWorkflows' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint '/workflows' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if ($result.Success) {
        Write-SPLog -Message "Fetched $($result.Data.Count) total workflows" `
            -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkAllWorkflows' `
            -CorrelationID $CorrelationID
    }

    return $result
}

function Get-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Gets a single workflow by ID.
    .PARAMETER WorkflowId
        The workflow ID.
    .PARAMETER IncludeMetrics
        When true, includes execution/failure counts. Default: false.
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
        [string]$WorkflowId,

        [Parameter()] [bool]$IncludeMetrics = $false,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'workflowMetrics' = $IncludeMetrics.ToString().ToLower()
    }

    Write-SPLog -Message "Getting workflow: $WorkflowId (metrics=$IncludeMetrics)" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/workflows/$WorkflowId" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Update-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Updates a workflow via JSON Patch (RFC 6902).
    .DESCRIPTION
        PATCHes /workflows/{id} with application/json-patch+json.
    .PARAMETER WorkflowId
        The workflow ID to update.
    .PARAMETER PatchOperations
        Array of patch operations (from New-SPSdkPatchOp or New-SPSdkPatchReplace).
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
        [string]$WorkflowId,

        [Parameter(Mandatory)]
        $PatchOperations,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId'", 'Patch')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $body = ConvertTo-SPSdkPatchBody -Operations $PatchOperations

    Write-SPLog -Message "Patching workflow '$WorkflowId' ($($body.Count) operations)" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Update-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method PATCH -Endpoint "/workflows/$WorkflowId" `
        -Body $body -ContentType 'application/json-patch+json' -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Set-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Full replacement update of a workflow via PUT.
    .DESCRIPTION
        PUTs to /workflows/{id} with application/json. Replaces the entire
        workflow definition.
    .PARAMETER WorkflowId
        The workflow ID to replace.
    .PARAMETER WorkflowBody
        Complete workflow hashtable.
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
        [string]$WorkflowId,

        [Parameter(Mandatory)]
        [hashtable]$WorkflowBody,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $wfName = if ($WorkflowBody.ContainsKey('name')) { $WorkflowBody['name'] } else { '(unnamed)' }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId' ($wfName)", 'Replace (PUT)')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Replacing workflow '$WorkflowId' via PUT" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Set-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method PUT -Endpoint "/workflows/$WorkflowId" `
        -Body $WorkflowBody -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Remove-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Deletes a workflow.
    .PARAMETER WorkflowId
        The workflow ID to delete.
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
        [string]$WorkflowId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId'", 'Delete')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Deleting workflow: $WorkflowId" `
        -Severity WARN -Component 'SP.SdkWorkflows' -Action 'Remove-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method DELETE -Endpoint "/workflows/$WorkflowId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

#endregion

#region Test and Execution

function Test-SPSdkWorkflow {
    <#
    .SYNOPSIS
        Tests a workflow execution with sample input.
    .DESCRIPTION
        POSTs to /workflows/{id}/test. Workflow must be DISABLED to test.
        Rate limit: 5 requests per 10 seconds.
    .PARAMETER WorkflowId
        The workflow ID to test.
    .PARAMETER TestInput
        Test input data hashtable.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
        Data contains workflowExecutionId on success.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkflowId,

        [Parameter(Mandatory)]
        [hashtable]$TestInput,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId'", 'Test')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Testing workflow '$WorkflowId' (workflow must be disabled)" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Test-SPSdkWorkflow' `
        -CorrelationID $CorrelationID

    $body = @{ input = $TestInput }

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/workflows/$WorkflowId/test" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Invoke-SPSdkExternalWorkflow {
    <#
    .SYNOPSIS
        Executes a workflow via external trigger.
    .DESCRIPTION
        POSTs to /workflows/execute/external/{id}.
    .PARAMETER WorkflowId
        The workflow ID to execute.
    .PARAMETER TestInput
        Input data hashtable for the workflow.
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
        [string]$WorkflowId,

        [Parameter()] [hashtable]$TestInput,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId'", 'Execute (external)')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Executing workflow '$WorkflowId' via external trigger" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Invoke-SPSdkExternalWorkflow' `
        -CorrelationID $CorrelationID

    $body = if ($null -ne $TestInput) { $TestInput } else { @{} }

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/workflows/execute/external/$WorkflowId" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Test-SPSdkExternalWorkflow {
    <#
    .SYNOPSIS
        Tests an external workflow execution.
    .DESCRIPTION
        POSTs to /workflows/execute/external/{id}/test.
    .PARAMETER WorkflowId
        The workflow ID to test.
    .PARAMETER TestInput
        Test input data hashtable.
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
        [string]$WorkflowId,

        [Parameter()] [hashtable]$TestInput,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow '$WorkflowId'", 'Test (external)')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Testing external workflow '$WorkflowId'" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Test-SPSdkExternalWorkflow' `
        -CorrelationID $CorrelationID

    $body = if ($null -ne $TestInput) { $TestInput } else { @{} }

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/workflows/execute/external/$WorkflowId/test" `
        -Body $body -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function New-SPSdkWorkflowExternalTrigger {
    <#
    .SYNOPSIS
        Creates an OAuth client for external workflow triggering.
    .DESCRIPTION
        POSTs to /workflows/{id}/external/oauth-clients.
        Returns an OAuth client with id, secret, and callback URL.
    .PARAMETER WorkflowId
        The workflow ID.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
        Data contains: id (OAuth client ID), secret, url.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkflowId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("External trigger for workflow '$WorkflowId'", 'Create OAuth client')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating external trigger OAuth client for workflow '$WorkflowId'" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'New-SPSdkWorkflowExternalTrigger' `
        -CorrelationID $CorrelationID

    # This endpoint takes no body -- POST with empty body
    $result = Invoke-SPApiRequest -Method POST -Endpoint "/workflows/$WorkflowId/external/oauth-clients" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

#endregion

#region Execution Monitoring

function Get-SPSdkWorkflowExecutions {
    <#
    .SYNOPSIS
        Lists executions for a workflow.
    .DESCRIPTION
        GETs /workflows/{id}/executions. Supports filters on: start_time, status.
    .PARAMETER WorkflowId
        The workflow ID.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression.
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
        [string]$WorkflowId,

        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Listing executions for workflow '$WorkflowId'" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowExecutions' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/workflows/$WorkflowId/executions" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) executions for workflow '$WorkflowId'" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowExecutions' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkWorkflowExecution {
    <#
    .SYNOPSIS
        Gets a single workflow execution by ID.
    .PARAMETER ExecutionId
        The workflow execution ID.
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
        [string]$ExecutionId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting workflow execution: $ExecutionId" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowExecution' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/workflow-executions/$ExecutionId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkWorkflowExecutionHistory {
    <#
    .SYNOPSIS
        Gets the execution history for a workflow execution.
    .DESCRIPTION
        GETs /workflow-executions/{id}/history.
        DEPRECATED: This endpoint will be removed in October 2027.
    .PARAMETER ExecutionId
        The workflow execution ID.
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
        [string]$ExecutionId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting execution history for: $ExecutionId (NOTE: endpoint deprecated Oct 2027)" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowExecutionHistory' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/workflow-executions/$ExecutionId/history" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    return @{ Success = $true; Data = $items; Error = $null }
}

function Stop-SPSdkWorkflowExecution {
    <#
    .SYNOPSIS
        Cancels a running workflow execution.
    .PARAMETER ExecutionId
        The workflow execution ID to cancel.
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
        [string]$ExecutionId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Workflow execution '$ExecutionId'", 'Cancel')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Cancelling workflow execution: $ExecutionId" `
        -Severity WARN -Component 'SP.SdkWorkflows' -Action 'Stop-SPSdkWorkflowExecution' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/workflow-executions/$ExecutionId/cancel" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

#endregion

#region Workflow Library

# NOTE: Bare /workflow-library endpoint removed (W-02) -- ISC V3 API does not
# document it. Use the individual sub-endpoints instead:
#   Get-SPSdkWorkflowLibraryActions, Get-SPSdkWorkflowLibraryOperators,
#   Get-SPSdkWorkflowLibraryTriggers.

function Get-SPSdkWorkflowLibraryActions {
    <#
    .SYNOPSIS
        Lists available workflow library actions.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression. Supports: id.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Getting workflow library actions" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowLibraryActions' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/workflow-library/actions' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = @($result.Data)
    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkWorkflowLibraryOperators {
    <#
    .SYNOPSIS
        Lists available workflow library operators.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting workflow library operators" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowLibraryOperators' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/workflow-library/operators' `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = @($result.Data)
    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkWorkflowLibraryTriggers {
    <#
    .SYNOPSIS
        Lists available workflow library triggers.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression. Supports: id, name, type.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit'  = $Limit.ToString()
        'offset' = $Offset.ToString()
    }
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }

    Write-SPLog -Message "Getting workflow library triggers" `
        -Severity DEBUG -Component 'SP.SdkWorkflows' -Action 'Get-SPSdkWorkflowLibraryTriggers' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/workflow-library/triggers' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = @($result.Data)
    return @{ Success = $true; Data = $items; Error = $null }
}

#endregion

#region Composite Operations

function Set-SPSdkOOOFallbackWorkflow {
    <#
    .SYNOPSIS
        Creates or updates a scheduled workflow for OOO fallback reviewer reassignment.
    .DESCRIPTION
        Composite function that builds an ISC workflow to check for stale
        certifications assigned to a primary reviewer and reassign them to a
        fallback reviewer after a configurable number of days.

        This addresses the documented ISC gap: "No native auto-fallback to
        backup reviewer after X days."

        If a workflow with the generated name already exists, it updates the
        existing workflow. Otherwise, it creates a new one.
    .PARAMETER PrimaryReviewerId
        Identity ID of the primary reviewer to monitor.
    .PARAMETER FallbackReviewerId
        Identity ID of the fallback reviewer who takes over.
    .PARAMETER FallbackDays
        Number of days after which stale certifications are reassigned. Default: 3.
    .PARAMETER WorkflowName
        Custom workflow name. Defaults to 'OOO Fallback: <PrimaryReviewerId>'.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
        Data contains the created/updated workflow object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PrimaryReviewerId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackReviewerId,

        [Parameter()]
        [int]$FallbackDays = 3,

        [Parameter()]
        [string]$WorkflowName,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if ([string]::IsNullOrWhiteSpace($WorkflowName)) {
        $WorkflowName = "OOO Fallback: $PrimaryReviewerId"
    }

    if (-not $PSCmdlet.ShouldProcess("OOO Fallback workflow for reviewer '$PrimaryReviewerId' -> '$FallbackReviewerId' after $FallbackDays days", 'Create/Update')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Setting up OOO fallback: primary=$PrimaryReviewerId, fallback=$FallbackReviewerId, days=$FallbackDays" `
        -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Set-SPSdkOOOFallbackWorkflow' `
        -CorrelationID $CorrelationID

    # Build the workflow definition.
    # This creates a SCHEDULED workflow with 3 steps:
    #   1. GET active certifications owned by PrimaryReviewerId
    #   2. Filter to those older than FallbackDays
    #   3. POST reassignment to FallbackReviewerId for each stale cert
    #
    # NOTE: The workflow is created DISABLED (enabled=$false). The admin
    # must review the definition and enable it manually. This is intentional
    # -- automated reassignment in production should be a deliberate act.
    #
    # ISC workflow limitations:
    # - Looping over HTTP results requires the sp:transform operator
    # - Reassignment endpoint is POST /certifications/{id}/reassign
    # - The workflow engine handles iteration via the forEach construct
    $workflowDef = @{
        name        = $WorkflowName
        description = "Auto-reassigns stale certifications from $PrimaryReviewerId to $FallbackReviewerId after $FallbackDays days. Generated by SP.SdkWorkflows. Review and enable manually."
        enabled     = $false
        trigger     = @{
            type       = 'SCHEDULED'
            attributes = @{
                cronString = '0 0 8 * * ?'  # Daily at 8 AM
            }
        }
        definition  = @{
            start = 'getCertifications'
            steps = @{
                getCertifications = @{
                    type          = 'action'
                    actionId      = 'sp:http'
                    versionNumber = 1
                    attributes    = @{
                        url    = "v3/certifications?filters=reviewer.id eq `"$PrimaryReviewerId`" and phase eq `"ACTIVE`""
                        method = 'GET'
                    }
                    nextStep      = 'filterStale'
                }
                filterStale = @{
                    type          = 'action'
                    actionId      = 'sp:transform'
                    versionNumber = 1
                    attributes    = @{
                        expression  = "`$.getCertifications.body[?(@.created < '`${now-${FallbackDays}d}')]"
                        variableName = 'staleCerts'
                    }
                    nextStep      = 'reassignCerts'
                }
                reassignCerts = @{
                    type          = 'action'
                    actionId      = 'sp:http'
                    versionNumber = 1
                    attributes    = @{
                        url    = 'v3/certifications/$.each.id/reassign'
                        method = 'POST'
                        body   = @{
                            reassign = @(
                                @{
                                    reviewerId = $FallbackReviewerId
                                    reason     = "OOO auto-fallback after $FallbackDays days of inactivity"
                                }
                            )
                        }
                        forEach = '$.filterStale.staleCerts'
                    }
                    nextStep      = 'end'
                }
            }
        }
    }

    # Check if workflow already exists
    $existingResult = Get-SPSdkWorkflows -Filters "name eq `"$WorkflowName`"" -CorrelationID $CorrelationID

    if ($existingResult.Success -and $existingResult.Data.Count -gt 0) {
        # Update existing workflow
        $existingId = $existingResult.Data[0].id
        Write-SPLog -Message "Found existing OOO workflow '$existingId', updating via PUT" `
            -Severity INFO -Component 'SP.SdkWorkflows' -Action 'Set-SPSdkOOOFallbackWorkflow' `
            -CorrelationID $CorrelationID

        return Set-SPSdkWorkflow -WorkflowId $existingId -WorkflowBody $workflowDef `
            -CorrelationID $CorrelationID
    }

    # Create new workflow
    return New-SPSdkWorkflow -Workflow $workflowDef -CorrelationID $CorrelationID
}

#endregion

Export-ModuleMember -Function @(
    'New-SPSdkWorkflow',
    'Get-SPSdkWorkflows',
    'Get-SPSdkAllWorkflows',
    'Get-SPSdkWorkflow',
    'Update-SPSdkWorkflow',
    'Set-SPSdkWorkflow',
    'Remove-SPSdkWorkflow',
    'Test-SPSdkWorkflow',
    'Invoke-SPSdkExternalWorkflow',
    'Test-SPSdkExternalWorkflow',
    'New-SPSdkWorkflowExternalTrigger',
    'Get-SPSdkWorkflowExecutions',
    'Get-SPSdkWorkflowExecution',
    'Get-SPSdkWorkflowExecutionHistory',
    'Stop-SPSdkWorkflowExecution',
    'Get-SPSdkWorkflowLibraryActions',
    'Get-SPSdkWorkflowLibraryOperators',
    'Get-SPSdkWorkflowLibraryTriggers',
    'Set-SPSdkOOOFallbackWorkflow'
)
