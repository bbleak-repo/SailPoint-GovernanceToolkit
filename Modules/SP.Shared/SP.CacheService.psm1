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
    .PARAMETER DiskPath
        Optional path to a JSONL file for disk-backed persistence. When set,
        Set-SPCachedItem auto-appends entries and Get-SPCachedItem triggers
        a lazy import on first access.
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
        [string]$DiskPath
    )

    $store = @{
        Name           = $Name
        TtlMinutes     = $TtlMinutes
        Items          = @{}
        Timestamps     = @{}
        DiskPath       = $DiskPath
        DiskLoaded     = $false
        DiskAutoAppend = ($null -ne $DiskPath -and $DiskPath -ne '')
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
    if ($s.ContainsKey('DiskPath') -and -not [string]::IsNullOrWhiteSpace($s.DiskPath) -and
        $s.ContainsKey('DiskLoaded') -and -not $s.DiskLoaded) {
        if (Test-Path $s.DiskPath) {
            $ttl = if ($s.TtlMinutes -gt 0) { $s.TtlMinutes } else { 0 }
            Import-SPCacheStore -Store $Store -Path $s.DiskPath -TtlMinutes $ttl | Out-Null
        }
        $s.DiskLoaded = $true
    }

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

        $jsonArgs = @{ InputObject = $rec; Depth = 6 }
        if ($Compress) { $jsonArgs['Compress'] = $true }
        [void]$sb.AppendLine((ConvertTo-Json @jsonArgs))
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

    # Rename .tmp to target (overwrite if exists)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    Rename-Item -Path $tmpPath -NewName (Split-Path -Leaf $Path) -Force

    return @{ Before = $before; After = $after; Pruned = $pruned }
}

#endregion Public Functions
