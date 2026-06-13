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

    Dependencies: SP.Core (Get-SPConfig, Write-SPLog) and SP.Api (Invoke-SPApiRequest).
    These must be loaded before SP.IdentityService. The project pattern is caller-handles-order
    so RequiredModules is NOT declared here.

.NOTES
    Module: SP.Shared / SP.IdentityService
    Version: 1.0.0
#>

Set-StrictMode -Version 1

# ---------------------------------------------------------------------------
# Module-scope identity caches
# ---------------------------------------------------------------------------

# In-memory identity cache keyed by identity ID -- avoids redundant API calls
# within a session.
$script:IdentityCache = @{}

# Persistent (disk-backed) identity-cache state. $script:_IdentityCachedAt records
# the CachedAt timestamp per identity so resolutions can be aged out (org movement)
# and persisted across runs; the disk warm-load happens once per session. Only
# successfully resolved (Found=true) identities are persisted -- transient misses
# stay session-only.
$script:_IdentityCachedAt   = @{}
$script:_IdentityDiskLoaded = $false

# In-memory email/attribute-to-identity cache keyed by "field:value" -- avoids
# duplicate search API calls when multiple records reference the same user.
$script:EmailToIdentityCache = @{}

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

function Import-SPIdentityCacheFromDisk {
    <#
    .SYNOPSIS
        Warms the in-memory identity cache from disk once per session.
    .DESCRIPTION
        Reads identities.jsonl, keeps the most recent non-expired record per identity ID,
        then compacts the file (dedupe + prune) in one rewrite. Only runs once per session
        (guarded by $script:_IdentityDiskLoaded).
    #>
    [CmdletBinding()]
    param()

    if ($script:_IdentityDiskLoaded) { return }
    $script:_IdentityDiskLoaded = $true
    $info = Get-SPIdentityCacheInfo
    if ($null -eq $info.File -or -not (Test-Path $info.File)) { return }
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
            $script:IdentityCache[$id]     = $detail
            $script:_IdentityCachedAt[$id] = $latest[$id].CachedAt
            [void]$sb.AppendLine((@{ IdentityId = $id; CachedAt = $latest[$id].CachedAt.ToString('o'); Detail = $detail } | ConvertTo-Json -Depth 6 -Compress))
        }
        Write-SPHtmlFile -Path $info.File -Content $sb.ToString()
    } catch { }
}

function Save-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Appends a resolved identity to the disk cache.
    .DESCRIPTION
        Only persists successful (Found=true) resolutions. The warm-load compacts
        and deduplicates per session.
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
        $script:_IdentityCachedAt[$IdentityId] = $now
        $dir = Split-Path -Parent $info.File
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
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

    # Warm the persistent (disk) cache into memory once per session, then check memory.
    Import-SPIdentityCacheFromDisk

    if ($script:IdentityCache.ContainsKey($IdentityId)) {
        return $script:IdentityCache[$IdentityId]
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

        $script:IdentityCache[$IdentityId] = $resolved
        Save-SPIdentityCacheEntry -IdentityId $IdentityId -Detail $resolved
        return $resolved
    }
    catch {
        Write-SPLog `
            -Message "Get-SPIdentityDetail failed for '$IdentityId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.IdentityService' -Action 'Get-SPIdentityDetail' `
            -CorrelationID $CorrelationID
        $script:IdentityCache[$IdentityId] = $emptyResult
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

    # Check cache first
    $cacheKey = "${AttributeField}:$($AttributeValue.ToLower())"
    if ($script:EmailToIdentityCache.ContainsKey($cacheKey)) {
        return $script:EmailToIdentityCache[$cacheKey]
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
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
            return $emptyResult
        }

        # POST /v3/search returns an array
        $hits = @($result.Data)
        if ($hits.Count -eq 0) {
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
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
            $script:EmailToIdentityCache[$cacheKey] = $emptyResult
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

        $script:EmailToIdentityCache[$cacheKey] = $found
        return $found
    }
    catch {
        Write-SPLog -Message "Search-SPIdentityByEmail failed for '$AttributeValue': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.IdentityService' -Action 'Search-SPIdentityByEmail' `
            -CorrelationID $CorrelationID
        $script:EmailToIdentityCache[$cacheKey] = $emptyResult
        return $emptyResult
    }
}

function Set-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Stores an identity detail in the in-memory cache (and optionally disk).
    .DESCRIPTION
        Unconditionally stores the detail in the in-memory identity cache. If
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
    $script:IdentityCache[$IdentityId] = $Detail
    if ($Detail.Found) {
        Save-SPIdentityCacheEntry -IdentityId $IdentityId -Detail $Detail
    }
}

function Get-SPIdentityCacheEntry {
    <#
    .SYNOPSIS
        Returns a cached identity entry without making an API call.
    .DESCRIPTION
        Reads from the in-memory identity cache only. Returns $null if the identity
        has not been resolved yet. Callers use this to peek at cached data (e.g. for
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
    if ($script:IdentityCache.ContainsKey($IdentityId)) {
        return $script:IdentityCache[$IdentityId]
    }
    return $null
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
    if (-not $DiskOnly) {
        $script:IdentityCache.Clear()
        $script:_IdentityCachedAt.Clear()
        $script:EmailToIdentityCache.Clear()
        $script:_IdentityDiskLoaded = $false
        Write-Host "  Identity memory cache cleared." -ForegroundColor DarkGray
    }
    if (-not $MemoryOnly) {
        try {
            $info = Get-SPIdentityCacheInfo
            if ($null -ne $info.File -and (Test-Path $info.File)) {
                Remove-Item $info.File -Force -ErrorAction SilentlyContinue
                Write-Host "  Identity disk cache cleared." -ForegroundColor DarkGray
            }
        } catch { }
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
