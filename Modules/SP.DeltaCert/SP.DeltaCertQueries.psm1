#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - AD Delta Certification Query Functions
.DESCRIPTION
    Provides functions for identifying newly-granted AD entitlements and grouping
    affected identities by manager for daily delta certification campaigns.

    Flow:
        1. Get-SPDeltaGrantEvents        - queries /v3/account-activities for GRANT_ACCESS
                                           events on specified AD sources within a time window
        2. Get-SPDeltaAffectedIdentities - resolves identity details and filters to active
                                           identities that have a manager in ISC
        3. Group-SPDeltaByManager        - groups identity IDs by their manager ID

    Authentication note:
        GET /v3/account-activities without a requested-for filter requires the
        sp:scopes:all OAuth scope (no granular scope exists for this endpoint).
        Use a browser token (-Token parameter) or a PAT with sp:scopes:all
        in environments where this scope is available.

.NOTES
    Module: SP.DeltaCertQueries
    Version: 1.0.0
#>

# Module-scope identity cache to avoid redundant API calls within a session.
$script:IdentityCache = @{}

# Module-scope entitlement privileged-status cache (keyed by "SourceId::ItemValue").
# Populated by Select-SPPrivilegedGrantEvents. Persists for the lifetime of the module
# import so repeated runs in the same session don't re-call the ISC entitlements API
# for the same group.
$script:EntitlementPrivilegedCache = @{}

#region Internal Functions

function Get-SPDeltaIdentityDetail {
    <#
    .SYNOPSIS
        Resolves an identity ID to its manager and active status, with in-memory caching.
    .DESCRIPTION
        Calls GET /v3/search/identities/{id} once per unique ID per session.
        Caches the result (including failures) so repeated lookups do not re-call the API.
        Requires sp:search:read scope.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{IdentityId; DisplayName; ManagerId; ManagerName; IsActive; Found}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $emptyResult = @{
        IdentityId          = $IdentityId
        DisplayName         = ''
        ManagerId           = ''
        ManagerName         = ''
        IsActive            = $false
        Found               = $false
        CloudLifecycleState = ''
        Email               = ''
        JobLevel            = ''
    }

    if ($script:IdentityCache.ContainsKey($IdentityId)) {
        return $script:IdentityCache[$IdentityId]
    }

    Write-SPLog -Message "Resolving identity details for '$IdentityId'" `
        -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaIdentityDetail' `
        -CorrelationID $CorrelationID

    try {
        # NOTE: GET /v3/identities/{id} does not exist in the ISC v3 API.
        # Use GET /v3/search/identities/{id} which returns the IdentityDocument
        # schema: manager.id, manager.name, attributes.cloudLifecycleState, displayName.
        # Requires sp:search:read scope.
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/search/identities/$IdentityId" `
            -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            $script:IdentityCache[$IdentityId] = $emptyResult
            return $emptyResult
        }

        $identity = $result.Data

        # Extract display name
        $displayName = ''
        foreach ($prop in @('displayName', 'name')) {
            if ($null -ne $identity.PSObject.Properties[$prop] -and
                -not [string]::IsNullOrWhiteSpace($identity.$prop)) {
                $displayName = [string]$identity.$prop
                break
            }
        }

        # Extract manager
        $managerId   = ''
        $managerName = ''
        if ($null -ne $identity.PSObject.Properties['manager'] -and $null -ne $identity.manager) {
            $mgr = $identity.manager
            if ($null -ne $mgr.PSObject.Properties['id'] -and
                -not [string]::IsNullOrWhiteSpace($mgr.id)) {
                $managerId = [string]$mgr.id
            }
            foreach ($prop in @('displayName', 'name')) {
                if ($null -ne $mgr.PSObject.Properties[$prop] -and
                    -not [string]::IsNullOrWhiteSpace($mgr.$prop)) {
                    $managerName = [string]$mgr.$prop
                    break
                }
            }
        }

        # Active status: ISC uses cloudLifecycleState on the attributes bag.
        # Treat missing or unrecognised states as active.
        $isActive = $true
        $cloudLifecycleState = ''
        if ($null -ne $identity.PSObject.Properties['attributes'] -and
            $null -ne $identity.attributes) {
            $attrs = $identity.attributes
            if ($null -ne $attrs.PSObject.Properties['cloudLifecycleState'] -and
                -not [string]::IsNullOrWhiteSpace($attrs.cloudLifecycleState)) {
                $cloudLifecycleState = [string]$attrs.cloudLifecycleState
                if ($cloudLifecycleState -in @('terminated', 'inactive', 'leaver', 'prehire')) {
                    $isActive = $false
                }
            }
        }

        # Extract email for downstream consumers (band classification, reports)
        $email = ''
        if ($null -ne $identity.PSObject.Properties['email'] -and
            -not [string]::IsNullOrWhiteSpace($identity.email)) {
            $email = [string]$identity.email
        }
        elseif ($null -ne $identity.PSObject.Properties['attributes'] -and
                $null -ne $identity.attributes -and
                $null -ne $identity.attributes.PSObject.Properties['email'] -and
                -not [string]::IsNullOrWhiteSpace($identity.attributes.email)) {
            $email = [string]$identity.attributes.email
        }

        # Extract job level / band attribute for band classification (OC-06)
        $jobLevel = ''
        if ($null -ne $identity.PSObject.Properties['attributes'] -and
            $null -ne $identity.attributes) {
            $bandAttrs = $identity.attributes
            foreach ($attrName in @('jobLevel', 'band')) {
                if ($null -ne $bandAttrs.PSObject.Properties[$attrName] -and
                    -not [string]::IsNullOrWhiteSpace($bandAttrs.$attrName)) {
                    $jobLevel = [string]$bandAttrs.$attrName
                    break
                }
            }
        }

        $resolved = @{
            IdentityId          = $IdentityId
            DisplayName         = $displayName
            ManagerId           = $managerId
            ManagerName         = $managerName
            IsActive            = $isActive
            Found               = $true
            CloudLifecycleState = $cloudLifecycleState
            Email               = $email
            JobLevel            = $jobLevel
        }

        $script:IdentityCache[$IdentityId] = $resolved
        return $resolved
    }
    catch {
        Write-SPLog `
            -Message "Get-SPDeltaIdentityDetail failed for '$IdentityId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaIdentityDetail' `
            -CorrelationID $CorrelationID
        $script:IdentityCache[$IdentityId] = $emptyResult
        return $emptyResult
    }
}

#endregion

#region Public Functions

function Select-SPPrivilegedGrantEvents {
    <#
    .SYNOPSIS
        Filters grant events to only those where the granted entitlement is privileged.
    .DESCRIPTION
        For each unique (SourceId, ItemValue) pair in the grant event list, queries ISC
        GET /v3/entitlements?filters=value eq "ITEM_VALUE" and source.id eq "SOURCE_ID"
        and checks whether the returned entitlement has privileged:true in ISC.

        If ISC returns no matching entitlement (entitlement not yet aggregated or not
        managed by ISC), falls back to pattern matching against PrivilegedPatterns.
        Patterns are matched case-insensitively against the EntitlementName field.

        Results are cached in the module-scope EntitlementPrivilegedCache to avoid
        redundant API calls for the same entitlement within a session.

        ISC scope required: idn:entitlement:read or sp:scopes:all

    .PARAMETER GrantEvents
        Array of grant event objects as returned by Get-SPDeltaGrantEvents.
    .PARAMETER PrivilegedPatterns
        Optional regex patterns matched case-insensitively against EntitlementName when
        ISC has no record for the entitlement (unmanaged groups, not yet aggregated).
        Typically sourced from Audit.RiskIndicators.PrivilegedPatterns in settings.json.
        Example: @('Admin', 'Root', 'DBA', 'Domain Admins')
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [PSCustomObject[]] Filtered array containing only privileged grant events.
        Returns an empty array when no privileged events are found.
    .EXAMPLE
        $events    = (Get-SPDeltaGrantEvents -SourceIds @('src-abc') -HoursBack 24).Data
        $patterns  = @('Admin', 'Root', 'Domain Admins')
        $privEvts  = Select-SPPrivilegedGrantEvents -GrantEvents $events -PrivilegedPatterns $patterns
        "$($privEvts.Count) privileged grant events found"
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$GrantEvents,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$PrivilegedPatterns = @(),

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    if ($GrantEvents.Count -eq 0) { return @() }

    # Collect unique (SourceId, ItemValue) pairs to minimise API calls
    $uniquePairs = $GrantEvents |
        Select-Object SourceId, ItemValue -Unique |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.SourceId) -and
                       -not [string]::IsNullOrWhiteSpace($_.ItemValue) }

    $checkedViaISC  = 0
    $privilegedISC  = 0
    $privilegedPatt = 0
    $notPrivileged  = 0

    foreach ($pair in @($uniquePairs)) {
        $cacheKey = "$($pair.SourceId)::$($pair.ItemValue)"
        if ($script:EntitlementPrivilegedCache.ContainsKey($cacheKey)) { continue }

        $isPrivileged = $false
        $foundInISC   = $false

        try {
            # Escape embedded double-quotes for Lucene filter syntax
            $escapedValue  = $pair.ItemValue -replace '"', '\"'
            $escapedSource = $pair.SourceId  -replace '"', '\"'
            $filterStr     = "value eq `"$escapedValue`" and source.id eq `"$escapedSource`""

            $apiResult = Invoke-SPApiRequest -Method GET -Endpoint '/entitlements' `
                -QueryParams @{ filters = $filterStr; limit = 1 } `
                -CorrelationID $CorrelationID

            $checkedViaISC++

            if ($apiResult.Success) {
                $items = @($apiResult.Data)
                if ($items.Count -gt 0 -and $null -ne $items[0]) {
                    $foundInISC = $true
                    $privProp = $items[0].PSObject.Properties['privileged']
                    if ($null -ne $privProp -and $privProp.Value -eq $true) {
                        $isPrivileged = $true
                        $privilegedISC++
                    }
                }
            }
        }
        catch {
            Write-SPLog -Message "Entitlement lookup failed for '$($pair.ItemValue)' on source '$($pair.SourceId)': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Select-SPPrivilegedGrantEvents' `
                -CorrelationID $CorrelationID
        }

        # Pattern fallback: when ISC has no record (not aggregated / not managed),
        # fall back to name-based pattern match so newly provisioned groups that
        # haven't been tagged in ISC yet still get caught.
        if (-not $foundInISC -and $PrivilegedPatterns.Count -gt 0) {
            $nameToCheck = if (-not [string]::IsNullOrWhiteSpace($pair.ItemValue)) { $pair.ItemValue } else { '' }
            foreach ($pattern in $PrivilegedPatterns) {
                if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
                if ($nameToCheck -imatch $pattern) {
                    $isPrivileged = $true
                    $privilegedPatt++
                    break
                }
            }
        }

        if (-not $isPrivileged) { $notPrivileged++ }
        $script:EntitlementPrivilegedCache[$cacheKey] = $isPrivileged
    }

    Write-SPLog -Message "Privileged filter: UniqueEntitlements=$($uniquePairs.Count) CheckedViaISC=$checkedViaISC PrivilegedByISC=$privilegedISC PrivilegedByPattern=$privilegedPatt NotPrivileged=$notPrivileged" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Select-SPPrivilegedGrantEvents' `
        -CorrelationID $CorrelationID

    # Return only the grant events whose (SourceId, ItemValue) pair was determined privileged
    $filtered = $GrantEvents | Where-Object {
        $k = "$($_.SourceId)::$($_.ItemValue)"
        $script:EntitlementPrivilegedCache.ContainsKey($k) -and
        $script:EntitlementPrivilegedCache[$k] -eq $true
    }

    return @($filtered)
}

function Get-SPDeltaGrantEvents {
    <#
    .SYNOPSIS
        Retrieves AD group grant events within a time window from ISC account activities.
    .DESCRIPTION
        Queries GET /v3/account-activities with a server-side type filter of GRANT_ACCESS
        and auto-paginates. Client-side filtering is then applied for:
          - Date window: activities created within the last HoursBack hours
          - Source ID:   provisioning items belonging to the specified AD source IDs
          - Operation:   only items with operation ADD

        IMPORTANT - Scope requirement:
          This endpoint has no granular ISC scope. It requires sp:scopes:all or a browser
          token. Use -Token on the CLI script or a full-scope PAT in settings.json.

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to monitor for AD group add operations.
        If empty, no source filter is applied (all sources are included).
    .PARAMETER HoursBack
        How many hours to look back for grant events. Default: 24.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @([GrantEvent objects])
            Error   = $string
        }
        Each GrantEvent has: IdentityId, SourceId, ActivityId, ActivityCreated,
                             ItemType, ItemValue, ItemName
    .EXAMPLE
        $result = Get-SPDeltaGrantEvents -SourceIds @('src-abc123') -HoursBack 24
        $result.Data | ForEach-Object { $_.IdentityId }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SourceIds = @(),

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceFilter = if ($SourceIds.Count -gt 0) { $SourceIds -join ',' } else { '(all)' }
    Write-SPLog -Message "Getting delta grant events: SourceIds='$sourceFilter', HoursBack=$HoursBack" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaGrantEvents' `
        -CorrelationID $CorrelationID

    try {
        $allActivities = [System.Collections.Generic.List[object]]::new()
        $pageSize      = 250
        $offset        = 0
        $pageNum       = 0

        # M2: pagination ceiling
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
                $errMsg = "Pagination ceiling reached: $maxPages pages fetched " +
                          "(accumulated $($allActivities.Count) activities). " +
                          "Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
                    -Action 'Get-SPDeltaGrantEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'filters' = 'type eq "GRANT_ACCESS"'
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/account-activities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPDeltaGrantEvents failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
                    -Action 'Get-SPDeltaGrantEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and
                $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($activity in $page) { $allActivities.Add($activity) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) activities (running total: $($allActivities.Count))" `
                -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaGrantEvents' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allActivities.Count) GRANT_ACCESS activities before date/source filtering" `
            -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaGrantEvents' `
            -CorrelationID $CorrelationID

        # Client-side: date filter and source / operation filter
        $cutoff    = (Get-Date).ToUniversalTime().AddHours(-$HoursBack)
        $sourceSet = if ($SourceIds.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new($SourceIds)
        } else {
            $null
        }
        $grantEvents = [System.Collections.Generic.List[object]]::new()

        foreach ($activity in $allActivities) {

            # Date filter (client-side; ISC campaign list does not support created filter)
            $createdRaw  = $activity.created
            $createdDate = $null
            if ($null -ne $createdRaw) {
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsed)) {
                        $createdDate = $parsed
                    }
                }
            }
            if ($null -ne $createdDate -and $createdDate -lt $cutoff) { continue }

            # Extract identity ID from requestedFor (array or single object)
            $identityId = ''
            if ($null -ne $activity.PSObject.Properties['requestedFor'] -and
                $null -ne $activity.requestedFor) {
                $rf = $activity.requestedFor
                if ($rf -is [System.Collections.IEnumerable] -and $rf -isnot [string]) {
                    $rfArr = @($rf)
                    if ($rfArr.Count -gt 0 -and $null -ne $rfArr[0] -and
                        $null -ne $rfArr[0].PSObject.Properties['id']) {
                        $identityId = [string]$rfArr[0].id
                    }
                }
                elseif ($null -ne $rf.PSObject.Properties['id']) {
                    $identityId = [string]$rf.id
                }
            }
            if ([string]::IsNullOrWhiteSpace($identityId)) { continue }

            # Examine provisioning items
            $activityItems = $null
            if ($null -ne $activity.PSObject.Properties['items'] -and
                $null -ne $activity.items) {
                $activityItems = @($activity.items)
            }
            if ($null -eq $activityItems -or $activityItems.Count -eq 0) { continue }

            foreach ($item in $activityItems) {
                if ($null -eq $item) { continue }

                # Operation must be ADD
                $operation = ''
                if ($null -ne $item.PSObject.Properties['operation'] -and $null -ne $item.operation) {
                    $operation = [string]$item.operation
                }
                if ($operation -ne 'ADD') { continue }

                # Extract source ID (tries sourceId, source_id, then source.id)
                $itemSourceId = ''
                foreach ($prop in @('sourceId', 'source_id')) {
                    if ($null -ne $item.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace($item.$prop)) {
                        $itemSourceId = [string]$item.$prop
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($itemSourceId) -and
                    $null -ne $item.PSObject.Properties['source'] -and
                    $null -ne $item.source -and
                    $null -ne $item.source.PSObject.Properties['id']) {
                    $itemSourceId = [string]$item.source.id
                }

                # Source filter
                if ($null -ne $sourceSet -and -not $sourceSet.Contains($itemSourceId)) {
                    continue
                }

                $itemType  = if ($null -ne $item.PSObject.Properties['type']  -and $null -ne $item.type)  { [string]$item.type  } else { '' }
                $itemValue = if ($null -ne $item.PSObject.Properties['value'] -and $null -ne $item.value) { [string]$item.value } else { '' }
                $itemName  = if ($null -ne $item.PSObject.Properties['name']  -and $null -ne $item.name)  { [string]$item.name  } else { $itemValue }

                # Extract entitlement / access-profile ID if the item carries it.
                # ISC account-activity provisioning items may carry entitlementId
                # or accessProfileId depending on the ISC provisioning path.
                # These fields are captured for audit traceability and are
                # available to callers for post-hoc reporting. They are NOT
                # passed to the ISC /v3/campaigns API because the SEARCH
                # campaign filter only accepts identity-level Lucene queries --
                # there is no entitlement-level filter parameter in the campaign
                # creation body. See design note in SP.DeltaCertRunner.psm1.
                $entitlementId   = ''
                $accessProfileId = ''
                foreach ($prop in @('entitlementId', 'entitlement_id')) {
                    if ($null -ne $item.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace($item.$prop)) {
                        $entitlementId = [string]$item.$prop
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($entitlementId) -and
                    $null -ne $item.PSObject.Properties['entitlement'] -and
                    $null -ne $item.entitlement -and
                    $null -ne $item.entitlement.PSObject.Properties['id'] -and
                    -not [string]::IsNullOrWhiteSpace($item.entitlement.id)) {
                    $entitlementId = [string]$item.entitlement.id
                }
                foreach ($prop in @('accessProfileId', 'access_profile_id')) {
                    if ($null -ne $item.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace($item.$prop)) {
                        $accessProfileId = [string]$item.$prop
                        break
                    }
                }

                $grantEvents.Add([PSCustomObject]@{
                    IdentityId      = $identityId
                    SourceId        = $itemSourceId
                    ActivityId      = if ($null -ne $activity.PSObject.Properties['id']) { [string]$activity.id } else { '' }
                    ActivityCreated = if ($null -ne $createdDate) { $createdDate.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                    ItemType        = $itemType
                    ItemValue       = $itemValue
                    ItemName        = $itemName
                    EntitlementId   = $entitlementId
                    EntitlementName = $itemName   # best available name; ItemName already falls back to ItemValue
                    AccessProfileId = $accessProfileId
                })
            }
        }

        $uniqueCount = ($grantEvents | Select-Object -ExpandProperty IdentityId -Unique).Count
        Write-SPLog -Message "Found $($grantEvents.Count) ADD event(s) across $uniqueCount unique identit(ies) in the last $HoursBack hours" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaGrantEvents' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $grantEvents.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaGrantEvents failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Get-SPDeltaGrantEvents' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDeltaAffectedIdentities {
    <#
    .SYNOPSIS
        Resolves and filters identities from grant events to active identities with managers.
    .DESCRIPTION
        Deduplicates identity IDs from GrantEvents, then calls GET /v3/search/identities/{id}
        for each (results cached per session). Filters out:
          - Identities not found in ISC
          - Identities whose cloudLifecycleState is terminated, inactive, leaver, or prehire
          - Identities with no manager assignment (cannot route a campaign without a reviewer)

        If FallbackManagerId is provided, manager-less identities are included in the output
        with that identity ID set as their ManagerId instead of being skipped.
    .PARAMETER GrantEvents
        Array of GrantEvent objects as returned by Get-SPDeltaGrantEvents.
    .PARAMETER FallbackManagerId
        Optional identity ID of the fallback reviewer for identities who have no manager in ISC.
        If omitted, manager-less identities are skipped with a WARN log entry.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @([IdentityDetail objects])
            Error   = $string
        }
        Each IdentityDetail has: IdentityId, DisplayName, ManagerId, ManagerName, IsActive
    .EXAMPLE
        $evts   = (Get-SPDeltaGrantEvents -SourceIds @('src-abc') -HoursBack 24).Data
        $result = Get-SPDeltaAffectedIdentities -GrantEvents $evts
        $result.Data | Format-Table IdentityId, ManagerId, DisplayName
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$GrantEvents,

        [Parameter()]
        [string]$FallbackManagerId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Resolving affected identities from $($GrantEvents.Count) grant event(s)" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
        -CorrelationID $CorrelationID

    try {
        # Load exclusion config (fail-safe to hardcoded defaults)
        $excludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
        $excludeDisplayNamePatterns = @()
        $excludeIdentityIds         = @()
        try {
            $cfg = Get-SPConfig
            if ($null -ne $cfg -and $null -ne $cfg.PSObject.Properties['DeltaCert'] -and
                $null -ne $cfg.DeltaCert) {
                $dc = $cfg.DeltaCert
                if ($dc.PSObject.Properties.Name -contains 'ExcludeLifecycleStates' -and
                    $null -ne $dc.ExcludeLifecycleStates) {
                    $excludeLifecycleStates = @($dc.ExcludeLifecycleStates)
                }
                if ($dc.PSObject.Properties.Name -contains 'ExcludeDisplayNamePatterns' -and
                    $null -ne $dc.ExcludeDisplayNamePatterns) {
                    $excludeDisplayNamePatterns = @($dc.ExcludeDisplayNamePatterns)
                }
                if ($dc.PSObject.Properties.Name -contains 'ExcludeIdentityIds' -and
                    $null -ne $dc.ExcludeIdentityIds) {
                    $excludeIdentityIds = @($dc.ExcludeIdentityIds)
                }
            }
        } catch { }
        $excludeIdSet = if ($excludeIdentityIds.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]$excludeIdentityIds)
        } else { $null }

        $uniqueIds = @(
            $GrantEvents |
                Select-Object -ExpandProperty IdentityId |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        if ($uniqueIds.Count -eq 0) {
            Write-SPLog -Message "No identity IDs found in grant events" `
                -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $affectedIdentities    = [System.Collections.Generic.List[object]]::new()
        $skippedNotFound       = 0
        $skippedInactive       = 0
        $skippedNoManager      = 0
        $skippedExcludedId     = 0
        $skippedDisplayName    = 0

        foreach ($identityId in $uniqueIds) {
            # Explicit identity ID exclusion (before API call)
            if ($null -ne $excludeIdSet -and $excludeIdSet.Contains($identityId)) {
                $skippedExcludedId++
                Write-SPLog -Message "Identity '$identityId' is in ExcludeIdentityIds -- skipped" `
                    -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                    -CorrelationID $CorrelationID
                continue
            }

            $detail = Get-SPDeltaIdentityDetail -IdentityId $identityId -CorrelationID $CorrelationID

            if (-not $detail.Found) {
                $skippedNotFound++
                Write-SPLog -Message "Identity '$identityId' not found in ISC -- skipped" `
                    -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                    -CorrelationID $CorrelationID
                continue
            }

            # Configurable lifecycle state exclusion
            $lcs = $detail.CloudLifecycleState
            if (-not [string]::IsNullOrWhiteSpace($lcs) -and
                $excludeLifecycleStates.Count -gt 0 -and $lcs -in $excludeLifecycleStates) {
                $skippedInactive++
                Write-SPLog -Message "Identity '$identityId' ($($detail.DisplayName)) has lifecycle state '$lcs' -- skipped" `
                    -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                    -CorrelationID $CorrelationID
                continue
            }

            # Display name pattern exclusion
            if ($excludeDisplayNamePatterns.Count -gt 0 -and
                -not [string]::IsNullOrWhiteSpace($detail.DisplayName)) {
                $matchedPattern = $null
                foreach ($pattern in $excludeDisplayNamePatterns) {
                    if (-not [string]::IsNullOrWhiteSpace($pattern) -and
                        $detail.DisplayName -match $pattern) {
                        $matchedPattern = $pattern
                        break
                    }
                }
                if ($null -ne $matchedPattern) {
                    $skippedDisplayName++
                    Write-SPLog -Message "Identity '$identityId' ($($detail.DisplayName)) matches exclusion pattern '$matchedPattern' -- skipped" `
                        -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                        -CorrelationID $CorrelationID
                    continue
                }
            }

            if ([string]::IsNullOrWhiteSpace($detail.ManagerId)) {
                if (-not [string]::IsNullOrWhiteSpace($FallbackManagerId)) {
                    Write-SPLog -Message "Identity '$identityId' ($($detail.DisplayName)) has no manager -- using fallback '$FallbackManagerId'" `
                        -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                        -CorrelationID $CorrelationID
                    $affectedIdentities.Add([PSCustomObject]@{
                        IdentityId  = $detail.IdentityId
                        DisplayName = $detail.DisplayName
                        ManagerId   = $FallbackManagerId
                        ManagerName = '(fallback)'
                        IsActive    = $true
                    })
                }
                else {
                    $skippedNoManager++
                    Write-SPLog -Message "Identity '$identityId' ($($detail.DisplayName)) has no manager and no fallback configured -- skipped" `
                        -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
                        -CorrelationID $CorrelationID
                }
                continue
            }

            $affectedIdentities.Add([PSCustomObject]@{
                IdentityId  = $detail.IdentityId
                DisplayName = $detail.DisplayName
                ManagerId   = $detail.ManagerId
                ManagerName = $detail.ManagerName
                IsActive    = $true
            })
        }

        Write-SPLog -Message "Affected identity resolution complete: $($affectedIdentities.Count) included, $skippedNotFound not-found, $skippedInactive inactive, $skippedNoManager no-manager, $skippedExcludedId excluded-id, $skippedDisplayName excluded-displayname" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaAffectedIdentities' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $affectedIdentities.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaAffectedIdentities failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Get-SPDeltaAffectedIdentities' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Group-SPDeltaByManager {
    <#
    .SYNOPSIS
        Groups affected identity details by their manager ID.
    .DESCRIPTION
        Takes the output of Get-SPDeltaAffectedIdentities and returns a hashtable
        keyed by manager identity ID. Each value is an array of identity objects
        whose manager is that identity. One campaign will be created per group.
    .PARAMETER AffectedIdentities
        Array of IdentityDetail objects as returned by Get-SPDeltaAffectedIdentities.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ managerId = @([IdentityDetail objects]) }
            Error   = $string
        }
    .EXAMPLE
        $groups = (Group-SPDeltaByManager -AffectedIdentities $identities).Data
        foreach ($managerId in $groups.Keys) {
            "$managerId has $($groups[$managerId].Count) affected report(s)"
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$AffectedIdentities,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Grouping $($AffectedIdentities.Count) identit(ies) by manager" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Group-SPDeltaByManager' `
        -CorrelationID $CorrelationID

    try {
        $lists = @{}

        foreach ($identity in $AffectedIdentities) {
            $managerId = $identity.ManagerId
            if ([string]::IsNullOrWhiteSpace($managerId)) { continue }

            if (-not $lists.ContainsKey($managerId)) {
                $lists[$managerId] = [System.Collections.Generic.List[object]]::new()
            }
            $lists[$managerId].Add($identity)
        }

        # Convert lists to plain arrays for clean output
        $result = @{}
        foreach ($key in $lists.Keys) {
            $result[$key] = $lists[$key].ToArray()
        }

        Write-SPLog -Message "Grouped into $($result.Count) manager group(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Group-SPDeltaByManager' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $result; Error = $null }
    }
    catch {
        $errMsg = "Group-SPDeltaByManager failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Group-SPDeltaByManager' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDeltaCertStaleCertifications {
    <#
    .SYNOPSIS
        Finds delta cert certifications that meet escalation criteria or are in-scope for audit.
    .DESCRIPTION
        Searches for delta cert campaigns matching a name prefix, retrieves all certifications
        for each campaign, and applies configurable filters.

        STANDARD MODE (default, -DaysBack 0):
          Searches ACTIVE campaigns only. Includes certifications where:
            - signed is null (not completed by the reviewer)
            - StaleHours condition: cert has been open >= StaleHours hours
            - OR EscalateBeforeDeadlineHours condition: campaign deadline is within
              EscalateBeforeDeadlineHours hours (union -- either condition triggers)

        ORG CHART AUDIT MODE (-DaysBack N or -AllCertifications):
          Searches all campaigns (ACTIVE + COMPLETED + STAGED) within the last N days.
          Skips the signed/stale filters -- returns ALL certifications so callers can
          validate the manager chain for every reviewer that ever appeared in the window.
          Designed for -WhatIf dry-runs to verify ISC org chain data before enabling
          live escalation.

    .PARAMETER CampaignNamePrefix
        Prefix used to find delta cert campaigns. Default: 'AD Delta Cert'.
        Uses an ISC starts-with filter (sw=) for indexed performance.
    .PARAMETER StaleHours
        Hours with no reviewer action before a certification is stale. Default: 24.
        Ignored when -AllCertifications is set.
    .PARAMETER EscalateBeforeDeadlineHours
        Escalate if the campaign deadline is within this many hours, regardless of
        how long the cert has been open. 0 = disabled. Union with StaleHours:
        if either condition is met the certification is returned.
        Ignored when -AllCertifications is set.
    .PARAMETER DaysBack
        When > 0, searches all campaign statuses (ACTIVE, COMPLETED, STAGED, etc.)
        and restricts to campaigns created in the last N days. Automatically activates
        AllCertifications mode (signed/stale filters are skipped).
        When 0 (default), searches ACTIVE campaigns only with no date limit.
    .PARAMETER AllCertifications
        When set, skips the signed and stale-hours filters -- returns ALL certifications
        regardless of status. Implies DaysBack audit behaviour. Useful for org chart
        validation in -WhatIf runs.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @([PSCustomObject]:
                        CertificationId, CampaignId, CampaignName, CampaignStatus,
                        ReviewerIdentityId, ReviewerName, HoursOpen,
                        HoursUntilDeadline, EscalationReason,
                        ReviewerClassification, CertSigned)
            Error   = $string
        }
    .EXAMPLE
        $r = Get-SPDeltaCertStaleCertifications -StaleHours 24
        $r.Data | Format-Table CertificationId, ReviewerName, HoursOpen
    .EXAMPLE
        # Org chart audit: all certs from last 30 days
        $r = Get-SPDeltaCertStaleCertifications -DaysBack 30
        $r.Data | Format-Table CampaignName, ReviewerName, CertSigned
    .EXAMPLE
        # Deadline-proximity mode: escalate if campaign closes within 8 hours
        $r = Get-SPDeltaCertStaleCertifications -StaleHours 0 -EscalateBeforeDeadlineHours 8
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$StaleHours = 24,

        [Parameter()]
        [int]$EscalateBeforeDeadlineHours = 0,

        [Parameter()]
        [int]$DaysBack = 0,

        [Parameter()]
        [switch]$AllCertifications,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # DaysBack > 0 automatically activates AllCertifications (audit) mode
    $auditMode = $AllCertifications.IsPresent -or ($DaysBack -gt 0)

    Write-SPLog -Message "Get-SPDeltaCertStaleCertifications: Prefix='$CampaignNamePrefix' StaleHours=$StaleHours EscalateBeforeDeadlineHours=$EscalateBeforeDeadlineHours DaysBack=$DaysBack AuditMode=$auditMode" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Find campaigns
        # Standard mode: ACTIVE only, no date limit (sw= prefix filter, indexed).
        # Audit mode:    All statuses, DaysBack date window (client-side date filter).
        if ($auditMode) {
            $auditSearchParams = @{
                CampaignNameStartsWith = $CampaignNamePrefix
                CorrelationID          = $CorrelationID
            }
            if ($DaysBack -gt 0) {
                $auditSearchParams['DaysBack'] = $DaysBack
            }
            else {
                # AllCertifications without DaysBack: no date limit (DaysBack=0 disables it)
                $auditSearchParams['DaysBack'] = 0
            }
            $searchResult = Get-SPAuditCampaigns @auditSearchParams
        }
        else {
            $searchResult = Get-SPAuditCampaigns `
                -CampaignNameStartsWith $CampaignNamePrefix `
                -Status @('ACTIVE') `
                -DaysBack 0 `
                -CorrelationID $CorrelationID
        }

        if (-not $searchResult.Success) {
            $errMsg = "Campaign search failed: $($searchResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
                -Action 'Get-SPDeltaCertStaleCertifications' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $foundCampaigns = @($searchResult.Data)

        if ($foundCampaigns.Count -eq 0) {
            $noResultMsg = if ($auditMode) {
                "No campaigns found matching '$CampaignNamePrefix' in last $DaysBack days"
            } else {
                "No active campaigns found matching '$CampaignNamePrefix'"
            }
            Write-SPLog -Message $noResultMsg `
                -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $modeLabel = if ($auditMode) { 'campaign(s) (audit mode)' } else { 'active campaign(s)' }
        Write-SPLog -Message "Found $($foundCampaigns.Count) $modeLabel -- retrieving certifications" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
            -CorrelationID $CorrelationID

        $nowUtc      = (Get-Date).ToUniversalTime()
        $staleCutoff = $nowUtc.AddHours(-$StaleHours)
        $resultCerts = [System.Collections.Generic.List[object]]::new()

        # Step 2: For each campaign, get certifications and apply filters
        foreach ($campaign in $foundCampaigns) {
            $campaignId     = [string]$campaign.id
            $campaignName   = [string]$campaign.name
            $campaignStatus = ''
            if ($campaign.PSObject.Properties.Name -contains 'status' -and $null -ne $campaign.status) {
                $campaignStatus = [string]$campaign.status
            }

            # Extract campaign deadline for EscalateBeforeDeadlineHours mode
            $campaignDeadline      = $null
            $hoursUntilDeadline    = [double]::MaxValue
            $deadlineStr = $null
            foreach ($prop in @('deadline', 'Deadline', 'endDate', 'end')) {
                if ($campaign.PSObject.Properties.Name -contains $prop -and
                    $null -ne $campaign.$prop -and
                    -not [string]::IsNullOrWhiteSpace([string]$campaign.$prop)) {
                    $deadlineStr = [string]$campaign.$prop
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($deadlineStr)) {
                try {
                    if ($deadlineStr -is [datetime]) {
                        $campaignDeadline = ([datetime]$deadlineStr).ToUniversalTime()
                    }
                    else {
                        $campaignDeadline = [datetime]::Parse($deadlineStr).ToUniversalTime()
                    }
                    $hoursUntilDeadline = [math]::Round(($campaignDeadline - $nowUtc).TotalHours, 1)
                }
                catch { }
            }

            $certResult = Get-SPAuditCertifications -CampaignId $campaignId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Failed to get certifications for campaign '$campaignName' ($campaignId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)

            foreach ($cert in $certs) {
                # Extract signed status
                $signedValue = $null
                if ($cert.PSObject.Properties.Name -contains 'signed') {
                    $signedValue = $cert.signed
                }
                $isSigned = ($null -ne $signedValue -and -not [string]::IsNullOrWhiteSpace([string]$signedValue))

                # In standard mode: skip signed certifications
                if (-not $auditMode -and $isSigned) { continue }

                # Parse created date
                $certCreatedStr = $null
                if ($cert.PSObject.Properties.Name -contains 'created') {
                    $certCreatedStr = $cert.created
                }
                if ([string]::IsNullOrWhiteSpace($certCreatedStr)) { continue }

                $certCreated = $null
                try {
                    if ($certCreatedStr -is [datetime]) {
                        $certCreated = ([datetime]$certCreatedStr).ToUniversalTime()
                    }
                    else {
                        $certCreated = [datetime]::Parse([string]$certCreatedStr).ToUniversalTime()
                    }
                }
                catch {
                    Write-SPLog -Message "Failed to parse created date for certification '$($cert.id)': $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $hoursOpen = [math]::Round(($nowUtc - $certCreated).TotalHours, 1)

                # Determine if this cert meets escalation criteria (standard mode only)
                $escalationReason = ''
                if (-not $auditMode) {
                    $meetsStaleHours   = ($StaleHours -gt 0 -and $certCreated -lt $staleCutoff)
                    $meetsDeadline     = ($EscalateBeforeDeadlineHours -gt 0 -and
                                         $hoursUntilDeadline -ne [double]::MaxValue -and
                                         $hoursUntilDeadline -le $EscalateBeforeDeadlineHours)

                    if ($meetsStaleHours -and $meetsDeadline) {
                        $escalationReason = 'Both'
                    }
                    elseif ($meetsStaleHours) {
                        $escalationReason = 'Stale'
                    }
                    elseif ($meetsDeadline) {
                        $escalationReason = 'Deadline'
                    }
                    else {
                        continue  # neither condition met -- skip
                    }
                }
                else {
                    $escalationReason = 'AuditAll'
                }

                $hoursOpen = [math]::Round(($nowUtc - $certCreated).TotalHours, 1)

                # Extract reviewer info from EffectiveReviewer (added by Get-SPAuditCertifications)
                $reviewerId   = ''
                $reviewerName = ''
                $reviewerClassification = ''

                if ($cert.PSObject.Properties.Name -contains 'EffectiveReviewer' -and $null -ne $cert.EffectiveReviewer) {
                    $reviewer = $cert.EffectiveReviewer
                    if ($null -ne $reviewer.PSObject.Properties['id'] -and
                        -not [string]::IsNullOrWhiteSpace($reviewer.id)) {
                        $reviewerId = [string]$reviewer.id
                    }
                    foreach ($prop in @('displayName', 'name')) {
                        if ($null -ne $reviewer.PSObject.Properties[$prop] -and
                            -not [string]::IsNullOrWhiteSpace($reviewer.$prop)) {
                            $reviewerName = [string]$reviewer.$prop
                            break
                        }
                    }
                }

                if ($cert.PSObject.Properties.Name -contains 'ReviewerClassification') {
                    $reviewerClassification = [string]$cert.ReviewerClassification
                }

                $resultCerts.Add([PSCustomObject]@{
                    CertificationId        = [string]$cert.id
                    CampaignId             = $campaignId
                    CampaignName           = $campaignName
                    CampaignStatus         = $campaignStatus
                    ReviewerIdentityId     = $reviewerId
                    ReviewerName           = $reviewerName
                    HoursOpen              = $hoursOpen
                    HoursUntilDeadline     = if ($hoursUntilDeadline -eq [double]::MaxValue) { $null } else { $hoursUntilDeadline }
                    EscalationReason       = $escalationReason
                    ReviewerClassification = $reviewerClassification
                    CertSigned             = $isSigned
                })
            }
        }

        $resultLabel = if ($auditMode) { 'certification(s) (audit)' } else { 'stale certification(s)' }
        Write-SPLog -Message "Found $($resultCerts.Count) $resultLabel across $($foundCampaigns.Count) campaign(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $resultCerts.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaCertStaleCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Get-SPDeltaCertStaleCertifications' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Build-SPOrgTree {
    <#
    .SYNOPSIS
        Walks ISC identity manager chains to build an org tree structure.
    .DESCRIPTION
        Takes an array of identity IDs (leaf-level reviewed identities) and walks
        each one up the manager chain using Get-SPDeltaIdentityDetail. Builds a
        complete org tree with nodes at each level (leaf=0, manager=1, director=2,
        VP=3, etc.).

        Uses the module-scope IdentityCache via Get-SPDeltaIdentityDetail so each
        unique identity is resolved via API only once per session.

        Safety: cycle detection via visited-ID tracking per chain, plus max depth
        enforcement to prevent runaway walks when ISC data has circular manager refs.
    .PARAMETER IdentityIds
        Array of SailPoint ISC identity IDs to use as tree leaves (level 0).
    .PARAMETER MaxDepth
        Maximum number of levels to walk above the leaf. Default 3 (leaf -> manager
        -> director -> VP). Walking stops when manager is null, max depth is reached,
        or a cycle is detected.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                Nodes       = @{ id = @{Identity; ManagerId; Level; Children} }
                TopLeaders  = @(ids)
                Directors   = @(ids)
                Managers    = @(ids)
                LeafCount   = [int]
                MaxDepthHit = $bool
            }
            Error   = $null
        }
    .EXAMPLE
        $tree = Build-SPOrgTree -IdentityIds @('id-alice','id-bob') -MaxDepth 3
        $tree.Data.TopLeaders  # VPs at the top of the tree
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$IdentityIds,

        [Parameter()]
        [int]$MaxDepth = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Build-SPOrgTree: Building org tree for $($IdentityIds.Count) leaf identit(ies), MaxDepth=$MaxDepth" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Build-SPOrgTree' `
        -CorrelationID $CorrelationID

    try {
        # Nodes hashtable keyed by identity ID
        $nodes       = @{}
        $maxDepthHit = $false

        # Step 1: Create leaf nodes (level 0) for each input identity
        $leafIds = [System.Collections.Generic.List[string]]::new()
        foreach ($leafId in $IdentityIds) {
            if ([string]::IsNullOrWhiteSpace($leafId)) { continue }
            if ($leafIds.Contains($leafId)) { continue }
            $leafIds.Add($leafId)

            $detail = Get-SPDeltaIdentityDetail -IdentityId $leafId -CorrelationID $CorrelationID

            $nodes[$leafId] = @{
                Identity  = @{
                    Id          = $leafId
                    Name        = $detail.DisplayName
                    ManagerId   = $detail.ManagerId
                    ManagerName = $detail.ManagerName
                    Found       = $detail.Found
                }
                ManagerId = $detail.ManagerId
                Level     = 0
                Children  = @()
            }
        }

        # Step 2: Walk each leaf up the manager chain
        foreach ($leafId in $leafIds) {
            $currentId = $leafId
            $visited   = [System.Collections.Generic.HashSet[string]]::new()
            [void]$visited.Add($currentId)
            $depth = 0

            while ($depth -lt $MaxDepth) {
                $currentNode = $nodes[$currentId]
                $managerId   = $currentNode.ManagerId

                # Stop if no manager
                if ([string]::IsNullOrWhiteSpace($managerId)) {
                    break
                }

                # Cycle detection
                if (-not $visited.Add($managerId)) {
                    Write-SPLog -Message "Build-SPOrgTree: Cycle detected -- identity '$currentId' has manager '$managerId' which is already in the chain. Stopping walk." `
                        -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Build-SPOrgTree' `
                        -CorrelationID $CorrelationID
                    break
                }

                $depth++

                # Create manager node if it does not exist yet
                if (-not $nodes.ContainsKey($managerId)) {
                    $mgrDetail = Get-SPDeltaIdentityDetail -IdentityId $managerId -CorrelationID $CorrelationID

                    $nodes[$managerId] = @{
                        Identity  = @{
                            Id          = $managerId
                            Name        = $mgrDetail.DisplayName
                            ManagerId   = $mgrDetail.ManagerId
                            ManagerName = $mgrDetail.ManagerName
                            Found       = $mgrDetail.Found
                        }
                        ManagerId = $mgrDetail.ManagerId
                        Level     = $depth
                        Children  = @()
                    }
                }
                else {
                    # Node exists -- update level to the higher value (farther from leaf)
                    if ($depth -gt $nodes[$managerId].Level) {
                        $nodes[$managerId].Level = $depth
                    }
                }

                # Add current node as child of the manager (if not already listed)
                $existingChildren = @($nodes[$managerId].Children)
                if ($currentId -notin $existingChildren) {
                    $nodes[$managerId].Children = $existingChildren + @($currentId)
                }

                # Check if we hit max depth on next iteration
                if ($depth -ge $MaxDepth) {
                    $maxDepthHit = $true
                    break
                }

                $currentId = $managerId
            }
        }

        # Step 3: Build level labels and per-level node groupings
        $levelLabels = @{
            0 = 'Individual Contributors'
            1 = 'Managers'
            2 = 'Directors'
            3 = 'Vice Presidents'
            4 = 'Senior Vice Presidents'
            5 = 'Executive Leadership'
        }

        # Group nodes by actual level and determine highest level
        $levelNodeLists = @{}
        $topLevel       = 0

        foreach ($nodeId in $nodes.Keys) {
            $level = $nodes[$nodeId].Level
            if ($level -eq 0) { continue }
            if ($level -gt $topLevel) { $topLevel = $level }
            if (-not $levelNodeLists.ContainsKey($level)) {
                $levelNodeLists[$level] = [System.Collections.Generic.List[string]]::new()
            }
            $levelNodeLists[$level].Add($nodeId)
        }

        # Ensure labels exist for all discovered levels
        foreach ($level in $levelNodeLists.Keys) {
            if (-not $levelLabels.ContainsKey($level)) {
                $levelLabels[$level] = 'Executive Leadership'
            }
        }

        # Convert LevelNodes lists to arrays
        $levelNodes = @{}
        foreach ($level in $levelNodeLists.Keys) {
            $levelNodes[[int]$level] = @($levelNodeLists[$level].ToArray())
        }

        # Backward-compatible quick-lookup lists
        $topLeaders = [System.Collections.Generic.List[string]]::new()
        $directors  = [System.Collections.Generic.List[string]]::new()
        $managers   = [System.Collections.Generic.List[string]]::new()

        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            $level = $node.Level

            $isTopOfChain = [string]::IsNullOrWhiteSpace($node.ManagerId) -or
                            (-not $nodes.ContainsKey($node.ManagerId) -and $level -gt 0)

            if ($level -ge 3 -or ($isTopOfChain -and $level -ge 2)) {
                if (-not $topLeaders.Contains($nodeId)) {
                    $topLeaders.Add($nodeId)
                }
            }
            elseif ($level -eq 2) {
                if (-not $directors.Contains($nodeId)) {
                    $directors.Add($nodeId)
                }
            }
            elseif ($level -eq 1) {
                if (-not $managers.Contains($nodeId)) {
                    $managers.Add($nodeId)
                }
            }
        }

        # If no nodes reached level 3+, promote the highest-level nodes to TopLeaders
        if ($topLeaders.Count -eq 0 -and $nodes.Count -gt 0) {
            $maxLevel = 0
            foreach ($nodeId in $nodes.Keys) {
                if ($nodes[$nodeId].Level -gt $maxLevel) { $maxLevel = $nodes[$nodeId].Level }
            }
            if ($maxLevel -gt 0) {
                foreach ($nodeId in $nodes.Keys) {
                    $node = $nodes[$nodeId]
                    $isTopOfChain = [string]::IsNullOrWhiteSpace($node.ManagerId) -or
                                    (-not $nodes.ContainsKey($node.ManagerId))
                    if ($node.Level -eq $maxLevel -and $isTopOfChain) {
                        $topLeaders.Add($nodeId)
                        [void]$directors.Remove($nodeId)
                    }
                }
            }
        }

        $treeData = @{
            Nodes       = $nodes
            TopLeaders  = @($topLeaders.ToArray())
            Directors   = @($directors.ToArray())
            Managers    = @($managers.ToArray())
            LevelLabels = $levelLabels
            LevelNodes  = $levelNodes
            TopLevel    = $topLevel
            LeafCount   = $leafIds.Count
            MaxDepthHit = $maxDepthHit
        }

        Write-SPLog -Message "Build-SPOrgTree: Complete -- $($nodes.Count) nodes, TopLevel=$topLevel, $($topLeaders.Count) top leader(s), $($directors.Count) director(s), $($managers.Count) manager(s), $($leafIds.Count) leaves, MaxDepthHit=$maxDepthHit" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Build-SPOrgTree' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $treeData; Error = $null }
    }
    catch {
        $errMsg = "Build-SPOrgTree failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Build-SPOrgTree' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Import-SPOrgChartSupplement {
    <#
    .SYNOPSIS
        Imports an org chart supplement CSV that fills gaps in ISC manager chain data.
    .DESCRIPTION
        Reads a CSV file with columns: identityEmail, managerEmail, level, title, band.
        Validates email format, required columns, and checks for circular references.
        The supplement provides FALLBACK data for report generation only -- it does
        not modify ISC identity records.

        Band convention: A=President/C-suite, B=VP/SVP, C=Director, D=Manager, E=IC
    .PARAMETER FilePath
        Path to the supplement CSV file.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ Entries; Conflicts; Gaps }
            Error   = $null | [string]
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Import-SPOrgChartSupplement: Importing supplement from '$FilePath'" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Import-SPOrgChartSupplement' `
        -CorrelationID $CorrelationID

    try {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            return @{ Success = $false; Data = $null; Error = "Supplement file not found: $FilePath" }
        }

        $csv = Import-Csv -LiteralPath $FilePath

        if ($csv.Count -eq 0) {
            return @{ Success = $false; Data = $null; Error = "Supplement CSV is empty" }
        }

        # Validate required columns
        $requiredCols = @('identityEmail', 'managerEmail', 'level', 'title', 'band')
        $actualCols = $csv[0].PSObject.Properties.Name
        $missingCols = @()
        foreach ($col in $requiredCols) {
            if ($col -notin $actualCols) {
                $missingCols += $col
            }
        }
        if ($missingCols.Count -gt 0) {
            return @{
                Success = $false
                Data    = $null
                Error   = "Supplement CSV missing required columns: $($missingCols -join ', ')"
            }
        }

        # Valid band values
        $validBands = @('A', 'B', 'C', 'D', 'E')

        # Email regex (simple but sufficient for validation)
        $emailRegex = '^[^@\s]+@[^@\s]+\.[^@\s]+$'

        # Build entries hashtable keyed by email (lowercase)
        $entries  = @{}
        $errors   = [System.Collections.Generic.List[string]]::new()
        $rowNum   = 1

        foreach ($row in $csv) {
            $rowNum++
            $email = ($row.identityEmail -as [string]).Trim().ToLower()
            $mgrEmail = ($row.managerEmail -as [string]).Trim().ToLower()
            $level = ($row.level -as [string]).Trim()
            $title = ($row.title -as [string]).Trim()
            $band  = ($row.band -as [string]).Trim().ToUpper()

            # Validate identity email
            if ([string]::IsNullOrWhiteSpace($email)) {
                $errors.Add("Row $rowNum`: identityEmail is empty")
                continue
            }
            if ($email -notmatch $emailRegex) {
                $errors.Add("Row $rowNum`: invalid identityEmail format '$email'")
                continue
            }

            # Validate manager email (optional for root/president)
            if (-not [string]::IsNullOrWhiteSpace($mgrEmail) -and $mgrEmail -notmatch $emailRegex) {
                $errors.Add("Row $rowNum`: invalid managerEmail format '$mgrEmail'")
                continue
            }

            # Validate band
            if (-not [string]::IsNullOrWhiteSpace($band) -and $band -notin $validBands) {
                $errors.Add("Row $rowNum`: invalid band '$band' (must be A-E)")
                continue
            }

            # Duplicate check
            if ($entries.ContainsKey($email)) {
                $errors.Add("Row $rowNum`: duplicate identityEmail '$email'")
                continue
            }

            $entries[$email] = @{
                IdentityEmail = $email
                ManagerEmail  = if ([string]::IsNullOrWhiteSpace($mgrEmail)) { $null } else { $mgrEmail }
                Level         = $level
                Title         = $title
                Band          = if ([string]::IsNullOrWhiteSpace($band)) { $null } else { $band }
            }
        }

        if ($errors.Count -gt 0) {
            $errSummary = "Supplement CSV has $($errors.Count) validation error(s): $($errors[0])"
            if ($errors.Count -gt 1) { $errSummary += " (and $($errors.Count - 1) more)" }
            Write-SPLog -Message "Import-SPOrgChartSupplement: $errSummary" `
                -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Import-SPOrgChartSupplement' `
                -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errSummary }
        }

        # Circular reference detection
        foreach ($email in $entries.Keys) {
            $visited = [System.Collections.Generic.HashSet[string]]::new()
            [void]$visited.Add($email)
            $current = $entries[$email].ManagerEmail

            while ($null -ne $current -and $entries.ContainsKey($current)) {
                if (-not $visited.Add($current)) {
                    return @{
                        Success = $false
                        Data    = $null
                        Error   = "Circular reference detected: '$email' chain revisits '$current'"
                    }
                }
                $current = $entries[$current].ManagerEmail
            }
        }

        # Identify gaps -- entries whose manager is not in supplement and not empty
        $gaps = [System.Collections.Generic.List[string]]::new()
        foreach ($email in $entries.Keys) {
            $mgrEmail = $entries[$email].ManagerEmail
            if ($null -ne $mgrEmail -and -not $entries.ContainsKey($mgrEmail)) {
                $gaps.Add($email)
            }
        }

        # Identify conflicts (logged for awareness -- will matter when merging with ISC)
        $conflicts = [System.Collections.Generic.List[string]]::new()

        Write-SPLog -Message "Import-SPOrgChartSupplement: Imported $($entries.Count) entries, $($gaps.Count) gap(s), $($conflicts.Count) conflict(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Import-SPOrgChartSupplement' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Entries   = $entries
                Conflicts = @($conflicts.ToArray())
                Gaps      = @($gaps.ToArray())
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Import-SPOrgChartSupplement failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Import-SPOrgChartSupplement' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Merge-SPOrgTreeWithSupplement {
    <#
    .SYNOPSIS
        Enriches an org tree with supplement data, filling gaps in ISC manager chains.
    .DESCRIPTION
        For each identity in the org tree: if ISC has no manager but the supplement does,
        use the supplement's manager. For identities in the supplement but not in the org
        tree, add them as synthetic nodes.

        ISC data takes PRECEDENCE when both exist -- the supplement is a fallback only.
        The supplement does not modify ISC identity records.
    .PARAMETER OrgTree
        Org tree Data hashtable from Build-SPOrgTree (the .Data property).
    .PARAMETER Supplement
        Supplement entries hashtable from Import-SPOrgChartSupplement (the .Data.Entries property).
    .PARAMETER IdentityEmailMap
        Optional hashtable mapping identity ID -> email address for matching org tree
        nodes to supplement entries. If not provided, matching is attempted via node
        Identity.Name lookups.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ Nodes; TopLeaders; Directors; Managers; ... ; SupplementApplied; SyntheticNodes }
            Error   = $null | [string]
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [hashtable]$Supplement,

        [Parameter()]
        [hashtable]$IdentityEmailMap,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Merge-SPOrgTreeWithSupplement: Merging $($Supplement.Count) supplement entries into org tree with $($OrgTree.Nodes.Count) nodes" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Merge-SPOrgTreeWithSupplement' `
        -CorrelationID $CorrelationID

    try {
        # Deep-copy the org tree to avoid mutating the original
        $mergedNodes = @{}
        foreach ($nodeId in $OrgTree.Nodes.Keys) {
            $src = $OrgTree.Nodes[$nodeId]
            $mergedNodes[$nodeId] = @{
                Identity  = @{
                    Id          = $src.Identity.Id
                    Name        = $src.Identity.Name
                    ManagerId   = $src.Identity.ManagerId
                    ManagerName = $src.Identity.ManagerName
                    Found       = $src.Identity.Found
                }
                ManagerId = $src.ManagerId
                Level     = $src.Level
                Children  = @() + $src.Children
            }
        }

        # Build reverse map: email -> node ID (for matching supplement to tree)
        $emailToNodeId = @{}
        if ($null -ne $IdentityEmailMap) {
            foreach ($id in $IdentityEmailMap.Keys) {
                $email = $IdentityEmailMap[$id].ToLower()
                $emailToNodeId[$email] = $id
            }
        }

        $supplementApplied = 0
        $syntheticNodes    = [System.Collections.Generic.List[string]]::new()
        $conflicts         = [System.Collections.Generic.List[hashtable]]::new()

        # Phase 1: For each supplement entry, check if the identity exists in the tree
        # If the identity exists but has no manager, fill from supplement
        foreach ($email in $Supplement.Keys) {
            $suppEntry = $Supplement[$email]
            $nodeId    = $null

            # Try email map first
            if ($emailToNodeId.ContainsKey($email)) {
                $nodeId = $emailToNodeId[$email]
            }

            if ($null -ne $nodeId -and $mergedNodes.ContainsKey($nodeId)) {
                $node = $mergedNodes[$nodeId]

                # ISC has manager -> ISC wins; log conflict if supplement disagrees
                if (-not [string]::IsNullOrWhiteSpace($node.ManagerId)) {
                    if ($null -ne $suppEntry.ManagerEmail) {
                        $conflicts.Add(@{
                            IdentityEmail = $email
                            NodeId        = $nodeId
                            ISCManagerId  = $node.ManagerId
                            SupplementMgr = $suppEntry.ManagerEmail
                            Resolution    = 'ISC wins'
                        })
                    }
                    continue
                }

                # ISC has NO manager -> supplement fills the gap
                $mgrNodeId = $null
                if ($null -ne $suppEntry.ManagerEmail -and $emailToNodeId.ContainsKey($suppEntry.ManagerEmail)) {
                    $mgrNodeId = $emailToNodeId[$suppEntry.ManagerEmail]
                }

                if ($null -ne $mgrNodeId -and $mergedNodes.ContainsKey($mgrNodeId)) {
                    $node.ManagerId = $mgrNodeId
                    $node.Identity.ManagerId = $mgrNodeId
                    $node.Identity.ManagerName = $mergedNodes[$mgrNodeId].Identity.Name

                    # Add as child of manager
                    $existingChildren = @($mergedNodes[$mgrNodeId].Children)
                    if ($nodeId -notin $existingChildren) {
                        $mergedNodes[$mgrNodeId].Children = $existingChildren + @($nodeId)
                    }
                    $supplementApplied++
                }
            }
            else {
                # Identity is in supplement but NOT in the org tree -> add as synthetic node
                $syntheticId = "supplement-$email"
                $mgrSyntheticId = $null

                if ($null -ne $suppEntry.ManagerEmail) {
                    # Check if manager is already in tree via email map
                    if ($emailToNodeId.ContainsKey($suppEntry.ManagerEmail)) {
                        $mgrSyntheticId = $emailToNodeId[$suppEntry.ManagerEmail]
                    }
                    elseif ($Supplement.ContainsKey($suppEntry.ManagerEmail)) {
                        $mgrSyntheticId = "supplement-$($suppEntry.ManagerEmail)"
                    }
                }

                # Determine level from band
                $synthLevel = switch ($suppEntry.Band) {
                    'A' { 4 }
                    'B' { 3 }
                    'C' { 2 }
                    'D' { 1 }
                    'E' { 0 }
                    default { 0 }
                }

                $mergedNodes[$syntheticId] = @{
                    Identity  = @{
                        Id          = $syntheticId
                        Name        = $suppEntry.Title
                        ManagerId   = $mgrSyntheticId
                        ManagerName = ''
                        Found       = $false
                    }
                    ManagerId = $mgrSyntheticId
                    Level     = $synthLevel
                    Children  = @()
                    Synthetic = $true
                    Email     = $email
                    Band      = $suppEntry.Band
                    Title     = $suppEntry.Title
                }

                $syntheticNodes.Add($syntheticId)
                $supplementApplied++
            }
        }

        # Phase 2: Wire up synthetic node parent-child relationships
        foreach ($synId in $syntheticNodes) {
            $synNode = $mergedNodes[$synId]
            $mgrId   = $synNode.ManagerId
            if ($null -ne $mgrId -and $mergedNodes.ContainsKey($mgrId)) {
                $existingChildren = @($mergedNodes[$mgrId].Children)
                if ($synId -notin $existingChildren) {
                    $mergedNodes[$mgrId].Children = $existingChildren + @($synId)
                }
                # Update manager name on synthetic node
                $synNode.Identity.ManagerName = $mergedNodes[$mgrId].Identity.Name
            }
        }

        # Phase 3: Rebuild classification lists
        $topLeaders = [System.Collections.Generic.List[string]]::new()
        $directors  = [System.Collections.Generic.List[string]]::new()
        $managers   = [System.Collections.Generic.List[string]]::new()

        foreach ($nodeId in $mergedNodes.Keys) {
            $node  = $mergedNodes[$nodeId]
            $level = $node.Level

            $isTopOfChain = [string]::IsNullOrWhiteSpace($node.ManagerId) -or
                            (-not $mergedNodes.ContainsKey($node.ManagerId) -and $level -gt 0)

            if ($level -ge 3 -or ($isTopOfChain -and $level -ge 2)) {
                if (-not $topLeaders.Contains($nodeId)) {
                    $topLeaders.Add($nodeId)
                }
            }
            elseif ($level -eq 2) {
                if (-not $directors.Contains($nodeId)) {
                    $directors.Add($nodeId)
                }
            }
            elseif ($level -eq 1) {
                if (-not $managers.Contains($nodeId)) {
                    $managers.Add($nodeId)
                }
            }
        }

        # Rebuild LevelNodes
        $levelNodes = @{}
        $topLevel   = 0
        foreach ($nodeId in $mergedNodes.Keys) {
            $level = $mergedNodes[$nodeId].Level
            if ($level -eq 0) { continue }
            if ($level -gt $topLevel) { $topLevel = $level }
            if (-not $levelNodes.ContainsKey($level)) {
                $levelNodes[$level] = [System.Collections.Generic.List[string]]::new()
            }
            $levelNodes[$level].Add($nodeId)
        }
        $levelNodesArrays = @{}
        foreach ($level in $levelNodes.Keys) {
            $levelNodesArrays[[int]$level] = @($levelNodes[$level].ToArray())
        }

        $mergedTree = @{
            Nodes             = $mergedNodes
            TopLeaders        = @($topLeaders.ToArray())
            Directors         = @($directors.ToArray())
            Managers          = @($managers.ToArray())
            LevelLabels       = $OrgTree.LevelLabels
            LevelNodes        = $levelNodesArrays
            TopLevel          = $topLevel
            LeafCount         = $OrgTree.LeafCount
            MaxDepthHit       = $OrgTree.MaxDepthHit
            SupplementApplied = $supplementApplied
            SyntheticNodes    = @($syntheticNodes.ToArray())
            Conflicts         = @($conflicts.ToArray())
        }

        Write-SPLog -Message "Merge-SPOrgTreeWithSupplement: Complete -- $supplementApplied supplement entries applied, $($syntheticNodes.Count) synthetic nodes, $($conflicts.Count) conflict(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Merge-SPOrgTreeWithSupplement' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $mergedTree; Error = $null }
    }
    catch {
        $errMsg = "Merge-SPOrgTreeWithSupplement failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Merge-SPOrgTreeWithSupplement' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Show-SPOrgTree {
    <#
    .SYNOPSIS
        Renders an org tree as ASCII art in the terminal.
    .DESCRIPTION
        Takes an org tree structure (from Build-SPOrgTree or Merge-SPOrgTreeWithSupplement)
        and renders it as a hierarchical ASCII tree. Uses PS 5.1-compatible box-drawing
        characters (+-- and | for branches).

        Supports child truncation (-MaxChildrenShown), band display (-ShowBands), and
        a summary footer with node counts per level.
    .PARAMETER OrgTree
        Org tree Data hashtable (the .Data property from Build-SPOrgTree or
        Merge-SPOrgTreeWithSupplement). Must contain a Nodes hashtable.
    .PARAMETER MaxChildrenShown
        Maximum children to display per node before truncating with an "(N more)"
        indicator. Default: 5.
    .PARAMETER ShowBands
        Display band classification (A-E) for each node. Band is resolved from
        supplement data first, then auto-detected from tree depth.
    .PARAMETER Full
        Show all children without truncation (overrides MaxChildrenShown).
    .OUTPUTS
        [string[]] Lines forming the ASCII tree, written to the output stream.
    .EXAMPLE
        $tree = Build-SPOrgTree -IdentityIds $ids -MaxDepth 4
        Show-SPOrgTree -OrgTree $tree.Data -ShowBands
    .EXAMPLE
        $merged = Merge-SPOrgTreeWithSupplement -OrgTree $tree.Data -Supplement $supp
        Show-SPOrgTree -OrgTree $merged.Data -ShowBands -MaxChildrenShown 3
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter()]
        [int]$MaxChildrenShown = 5,

        [Parameter()]
        [switch]$ShowBands,

        [Parameter()]
        [switch]$Full
    )

    $nodes = $OrgTree.Nodes
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        Write-Output '  (empty org tree)'
        return
    }

    # Band auto-detect from tree level (fallback when node has no explicit Band)
    $bandFromLevel = @{ 0 = 'E'; 1 = 'D'; 2 = 'C'; 3 = 'B' }

    # Output collector -- List so nested Render-Children can .Add() across scope
    $lines = [System.Collections.Generic.List[string]]::new()

    # Resolve band letter for a node
    function Get-NodeBand {
        param([hashtable]$Node)
        if ($Node.ContainsKey('Band') -and -not [string]::IsNullOrWhiteSpace($Node.Band)) {
            return $Node.Band
        }
        $lvl = $Node.Level
        if ($lvl -ge 4) { return 'A' }
        if ($bandFromLevel.ContainsKey($lvl)) { return $bandFromLevel[$lvl] }
        return 'E'
    }

    # Format a single node for display
    function Format-NodeDisplay {
        param([hashtable]$Node, [bool]$IncludeBand)
        $name = $Node.Identity.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $Node.Identity.Id }
        $display = $name
        if ($Node.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Node.Title)) {
            $display += " ($($Node.Title))"
        }
        if ($IncludeBand) {
            $band = Get-NodeBand -Node $Node
            $display += " [Band $band]"
        }
        return $display
    }

    # Recursively render a node's children as ASCII tree branches
    function Render-Children {
        param(
            [string]$NodeId,
            [string]$Continuation
        )

        $node     = $nodes[$NodeId]
        $children = @($node.Children | Where-Object { $nodes.ContainsKey($_) })
        if ($children.Count -eq 0) { return }

        # Sort: higher level first, then alphabetically by name
        $sorted = @(
            $children |
                Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
        )

        $showCount = if ($Full.IsPresent) {
            $sorted.Count
        } else {
            [Math]::Min($MaxChildrenShown, $sorted.Count)
        }
        $remaining = $sorted.Count - $showCount

        for ($i = 0; $i -lt $showCount; $i++) {
            $childId     = $sorted[$i]
            $isLastEntry = ($i -eq ($showCount - 1)) -and ($remaining -eq 0)

            $childDisplay = Format-NodeDisplay -Node $nodes[$childId] `
                -IncludeBand $ShowBands.IsPresent
            $lines.Add("$Continuation+-- $childDisplay")

            $childCont = if ($isLastEntry) {
                "$Continuation    "
            } else {
                "$Continuation|   "
            }

            Render-Children -NodeId $childId -Continuation $childCont
        }

        if ($remaining -gt 0) {
            $lines.Add("$Continuation+-- ... ($remaining more)")
        }
    }

    # --- Find root nodes (manager absent or not in the tree) ---
    $rootIds = [System.Collections.Generic.List[string]]::new()
    foreach ($nodeId in $nodes.Keys) {
        $node  = $nodes[$nodeId]
        $mgrId = $node.ManagerId
        if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) {
            $rootIds.Add($nodeId)
        }
    }

    # Sort roots: highest level first, then by name
    $sortedRoots = @(
        $rootIds | Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
    )

    # --- Render each root subtree ---
    foreach ($rootId in $sortedRoots) {
        $rootDisplay = Format-NodeDisplay -Node $nodes[$rootId] `
            -IncludeBand $ShowBands.IsPresent
        $lines.Add($rootDisplay)
        Render-Children -NodeId $rootId -Continuation ''
    }

    # --- Summary footer ---
    $lines.Add('')

    # Count nodes per level
    $levelCounts = @{}
    foreach ($nodeId in $nodes.Keys) {
        $lvl = $nodes[$nodeId].Level
        if (-not $levelCounts.ContainsKey($lvl)) { $levelCounts[$lvl] = 0 }
        $levelCounts[$lvl]++
    }

    # Count unmanaged (level-0 nodes that are also roots)
    $unmanagedCount = 0
    foreach ($rootId in $sortedRoots) {
        if ($nodes[$rootId].Level -eq 0) { $unmanagedCount++ }
    }

    # Level names for summary (singular form; append 's' for plural)
    $levelNames = @{
        0 = 'IC'
        1 = 'Manager'
        2 = 'Director'
        3 = 'VP'
        4 = 'SVP'
        5 = 'Executive'
    }

    $summaryParts = [System.Collections.Generic.List[string]]::new()
    $sortedLevels = @($levelCounts.Keys | Sort-Object { -[int]$_ })
    foreach ($lvl in $sortedLevels) {
        $count = $levelCounts[$lvl]
        $name  = if ($levelNames.ContainsKey([int]$lvl)) {
            $levelNames[[int]$lvl]
        } else {
            'Executive'
        }
        if ($count -ne 1) { $name += 's' }
        $summaryParts.Add("$count $name")
    }
    $lines.Add("Summary: $($summaryParts -join ', ')")

    # Depth and unmanaged
    $depth = if ($sortedLevels.Count -gt 0) {
        ([int]($sortedLevels | Measure-Object -Maximum).Maximum) + 1
    } else { 0 }
    $depthLine = "Depth: $depth levels"
    if ($unmanagedCount -gt 0) {
        $depthLine += " | Unmanaged: $unmanagedCount"
    }
    $lines.Add($depthLine)

    # Write all lines to the output stream
    foreach ($line in $lines) {
        Write-Output $line
    }
}

function Show-SPCampaignOrgPreview {
    <#
    .SYNOPSIS
        Previews the org tree for a campaign scope, showing which managers would
        receive campaigns and which identities they would review.
    .DESCRIPTION
        Takes an array of identity IDs (campaign subjects), builds an org tree via
        Build-SPOrgTree, then renders an ASCII preview showing:
        - Which managers would receive campaigns
        - Which identities each manager would review
        - Unmanaged identities that would not receive campaigns
        - Total campaign count

        This is a dry-run/preview tool -- it does not create campaigns.
    .PARAMETER IdentityIds
        Array of SailPoint ISC identity IDs representing the campaign subjects
        (identities whose access would be reviewed).
    .PARAMETER MaxDepth
        Maximum org tree depth to walk above the leaf identities. Default 3.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [string[]] Lines forming the ASCII campaign preview, written to the output stream.
    .EXAMPLE
        Show-SPCampaignOrgPreview -IdentityIds @('id-1','id-2','id-3') -MaxDepth 3
    .EXAMPLE
        $ids = (Get-SPDeltaAffectedIdentities -Events $events).Data.IdentityId
        Show-SPCampaignOrgPreview -IdentityIds $ids
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$IdentityIds,

        [Parameter()]
        [int]$MaxDepth = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Build the org tree from the provided identity IDs
    $treeResult = Build-SPOrgTree -IdentityIds $IdentityIds -MaxDepth $MaxDepth `
        -CorrelationID $CorrelationID

    if (-not $treeResult.Success) {
        Write-Warning "Show-SPCampaignOrgPreview: Failed to build org tree: $($treeResult.Error)"
        Write-Output "Campaign Org Preview -- ERROR: $($treeResult.Error)"
        return
    }

    $nodes = $treeResult.Data.Nodes
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        Write-Output 'Campaign Org Preview -- no identities found'
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    # Identify leaf identities (level 0) -- these are the campaign subjects
    $leafIds = [System.Collections.Generic.List[string]]::new()
    foreach ($nodeId in $nodes.Keys) {
        if ($nodes[$nodeId].Level -eq 0) {
            $leafIds.Add($nodeId)
        }
    }

    # Build manager -> leaf mapping: direct managers (level 1) and their level-0 children
    # A campaign is created per direct manager who has at least one level-0 child.
    $managerLeafMap = @{}  # managerId -> list of leaf identity names
    $unmanagedLeaves = [System.Collections.Generic.List[string]]::new()

    foreach ($leafId in $leafIds) {
        $leaf    = $nodes[$leafId]
        $mgrId   = $leaf.ManagerId
        $leafName = $leaf.Identity.Name
        if ([string]::IsNullOrWhiteSpace($leafName)) { $leafName = $leaf.Identity.Id }

        if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) {
            # No manager in the tree -- unmanaged
            $unmanagedLeaves.Add($leafName)
            continue
        }

        if (-not $managerLeafMap.ContainsKey($mgrId)) {
            $managerLeafMap[$mgrId] = [System.Collections.Generic.List[string]]::new()
        }
        $managerLeafMap[$mgrId].Add($leafName)
    }

    # Group managers by their highest-level ancestor (VP branch)
    # Walk each manager up the tree to find the top-level branch root
    function Get-BranchRoot {
        param([string]$NodeId)
        $current = $NodeId
        $visited = @{}
        while ($true) {
            $visited[$current] = $true
            $node  = $nodes[$current]
            $parent = $node.ManagerId
            if ([string]::IsNullOrWhiteSpace($parent) -or
                -not $nodes.ContainsKey($parent) -or
                $visited.ContainsKey($parent)) {
                return $current
            }
            $current = $parent
        }
    }

    # Build branch -> managers mapping
    $branchManagers = @{}  # branchRootId -> list of managerIds
    foreach ($mgrId in $managerLeafMap.Keys) {
        $rootId = Get-BranchRoot -NodeId $mgrId
        if (-not $branchManagers.ContainsKey($rootId)) {
            $branchManagers[$rootId] = [System.Collections.Generic.List[string]]::new()
        }
        $branchManagers[$rootId].Add($mgrId)
    }

    # Count VP branches (top-level roots at level >= 3)
    $vpBranchCount = 0
    foreach ($rootId in $branchManagers.Keys) {
        if ($nodes[$rootId].Level -ge 3) { $vpBranchCount++ }
    }
    $branchCount = if ($vpBranchCount -gt 0) { $vpBranchCount } else { $branchManagers.Count }
    $branchNoun  = if ($branchCount -eq 1) { 'branch' } else { 'branches' }
    $branchQual  = if ($vpBranchCount -gt 0) { 'VP ' } else { '' }
    $branchLabel = "$branchCount ${branchQual}$branchNoun"

    # Header
    $totalLeaves = $leafIds.Count
    $lines.Add("Campaign Org Preview -- $totalLeaves identities across $branchLabel")
    $lines.Add('')

    # Sort branch roots: highest level first, then by name
    $sortedBranchRoots = @(
        $branchManagers.Keys | Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
    )

    # Render each branch
    foreach ($rootId in $sortedBranchRoots) {
        $rootNode = $nodes[$rootId]
        $rootName = $rootNode.Identity.Name
        if ([string]::IsNullOrWhiteSpace($rootName)) { $rootName = $rootNode.Identity.Id }

        # Count total identities under this branch
        $branchMgrIds  = $branchManagers[$rootId]
        $branchTotal   = 0
        foreach ($mid in $branchMgrIds) {
            $branchTotal += $managerLeafMap[$mid].Count
        }

        $rootTitle = ''
        if ($rootNode.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($rootNode.Title)) {
            $rootTitle = " ($($rootNode.Title))"
        }

        $lines.Add("$rootName$rootTitle -- $branchTotal identities to review")

        # Get managers under this branch, sorted by level (desc) then name
        $sortedMgrs = @(
            $branchMgrIds | Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
        )

        for ($m = 0; $m -lt $sortedMgrs.Count; $m++) {
            $mgrId   = $sortedMgrs[$m]
            $mgrNode = $nodes[$mgrId]
            $mgrName = $mgrNode.Identity.Name
            if ([string]::IsNullOrWhiteSpace($mgrName)) { $mgrName = $mgrNode.Identity.Id }

            $mgrTitle = ''
            if ($mgrNode.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($mgrNode.Title)) {
                $mgrTitle = " ($($mgrNode.Title))"
            }

            $leafNames   = $managerLeafMap[$mgrId]
            $leafCount   = $leafNames.Count
            $countNoun   = if ($leafCount -eq 1) { 'identity' } else { 'identities' }
            $isLastMgr   = ($m -eq ($sortedMgrs.Count - 1))

            # Skip rendering the branch root as a child of itself if it IS the manager
            if ($mgrId -eq $rootId) {
                # Root IS the direct manager -- list identities under the header
                $lines.Add("  Manager for: $($leafNames -join ', ')")
            } else {
                $lines.Add("  +-- $mgrName$mgrTitle -- $leafCount $countNoun")

                $continuation = if ($isLastMgr) { '      ' } else { '  |   ' }
                $lines.Add("${continuation}Manager for: $($leafNames -join ', ')")
            }
        }

        $lines.Add('')
    }

    # Unmanaged identities
    if ($unmanagedLeaves.Count -gt 0) {
        $sortedUnmanaged = @($unmanagedLeaves | Sort-Object)
        $lines.Add("Unmanaged (no campaign): $($sortedUnmanaged -join ', ')")
        $lines.Add('')
    }

    # Campaign count = number of unique direct managers with leaf children
    $campaignCount = $managerLeafMap.Count
    $lines.Add("Campaigns that would be created: $campaignCount (one per manager with affected reports)")

    # Write all lines to the output stream
    foreach ($line in $lines) {
        Write-Output $line
    }
}

function Show-SPReportDistributionPreview {
    <#
    .SYNOPSIS
        Previews which leadership reports would be generated and who would receive them.
    .DESCRIPTION
        Shows the full distribution plan for leadership reports without generating or
        sending anything. For each org tree level that has leaders in the LeadershipData,
        lists the recipient, their content summary (subordinate count, completion %),
        and optionally their email address.

        Displays SMTP status at the bottom so the caller knows whether email delivery
        is configured.

        This is a dry-run preview -- no reports are generated, no emails are sent.
    .PARAMETER OrgTree
        Org tree Data hashtable (the .Data property from Build-SPOrgTree or
        Merge-SPOrgTreeWithSupplement). Must contain Nodes and LevelLabels.
    .PARAMETER LeadershipData
        Hashtable from Group-SPAuditByLeadership containing Levels, TopLevel,
        LevelLabels, Directors, and Executive rollups.
    .PARAMETER IncludeEmail
        When specified, resolves each leader's email address from ISC via
        Resolve-SPAuditIdentityAccounts and includes it in the output.
    .OUTPUTS
        [string[]] Lines forming the ASCII distribution preview, written to the output stream.
    .EXAMPLE
        $tree = Build-SPOrgTree -IdentityIds $ids -MaxDepth 4
        $leadership = Group-SPAuditByLeadership -Decisions $decisions -OrgTree $tree.Data
        Show-SPReportDistributionPreview -OrgTree $tree.Data -LeadershipData $leadership
    .EXAMPLE
        Show-SPReportDistributionPreview -OrgTree $tree.Data -LeadershipData $leadership -IncludeEmail
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [hashtable]$LeadershipData,

        [Parameter()]
        [switch]$IncludeEmail
    )

    $nodes = $OrgTree.Nodes
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        Write-Output 'Report Distribution Preview -- no org tree nodes'
        return
    }

    $levels      = $LeadershipData.Levels
    $topLevel    = $LeadershipData.TopLevel
    $levelLabels = $LeadershipData.LevelLabels

    if ($null -eq $levels -or $levels.Count -eq 0) {
        Write-Output 'Report Distribution Preview -- no leadership data'
        return
    }

    # Band auto-detect from tree level
    $bandFromLevel = @{ 0 = 'E'; 1 = 'D'; 2 = 'C'; 3 = 'B' }

    # Resolve band letter for a node
    function Get-NodeBandLocal {
        param([hashtable]$Node)
        if ($Node.ContainsKey('Band') -and -not [string]::IsNullOrWhiteSpace($Node.Band)) {
            return $Node.Band
        }
        $lvl = $Node.Level
        if ($lvl -ge 4) { return 'A' }
        if ($bandFromLevel.ContainsKey($lvl)) { return $bandFromLevel[$lvl] }
        return 'E'
    }

    # Resolve email addresses if requested
    $emailMap = @{}  # identityId -> email string
    if ($IncludeEmail) {
        # Collect all leader identity IDs across all levels
        $leaderIds = [System.Collections.Generic.List[string]]::new()
        foreach ($lvl in $levels.Keys) {
            $lvlLeaders = $levels[$lvl].Leaders
            if ($null -eq $lvlLeaders) { continue }
            foreach ($leaderId in $lvlLeaders.Keys) {
                if ($leaderId -ne '__unmanaged__' -and
                    -not $leaderId.StartsWith('supplement-') -and
                    -not $leaderIds.Contains($leaderId)) {
                    $leaderIds.Add($leaderId)
                }
            }
        }

        if ($leaderIds.Count -gt 0) {
            try {
                $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds @($leaderIds.ToArray())
                if ($null -ne $acctResult -and $acctResult.Success -and $null -ne $acctResult.Data) {
                    foreach ($id in $acctResult.Data.Keys) {
                        $acct = $acctResult.Data[$id]
                        $email = ''
                        if ($null -ne $acct) {
                            if (-not [string]::IsNullOrWhiteSpace($acct.Email)) {
                                $email = $acct.Email
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace($acct.UserPrincipalName)) {
                                $email = $acct.UserPrincipalName
                            }
                        }
                        if (-not [string]::IsNullOrWhiteSpace($email)) {
                            $emailMap[$id] = $email
                        }
                    }
                }
            }
            catch {
                Write-Warning "Show-SPReportDistributionPreview: Could not resolve emails: $($_.Exception.Message)"
            }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Report Distribution Preview')
    $lines.Add('============================')
    $lines.Add('')

    $totalReports    = 0
    $totalRecipients = 0

    # Walk levels from top down (highest level first)
    $sortedLevels = @($levels.Keys | Sort-Object { -$_ })

    foreach ($lvl in $sortedLevels) {
        $lvlData    = $levels[$lvl]
        $lvlLeaders = $lvlData.Leaders
        if ($null -eq $lvlLeaders -or $lvlLeaders.Count -eq 0) { continue }

        # Determine level label
        $levelLabel = $lvlData.Label
        if ([string]::IsNullOrWhiteSpace($levelLabel)) {
            $levelLabel = if ($null -ne $levelLabels -and $levelLabels.ContainsKey($lvl)) {
                $levelLabels[$lvl]
            } else { "Level $lvl" }
        }

        # Filter out unmanaged bucket from report count
        $reportLeaders = @{}
        foreach ($leaderId in $lvlLeaders.Keys) {
            if ($leaderId -ne '__unmanaged__') {
                $reportLeaders[$leaderId] = $lvlLeaders[$leaderId]
            }
        }

        if ($reportLeaders.Count -eq 0) { continue }

        # Determine section label
        $reportNoun  = if ($reportLeaders.Count -eq 1) { 'report' } else { 'reports' }

        # Top level is the executive summary
        $sectionTitle = if ($lvl -eq $topLevel -and $reportLeaders.Count -eq 1) {
            "Executive Summary (1 report)"
        } else {
            "$levelLabel Reports ($($reportLeaders.Count) $reportNoun)"
        }
        $lines.Add($sectionTitle)

        # Sort leaders by name
        $sortedLeaderIds = @(
            $reportLeaders.Keys | Sort-Object { $reportLeaders[$_].Name }
        )

        foreach ($leaderId in $sortedLeaderIds) {
            $leader = $reportLeaders[$leaderId]
            $name   = $leader.Name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $leaderId }

            # Build the "To:" line with optional email and band
            $toLine = "  To: $name"

            if ($IncludeEmail) {
                $email = if ($emailMap.ContainsKey($leaderId)) { $emailMap[$leaderId] } else { 'no email' }
                $toLine += " ($email)"
            }

            # Resolve band from org tree node if available
            if ($nodes.ContainsKey($leaderId)) {
                $node  = $nodes[$leaderId]
                $band  = Get-NodeBandLocal -Node $node
                $title = ''
                if ($node.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($node.Title)) {
                    $title = $node.Title + ', '
                }
                $toLine += " [${title}Band $band]"
            }

            $lines.Add($toLine)

            # Content summary: subordinate/manager counts and completion
            $contentParts = [System.Collections.Generic.List[string]]::new()

            # Count subordinates (for level 3+ leaders)
            if ($null -ne $leader['Subordinates'] -and $leader.Subordinates.Count -gt 0) {
                $subCount = $leader.Subordinates.Count
                $subNoun  = if ($subCount -eq 1) { 'direct report' } else { 'direct reports' }
                $contentParts.Add("$subCount $subNoun")
            }

            # Count managers (for level 2 directors)
            if ($null -ne $leader['Managers'] -and $leader.Managers.Count -gt 0) {
                $mgrCount = $leader.Managers.Count
                $mgrNoun  = if ($mgrCount -eq 1) { 'manager' } else { 'managers' }
                $contentParts.Add("$mgrCount $mgrNoun")
            }

            # Total items and completion
            if ($leader.TotalItems -gt 0) {
                $contentParts.Add("$($leader.TotalItems) items")
                $contentParts.Add("$($leader.CompletionPct)% completion")
            }

            if ($contentParts.Count -gt 0) {
                $lines.Add("      Content: $($contentParts -join ', ')")
            }

            $totalReports++
            $totalRecipients++
        }

        $lines.Add('')
    }

    # Total summary
    $lines.Add("Total: $totalReports reports to $totalRecipients recipients")

    # SMTP status
    $smtpStatus = 'NOT CONFIGURED (reports will be generated but not emailed)'
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg -and
            $null -ne $cfg.PSObject.Properties['Audit'] -and
            $null -ne $cfg.Audit -and
            $null -ne $cfg.Audit.PSObject.Properties['Smtp'] -and
            $null -ne $cfg.Audit.Smtp -and
            $null -ne $cfg.Audit.Smtp.PSObject.Properties['Enabled'] -and
            $cfg.Audit.Smtp.Enabled -eq $true) {
            $server = $cfg.Audit.Smtp.Server
            if (-not [string]::IsNullOrWhiteSpace($server)) {
                $smtpStatus = "CONFIGURED (Server: $server)"
            } else {
                $smtpStatus = 'ENABLED but no server configured'
            }
        }
    }
    catch {
        # Config read failed -- default to NOT CONFIGURED
    }

    $lines.Add("SMTP Status: $smtpStatus")

    foreach ($line in $lines) {
        Write-Output $line
    }
}

function Export-SPOrgChartHtml {
    <#
    .SYNOPSIS
        Generates a visual org chart as a self-contained HTML file.
    .DESCRIPTION
        Renders the org tree as a top-down HTML document with nested div elements and
        CSS borders for visual hierarchy. Each node displays name, title, band, and
        direct report count. Nodes are color-coded by band classification:

        A (purple) = President / C-suite
        B (blue)   = VP / SVP
        C (green)  = Director
        D (orange) = Manager
        E (gray)   = Individual Contributor

        All CSS is inline on elements for Word copy-paste compatibility.
        No JavaScript, no flexbox, no grid, no external resources.

        When ReportsPath is provided, nodes link to corresponding leadership reports
        if the report HTML file exists in that directory.
    .PARAMETER OrgTree
        Org tree Data hashtable (the .Data property from Build-SPOrgTree or
        Merge-SPOrgTreeWithSupplement). Must contain a Nodes hashtable.
    .PARAMETER OutputPath
        File path or directory for the HTML output. If a directory, generates
        a file named org-chart-{yyyy-MM-dd}.html inside it.
    .PARAMETER Title
        Title displayed at the top of the report. Default: 'Organization Chart'.
    .PARAMETER ReportsPath
        Optional directory containing leadership reports. When provided, nodes
        with matching report files get clickable links.
    .PARAMETER CorrelationID
        Correlation ID embedded in the report footer. Auto-generated if omitted.
    .OUTPUTS
        Hashtable with Success, Data (@{FilePath; NodeCount}), and Error keys.
    .EXAMPLE
        $tree = Build-SPOrgTree -IdentityIds $ids -MaxDepth 4
        $result = Export-SPOrgChartHtml -OrgTree $tree.Data -OutputPath 'C:\Reports'
    .EXAMPLE
        $merged = Merge-SPOrgTreeWithSupplement -OrgTree $tree.Data -Supplement $supp
        Export-SPOrgChartHtml -OrgTree $merged.Data -OutputPath 'C:\Reports\org-chart.html' `
            -ReportsPath 'C:\Reports\leadership' -Title 'Q1 Org Chart'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [string]$Title = 'Organization Chart',

        [Parameter()]
        [string]$ReportsPath,

        [Parameter()]
        [string]$CorrelationID
    )

    # --- Validate input ---
    $nodes = $OrgTree.Nodes
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        return @{ Success = $false; Data = $null; Error = 'OrgTree contains no nodes' }
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # --- Resolve output file path ---
    if (Test-Path -Path $OutputPath -PathType Container) {
        $dateStr = (Get-Date).ToString('yyyy-MM-dd')
        $OutputPath = Join-Path $OutputPath "org-chart-$dateStr.html"
    } else {
        $outputDir = Split-Path -Path $OutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDir) -and
            -not (Test-Path -Path $outputDir -PathType Container)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
    }

    $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $fontFamily  = "-apple-system,'Segoe UI',system-ui,sans-serif"

    # --- Band colors ---
    # A=purple, B=blue (toolkit #336699), C=green (toolkit #339933),
    # D=orange (toolkit #FF8800), E=gray (toolkit #777777)
    $bandColors = @{
        'A' = @{ Border = '#7b2d8e'; Background = '#f8f5fa'; Text = '#7b2d8e' }
        'B' = @{ Border = '#336699'; Background = '#f0f4f8'; Text = '#336699' }
        'C' = @{ Border = '#339933'; Background = '#f0f8f0'; Text = '#339933' }
        'D' = @{ Border = '#FF8800'; Background = '#fff8f0'; Text = '#FF8800' }
        'E' = @{ Border = '#777777'; Background = '#f5f5f5'; Text = '#777777' }
    }

    $bandFromLevel = @{ 0 = 'E'; 1 = 'D'; 2 = 'C'; 3 = 'B' }

    $bandLabels = @{
        'A' = 'President / C-suite'
        'B' = 'VP / SVP'
        'C' = 'Director'
        'D' = 'Manager'
        'E' = 'Individual Contributor'
    }

    # --- Helper: resolve band for a node ---
    function Get-NodeBand {
        param([hashtable]$Node)
        if ($Node.ContainsKey('Band') -and -not [string]::IsNullOrWhiteSpace($Node.Band)) {
            return $Node.Band.ToUpper()
        }
        $lvl = $Node.Level
        if ($lvl -ge 4) { return 'A' }
        if ($bandFromLevel.ContainsKey($lvl)) { return $bandFromLevel[$lvl] }
        return 'E'
    }

    # --- Helper: HTML-encode ---
    function Encode-Html {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        return [System.Net.WebUtility]::HtmlEncode($Text)
    }

    # --- Helper: resolve leadership report link for a node ---
    function Get-ReportLink {
        param([hashtable]$Node, [string]$NodeId)
        if ([string]::IsNullOrWhiteSpace($ReportsPath)) { return $null }
        if (-not (Test-Path -Path $ReportsPath -PathType Container)) { return $null }

        $name = if ($null -ne $Node.Identity -and
                    -not [string]::IsNullOrWhiteSpace($Node.Identity.Name)) {
            $Node.Identity.Name
        } else { $NodeId }

        $safeName = ($name -replace '[^a-zA-Z0-9_-]', '').Trim()
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = $NodeId -replace '[^a-zA-Z0-9_-]', ''
        }

        $levelPrefixes = @{
            1 = 'manager'
            2 = 'director'
            3 = 'vice-president'
            4 = 'senior-vice-president'
            5 = 'executive-leadership'
        }
        $lvl = $Node.Level

        if ($levelPrefixes.ContainsKey($lvl)) {
            $prefix   = $levelPrefixes[$lvl]
            $fileName = "$prefix-$safeName.html"
            $filePath = Join-Path $ReportsPath $fileName
            if (Test-Path $filePath) { return $fileName }
        }

        # Top-of-tree leaders may have an executive-summary report
        $mgrId = $Node.ManagerId
        $isRoot = [string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)
        if ($isRoot -and $lvl -ge 3) {
            $execPath = Join-Path $ReportsPath 'executive-summary.html'
            if (Test-Path $execPath) { return 'executive-summary.html' }
        }

        return $null
    }

    # --- Find root nodes ---
    $rootIds = [System.Collections.Generic.List[string]]::new()
    foreach ($nodeId in $nodes.Keys) {
        $node  = $nodes[$nodeId]
        $mgrId = $node.ManagerId
        if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) {
            $rootIds.Add($nodeId)
        }
    }
    $sortedRoots = @(
        $rootIds | Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
    )

    # --- Build node HTML recursively ---
    function Build-NodeHtml {
        param([string]$NodeId)

        $node  = $nodes[$NodeId]
        $band  = Get-NodeBand -Node $node
        $style = if ($bandColors.ContainsKey($band)) { $bandColors[$band] } else { $bandColors['E'] }

        $name = if ($null -ne $node.Identity -and
                    -not [string]::IsNullOrWhiteSpace($node.Identity.Name)) {
            $node.Identity.Name
        } else { $NodeId }
        $safeName = Encode-Html $name

        $titleText = ''
        if ($node.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($node.Title)) {
            $titleText = Encode-Html $node.Title
        }

        $children = @()
        if ($null -ne $node.Children) {
            $children = @($node.Children | Where-Object { $nodes.ContainsKey($_) })
        }
        $childCount = $children.Count

        $reportLink = Get-ReportLink -Node $node -NodeId $NodeId

        $sb = [System.Text.StringBuilder]::new()

        # Node wrapper
        [void]$sb.Append("<div style=""margin-bottom:6px;"">")

        # Node card with colored left border
        [void]$sb.Append("<div style=""border-left:4px solid $($style.Border); background:$($style.Background); padding:8px 12px; font-family:$fontFamily;"">")

        # Name (optionally linked to leadership report)
        if ($null -ne $reportLink) {
            [void]$sb.Append("<a href=""$reportLink"" style=""color:$($style.Text); text-decoration:none; font-weight:bold; font-size:14px; font-family:$fontFamily;"">$safeName</a>")
        } else {
            [void]$sb.Append("<span style=""font-weight:bold; font-size:14px; color:#2c3e50; font-family:$fontFamily;"">$safeName</span>")
        }

        # Title
        if (-not [string]::IsNullOrWhiteSpace($titleText)) {
            [void]$sb.Append(" &mdash; <span style=""color:#555; font-size:13px;"">$titleText</span>")
        }

        # Band badge
        [void]$sb.Append(" <span style=""color:$($style.Text); font-size:12px; font-weight:bold;"">[Band $band]</span>")

        # Direct report count
        if ($childCount -gt 0) {
            $reportLabel = if ($childCount -eq 1) { '1 direct report' } else { "$childCount direct reports" }
            [void]$sb.Append(" <span style=""color:#777; font-size:12px;"">($reportLabel)</span>")
        }

        [void]$sb.Append('</div>')

        # Children container with connecting border
        if ($childCount -gt 0) {
            $sortedChildren = @(
                $children | Sort-Object { -$nodes[$_].Level }, { $nodes[$_].Identity.Name }
            )
            [void]$sb.Append("<div style=""margin-left:24px; border-left:2px solid #ddd; padding-left:16px; padding-top:4px;"">")
            foreach ($childId in $sortedChildren) {
                [void]$sb.Append((Build-NodeHtml -NodeId $childId))
            }
            [void]$sb.Append('</div>')
        }

        [void]$sb.Append('</div>')
        return $sb.ToString()
    }

    # --- Compute summary statistics ---
    $levelCounts = @{}
    $bandCounts  = @{}
    foreach ($nodeId in $nodes.Keys) {
        $node = $nodes[$nodeId]
        $lvl  = $node.Level
        if (-not $levelCounts.ContainsKey($lvl)) { $levelCounts[$lvl] = 0 }
        $levelCounts[$lvl]++

        $band = Get-NodeBand -Node $node
        if (-not $bandCounts.ContainsKey($band)) { $bandCounts[$band] = 0 }
        $bandCounts[$band]++
    }

    $totalNodes = $nodes.Count
    $maxDepth   = if ($levelCounts.Count -gt 0) {
        ([int]($levelCounts.Keys | Measure-Object -Maximum).Maximum) + 1
    } else { 0 }

    # --- Build summary cards HTML (table layout for Word compat) ---
    $summaryCardsHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:20px; font-family:$fontFamily;">
<tr>
<td style="width:25%; padding:12px 16px; background:#f0f2f5; text-align:center; border:1px solid #e0e0e0;">
<div style="font-size:28px; font-weight:bold; color:#2c3e50;">$totalNodes</div>
<div style="font-size:12px; color:#777;">Total Nodes</div>
</td>
<td style="width:25%; padding:12px 16px; background:#f0f2f5; text-align:center; border:1px solid #e0e0e0;">
<div style="font-size:28px; font-weight:bold; color:#2c3e50;">$maxDepth</div>
<div style="font-size:12px; color:#777;">Levels Deep</div>
</td>
<td style="width:25%; padding:12px 16px; background:#f0f2f5; text-align:center; border:1px solid #e0e0e0;">
<div style="font-size:28px; font-weight:bold; color:#2c3e50;">$($sortedRoots.Count)</div>
<div style="font-size:12px; color:#777;">Root Nodes</div>
</td>
<td style="width:25%; padding:12px 16px; background:#f0f2f5; text-align:center; border:1px solid #e0e0e0;">
<div style="font-size:28px; font-weight:bold; color:#2c3e50;">$(if ($levelCounts.ContainsKey(0)) { $totalNodes - $levelCounts[0] } else { $totalNodes })</div>
<div style="font-size:12px; color:#777;">Leaders</div>
</td>
</tr>
</table>
"@

    # --- Build band legend HTML (table layout) ---
    $legendCells = [System.Text.StringBuilder]::new()
    foreach ($b in @('A','B','C','D','E')) {
        $style = $bandColors[$b]
        $label = $bandLabels[$b]
        $count = if ($bandCounts.ContainsKey($b)) { $bandCounts[$b] } else { 0 }
        [void]$legendCells.Append(@"
<td style="padding:6px 10px; border-left:4px solid $($style.Border); background:$($style.Background); font-family:$fontFamily; font-size:12px;">
<strong style="color:$($style.Text);">Band $b</strong> $([System.Net.WebUtility]::HtmlEncode($label)) <span style="color:#777;">($count)</span>
</td>
"@)
    }
    $legendHtml = @"
<table style="width:100%; border-collapse:collapse; margin-bottom:24px; font-family:$fontFamily;">
<tr>
$($legendCells.ToString())
</tr>
</table>
"@

    # --- Build org tree HTML ---
    $treeHtml = [System.Text.StringBuilder]::new()
    foreach ($rootId in $sortedRoots) {
        [void]$treeHtml.Append((Build-NodeHtml -NodeId $rootId))
    }

    # --- Footer ---
    $safeTitle     = [System.Net.WebUtility]::HtmlEncode($Title)
    $safeGenerated = [System.Net.WebUtility]::HtmlEncode($generatedAt)
    $safeCorrId    = [System.Net.WebUtility]::HtmlEncode($CorrelationID)

    $footerHtml = @"
<div style="margin-top:32px; padding-top:12px; border-top:1px solid #dee2e6; color:#777777; font-family:$fontFamily; font-size:11px; text-align:center;">
    SailPoint ISC Governance Toolkit &nbsp;|&nbsp; $safeTitle &nbsp;|&nbsp; Generated: $safeGenerated &nbsp;|&nbsp; Correlation ID: $safeCorrId
</div>
"@

    # --- Assemble full HTML document ---
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$safeTitle</title>
</head>
<body style="font-family:$fontFamily; margin:0; padding:24px; background:#f0f2f5; color:#333;">
<div style="max-width:1100px; margin:0 auto; background:#fff; padding:32px 40px;">

<h1 style="font-family:$fontFamily; color:#2c3e50; font-size:24px; margin-bottom:4px;">$safeTitle</h1>
<p style="font-family:$fontFamily; color:#555; font-size:14px; margin:0 0 16px 0;">Generated: $safeGenerated</p>

$summaryCardsHtml

$legendHtml

<h2 style="font-family:$fontFamily; color:#2c3e50; font-size:18px; border-bottom:2px solid #336699; padding-bottom:6px; margin-bottom:16px;">Organizational Hierarchy</h2>

$($treeHtml.ToString())

$footerHtml

</div>
</body>
</html>
"@

    # --- Write to file ---
    try {
        $html | Set-Content -Path $OutputPath -Encoding UTF8

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Org chart HTML exported: $OutputPath ($totalNodes nodes)" `
                -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Export-SPOrgChartHtml' `
                -CorrelationID $CorrelationID
        }

        return @{
            Success = $true
            Data    = @{
                FilePath  = $OutputPath
                NodeCount = $totalNodes
                Depth     = $maxDepth
                RootCount = $sortedRoots.Count
            }
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = $null
            Error   = "Failed to write org chart HTML: $_"
        }
    }
}

function Resolve-SPIdentityBand {
    <#
    .SYNOPSIS
        Assigns band classifications (A-E) to each identity in the org tree.
    .DESCRIPTION
        Three sources of band data, checked in priority order:
        1. Supplement CSV (OC-01) -- explicit band column (highest priority)
        2. ISC identity attributes -- jobLevel or band attribute from the identity cache
        3. Auto-detect from depth -- fallback using BandMapping (tree Level -> band letter)

        Band convention: A=President/C-suite, B=VP/SVP, C=Director, D=Manager, E=IC.
        Every identity receives a band assignment (no nulls).
    .PARAMETER OrgTree
        Org tree Data hashtable from Build-SPOrgTree or Merge-SPOrgTreeWithSupplement
        (the .Data property, containing Nodes, TopLeaders, etc.).
    .PARAMETER Supplement
        Optional supplement entries hashtable from Import-SPOrgChartSupplement
        (.Data.Entries property). Keyed by lowercase email address.
    .PARAMETER BandMapping
        Optional hashtable mapping tree depth to band letter. Keys may be integers or
        strings (e.g. @{ 0='E'; 1='D' } or @{ '0'='E'; '1'='D' }).
        Defaults to @{ 0='E'; 1='D'; 2='C'; 3='B'; 4='A' }.
    .PARAMETER ISCBandAttribute
        Name of the ISC identity attribute to check for band/level data.
        Defaults to 'jobLevel'. Falls back to 'band' if the primary attribute is empty.
    .OUTPUTS
        [hashtable] @{
            Success = [bool]
            Data    = @{
                Bands   = @{ identityId -> [string] band letter (A-E) }
                Sources = @{ identityId -> [string] 'Supplement'|'ISC'|'Depth' }
                Summary = @{ A=[int]; B=[int]; C=[int]; D=[int]; E=[int] }
            }
            Error   = $null | [string]
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter()]
        [hashtable]$Supplement,

        [Parameter()]
        [hashtable]$BandMapping,

        [Parameter()]
        [string]$ISCBandAttribute = 'jobLevel'
    )

    # Default band mapping: depth -> band letter
    if ($null -eq $BandMapping -or $BandMapping.Count -eq 0) {
        $BandMapping = @{ 0 = 'E'; 1 = 'D'; 2 = 'C'; 3 = 'B'; 4 = 'A' }
    }

    # Normalise BandMapping keys to integers for consistent lookups
    $normalizedMapping = @{}
    foreach ($key in $BandMapping.Keys) {
        $intKey = 0
        if ([int]::TryParse("$key", [ref]$intKey)) {
            $normalizedMapping[$intKey] = [string]$BandMapping[$key]
        }
    }

    $validBands = @('A', 'B', 'C', 'D', 'E')

    $nodes = $OrgTree.Nodes
    if ($null -eq $nodes -or $nodes.Count -eq 0) {
        return @{
            Success = $true
            Data    = @{
                Bands   = @{}
                Sources = @{}
                Summary = @{ A = 0; B = 0; C = 0; D = 0; E = 0 }
            }
            Error   = $null
        }
    }

    $bands   = @{}
    $sources = @{}
    $summary = @{ A = 0; B = 0; C = 0; D = 0; E = 0 }

    foreach ($nodeId in $nodes.Keys) {
        $node   = $nodes[$nodeId]
        $band   = $null
        $source = $null

        # --- Source 1: Supplement CSV (highest priority) ---
        if ($null -eq $band -and $null -ne $Supplement -and $Supplement.Count -gt 0) {
            $nodeEmail = $null

            # Synthetic nodes carry Email directly
            if ($node.ContainsKey('Email') -and
                -not [string]::IsNullOrWhiteSpace($node.Email)) {
                $nodeEmail = $node.Email.ToLower()
            }
            # Real nodes: resolve email from identity cache
            elseif ($script:IdentityCache.ContainsKey($nodeId)) {
                $cached = $script:IdentityCache[$nodeId]
                if (-not [string]::IsNullOrWhiteSpace($cached.Email)) {
                    $nodeEmail = $cached.Email.ToLower()
                }
            }

            if ($null -ne $nodeEmail -and $Supplement.ContainsKey($nodeEmail)) {
                $suppEntry = $Supplement[$nodeEmail]
                if (-not [string]::IsNullOrWhiteSpace($suppEntry.Band) -and
                    $suppEntry.Band.ToUpper() -in $validBands) {
                    $band   = $suppEntry.Band.ToUpper()
                    $source = 'Supplement'
                }
            }
        }

        # Source 1b: Node explicit Band key (set by Merge-SPOrgTreeWithSupplement on
        # synthetic nodes -- still supplement-sourced data)
        if ($null -eq $band -and $node.ContainsKey('Band') -and
            -not [string]::IsNullOrWhiteSpace($node.Band)) {
            if ($node.Band.ToUpper() -in $validBands) {
                $band   = $node.Band.ToUpper()
                $source = 'Supplement'
            }
        }

        # --- Source 2: ISC identity attribute (jobLevel / band) ---
        if ($null -eq $band -and $script:IdentityCache.ContainsKey($nodeId)) {
            $cached = $script:IdentityCache[$nodeId]
            if ($cached.Found -and -not [string]::IsNullOrWhiteSpace($cached.JobLevel)) {
                $iscValue = $cached.JobLevel.Trim()

                # If it is already a valid band letter, use directly
                if ($iscValue.ToUpper() -in $validBands) {
                    $band   = $iscValue.ToUpper()
                    $source = 'ISC'
                }
                else {
                    # Try to interpret as numeric level and map via BandMapping
                    $numericLevel = 0
                    if ([int]::TryParse($iscValue, [ref]$numericLevel) -and
                        $normalizedMapping.ContainsKey($numericLevel)) {
                        $band   = $normalizedMapping[$numericLevel]
                        $source = 'ISC'
                    }
                }
            }
        }

        # --- Source 3: Auto-detect from tree depth (fallback) ---
        if ($null -eq $band) {
            $lvl = [int]$node.Level
            if ($normalizedMapping.ContainsKey($lvl)) {
                $band = $normalizedMapping[$lvl]
            }
            elseif ($lvl -ge 4) {
                # Levels beyond the mapping ceiling default to top band
                $band = 'A'
            }
            else {
                $band = 'E'
            }
            $source = 'Depth'
        }

        $bands[$nodeId]   = $band
        $sources[$nodeId] = $source
        $summary[$band]++
    }

    return @{
        Success = $true
        Data    = @{
            Bands   = $bands
            Sources = $sources
            Summary = $summary
        }
        Error   = $null
    }
}

#endregion

#region OC-09: Org Chart Gap Detector

function Get-SPOrgChartGaps {
    <#
    .SYNOPSIS
        Analyzes the org tree and identifies gaps that prevent complete leadership reporting.
    .DESCRIPTION
        Scans the org tree for six types of structural gaps:
        - NoManager: identity has no manager (ISC or supplement)
        - ShallowChain: manager chain is less than 3 levels deep
        - MissingEmail: leader (level >= 1) has no email address
        - OrphanedBranch: manager has no manager themselves (chain ends prematurely)
        - SupplementConflict: supplement and ISC disagree on manager
        - CircularReference: cycle detected in the manager chain

        Produces an actionable list of issues and recommendations for the governance
        team. Intended as a pre-flight check before report generation.
    .PARAMETER OrgTree
        Org tree Data hashtable from Build-SPOrgTree or Merge-SPOrgTreeWithSupplement
        (the .Data property, containing Nodes, TopLeaders, etc.).
    .PARAMETER Supplement
        Optional supplement entries hashtable from Import-SPOrgChartSupplement
        (.Data.Entries property). Used to detect supplement-specific conflicts.
    .PARAMETER MinChainDepth
        Minimum expected chain depth (levels above leaf). Chains shorter than this
        are flagged as ShallowChain. Default: 3.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = [bool]
            Data    = @{
                Gaps            = [hashtable[]]  # array of gap records
                Summary         = @{ Total; Complete; Gaps; GapRate }
                Recommendations = [string[]]
            }
            Error   = $null | [string]
        }
    .EXAMPLE
        $tree = Build-SPOrgTree -IdentityIds $ids -MaxDepth 4
        $gaps = Get-SPOrgChartGaps -OrgTree $tree.Data
        $gaps.Data.Gaps | Where-Object { $_.Type -eq 'NoManager' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$OrgTree,

        [Parameter()]
        [hashtable]$Supplement,

        [Parameter()]
        [int]$MinChainDepth = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPOrgChartGaps: Analyzing org tree with $($OrgTree.Nodes.Count) nodes for structural gaps" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPOrgChartGaps' `
        -CorrelationID $CorrelationID

    try {
        $nodes = $OrgTree.Nodes
        if ($null -eq $nodes -or $nodes.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    Gaps            = @()
                    Summary         = @{ Total = 0; Complete = 0; Gaps = 0; GapRate = 0.0 }
                    Recommendations = @('No nodes in org tree to analyze')
                }
                Error   = $null
            }
        }

        $gaps = [System.Collections.Generic.List[hashtable]]::new()

        # Determine the top level in the tree to distinguish intentional roots from orphans
        $topLevel = 0
        if ($OrgTree.ContainsKey('TopLevel')) {
            $topLevel = [int]$OrgTree.TopLevel
        }
        else {
            foreach ($nodeId in $nodes.Keys) {
                if ($nodes[$nodeId].Level -gt $topLevel) { $topLevel = $nodes[$nodeId].Level }
            }
        }

        # Build a set of intentional root IDs (TopLeaders at the highest level)
        $intentionalRoots = [System.Collections.Generic.HashSet[string]]::new()
        if ($OrgTree.ContainsKey('TopLeaders')) {
            foreach ($tlId in $OrgTree.TopLeaders) {
                if ($nodes.ContainsKey($tlId) -and $nodes[$tlId].Level -ge $topLevel) {
                    [void]$intentionalRoots.Add($tlId)
                }
            }
        }

        # Track which nodes have gaps to avoid double-counting
        $nodeIdsWithGaps = [System.Collections.Generic.HashSet[string]]::new()

        # --- Gap Type 1: NoManager ---
        # Identity has no manager in ISC and no supplement override.
        # Applies to leaf nodes (Level 0) without a manager.
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -ne 0) { continue }
            if (-not [string]::IsNullOrWhiteSpace($node.ManagerId) -and
                $nodes.ContainsKey($node.ManagerId)) { continue }

            $nodeName = if ($node.Identity) { $node.Identity.Name } else { $nodeId }
            $gaps.Add(@{
                Type       = 'NoManager'
                IdentityId = $nodeId
                Name       = $nodeName
                Impact     = 'No campaign, excluded from reports'
            })
            [void]$nodeIdsWithGaps.Add($nodeId)
        }

        # --- Gap Type 2: ShallowChain ---
        # Walk up from each leaf node and count the chain depth.
        # Flag if chain depth < MinChainDepth.
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -ne 0) { continue }

            # Walk the manager chain from this leaf
            $depth   = 0
            $current = $nodeId
            $visited = [System.Collections.Generic.HashSet[string]]::new()
            [void]$visited.Add($current)

            while ($true) {
                $cn = $nodes[$current]
                $mgrId = $cn.ManagerId
                if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) {
                    break
                }
                if (-not $visited.Add($mgrId)) {
                    break  # cycle -- handled separately
                }
                $depth++
                $current = $mgrId
            }

            if ($depth -gt 0 -and $depth -lt $MinChainDepth) {
                # Only flag if the chain top is NOT an intentional root at the highest level
                # (a short chain is expected if the org only has 2 levels)
                $chainTop = $current
                if (-not $intentionalRoots.Contains($chainTop)) {
                    $nodeName = if ($nodes[$chainTop].Identity) { $nodes[$chainTop].Identity.Name } else { $chainTop }
                    $gaps.Add(@{
                        Type       = 'ShallowChain'
                        IdentityId = $chainTop
                        Name       = $nodeName
                        Depth      = $depth
                        Impact     = "Reports stop at depth $depth (expected $MinChainDepth+)"
                    })
                    [void]$nodeIdsWithGaps.Add($chainTop)
                }
            }
        }

        # Deduplicate ShallowChain gaps (multiple leaves may trace to the same chain top)
        $seenShallow = [System.Collections.Generic.HashSet[string]]::new()
        $dedupedGaps = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($gap in $gaps) {
            if ($gap.Type -eq 'ShallowChain') {
                $key = "ShallowChain:$($gap.IdentityId)"
                if (-not $seenShallow.Add($key)) { continue }
            }
            $dedupedGaps.Add($gap)
        }
        $gaps = $dedupedGaps

        # --- Gap Type 3: MissingEmail ---
        # Leaders (Level >= 1) who have no email address in the identity cache.
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -lt 1) { continue }

            $hasEmail = $false

            # Check synthetic nodes for Email property
            if ($node.ContainsKey('Synthetic') -and $node.Synthetic -eq $true) {
                if ($node.ContainsKey('Email') -and
                    -not [string]::IsNullOrWhiteSpace($node.Email)) {
                    $hasEmail = $true
                }
            }
            else {
                # Check identity cache for real nodes
                if ($script:IdentityCache.ContainsKey($nodeId)) {
                    $cached = $script:IdentityCache[$nodeId]
                    if (-not [string]::IsNullOrWhiteSpace($cached.Email)) {
                        $hasEmail = $true
                    }
                }
            }

            if (-not $hasEmail) {
                $nodeName = if ($node.Identity) { $node.Identity.Name } else { $nodeId }
                $levelLabel = if ($OrgTree.ContainsKey('LevelLabels') -and
                                  $OrgTree.LevelLabels.ContainsKey($node.Level)) {
                    $OrgTree.LevelLabels[$node.Level]
                } else { "Level $($node.Level)" }

                $gaps.Add(@{
                    Type       = 'MissingEmail'
                    IdentityId = $nodeId
                    Name       = $nodeName
                    Level      = $levelLabel
                    Impact     = "Cannot email $levelLabel report"
                })
                [void]$nodeIdsWithGaps.Add($nodeId)
            }
        }

        # --- Gap Type 4: OrphanedBranch ---
        # Manager (Level >= 1) has no manager themselves, but is NOT an intentional root.
        # Their branch ends prematurely.
        foreach ($nodeId in $nodes.Keys) {
            $node = $nodes[$nodeId]
            if ($node.Level -lt 1) { continue }
            if ($intentionalRoots.Contains($nodeId)) { continue }

            $hasManager = (-not [string]::IsNullOrWhiteSpace($node.ManagerId)) -and
                          $nodes.ContainsKey($node.ManagerId)

            if (-not $hasManager) {
                $nodeName = if ($node.Identity) { $node.Identity.Name } else { $nodeId }
                $childCount = @($node.Children).Count
                $gaps.Add(@{
                    Type        = 'OrphanedBranch'
                    IdentityId  = $nodeId
                    Name        = $nodeName
                    ChildCount  = $childCount
                    Impact      = "Branch ends prematurely -- $childCount report(s) under this node lack full chain"
                })
                [void]$nodeIdsWithGaps.Add($nodeId)
            }
        }

        # --- Gap Type 5: SupplementConflict ---
        # If the merged tree has conflict records, surface them as gaps.
        if ($OrgTree.ContainsKey('Conflicts') -and $OrgTree.Conflicts.Count -gt 0) {
            foreach ($conflict in $OrgTree.Conflicts) {
                $nodeName = $conflict.IdentityEmail
                if ($conflict.ContainsKey('NodeId') -and $nodes.ContainsKey($conflict.NodeId)) {
                    $cNode = $nodes[$conflict.NodeId]
                    if ($cNode.Identity) { $nodeName = $cNode.Identity.Name }
                }
                $gaps.Add(@{
                    Type            = 'SupplementConflict'
                    IdentityId      = if ($conflict.ContainsKey('NodeId')) { $conflict.NodeId } else { $conflict.IdentityEmail }
                    Name            = $nodeName
                    ISCManager      = $conflict.ISCManagerId
                    SupplementManager = $conflict.SupplementMgr
                    Resolution      = $conflict.Resolution
                    Impact          = "ISC and supplement disagree on manager (resolved: $($conflict.Resolution))"
                })
                if ($conflict.ContainsKey('NodeId')) {
                    [void]$nodeIdsWithGaps.Add($conflict.NodeId)
                }
            }
        }

        # --- Gap Type 6: CircularReference ---
        # Re-walk chains to detect any cycles not caught by Build-SPOrgTree.
        $checkedForCycles = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($nodeId in $nodes.Keys) {
            if ($checkedForCycles.Contains($nodeId)) { continue }

            $current = $nodeId
            $path    = [System.Collections.Generic.List[string]]::new()

            while ($true) {
                if ($path.Contains($current)) {
                    # Cycle found -- report the node where the cycle starts
                    $nodeName = if ($nodes[$current].Identity) { $nodes[$current].Identity.Name } else { $current }
                    $gaps.Add(@{
                        Type       = 'CircularReference'
                        IdentityId = $current
                        Name       = $nodeName
                        Impact     = 'Infinite loop in manager chain -- reports cannot be generated'
                    })
                    [void]$nodeIdsWithGaps.Add($current)
                    break
                }

                $path.Add($current)
                [void]$checkedForCycles.Add($current)

                $cn = $nodes[$current]
                $mgrId = $cn.ManagerId
                if ([string]::IsNullOrWhiteSpace($mgrId) -or -not $nodes.ContainsKey($mgrId)) {
                    break
                }
                $current = $mgrId
            }
        }

        # --- Build Summary ---
        $totalNodes   = $nodes.Count
        $gapNodeCount = $nodeIdsWithGaps.Count
        $completeCount = $totalNodes - $gapNodeCount
        $gapRate = if ($totalNodes -gt 0) {
            [math]::Round(($gapNodeCount / $totalNodes) * 100, 1)
        } else { 0.0 }

        $summary = @{
            Total    = $totalNodes
            Complete = $completeCount
            Gaps     = $gapNodeCount
            GapRate  = $gapRate
        }

        # --- Build Recommendations ---
        $recommendations = [System.Collections.Generic.List[string]]::new()

        $noMgrGaps = @($gaps | Where-Object { $_.Type -eq 'NoManager' })
        if ($noMgrGaps.Count -gt 0) {
            $recommendations.Add("Provide org chart supplement CSV for $($noMgrGaps.Count) identit$(if ($noMgrGaps.Count -eq 1) { 'y' } else { 'ies' }) with no manager")
            foreach ($g in $noMgrGaps) {
                $recommendations.Add("  - Contact HR to populate manager field for $($g.Name) ($($g.IdentityId))")
            }
        }

        $shallowGaps = @($gaps | Where-Object { $_.Type -eq 'ShallowChain' })
        if ($shallowGaps.Count -gt 0) {
            $recommendations.Add("$($shallowGaps.Count) manager chain(s) are too shallow for full leadership reporting")
            foreach ($g in $shallowGaps) {
                $recommendations.Add("  - Extend chain above $($g.Name) (current depth: $($g.Depth), needed: $MinChainDepth)")
            }
        }

        $emailGaps = @($gaps | Where-Object { $_.Type -eq 'MissingEmail' })
        if ($emailGaps.Count -gt 0) {
            $recommendations.Add("$($emailGaps.Count) leader(s) have no email address -- reports cannot be emailed")
            foreach ($g in $emailGaps) {
                $recommendations.Add("  - Add email for $($g.Name) ($($g.IdentityId))")
            }
        }

        $orphanGaps = @($gaps | Where-Object { $_.Type -eq 'OrphanedBranch' })
        if ($orphanGaps.Count -gt 0) {
            $recommendations.Add("$($orphanGaps.Count) orphaned branch(es) -- managers without a manager above them")
            foreach ($g in $orphanGaps) {
                $recommendations.Add("  - Assign a manager for $($g.Name) ($($g.IdentityId)) or add to supplement CSV")
            }
        }

        $conflictGaps = @($gaps | Where-Object { $_.Type -eq 'SupplementConflict' })
        if ($conflictGaps.Count -gt 0) {
            $recommendations.Add("$($conflictGaps.Count) supplement conflict(s) -- ISC and supplement disagree on manager assignments")
            $recommendations.Add("  - Review Config/org-chart-supplement.csv and reconcile with ISC data")
        }

        $cycleGaps = @($gaps | Where-Object { $_.Type -eq 'CircularReference' })
        if ($cycleGaps.Count -gt 0) {
            $recommendations.Add("$($cycleGaps.Count) circular reference(s) detected -- fix manager assignments immediately")
            foreach ($g in $cycleGaps) {
                $recommendations.Add("  - Break cycle at $($g.Name) ($($g.IdentityId))")
            }
        }

        if ($gaps.Count -eq 0) {
            $recommendations.Add('No gaps detected -- org tree is complete for leadership reporting')
        }

        Write-SPLog -Message "Get-SPOrgChartGaps: Found $($gaps.Count) gap(s) across $gapNodeCount node(s) ($gapRate% gap rate)" `
            -Severity $(if ($gaps.Count -gt 0) { 'WARN' } else { 'INFO' }) `
            -Component 'SP.DeltaCertQueries' -Action 'Get-SPOrgChartGaps' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Gaps            = @($gaps.ToArray())
                Summary         = $summary
                Recommendations = @($recommendations.ToArray())
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPOrgChartGaps failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Get-SPOrgChartGaps' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPDeltaManagersForSources {
    <#
    .SYNOPSIS
        Returns a hashtable of all unique managers who have direct reports with
        accounts on the specified AD source IDs.
    .DESCRIPTION
        Used by Invoke-SPDeltaCertFullRun to determine which managers should
        receive a MANAGER-type full certification campaign.

        Queries GET /v3/search/identities with filters that narrow to active
        identities who have accounts on the monitored source IDs and who have a
        manager assignment in ISC. Extracts the unique manager IDs and resolves
        their display names.

        The same ExcludeLifecycleStates, ExcludeIdentityIds, and
        ExcludeDisplayNamePatterns filters applied by Get-SPDeltaAffectedIdentities
        are applied here for consistency.

        IMPORTANT -- ISC API ceiling:
          The /v3/search/identities filter supports 'accounts.source.id in (...)' for
          source-level scoping. If that filter is not indexed or returns errors on the
          tenant, the function falls back to fetching all active identities and
          filtering client-side by source ID from the accounts array.

    .PARAMETER SourceIds
        Array of SailPoint ISC source IDs to scope to. If empty, all active
        identities with any manager are included (not recommended for large tenants).
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ managerId = ManagerName }  # keyed by manager identity ID
            Error   = $string
        }
    .EXAMPLE
        $mgrs = Get-SPDeltaManagersForSources -SourceIds @('src-abc123')
        foreach ($mgrId in $mgrs.Data.Keys) {
            "Manager: $($mgrs.Data[$mgrId]) ($mgrId)"
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SourceIds = @(),

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $srcLabel = if ($SourceIds.Count -gt 0) { $SourceIds -join ',' } else { '(all)' }
    Write-SPLog -Message "Get-SPDeltaManagersForSources: SourceIds='$srcLabel'" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
        -CorrelationID $CorrelationID

    try {
        # Load exclusion config (fail-safe to hardcoded defaults)
        $excludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
        $excludeDisplayNamePatterns = @()
        $excludeIdentityIds         = @()
        $maxPerPage                 = 250

        try {
            $cfg = Get-SPConfig
            if ($null -ne $cfg -and $null -ne $cfg.PSObject.Properties['DeltaCert'] -and
                $null -ne $cfg.DeltaCert) {
                $dc = $cfg.DeltaCert
                if ($dc.PSObject.Properties.Name -contains 'ExcludeLifecycleStates' -and
                    $null -ne $dc.ExcludeLifecycleStates) {
                    $excludeLifecycleStates = @($dc.ExcludeLifecycleStates)
                }
                if ($dc.PSObject.Properties.Name -contains 'ExcludeDisplayNamePatterns' -and
                    $null -ne $dc.ExcludeDisplayNamePatterns) {
                    $excludeDisplayNamePatterns = @($dc.ExcludeDisplayNamePatterns)
                }
                if ($dc.PSObject.Properties.Name -contains 'ExcludeIdentityIds' -and
                    $null -ne $dc.ExcludeIdentityIds) {
                    $excludeIdentityIds = @($dc.ExcludeIdentityIds)
                }

                # Optional per-page override for full-cert identity search
                if ($null -ne $dc.PSObject.Properties['FullCert'] -and
                    $null -ne $dc.FullCert -and
                    $dc.FullCert.PSObject.Properties.Name -contains 'MaxIdentitiesPerPage' -and
                    [int]$dc.FullCert.MaxIdentitiesPerPage -gt 0) {
                    $maxPerPage = [int]$dc.FullCert.MaxIdentitiesPerPage
                }
            }
        } catch { }

        $excludeIdSet = if ($excludeIdentityIds.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new([string[]]$excludeIdentityIds)
        } else { $null }

        $sourceSet = if ($SourceIds.Count -gt 0) {
            [System.Collections.Generic.HashSet[string]]::new($SourceIds)
        } else { $null }

        # Pagination ceiling (reuse Api.MaxPaginationPages from config)
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # Attempt server-side source filter first. If the filter is unsupported,
        # fall back to fetching all active identities with a manager.
        $useServerSideSourceFilter = ($SourceIds.Count -gt 0)
        $allIdentities = [System.Collections.Generic.List[object]]::new()
        $offset  = 0
        $pageNum = 0

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached at $maxPages pages while retrieving identity list for full-cert manager resolution."
                Write-SPLog -Message $errMsg -Severity ERROR `
                    -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
                    -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $maxPerPage.ToString()
                'offset' = $offset.ToString()
            }

            # Build server-side filter. The 'manager.id is present' filter selects
            # identities that have any manager assignment.
            if ($useServerSideSourceFilter) {
                $srcFilterParts = $SourceIds | ForEach-Object { "`"$_`"" }
                $queryParams['filters'] = "manager.id is present and attributes.cloudLifecycleState ne `"terminated`" and accounts.source.id in ($($srcFilterParts -join ','))"
            } else {
                $queryParams['filters'] = 'manager.id is present'
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/search/identities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                # Server-side source filter may not be supported by tenant -- fall back
                if ($useServerSideSourceFilter) {
                    Write-SPLog -Message "Server-side source filter unsupported or failed ($($result.Error)). Falling back to client-side source filtering." `
                        -Severity WARN -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
                        -CorrelationID $CorrelationID
                    $useServerSideSourceFilter = $false
                    $offset  = 0
                    $pageNum = 0
                    $allIdentities.Clear()
                    continue
                }
                else {
                    $errMsg = "Identity search failed at page $($pageNum): $($result.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR `
                        -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
                        -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and
                $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($identity in $page) { $allIdentities.Add($identity) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) identities (running total: $($allIdentities.Count))" `
                -Severity DEBUG -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
                -CorrelationID $CorrelationID

            $offset += $maxPerPage
        } while ($page.Count -ge $maxPerPage)

        Write-SPLog -Message "Retrieved $($allIdentities.Count) candidate identities for full-cert manager resolution" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
            -CorrelationID $CorrelationID

        # Extract unique manager IDs, applying exclusion filters
        # Key: managerId, Value: manager display name (best resolved from any subordinate record)
        $managerMap = @{}

        foreach ($identity in $allIdentities) {

            # Explicit identity exclusion
            $identId = ''
            if ($null -ne $identity.PSObject.Properties['id'] -and
                -not [string]::IsNullOrWhiteSpace($identity.id)) {
                $identId = [string]$identity.id
            }
            if ([string]::IsNullOrWhiteSpace($identId)) { continue }
            if ($null -ne $excludeIdSet -and $excludeIdSet.Contains($identId)) { continue }

            # Lifecycle state exclusion
            $lcs = ''
            if ($null -ne $identity.PSObject.Properties['attributes'] -and
                $null -ne $identity.attributes -and
                $null -ne $identity.attributes.PSObject.Properties['cloudLifecycleState'] -and
                -not [string]::IsNullOrWhiteSpace($identity.attributes.cloudLifecycleState)) {
                $lcs = [string]$identity.attributes.cloudLifecycleState
            }
            if (-not [string]::IsNullOrWhiteSpace($lcs) -and
                $excludeLifecycleStates.Count -gt 0 -and $lcs -in $excludeLifecycleStates) {
                continue
            }

            # Display name exclusion
            $displayName = ''
            foreach ($prop in @('displayName', 'name')) {
                if ($null -ne $identity.PSObject.Properties[$prop] -and
                    -not [string]::IsNullOrWhiteSpace($identity.$prop)) {
                    $displayName = [string]$identity.$prop
                    break
                }
            }
            if ($excludeDisplayNamePatterns.Count -gt 0 -and
                -not [string]::IsNullOrWhiteSpace($displayName)) {
                $isExcluded = $false
                foreach ($pattern in $excludeDisplayNamePatterns) {
                    if (-not [string]::IsNullOrWhiteSpace($pattern) -and
                        $displayName -match $pattern) {
                        $isExcluded = $true
                        break
                    }
                }
                if ($isExcluded) { continue }
            }

            # Client-side source filter (only needed when server-side filter is not active)
            if (-not $useServerSideSourceFilter -and $null -ne $sourceSet) {
                $hasMatchingSource = $false
                if ($null -ne $identity.PSObject.Properties['accounts'] -and
                    $null -ne $identity.accounts) {
                    $accts = @($identity.accounts)
                    foreach ($acct in $accts) {
                        $acctSrcId = ''
                        foreach ($prop in @('sourceId', 'source_id')) {
                            if ($null -ne $acct.PSObject.Properties[$prop] -and
                                -not [string]::IsNullOrWhiteSpace($acct.$prop)) {
                                $acctSrcId = [string]$acct.$prop
                                break
                            }
                        }
                        if ([string]::IsNullOrWhiteSpace($acctSrcId) -and
                            $null -ne $acct.PSObject.Properties['source'] -and
                            $null -ne $acct.source -and
                            $null -ne $acct.source.PSObject.Properties['id'] -and
                            -not [string]::IsNullOrWhiteSpace($acct.source.id)) {
                            $acctSrcId = [string]$acct.source.id
                        }
                        if ($sourceSet.Contains($acctSrcId)) {
                            $hasMatchingSource = $true
                            break
                        }
                    }
                }
                if (-not $hasMatchingSource) { continue }
            }

            # Extract manager
            $managerId   = ''
            $managerName = ''
            if ($null -ne $identity.PSObject.Properties['manager'] -and
                $null -ne $identity.manager) {
                $mgr = $identity.manager
                if ($null -ne $mgr.PSObject.Properties['id'] -and
                    -not [string]::IsNullOrWhiteSpace($mgr.id)) {
                    $managerId = [string]$mgr.id
                }
                foreach ($prop in @('displayName', 'name')) {
                    if ($null -ne $mgr.PSObject.Properties[$prop] -and
                        -not [string]::IsNullOrWhiteSpace($mgr.$prop)) {
                        $managerName = [string]$mgr.$prop
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($managerId)) { continue }

            # Add or update manager entry (prefer a non-empty display name)
            if (-not $managerMap.ContainsKey($managerId)) {
                $managerMap[$managerId] = $managerName
            }
            elseif ([string]::IsNullOrWhiteSpace($managerMap[$managerId]) -and
                    -not [string]::IsNullOrWhiteSpace($managerName)) {
                $managerMap[$managerId] = $managerName
            }
        }

        Write-SPLog -Message "Get-SPDeltaManagersForSources: Found $($managerMap.Count) unique manager(s) with staff on monitored source(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaManagersForSources' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $managerMap; Error = $null }
    }
    catch {
        $errMsg = "Get-SPDeltaManagersForSources failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
            -Action 'Get-SPDeltaManagersForSources' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPDeltaGrantEvents',
    'Get-SPDeltaAffectedIdentities',
    'Group-SPDeltaByManager',
    'Get-SPDeltaCertStaleCertifications',
    'Get-SPDeltaIdentityDetail',
    'Build-SPOrgTree',
    'Import-SPOrgChartSupplement',
    'Merge-SPOrgTreeWithSupplement',
    'Show-SPOrgTree',
    'Show-SPCampaignOrgPreview',
    'Show-SPReportDistributionPreview',
    'Export-SPOrgChartHtml',
    'Resolve-SPIdentityBand',
    'Get-SPOrgChartGaps',
    'Get-SPDeltaManagersForSources'
)
