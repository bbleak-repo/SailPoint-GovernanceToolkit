#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Decision Actions
.DESCRIPTION
    Provides functions to submit decisions (approve/revoke/reassign),
    perform synchronous and asynchronous reassignments, and sign off
    on SailPoint ISC certifications.
    All HTTP calls are delegated to Invoke-SPApiRequest.
.NOTES
    Module: SP.Decisions
    Version: 1.0.0

    ISC API constraints (hard limits):
        Bulk decide:         max 250 items per call  (config: Testing.DecisionBatchSize)
        Reassign sync:       max  50 items per call  (config: Testing.ReassignSyncMax)
        Reassign async:      max 500 items per call  (config: Testing.ReassignAsyncMax)
#>

#region Internal Functions

function Split-SPItemsIntoBatches {
    <#
    .SYNOPSIS
        Splits an array of items into batches of a maximum size.
    .PARAMETER Items
        The full array of items to batch.
    .PARAMETER BatchSize
        Maximum items per batch.
    .OUTPUTS
        [System.Collections.Generic.List[object[]]] List of batches.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object[]]])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [int]$BatchSize
    )

    $batches = [System.Collections.Generic.List[object[]]]::new()
    $total   = $Items.Count
    $start   = 0

    while ($start -lt $total) {
        $end      = [Math]::Min($start + $BatchSize, $total)
        $batch    = $Items[$start..($end - 1)]
        $batches.Add($batch)
        $start    = $end
    }

    # Return with the comma operator so a single-batch result is not unwrapped
    # by the PowerShell pipeline. Without this, an input of exactly BatchSize
    # items (e.g. 250) would produce a 1-element list; PowerShell unwraps it
    # and the caller's foreach would iterate the inner item-id array instead
    # of the batch list - causing N individual API calls instead of 1.
    return ,$batches
}

#endregion

#region Public Functions

function Invoke-SPBulkDecide {
    <#
    .SYNOPSIS
        Submits bulk decisions for access review items in a certification.
    .DESCRIPTION
        POSTs to /certifications/{id}/decide.
        Automatically splits ReviewItemIds into batches at the configured
        Testing.DecisionBatchSize (max 250 per ISC API constraint).
        Collects and returns results from all batches.
    .PARAMETER CertificationId
        The certification ID to submit decisions for.
    .PARAMETER ReviewItemIds
        Array of access review item IDs to decide on.
    .PARAMETER Decision
        Decision to apply: APPROVE or REVOKE.
    .PARAMETER Comments
        Optional comment attached to each decision item.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{
            Success=$bool;
            Data=@{BatchResults=$array; TotalDecided=$int};
            Error=$string
        }
    .EXAMPLE
        $result = Invoke-SPBulkDecide -CertificationId 'cert-xyz' `
            -ReviewItemIds @('item-1','item-2') -Decision 'APPROVE' `
            -Comments 'Verified via UAT' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ReviewItemIds,

        [Parameter(Mandatory)]
        [ValidateSet('APPROVE', 'REVOKE', 'REASSIGN')]
        [string]$Decision,

        [Parameter()]
        [string]$Comments,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Read batch size from config with safe fallback
    $batchSize = 250
    try {
        $config    = Get-SPConfig
        $batchSize = $config.Testing.DecisionBatchSize
        if ($batchSize -le 0) { $batchSize = 250 }
    }
    catch {
        Write-SPLog -Message "Could not read Testing.DecisionBatchSize from config; using default 250." `
            -Severity WARN -Component 'SP.Decisions' -Action 'Invoke-SPBulkDecide' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
    }

    Write-SPLog -Message "Bulk decide: CertificationId='$CertificationId', Items=$($ReviewItemIds.Count), Decision='$Decision', BatchSize=$batchSize" `
        -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPBulkDecide' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $batches      = Split-SPItemsIntoBatches -Items $ReviewItemIds -BatchSize $batchSize
        $batchResults = [System.Collections.Generic.List[object]]::new()
        $totalDecided = 0
        $batchNum     = 0

        foreach ($batch in $batches) {
            $batchNum++
            Write-SPLog -Message "Deciding batch $batchNum of $($batches.Count): $($batch.Count) items" `
                -Severity DEBUG -Component 'SP.Decisions' -Action 'Invoke-SPBulkDecide' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            # Build decision items array for this batch.
            # M1: Use List[object] + .Add() rather than `$arr += $item`. The
            # latter reallocates the entire backing array on every append
            # (O(N^2)); for a 250-item batch that's ~32k object copies just
            # to build the request body. Negligible at small N, measurable
            # at full batch sizes.
            $decisionItemList = [System.Collections.Generic.List[object]]::new()
            foreach ($itemId in $batch) {
                $decisionItem = @{
                    id       = $itemId
                    decision = $Decision
                }
                if (-not [string]::IsNullOrWhiteSpace($Comments)) {
                    $decisionItem['comments'] = $Comments
                }
                $decisionItemList.Add($decisionItem)
            }

            $body   = @{ items = $decisionItemList.ToArray() }
            $result = Invoke-SPApiRequest -Method POST `
                -Endpoint "/certifications/$CertificationId/decide" `
                -Body $body `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            if (-not $result.Success) {
                $errMsg = "Batch $batchNum failed: $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
                    -Action 'Invoke-SPBulkDecide' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                return @{
                    Success = $false
                    Data    = @{ BatchResults = $batchResults.ToArray(); TotalDecided = $totalDecided }
                    Error   = $errMsg
                }
            }

            $batchResults.Add($result.Data)
            $totalDecided += $batch.Count

            Write-SPLog -Message "Batch $batchNum complete. Running total decided: $totalDecided" `
                -Severity DEBUG -Component 'SP.Decisions' -Action 'Invoke-SPBulkDecide' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        }

        Write-SPLog -Message "Bulk decide complete: $totalDecided items decided across $($batches.Count) batch(es)" `
            -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPBulkDecide' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        return @{
            Success = $true
            Data    = @{ BatchResults = $batchResults.ToArray(); TotalDecided = $totalDecided }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Invoke-SPBulkDecide failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPBulkDecide' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPReassign {
    <#
    .SYNOPSIS
        Synchronously reassigns access review items to a new certifier.
    .DESCRIPTION
        POSTs to /certifications/{id}/reassign (synchronous variant).
        Limited to Testing.ReassignSyncMax items (default 50).
        If more items are provided, returns an error suggesting the async variant.
    .PARAMETER CertificationId
        The certification ID containing the items to reassign.
    .PARAMETER NewCertifierIdentityId
        Identity ID of the reviewer to reassign items to.
    .PARAMETER ReviewItemIds
        Array of access review item IDs to reassign. Maximum 50.
    .PARAMETER Reason
        Reason for reassignment (required by ISC API).
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$object; Error=$string}
    .EXAMPLE
        $result = Invoke-SPReassign -CertificationId 'cert-xyz' `
            -NewCertifierIdentityId 'id-456' `
            -ReviewItemIds @('item-1','item-2') `
            -Reason 'Reviewer is out of office' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NewCertifierIdentityId,

        [Parameter()]
        [string[]]$ReviewItemIds,

        [Parameter()]
        [string]$Reason,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Read sync max from config with safe fallback
    $syncMax = 50
    try {
        $config  = Get-SPConfig
        $syncMax = $config.Testing.ReassignSyncMax
        if ($syncMax -le 0) { $syncMax = 50 }
    }
    catch {
        Write-SPLog -Message "Could not read Testing.ReassignSyncMax from config; using default 50." `
            -Severity WARN -Component 'SP.Decisions' -Action 'Invoke-SPReassign' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
    }

    if ($ReviewItemIds.Count -gt $syncMax) {
        $errMsg = "Invoke-SPReassign: $($ReviewItemIds.Count) items exceeds the synchronous limit of $syncMax. " +
                  "Use Invoke-SPReassignAsync for larger batches."
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPReassign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }

    Write-SPLog -Message "Reassign (sync): CertificationId='$CertificationId', Items=$($ReviewItemIds.Count), To='$NewCertifierIdentityId'" `
        -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPReassign' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        # M1: List[object] + .Add() instead of O(N^2) `$arr += $item`.
        $reassignItemList = [System.Collections.Generic.List[object]]::new()
        foreach ($itemId in $ReviewItemIds) {
            $reassignItemList.Add(@{ id = $itemId })
        }

        $body = @{
            reassignTo = @{ type = 'IDENTITY'; id = $NewCertifierIdentityId }
            items      = $reassignItemList.ToArray()
        }
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $body['reason'] = $Reason
        }

        $result = Invoke-SPApiRequest -Method POST `
            -Endpoint "/certifications/$CertificationId/reassign" `
            -Body $body `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            Write-SPLog -Message "Synchronous reassignment complete: $($ReviewItemIds.Count) items reassigned." `
                -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPReassign' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Invoke-SPReassign failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPReassign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPReassignAsync {
    <#
    .SYNOPSIS
        Asynchronously reassigns access review items to a new certifier.
    .DESCRIPTION
        POSTs to /certifications/{id}/reassign-async.
        Returns a task ID that can be polled for completion.
        Limited to Testing.ReassignAsyncMax items (default 500).
    .PARAMETER CertificationId
        The certification ID containing the items to reassign.
    .PARAMETER NewCertifierIdentityId
        Identity ID of the reviewer to reassign items to.
    .PARAMETER ReviewItemIds
        Array of access review item IDs to reassign. Maximum 500.
    .PARAMETER Reason
        Reason for reassignment.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{TaskId=$string}; Error=$string}
    .EXAMPLE
        $result = Invoke-SPReassignAsync -CertificationId 'cert-xyz' `
            -NewCertifierIdentityId 'id-456' `
            -ReviewItemIds $largeArray `
            -Reason 'Bulk reassignment for Q1 review' -CorrelationID $cid
        $taskId = $result.Data.TaskId
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$NewCertifierIdentityId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ReviewItemIds,

        [Parameter()]
        [string]$Reason,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Read async max from config with safe fallback
    $asyncMax = 500
    try {
        $config   = Get-SPConfig
        $asyncMax = $config.Testing.ReassignAsyncMax
        if ($asyncMax -le 0) { $asyncMax = 500 }
    }
    catch {
        Write-SPLog -Message "Could not read Testing.ReassignAsyncMax from config; using default 500." `
            -Severity WARN -Component 'SP.Decisions' -Action 'Invoke-SPReassignAsync' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
    }

    if ($ReviewItemIds.Count -gt $asyncMax) {
        $errMsg = "Invoke-SPReassignAsync: $($ReviewItemIds.Count) items exceeds the async limit of $asyncMax."
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPReassignAsync' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }

    Write-SPLog -Message "Reassign (async): CertificationId='$CertificationId', Items=$($ReviewItemIds.Count), To='$NewCertifierIdentityId'" `
        -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPReassignAsync' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        # M1: List[object] + .Add() instead of O(N^2) `$arr += $item`.
        # Async reassign accepts up to 500 items - the worst case for the
        # array-append pattern (~125k object copies just to build the body).
        $reassignItemList = [System.Collections.Generic.List[object]]::new()
        foreach ($itemId in $ReviewItemIds) {
            $reassignItemList.Add(@{ id = $itemId })
        }

        $body = @{
            reassignTo = @{ type = 'IDENTITY'; id = $NewCertifierIdentityId }
            items      = $reassignItemList.ToArray()
        }
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $body['reason'] = $Reason
        }

        $result = Invoke-SPApiRequest -Method POST `
            -Endpoint "/certifications/$CertificationId/reassign-async" `
            -Body $body `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            # Extract task ID from response
            $taskId = $null
            if ($null -ne $result.Data) {
                if ($result.Data.PSObject.Properties.Name -contains 'id') {
                    $taskId = $result.Data.id
                }
                elseif ($result.Data.PSObject.Properties.Name -contains 'taskId') {
                    $taskId = $result.Data.taskId
                }
            }

            Write-SPLog -Message "Async reassignment submitted: TaskId='$taskId', Items=$($ReviewItemIds.Count)" `
                -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPReassignAsync' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Data = @{ TaskId = $taskId }; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Invoke-SPReassignAsync failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPReassignAsync' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Invoke-SPSignOff {
    <#
    .SYNOPSIS
        Signs off a completed certification, indicating the reviewer is done.
    .DESCRIPTION
        POSTs to /certifications/{id}/sign-off to mark the certification
        as reviewer-signed.
    .PARAMETER CertificationId
        The certification ID to sign off.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Error=$string}
    .EXAMPLE
        $result = Invoke-SPSignOff -CertificationId 'cert-xyz' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Signing off certification: Id='$CertificationId'" `
        -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPSignOff' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $result = Invoke-SPApiRequest -Method POST `
            -Endpoint "/certifications/$CertificationId/sign-off" `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            Write-SPLog -Message "Certification '$CertificationId' signed off successfully." `
                -Severity INFO -Component 'SP.Decisions' -Action 'Invoke-SPSignOff' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Error = $null }
        }
        else {
            return @{ Success = $false; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Invoke-SPSignOff failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Decisions' `
            -Action 'Invoke-SPSignOff' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPBulkDecide',
    'Invoke-SPReassign',
    'Invoke-SPReassignAsync',
    'Invoke-SPSignOff'
)
