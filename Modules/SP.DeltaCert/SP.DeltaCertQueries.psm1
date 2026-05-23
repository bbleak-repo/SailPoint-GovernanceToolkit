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

        $resolved = @{
            IdentityId          = $IdentityId
            DisplayName         = $displayName
            ManagerId           = $managerId
            ManagerName         = $managerName
            IsActive            = $isActive
            Found               = $true
            CloudLifecycleState = $cloudLifecycleState
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

                $grantEvents.Add([PSCustomObject]@{
                    IdentityId      = $identityId
                    SourceId        = $itemSourceId
                    ActivityId      = if ($null -ne $activity.PSObject.Properties['id']) { [string]$activity.id } else { '' }
                    ActivityCreated = if ($null -ne $createdDate) { $createdDate.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
                    ItemType        = $itemType
                    ItemValue       = $itemValue
                    ItemName        = $itemName
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
        Finds active delta cert certifications that have been open longer than a threshold.
    .DESCRIPTION
        Searches for active delta cert campaigns matching a name prefix, retrieves all
        certifications for each campaign, and filters to certifications where:
          - signed is null (not completed by the reviewer)
          - created date is older than StaleHours

        Returns enough context per stale certification for downstream escalation
        (F-07: cert ID, reviewer ID, campaign name, hours open).
    .PARAMETER CampaignNamePrefix
        Prefix used to find delta cert campaigns. Default: 'AD Delta Cert'.
    .PARAMETER StaleHours
        Number of hours with no reviewer action before a certification is considered
        stale. Default: 24.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @([PSCustomObject] with CertificationId, CampaignId, CampaignName,
                        ReviewerIdentityId, ReviewerName, HoursOpen, ReviewerClassification)
            Error   = $string
        }
    .EXAMPLE
        $result = Get-SPDeltaCertStaleCertifications -CampaignNamePrefix 'AD Delta Cert' -StaleHours 24
        $result.Data | Format-Table CertificationId, ReviewerName, HoursOpen
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$StaleHours = 24,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPDeltaCertStaleCertifications: Prefix='$CampaignNamePrefix' StaleHours=$StaleHours" `
        -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Find active delta cert campaigns
        $searchResult = Search-SPCampaigns -Keyword $CampaignNamePrefix -Status @('ACTIVE') `
            -CorrelationID $CorrelationID

        if (-not $searchResult.Success) {
            $errMsg = "Campaign search failed: $($searchResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.DeltaCertQueries' `
                -Action 'Get-SPDeltaCertStaleCertifications' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $activeCampaigns = @($searchResult.Data)

        if ($activeCampaigns.Count -eq 0) {
            Write-SPLog -Message "No active campaigns found matching '$CampaignNamePrefix'" `
                -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
                -CorrelationID $CorrelationID
            return @{ Success = $true; Data = @(); Error = $null }
        }

        Write-SPLog -Message "Found $($activeCampaigns.Count) active campaign(s) -- retrieving certifications" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
            -CorrelationID $CorrelationID

        $nowUtc        = (Get-Date).ToUniversalTime()
        $staleCutoff   = $nowUtc.AddHours(-$StaleHours)
        $staleCerts    = [System.Collections.Generic.List[object]]::new()

        # Step 2: For each campaign, get certifications and filter
        foreach ($campaign in $activeCampaigns) {
            $campaignId   = $campaign.id
            $campaignName = $campaign.name

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
                # Skip completed certifications (signed is not null)
                $signedValue = $null
                if ($cert.PSObject.Properties.Name -contains 'signed') {
                    $signedValue = $cert.signed
                }
                if ($null -ne $signedValue -and -not [string]::IsNullOrWhiteSpace([string]$signedValue)) {
                    continue
                }

                # Check created date against stale threshold
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

                if ($certCreated -ge $staleCutoff) {
                    continue
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

                $staleCerts.Add([PSCustomObject]@{
                    CertificationId        = [string]$cert.id
                    CampaignId             = $campaignId
                    CampaignName           = $campaignName
                    ReviewerIdentityId     = $reviewerId
                    ReviewerName           = $reviewerName
                    HoursOpen              = $hoursOpen
                    ReviewerClassification = $reviewerClassification
                })
            }
        }

        Write-SPLog -Message "Found $($staleCerts.Count) stale certification(s) across $($activeCampaigns.Count) active campaign(s)" `
            -Severity INFO -Component 'SP.DeltaCertQueries' -Action 'Get-SPDeltaCertStaleCertifications' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $staleCerts.ToArray(); Error = $null }
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

#endregion

Export-ModuleMember -Function @(
    'Get-SPDeltaGrantEvents',
    'Get-SPDeltaAffectedIdentities',
    'Group-SPDeltaByManager',
    'Get-SPDeltaCertStaleCertifications',
    'Get-SPDeltaIdentityDetail',
    'Build-SPOrgTree'
)
