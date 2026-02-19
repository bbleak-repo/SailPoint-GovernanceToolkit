#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Certification and Access Review Item Queries
.DESCRIPTION
    Provides functions to retrieve certifications (reviewers) and their associated
    access review items from the SailPoint ISC API.  Includes both single-page
    and auto-paginating variants for each resource type.
    All HTTP calls are delegated to Invoke-SPApiRequest.
.NOTES
    Module: SP.Certifications
    Version: 1.0.0
#>

#region Internal Functions

function Get-SPTotalCountFromResult {
    <#
    .SYNOPSIS
        Extracts the total item count from an API result, with fallback.
    .DESCRIPTION
        SailPoint ISC may return the total count in X-Total-Count response header
        or as a top-level count/totalCount field on the response body.
        Because Invoke-RestMethod collapses headers, we inspect the Data object
        for common count field names and fall back to the array length.
    .PARAMETER ApiResult
        The successful hashtable returned by Invoke-SPApiRequest.
    .OUTPUTS
        [int] Total item count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ApiResult
    )

    $data = $ApiResult.Data

    # Try well-known total-count properties returned in body
    if ($null -ne $data) {
        foreach ($prop in @('total', 'totalCount', 'count', 'Total', 'TotalCount', 'Count')) {
            if ($data.PSObject.Properties.Name -contains $prop) {
                $val = $data.$prop
                if ($null -ne $val) {
                    $intVal = 0
                    if ([int]::TryParse($val.ToString(), [ref]$intVal)) {
                        return $intVal
                    }
                }
            }
        }
    }

    # Fallback: count the items array if data is an array
    if ($data -is [System.Array]) {
        return $data.Count
    }

    return 0
}

#endregion

#region Public Functions

function Get-SPCertifications {
    <#
    .SYNOPSIS
        Retrieves a single page of certifications for a given campaign.
    .DESCRIPTION
        GETs /certifications filtered by campaign.id, with configurable
        limit and offset for manual pagination.
    .PARAMETER CampaignId
        The campaign ID to filter certifications by.
    .PARAMETER Limit
        Maximum number of records to return per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset into the full result set. Default: 0.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$certArray; TotalCount=$int; Error=$string}
    .EXAMPLE
        $result = Get-SPCertifications -CampaignId 'camp-abc123' -Limit 100 -Offset 0
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [int]$Limit = 250,

        [Parameter()]
        [int]$Offset = 0,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting certifications: CampaignId='$CampaignId', Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPCertifications' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $queryParams = @{
            'filters' = "campaign.id eq `"$CampaignId`""
            'limit'   = $Limit.ToString()
            'offset'  = $Offset.ToString()
        }

        $result = Invoke-SPApiRequest -Method GET -Endpoint '/certifications' `
            -QueryParams $queryParams `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; TotalCount = 0; Error = $result.Error }
        }

        # Normalize: API may return array directly or object with items property
        $items = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $items = $result.Data.items
        }
        if ($null -eq $items) {
            $items = @()
        }

        $totalCount = Get-SPTotalCountFromResult -ApiResult $result

        Write-SPLog -Message "Got $($items.Count) certifications (total: $totalCount) for campaign '$CampaignId'" `
            -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPCertifications' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        return @{ Success = $true; Data = $items; TotalCount = $totalCount; Error = $null }
    }
    catch {
        $errMsg = "Get-SPCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
            -Action 'Get-SPCertifications' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; TotalCount = 0; Error = $errMsg }
    }
}

function Get-SPAllCertifications {
    <#
    .SYNOPSIS
        Retrieves ALL certifications for a campaign, auto-paginating as needed.
    .DESCRIPTION
        Calls Get-SPCertifications repeatedly with increasing offset until all
        certifications are retrieved.  Stops when the returned page is empty or
        smaller than the requested limit.
    .PARAMETER CampaignId
        The campaign ID to retrieve all certifications for.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$allCertsArray; Error=$string}
    .EXAMPLE
        $result = Get-SPAllCertifications -CampaignId 'camp-abc123'
        $certs = $result.Data
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

    Write-SPLog -Message "Getting ALL certifications for campaign '$CampaignId' (auto-paginating)" `
        -Severity INFO -Component 'SP.Certifications' -Action 'Get-SPAllCertifications' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $allCerts  = [System.Collections.Generic.List[object]]::new()
        $pageSize  = 250
        $offset    = 0
        $pageNum   = 0

        do {
            $pageNum++
            $pageResult = Get-SPCertifications -CampaignId $CampaignId `
                -Limit $pageSize -Offset $offset `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            if (-not $pageResult.Success) {
                $errMsg = "Get-SPAllCertifications failed at page $pageNum (offset $offset): $($pageResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
                    -Action 'Get-SPAllCertifications' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $pageResult.Data
            if ($null -ne $page -and $page.Count -gt 0) {
                foreach ($cert in $page) {
                    $allCerts.Add($cert)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) certifications (running total: $($allCerts.Count))" `
                -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPAllCertifications' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCerts.Count) total certifications for campaign '$CampaignId'" `
            -Severity INFO -Component 'SP.Certifications' -Action 'Get-SPAllCertifications' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        return @{ Success = $true; Data = $allCerts.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAllCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
            -Action 'Get-SPAllCertifications' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAccessReviewItems {
    <#
    .SYNOPSIS
        Retrieves a single page of access review items for a certification.
    .DESCRIPTION
        GETs /certifications/{id}/access-review-items with configurable
        limit and offset for manual pagination.
    .PARAMETER CertificationId
        The certification ID to retrieve items for.
    .PARAMETER Limit
        Maximum number of records to return per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset into the full result set. Default: 0.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$itemsArray; TotalCount=$int; Error=$string}
    .EXAMPLE
        $result = Get-SPAccessReviewItems -CertificationId 'cert-xyz' -Limit 100
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [int]$Limit = 250,

        [Parameter()]
        [int]$Offset = 0,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [string]$CampaignTestId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting access review items: CertificationId='$CertificationId', Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPAccessReviewItems' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $queryParams = @{
            'limit'  = $Limit.ToString()
            'offset' = $Offset.ToString()
        }

        $endpoint = "/certifications/$CertificationId/access-review-items"
        $result   = Invoke-SPApiRequest -Method GET -Endpoint $endpoint `
            -QueryParams $queryParams `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; TotalCount = 0; Error = $result.Error }
        }

        # Normalize response
        $items = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $items = $result.Data.items
        }
        if ($null -eq $items) {
            $items = @()
        }

        $totalCount = Get-SPTotalCountFromResult -ApiResult $result

        Write-SPLog -Message "Got $($items.Count) access review items (total: $totalCount) for certification '$CertificationId'" `
            -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPAccessReviewItems' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        return @{ Success = $true; Data = $items; TotalCount = $totalCount; Error = $null }
    }
    catch {
        $errMsg = "Get-SPAccessReviewItems failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
            -Action 'Get-SPAccessReviewItems' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; TotalCount = 0; Error = $errMsg }
    }
}

function Get-SPAllAccessReviewItems {
    <#
    .SYNOPSIS
        Retrieves ALL access review items for a certification, auto-paginating.
    .DESCRIPTION
        Calls Get-SPAccessReviewItems repeatedly with increasing offset until
        all items are retrieved.  Stops when the returned page is empty or
        smaller than the page size.
    .PARAMETER CertificationId
        The certification ID to retrieve all items for.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .PARAMETER CampaignTestId
        Test case identifier.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$allItemsArray; Error=$string}
    .EXAMPLE
        $result = Get-SPAllAccessReviewItems -CertificationId 'cert-xyz'
        $items = $result.Data
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

    Write-SPLog -Message "Getting ALL access review items for certification '$CertificationId' (auto-paginating)" `
        -Severity INFO -Component 'SP.Certifications' -Action 'Get-SPAllAccessReviewItems' `
        -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

    try {
        $allItems = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0

        do {
            $pageNum++
            $pageResult = Get-SPAccessReviewItems -CertificationId $CertificationId `
                -Limit $pageSize -Offset $offset `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            if (-not $pageResult.Success) {
                $errMsg = "Get-SPAllAccessReviewItems failed at page $pageNum (offset $offset): $($pageResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
                    -Action 'Get-SPAllAccessReviewItems' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $pageResult.Data
            if ($null -ne $page -and $page.Count -gt 0) {
                foreach ($item in $page) {
                    $allItems.Add($item)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) access review items (running total: $($allItems.Count))" `
                -Severity DEBUG -Component 'SP.Certifications' -Action 'Get-SPAllAccessReviewItems' `
                -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allItems.Count) total access review items for certification '$CertificationId'" `
            -Severity INFO -Component 'SP.Certifications' -Action 'Get-SPAllAccessReviewItems' `
            -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId

        return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAllAccessReviewItems failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Certifications' `
            -Action 'Get-SPAllAccessReviewItems' -CorrelationID $CorrelationID -CampaignTestId $CampaignTestId
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPCertifications',
    'Get-SPAllCertifications',
    'Get-SPAccessReviewItems',
    'Get-SPAllAccessReviewItems'
)
