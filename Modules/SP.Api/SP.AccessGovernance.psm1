#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Access Profile, Role, and Transform Primitives
.DESCRIPTION
    Thin wrappers over the ISC v3 access-governance endpoints: access profiles,
    roles with membership criteria, and transforms. All calls delegate HTTP work
    to Invoke-SPApiRequest.

    These are the write primitives the B2B setup orchestrator composes. Every
    create/update supports ShouldProcess so an orchestrator can run a full
    -WhatIf pass without touching the tenant.

    Search campaigns are NOT built here: New-SPCampaign -Type SEARCH
    (SP.Campaigns.psm1) already accepts an inline search filter, so no saved
    search object is needed for a campaign scope.
.NOTES
    Module: SP.AccessGovernance
    Version: 1.0.0

    Endpoints are written WITH the /v3 prefix. Invoke-SPApiRequest normalizes the
    duplicate version segment when Api.BaseUrl already ends in /v3, so both
    endpoint styles resolve to the same URL.
#>

#region Internal Functions

function Get-SPAccessGovernancePaginationCeiling {
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

function Build-SPAccessProfileBody {
    <#
    .SYNOPSIS
        Builds the access profile creation request body.
    .PARAMETER Name
        Access profile display name.
    .PARAMETER SourceId
        ID of the source that owns every entitlement in the profile. ISC rejects
        an access profile whose entitlements come from a different source.
    .PARAMETER OwnerIdentityId
        Identity ID recorded as the access profile owner.
    .PARAMETER EntitlementId
        Entitlement IDs to bundle into the profile.
    .PARAMETER SourceName
        Optional source display name, echoed into the source reference.
    .PARAMETER Description
        Optional description.
    .PARAMETER Requestable
        Whether the profile can be requested through the access request catalog.
    .PARAMETER Enabled
        Whether the profile is active.
    .OUTPUTS
        [hashtable] Access profile body ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SourceId,

        [Parameter(Mandatory)]
        [string]$OwnerIdentityId,

        [Parameter()]
        [AllowNull()]
        [string[]]$EntitlementId,

        [Parameter()]
        [string]$SourceName,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [bool]$Requestable = $false,

        [Parameter()]
        [bool]$Enabled = $true
    )

    $sourceRef = @{
        id   = $SourceId
        type = 'SOURCE'
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceName)) {
        $sourceRef['name'] = $SourceName
    }

    $entitlementRefs = @()
    if ($null -ne $EntitlementId) {
        foreach ($entId in $EntitlementId) {
            if ([string]::IsNullOrWhiteSpace($entId)) { continue }
            $entitlementRefs += @{ id = $entId; type = 'ENTITLEMENT' }
        }
    }

    return @{
        name         = $Name
        description  = if ($Description) { $Description } else { '' }
        source       = $sourceRef
        owner        = @{ type = 'IDENTITY'; id = $OwnerIdentityId }
        entitlements = @($entitlementRefs)
        requestable  = $Requestable
        enabled      = $Enabled
    }
}

function Build-SPRoleBody {
    <#
    .SYNOPSIS
        Builds the role creation request body.
    .DESCRIPTION
        The Criteria hashtable is shipped VERBATIM under membership.criteria.
        Callers own the criteria schema (operation / key / value / children) --
        this function does not rewrite, validate, or normalize it, so a tenant
        with non-standard identity attribute names is not silently corrected.
    .PARAMETER Name
        Role display name.
    .PARAMETER OwnerIdentityId
        Identity ID recorded as the role owner.
    .PARAMETER AccessProfileId
        Access profile IDs granted by the role.
    .PARAMETER Criteria
        Role membership criteria hashtable. When omitted, no membership block is
        emitted and ISC treats the role as manually assigned.
    .PARAMETER Description
        Optional description.
    .PARAMETER Requestable
        Whether the role can be requested through the access request catalog.
    .PARAMETER Enabled
        Whether the role is active.
    .OUTPUTS
        [hashtable] Role body ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$OwnerIdentityId,

        [Parameter()]
        [AllowNull()]
        [string[]]$AccessProfileId,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Criteria,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [bool]$Requestable = $false,

        [Parameter()]
        [bool]$Enabled = $true
    )

    $accessProfileRefs = @()
    if ($null -ne $AccessProfileId) {
        foreach ($apId in $AccessProfileId) {
            if ([string]::IsNullOrWhiteSpace($apId)) { continue }
            $accessProfileRefs += @{ id = $apId; type = 'ACCESS_PROFILE' }
        }
    }

    $body = @{
        name           = $Name
        description    = if ($Description) { $Description } else { '' }
        owner          = @{ type = 'IDENTITY'; id = $OwnerIdentityId }
        accessProfiles = @($accessProfileRefs)
        requestable    = $Requestable
        enabled        = $Enabled
    }

    if ($null -ne $Criteria -and $Criteria.Count -gt 0) {
        $body['membership'] = @{
            type     = 'CRITERIA'
            criteria = $Criteria
        }
    }

    return $body
}

function Build-SPTransformBody {
    <#
    .SYNOPSIS
        Builds the transform create/update request body.
    .PARAMETER Name
        Transform name. ISC treats this as the transform's stable identifier in
        attribute mappings, so it must stay constant across updates.
    .PARAMETER Type
        Transform type, e.g. 'lookup', 'split', 'lower'.
    .PARAMETER Attributes
        Type-specific attribute hashtable, shipped verbatim.
    .OUTPUTS
        [hashtable] Transform body ready for ConvertTo-Json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [hashtable]$Attributes
    )

    return @{
        name       = $Name
        type       = $Type
        attributes = $Attributes
    }
}

#endregion

#region Public Functions

function New-SPAccessProfile {
    <#
    .SYNOPSIS
        Creates a SailPoint ISC access profile bundling source entitlements.
    .DESCRIPTION
        POSTs to /v3/access-profiles. Every entitlement in the profile must come
        from the source identified by -SourceId; ISC rejects cross-source
        bundles. Callers should GET first (Get-SPAccessProfiles -Name) because
        ISC returns 400 on a duplicate name rather than returning the existing
        profile.
    .PARAMETER Name
        Access profile display name.
    .PARAMETER SourceId
        ID of the source that owns the bundled entitlements.
    .PARAMETER OwnerIdentityId
        Identity ID recorded as the access profile owner.
    .PARAMETER EntitlementId
        Entitlement IDs to bundle.
    .PARAMETER SourceName
        Optional source display name, echoed into the source reference.
    .PARAMETER Description
        Optional description.
    .PARAMETER Requestable
        When set, the profile appears in the access request catalog. Leave unset
        for baseline access granted automatically by role criteria.
    .PARAMETER Disabled
        When set, the profile is created in a disabled state.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$accessProfileObject; Error=$string}
    .EXAMPLE
        $result = New-SPAccessProfile -Name 'B2B PartnerA - Users Access' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-cld-b2b-partnera-users'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerIdentityId,

        [Parameter()]
        [string[]]$EntitlementId,

        [Parameter()]
        [string]$SourceName,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [switch]$Requestable,

        [Parameter()]
        [switch]$Disabled,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Access profile '$Name'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating access profile: Name='$Name', SourceId='$SourceId', Requestable=$($Requestable.IsPresent)" `
        -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPAccessProfile' `
        -CorrelationID $CorrelationID

    try {
        $body = Build-SPAccessProfileBody -Name $Name -SourceId $SourceId `
            -OwnerIdentityId $OwnerIdentityId -EntitlementId $EntitlementId `
            -SourceName $SourceName -Description $Description `
            -Requestable ([bool]$Requestable) -Enabled (-not [bool]$Disabled)

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/v3/access-profiles' `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Access profile created: Id='$($result.Data.id)', Name='$Name'" `
                -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPAccessProfile' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "New-SPAccessProfile failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'New-SPAccessProfile' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAccessProfiles {
    <#
    .SYNOPSIS
        Lists SailPoint ISC access profiles, optionally filtered.
    .DESCRIPTION
        GETs /v3/access-profiles with offset/limit auto-pagination. -Name is an
        exact ISC 'eq' match (the idempotency check used before creating a
        profile), -NamePrefix is a 'sw' match, -SourceId scopes to one source.
    .PARAMETER Name
        Exact access profile name to match (ISC 'eq').
    .PARAMETER NamePrefix
        Access profile name prefix to match (ISC 'sw').
    .PARAMETER SourceId
        Restrict results to a single source (ISC 'source.id eq').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([access profile objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAccessProfiles -Name 'B2B PartnerA - Users Access'
        if ($result.Data.Count -gt 0) { 'already exists' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$NamePrefix,

        [Parameter()]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Listing access profiles: Name='$Name', NamePrefix='$NamePrefix', SourceId='$SourceId'" `
        -Severity DEBUG -Component 'SP.AccessGovernance' -Action 'Get-SPAccessProfiles' `
        -CorrelationID $CorrelationID

    try {
        $clauses = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $clauses.Add("name eq `"$($Name.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($NamePrefix)) {
            $clauses.Add("name sw `"$($NamePrefix.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($SourceId)) {
            $clauses.Add("source.id eq `"$($SourceId.Replace('"', '\"'))`"")
        }
        $filters = $null
        if ($clauses.Count -gt 0) { $filters = ($clauses -join ' and ') }

        $allProfiles = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $maxPages = Get-SPAccessGovernancePaginationCeiling

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching access profiles: $maxPages pages ($($allProfiles.Count) profiles). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
                    -Action 'Get-SPAccessProfiles' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }
            if (-not [string]::IsNullOrWhiteSpace($filters)) {
                $queryParams['filters'] = $filters
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/access-profiles' `
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
                foreach ($item in $page) { $allProfiles.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        return @{ Success = $true; Data = $allProfiles.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAccessProfiles failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'Get-SPAccessProfiles' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function New-SPRole {
    <#
    .SYNOPSIS
        Creates a SailPoint ISC role, optionally with membership criteria.
    .DESCRIPTION
        POSTs to /v3/roles. When -Criteria is supplied it is shipped verbatim as
        membership.criteria with membership.type = CRITERIA; the caller owns the
        criteria schema, including the identity attribute property names, which
        are tenant-specific and are NOT validated here.

        Criteria are evaluated during identity refresh, not at creation time, so
        access does not appear immediately after this call returns.

        Callers should GET first (Get-SPRoles -Name) because ISC returns 400 on a
        duplicate role name.
    .PARAMETER Name
        Role display name.
    .PARAMETER OwnerIdentityId
        Identity ID recorded as the role owner.
    .PARAMETER AccessProfileId
        Access profile IDs granted by this role.
    .PARAMETER Criteria
        Role membership criteria hashtable matching the ISC schema, e.g.
        @{ operation='AND'; children=@(@{ operation='EQUALS'
           key=@{ type='IDENTITY'; property='attribute.userType' }; value='Guest' }) }
    .PARAMETER Description
        Optional description.
    .PARAMETER Requestable
        When set, the role appears in the access request catalog. Leave unset for
        criteria-assigned roles.
    .PARAMETER Disabled
        When set, the role is created in a disabled state.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$roleObject; Error=$string}
    .EXAMPLE
        $criteria = @{
            operation = 'AND'
            children  = @(
                @{ operation = 'EQUALS'; key = @{ type = 'IDENTITY'; property = 'attribute.userType' }; value = 'Guest' }
                @{ operation = 'CONTAINS'; key = @{ type = 'IDENTITY'; property = 'attribute.email' }; value = 'partnera.com' }
            )
        }
        $result = New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-123' -Criteria $criteria
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OwnerIdentityId,

        [Parameter()]
        [string[]]$AccessProfileId,

        [Parameter()]
        [hashtable]$Criteria,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [switch]$Requestable,

        [Parameter()]
        [switch]$Disabled,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Role '$Name'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    $criteriaLabel = if ($null -ne $Criteria -and $Criteria.Count -gt 0) { 'CRITERIA' } else { 'none' }
    Write-SPLog -Message "Creating role: Name='$Name', Membership='$criteriaLabel', AccessProfiles=$(@($AccessProfileId).Count)" `
        -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPRole' `
        -CorrelationID $CorrelationID

    try {
        $body = Build-SPRoleBody -Name $Name -OwnerIdentityId $OwnerIdentityId `
            -AccessProfileId $AccessProfileId -Criteria $Criteria `
            -Description $Description -Requestable ([bool]$Requestable) `
            -Enabled (-not [bool]$Disabled)

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/v3/roles' `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Role created: Id='$($result.Data.id)', Name='$Name'" `
                -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPRole' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "New-SPRole failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'New-SPRole' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPRoles {
    <#
    .SYNOPSIS
        Lists SailPoint ISC roles, optionally filtered by name.
    .DESCRIPTION
        GETs /v3/roles with offset/limit auto-pagination. The roles endpoint uses
        a smaller page size than access profiles because role bodies carry their
        full access profile and criteria structures.
    .PARAMETER Name
        Exact role name to match (ISC 'eq').
    .PARAMETER NamePrefix
        Role name prefix to match (ISC 'sw').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([role objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPRoles -NamePrefix 'B2B-PartnerA'
        $result.Data | ForEach-Object { $_.name }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
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

    Write-SPLog -Message "Listing roles: Name='$Name', NamePrefix='$NamePrefix'" `
        -Severity DEBUG -Component 'SP.AccessGovernance' -Action 'Get-SPRoles' `
        -CorrelationID $CorrelationID

    try {
        $clauses = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $clauses.Add("name eq `"$($Name.Replace('"', '\"'))`"")
        }
        if (-not [string]::IsNullOrWhiteSpace($NamePrefix)) {
            $clauses.Add("name sw `"$($NamePrefix.Replace('"', '\"'))`"")
        }
        $filters = $null
        if ($clauses.Count -gt 0) { $filters = ($clauses -join ' and ') }

        $allRoles = [System.Collections.Generic.List[object]]::new()
        $pageSize = 50
        $offset   = 0
        $pageNum  = 0
        $maxPages = Get-SPAccessGovernancePaginationCeiling

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching roles: $maxPages pages ($($allRoles.Count) roles). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
                    -Action 'Get-SPRoles' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }
            if (-not [string]::IsNullOrWhiteSpace($filters)) {
                $queryParams['filters'] = $filters
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/roles' `
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
                foreach ($item in $page) { $allRoles.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        return @{ Success = $true; Data = $allRoles.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPRoles failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'Get-SPRoles' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function New-SPTransform {
    <#
    .SYNOPSIS
        Creates a SailPoint ISC transform.
    .DESCRIPTION
        POSTs to /v3/transforms. The -Attributes hashtable is shipped verbatim
        as the transform's attributes block, so any transform type ISC supports
        can be deployed without a per-type function.

        Transform names are the identifier used by identity attribute mappings,
        so a name is effectively permanent once referenced.
    .PARAMETER Name
        Transform name.
    .PARAMETER Type
        Transform type, e.g. 'lookup', 'split', 'lower', 'static'.
    .PARAMETER Attributes
        Type-specific attribute hashtable.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$transformObject; Error=$string}
    .EXAMPLE
        $attrs = @{
            input = @{ type = 'identityAttribute'; attributes = @{ name = 'email' } }
            table = @{ 'partnera.com' = 'CLD-B2B-PartnerA-Users' }
            default = 'CLD-B2B-Unknown-Review'
        }
        $result = New-SPTransform -Name 'B2B Partner Group Resolver' -Type 'lookup' -Attributes $attrs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Attributes,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Transform '$Name'", 'Create')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Creating transform: Name='$Name', Type='$Type'" `
        -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPTransform' `
        -CorrelationID $CorrelationID

    try {
        $body = Build-SPTransformBody -Name $Name -Type $Type -Attributes $Attributes

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/v3/transforms' `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Transform created: Id='$($result.Data.id)', Name='$Name'" `
                -Severity INFO -Component 'SP.AccessGovernance' -Action 'New-SPTransform' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "New-SPTransform failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'New-SPTransform' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Set-SPTransform {
    <#
    .SYNOPSIS
        Updates an existing SailPoint ISC transform.
    .DESCRIPTION
        PUTs to /v3/transforms/{id}. This is a FULL replacement, not a partial
        patch: the body must carry the complete attributes block, so callers
        adding one entry to a lookup table must send the merged table, not just
        the new key.
    .PARAMETER TransformId
        The unique ID of the transform to update.
    .PARAMETER Name
        Transform name. Keep this identical to the existing name -- identity
        attribute mappings reference transforms by name.
    .PARAMETER Type
        Transform type, e.g. 'lookup'.
    .PARAMETER Attributes
        Complete replacement attribute hashtable.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=$transformObject; Error=$string}
    .EXAMPLE
        $result = Set-SPTransform -TransformId 'tf-123' -Name 'B2B Partner Group Resolver' `
            -Type 'lookup' -Attributes $mergedAttributes
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TransformId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Attributes,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if (-not $PSCmdlet.ShouldProcess("Transform '$Name' ($TransformId)", 'Update')) {
        return @{ Success = $true; Data = $null; Error = 'Skipped (WhatIf)' }
    }

    Write-SPLog -Message "Updating transform: Id='$TransformId', Name='$Name', Type='$Type'" `
        -Severity INFO -Component 'SP.AccessGovernance' -Action 'Set-SPTransform' `
        -CorrelationID $CorrelationID

    try {
        $body = Build-SPTransformBody -Name $Name -Type $Type -Attributes $Attributes

        $result = Invoke-SPApiRequest -Method PUT -Endpoint "/v3/transforms/$TransformId" `
            -Body $body -CorrelationID $CorrelationID

        if ($result.Success) {
            Write-SPLog -Message "Transform updated: Id='$TransformId', Name='$Name'" `
                -Severity INFO -Component 'SP.AccessGovernance' -Action 'Set-SPTransform' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = $result.Data; Error = $null }
        }
        else {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }
    }
    catch {
        $errMsg = "Set-SPTransform failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'Set-SPTransform' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPTransforms {
    <#
    .SYNOPSIS
        Lists SailPoint ISC transforms, optionally filtered by name.
    .DESCRIPTION
        GETs /v3/transforms with offset/limit auto-pagination. Used to decide
        between create and update: a transform found by exact name is updated
        in place rather than recreated.
    .PARAMETER Name
        Exact transform name to match (ISC 'eq').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([transform objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPTransforms -Name 'B2B Partner Group Resolver'
        if ($result.Data.Count -gt 0) { $result.Data[0].id }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Listing transforms: Name='$Name'" `
        -Severity DEBUG -Component 'SP.AccessGovernance' -Action 'Get-SPTransforms' `
        -CorrelationID $CorrelationID

    try {
        $filters = $null
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $filters = "name eq `"$($Name.Replace('"', '\"'))`""
        }

        $allTransforms = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $maxPages = Get-SPAccessGovernancePaginationCeiling

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching transforms: $maxPages pages ($($allTransforms.Count) transforms). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
                    -Action 'Get-SPTransforms' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }
            if (-not [string]::IsNullOrWhiteSpace($filters)) {
                $queryParams['filters'] = $filters
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/transforms' `
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
                foreach ($item in $page) { $allTransforms.Add($item) }
            }

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        return @{ Success = $true; Data = $allTransforms.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPTransforms failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AccessGovernance' `
            -Action 'Get-SPTransforms' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-SPAccessProfile',
    'Get-SPAccessProfiles',
    'New-SPRole',
    'Get-SPRoles',
    'New-SPTransform',
    'Set-SPTransform',
    'Get-SPTransforms'
)
