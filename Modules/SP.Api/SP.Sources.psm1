#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Source and Entitlement Primitives
.DESCRIPTION
    Thin wrappers over the ISC v3 source endpoints: source lookup, entitlement
    lookup, aggregation triggers, and provisioning policy inspection. All calls
    delegate to Invoke-SPApiRequest.

    These are primitives for setup/orchestration scripts. Report-oriented
    aggregation lives in SP.Audit (Get-SPSourceAggregationHealth,
    Get-SPEntitlementInventory) -- do not duplicate that logic here.
.NOTES
    Module: SP.Sources
    Version: 1.0.0

    Endpoints are written WITH the /v3 prefix. Invoke-SPApiRequest normalizes the
    duplicate version segment when Api.BaseUrl already ends in /v3, so both
    endpoint styles resolve to the same URL.
#>

#region Internal Functions

function Build-SPSourceFilterQuery {
    <#
    .SYNOPSIS
        Joins ISC filter clauses into a single 'and'-combined filter expression.
    .DESCRIPTION
        Returns $null when no clauses were supplied so the caller can omit the
        'filters' query parameter entirely rather than sending an empty string.
    .PARAMETER Clause
        One or more ISC filter clauses (e.g. 'name eq "Entra ID"').
    .OUTPUTS
        [string] Combined filter expression, or $null when no clauses given.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [string[]]$Clause
    )

    if ($null -eq $Clause) { return $null }

    $kept = @($Clause | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($kept.Count -eq 0) { return $null }

    return ($kept -join ' and ')
}

function Get-SPSourcePaginationCeiling {
    <#
    .SYNOPSIS
        Resolves the auto-paginator page ceiling from configuration.
    .DESCRIPTION
        Mirrors the M2 ceiling used by SP.Campaigns / SP.AuditQueries: fail loudly
        after N pages rather than spin forever on an offset or cursor regression.
    .OUTPUTS
        [int] Maximum number of pages a single auto-paginating call may fetch.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $maxPages = 200
    try {
        $cfgForCeiling = Get-SPConfig
        if ($null -ne $cfgForCeiling.Api -and
            $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
            [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
            $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
        }
    } catch { }
    return $maxPages
}

#endregion

#region Public Functions

function Get-SPSource {
    <#
    .SYNOPSIS
        Retrieves a single SailPoint ISC source by ID.
    .DESCRIPTION
        GETs /v3/sources/{id}. The returned object carries the source name,
        connector type, owner, and health flags used by the B2B setup
        orchestrator to verify the Entra connector before building on top of it.
    .PARAMETER SourceId
        The unique ID of the source.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$sourceObject; Error=$string}
    .EXAMPLE
        $result = Get-SPSource -SourceId 'src-entra-001'
        $result.Data.connector
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting source: Id='$SourceId'" `
        -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPSource' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/v3/sources/$SourceId" `
            -CorrelationID $CorrelationID

        if ($result.Success) {
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Get-SPSource failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Get-SPSource' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPSources {
    <#
    .SYNOPSIS
        Lists SailPoint ISC sources, optionally filtered by name or connector.
    .DESCRIPTION
        GETs /v3/sources with offset/limit auto-pagination. Name matching uses
        the ISC filter operators: -Name is an exact 'eq' match, -NamePrefix is a
        'sw' (starts-with) match. Connector filtering uses 'eq' against the
        source's connector attribute.
    .PARAMETER Name
        Exact source name to match (ISC 'eq').
    .PARAMETER NamePrefix
        Source name prefix to match (ISC 'sw').
    .PARAMETER ConnectorType
        Connector identifier to match, e.g. 'azure-active-directory' (ISC 'eq').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([source objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPSources -Name 'Entra ID - CORP'
        $result.Data[0].id
    .EXAMPLE
        $result = Get-SPSources -ConnectorType 'azure-active-directory'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$NamePrefix,

        [Parameter()]
        [string]$ConnectorType,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Listing sources: Name='$Name', NamePrefix='$NamePrefix', Connector='$ConnectorType'" `
        -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPSources' `
        -CorrelationID $CorrelationID

    try {
        $clauses = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $clauses.Add("name eq `"$($Name.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($NamePrefix)) {
            $clauses.Add("name sw `"$($NamePrefix.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($ConnectorType)) {
            $clauses.Add("connector eq `"$($ConnectorType.Replace('"', '\"'))`"")
        }
        $filters = Build-SPSourceFilterQuery -Clause $clauses.ToArray()

        $allSources = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $maxPages = Get-SPSourcePaginationCeiling

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching sources: $maxPages pages ($($allSources.Count) sources). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
                    -Action 'Get-SPSources' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }
            if (-not [string]::IsNullOrWhiteSpace($filters)) {
                $queryParams['filters'] = $filters
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/sources' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                return @{ Success = $false; Data = $null; Error = $result.Error }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page | Where-Object { $null -ne $_ })

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allSources.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Get-SPSources returned $($allSources.Count) source(s)" `
            -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPSources' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allSources.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPSources failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Get-SPSources' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPEntitlements {
    <#
    .SYNOPSIS
        Lists SailPoint ISC entitlements filtered by source and/or name.
    .DESCRIPTION
        GETs /v3/entitlements with offset/limit auto-pagination. Combines the
        supplied filters with ISC's 'and' operator: source scoping uses
        'source.id eq', exact naming uses 'name eq', prefix naming uses 'name sw'.

        This is the primitive used by the B2B setup orchestrator to discover
        aggregated CLD-B2B-* groups. For reporting across many sources, use
        Get-SPEntitlementInventory in SP.Audit instead.
    .PARAMETER SourceId
        Restrict results to a single source (ISC 'source.id eq').
    .PARAMETER Name
        Exact entitlement name to match (ISC 'eq').
    .PARAMETER NamePrefix
        Entitlement name prefix to match, e.g. 'CLD-B2B-PartnerA' (ISC 'sw').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([entitlement objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPEntitlements -SourceId 'src-entra-001' -NamePrefix 'CLD-B2B-PartnerA'
        $result.Data | ForEach-Object { $_.name }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$SourceId,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$NamePrefix,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Listing entitlements: SourceId='$SourceId', Name='$Name', NamePrefix='$NamePrefix'" `
        -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPEntitlements' `
        -CorrelationID $CorrelationID

    try {
        $clauses = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($SourceId)) {
            $clauses.Add("source.id eq `"$($SourceId.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $clauses.Add("name eq `"$($Name.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($NamePrefix)) {
            $clauses.Add("name sw `"$($NamePrefix.Replace('"', '\"'))`"")
        }
        $filters = Build-SPSourceFilterQuery -Clause $clauses.ToArray()

        $allEntitlements = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $maxPages = Get-SPSourcePaginationCeiling

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching entitlements: $maxPages pages ($($allEntitlements.Count) entitlements). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
                    -Action 'Get-SPEntitlements' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }
            if (-not [string]::IsNullOrWhiteSpace($filters)) {
                $queryParams['filters'] = $filters
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/entitlements' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                return @{ Success = $false; Data = $null; Error = $result.Error }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page | Where-Object { $null -ne $_ })

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allEntitlements.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Get-SPEntitlements returned $($allEntitlements.Count) entitlement(s)" `
            -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPEntitlements' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allEntitlements.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPEntitlements failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Get-SPEntitlements' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Start-SPAccountAggregation {
    <#
    .SYNOPSIS
        Triggers an account aggregation run on a SailPoint ISC source.
    .DESCRIPTION
        POSTs to /v3/sources/{id}/load-accounts. This MUTATES tenant state, so it
        is gated by ShouldProcess -- run with -WhatIf to confirm the target
        without starting a run.

        The call is asynchronous: it returns a task reference, not a finished
        aggregation. Poll the source's aggregation history (or SP.Audit's
        Get-SPSourceAggregationHealth) to observe completion.

        A 403 here means the token lacks source manage permission, not merely
        source read -- aggregation triggers write to the tenant.
    .PARAMETER SourceId
        The unique ID of the source to aggregate.
    .PARAMETER DisableOptimization
        When set, sends disableOptimization=true so ISC processes every account
        rather than only those it believes changed. Slower, but the safe choice
        after a connector configuration change.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$taskObject; Error=$string}
    .EXAMPLE
        $result = Start-SPAccountAggregation -SourceId 'src-entra-001' -DisableOptimization
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [switch]$DisableOptimization,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Source '$SourceId'", 'Start account aggregation')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Starting account aggregation: SourceId='$SourceId', DisableOptimization=$($DisableOptimization.IsPresent)" `
        -Severity INFO -Component 'SP.Sources' -Action 'Start-SPAccountAggregation' `
        -CorrelationID $CorrelationID

    try {
        $body = @{ disableOptimization = [bool]$DisableOptimization }

        $result = Invoke-SPApiRequest -Method POST -Endpoint "/v3/sources/$SourceId/load-accounts" `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Account aggregation submitted for source '$SourceId'" `
                -Severity INFO -Component 'SP.Sources' -Action 'Start-SPAccountAggregation' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Start-SPAccountAggregation failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Start-SPAccountAggregation' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Start-SPEntitlementAggregation {
    <#
    .SYNOPSIS
        Triggers an entitlement aggregation run on a SailPoint ISC source.
    .DESCRIPTION
        POSTs to /v3/sources/{id}/load-entitlements. This is the call that makes
        newly created Entra groups visible in ISC as entitlements. It MUTATES
        tenant state and is gated by ShouldProcess.

        Like account aggregation, the call is asynchronous and a 403 indicates
        the token lacks source manage permission rather than source read.
    .PARAMETER SourceId
        The unique ID of the source to aggregate.
    .PARAMETER DisableOptimization
        When set, sends disableOptimization=true so every entitlement is
        reprocessed instead of only those ISC believes changed.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$taskObject; Error=$string}
    .EXAMPLE
        $result = Start-SPEntitlementAggregation -SourceId 'src-entra-001'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [switch]$DisableOptimization,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Source '$SourceId'", 'Start entitlement aggregation')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Starting entitlement aggregation: SourceId='$SourceId', DisableOptimization=$($DisableOptimization.IsPresent)" `
        -Severity INFO -Component 'SP.Sources' -Action 'Start-SPEntitlementAggregation' `
        -CorrelationID $CorrelationID

    try {
        $body = @{ disableOptimization = [bool]$DisableOptimization }

        $result = Invoke-SPApiRequest -Method POST -Endpoint "/v3/sources/$SourceId/load-entitlements" `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Entitlement aggregation submitted for source '$SourceId'" `
                -Severity INFO -Component 'SP.Sources' -Action 'Start-SPEntitlementAggregation' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Start-SPEntitlementAggregation failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Start-SPEntitlementAggregation' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPProvisioningPolicies {
    <#
    .SYNOPSIS
        Retrieves the provisioning policies configured on a SailPoint ISC source.
    .DESCRIPTION
        GETs /v3/sources/{id}/provisioning-policies. The response is a flat list;
        each policy carries a usageType such as CREATE, UPDATE, ADD_ENTITLEMENT,
        or REMOVE_ENTITLEMENT.

        Without ADD_ENTITLEMENT / REMOVE_ENTITLEMENT policies the connector cannot
        push group membership changes back to the target system. This is a
        read-only check: the toolkit reports the gap, it does not create policies.
    .PARAMETER SourceId
        The unique ID of the source.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([policy objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPProvisioningPolicies -SourceId 'src-entra-001'
        $result.Data | ForEach-Object { $_.usageType }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting provisioning policies: SourceId='$SourceId'" `
        -Severity DEBUG -Component 'SP.Sources' -Action 'Get-SPProvisioningPolicies' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET `
            -Endpoint "/v3/sources/$SourceId/provisioning-policies" `
            -CorrelationID $CorrelationID

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }

        # The endpoint returns a bare array, but tolerate an items-wrapped body
        # so a tenant-side response shape change does not silently yield zero
        # policies (which would read as "provisioning is not configured").
        $policies = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $policies = $result.Data.items
        }

        return @{ Success = $true; Data = @($policies); Error = $null }
    }
    catch {
        $errMsg = "Get-SPProvisioningPolicies failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Sources' `
            -Action 'Get-SPProvisioningPolicies' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPSource',
    'Get-SPSources',
    'Get-SPEntitlements',
    'Start-SPAccountAggregation',
    'Start-SPEntitlementAggregation',
    'Get-SPProvisioningPolicies'
)
