#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Common Utilities
.DESCRIPTION
    Shared helper functions for the SP.Sdk module family.
    Provides a generic auto-paginator that wraps Invoke-SPApiRequest
    for offset/limit based ISC V3 collection endpoints.
.NOTES
    Module: SP.SdkCommon
    Version: 1.0.0
#>

function Invoke-SPSdkPaginatedGet {
    <#
    .SYNOPSIS
        Auto-paginating GET for ISC V3 collection endpoints.
    .DESCRIPTION
        Repeatedly GETs the specified endpoint with offset/limit pagination
        until fewer items than the page size are returned. Follows the same
        ceiling-protection pattern used in SP.Campaigns and SP.Certifications.
    .PARAMETER Endpoint
        Relative API path (e.g. '/campaign-templates').
    .PARAMETER QueryParams
        Additional query parameters (filters, sorters, etc.). Limit and offset
        are managed by this function and should not be included.
    .PARAMETER PageSize
        Items per page. Default: 250 (ISC maximum for list endpoints).
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$allItems; Error=$string}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter()]
        [hashtable]$QueryParams = @{},

        [Parameter()]
        [int]$PageSize = 250,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $config = Get-SPConfig
    $maxPages = if ($config.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                     $config.Api.MaxPaginationPages -gt 0) {
                    $config.Api.MaxPaginationPages
                } else { 200 }

    $allItems = [System.Collections.Generic.List[object]]::new()
    $offset   = 0
    $pageNum  = 0

    do {
        $pageNum++
        if ($pageNum -gt $maxPages) {
            $errMsg = "Pagination ceiling reached: $maxPages pages fetched (accumulated $($allItems.Count) items). Raise Api.MaxPaginationPages in settings.json if this is a legitimate large dataset."
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.SdkCommon' `
                -Action 'Invoke-SPSdkPaginatedGet' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $pageParams = $QueryParams.Clone()
        $pageParams['limit']  = $PageSize.ToString()
        $pageParams['offset'] = $offset.ToString()

        $result = Invoke-SPApiRequest -Method GET -Endpoint $Endpoint `
            -QueryParams $pageParams -CorrelationID $CorrelationID

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }

        # Normalize: API may return array directly or object with items property
        $page = $result.Data
        if ($null -ne $result.Data -and
            $result.Data.PSObject.Properties.Name -contains 'items') {
            $page = $result.Data.items
        }
        # Force array wrap (PS 5.1 single-element unwrap protection)
        $page = @($page)

        if ($page.Count -gt 0) {
            foreach ($item in $page) {
                $allItems.Add($item)
            }
        }

        Write-SPLog -Message "Page ${pageNum}: $($page.Count) items from $Endpoint (total: $($allItems.Count))" `
            -Severity DEBUG -Component 'SP.SdkCommon' -Action 'Invoke-SPSdkPaginatedGet' `
            -CorrelationID $CorrelationID

        $offset += $PageSize
    } while ($page.Count -ge $PageSize)

    return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
}

Export-ModuleMember -Function @(
    'Invoke-SPSdkPaginatedGet'
)
