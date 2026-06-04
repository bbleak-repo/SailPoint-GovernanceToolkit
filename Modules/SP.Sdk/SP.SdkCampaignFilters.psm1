#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Campaign Filter Management
.DESCRIPTION
    Wraps the ISC V3 campaign-filters endpoints. Provides CRUD for campaign
    filters used to include or exclude identities/entitlements from certification
    campaigns.
    Parity with PSSailpoint SDK CertificationCampaignFiltersApi functions.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
    Update uses POST (full replacement), not PATCH, per the ISC API spec.
    Delete uses POST /campaign-filters/delete with an array of IDs (bulk).
.NOTES
    Module: SP.SdkCampaignFilters
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/CertificationCampaignFiltersApi.ps1
#>

function Get-SPSdkCampaignFilters {
    <#
    .SYNOPSIS
        Lists campaign filters with optional pagination and system filter inclusion.
    .DESCRIPTION
        GETs /campaign-filters with standard collection parameters.
        Returns both custom and system filters by default.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset for pagination. Default: 0.
        Maps to the 'start' query parameter in the ISC API.
    .PARAMETER IncludeSystemFilters
        If true, includes system-created filters. Default: true.
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
        [Parameter()] [bool]$IncludeSystemFilters = $true,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $queryParams = @{
        'limit' = $Limit.ToString()
        'start' = $Offset.ToString()
    }
    if (-not $IncludeSystemFilters) {
        $queryParams['includeSystemFilters'] = 'false'
    }

    Write-SPLog -Message "Listing campaign filters: Limit=$Limit, Offset=$Offset, IncludeSystemFilters=$IncludeSystemFilters" `
        -Severity DEBUG -Component 'SP.SdkCampaignFilters' -Action 'Get-SPSdkCampaignFilters' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaign-filters' `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) campaign filters" `
        -Severity DEBUG -Component 'SP.SdkCampaignFilters' -Action 'Get-SPSdkCampaignFilters' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllCampaignFilters {
    <#
    .SYNOPSIS
        Auto-paginating retrieval of all campaign filters.
    .DESCRIPTION
        Repeatedly calls Get-SPSdkCampaignFilters with increasing offset
        until fewer items than the page size are returned. Cannot use
        Invoke-SPSdkPaginatedGet because this endpoint uses the 'start'
        query parameter instead of 'offset'.
    .PARAMETER IncludeSystemFilters
        If true, includes system-created filters. Default: true.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [bool]$IncludeSystemFilters = $true,
        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Fetching all campaign filters (auto-paginated)" `
        -Severity DEBUG -Component 'SP.SdkCampaignFilters' -Action 'Get-SPSdkAllCampaignFilters' `
        -CorrelationID $CorrelationID

    $config = Get-SPConfig
    $maxPages = if ($config.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                     $config.Api.MaxPaginationPages -gt 0) {
                    $config.Api.MaxPaginationPages
                } else { 200 }

    $allItems = [System.Collections.Generic.List[object]]::new()
    $offset   = 0
    $pageSize = 250
    $pageNum  = 0

    do {
        $pageNum++
        if ($pageNum -gt $maxPages) {
            $errMsg = "Pagination ceiling reached: $maxPages pages fetched ($($allItems.Count) filters). Raise Api.MaxPaginationPages if needed."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.SdkCampaignFilters' `
                -Action 'Get-SPSdkAllCampaignFilters' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $pageResult = Get-SPSdkCampaignFilters -Limit $pageSize -Offset $offset `
            -IncludeSystemFilters $IncludeSystemFilters -CorrelationID $CorrelationID

        if (-not $pageResult.Success) {
            return @{ Success = $false; Data = $null; Error = $pageResult.Error }
        }

        $page = @($pageResult.Data)
        if ($page.Count -gt 0) {
            foreach ($item in $page) { $allItems.Add($item) }
        }

        $offset += $pageSize
    } while ($page.Count -ge $pageSize)

    Write-SPLog -Message "Fetched $($allItems.Count) total campaign filters" `
        -Severity DEBUG -Component 'SP.SdkCampaignFilters' -Action 'Get-SPSdkAllCampaignFilters' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
}

function Get-SPSdkCampaignFilter {
    <#
    .SYNOPSIS
        Gets a single campaign filter by ID.
    .PARAMETER FilterId
        The campaign filter ID.
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
        [string]$FilterId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting campaign filter: $FilterId" `
        -Severity DEBUG -Component 'SP.SdkCampaignFilters' -Action 'Get-SPSdkCampaignFilter' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/campaign-filters/$FilterId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function New-SPSdkCampaignFilter {
    <#
    .SYNOPSIS
        Creates a new campaign filter.
    .DESCRIPTION
        POSTs to /campaign-filters. The filter body must include at minimum:
        name (string), mode (INCLUSION or EXCLUSION), criteriaList (array).
        Optional: description (string).
    .PARAMETER Filter
        Hashtable with filter properties. Required keys: name, mode, criteriaList.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    .EXAMPLE
        $filter = @{
            name         = 'Exclude Service Accounts'
            description  = 'Excludes all service accounts from campaigns'
            mode         = 'EXCLUSION'
            criteriaList = @(
                @{ type = 'IDENTITY_ATTRIBUTE'; property = 'accountType'; value = 'service'; operation = 'EQUALS' }
            )
        }
        New-SPSdkCampaignFilter -Filter $filter
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Filter,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $filterName = if ($Filter.ContainsKey('name')) { $Filter['name'] } else { '(unnamed)' }

    if (-not $PSCmdlet.ShouldProcess("Campaign filter '$filterName'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating campaign filter: '$filterName'" `
        -Severity INFO -Component 'SP.SdkCampaignFilters' -Action 'New-SPSdkCampaignFilter' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint '/campaign-filters' `
        -Body $Filter -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Created campaign filter: id=$($result.Data.id)" `
        -Severity INFO -Component 'SP.SdkCampaignFilters' -Action 'New-SPSdkCampaignFilter' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Update-SPSdkCampaignFilter {
    <#
    .SYNOPSIS
        Updates a campaign filter (full replacement via POST).
    .DESCRIPTION
        POSTs to /campaign-filters/{filterId} with a full CampaignFilterDetails body.
        This is a full replacement, not a partial patch. The ISC API uses POST
        (not PUT or PATCH) for campaign filter updates.
    .PARAMETER FilterId
        The campaign filter ID to update.
    .PARAMETER Filter
        Hashtable with the complete updated filter properties.
        Required keys: name, mode, criteriaList.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{Success; Data; Error}
    .EXAMPLE
        $filter = @{
            name         = 'Updated Filter Name'
            description  = 'Updated description'
            mode         = 'INCLUSION'
            criteriaList = @(
                @{ type = 'IDENTITY_ATTRIBUTE'; property = 'department'; value = 'IT'; operation = 'EQUALS' }
            )
        }
        Update-SPSdkCampaignFilter -FilterId 'filt-123' -Filter $filter
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilterId,

        [Parameter(Mandatory)]
        [hashtable]$Filter,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Campaign filter '$FilterId'", 'Update')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Updating campaign filter '$FilterId'" `
        -Severity INFO -Component 'SP.SdkCampaignFilters' -Action 'Update-SPSdkCampaignFilter' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint "/campaign-filters/$FilterId" `
        -Body $Filter -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Remove-SPSdkCampaignFilter {
    <#
    .SYNOPSIS
        Deletes one or more campaign filters.
    .DESCRIPTION
        POSTs to /campaign-filters/delete with an array of filter IDs.
        The ISC API uses a bulk-delete pattern (POST with ID array in body),
        not a standard DELETE /campaign-filters/{id} endpoint.
    .PARAMETER FilterId
        The campaign filter ID(s) to delete. Accepts a single ID or an array.
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
        [string[]]$FilterId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $idList = @($FilterId)
    $displayIds = ($idList -join ', ')

    if (-not $PSCmdlet.ShouldProcess("Campaign filter(s) '$displayIds'", 'Delete')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Deleting campaign filter(s): $displayIds" `
        -Severity WARN -Component 'SP.SdkCampaignFilters' -Action 'Remove-SPSdkCampaignFilter' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method POST -Endpoint '/campaign-filters/delete' `
        -Body $idList -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $null; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-SPSdkCampaignFilters',
    'Get-SPSdkAllCampaignFilters',
    'Get-SPSdkCampaignFilter',
    'New-SPSdkCampaignFilter',
    'Update-SPSdkCampaignFilter',
    'Remove-SPSdkCampaignFilter'
)
