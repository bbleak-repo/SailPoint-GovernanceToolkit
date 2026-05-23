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
    .PARAMETER Deadline
        Optional ISO 8601 deadline string (e.g. '2026-06-01T23:59:59Z').
        When provided, sets the ISC-enforced campaign deadline.
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
        [string]$Description,

        [Parameter()]
        [string]$Deadline
    )

    $body = @{
        name        = $Name
        description = if ($Description) { $Description } else { '' }
        type        = $Type
    }

    if (-not [string]::IsNullOrWhiteSpace($Deadline)) {
        $body['deadline'] = $Deadline
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
    .PARAMETER Deadline
        Optional ISO 8601 deadline string (e.g. '2026-06-01T23:59:59Z').
        When provided, sets the ISC-enforced campaign deadline.
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
        [string]$Deadline,

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
            -RoleId $RoleId -Description $Description -Deadline $Deadline

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
    .PARAMETER Type
        Optional campaign type filter. Valid values: MANAGER, SOURCE_OWNER,
        SEARCH, ROLE_COMPOSITION. Translates to: type eq "MANAGER" (server-side).
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([campaign objects]); Error=$string}
    .EXAMPLE
        $result = Search-SPCampaigns -Keyword 'test'
        $result.Data | ForEach-Object { $_.name }
    .EXAMPLE
        $result = Search-SPCampaigns -Keyword 'Q1' -Status 'COMPLETED'
    .EXAMPLE
        $result = Search-SPCampaigns -Keyword 'Review' -Type 'MANAGER'
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
        [ValidateSet('MANAGER', 'SOURCE_OWNER', 'SEARCH', 'ROLE_COMPOSITION')]
        [string]$Type,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Searching campaigns: Keyword='$Keyword', Status='$($Status -join ',')', Type='$Type'" `
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

        if (-not [string]::IsNullOrWhiteSpace($Type)) {
            $filterParts.Add("type eq `"$Type`"")
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

function Get-SPCampaignDeadlineStatus {
    <#
    .SYNOPSIS
        Classifies campaigns by deadline urgency.
    .DESCRIPTION
        Retrieves campaigns matching the Status filter, then classifies each
        campaign into one of six deadline urgency buckets:

          Overdue    - deadline is in the past AND status is ACTIVE
          Critical   - deadline is within 24 hours AND status is ACTIVE
          Warning    - deadline is within 72 hours AND status is ACTIVE
          OnTrack    - deadline is more than 72 hours away AND status is ACTIVE
          Completed  - status is COMPLETED (regardless of deadline)
          NoDeadline - deadline is null

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch
        between PS7 auto-converted UTC datetimes and local cutoff values.

        Client-side creation date filtering is applied via DaysBack to limit
        the campaign set (ISC API does not support date in filters).
    .PARAMETER Status
        Campaign status filter. Default: @('ACTIVE').
        Valid values: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
    .PARAMETER DaysBack
        Number of calendar days to look back for campaigns by creation date.
        Default: 365. Set to 0 to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Overdue    = @([campaign objects with DeadlineStatus='Overdue'])
                Critical   = @([campaign objects with DeadlineStatus='Critical'])
                Warning    = @([campaign objects with DeadlineStatus='Warning'])
                OnTrack    = @([campaign objects with DeadlineStatus='OnTrack'])
                Completed  = @([campaign objects with DeadlineStatus='Completed'])
                NoDeadline = @([campaign objects with DeadlineStatus='NoDeadline'])
                Summary    = @{ Overdue=N; Critical=N; Warning=N; OnTrack=N; Completed=N; NoDeadline=N }
            }
            Error = $null
        }
    .EXAMPLE
        $result = Get-SPCampaignDeadlineStatus
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 90
        $result.Data.Overdue | ForEach-Object { $_.name }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('STAGED', 'ACTIVATING', 'ACTIVE', 'COMPLETING', 'COMPLETED', 'ERROR')]
        [string[]]$Status = @('ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting campaign deadline status: Status='$($Status -join ',')', DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignDeadlineStatus' `
        -CorrelationID $CorrelationID

    try {
        # Build server-side filter for status
        $filterParts = [System.Collections.Generic.List[string]]::new()

        if ($null -ne $Status -and $Status.Count -gt 0) {
            $quotedStatuses = ($Status | ForEach-Object { "`"$_`"" }) -join ','
            $filterParts.Add("status in ($quotedStatuses)")
        }

        $queryParams = @{
            'detail' = 'FULL'
            'limit'  = '250'
            'offset' = '0'
        }

        if ($filterParts.Count -gt 0) {
            $queryParams['filters'] = ($filterParts -join ' and ')
        }

        # Auto-paginate
        $allCampaigns = [System.Collections.Generic.List[object]]::new()
        $pageSize     = 250
        $offset       = 0
        $pageNum      = 0

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
                    -Action 'Get-SPCampaignDeadlineStatus' -CorrelationID $CorrelationID
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
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allCampaigns.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        # Client-side creation date filter
        $filteredCampaigns = [System.Collections.Generic.List[object]]::new()
        if ($DaysBack -gt 0) {
            $cutoffUtc = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
            foreach ($campaign in $allCampaigns) {
                $createdRaw = $campaign.created
                if ($null -eq $createdRaw) {
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = ([datetime]$createdRaw).ToUniversalTime()
                } else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate.ToUniversalTime()
                    }
                }

                if ($null -eq $createdDate -or $createdDate -ge $cutoffUtc) {
                    $filteredCampaigns.Add($campaign)
                }
            }
        } else {
            foreach ($campaign in $allCampaigns) { $filteredCampaigns.Add($campaign) }
        }

        Write-SPLog -Message "Classifying $($filteredCampaigns.Count) campaigns by deadline urgency" `
            -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignDeadlineStatus' `
            -CorrelationID $CorrelationID

        # Classify each campaign
        $overdue    = [System.Collections.Generic.List[object]]::new()
        $critical   = [System.Collections.Generic.List[object]]::new()
        $warning    = [System.Collections.Generic.List[object]]::new()
        $onTrack    = [System.Collections.Generic.List[object]]::new()
        $completed  = [System.Collections.Generic.List[object]]::new()
        $noDeadline = [System.Collections.Generic.List[object]]::new()

        $nowUtc = (Get-Date).ToUniversalTime()

        foreach ($campaign in $filteredCampaigns) {
            $campStatus = $campaign.status

            # Completed campaigns always go to Completed bucket
            if ($campStatus -eq 'COMPLETED') {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'Completed' -Force
                $completed.Add($campaign)
                continue
            }

            # Parse deadline
            $deadlineRaw = $campaign.deadline
            if ($null -eq $deadlineRaw -or ([string]$deadlineRaw).Trim() -eq '') {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'NoDeadline' -Force
                $noDeadline.Add($campaign)
                continue
            }

            $deadlineUtc = $null
            if ($deadlineRaw -is [datetime]) {
                $deadlineUtc = ([datetime]$deadlineRaw).ToUniversalTime()
            } else {
                $parsedDeadline = [datetime]::MinValue
                if ([datetime]::TryParse($deadlineRaw.ToString(), [ref]$parsedDeadline)) {
                    $deadlineUtc = $parsedDeadline.ToUniversalTime()
                }
            }

            if ($null -eq $deadlineUtc) {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'NoDeadline' -Force
                $noDeadline.Add($campaign)
                continue
            }

            # Add parsed deadline as a property for downstream use
            $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineUtc' `
                -Value $deadlineUtc -Force

            $hoursRemaining = ($deadlineUtc - $nowUtc).TotalHours
            $campaign | Add-Member -MemberType NoteProperty -Name 'HoursRemaining' `
                -Value ([math]::Round($hoursRemaining, 1)) -Force

            if ($hoursRemaining -lt 0) {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'Overdue' -Force
                $overdue.Add($campaign)
            }
            elseif ($hoursRemaining -le 24) {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'Critical' -Force
                $critical.Add($campaign)
            }
            elseif ($hoursRemaining -le 72) {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'Warning' -Force
                $warning.Add($campaign)
            }
            else {
                $campaign | Add-Member -MemberType NoteProperty -Name 'DeadlineStatus' `
                    -Value 'OnTrack' -Force
                $onTrack.Add($campaign)
            }
        }

        $summary = @{
            Overdue    = $overdue.Count
            Critical   = $critical.Count
            Warning    = $warning.Count
            OnTrack    = $onTrack.Count
            Completed  = $completed.Count
            NoDeadline = $noDeadline.Count
        }

        Write-SPLog -Message ("Deadline classification complete: " +
            "Overdue=$($overdue.Count), Critical=$($critical.Count), " +
            "Warning=$($warning.Count), OnTrack=$($onTrack.Count), " +
            "Completed=$($completed.Count), NoDeadline=$($noDeadline.Count)") `
            -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignDeadlineStatus' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Overdue    = $overdue.ToArray()
                Critical   = $critical.ToArray()
                Warning    = $warning.ToArray()
                OnTrack    = $onTrack.ToArray()
                Completed  = $completed.ToArray()
                NoDeadline = $noDeadline.ToArray()
                Summary    = $summary
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPCampaignDeadlineStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Get-SPCampaignDeadlineStatus' -CorrelationID $CorrelationID
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

function Get-SPCampaignHealth {
    <#
    .SYNOPSIS
        Checks all active campaigns for operational health indicators.
    .DESCRIPTION
        Retrieves campaigns matching the Status filter, then for each campaign
        assesses health across multiple dimensions: deadline urgency, completion
        velocity, stale reviewers, and unresponsive reviewers. Designed for daily
        monitoring and alerting -- answers "are any campaigns in trouble right now?"

        Each campaign is classified as Red, Yellow, or Green:
          Red    - Overdue deadline, OR >50% certs stale, OR 0 decisions after 48h
          Yellow - Critical/Warning deadline, OR >25% certs stale, OR velocity too slow
          Green  - OnTrack deadline, <25% stale, velocity on pace

        Reuses the existing deadline classification logic from Get-SPCampaignDeadlineStatus
        and fetches certifications via Get-SPAuditCertifications for reviewer analysis.
    .PARAMETER Status
        Campaign status filter. Default: @('ACTIVE').
    .PARAMETER DaysBack
        Number of calendar days to look back for campaigns by creation date. Default: 30.
    .PARAMETER StaleReviewerHours
        Hours with no reviewer action before a certification is considered stale. Default: 48.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Campaigns = @([hashtable] per-campaign health detail)
                Summary   = @{ Red=$n; Yellow=$n; Green=$n; Total=$n }
            }
            Error = $null
        }
    .EXAMPLE
        $result = Get-SPCampaignHealth
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPCampaignHealth -StaleReviewerHours 24
        $result.Data.Campaigns | Where-Object { $_.OverallHealth -eq 'Red' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('STAGED', 'ACTIVATING', 'ACTIVE', 'COMPLETING', 'COMPLETED', 'ERROR')]
        [string[]]$Status = @('ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [int]$StaleReviewerHours = 48,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPCampaignHealth: Status='$($Status -join ',')', DaysBack=$DaysBack, StaleHours=$StaleReviewerHours" `
        -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignHealth' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Get campaigns with deadline classification
        $deadlineResult = Get-SPCampaignDeadlineStatus -Status $Status -DaysBack $DaysBack `
            -CorrelationID $CorrelationID

        if (-not $deadlineResult.Success) {
            return @{ Success = $false; Data = $null; Error = $deadlineResult.Error }
        }

        # Collect all non-completed campaigns for health analysis
        $campaignsToCheck = [System.Collections.Generic.List[object]]::new()
        foreach ($bucket in @('Overdue', 'Critical', 'Warning', 'OnTrack', 'NoDeadline')) {
            foreach ($camp in $deadlineResult.Data[$bucket]) {
                $campaignsToCheck.Add($camp)
            }
        }

        if ($campaignsToCheck.Count -eq 0) {
            Write-SPLog -Message "No active campaigns found for health check" `
                -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignHealth' `
                -CorrelationID $CorrelationID
            return @{
                Success = $true
                Data    = @{
                    Campaigns = @()
                    Summary   = @{ Red = 0; Yellow = 0; Green = 0; Total = 0 }
                }
                Error   = $null
            }
        }

        Write-SPLog -Message "Analyzing health for $($campaignsToCheck.Count) campaign(s)" `
            -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignHealth' `
            -CorrelationID $CorrelationID

        $nowUtc        = (Get-Date).ToUniversalTime()
        $staleCutoff   = $nowUtc.AddHours(-$StaleReviewerHours)
        $campaignHealthList = [System.Collections.Generic.List[object]]::new()
        $redCount      = 0
        $yellowCount   = 0
        $greenCount    = 0

        foreach ($campaign in $campaignsToCheck) {
            $campaignId   = $campaign.id
            $campaignName = $campaign.name
            $deadlineStatus = 'NoDeadline'
            if ($campaign.PSObject.Properties.Name -contains 'DeadlineStatus') {
                $deadlineStatus = $campaign.DeadlineStatus
            }

            # Parse campaign created date for velocity calculation
            $createdUtc = $null
            $createdRaw = $campaign.created
            if ($null -ne $createdRaw) {
                if ($createdRaw -is [datetime]) {
                    $createdUtc = ([datetime]$createdRaw).ToUniversalTime()
                } else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdUtc = $parsedDate.ToUniversalTime()
                    }
                }
            }

            # Get campaign-level completion stats from the campaign object (detail=FULL)
            $totalItems   = 0
            $decidedItems = 0
            if ($campaign.PSObject.Properties.Name -contains 'totalItems' -and $null -ne $campaign.totalItems) {
                $totalItems = [int]$campaign.totalItems
            }
            if ($campaign.PSObject.Properties.Name -contains 'completedItems' -and $null -ne $campaign.completedItems) {
                $decidedItems = [int]$campaign.completedItems
            }
            $pendingItems   = [math]::Max(0, $totalItems - $decidedItems)
            $completionPct  = if ($totalItems -gt 0) { [math]::Round(($decidedItems / $totalItems) * 100, 1) } else { 0.0 }

            # Calculate completion velocity (items per day)
            $daysOpen = 0.0
            if ($null -ne $createdUtc) {
                $daysOpen = ($nowUtc - $createdUtc).TotalDays
                if ($daysOpen -lt 0.01) { $daysOpen = 0.01 }
            }
            $velocity = if ($daysOpen -gt 0) { [math]::Round($decidedItems / $daysOpen, 1) } else { 0.0 }

            # Parse deadline for days remaining and projected completion
            $daysRemaining      = $null
            $projectedCompletion = $null
            $deadlineUtc        = $null
            if ($campaign.PSObject.Properties.Name -contains 'DeadlineUtc' -and $null -ne $campaign.DeadlineUtc) {
                $deadlineUtc   = $campaign.DeadlineUtc
                $daysRemaining = [math]::Round(($deadlineUtc - $nowUtc).TotalDays, 1)
            }

            if ($velocity -gt 0 -and $pendingItems -gt 0) {
                $daysToFinish        = $pendingItems / $velocity
                $projectedCompletion = $nowUtc.AddDays($daysToFinish).ToString('yyyy-MM-dd')
            } elseif ($pendingItems -eq 0) {
                $projectedCompletion = $nowUtc.ToString('yyyy-MM-dd')
            }

            # Get certifications to check for stale/unresponsive reviewers
            $staleReviewerNames  = [System.Collections.Generic.List[string]]::new()
            $staleReviewerCount  = 0
            $totalCerts          = 0
            $staleCertCount      = 0

            $certResult = Get-SPAuditCertifications -CampaignId $campaignId `
                -CorrelationID $CorrelationID

            if ($certResult.Success -and $null -ne $certResult.Data) {
                $certs = @($certResult.Data)
                $totalCerts = $certs.Count

                # Track unique stale reviewers
                $staleReviewerIds = [System.Collections.Generic.HashSet[string]]::new()

                foreach ($cert in $certs) {
                    # Skip signed-off (completed) certifications
                    $signedValue = $null
                    if ($cert.PSObject.Properties.Name -contains 'signed') {
                        $signedValue = $cert.signed
                    }
                    if ($null -ne $signedValue -and -not [string]::IsNullOrWhiteSpace([string]$signedValue)) {
                        continue
                    }

                    # Check cert created date for staleness
                    $certCreatedStr = $null
                    if ($cert.PSObject.Properties.Name -contains 'created') {
                        $certCreatedStr = $cert.created
                    }
                    if ([string]::IsNullOrWhiteSpace($certCreatedStr)) {
                        continue
                    }

                    $certCreated = $null
                    try {
                        if ($certCreatedStr -is [datetime]) {
                            $certCreated = ([datetime]$certCreatedStr).ToUniversalTime()
                        } else {
                            $certCreated = [datetime]::Parse([string]$certCreatedStr).ToUniversalTime()
                        }
                    } catch {
                        continue
                    }

                    if ($certCreated -lt $staleCutoff) {
                        $staleCertCount++

                        # Get reviewer name
                        $reviewerName = 'Unknown'
                        $reviewerId   = ''
                        if ($cert.PSObject.Properties.Name -contains 'EffectiveReviewer' -and $null -ne $cert.EffectiveReviewer) {
                            $reviewer = $cert.EffectiveReviewer
                            if ($reviewer.PSObject.Properties.Name -contains 'displayName' -and
                                -not [string]::IsNullOrWhiteSpace($reviewer.displayName)) {
                                $reviewerName = $reviewer.displayName
                            } elseif ($reviewer.PSObject.Properties.Name -contains 'name' -and
                                      -not [string]::IsNullOrWhiteSpace($reviewer.name)) {
                                $reviewerName = $reviewer.name
                            }
                            if ($reviewer.PSObject.Properties.Name -contains 'id') {
                                $reviewerId = [string]$reviewer.id
                            }
                        } elseif ($cert.PSObject.Properties.Name -contains 'reviewer' -and $null -ne $cert.reviewer) {
                            $reviewer = $cert.reviewer
                            if ($reviewer.PSObject.Properties.Name -contains 'displayName' -and
                                -not [string]::IsNullOrWhiteSpace($reviewer.displayName)) {
                                $reviewerName = $reviewer.displayName
                            } elseif ($reviewer.PSObject.Properties.Name -contains 'name' -and
                                      -not [string]::IsNullOrWhiteSpace($reviewer.name)) {
                                $reviewerName = $reviewer.name
                            }
                            if ($reviewer.PSObject.Properties.Name -contains 'id') {
                                $reviewerId = [string]$reviewer.id
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($reviewerId)) {
                            if ($staleReviewerIds.Add($reviewerId)) {
                                $staleReviewerNames.Add($reviewerName)
                            }
                        } else {
                            $staleReviewerNames.Add($reviewerName)
                        }
                    }
                }

                $staleReviewerCount = $staleReviewerIds.Count
                if ($staleReviewerCount -eq 0) {
                    $staleReviewerCount = $staleReviewerNames.Count
                }
            } else {
                Write-SPLog -Message "Could not retrieve certifications for campaign '$campaignName' ($campaignId) -- reviewer analysis skipped" `
                    -Severity WARN -Component 'SP.Campaigns' -Action 'Get-SPCampaignHealth' `
                    -CorrelationID $CorrelationID
            }

            $stalePct = if ($totalCerts -gt 0) { ($staleCertCount / $totalCerts) * 100 } else { 0.0 }

            # Check if campaign is old enough (48h) with zero decisions
            $hoursOpen = if ($null -ne $createdUtc) { ($nowUtc - $createdUtc).TotalHours } else { 0 }
            $zeroDecisionsStale = ($decidedItems -eq 0 -and $hoursOpen -ge 48 -and $totalItems -gt 0)

            # Determine if velocity is too slow to finish before deadline
            $velocityTooSlow = $false
            if ($null -ne $deadlineUtc -and $velocity -gt 0 -and $pendingItems -gt 0) {
                $daysNeeded = $pendingItems / $velocity
                $daysLeft   = ($deadlineUtc - $nowUtc).TotalDays
                if ($daysNeeded -gt $daysLeft) {
                    $velocityTooSlow = $true
                }
            }

            # Health classification
            $overallHealth = 'Green'

            # Red conditions
            if ($deadlineStatus -eq 'Overdue') {
                $overallHealth = 'Red'
            } elseif ($stalePct -gt 50) {
                $overallHealth = 'Red'
            } elseif ($zeroDecisionsStale) {
                $overallHealth = 'Red'
            }

            # Yellow conditions (only if not already Red)
            if ($overallHealth -eq 'Green') {
                if ($deadlineStatus -eq 'Critical' -or $deadlineStatus -eq 'Warning') {
                    $overallHealth = 'Yellow'
                } elseif ($stalePct -gt 25) {
                    $overallHealth = 'Yellow'
                } elseif ($velocityTooSlow) {
                    $overallHealth = 'Yellow'
                }
            }

            $campaignHealth = @{
                CampaignId          = $campaignId
                CampaignName        = $campaignName
                OverallHealth       = $overallHealth
                DeadlineStatus      = $deadlineStatus
                TotalItems          = $totalItems
                DecidedItems        = $decidedItems
                PendingItems        = $pendingItems
                CompletionPct       = $completionPct
                CompletionVelocity  = $velocity
                ProjectedCompletion = $projectedCompletion
                StaleReviewerCount  = $staleReviewerCount
                StaleReviewers      = $staleReviewerNames.ToArray()
                DaysRemaining       = $daysRemaining
            }

            $campaignHealthList.Add($campaignHealth)

            switch ($overallHealth) {
                'Red'    { $redCount++ }
                'Yellow' { $yellowCount++ }
                'Green'  { $greenCount++ }
            }
        }

        Write-SPLog -Message ("Campaign health summary: Red=$redCount, Yellow=$yellowCount, Green=$greenCount, Total=$($campaignHealthList.Count)") `
            -Severity INFO -Component 'SP.Campaigns' -Action 'Get-SPCampaignHealth' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Campaigns = $campaignHealthList.ToArray()
                Summary   = @{
                    Red    = $redCount
                    Yellow = $yellowCount
                    Green  = $greenCount
                    Total  = $campaignHealthList.Count
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPCampaignHealth failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Campaigns' `
            -Action 'Get-SPCampaignHealth' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-SPCampaign',
    'Start-SPCampaign',
    'Get-SPCampaign',
    'Get-SPCampaignStatus',
    'Search-SPCampaigns',
    'Get-SPCampaignDeadlineStatus',
    'Complete-SPCampaign',
    'Get-SPCampaignHealth'
)
