#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK-to-GUI Bridge Adapter (read functions)
.DESCRIPTION
    Provides an adapter layer between the WPF SDK Features tab and the SP.Sdk
    read functions. Each bridge function wraps one or more SP.Sdk reads and
    returns a normalized hashtable @{ Success; Data; Error } suitable for WPF
    DataGrid binding and background-worker patterns in SP.MainWindow.

    The backing SP.Sdk reads already return @{Success; Data; Error} and already
    unwrap the {items:[...]} collection envelope, so this bridge consumes
    $result.Data directly and shapes each item into a display-ready
    [PSCustomObject] row. Checkbox-selectable grids carry an IsSelected flag;
    every row keeps a _Raw reference to the original SP.Sdk object for detail
    views.

    All functions are pure/synchronous and never throw: the body is wrapped in
    try/catch and failures return @{Success=$false; Data=@(); Error=<message>}.

    SDK-01 scope: READ functions only. Write dispatchers (SDK-02), Safety gates
    (SDK-03), psd1 registration (SDK-04), test-loader changes (SDK-05) and tests
    (SDK-06) are separate backlog items.
.NOTES
    Module:  SP.SdkBridge
    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Safety Gate (private)

function Test-SPGuiSdkSafetyGate {
    <#
    .SYNOPSIS
        Private Safety-policy gate for the SDK-tab write dispatchers (SDK-03).
    .DESCRIPTION
        Pure/synchronous, never-throws Safety policy enforcement shared by the five
        Invoke-SPGuiSdk*Action dispatchers. Reads the toolkit Safety config
        defensively (Get-SPConfig in a try, PSObject guards, [bool]/[int] casts with
        fail-safe defaults) and decides whether a write may proceed:

          (a) AllowCompleteCampaign terminal gate (plan req 2). Terminal/destructive
              verbs (passed with -IsTerminal) require Safety.AllowCompleteCampaign to
              be $true. Default config = $false, so terminal verbs are BLOCKED unless
              explicitly enabled. If the config cannot be read or has no Safety block,
              the gate FAILS SAFE (terminal verbs blocked).

          (b) MaxCampaignsPerRun bulk cap (plan req 4, never silently truncate). When
              a dispatcher acts on a count (-ItemCount) above Safety.MaxCampaignsPerRun
              (default 10), the gate BLOCKS and names the count + cap. The caller does
              NOT truncate -- the whole action is refused.

        RequireWhatIfOnProd (plan req 1) is NOT enforced here: the bridge runs in a
        background STA runspace (plan WPF note 3) with NO UI thread, so it cannot show
        the confirmation MessageBox. That interactive prompt is owned by the SDK-11 UI
        click-handlers (mirroring SP.MainWindow.psm1 Invoke-GuiTestRun, which prompts
        on the UI thread BEFORE spawning the runspace). The bridge gate is the
        enforcement of record; the MessageBox is advisory UX layered on top. See
        round-03.md (Plan disagreement).

        PRIVATE: not added to Export-ModuleMember.
    .OUTPUTS
        @{ Allowed=$bool; Error=$string }  (Error is $null when Allowed)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter()] [int]$ItemCount = 1,
        [Parameter()] [switch]$IsTerminal,
        [Parameter()] [switch]$IsBulk,
        [Parameter()] [string]$CorrelationID
    )

    # Defensive Safety-config read (idiom from SP.DeltaCertRunner.psm1:1052-1059):
    # Get-SPConfig in a try; guard every hop; cast; fail safe to blocked defaults.
    $allowComplete = $false
    $maxPerRun = 10
    try {
        $config = Get-SPConfig
        if ($null -ne $config -and
            $null -ne $config.PSObject.Properties['Safety'] -and
            $null -ne $config.Safety) {
            if ($config.Safety.PSObject.Properties.Name -contains 'AllowCompleteCampaign') {
                $allowComplete = [bool]$config.Safety.AllowCompleteCampaign
            }
            if ($config.Safety.PSObject.Properties.Name -contains 'MaxCampaignsPerRun') {
                $maxPerRun = [int]$config.Safety.MaxCampaignsPerRun
            }
        }
    }
    catch {
        # Fail safe: leave $allowComplete=$false (terminal verbs blocked) and keep the
        # conservative default cap. Never throw out of the gate.
        Write-SPLog -Message "Test-SPGuiSdkSafetyGate: config read failed, failing safe (blocked): $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.SdkBridge' -Action 'Test-SPGuiSdkSafetyGate' -CorrelationID $CorrelationID
    }

    # (b) Bulk cap -- never silently truncate. Refuse the whole action.
    if ($IsBulk -and $ItemCount -gt $maxPerRun) {
        return @{
            Allowed = $false
            Error   = "blocked by Safety: $ItemCount items exceeds Safety.MaxCampaignsPerRun ($maxPerRun)"
        }
    }

    # (a) Terminal/destructive gate -- requires AllowCompleteCampaign.
    if ($IsTerminal -and -not $allowComplete) {
        return @{
            Allowed = $false
            Error   = "blocked by Safety: action '$Action' is terminal/destructive and Safety.AllowCompleteCampaign is false"
        }
    }

    return @{ Allowed = $true; Error = $null }
}

#endregion

#region Campaign Templates

function Get-SPGuiSdkCampaignTemplates {
    <#
    .SYNOPSIS
        Load campaign templates for the SDK tab Templates DataGrid.
    .DESCRIPTION
        Wraps Get-SPSdkCampaignTemplates and, for each template, calls
        Get-SPSdkTemplateSchedule to determine whether a schedule exists.
        A schedule 404 (the backing read returns Success=$true / Data=$null)
        is treated as Scheduled=$false and surfaces no error.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$Filters,
        [Parameter()] [string]$Sorters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $params = @{
            Limit         = $Limit
            Offset        = $Offset
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) { $params['Filters'] = $Filters }
        if (-not [string]::IsNullOrWhiteSpace($Sorters)) { $params['Sorters'] = $Sorters }

        $result = Get-SPSdkCampaignTemplates @params

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($template in @($result.Data)) {
            $scheduled = $false
            if ($null -ne $template.id) {
                $schedResult = Get-SPSdkTemplateSchedule -TemplateId $template.id -CorrelationID $CorrelationID
                if ($schedResult.Success -and $null -ne $schedResult.Data) {
                    $scheduled = $true
                }
            }

            [PSCustomObject]@{
                IsSelected = $false
                Name       = if ($null -ne $template.name)             { [string]$template.name }             else { '' }
                Id         = if ($null -ne $template.id)               { [string]$template.id }               else { '' }
                Deadline   = if ($null -ne $template.deadlineDuration) { [string]$template.deadlineDuration } else { '' }
                Scheduled  = $scheduled
                Modified   = if ($null -ne $template.modified)         { [string]$template.modified }         else { '' }
                Owner      = if ($null -ne $template.ownerRef -and $null -ne $template.ownerRef.name) { [string]$template.ownerRef.name } else { '' }
                _Raw       = $template
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkCampaignTemplates failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkCampaignTemplates' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkCampaignTemplates failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Approvals

function Get-SPGuiSdkApprovals {
    <#
    .SYNOPSIS
        Load pending or completed access-request approvals for the SDK tab.
    .DESCRIPTION
        Routes to Get-SPSdkPendingApprovals (-State Pending) or
        Get-SPSdkCompletedApprovals (-State Completed) and emits the matching
        column set.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('Pending', 'Completed')]
        [string]$State = 'Pending',

        [Parameter()] [string]$OwnerId,
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $params = @{
            Limit         = $Limit
            Offset        = $Offset
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($OwnerId)) { $params['OwnerId'] = $OwnerId }

        if ($State -eq 'Completed') {
            $result = Get-SPSdkCompletedApprovals @params
        }
        else {
            $result = Get-SPSdkPendingApprovals @params
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($approval in @($result.Data)) {
            if ($State -eq 'Completed') {
                [PSCustomObject]@{
                    IsSelected   = $false
                    Name         = if ($null -ne $approval.name)         { [string]$approval.name }         else { '' }
                    Requester    = if ($null -ne $approval.requestedBy   -and $null -ne $approval.requestedBy.name)  { [string]$approval.requestedBy.name }  else { '' }
                    RequestedFor = if ($null -ne $approval.requestedFor  -and $null -ne $approval.requestedFor.name) { [string]$approval.requestedFor.name } else { '' }
                    State        = if ($null -ne $approval.state)        { [string]$approval.state }        else { '' }
                    ReviewedBy   = if ($null -ne $approval.reviewedBy    -and $null -ne $approval.reviewedBy.name)   { [string]$approval.reviewedBy.name }   else { '' }
                    Modified     = if ($null -ne $approval.modified)     { [string]$approval.modified }     else { '' }
                    _Raw         = $approval
                }
            }
            else {
                [PSCustomObject]@{
                    IsSelected   = $false
                    Name         = if ($null -ne $approval.name)         { [string]$approval.name }         else { '' }
                    Requester    = if ($null -ne $approval.requestedBy   -and $null -ne $approval.requestedBy.name)  { [string]$approval.requestedBy.name }  else { '' }
                    RequestedFor = if ($null -ne $approval.requestedFor  -and $null -ne $approval.requestedFor.name) { [string]$approval.requestedFor.name } else { '' }
                    RequestType  = if ($null -ne $approval.requestType)  { [string]$approval.requestType }  else { '' }
                    Created      = if ($null -ne $approval.created)      { [string]$approval.created }      else { '' }
                    Owner        = if ($null -ne $approval.owner         -and $null -ne $approval.owner.name)        { [string]$approval.owner.name }        else { '' }
                    _Raw         = $approval
                }
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkApprovals failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkApprovals' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkApprovals failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Work Items

function Get-SPGuiSdkWorkItems {
    <#
    .SYNOPSIS
        Load work items plus their open/completed/total summary for the SDK tab.
    .DESCRIPTION
        Wraps Get-SPSdkWorkItems for the grid rows and Get-SPSdkWorkItemsSummary
        for the badge counts, returning both in one hashtable (SDK-BR-004 shape):
        @{ Success; Data=@(rows); Summary=@{Open;Completed;Total}; Error }.
        A summary-call failure is non-fatal: rows are still returned and Summary
        falls back to zeroed counts.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Summary=@{Open;Completed;Total}; Error=$string }
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

    try {
        $rowParams = @{
            Limit         = $Limit
            Offset        = $Offset
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($OwnerId)) { $rowParams['OwnerId'] = $OwnerId }

        $result = Get-SPSdkWorkItems @rowParams

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Summary = @{ Open = 0; Completed = 0; Total = 0 }; Error = $result.Error }
        }

        $displayItems = foreach ($workItem in @($result.Data)) {
            [PSCustomObject]@{
                IsSelected  = $false
                Type        = if ($null -ne $workItem.type)        { [string]$workItem.type }        else { '' }
                Description = if ($null -ne $workItem.description)  { [string]$workItem.description }  else { '' }
                Owner       = if ($null -ne $workItem.ownerName)    { [string]$workItem.ownerName }    elseif ($null -ne $workItem.owner -and $null -ne $workItem.owner.name) { [string]$workItem.owner.name } else { '' }
                State       = if ($null -ne $workItem.state)        { [string]$workItem.state }        else { '' }
                Created     = if ($null -ne $workItem.created)      { [string]$workItem.created }      else { '' }
                NumItems    = if ($null -ne $workItem.numItems)     { [int]$workItem.numItems }        else { 0 }
                _Raw        = $workItem
            }
        }

        # Summary badges (non-fatal if it fails)
        $summary = @{ Open = 0; Completed = 0; Total = 0 }
        $summaryParams = @{ CorrelationID = $CorrelationID }
        if (-not [string]::IsNullOrWhiteSpace($OwnerId)) { $summaryParams['OwnerId'] = $OwnerId }
        $summaryResult = Get-SPSdkWorkItemsSummary @summaryParams
        if ($summaryResult.Success -and $null -ne $summaryResult.Data) {
            $s = $summaryResult.Data
            $summary = @{
                Open      = if ($null -ne $s.open)      { [int]$s.open }      else { 0 }
                Completed = if ($null -ne $s.completed) { [int]$s.completed } else { 0 }
                Total     = if ($null -ne $s.total)     { [int]$s.total }     else { 0 }
            }
        }
        else {
            Write-SPLog -Message "Get-SPGuiSdkWorkItems: summary unavailable: $($summaryResult.Error)" `
                -Severity WARN -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkWorkItems' -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = @($displayItems); Summary = $summary; Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkWorkItems failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkWorkItems' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Summary = @{ Open = 0; Completed = 0; Total = 0 }; Error = "Get-SPGuiSdkWorkItems failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Workflows

function Get-SPGuiSdkWorkflows {
    <#
    .SYNOPSIS
        Load workflows for the SDK tab Workflows DataGrid.
    .DESCRIPTION
        Wraps Get-SPSdkWorkflows and shapes each workflow into a checkbox-
        selectable display row.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
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

    try {
        $params = @{
            Limit         = $Limit
            Offset        = $Offset
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) { $params['Filters'] = $Filters }
        if (-not [string]::IsNullOrWhiteSpace($Sorters)) { $params['Sorters'] = $Sorters }

        $result = Get-SPSdkWorkflows @params

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($workflow in @($result.Data)) {
            [PSCustomObject]@{
                IsSelected     = $false
                Name           = if ($null -ne $workflow.name)    { [string]$workflow.name } else { '' }
                Id             = if ($null -ne $workflow.id)      { [string]$workflow.id }   else { '' }
                Enabled        = if ($null -ne $workflow.enabled) { [bool]$workflow.enabled } else { $false }
                TriggerType    = if ($null -ne $workflow.trigger -and $null -ne $workflow.trigger.type) { [string]$workflow.trigger.type } else { '' }
                ExecutionCount = if ($null -ne $workflow.executionCount) { [int]$workflow.executionCount } else { 0 }
                FailureCount   = if ($null -ne $workflow.failureCount)   { [int]$workflow.failureCount }   else { 0 }
                Modified       = if ($null -ne $workflow.modified) { [string]$workflow.modified } else { '' }
                _Raw           = $workflow
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkWorkflows failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkWorkflows' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkWorkflows failed: $($_.Exception.Message)" }
    }
}

function Get-SPGuiSdkWorkflowExecutions {
    <#
    .SYNOPSIS
        Load executions for a single workflow (read-only) for the SDK tab.
    .DESCRIPTION
        Wraps Get-SPSdkWorkflowExecutions. Read-only grid: rows do not carry an
        IsSelected flag.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
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

    try {
        $params = @{
            WorkflowId    = $WorkflowId
            Limit         = $Limit
            Offset        = $Offset
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) { $params['Filters'] = $Filters }

        $result = Get-SPSdkWorkflowExecutions @params

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($execution in @($result.Data)) {
            [PSCustomObject]@{
                ExecutionId = if ($null -ne $execution.id)         { [string]$execution.id }         else { '' }
                Status      = if ($null -ne $execution.status)     { [string]$execution.status }     else { '' }
                StartTime   = if ($null -ne $execution.startTime)  { [string]$execution.startTime }  else { '' }
                CloseTime   = if ($null -ne $execution.closeTime)  { [string]$execution.closeTime }  else { '' }
                WorkflowId  = if ($null -ne $execution.workflowId) { [string]$execution.workflowId } else { [string]$WorkflowId }
                _Raw        = $execution
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkWorkflowExecutions failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkWorkflowExecutions' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkWorkflowExecutions failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Campaign Filters

function Get-SPGuiSdkCampaignFilters {
    <#
    .SYNOPSIS
        Load campaign filters for the SDK tab Filters DataGrid.
    .DESCRIPTION
        Wraps Get-SPSdkCampaignFilters. The backing read takes a bool
        -IncludeSystemFilters (default $true). To preserve include-all behavior
        by default in PowerShell, this bridge inverts the switch: when
        -IncludeSystem is NOT supplied the bridge forwards
        -IncludeSystemFilters:$true (show everything); when -IncludeSystem IS
        supplied it forwards -IncludeSystemFilters:$true as well -- i.e. the
        switch is an explicit "include system filters" affordance and the
        DEFAULT remains include-all. See round-01.md (Plan disagreement 3).
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [switch]$IncludeSystem,
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # Default semantics: preserve include-all. The switch never narrows the
        # result below the backing default of include-system=true.
        $includeSystemFilters = $true

        $result = Get-SPSdkCampaignFilters `
            -IncludeSystemFilters:$includeSystemFilters `
            -Limit $Limit -Offset $Offset -CorrelationID $CorrelationID

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($filter in @($result.Data)) {
            [PSCustomObject]@{
                IsSelected   = $false
                Name         = if ($null -ne $filter.name)        { [string]$filter.name }        else { '' }
                Id           = if ($null -ne $filter.id)          { [string]$filter.id }          else { '' }
                Mode         = if ($null -ne $filter.mode)        { [string]$filter.mode }        else { '' }
                Description  = if ($null -ne $filter.description) { [string]$filter.description } else { '' }
                SystemFilter = if ($null -ne $filter.isSystemFilter) { [bool]$filter.isSystemFilter } elseif ($null -ne $filter.systemFilter) { [bool]$filter.systemFilter } else { $false }
                Modified     = if ($null -ne $filter.modified)    { [string]$filter.modified }    else { '' }
                _Raw         = $filter
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkCampaignFilters failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkCampaignFilters' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkCampaignFilters failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Certification Summaries (SCOPE-GATED -- see SDK-18)

function Get-SPGuiSdkCertSummaries {
    <#
    .SYNOPSIS
        Load identity or access summaries for a certification (SDK tab).
    .DESCRIPTION
        Wraps Get-SPSdkIdentitySummaries (-SummaryType Identity) or
        Get-SPSdkAccessSummaries (-SummaryType Access; -AccessType selects the
        ROLE/ACCESS_PROFILE/ENTITLEMENT sub-resource, default ENTITLEMENT).
        SCOPE-GATED: the mock seed has no verified cert-summary fixtures (SDK-18);
        the function is wired live to the existing backings so SDK-04/06 surface
        stays stable. Returns the standard @{Success;Data;Error} envelope.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [ValidateSet('Identity', 'Access')]
        [string]$SummaryType = 'Identity',

        [Parameter()] [string]$AccessType,
        [Parameter()] [int]$Limit = 250,
        [Parameter()] [int]$Offset = 0,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        if ($SummaryType -eq 'Access') {
            $resolvedType = if (-not [string]::IsNullOrWhiteSpace($AccessType)) { $AccessType } else { 'ENTITLEMENT' }
            $result = Get-SPSdkAccessSummaries -CertificationId $CertificationId -Type $resolvedType `
                -Limit $Limit -Offset $Offset -CorrelationID $CorrelationID
        }
        else {
            $result = Get-SPSdkIdentitySummaries -CertificationId $CertificationId `
                -Limit $Limit -Offset $Offset -CorrelationID $CorrelationID
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($summary in @($result.Data)) {
            [PSCustomObject]@{
                IsSelected = $false
                Name       = if ($null -ne $summary.name)        { [string]$summary.name }        else { '' }
                Id         = if ($null -ne $summary.id)          { [string]$summary.id }          else { '' }
                Completed  = if ($null -ne $summary.completed)   { [bool]$summary.completed }     else { $false }
                _Raw       = $summary
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkCertSummaries failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkCertSummaries' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkCertSummaries failed: $($_.Exception.Message)" }
    }
}

function Get-SPGuiSdkDecisionSummary {
    <#
    .SYNOPSIS
        Load the decision summary for a certification (SDK tab).
    .DESCRIPTION
        Wraps Get-SPSdkDecisionSummary. The backing read returns a single
        (non-paginated) summary object; this bridge surfaces it as a single-row
        Data array for grid binding. SCOPE-GATED (SDK-18): wired live to the
        existing backing.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject]); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()] [string]$Filters,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        $params = @{
            CertificationId = $CertificationId
            CorrelationID   = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($Filters)) { $params['Filters'] = $Filters }

        $result = Get-SPSdkDecisionSummary @params

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($summary in @($result.Data)) {
            [PSCustomObject]@{
                IsSelected = $false
                _Raw       = $summary
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkDecisionSummary failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkDecisionSummary' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkDecisionSummary failed: $($_.Exception.Message)" }
    }
}

function Get-SPGuiSdkCertCampaigns {
    <#
    .SYNOPSIS
        Populate the SDK tab certification campaign comboboxes (SCOPE-GATED).
    .DESCRIPTION
        Intended to feed campaign-selection comboboxes. The plan cited
        SP.Api/SP.Certifications, which DOES NOT EXIST -- SP.Api exposes only
        Get-SPCampaign (single, by ID) and there is no campaign-list function in
        SP.Api. The existing GUI campaign cache lives behind Get-SPGuiAuditCampaigns
        in SP.GuiBridge, so this bridge backs onto that (default look-back) when
        available, returning Id/Name pairs for combobox binding.

        If Get-SPGuiAuditCampaigns is not loaded (e.g. SP.GuiBridge absent), the
        function returns the standard envelope with Success=$false and a
        descriptive Error rather than throwing -- this keeps the SDK-04/06 surface
        stable until SDK-18 finalizes the cert sub-tab.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject]); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        if (-not (Get-Command -Name Get-SPGuiAuditCampaigns -ErrorAction SilentlyContinue)) {
            return @{
                Success = $false
                Data    = @()
                Error   = 'Cert campaign list unavailable: no SP.Api campaign-list function exists and Get-SPGuiAuditCampaigns (SP.GuiBridge) is not loaded. Finalize under SDK-18.'
            }
        }

        $result = Get-SPGuiAuditCampaigns

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($campaign in @($result.Data)) {
            [PSCustomObject]@{
                Id   = if ($null -ne $campaign.CampaignId)   { [string]$campaign.CampaignId }   else { '' }
                Name = if ($null -ne $campaign.CampaignName) { [string]$campaign.CampaignName } else { '' }
                _Raw = $campaign
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiSdkCertCampaigns failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Get-SPGuiSdkCertCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiSdkCertCampaigns failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Campaign Templates (WRITE)

function Invoke-SPGuiSdkTemplateAction {
    <#
    .SYNOPSIS
        Write dispatcher for campaign-template actions (SDK tab).
    .DESCRIPTION
        Routes -Action to the matching SP.Sdk write function:
          Create         -> New-SPSdkCampaignTemplate    (requires -Template)
          Update         -> Update-SPSdkCampaignTemplate (requires -TemplateId, -PatchOperations)
          Delete         -> Remove-SPSdkCampaignTemplate (requires -TemplateId)
          SetSchedule    -> Set-SPSdkTemplateSchedule    (requires -TemplateId, -Schedule)
          RemoveSchedule -> Remove-SPSdkTemplateSchedule (requires -TemplateId)

        ValidateSet is the PRIMARY unknown-verb guard (a verb outside the set is a
        parameter-binding error); the switch's default arm is the belt-and-suspenders
        path the Accept asks for (returns Success=$false / 'Unknown action: ...').

        Pure/synchronous and never throws: the whole body is wrapped in try/catch and
        failures return @{Success=$false; Data=@(); Error=<message>}. No UI, no
        Dispatcher, no $script: state -- safe to call from a background runspace.
    .OUTPUTS
        @{ Success=$bool; Data=$object; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Update', 'Delete', 'SetSchedule', 'RemoveSchedule')]
        [string]$Action,

        [Parameter()] [string]$TemplateId,
        [Parameter()] [hashtable]$Template,
        [Parameter()] $PatchOperations,
        [Parameter()] [hashtable]$Schedule,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # SDK-03 Safety / What-If gate: Template Delete and RemoveSchedule are
        # terminal/destructive (gated by Safety.AllowCompleteCampaign). Create /
        # Update / SetSchedule are non-terminal and pass through ungated.

        switch ($Action) {
            'Create' {
                if ($null -eq $Template) {
                    return @{ Success = $false; Data = @(); Error = 'Action Create requires -Template' }
                }
                $result = New-SPSdkCampaignTemplate -Template $Template -CorrelationID $CorrelationID
            }
            'Update' {
                if ([string]::IsNullOrWhiteSpace($TemplateId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Update requires -TemplateId' }
                }
                if ($null -eq $PatchOperations) {
                    return @{ Success = $false; Data = @(); Error = 'Action Update requires -PatchOperations' }
                }
                $result = Update-SPSdkCampaignTemplate -TemplateId $TemplateId -PatchOperations $PatchOperations -CorrelationID $CorrelationID
            }
            'Delete' {
                if ([string]::IsNullOrWhiteSpace($TemplateId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Delete requires -TemplateId' }
                }
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -ItemCount 1 -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $result = Remove-SPSdkCampaignTemplate -TemplateId $TemplateId -CorrelationID $CorrelationID
            }
            'SetSchedule' {
                if ([string]::IsNullOrWhiteSpace($TemplateId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action SetSchedule requires -TemplateId' }
                }
                if ($null -eq $Schedule) {
                    return @{ Success = $false; Data = @(); Error = 'Action SetSchedule requires -Schedule' }
                }
                $result = Set-SPSdkTemplateSchedule -TemplateId $TemplateId -Schedule $Schedule -CorrelationID $CorrelationID
            }
            'RemoveSchedule' {
                if ([string]::IsNullOrWhiteSpace($TemplateId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action RemoveSchedule requires -TemplateId' }
                }
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -ItemCount 1 -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $result = Remove-SPSdkTemplateSchedule -TemplateId $TemplateId -CorrelationID $CorrelationID
            }
            default {
                return @{ Success = $false; Data = @(); Error = "Unknown action: $Action" }
            }
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }
        return @{ Success = $true; Data = $result.Data; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiSdkTemplateAction failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Invoke-SPGuiSdkTemplateAction' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Invoke-SPGuiSdkTemplateAction failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Approvals (WRITE)

function Invoke-SPGuiSdkApprovalAction {
    <#
    .SYNOPSIS
        Write dispatcher for access-request approval actions (SDK tab).
    .DESCRIPTION
        Routes -Action to the matching SP.Sdk write function:
          Approve -> Approve-SPSdkAccessRequest (requires -ApprovalId; -Comment optional)
          Deny    -> Deny-SPSdkAccessRequest    (requires -ApprovalId, -Comment)
          Forward -> Forward-SPSdkAccessRequest (requires -ApprovalId, -NewOwnerId, -Comment)

        ValidateSet is the PRIMARY unknown-verb guard; the default arm is the explicit
        Accept-satisfying path. Never throws (try/catch). No UI/Safety code here --
        SDK-03 adds gates.
    .OUTPUTS
        @{ Success=$bool; Data=$object; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Approve', 'Deny', 'Forward')]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApprovalId,

        [Parameter()] [string]$Comment,
        [Parameter()] [string]$NewOwnerId,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # SDK-03 Safety / What-If gate: approval verbs (Approve/Deny/Forward) are
        # routing-only here. Per the SDK-03 Accept they are NOT AllowCompleteCampaign-
        # gated (the gate fires for the work-item/template/filter terminal verbs).
        # The interactive RequireWhatIfOnProd confirmation for Deny/Forward is owned by
        # the SDK-11 UI click-handlers (no UI thread in this background runspace). See
        # round-03.md (Plan disagreement).

        switch ($Action) {
            'Approve' {
                $params = @{ ApprovalId = $ApprovalId; CorrelationID = $CorrelationID }
                if (-not [string]::IsNullOrWhiteSpace($Comment)) { $params['Comment'] = $Comment }
                $result = Approve-SPSdkAccessRequest @params
            }
            'Deny' {
                if ([string]::IsNullOrWhiteSpace($Comment)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Deny requires -Comment' }
                }
                $result = Deny-SPSdkAccessRequest -ApprovalId $ApprovalId -Comment $Comment -CorrelationID $CorrelationID
            }
            'Forward' {
                if ([string]::IsNullOrWhiteSpace($NewOwnerId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Forward requires -NewOwnerId' }
                }
                if ([string]::IsNullOrWhiteSpace($Comment)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Forward requires -Comment' }
                }
                $result = Forward-SPSdkAccessRequest -ApprovalId $ApprovalId -NewOwnerId $NewOwnerId -Comment $Comment -CorrelationID $CorrelationID
            }
            default {
                return @{ Success = $false; Data = @(); Error = "Unknown action: $Action" }
            }
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }
        return @{ Success = $true; Data = $result.Data; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiSdkApprovalAction failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Invoke-SPGuiSdkApprovalAction' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Invoke-SPGuiSdkApprovalAction failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Work Items (WRITE)

function Invoke-SPGuiSdkWorkItemAction {
    <#
    .SYNOPSIS
        Write dispatcher for work-item actions (SDK tab).
    .DESCRIPTION
        Routes -Action to the matching SP.Sdk write function:
          Complete    -> Complete-SPSdkWorkItem          (requires -WorkItemId; -Body optional)
          Forward     -> Forward-SPSdkWorkItem           (requires -WorkItemId, -TargetOwnerId, -Comment; -SendNotifications optional)
          BulkApprove -> Invoke-SPSdkBulkApproveWorkItem (requires -WorkItemId)
          BulkReject  -> Invoke-SPSdkBulkRejectWorkItem  (requires -WorkItemId)

        ValidateSet is the PRIMARY unknown-verb guard; the default arm is the explicit
        Accept-satisfying path. Never throws (try/catch). No UI/Safety code here --
        SDK-03 adds gates.
    .OUTPUTS
        @{ Success=$bool; Data=$object; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Complete', 'Forward', 'BulkApprove', 'BulkReject')]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkItemId,

        [Parameter()] [string]$TargetOwnerId,
        [Parameter()] [string]$Comment,
        [Parameter()] [bool]$SendNotifications = $true,
        [Parameter()] [string]$Body,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # SDK-03 Safety / What-If gate: Complete / BulkApprove / BulkReject are
        # terminal/destructive (gated by Safety.AllowCompleteCampaign). Forward is a
        # non-terminal hand-off and passes through ungated.

        switch ($Action) {
            'Complete' {
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -ItemCount 1 -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $params = @{ WorkItemId = $WorkItemId; CorrelationID = $CorrelationID }
                if (-not [string]::IsNullOrWhiteSpace($Body)) { $params['Body'] = $Body }
                $result = Complete-SPSdkWorkItem @params
            }
            'Forward' {
                if ([string]::IsNullOrWhiteSpace($TargetOwnerId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Forward requires -TargetOwnerId' }
                }
                if ([string]::IsNullOrWhiteSpace($Comment)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Forward requires -Comment' }
                }
                $params = @{
                    WorkItemId        = $WorkItemId
                    TargetOwnerId     = $TargetOwnerId
                    Comment           = $Comment
                    SendNotifications = $SendNotifications
                    CorrelationID     = $CorrelationID
                }
                $result = Forward-SPSdkWorkItem @params
            }
            'BulkApprove' {
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -ItemCount 1 -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $result = Invoke-SPSdkBulkApproveWorkItem -WorkItemId $WorkItemId -CorrelationID $CorrelationID
            }
            'BulkReject' {
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -ItemCount 1 -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $result = Invoke-SPSdkBulkRejectWorkItem -WorkItemId $WorkItemId -CorrelationID $CorrelationID
            }
            default {
                return @{ Success = $false; Data = @(); Error = "Unknown action: $Action" }
            }
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }
        return @{ Success = $true; Data = $result.Data; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiSdkWorkItemAction failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Invoke-SPGuiSdkWorkItemAction' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Invoke-SPGuiSdkWorkItemAction failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Workflows (WRITE)

function Invoke-SPGuiSdkWorkflowAction {
    <#
    .SYNOPSIS
        Write dispatcher for workflow actions (SDK tab).
    .DESCRIPTION
        Routes -Action to the matching SP.Sdk write function:
          Toggle    -> Update-SPSdkWorkflow         (requires -WorkflowId, -Enabled; PATCH /enabled)
          Test      -> Test-SPSdkWorkflow           (requires -WorkflowId, -TestInput)
          CreateOOO -> Set-SPSdkOOOFallbackWorkflow (requires -PrimaryReviewerId, -FallbackReviewerId; -FallbackDays/-WorkflowName optional)

        PLAN DISAGREEMENT (resolved in favour of the code -- see round-02.md): the
        mapping table maps Toggle -> Set-SPSdkWorkflow, but that backing is a full PUT
        requiring a complete WorkflowBody the GUI does not hold. Toggle is therefore
        implemented via Update-SPSdkWorkflow (PATCH /workflows/{id},
        application/json-patch+json) with a single replace op on '/enabled'.

        ValidateSet is the PRIMARY unknown-verb guard; the default arm is the explicit
        Accept-satisfying path. Never throws (try/catch). No UI/Safety code here --
        SDK-03 adds gates.
    .OUTPUTS
        @{ Success=$bool; Data=$object; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Toggle', 'Test', 'CreateOOO')]
        [string]$Action,

        [Parameter()] [string]$WorkflowId,
        [Parameter()] [bool]$Enabled,
        [Parameter()] $PatchOperations,
        [Parameter()] [hashtable]$TestInput,
        [Parameter()] [string]$PrimaryReviewerId,
        [Parameter()] [string]$FallbackReviewerId,
        [Parameter()] [int]$FallbackDays = 3,
        [Parameter()] [string]$WorkflowName,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # SDK-03 Safety / What-If gate: workflow verbs (Toggle/Test/CreateOOO) are
        # routing-only here. Per the SDK-03 Accept they are NOT AllowCompleteCampaign-
        # gated (the gate fires for the work-item/template/filter terminal verbs). The
        # interactive RequireWhatIfOnProd confirmation for disable/Test/CreateOOO is
        # owned by the SDK-11 UI click-handlers (no UI thread in this background
        # runspace). See round-03.md (Plan disagreement).

        switch ($Action) {
            'Toggle' {
                if ([string]::IsNullOrWhiteSpace($WorkflowId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Toggle requires -WorkflowId' }
                }
                if (-not $PSBoundParameters.ContainsKey('Enabled')) {
                    return @{ Success = $false; Data = @(); Error = 'Action Toggle requires -Enabled' }
                }
                $ops = @(New-SPSdkPatchReplace -Path '/enabled' -Value $Enabled -CorrelationID $CorrelationID)
                $result = Update-SPSdkWorkflow -WorkflowId $WorkflowId -PatchOperations $ops -CorrelationID $CorrelationID
            }
            'Test' {
                if ([string]::IsNullOrWhiteSpace($WorkflowId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action Test requires -WorkflowId' }
                }
                if ($null -eq $TestInput) {
                    return @{ Success = $false; Data = @(); Error = 'Action Test requires -TestInput' }
                }
                $result = Test-SPSdkWorkflow -WorkflowId $WorkflowId -TestInput $TestInput -CorrelationID $CorrelationID
            }
            'CreateOOO' {
                if ([string]::IsNullOrWhiteSpace($PrimaryReviewerId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action CreateOOO requires -PrimaryReviewerId' }
                }
                if ([string]::IsNullOrWhiteSpace($FallbackReviewerId)) {
                    return @{ Success = $false; Data = @(); Error = 'Action CreateOOO requires -FallbackReviewerId' }
                }
                $params = @{
                    PrimaryReviewerId  = $PrimaryReviewerId
                    FallbackReviewerId = $FallbackReviewerId
                    CorrelationID      = $CorrelationID
                }
                if ($PSBoundParameters.ContainsKey('FallbackDays')) { $params['FallbackDays'] = $FallbackDays }
                if (-not [string]::IsNullOrWhiteSpace($WorkflowName)) { $params['WorkflowName'] = $WorkflowName }
                $result = Set-SPSdkOOOFallbackWorkflow @params
            }
            default {
                return @{ Success = $false; Data = @(); Error = "Unknown action: $Action" }
            }
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }
        return @{ Success = $true; Data = $result.Data; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiSdkWorkflowAction failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Invoke-SPGuiSdkWorkflowAction' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Invoke-SPGuiSdkWorkflowAction failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Campaign Filters (WRITE)

function Invoke-SPGuiSdkFilterAction {
    <#
    .SYNOPSIS
        Write dispatcher for campaign-filter actions (SDK tab).
    .DESCRIPTION
        Routes -Action to the matching SP.Sdk write function:
          Create -> New-SPSdkCampaignFilter    (requires -Filter)
          Update -> Update-SPSdkCampaignFilter (requires a SINGLE -FilterId, -Filter)
          Delete -> Remove-SPSdkCampaignFilter (requires -FilterId; accepts one or many)

        ASYMMETRY (intentional, mirrors the backings): Update takes a single FilterId
        (full-replacement POST /campaign-filters/{id}); Delete takes a string[] (bulk
        POST /campaign-filters/delete). On Update the dispatcher uses the first id.

        ValidateSet is the PRIMARY unknown-verb guard; the default arm is the explicit
        Accept-satisfying path. Never throws (try/catch). No UI/Safety code here --
        SDK-03 adds gates.
    .OUTPUTS
        @{ Success=$bool; Data=$object; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Update', 'Delete')]
        [string]$Action,

        [Parameter()] [string[]]$FilterId,
        [Parameter()] [hashtable]$Filter,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # SDK-03 Safety / What-If gate: Delete is terminal/destructive AND bulk-capable
        # -- gated by Safety.AllowCompleteCampaign AND Safety.MaxCampaignsPerRun (never
        # silently truncates). Create / Update are non-terminal and pass through ungated.

        switch ($Action) {
            'Create' {
                if ($null -eq $Filter) {
                    return @{ Success = $false; Data = @(); Error = 'Action Create requires -Filter' }
                }
                $result = New-SPSdkCampaignFilter -Filter $Filter -CorrelationID $CorrelationID
            }
            'Update' {
                if ($null -eq $FilterId -or @($FilterId).Count -eq 0 -or [string]::IsNullOrWhiteSpace(@($FilterId)[0])) {
                    return @{ Success = $false; Data = @(); Error = 'Action Update requires -FilterId' }
                }
                if ($null -eq $Filter) {
                    return @{ Success = $false; Data = @(); Error = 'Action Update requires -Filter' }
                }
                $result = Update-SPSdkCampaignFilter -FilterId @($FilterId)[0] -Filter $Filter -CorrelationID $CorrelationID
            }
            'Delete' {
                if ($null -eq $FilterId -or @($FilterId).Count -eq 0 -or [string]::IsNullOrWhiteSpace(@($FilterId)[0])) {
                    return @{ Success = $false; Data = @(); Error = 'Action Delete requires -FilterId' }
                }
                $gate = Test-SPGuiSdkSafetyGate -Action $Action -IsTerminal -IsBulk -ItemCount @($FilterId).Count -CorrelationID $CorrelationID
                if (-not $gate.Allowed) { return @{ Success = $false; Data = @(); Error = $gate.Error } }
                $result = Remove-SPSdkCampaignFilter -FilterId $FilterId -CorrelationID $CorrelationID
            }
            default {
                return @{ Success = $false; Data = @(); Error = "Unknown action: $Action" }
            }
        }

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }
        return @{ Success = $true; Data = $result.Data; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiSdkFilterAction failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.SdkBridge' -Action 'Invoke-SPGuiSdkFilterAction' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = @(); Error = "Invoke-SPGuiSdkFilterAction failed: $($_.Exception.Message)" }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPGuiSdkCampaignTemplates',
    'Get-SPGuiSdkApprovals',
    'Get-SPGuiSdkWorkItems',
    'Get-SPGuiSdkWorkflows',
    'Get-SPGuiSdkWorkflowExecutions',
    'Get-SPGuiSdkCampaignFilters',
    'Get-SPGuiSdkCertSummaries',
    'Get-SPGuiSdkDecisionSummary',
    'Get-SPGuiSdkCertCampaigns',
    'Invoke-SPGuiSdkTemplateAction',
    'Invoke-SPGuiSdkApprovalAction',
    'Invoke-SPGuiSdkWorkItemAction',
    'Invoke-SPGuiSdkWorkflowAction',
    'Invoke-SPGuiSdkFilterAction'
)
