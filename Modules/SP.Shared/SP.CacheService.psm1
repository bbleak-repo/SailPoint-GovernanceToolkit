#Requires -Version 5.1
<#
.SYNOPSIS
    SP.CacheService -- generic in-memory key-value cache with optional TTL.
.DESCRIPTION
    Provides a lightweight, module-scoped cache registry that any toolkit module
    can use instead of rolling its own $script:*Cache + $script:_*CachedAt
    timestamp-tracking pattern.

    Each named "store" is a hashtable with:
        - Name          [string]  human-readable label
        - TtlMinutes    [int]     0 = no expiry; >0 = auto-expire after N minutes
        - Items         [hashtable]  key -> value
        - Timestamps    [hashtable]  key -> [datetime] when the value was stored

    Stores are auto-created on first use by Get/Set if the store name has not
    been registered via New-SPCacheStore.

    Functions:
        New-SPCacheStore   - Create a named store with optional TTL
        Get-SPCachedItem   - Retrieve an item; returns $null if expired or missing
        Set-SPCachedItem   - Store an item with automatic timestamp
        Test-SPCacheValid  - Check if an item exists and is not expired
        Clear-SPCacheStore - Flush all entries from a named store

    No dependencies on SP.Core, SP.Api, or any other toolkit module.

.NOTES
    Module: SP.Shared / SP.CacheService
    Version: 1.0.0
#>

Set-StrictMode -Version 1

# ---------------------------------------------------------------------------
# Module-scope registry of cache stores.
# ---------------------------------------------------------------------------
$script:CacheStores = @{}

#region Internal Helpers

function _EnsureStore {
    <#
    .SYNOPSIS
        Returns the store hashtable for the given name, creating it (TtlMinutes=0)
        if it does not yet exist.
    #>
    param([string]$Name)

    if (-not $script:CacheStores.ContainsKey($Name)) {
        $script:CacheStores[$Name] = @{
            Name       = $Name
            TtlMinutes = 0
            Items      = @{}
            Timestamps = @{}
        }
    }
    return $script:CacheStores[$Name]
}

function _IsExpired {
    <#
    .SYNOPSIS
        Returns $true if the item in the given store is past its TTL.
    #>
    param(
        [hashtable]$Store,
        [string]$Key,
        [int]$OverrideTtl = -1
    )

    $ttl = if ($OverrideTtl -ge 0) { $OverrideTtl } else { $Store.TtlMinutes }

    # TTL of 0 means no expiry
    if ($ttl -le 0) { return $false }

    if (-not $Store.Timestamps.ContainsKey($Key)) { return $true }

    $elapsed = ((Get-Date) - [datetime]$Store.Timestamps[$Key]).TotalMinutes
    return ($elapsed -ge $ttl)
}

#endregion Internal Helpers

#region Public Functions

function New-SPCacheStore {
    <#
    .SYNOPSIS
        Creates (or re-initialises) a named cache store.
    .DESCRIPTION
        Registers a new cache store in the module-scope registry. If a store
        with the same name already exists it is replaced (flushed).
    .PARAMETER Name
        Unique name for the store (e.g. 'IdentityCache', 'SourceNameCache').
    .PARAMETER TtlMinutes
        Time-to-live in minutes for items stored without an explicit override.
        0 (default) means items never expire.
    .OUTPUTS
        [hashtable] The store object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [int]$TtlMinutes = 0
    )

    $store = @{
        Name       = $Name
        TtlMinutes = $TtlMinutes
        Items      = @{}
        Timestamps = @{}
    }
    $script:CacheStores[$Name] = $store
    return $store
}

function Get-SPCachedItem {
    <#
    .SYNOPSIS
        Retrieves an item from a named cache store.
    .DESCRIPTION
        Returns the cached value if the key exists and has not expired.
        Returns $null if the key is missing, the store does not exist,
        or the item's TTL has elapsed.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Key
        The lookup key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $s = _EnsureStore -Name $Store

    if (-not $s.Items.ContainsKey($Key)) { return $null }

    # Check per-item TTL first, fall back to store TTL
    $overrideTtl = -1
    if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($Key)) {
        $overrideTtl = $s['ItemTtl'][$Key]
    }

    if (_IsExpired -Store $s -Key $Key -OverrideTtl $overrideTtl) {
        # Expired -- evict the entry
        $s.Items.Remove($Key)
        $s.Timestamps.Remove($Key)
        if ($s.ContainsKey('ItemTtl')) { $s['ItemTtl'].Remove($Key) }
        return $null
    }

    return $s.Items[$Key]
}

function Set-SPCachedItem {
    <#
    .SYNOPSIS
        Stores an item in a named cache store with an automatic timestamp.
    .DESCRIPTION
        Writes the value under the given key, recording the current time.
        If the store does not exist it is auto-created with TtlMinutes=0.
        An optional per-item TtlMinutes override can be supplied; when
        omitted the store's default TTL applies.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Key
        The lookup key.
    .PARAMETER Value
        The value to cache. Any type is accepted.
    .PARAMETER TtlMinutes
        Per-item TTL override (minutes). When not specified, the store's
        default TtlMinutes is used during retrieval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        $Value,

        [Parameter()]
        [int]$TtlMinutes = -1
    )

    $s = _EnsureStore -Name $Store

    $s.Items[$Key]      = $Value
    $s.Timestamps[$Key] = Get-Date

    # If a per-item TTL was given, store it as item-level metadata so
    # _IsExpired can pick it up. We encode it in the Timestamps entry
    # by keeping a secondary hashtable; but to keep the design simple
    # and avoid a breaking schema change, we store per-item overrides
    # in a parallel hashtable on the store.
    if ($TtlMinutes -ge 0) {
        if (-not $s.ContainsKey('ItemTtl')) {
            $s['ItemTtl'] = @{}
        }
        $s['ItemTtl'][$Key] = $TtlMinutes
    }
}

function Test-SPCacheValid {
    <#
    .SYNOPSIS
        Checks whether a cached item exists and has not expired.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Key
        The lookup key.
    .OUTPUTS
        [bool] $true if the item is present and within its TTL; $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $s = _EnsureStore -Name $Store

    if (-not $s.Items.ContainsKey($Key)) { return $false }

    # Check per-item TTL first, fall back to store TTL
    $overrideTtl = -1
    if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($Key)) {
        $overrideTtl = $s['ItemTtl'][$Key]
    }

    if (_IsExpired -Store $s -Key $Key -OverrideTtl $overrideTtl) { return $false }

    return $true
}

function Clear-SPCacheStore {
    <#
    .SYNOPSIS
        Flushes all entries from a named cache store.
    .DESCRIPTION
        Removes every key/value pair and timestamp from the store but
        keeps the store registration (Name, TtlMinutes) intact.
        If the store does not exist, this is a no-op.
    .PARAMETER Store
        Name of the cache store to flush.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store
    )

    if (-not $script:CacheStores.ContainsKey($Store)) { return }

    $s = $script:CacheStores[$Store]
    $s.Items.Clear()
    $s.Timestamps.Clear()
    if ($s.ContainsKey('ItemTtl')) { $s['ItemTtl'].Clear() }
}

#endregion Public Functions
