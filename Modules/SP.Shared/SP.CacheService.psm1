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

function _EnsureDiskLoaded {
    <#
    .SYNOPSIS
        Performs the one-time lazy disk import for a disk-backed store.
    .DESCRIPTION
        Shared by Get-SPCachedItem AND Test-SPCacheValid so both entry points see
        disk-persisted entries. Previously only Get did the lazy import, so the
        Test-then-Get pattern reported $false on a fresh session even when the
        disk file held valid data.
    #>
    param([hashtable]$Store, [string]$StoreName)

    if ($Store.ContainsKey('DiskPath') -and -not [string]::IsNullOrWhiteSpace($Store.DiskPath) -and
        $Store.ContainsKey('DiskLoaded') -and -not $Store.DiskLoaded) {
        if (Test-Path $Store.DiskPath) {
            $ttl = if ($Store.TtlMinutes -gt 0) { $Store.TtlMinutes } else { 0 }
            Import-SPCacheStore -Store $StoreName -Path $Store.DiskPath -TtlMinutes $ttl | Out-Null
        }
        $Store.DiskLoaded = $true
    }
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
    .PARAMETER DiskPath
        Optional path to a JSONL file for disk-backed persistence. When set,
        Set-SPCachedItem auto-appends entries and Get-SPCachedItem triggers
        a lazy import on first access.
    .PARAMETER TrackStats
        When set, enables hit/miss tracking on the store. Get-SPCachedItem
        will increment HitCount on successful retrieval and MissCount on
        miss or expired item.
    .OUTPUTS
        [hashtable] The store object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [int]$TtlMinutes = 0,

        [Parameter()]
        [string]$DiskPath,

        [Parameter()]
        [switch]$TrackStats
    )

    $store = @{
        Name           = $Name
        TtlMinutes     = $TtlMinutes
        Items          = @{}
        Timestamps     = @{}
        DiskPath       = $DiskPath
        DiskLoaded     = $false
        DiskAutoAppend = ($null -ne $DiskPath -and $DiskPath -ne '')
        TrackStats     = [bool]$TrackStats
        HitCount       = 0
        MissCount      = 0
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

        When the store has a DiskPath and has not yet been loaded from disk,
        triggers a lazy Import-SPCacheStore on first access.
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

    # Lazy disk load: if the store has a DiskPath and has not been loaded yet,
    # import from disk before checking the key.
    _EnsureDiskLoaded -Store $s -StoreName $Store

    if (-not $s.Items.ContainsKey($Key)) {
        if ($s.ContainsKey('TrackStats') -and $s.TrackStats) { $s.MissCount++ }
        return $null
    }

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
        if ($s.ContainsKey('TrackStats') -and $s.TrackStats) { $s.MissCount++ }
        return $null
    }

    if ($s.ContainsKey('TrackStats') -and $s.TrackStats) { $s.HitCount++ }
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

        When the store has a DiskPath and DiskAutoAppend is true, the entry
        is automatically appended to the JSONL file unless -NoPersist is set.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Key
        The lookup key.
    .PARAMETER Value
        The value to cache. Any type is accepted.
    .PARAMETER TtlMinutes
        Per-item TTL override (minutes). When not specified, the store's
        default TtlMinutes is used during retrieval.
    .PARAMETER NoPersist
        When set, suppresses the automatic disk append even if the store
        has a DiskPath configured. Use during bulk operations where you
        plan to Export at the end.
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
        [int]$TtlMinutes = -1,

        [Parameter()]
        [switch]$NoPersist
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
    elseif ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($Key)) {
        # Re-set without an explicit TTL: drop any stale per-item override so the new value
        # uses the store default rather than silently inheriting the old item TTL.
        [void]$s['ItemTtl'].Remove($Key)
    }

    # Auto-append to disk if the store has a DiskPath and DiskAutoAppend is true
    if (-not $NoPersist -and
        $s.ContainsKey('DiskAutoAppend') -and $s.DiskAutoAppend -and
        $s.ContainsKey('DiskPath') -and -not [string]::IsNullOrWhiteSpace($s.DiskPath)) {
        try {
            Add-SPCacheStoreEntry -Store $Store -Key $Key -Path $s.DiskPath
        } catch {
            # Disk failures should not crash the toolkit
        }
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

    # Same lazy disk load as Get-SPCachedItem so Test/Get agree on fresh sessions.
    _EnsureDiskLoaded -Store $s -StoreName $Store

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

        An optional -OnClear scriptblock can be provided by consumers
        that have logging capabilities (SP.CacheService has no dependency
        on SP.Core and cannot call Write-SPLog directly).
    .PARAMETER Store
        Name of the cache store to flush.
    .PARAMETER OnClear
        Optional scriptblock invoked after the store is cleared. Receives
        the store name as its first positional argument. Exceptions from
        the scriptblock are silently swallowed so logging failures never
        break cache operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter()]
        [scriptblock]$OnClear
    )

    if (-not $script:CacheStores.ContainsKey($Store)) { return }

    $s = $script:CacheStores[$Store]
    $s.Items.Clear()
    $s.Timestamps.Clear()
    if ($s.ContainsKey('ItemTtl')) { $s['ItemTtl'].Clear() }
    if ($s.ContainsKey('TrackStats') -and $s.TrackStats) {
        $s.HitCount  = 0
        $s.MissCount = 0
    }

    if ($OnClear) { try { & $OnClear $Store } catch { } }
}

# ---------------------------------------------------------------------------
# JSONL Persistence Functions
# ---------------------------------------------------------------------------

function Export-SPCacheStore {
    <#
    .SYNOPSIS
        Saves a cache store (or selected entries) to a JSONL file.
    .DESCRIPTION
        Writes each in-memory entry as a single JSON line. Each line has the
        schema: { "Key": "...", "Value": {...}, "CachedAt": "ISO8601", "TtlMinutes": N }
    .PARAMETER Store
        Name of the cache store to export.
    .PARAMETER Path
        Destination JSONL file path.
    .PARAMETER Compress
        Uses ConvertTo-Json -Compress for compact output (default: true).
    .PARAMETER Filter
        Optional scriptblock that receives the value as $_. Only entries where
        the filter returns $true are exported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [switch]$Compress = $true,

        [Parameter()]
        [scriptblock]$Filter
    )

    $s = _EnsureStore -Name $Store

    # Create parent directories if missing
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($key in $s.Items.Keys) {
        $value = $s.Items[$key]

        # Apply filter if provided -- scriptblock receives value as $_
        if ($null -ne $Filter) {
            $pass = $false
            try {
                $pass = $value | ForEach-Object $Filter
            } catch { $pass = $false }
            if (-not $pass) { continue }
        }

        $cachedAt = if ($s.Timestamps.ContainsKey($key)) {
            ([datetime]$s.Timestamps[$key]).ToString('o')
        } else {
            (Get-Date).ToString('o')
        }

        $ttlVal = $null
        if ($s.TtlMinutes -gt 0) { $ttlVal = $s.TtlMinutes }
        if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($key)) {
            $ttlVal = $s['ItemTtl'][$key]
        }

        $rec = @{
            Key        = $key
            Value      = $value
            CachedAt   = $cachedAt
            TtlMinutes = $ttlVal
        }

        # JSONL requires exactly ONE record per physical line. ConvertTo-Json WITHOUT -Compress
        # emits multi-line (pretty) JSON, which Import-SPCacheStore (reads line-by-line) silently
        # fails to parse -> every record is lost. So each record is ALWAYS written single-line,
        # regardless of the -Compress switch (kept only for call-signature back-compat).
        [void]$sb.AppendLine((ConvertTo-Json -InputObject $rec -Depth 6 -Compress))
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $utf8NoBom)
}

function Import-SPCacheStore {
    <#
    .SYNOPSIS
        Loads a JSONL file into a cache store with dedup and TTL pruning.
    .DESCRIPTION
        Reads the file line-by-line, parses JSON, keeps the newest record per
        key, and optionally prunes entries older than TtlMinutes. Populates
        the in-memory store with the loaded entries.
    .PARAMETER Store
        Name of the cache store to load into.
    .PARAMETER Path
        Source JSONL file path.
    .PARAMETER TtlMinutes
        Override TTL for pruning. Entries older than this many minutes from
        now are discarded. 0 means no pruning.
    .PARAMETER Compact
        When set, rewrites the file after loading (dedup + prune = smaller file).
    .OUTPUTS
        [hashtable] @{ Loaded = <int>; Pruned = <int>; Errors = <int> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [int]$TtlMinutes = 0,

        [Parameter()]
        [switch]$Compact
    )

    $s = _EnsureStore -Name $Store

    $loaded  = 0
    $pruned  = 0
    $errors  = 0

    if (-not (Test-Path $Path)) {
        return @{ Loaded = $loaded; Pruned = $pruned; Errors = $errors }
    }

    $now = Get-Date
    # Temporary dedup table: key -> @{ Value; CachedAt; TtlMinutes }
    $dedup = @{}

    $lines = Get-Content $Path
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $rec = $line | ConvertFrom-Json

            $key = [string]$rec.Key
            if ([string]::IsNullOrWhiteSpace($key)) {
                $errors++
                continue
            }

            # Handle PS 5.1 datetime auto-conversion: force to string first,
            # then parse back to datetime.
            $cachedAt = [datetime]::Parse([string]$rec.CachedAt)

            $recTtl = $null
            if ($null -ne $rec.TtlMinutes) {
                $recTtl = [int]$rec.TtlMinutes
            }

            # Prune expired entries
            if ($TtlMinutes -gt 0) {
                $elapsed = ($now - $cachedAt).TotalMinutes
                if ($elapsed -ge $TtlMinutes) {
                    $pruned++
                    continue
                }
            }

            # Dedup: keep newest by CachedAt
            if ($dedup.ContainsKey($key)) {
                $existing = $dedup[$key]
                if ($cachedAt -gt $existing.CachedAt) {
                    $dedup[$key] = @{ Value = $rec.Value; CachedAt = $cachedAt; TtlMinutes = $recTtl }
                    $pruned++   # the older duplicate is pruned
                } else {
                    $pruned++   # this record is older, skip it
                }
            } else {
                $dedup[$key] = @{ Value = $rec.Value; CachedAt = $cachedAt; TtlMinutes = $recTtl }
            }
        } catch {
            $errors++
        }
    }

    # Populate the in-memory store from the dedup table
    foreach ($key in $dedup.Keys) {
        $entry = $dedup[$key]
        $s.Items[$key]      = $entry.Value
        $s.Timestamps[$key] = $entry.CachedAt
        if ($null -ne $entry.TtlMinutes) {
            if (-not $s.ContainsKey('ItemTtl')) { $s['ItemTtl'] = @{} }
            $s['ItemTtl'][$key] = $entry.TtlMinutes
        }
        $loaded++
    }

    # Compact: rewrite the file with only loaded entries
    if ($Compact) {
        try {
            $sb = New-Object System.Text.StringBuilder
            foreach ($key in $dedup.Keys) {
                $entry = $dedup[$key]
                $rec = @{
                    Key        = $key
                    Value      = $entry.Value
                    CachedAt   = $entry.CachedAt.ToString('o')
                    TtlMinutes = $entry.TtlMinutes
                }
                [void]$sb.AppendLine((ConvertTo-Json -InputObject $rec -Depth 6 -Compress))
            }
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $sb.ToString(), $utf8NoBom)
        } catch {
            # Disk failures should not crash the toolkit
        }
    }

    return @{ Loaded = $loaded; Pruned = $pruned; Errors = $errors }
}

function Add-SPCacheStoreEntry {
    <#
    .SYNOPSIS
        Appends a single entry from the in-memory store to a JSONL file.
    .DESCRIPTION
        Reads the entry from the in-memory store by key and appends one
        JSONL line to the file via AppendAllText. Creates the file and
        parent directories if missing.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Key
        The key of the item to append.
    .PARAMETER Path
        JSONL file path to append to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $s = _EnsureStore -Name $Store

    if (-not $s.Items.ContainsKey($Key)) { return }

    # Create parent directories if missing
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    # Create file if missing
    if (-not (Test-Path $Path)) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, '', $utf8NoBom)
    }

    $cachedAt = if ($s.Timestamps.ContainsKey($Key)) {
        ([datetime]$s.Timestamps[$Key]).ToString('o')
    } else {
        (Get-Date).ToString('o')
    }

    $ttlVal = $null
    if ($s.TtlMinutes -gt 0) { $ttlVal = $s.TtlMinutes }
    if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($Key)) {
        $ttlVal = $s['ItemTtl'][$Key]
    }

    $rec = @{
        Key        = $Key
        Value      = $s.Items[$Key]
        CachedAt   = $cachedAt
        TtlMinutes = $ttlVal
    }

    $jsonLine = ConvertTo-Json -InputObject $rec -Depth 6 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, "$jsonLine`n", $utf8NoBom)
}

function Compress-SPCacheStore {
    <#
    .SYNOPSIS
        Compacts a store's JSONL file: dedup by key, prune expired, rewrite.
    .DESCRIPTION
        Reads the in-memory store (already deduped since it is a hashtable)
        and writes all non-expired entries to a new JSONL file. Uses an
        atomic write pattern: write to .tmp then rename to avoid corruption
        on crash.
    .PARAMETER Store
        Name of the cache store.
    .PARAMETER Path
        JSONL file path to compact.
    .OUTPUTS
        [hashtable] @{ Before = <int lines>; After = <int entries>; Pruned = <int> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $s = _EnsureStore -Name $Store

    # Count lines in the existing file
    $before = 0
    if (Test-Path $Path) {
        $existingLines = Get-Content $Path
        foreach ($ln in $existingLines) {
            if (-not [string]::IsNullOrWhiteSpace($ln)) { $before++ }
        }
    }

    # Write non-expired entries from memory
    $now     = Get-Date
    $after   = 0
    $pruned  = 0
    $sb      = New-Object System.Text.StringBuilder

    foreach ($key in $s.Items.Keys) {
        # Check per-item TTL first, fall back to store TTL
        $overrideTtl = -1
        if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($key)) {
            $overrideTtl = $s['ItemTtl'][$key]
        }

        if (_IsExpired -Store $s -Key $key -OverrideTtl $overrideTtl) {
            $pruned++
            continue
        }

        $cachedAt = if ($s.Timestamps.ContainsKey($key)) {
            ([datetime]$s.Timestamps[$key]).ToString('o')
        } else {
            $now.ToString('o')
        }

        $ttlVal = $null
        if ($s.TtlMinutes -gt 0) { $ttlVal = $s.TtlMinutes }
        if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($key)) {
            $ttlVal = $s['ItemTtl'][$key]
        }

        $rec = @{
            Key        = $key
            Value      = $s.Items[$key]
            CachedAt   = $cachedAt
            TtlMinutes = $ttlVal
        }
        [void]$sb.AppendLine((ConvertTo-Json -InputObject $rec -Depth 6 -Compress))
        $after++
    }

    # Atomic write: write to .tmp, then rename
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    $tmpPath  = "$Path.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $sb.ToString(), $utf8NoBom)

    # Atomic replace: no Remove-then-Rename gap that could lose the file if the process crashes
    # between the two. [IO.File]::Replace is atomic on NTFS (requires the destination to exist).
    if (Test-Path $Path) { [System.IO.File]::Replace($tmpPath, $Path, [NullString]::Value) }
    else { Move-Item -Path $tmpPath -Destination $Path -Force }

    return @{ Before = $before; After = $after; Pruned = $pruned }
}

# ---------------------------------------------------------------------------
# Inspection & Stats Functions
# ---------------------------------------------------------------------------

function Get-SPCacheStoreInfo {
    <#
    .SYNOPSIS
        Returns diagnostic information about a single cache store.
    .DESCRIPTION
        Provides a hashtable with item count, TTL, oldest/newest entry timestamps,
        expired count (without evicting), disk file metrics, and hit/miss stats.
        Returns $null if the store does not exist.
    .PARAMETER Store
        Name of the cache store to inspect.
    .OUTPUTS
        [hashtable] Diagnostic info or $null if the store is unknown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store
    )

    if (-not $script:CacheStores.ContainsKey($Store)) { return $null }

    $s = $script:CacheStores[$Store]

    # Item count
    $itemCount = $s.Items.Count

    # Oldest and newest entry from Timestamps
    $oldest = $null
    $newest = $null
    if ($s.Timestamps.Count -gt 0) {
        foreach ($ts in $s.Timestamps.Values) {
            $dt = [datetime]$ts
            if ($null -eq $oldest -or $dt -lt $oldest) { $oldest = $dt }
            if ($null -eq $newest -or $dt -gt $newest) { $newest = $dt }
        }
    }

    # Expired count: scan without evicting
    $expiredCount = 0
    $now = Get-Date
    if ($s.TtlMinutes -gt 0) {
        foreach ($key in @($s.Timestamps.Keys)) {
            $ttl = $s.TtlMinutes
            if ($s.ContainsKey('ItemTtl') -and $s['ItemTtl'].ContainsKey($key)) {
                $ttl = $s['ItemTtl'][$key]
            }
            if ($ttl -gt 0) {
                $elapsed = ($now - [datetime]$s.Timestamps[$key]).TotalMinutes
                if ($elapsed -ge $ttl) { $expiredCount++ }
            }
        }
    }

    # Disk metrics
    $diskPath      = if ($s.ContainsKey('DiskPath')) { $s.DiskPath } else { $null }
    $diskSizeBytes = $null
    $diskLineCount = $null
    $diskLoaded    = if ($s.ContainsKey('DiskLoaded')) { $s.DiskLoaded } else { $false }

    if (-not [string]::IsNullOrWhiteSpace($diskPath) -and (Test-Path $diskPath)) {
        try {
            $fileInfo = Get-Item $diskPath
            $diskSizeBytes = $fileInfo.Length
            $diskLineCount = 0
            $fileLines = Get-Content $diskPath
            foreach ($fl in $fileLines) {
                if (-not [string]::IsNullOrWhiteSpace($fl)) { $diskLineCount++ }
            }
        } catch {
            # Disk read failures are non-fatal
        }
    }

    # Hit/miss stats
    $hitCount  = if ($s.ContainsKey('HitCount'))  { $s.HitCount }  else { 0 }
    $missCount = if ($s.ContainsKey('MissCount')) { $s.MissCount } else { 0 }
    $total     = $hitCount + $missCount
    $hitRate   = if ($total -gt 0) {
        '{0:F1}%' -f (($hitCount / $total) * 100)
    } else {
        '0.0%'
    }

    return @{
        Name          = $s.Name
        TtlMinutes    = $s.TtlMinutes
        ItemCount     = $itemCount
        OldestEntry   = $oldest
        NewestEntry   = $newest
        ExpiredCount  = $expiredCount
        DiskPath      = $diskPath
        DiskSizeBytes = $diskSizeBytes
        DiskLineCount = $diskLineCount
        DiskLoaded    = $diskLoaded
        HitCount      = $hitCount
        MissCount     = $missCount
        HitRate       = $hitRate
    }
}

function Get-SPCacheStoreSummary {
    <#
    .SYNOPSIS
        Returns a summary table of all registered cache stores.
    .DESCRIPTION
        Returns an array of hashtables, one per registered store, with key
        metrics: Name, ItemCount, TtlMinutes, DiskPath, DiskSizeKB, HitRate.
    .OUTPUTS
        [array] Array of hashtables with store summary info.
    #>
    [CmdletBinding()]
    param()

    $results = @()

    foreach ($name in $script:CacheStores.Keys) {
        $s = $script:CacheStores[$name]

        # Disk size in KB
        $diskSizeKB = $null
        $diskPath = if ($s.ContainsKey('DiskPath')) { $s.DiskPath } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($diskPath) -and (Test-Path $diskPath)) {
            try {
                $fileInfo = Get-Item $diskPath
                $diskSizeKB = [math]::Round($fileInfo.Length / 1024, 2)
            } catch {
                # Disk read failures are non-fatal
            }
        }

        # Hit rate
        $hitCount  = if ($s.ContainsKey('HitCount'))  { $s.HitCount }  else { 0 }
        $missCount = if ($s.ContainsKey('MissCount')) { $s.MissCount } else { 0 }
        $total     = $hitCount + $missCount
        $hitRate   = if ($total -gt 0) {
            '{0:F1}%' -f (($hitCount / $total) * 100)
        } else {
            '0.0%'
        }

        $results += @{
            Name       = $s.Name
            ItemCount  = $s.Items.Count
            TtlMinutes = $s.TtlMinutes
            DiskPath   = $diskPath
            DiskSizeKB = $diskSizeKB
            HitRate    = $hitRate
        }
    }

    return $results
}

function Test-SPCacheStoreIntegrity {
    <#
    .SYNOPSIS
        Validates a cache store's JSONL file on disk.
    .DESCRIPTION
        Reads the JSONL file line by line and checks for: valid JSON per line,
        CachedAt present and parseable, duplicate keys, expired entry ratio,
        and file vs memory consistency. Returns a result hashtable with Ok
        (bool) and Findings (array of finding hashtables).
    .PARAMETER Store
        Name of the cache store to validate.
    .OUTPUTS
        [hashtable] @{ Ok = $bool; Findings = @(...) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Store
    )

    $findings = @()

    # Check store exists
    if (-not $script:CacheStores.ContainsKey($Store)) {
        $findings += @{
            Severity = 'Error'
            Code     = 'UNKNOWN_STORE'
            Message  = "Store '$Store' is not registered"
            Count    = 1
        }
        return @{ Ok = $false; Findings = $findings }
    }

    $s = $script:CacheStores[$Store]
    $diskPath = if ($s.ContainsKey('DiskPath')) { $s.DiskPath } else { $null }

    # Check DiskPath is set
    if ([string]::IsNullOrWhiteSpace($diskPath)) {
        $findings += @{
            Severity = 'Error'
            Code     = 'NO_DISK_PATH'
            Message  = "Store '$Store' has no DiskPath configured"
            Count    = 1
        }
        return @{ Ok = $false; Findings = $findings }
    }

    # Check file exists
    if (-not (Test-Path $diskPath)) {
        $findings += @{
            Severity = 'Error'
            Code     = 'FILE_NOT_FOUND'
            Message  = "Disk file not found: $diskPath"
            Count    = 1
        }
        return @{ Ok = $false; Findings = $findings }
    }

    # Read and validate each line
    $lines       = Get-Content $diskPath
    $totalLines  = 0
    $parseErrors = 0
    $cachedAtErrors = 0
    $keyCounts   = @{}
    $expiredCount = 0
    $now = Get-Date

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $totalLines++

        # Check valid JSON
        $rec = $null
        try {
            $rec = $line | ConvertFrom-Json
        } catch {
            $parseErrors++
            continue
        }

        # Check CachedAt present and parseable
        $cachedAtOk = $false
        $cachedAtDt = $null
        if ($null -ne $rec.CachedAt) {
            try {
                $cachedAtDt = [datetime]::Parse([string]$rec.CachedAt)
                $cachedAtOk = $true
            } catch {
                $cachedAtErrors++
            }
        } else {
            $cachedAtErrors++
        }

        # Track keys for duplicate detection
        $key = [string]$rec.Key
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            if (-not $keyCounts.ContainsKey($key)) {
                $keyCounts[$key] = 0
            }
            $keyCounts[$key]++
        }

        # Check expired
        if ($cachedAtOk -and $s.TtlMinutes -gt 0) {
            $elapsed = ($now - $cachedAtDt).TotalMinutes
            if ($elapsed -ge $s.TtlMinutes) { $expiredCount++ }
        }
    }

    # Report parse errors
    if ($parseErrors -gt 0) {
        $findings += @{
            Severity = 'Error'
            Code     = 'INVALID_JSON'
            Message  = "$parseErrors line(s) contain invalid JSON"
            Count    = $parseErrors
        }
    }

    # Report CachedAt errors
    if ($cachedAtErrors -gt 0) {
        $findings += @{
            Severity = 'Warn'
            Code     = 'CACHEDATPROBLEM'
            Message  = "$cachedAtErrors line(s) have missing or unparseable CachedAt"
            Count    = $cachedAtErrors
        }
    }

    # Report duplicate keys
    $dupCount = 0
    foreach ($kv in $keyCounts.GetEnumerator()) {
        if ($kv.Value -gt 1) { $dupCount += ($kv.Value - 1) }
    }
    if ($dupCount -gt 0) {
        $findings += @{
            Severity = 'Warn'
            Code     = 'DEDUP_NEEDED'
            Message  = "$dupCount duplicate key(s) found"
            Count    = $dupCount
        }
    }

    # Report expired ratio
    if ($totalLines -gt 0 -and $expiredCount -gt 0) {
        $pct = [math]::Round(($expiredCount / $totalLines) * 100, 0)
        $findings += @{
            Severity = 'Info'
            Code     = 'EXPIRED_RATIO'
            Message  = "${pct}% of entries are expired"
            Count    = $expiredCount
        }
    }

    # File vs memory consistency
    $memoryCount = $s.Items.Count
    $uniqueFileKeys = $keyCounts.Count
    if ($memoryCount -ne $uniqueFileKeys -and $s.ContainsKey('DiskLoaded') -and $s.DiskLoaded) {
        $findings += @{
            Severity = 'Warn'
            Code     = 'MEM_DISK_MISMATCH'
            Message  = "Memory has $memoryCount items but file has $uniqueFileKeys unique keys"
            Count    = [math]::Abs($memoryCount - $uniqueFileKeys)
        }
    }

    # Ok = true if no Error-level findings
    $hasError = $false
    foreach ($f in $findings) {
        if ($f.Severity -eq 'Error') { $hasError = $true; break }
    }

    return @{ Ok = (-not $hasError); Findings = $findings }
}

#endregion Public Functions
