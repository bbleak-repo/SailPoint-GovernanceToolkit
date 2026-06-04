#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - SDK Certification Summary Queries
.DESCRIPTION
    Wraps the ISC V3 certification summary endpoints:
    /certifications/{id}/identity-summaries, /certifications/{id}/access-summaries/{type},
    /certifications/{id}/decision-summary.
    Parity with PSSailpoint SDK CertificationSummariesApi.

    All HTTP calls are delegated to Invoke-SPApiRequest (SP.Api).
    Auto-paginating wrappers use Invoke-SPSdkPaginatedGet (SP.SdkCommon).
.NOTES
    Module: SP.SdkCertSummaries
    Version: 1.0.0
    SDK Source: PSSailpoint/v3/src/PSSailpoint.V3/Api/CertificationSummariesApi.ps1
#>

function Get-SPSdkIdentitySummaries {
    <#
    .SYNOPSIS
        Lists identity summaries for a certification with optional filtering and sorting.
    .DESCRIPTION
        GETs /certifications/{id}/identity-summaries with standard collection parameters.
    .PARAMETER CertificationId
        The certification campaign ID.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression.
    .PARAMETER Sorters
        Sort expression.
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
        [string]$CertificationId,

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
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing identity summaries for certification ${CertificationId}: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkIdentitySummaries' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET -Endpoint "/certifications/$CertificationId/identity-summaries" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) identity summaries for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkIdentitySummaries' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllIdentitySummaries {
    <#
    .SYNOPSIS
        Auto-paginating wrapper that retrieves all identity summaries for a certification.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to page through
        /certifications/{id}/identity-summaries until all records are fetched.
    .PARAMETER CertificationId
        The certification campaign ID.
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
        [string]$CertificationId,

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

    Write-SPLog -Message "Fetching all identity summaries for certification $CertificationId (paginated)" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAllIdentitySummaries' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet -Endpoint "/certifications/$CertificationId/identity-summaries" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Fetched $($result.Data.Count) total identity summaries for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAllIdentitySummaries' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkIdentitySummary {
    <#
    .SYNOPSIS
        Gets a single identity summary by ID within a certification.
    .PARAMETER CertificationId
        The certification campaign ID.
    .PARAMETER IdentitySummaryId
        The identity summary ID.
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
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentitySummaryId,

        [Parameter()] [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity summary $IdentitySummaryId for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkIdentitySummary' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET `
        -Endpoint "/certifications/$CertificationId/identity-summaries/$IdentitySummaryId" `
        -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkAccessSummaries {
    <#
    .SYNOPSIS
        Lists access summaries for a certification by access type.
    .DESCRIPTION
        GETs /certifications/{id}/access-summaries/{type} with standard collection parameters.
    .PARAMETER CertificationId
        The certification campaign ID.
    .PARAMETER Type
        Access type: ROLE, ACCESS_PROFILE, or ENTITLEMENT.
    .PARAMETER Limit
        Maximum records per page. Default: 250.
    .PARAMETER Offset
        Zero-based offset. Default: 0.
    .PARAMETER Filters
        ISC filter expression.
    .PARAMETER Sorters
        Sort expression.
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
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateSet('ROLE', 'ACCESS_PROFILE', 'ENTITLEMENT')]
        [string]$Type,

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
    if (-not [string]::IsNullOrWhiteSpace($Filters)) {
        $queryParams['filters'] = $Filters
    }
    if (-not [string]::IsNullOrWhiteSpace($Sorters)) {
        $queryParams['sorters'] = $Sorters
    }

    Write-SPLog -Message "Listing $Type access summaries for certification ${CertificationId}: Limit=$Limit, Offset=$Offset" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAccessSummaries' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET `
        -Endpoint "/certifications/$CertificationId/access-summaries/$Type" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    $items = $result.Data
    if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
        $items = $result.Data.items
    }
    $items = @($items)

    Write-SPLog -Message "Got $($items.Count) $Type access summaries for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAccessSummaries' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $items; Error = $null }
}

function Get-SPSdkAllAccessSummaries {
    <#
    .SYNOPSIS
        Auto-paginating wrapper that retrieves all access summaries for a certification by type.
    .DESCRIPTION
        Calls Invoke-SPSdkPaginatedGet to page through
        /certifications/{id}/access-summaries/{type} until all records are fetched.
    .PARAMETER CertificationId
        The certification campaign ID.
    .PARAMETER Type
        Access type: ROLE, ACCESS_PROFILE, or ENTITLEMENT.
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
        [string]$CertificationId,

        [Parameter(Mandatory)]
        [ValidateSet('ROLE', 'ACCESS_PROFILE', 'ENTITLEMENT')]
        [string]$Type,

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

    Write-SPLog -Message "Fetching all $Type access summaries for certification $CertificationId (paginated)" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAllAccessSummaries' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPSdkPaginatedGet `
        -Endpoint "/certifications/$CertificationId/access-summaries/$Type" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    Write-SPLog -Message "Fetched $($result.Data.Count) total $Type access summaries for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkAllAccessSummaries' `
        -CorrelationID $CorrelationID

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

function Get-SPSdkDecisionSummary {
    <#
    .SYNOPSIS
        Gets the decision summary for a certification.
    .DESCRIPTION
        GETs /certifications/{id}/decision-summary. Returns a single summary object
        with counts of decisions by type (APPROVE, REVOKE, etc.). Not paginated.
    .PARAMETER CertificationId
        The certification campaign ID.
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
        [string]$CertificationId,

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

    Write-SPLog -Message "Getting decision summary for certification $CertificationId" `
        -Severity DEBUG -Component 'SP.SdkCertSummaries' -Action 'Get-SPSdkDecisionSummary' `
        -CorrelationID $CorrelationID

    $result = Invoke-SPApiRequest -Method GET `
        -Endpoint "/certifications/$CertificationId/decision-summary" `
        -QueryParams $queryParams -CorrelationID $CorrelationID

    if (-not $result.Success) {
        return @{ Success = $false; Data = $null; Error = $result.Error }
    }

    return @{ Success = $true; Data = $result.Data; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-SPSdkIdentitySummaries',
    'Get-SPSdkAllIdentitySummaries',
    'Get-SPSdkIdentitySummary',
    'Get-SPSdkAccessSummaries',
    'Get-SPSdkAllAccessSummaries',
    'Get-SPSdkDecisionSummary'
)
