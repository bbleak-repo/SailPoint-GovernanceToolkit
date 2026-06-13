#Requires -Version 5.1
<#
.SYNOPSIS
    SP.IdentityService -- shared identity resolution and caching for all toolkit modules.
.DESCRIPTION
    Consolidates identity-related functions that were independently implemented across
    SP.DeltaCertQueries and SP.DisconnectedAppRunner. Provides a single, consistent
    API for resolving ISC identities by ID or email, with both in-memory and disk-backed
    caching.

    Functions:
        Get-SPIdentityDetail         - Resolve identity ID to name/email/manager/active status
        Search-SPIdentityByEmail     - Search identity by email/attribute value
        Clear-SPIdentityCache        - Clear memory and/or disk identity caches
        Get-SPIdentityCacheInfo      - Returns cache file path and TTL from config
        Import-SPIdentityCacheFromDisk - Warm-load disk cache once per session
        Save-SPIdentityCacheEntry    - Append a resolved identity to the disk cache

    Storage engine: SP.CacheService provides the in-memory cache stores. Disk
    persistence uses the original JSONL format (IdentityId/CachedAt/Detail) for
    backward compatibility. Two SP.CacheService stores are used:
        - 'SPIdentity'     : identity details keyed by identity ID (with TTL)
        - 'SPEmailLookup'  : email/attribute search results (no TTL, memory-only)

    Dependencies: SP.Core (Get-SPConfig, Write-SPLog) and SP.Api (Invoke-SPApiRequest).
    These must be loaded before SP.IdentityService. SP.CacheService must also be
    loaded (handled by SP.Shared.psd1 NestedModules ordering).

.NOTES
    Module: SP.Shared / SP.IdentityService
    Version: 2.0.0
#>

Set-StrictMode -Version 1

# ---------------------------------------------------------------------------
# SP.CacheService-backed identity stores
# ---------------------------------------------------------------------------
# Stores are initialised lazily (via _EnsureSPIdentityStore) because config is
# not available at module-load time. Two stores:
#   SPIdentity    -- identity detail keyed by ID, with TTL, no DiskPath
#                    (disk persistence uses the legacy JSONL format)
#   SPEmailLookup -- email/attribute search results, no TTL, memory-only
#
# $script:IdentityCache is kept as a compatibility alias pointing at the
# SP.CacheService store's Items hashtable. External tests that use
# InModuleScope to poke at $script:IdentityCache will continue to work
# because they are mutating the same hashtable object.
# ---------------------------------------------------------------------------

$script:_SPIdentityStoreReady = $false
$script:_IdentityDiskLoaded   = $false

# Compatibility aliases -- initialised to empty hashtables; replaced by the
# SP.CacheService store's Items hashtable once _EnsureSPIdentityStore runs.
$script:IdentityCache         = @{}
$script:_IdentityCachedAt     = @{}
$script:EmailToIdentityCache  = @{}

function _EnsureSPIdentityStore {
    <#
    .SYNOPSIS
        Lazily creates the SPIdentity and SPEmailLookup cache stores.
    .DESCRIPTION
        Called before any cache access. Creates SP.CacheService stores on first
        invocation and wires $script:IdentityCache to point at the store Items
        hashtable for backward-compatible InModuleScope access.

        Any entries that external callers wrote directly to $script:IdentityCache
        before this function ran are migrated into the new store so they are not
        lost (this supports InModuleScope test patterns).
    #>
    if ($script:_SPIdentityStoreReady) { return }

    # Capture any pre-existing entries (e.g. from InModuleScope in tests)
    $preExisting      = $script:IdentityCache
    $preExistingEmail = $script:EmailToIdentityCache

    # Create (or re-create) the SPIdentity store -- no DiskPath because disk
    # persistence uses the legacy format via Save-SPIdentityCacheEntry.
    # TtlMinutes=0 (no in-memory expiry) matches the original behavior where
    # items never expired during a session. TTL is applied only during disk
    # import (Import-SPIdentityCacheFromDisk prunes entries older than config TTL).
    $store = New-SPCacheStore -Name 'SPIdentity' -TtlMinutes 0 -TrackStats

    # Migrate any pre-existing entries into the new store
    if ($null -ne $preExisting -and $preExisting.Count -gt 0) {
        foreach ($key in @($preExisting.Keys)) {
            $store.Items[$key]      = $preExisting[$key]
            $store.Timestamps[$key] = Get-Date
        }
    }

    # Wire the compatibility aliases to the store's internal hashtables so
    # InModuleScope assignments from external tests mutate the right object.
    $script:IdentityCache     = $store.Items
    $script:_IdentityCachedAt = $store.Timestamps

    # SPEmailLookup: memory-only, no TTL, no disk
    $emailStore = New-SPCacheStore -Name 'SPEmailLookup'

    # Migrate pre-existing email entries
    if ($null -ne $preExistingEmail -and $preExistingEmail.Count -gt 0) {
        foreach ($key in @($preExistingEmail.Keys)) {
            $emailStore.Items[$key]      = $preExistingEmail[$key]
            $emailStore.Timestamps[$key] = Get-Date
        }
    }

    $script:EmailToIdentityCache = $emailStore.Items

    $script:_SPIdentityStoreReady = $true
}

# ---------------------------------------------------------------------------
# Internal cache helpers
# ---------------------------------------------------------------------------

function Get-SPIdentityCacheInfo {
    <#
    .SYNOPSIS
        Returns the disk cache file path and TTL from toolkit config.
    .DESCRIPTION
        Persistent identity-cache file (absolute -- Audit.CachePath is toolkit-root-resolved
        by Get-SPConfig) plus TTL. Default 1440 min (24h): fast, but an org move surfaces
        next day. Override via Audit.IdentityCacheTtlMinutes.
    .OUTPUTS
        [hashtable] @{ File = [string|null]; TtlMin = [int] }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $file = $null; $ttl = 1440
    try {
        $cfg = Get-SPConfig
        $dir = $null
        if ($null -ne $cfg.PSObject.Properties['Audit']) {
            if ($null -ne $cfg.Audit.PSObject.Properties['CachePath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Audit.CachePath)) { $dir = [string]$cfg.Audit.CachePath }
            elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) { $dir = Join-Path ([string]$cfg.Audit.OutputPath) '.cache' }
            if ($null -ne $cfg.Audit.PSObject.Properties['IdentityCacheTtlMinutes'] -and
                $null -ne $cfg.Audit.IdentityCacheTtlMinutes) { $ttl = [int]$cfg.Audit.IdentityCacheTtlMinutes }
        }
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (-not [System.IO.Path]::IsPathRooted($dir)) {
                $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
                $dir  = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
            }
            $file = Join-Path $dir 'identities.jsonl'
        }
    } catch { $file = $null }
    return @{ File = $file; TtlMin = $ttl }
}

function _WarnIfCacheDirectoryInsecure {
    <#
    .SYNOPSIS
        Checks cache directory permissions and warns if overly permissive.
    .DESCRIPTION
        Lightweight ACL check run once per session during Import-SPIdentityCacheFromDisk.
        On Windows: warns if Everyone, BUILTIN\Users, or Authenticated Users has Read access.
        On macOS/Linux: warns if group or other has read permission.
        Logs via Write-SPLog at WARN severity but never blocks execution.
    #>
    param([string]$DirPath)
    if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path $DirPath)) { return }
    try {
        if ($IsWindows -or [System.Environment]::OSVersion.Platform -eq 'Win32NT') {
            # On Windows: check if Everyone or Users has access
            $acl = Get-Acl $DirPath
            foreach ($rule in $acl.Access) {
                $id = $rule.IdentityReference.Value
                if ($id -match 'Everyone|BUILTIN\\Users|Authenticated Users' -and $rule.FileSystemRights -match 'Read') {
                    Write-SPLog -Message "Cache directory '$DirPath' is readable by '$id' -- consider restricting access for PII protection" `
                        -Severity WARN -Component 'SP.IdentityService' -Action '_WarnIfCacheDirectoryInsecure'
                    return
                }
            }
        } else {
            # macOS/Linux: check if group/other has read
            $mode = (Get-Item $DirPath).UnixMode
            if ($null -ne $mode -and $mode -match '.{4}r|.{7}r') {
                Write-SPLog -Message "Cache directory '$DirPath' may be readable by group/other -- consider restricting access for PII protection" `
                    -Severity WARN -Component 'SP.IdentityService' -Action '_WarnIfCacheDirectoryInsecure'
            }
        }
    } catch { }
}

function Import-SPIdentityCacheFromDisk {
    <#
    .SYNOPSIS
        Warms the in-memory identity cache from disk once per session.
    .DESCRIPTION
        Reads identities.jsonl (legacy format: IdentityId/CachedAt/Detail per line),
        keeps the most recent non-expired record per identity ID, then compacts the
        file (dedupe + prune) in one rewrite. Only runs once per session (guarded by
        $script:_IdentityDiskLoaded).

        Loaded entries are stored in the SPIdentity cache store via Set-SPCachedItem
        with -NoPersist (bulk load -- no per-item disk append).
    #>
    [CmdletBinding()]
    param()

    if ($script:_IdentityDiskLoaded) { return }
    $script:_IdentityDiskLoaded = $true

    _EnsureSPIdentityStore

    $info = Get-SPIdentityCacheInfo
    if ($null -eq $info.File -or -not (Test-Path $info.File)) { return }

    # One-time permission check on the cache directory
    $cacheDir = Split-Path -Parent $info.File
    _WarnIfCacheDirectoryInsecure -DirPath $cacheDir

    try {
        $now = Get-Date
        $latest = @{}
        Get-Content $info.File | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            try {
                $rec = $_ | ConvertFrom-Json
                $rid = [string]$rec.IdentityId
                $rat = [datetime]::Parse([string]$rec.CachedAt)
                if (-not [string]::IsNullOrWhiteSpace($rid) -and ($now - $rat).TotalMinutes -lt $info.TtlMin) {
                    if (-not $latest.ContainsKey($rid) -or $rat -gt $latest[$rid].CachedAt) {
                        $latest[$rid] = @{ Detail = $rec.Detail; CachedAt = $rat }
                    }
                }
            } catch { }
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $sb = New-Object System.Text.StringBuilder
        foreach ($id in $latest.Keys) {
            $d = $latest[$id].Detail
            $detail = @{
                IdentityId          = $id
                DisplayName         = [string]$d.DisplayName
                ManagerId           = [string]$d.ManagerId
                ManagerName         = [string]$d.ManagerName
                IsActive            = [bool]$d.IsActive
                Found               = [bool]$d.Found
                CloudLifecycleState = [string]$d.CloudLifecycleState
                Email               = [string]$d.Email
                JobLevel            = [string]$d.JobLevel
            }
            # Store in SP.CacheService (NoPersist -- we handle disk compaction below)
            Set-SPCachedItem -Store 'SPIdentity' -Key $id -Value $detail -NoPersist
            [void]$sb.AppendLine((@{ IdentityId = $id; CachedAt = $latest[$id].CachedAt.ToString('o'); Detail = $detail } | ConvertTo-Json -Depth 6 -Compress))
        }
        # Atomic write: write to .tmp file, then replace original to avoid
        # corruption if the process crashes mid-compaction.
        $tmpFile = "$($info.File).tmp"
        Write-SPHtmlFile -Path $tmpFile -Content $sb.ToString()
        if (Test-Path $info.File) { Remove-Item $info.File -Force }
        Move-Item -Path $tmpFile -Destination $info.File -Force
    } catch { }
}

function Save-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Appends a resolved identity to the disk cache.
    .DESCRIPTION
        Only persists successful (Found=true) resolutions. The warm-load compacts
        and deduplicates per session.

        Disk persistence uses the legacy JSONL format (IdentityId/CachedAt/Detail)
        for backward compatibility with existing identities.jsonl files.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID.
    .PARAMETER Detail
        The resolved identity hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IdentityId,

        [Parameter(Mandatory)]
        [hashtable]$Detail
    )

    if ($null -eq $Detail -or -not $Detail.Found) { return }
    $info = Get-SPIdentityCacheInfo
    if ($null -eq $info.File) { return }
    try {
        $now = Get-Date
        $dir = Split-Path -Parent $info.File
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
        # Legacy JSONL format for backward compatibility
        $rec = @{ IdentityId = $IdentityId; CachedAt = $now.ToString('o'); Detail = $Detail }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($info.File, (($rec | ConvertTo-Json -Depth 6 -Compress) + "`r`n"), $utf8NoBom)
    } catch { }
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Get-SPIdentityDetail {
    <#
    .SYNOPSIS
        Resolves an identity ID to its display name, email, manager, and active status.
    .DESCRIPTION
        Calls GET /v3/search/identities/{id} once per unique ID per session.
        Caches the result (including failures) so repeated lookups do not re-call the API.
        Requires sp:search:read scope.

        Results include: IdentityId, DisplayName, ManagerId, ManagerName, IsActive, Found,
        CloudLifecycleState, Email, JobLevel.

        Uses both in-memory and disk-backed caching (identities.jsonl) with a configurable
        TTL (Audit.IdentityCacheTtlMinutes, default 24h).
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{IdentityId; DisplayName; ManagerId; ManagerName; IsActive; Found;
                       CloudLifecycleState; Email; JobLevel}
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

    # Ensure SP.CacheService stores exist, then warm from disk once per session.
    _EnsureSPIdentityStore
    Import-SPIdentityCacheFromDisk

    # Check the SPIdentity cache store (includes TTL awareness)
    $cached = Get-SPCachedItem -Store 'SPIdentity' -Key $IdentityId
    if ($null -ne $cached) {
        return $cached
    }

    Write-SPLog -Message "Resolving identity details for '$IdentityId'" `
        -Severity DEBUG -Component 'SP.IdentityService' -Action 'Get-SPIdentityDetail' `
        -CorrelationID $CorrelationID

    try {
        # NOTE: GET /v3/identities/{id} does not exist in the ISC v3 API.
        # Use GET /v3/search/identities/{id} which returns the IdentityDocument
        # schema: manager.id, manager.name, attributes.cloudLifecycleState, displayName.
        # Requires sp:search:read scope.
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/search/identities/$IdentityId" `
            -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            # Transient miss -- cache in memory only, do not persist to disk
            Set-SPCachedItem -Store 'SPIdentity' -Key $IdentityId -Value $emptyResult -NoPersist
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

        # Extract job level / band attribute for band classification
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

        # Store in SP.CacheService (NoPersist -- disk uses legacy format below)
        Set-SPCachedItem -Store 'SPIdentity' -Key $IdentityId -Value $resolved -NoPersist
        Save-SPIdentityCacheEntry -IdentityId $IdentityId -Detail $resolved
        return $resolved
    }
    catch {
        Write-SPLog `
            -Message "Get-SPIdentityDetail failed for '$IdentityId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.IdentityService' -Action 'Get-SPIdentityDetail' `
            -CorrelationID $CorrelationID
        # Transient miss -- cache in memory only, do not persist to disk
        Set-SPCachedItem -Store 'SPIdentity' -Key $IdentityId -Value $emptyResult -NoPersist
        return $emptyResult
    }
}

function Search-SPIdentityByEmail {
    <#
    .SYNOPSIS
        Searches ISC for an identity by email or username via POST /v3/search.
    .DESCRIPTION
        Uses the ISC search API to find an identity matching the given attribute
        value. Searches by email first (attributes.email field), with optional
        username fallback (name field). Requires sp:search:read scope.

        Results are cached per attribute value for the session to avoid
        redundant API calls when multiple delta records reference the same user.
    .PARAMETER AttributeValue
        The value to search for (email address or username).
    .PARAMETER AttributeField
        The ISC search field to query. Default: 'attributes.email'.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{Found=$bool; IdentityId=$string; DisplayName=$string}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AttributeValue,

        [Parameter()]
        [string]$AttributeField = 'attributes.email',

        [Parameter()]
        [string]$CorrelationID
    )

    $emptyResult = @{
        Found       = $false
        IdentityId  = ''
        DisplayName = ''
    }

    _EnsureSPIdentityStore

    # Check SPEmailLookup cache store first
    $cacheKey = "${AttributeField}:$($AttributeValue.ToLower())"
    $cached = Get-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey
    if ($null -ne $cached) {
        return $cached
    }

    Write-SPLog -Message "Searching ISC for identity: $AttributeField='$AttributeValue'" `
        -Severity DEBUG -Component 'SP.IdentityService' -Action 'Search-SPIdentityByEmail' `
        -CorrelationID $CorrelationID

    try {
        # Escape double-quotes in the search value
        $escapedValue = $AttributeValue -replace '"', '\"'

        $searchBody = @{
            indices = @('identities')
            query   = @{ query = "${AttributeField}:`"$escapedValue`"" }
            limit   = 1
        }

        $result = Invoke-SPApiRequest -Method POST -Endpoint '/search' `
            -Body $searchBody -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            Set-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey -Value $emptyResult
            return $emptyResult
        }

        # POST /v3/search returns an array
        $hits = @($result.Data)
        if ($hits.Count -eq 0) {
            Set-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey -Value $emptyResult
            return $emptyResult
        }

        $identity = $hits[0]

        # Extract identity ID
        $identityId = ''
        if ($null -ne $identity.PSObject.Properties['id'] -and
            -not [string]::IsNullOrWhiteSpace($identity.id)) {
            $identityId = [string]$identity.id
        }

        if ([string]::IsNullOrWhiteSpace($identityId)) {
            Set-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey -Value $emptyResult
            return $emptyResult
        }

        # Extract display name
        $displayName = ''
        foreach ($prop in @('displayName', 'name')) {
            if ($null -ne $identity.PSObject.Properties[$prop] -and
                -not [string]::IsNullOrWhiteSpace($identity.$prop)) {
                $displayName = [string]$identity.$prop
                break
            }
        }

        $found = @{
            Found       = $true
            IdentityId  = $identityId
            DisplayName = $displayName
        }

        Set-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey -Value $found
        return $found
    }
    catch {
        Write-SPLog -Message "Search-SPIdentityByEmail failed for '$AttributeValue': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.IdentityService' -Action 'Search-SPIdentityByEmail' `
            -CorrelationID $CorrelationID
        Set-SPCachedItem -Store 'SPEmailLookup' -Key $cacheKey -Value $emptyResult
        return $emptyResult
    }
}

function Set-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Stores an identity detail in the in-memory cache (and optionally disk).
    .DESCRIPTION
        Unconditionally stores the detail in the SPIdentity cache store. If
        Found=true, also appends to the disk cache via Save-SPIdentityCacheEntry.
        This allows both found and not-found results to be cached in memory for
        session-scoped deduplication while only persisting successful resolutions.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID.
    .PARAMETER Detail
        The resolved identity hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IdentityId,

        [Parameter(Mandatory)]
        [hashtable]$Detail
    )
    _EnsureSPIdentityStore
    Set-SPCachedItem -Store 'SPIdentity' -Key $IdentityId -Value $Detail -NoPersist
    if ($Detail.Found) {
        Save-SPIdentityCacheEntry -IdentityId $IdentityId -Detail $Detail
    }
}

function Get-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Returns a cached identity entry without making an API call.
    .DESCRIPTION
        Reads from the SPIdentity cache store. Returns $null if the identity has
        not been resolved yet. Callers use this to peek at cached data (e.g. for
        band attribution, email lookup) without triggering an API call.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to look up.
    .OUTPUTS
        [hashtable|null] The cached identity detail or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId
    )
    _EnsureSPIdentityStore
    return Get-SPCachedItem -Store 'SPIdentity' -Key $IdentityId
}

function Clear-SPIdentityCache {
    <#
    .SYNOPSIS
        Clears the identity-detail cache (memory and/or disk).
    .DESCRIPTION
        Forces the next identity resolution to re-query ISC -- use this to validate
        org movement (manager changes / reorg) before the TTL would expire entries.
    .PARAMETER DiskOnly
        Clear the on-disk identities.jsonl only (keep the session memory cache).
    .PARAMETER MemoryOnly
        Clear the in-memory cache only (keep the disk file).
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [switch]$DiskOnly,
        [Parameter()] [switch]$MemoryOnly
    )
    $clearedTargets = @()
    if (-not $DiskOnly) {
        _EnsureSPIdentityStore
        # Clear-SPCacheStore calls .Clear() on Items/Timestamps in-place,
        # so $script:IdentityCache / $script:EmailToIdentityCache aliases
        # (which point at the same hashtable objects) are automatically cleared.
        Clear-SPCacheStore -Store 'SPIdentity'
        Clear-SPCacheStore -Store 'SPEmailLookup'
        $script:_IdentityDiskLoaded = $false
        $clearedTargets += 'memory'
        Write-Host "  Identity memory cache cleared." -ForegroundColor DarkGray
    }
    if (-not $MemoryOnly) {
        try {
            $info = Get-SPIdentityCacheInfo
            if ($null -ne $info.File -and (Test-Path $info.File)) {
                Remove-Item $info.File -Force -ErrorAction SilentlyContinue
                $clearedTargets += 'disk'
                Write-Host "  Identity disk cache cleared." -ForegroundColor DarkGray
            }
        } catch { }
    }
    if ($clearedTargets.Count -gt 0) {
        $targetDesc = $clearedTargets -join ' + '
        Write-SPLog -Message "Identity cache cleared ($targetDesc)" `
            -Severity INFO -Component 'SP.IdentityService' -Action 'Clear-SPIdentityCache'
    }
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Get-SPIdentityDetail',
    'Search-SPIdentityByEmail',
    'Set-SPIdentityCacheEntry',
    'Get-SPIdentityCacheEntry',
    'Clear-SPIdentityCache',
    'Get-SPIdentityCacheInfo',
    'Import-SPIdentityCacheFromDisk',
    'Save-SPIdentityCacheEntry'
)
