#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Lifecycle Management
.DESCRIPTION
    Provides functions to create, activate, query, poll, and complete
    SailPoint ISC certification campaigns via the ISC REST API v3.
    All functions delegate HTTP calls to Invoke-SPApiRequest.
.NOTES
    Module: SP.Campaigns
    Version: 1.0.0

    Campaign status state machine:
        STAGED -> ACTIVATING -> ACTIVE -> COMPLETING -> COMPLETED
#>

#region Internal Functions

function Build-SPCampaignBody {
    <#
    .SYNOPSIS
        Builds the campaign creation request body based on campaign type.
    .PARAMETER Name
        Campaign display name.
    .PARAMETER Type
        Campaign type: SOURCE_OWNER, MANAGER, SEARCH, ROLE_COMPOSITION.
    .PARAMETER CertifierIdentityId
        Identity ID of the certifier (not used for SOURCE_OWNER or MANAGER).
    .PARAMETER SourceId
        Required for SOURCE_OWNER campaigns.
    .PARAMETER SearchFilter
        Required for SEARCH campaigns - identity search filter expression.
    .PARAMETER RoleId
        Required for ROLE_COMPOSITION campaigns.
    .PARAMETER Description
        Optional campaign description.
    .OUTPUTS
        [hashtable] Campaign body ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('SOURCE_OWNER', 'MANAGER', 'SEARCH', 'ROLE_COMPOSITION')]
        [string]$Type,

        [Parameter()]
        [string]$CertifierIdentityId,

        [Parameter()]
        [string]$SourceId,

        [Parameter()]
        [string]$SearchFilter,

        [Parameter()]
        [string]$RoleId,

        [Parameter()]
        [string]$Description
    )

    $body = @{
        name        = $Name
        description = if ($Description) { $Description } else { '' }
        type        = $Type
    }

    switch ($Type) {
        'SOURCE_OWNER' {
            if (-not [string]::IsNullOrWhiteSpace($SourceId)) {
                $body['sourceIds'] = @($SourceId)
            }
        }
        'MANAGER' {
            if (-not [string]::IsNullOrWhiteSpace($CertifierIdentityId)) {
                $body['certifiers'] = @(
                    @{ type = 'IDENTITY'; id = $CertifierIdentityId }
                )
            }
        }
        'SEARCH' {
            if (-not [string]::IsNullOrWhiteSpace($SearchFilter)) {
                $body['filter'] = @{
                    type        = 'IDENTITY'
                    query       = @{ query = $SearchFilter }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($CertifierIdentityId)) {
                $body['certifiers'] = @(
                    @{ type = 'IDENTITY'; id = $CertifierIdentityId }
                )
            }
        }
        'ROLE_COMPOSITION' {
            if (-not [string]::IsNullOrWhiteSpace($RoleId)) {
                $body['roles'] = @(
                    @{ type = 'GOVERNANCE_GROUP'; id = $RoleId }
                )
            }
            if (-not [string]::IsNullOrWhiteSpace($CertifierIdentityId)) {
                $body['certifiers'] = @(
                    @{ type = 'IDENTITY'; id = $CertifierIdentityId }
                )
            }
        }
    }

    return $body
}

#endregion

#region Public Functions

function New-SPCampaign {
    <#
    .SYNOPSIS
        Creates a new SailPoint ISC certification campaign.
    .DESCRIPTION
        POSTs to /campaigns and returns the created campaign object.
        The request body varies by Type; supply only the parameters
        relevant to your campaign type.
    .PARAMETER Name
        Display name for the campaign.
    .PARAMETER Type
        Campaign type: SOURCE_OWNER, MANAGER, SEARCH, ROLE_COMPOSITION.
    .PARAMETER CertifierIdentityId
        Identity ID of the certifier (MANAGER/SEARCH/ROLE_COMPOSITION types).
    .PARAMETER SourceId
        Source ID for SOURCE_OWNER campaigns.
    .PARAMETER SearchFilter
        Identity search filter expression for SEARCH campaigns.
    .PARAMETER RoleId
        Role or governance group ID for ROLE_COMPOSITION campaigns.
    .PARAMETER Description
        Optional campaign description.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier (e.g. TC-001).
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$campaignObject; Error=$string}
    .EXAMPLE
        $result = New-SPCampaign -Name 'Q1 Access Review' -Type SOURCE_OWNER `
                    -SourceId 'src-123' -CorrelationID $cid -CampaignTestId 'TC-001'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('SOURCE_OWNER', 'MANAGER', 'SEARCH', 'ROLE_COMPOSITION')]
        [string]$Type,

        [Parameter()]
        [string]$CertifierIdentityId,

        [Parameter()]
        [string]$SourceId,

        [Parameter()]
        [string]$SearchFilter,

        [Parameter()]
        [string]$RoleId,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Creating campaign: Name='$Name', Type='$Type'" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'New-SPCampaign' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $body = Build-SPCampaignBody -Name $Name -Type $Type `
            -CertifierIdentityId $CertifierIdentityId `
            -SourceId $SourceId -SearchFilter $SearchFilter `
            -RoleId $RoleId -Description $Description

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/campaigns' `
            -Body $body -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            Write-SPLog -Message "Campaign created successfully: Id='$($result.Data.id)'" `
                -Severity INFO -Component 'SP.Campaigns' -Action 'New-SPCampaign' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "New-SPCampaign failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'New-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Start-SPCampaign {
    <#
    .SYNOPSIS
        Activates a staged SailPoint ISC certification campaign.
    .DESCRIPTION
        POSTs to /campaigns/{id}/activate to transition the campaign
        from STAGED to ACTIVATING -> ACTIVE.
    .PARAMETER CampaignId
        The unique ID of the campaign to activate.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$object; Error=$string}
    .EXAMPLE
        $result = Start-SPCampaign -CampaignId 'camp-abc123' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Activating campaign: Id='$CampaignId'" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Start-SPCampaign' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $endpoint = "/campaigns/$CampaignId/activate"
        $result   = Invoke-SPApiRequest -Method POST -Endpoint $endpoint `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            Write-SPLog -Message "Campaign activation request submitted: Id='$CampaignId'" `
                -Severity INFO -Component 'SP.Campaigns' -Action 'Start-SPCampaign' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Start-SPCampaign failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Start-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPCampaign {
    <#
    .SYNOPSIS
        Retrieves a single SailPoint ISC certification campaign by ID.
    .DESCRIPTION
        GETs /campaigns/{id}. Pass -Full to request detail=FULL which includes
        additional metadata about the campaign.
    .PARAMETER CampaignId
        The unique ID of the campaign.
    .PARAMETER Full
        When specified, appends ?detail=FULL to the request.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$campaignObject; Error=$string}
    .EXAMPLE
        $result = Get-SPCampaign -CampaignId 'camp-abc123' -Full -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [switch]$Full,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = $null
    if ($Full) {
        $queryParams = @{ detail = 'FULL' }
    }

    Write-SPLog -Message "Getting campaign: Id='$CampaignId', Full=$($Full.IsPresent)" `
        -Severity DEBUG -Component 'SP.Campaigns' -Action 'Get-SPCampaign' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/campaigns/$CampaignId" `
            -QueryParams $queryParams -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Get-SPCampaign failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Get-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPCampaignStatus {
    <#
    .SYNOPSIS
        Blocking poller that waits until a campaign reaches the target status.
    .DESCRIPTION
        Polls GET /campaigns/{id} every PollIntervalSeconds until the campaign
        status matches TargetStatus or the timeout is reached.

        Status machine: STAGED -> ACTIVATING -> ACTIVE -> COMPLETING -> COMPLETED
    .PARAMETER CampaignId
        The unique ID of the campaign.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait. Default: 300.
    .PARAMETER PollIntervalSeconds
        Seconds between polling attempts. Default: 10.
    .PARAMETER TargetStatus
        The status string to wait for. Default: 'ACTIVE'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{Status=$string; Campaign=$object}; Error=$string}
    .EXAMPLE
        $result = Get-SPCampaignStatus -CampaignId 'camp-abc123' -TargetStatus 'ACTIVE' `
                    -TimeoutSeconds 600 -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [int]$TimeoutSeconds = 300,

        [Parameter()]
        [int]$PollIntervalSeconds = 10,

        [Parameter()]
        [string]$TargetStatus = 'ACTIVE',

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Polling campaign status: Id='$CampaignId', Target='$TargetStatus', Timeout=${TimeoutSeconds}s" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignStatus' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    $deadline   = (Get-Date).AddSeconds($TimeoutSeconds)
    $pollCount  = 0

    try {
        while ((Get-Date) -lt $deadline) {
            $pollCount++
            $getResult = Get-SPCampaign -CampaignId $CampaignId `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            if (-not $getResult.Success) {
                Write-SPLog -Message "Poll $pollCount failed: $($getResult.Error)" `
                    -Severity WARN -Component 'SP.Campaigns' -Action 'Get-SPCampaignStatus' `
                    -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            }
            else {
                $currentStatus = $getResult.Data.status
                Write-SPLog -Message "Poll ${pollCount}: Campaign '$CampaignId' status = '$currentStatus'" `
                    -Severity DEBUG -Component 'SP.Campaigns' -Action 'Get-SPCampaignStatus' `
                    -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

                if ($currentStatus -eq $TargetStatus) {
                    Write-SPLog -Message "Campaign '$CampaignId' reached target status '$TargetStatus' after $pollCount polls." `
                        -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignStatus' `
                        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                    return @{
                        Success = $true
                        Data    = @{ Status = $currentStatus; Campaign = $getResult.Data }
                        Error   = $null
                    }
                }
            }

            # Wait before next poll (unless deadline has passed)
            if ((Get-Date).AddSeconds($PollIntervalSeconds) -lt $deadline) {
                Start-Sleep -Seconds $PollIntervalSeconds
            }
            else {
                break
            }
        }

        $errMsg = "Timeout: Campaign '$CampaignId' did not reach status '$TargetStatus' within ${TimeoutSeconds}s."
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Get-SPCampaignStatus' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
    catch {
        $errMsg = "Get-SPCampaignStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Get-SPCampaignStatus' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Search-SPCampaigns {
    <#
    .SYNOPSIS
        Searches SailPoint ISC campaigns by keyword (substring match).
    .DESCRIPTION
        GETs /campaigns with the 'name co "keyword"' filter to find campaigns
        where the keyword appears anywhere in the name. This works around the
        ISC admin UI limitation that only supports prefix matching.

        Auto-paginates across all results.
    .PARAMETER Keyword
        The search term. Matches campaigns whose name contains this string
        anywhere (case-insensitive, server-side).
    .PARAMETER Status
        Optional status filter. Valid values: STAGED, ACTIVATING, ACTIVE,
        COMPLETING, COMPLETED, ERROR.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([campaign objects]); Error=$string}
    .EXAMPLE
        $result = Search-SPCampaigns -Keyword 'test'
        $result.Data | ForEach-Object { $_.name }
    .EXAMPLE
        $result = Search-SPCampaigns -Keyword 'Q1' -Status 'COMPLETED'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Keyword,

        [Parameter()]
        [ValidateSet('STAGED', 'ACTIVATING', 'ACTIVE', 'COMPLETING', 'COMPLETED', 'ERROR')]
        [string[]]$Status,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Searching campaigns: Keyword='$Keyword', Status='$($Status -join ',')'" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Search-SPCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # Build server-side filter
        $filterParts = [System.Collections.Generic.List[string]]::new()

        $escaped = $Keyword.Replace('"', '\"')
        $filterParts.Add("name co `"$escaped`"")

        if ($null -ne $Status -and $Status.Count -gt 0) {
            $quotedStatuses = ($Status | ForEach-Object { "`"$_`"" }) -join ','
            $filterParts.Add("status in ($quotedStatuses)")
        }

        $queryParams = @{
            'filters' = ($filterParts -join ' and ')
            'limit'   = '250'
            'offset'  = '0'
        }

        # Auto-paginate
        $allCampaigns = [System.Collections.Generic.List[object]]::new()
        $pageSize     = 250
        $offset       = 0
        $pageNum      = 0

        # M2: pagination ceiling (see SP.Certifications.psm1 for rationale).
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allCampaigns.Count) campaigns). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
                    -Action 'Search-SPCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams['offset'] = $offset.ToString()

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                return @{ Success = $false; Data = $null; Error = $result.Error }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (H1 fix; see SP.Certifications.psm1 comment).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allCampaigns.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Search-SPCampaigns found $($allCampaigns.Count) campaign(s) matching '$Keyword'" `
            -Severity INFO -Component 'SP.Campaigns' -Action 'Search-SPCampaigns' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allCampaigns.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Search-SPCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Search-SPCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Complete-SPCampaign {
    <#
    .SYNOPSIS
        Completes (closes) a past-due SailPoint ISC certification campaign.
    .DESCRIPTION
        POSTs to /campaigns/{id}/complete. This action is guarded by the
        Safety.AllowCompleteCampaign configuration flag. If the flag is false,
        the function returns an error without making any API call.

        NOTE: The ISC API only accepts completion on past-due campaigns.
    .PARAMETER CampaignId
        The unique ID of the campaign to complete.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Error=$string}
    .EXAMPLE
        $result = Complete-SPCampaign -CampaignId 'camp-abc123' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Safety guard
    try {
        $config = Get-SPConfig
        if (-not $config.Safety.AllowCompleteCampaign) {
            $errMsg = "Complete-SPCampaign is blocked: Safety.AllowCompleteCampaign is set to false. " +
                      "Set to true in settings.json to allow campaign completion."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.Campaigns' `
                -Action 'Complete-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $false; Error = $errMsg }
        }
    }
    catch {
        $errMsg = "Complete-SPCampaign: Failed to read safety config: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Complete-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Error = $errMsg }
    }

    Write-SPLog -Message "Completing campaign: Id='$CampaignId'" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Complete-SPCampaign' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $result = Invoke-SPApiRequest -Method POST -Endpoint "/campaigns/$CampaignId/complete" `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if ($result.Success) {
            Write-SPLog -Message "Campaign '$CampaignId' completed successfully." `
                -Severity INFO -Component 'SP.Campaigns' -Action 'Complete-SPCampaign' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
            return @{ Success = $true; Error = $null }
        }
        else {
            return @{ Success = $false; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Complete-SPCampaign failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Complete-SPCampaign' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-SPCampaign',
    'Start-SPCampaign',
    'Get-SPCampaign',
    'Get-SPCampaignStatus',
    'Search-SPCampaigns',
    'Complete-SPCampaign'
)
