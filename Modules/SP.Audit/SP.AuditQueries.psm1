#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Audit Query Functions
.DESCRIPTION
    Provides functions for auditing SailPoint ISC certification campaigns:
    retrieving campaigns with date filtering, fetching certifications with
    reviewer classification, pulling access review items, downloading or
    importing campaign report CSVs, and resolving provisioning events for
    specific identities.

    All HTTP calls are delegated to Invoke-SPApiRequest.  Report downloads
    that require the legacy /cc/api endpoint call Invoke-RestMethod directly
    using the bearer token from Get-SPAuthToken.

    ISC API constraints observed in this module:
      - Campaign list filtering supports: id, name, status only (no date).
        Date filtering is applied client-side on the 'created' field.
      - Bulk decide cap: 250 items.
      - Rate limit: 95 requests / 10 s.
.NOTES
    Module: SP.AuditQueries
    Version: 1.0.0
#>

# Ensure SP.Shared is loaded (provides SP.CacheService for account cache store).
$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command New-SPCacheStore -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

# Module-scope source name cache to avoid redundant API calls within a session.
$script:SourceNameCache = @{}

# Account cache backed by SP.CacheService (in-memory store 'SPAccountCache').
# $script:AccountCache is aliased to the store's Items hashtable for backward compat.
# Disk persistence (accounts.jsonl) uses the legacy format unchanged.
$script:AccountCache       = @{}
$script:_AccountCachedAt   = @{}
$script:_AccountDiskLoaded = $false

$script:_AccountStoreReady = $false

function _EnsureAccountStore {
    # Lazily initialize the SPAccountCache store via SP.CacheService.
    # After init, $script:AccountCache points to the store's Items hashtable
    # so existing code that reads/writes $script:AccountCache[$id] keeps working.
    if ($script:_AccountStoreReady) { return }
    if (-not (Get-Command New-SPCacheStore -ErrorAction Ignore)) { return }

    # Capture any pre-existing entries (from InModuleScope in tests)
    $preExisting = $script:AccountCache

    # Create the store (TtlMinutes=0 -- no in-memory expiry, same as original)
    $store = New-SPCacheStore -Name 'SPAccountCache' -TtlMinutes 0 -TrackStats

    # Migrate pre-existing entries into the new store
    if ($null -ne $preExisting -and $preExisting.Count -gt 0) {
        foreach ($key in @($preExisting.Keys)) {
            $store.Items[$key]      = $preExisting[$key]
            $store.Timestamps[$key] = Get-Date
        }
    }

    # Wire the compatibility alias to the store's Items hashtable
    $script:AccountCache = $store.Items
    $script:_AccountStoreReady = $true
}

# Initialize eagerly if SP.CacheService is already loaded.
_EnsureAccountStore

#region Internal Functions

function Get-SPAuditCacheDir {
    # Returns the ABSOLUTE cache directory, stable regardless of the caller's current
    # directory. Honors Audit.CachePath (or Audit.OutputPath\.cache); a relative value is
    # anchored to the toolkit root -- this module lives at <root>\Modules\SP.Audit, so
    # $PSScriptRoot\..\.. is <root> -- matching the path convention used elsewhere in the
    # toolkit (vault, snapshots, supplement). Without this, launching a script from a
    # subdirectory (e.g. Scripts\) would scatter the cache to <cwd>\Audit\.cache and break
    # reuse across runs.
    $dir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit']) {
            if ($null -ne $cfg.Audit.PSObject.Properties['CachePath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Audit.CachePath)) {
                $dir = [string]$cfg.Audit.CachePath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                $dir = Join-Path ([string]$cfg.Audit.OutputPath) '.cache'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\.cache' }

    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $dir))
    }
    return $dir
}

function Get-SPAuditActiveCacheTtl {
    # Active-campaign cache TTL in minutes. Honors Audit.CacheActiveTtlMinutes; default 180
    # (3h). COMPLETED campaigns ignore this (cached permanently); it only bounds ACTIVE ones.
    $ttl = 180
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit'] -and
            $null -ne $cfg.Audit.PSObject.Properties['CacheActiveTtlMinutes'] -and
            $null -ne $cfg.Audit.CacheActiveTtlMinutes) {
            $ttl = [int]$cfg.Audit.CacheActiveTtlMinutes
        }
    } catch { }
    return $ttl
}

function Add-SPItemCacheLines {
    <#
    .SYNOPSIS
        Mutex-guarded append of pre-formatted JSONL line(s) to an item-cache file (G10).
    .DESCRIPTION
        The per-cert incremental flush in Get-SPCachedCampaignItems writes to the shared
        items-<campId>.jsonl. A GUI fetch and a scheduler fetch hitting the same campaign
        concurrently can interleave their AppendAllText calls and corrupt the JSONL. This
        mirrors the proven log-writer mutex (SP.Logging.psm1): a named Mutex keyed off a
        SHA256 of the absolute file path serializes appends cross-process; the write uses
        a FileShare.ReadWrite Append stream and Encoding.UTF8.GetBytes (which never emits a
        BOM) so the existing no-BOM JSONL format is preserved byte-for-byte.
    .PARAMETER Path
        Absolute path to the items-<campId>.jsonl cache file.
    .PARAMETER Content
        The already-newline-terminated text to append (StringBuilder content unchanged).
    .OUTPUTS
        None. Throws on a hard failure so the caller's existing try/catch logs a WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )
    if ([string]::IsNullOrEmpty($Content)) { return }

    # Mutex name: stable SHA256 of the absolute file path (local session scope is
    # sufficient -- toolkit users run as themselves). SHA256 for FIPS compliance.
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))
    $mutexName = 'SP.AuditCache.' + (([System.BitConverter]::ToString($hashBytes) -replace '-').Substring(0, 40))

    $payload  = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $mutex    = $null
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        try {
            $acquired = $mutex.WaitOne(5000)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Previous holder died without releasing -- mutex is now ours.
            $acquired = $true
        }
        if (-not $acquired) {
            throw [System.IO.IOException]::new("Could not acquire item-cache mutex within 5s for $Path")
        }
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Write($payload, 0, $payload.Length)
            $fs.Flush()
        }
        finally {
            $fs.Dispose()
        }
    }
    finally {
        if ($null -ne $mutex) {
            if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
}

function Get-SPAuditEffectiveCacheTtl {
    <#
    .SYNOPSIS
        Resolves the effective ACTIVE-cache TTL for a campaign, optionally shrinking it
        as the campaign's deadline approaches (WI-8 / G5 -- opt-in, default OFF).
    .DESCRIPTION
        Returns the base ACTIVE TTL unchanged unless the opt-in "near-deadline capture"
        feature is enabled AND the campaign's deadline falls within the configured window,
        in which case the TTL is shrunk to a smaller value so the cache goes stale sooner
        and a fresher (near-final) capture is taken before the campaign closes. This makes
        work done just before close less likely to be falsely shown as pending.

        KEY INVARIANT: this helper can only ever LOWER the TTL, never raise it. With the
        feature default-OFF (or any config error), it returns the base TTL byte-for-byte,
        so existing caching behavior is unchanged; even when ON it is strictly more
        conservative (fresher cache), so nothing that currently caches stops caching.

        Opt-in config (read defensively; code defaults apply when absent) under Audit:
          NearDeadlineCapture.Enabled       [bool] default $false -- master switch.
          NearDeadlineCapture.WindowMinutes [int]  default 1440 (24h) -- how close to the
                                            deadline (in minutes) the shrink activates.
          NearDeadlineCapture.TtlMinutes    [int]  default 15 -- the shrunk TTL applied
                                            inside the window (effective = min(base, this)).
    .PARAMETER Campaign
        Campaign object. May carry a '.deadline' (ISO-8601). When absent/blank/garbage,
        the base TTL is returned unchanged.
    .PARAMETER BaseTtl
        The base ACTIVE TTL in minutes. When -1 (default) the value is resolved from
        Get-SPAuditActiveCacheTtl (config Audit.CacheActiveTtlMinutes, default 180).
    .PARAMETER Now
        Reference "now" for deadline math (injectable for tests). Defaults to Get-Date.
    .OUTPUTS
        [int] effective TTL minutes (<= base).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [object]$Campaign,
        [int]$BaseTtl = -1,
        [datetime]$Now = (Get-Date)
    )

    $base = if ($BaseTtl -ge 0) { $BaseTtl } else { Get-SPAuditActiveCacheTtl }

    # Opt-in config with defensive code defaults.
    $enabled       = $false
    $windowMinutes = 1440
    $nearTtl       = 15
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit'] -and $null -ne $cfg.Audit -and
            $null -ne $cfg.Audit.PSObject.Properties['NearDeadlineCapture'] -and
            $null -ne $cfg.Audit.NearDeadlineCapture) {
            $ndc = $cfg.Audit.NearDeadlineCapture
            if ($null -ne $ndc.PSObject.Properties['Enabled'] -and $null -ne $ndc.Enabled) {
                $enabled = [bool]$ndc.Enabled
            }
            if ($null -ne $ndc.PSObject.Properties['WindowMinutes'] -and $null -ne $ndc.WindowMinutes) {
                $windowMinutes = [int]$ndc.WindowMinutes
            }
            if ($null -ne $ndc.PSObject.Properties['TtlMinutes'] -and $null -ne $ndc.TtlMinutes) {
                $nearTtl = [int]$ndc.TtlMinutes
            }
        }
    } catch { return $base }

    if (-not $enabled) { return $base }

    # Resolve campaign deadline (mirror the [datetime]::Parse RoundtripKind pattern used
    # elsewhere in this module). No parseable deadline -> base unchanged.
    $deadline = $null
    if ($null -ne $Campaign -and $null -ne $Campaign.PSObject.Properties['deadline'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Campaign.deadline)) {
        try {
            $deadline = [datetime]::Parse([string]$Campaign.deadline,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch { $deadline = $null }
    }
    if ($null -eq $deadline) { return $base }

    $minutesToDeadline = ($deadline.ToLocalTime() - $Now).TotalMinutes
    if ($minutesToDeadline -le $windowMinutes) {
        # Inside the window (or slightly past the deadline). Shrink -- but never raise.
        $effective = [math]::Min($base, $nearTtl)
        if ($effective -lt $base) {
            Write-SPLog -Message ("Near-deadline TTL shrink: base=${base}m -> ${effective}m " +
                "(minutesToDeadline=$([math]::Round($minutesToDeadline,1)), window=${windowMinutes}m)") `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'EffectiveCacheTtl'
        }
        return $effective
    }

    return $base
}

function Get-SPAuditSourceName {
    <#
    .SYNOPSIS
        Resolves a source ID to its display name, with in-memory caching.
    .DESCRIPTION
        Calls GET /sources/{sourceId} once per unique ID per session.
        On success the name is cached; on failure the sourceId is returned
        as the fallback display value so callers always receive a string.
    .PARAMETER SourceId
        The SailPoint ISC source ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [string] Source display name, or sourceId on error.
    .EXAMPLE
        $name = Get-SPAuditSourceName -SourceId 'src-abc123' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([string])]
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

    # Return cached name immediately
    if ($script:SourceNameCache.ContainsKey($SourceId)) {
        return $script:SourceNameCache[$SourceId]
    }

    Write-SPLog -Message "Resolving source name for ID '$SourceId'" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint "/sources/$SourceId" `
            -CorrelationID $CorrelationID

        if ($result.Success -and $null -ne $result.Data) {
            $sourceName = $result.Data.name
            if ([string]::IsNullOrWhiteSpace($sourceName)) {
                $sourceName = $SourceId
            }
            $script:SourceNameCache[$SourceId] = $sourceName
            return $sourceName
        }
    }
    catch {
        Write-SPLog -Message "Get-SPAuditSourceName failed for '$SourceId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAuditSourceName' `
            -CorrelationID $CorrelationID
    }

    # Fallback: cache and return the raw ID so we do not call the API again
    $script:SourceNameCache[$SourceId] = $SourceId
    return $SourceId
}

function Get-SPAuditAccountForIdentity {
    <#
    .SYNOPSIS
        Resolves an identity ID to its primary account attributes with in-memory caching.
    .DESCRIPTION
        Calls GET /accounts?filters=identityId eq "..." once per unique identity ID per session.
        Returns sAMAccountName, userPrincipalName, mail, and nativeIdentity extracted from
        the account attributes. Prefers AD/directory accounts when multiple accounts exist,
        but falls back to the first account with attributes if no AD account is found.

        On failure or no matching account, caches and returns empty strings so the API is
        not called again for the same identity ID within the session.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries.
    .OUTPUTS
        [hashtable] @{SamAccountName; UserPrincipalName; Email; NativeIdentity} - all strings.
    .EXAMPLE
        $acct = Get-SPAuditAccountForIdentity -IdentityId 'id-abc123' -CorrelationID $cid
        $acct.UserPrincipalName
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

    # Return cached result immediately
    if ($script:AccountCache.ContainsKey($IdentityId)) {
        return $script:AccountCache[$IdentityId]
    }

    $emptyResult = @{
        SamAccountName    = ''
        UserPrincipalName = ''
        Email             = ''
        NativeIdentity    = ''
    }

    Write-SPLog -Message "Resolving account attributes for identity '$IdentityId'" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditAccountForIdentity' `
        -CorrelationID $CorrelationID

    try {
        $result = Invoke-SPApiRequest -Method GET -Endpoint '/accounts' `
            -QueryParams @{
                'filters' = "identityId eq `"$IdentityId`""
                'limit'   = '10'
            } `
            -CorrelationID $CorrelationID

        if (-not $result.Success -or $null -eq $result.Data) {
            $script:AccountCache[$IdentityId] = $emptyResult
            return $emptyResult
        }

        # Normalize: API may return array directly or object with items
        $accounts = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $accounts = $result.Data.items
        }
        if ($null -eq $accounts) { $accounts = @() }

        # Find best account: prefer one with a non-empty sAMAccountName or UPN (AD/directory),
        # fall back to first account with any attributes.
        $bestAccount = $null
        foreach ($acct in $accounts) {
            if ($null -eq $acct) { continue }
            $attrs = $acct.attributes
            if ($null -eq $attrs) { continue }

            $sam = ''
            $upn = ''
            if ($attrs.PSObject.Properties.Name -contains 'sAMAccountName' -and $null -ne $attrs.sAMAccountName) {
                $sam = [string]$attrs.sAMAccountName
            }
            if ($attrs.PSObject.Properties.Name -contains 'userPrincipalName' -and $null -ne $attrs.userPrincipalName) {
                $upn = [string]$attrs.userPrincipalName
            }

            if (-not [string]::IsNullOrWhiteSpace($sam) -or -not [string]::IsNullOrWhiteSpace($upn)) {
                $bestAccount = $acct
                break
            }

            # Keep first account with attributes as fallback
            if ($null -eq $bestAccount) {
                $bestAccount = $acct
            }
        }

        if ($null -eq $bestAccount) {
            $script:AccountCache[$IdentityId] = $emptyResult
            return $emptyResult
        }

        $attrs          = $bestAccount.attributes
        $samValue       = ''
        $upnValue       = ''
        $mailValue      = ''
        $displayValue   = ''
        $nativeValue    = if ($null -ne $bestAccount.PSObject.Properties['nativeIdentity'] -and $null -ne $bestAccount.nativeIdentity) { [string]$bestAccount.nativeIdentity } else { '' }

        if ($null -ne $attrs) {
            if ($attrs.PSObject.Properties.Name -contains 'sAMAccountName'    -and $null -ne $attrs.sAMAccountName)    { $samValue     = [string]$attrs.sAMAccountName    }
            if ($attrs.PSObject.Properties.Name -contains 'userPrincipalName' -and $null -ne $attrs.userPrincipalName) { $upnValue     = [string]$attrs.userPrincipalName }
            if ($attrs.PSObject.Properties.Name -contains 'mail'              -and $null -ne $attrs.mail)              { $mailValue    = [string]$attrs.mail              }
            if ($attrs.PSObject.Properties.Name -contains 'displayName'       -and $null -ne $attrs.displayName)       { $displayValue = [string]$attrs.displayName       }
        }

        $resolved = @{
            SamAccountName    = $samValue
            UserPrincipalName = $upnValue
            Email             = $mailValue
            NativeIdentity    = $nativeValue
        }

        $script:AccountCache[$IdentityId] = $resolved
        return $resolved
    }
    catch {
        Write-SPLog -Message "Get-SPAuditAccountForIdentity failed for '$IdentityId': $($_.Exception.Message)" `
            -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAuditAccountForIdentity' `
            -CorrelationID $CorrelationID
        $script:AccountCache[$IdentityId] = $emptyResult
        return $emptyResult
    }
}

#endregion

#region Public Functions

function Get-SPAuditCampaigns {
    <#
    .SYNOPSIS
        Retrieves certification campaigns with optional name, status, and date filters.
    .DESCRIPTION
        GETs /v3/campaigns and auto-paginates across all pages.
        Exact/starts-with name and status filters are applied server-side via the ISC
        'filters' query parameter. Date AND substring (contains) filtering are applied
        client-side: ISC does not support filtering on 'created', and its `name co` is
        unreliable (a bare contains 400s, and it is case-sensitive).

        Server-side filter operators used here:
          name eq "..."    - exact name match
          name sw "..."    - starts-with match
          status in (...)  - one or more status values
        Client-side:
          name contains    - case-insensitive substring (-CampaignNameContains)
          created date     - DaysBack / CreatedAfter / CreatedBefore
    .PARAMETER CampaignName
        Optional exact name match. Translates to: name eq "..."
    .PARAMETER CampaignNameStartsWith
        Optional starts-with name match. Translates to: name sw "..."
        Ignored if CampaignName is also specified.
    .PARAMETER CampaignNameContains
        Optional substring (contains) name match, applied CLIENT-SIDE and case-insensitively
        (campaigns are fetched by status/date, then filtered locally). Ignored if CampaignName
        or CampaignNameStartsWith is also specified. This is the recommended fuzzy filter --
        ISC's server-side `name co` 400s on a bare contains and is case-sensitive.
    .PARAMETER Status
        Optional array of status values to filter by.
        Valid values: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
        Translates to: status in ("COMPLETED","ACTIVE")
    .PARAMETER CampaignType
        Optional campaign type filter. Valid values: MANAGER, SOURCE_OWNER,
        SEARCH, ROLE_COMPOSITION. Translates to server-side: type eq "MANAGER".
    .PARAMETER CreatedAfter
        Optional lower bound for the campaign 'created' timestamp. Only campaigns
        created on or after this date are returned. Takes precedence over DaysBack
        when both are specified. Compared using .ToUniversalTime().
    .PARAMETER CreatedBefore
        Optional upper bound for the campaign 'created' timestamp. Only campaigns
        created on or before this date are returned. Takes precedence over DaysBack
        when both are specified. Compared using .ToUniversalTime().
    .PARAMETER DaysBack
        Number of calendar days to look back from now when filtering campaigns
        by their 'created' timestamp. Filtering is client-side. Default: 30.
        Set to 0 or a negative number to disable date filtering.
        Ignored when CreatedAfter or CreatedBefore is specified.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([campaign objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaigns -Status 'COMPLETED','ACTIVE' -DaysBack 90
        $campaigns = $result.Data
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CampaignName 'Q1 2026 Access Review' -DaysBack 0
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CampaignType 'SOURCE_OWNER' -DaysBack 90
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'
    .EXAMPLE
        $result = Get-SPAuditCampaigns -CreatedAfter '2026-01-01' -Status 'COMPLETED'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignName,

        [Parameter()]
        [string]$CampaignNameStartsWith,

        [Parameter()]
        [string]$CampaignNameContains,

        [Parameter()]
        [string[]]$Status,

        [Parameter()]
        [ValidateSet('MANAGER', 'SOURCE_OWNER', 'SEARCH', 'ROLE_COMPOSITION')]
        [string]$CampaignType,

        [Parameter()]
        [DateTime]$CreatedAfter,

        [Parameter()]
        [DateTime]$CreatedBefore,

        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Determine date filtering mode: explicit range vs DaysBack
    $useExplicitRange = ($PSBoundParameters.ContainsKey('CreatedAfter') -or $PSBoundParameters.ContainsKey('CreatedBefore'))

    $dateLogPart = if ($useExplicitRange) {
        "CreatedAfter='$CreatedAfter', CreatedBefore='$CreatedBefore'"
    } else {
        "DaysBack=$DaysBack"
    }

    Write-SPLog -Message "Getting audit campaigns: Name='$CampaignName', NameSW='$CampaignNameStartsWith', NameCO='$CampaignNameContains', Status='$($Status -join ',')', Type='$CampaignType', $dateLogPart" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # Build server-side filter expression
        $filterParts = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($CampaignName)) {
            $escaped = $CampaignName.Replace('"', '\"')
            $filterParts.Add("name eq `"$escaped`"")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) {
            $escaped = $CampaignNameStartsWith.Replace('"', '\"')
            $filterParts.Add("name sw `"$escaped`"")
        }
        # NOTE: -CampaignNameContains is applied CLIENT-SIDE (after the fetch, below), NOT as a
        # server-side `name co` filter. ISC /v3/campaigns rejects a *bare* `name co` (with no
        # other indexed predicate) with HTTP 400, and `co` is case-sensitive -- both of which
        # bit the GUI (Audit/Hierarchical/Adaptive). Client-side -like is case-insensitive and
        # never 400s, matching the "contains" expectation everywhere.

        if ($null -ne $Status -and $Status.Count -gt 0) {
            $quotedStatuses = ($Status | ForEach-Object { "`"$_`"" }) -join ','
            $filterParts.Add("status in ($quotedStatuses)")
        }

        if (-not [string]::IsNullOrWhiteSpace($CampaignType)) {
            $filterParts.Add("type eq `"$CampaignType`"")
        }

        # NOTE: detail=FULL is intentionally omitted from the list query.
        # ISC /v3/campaigns list does not reliably support detail=FULL across
        # all tenant configurations and returns 400 on some. The audit pipeline
        # only needs id, name, status, created, deadline -- all present in the
        # default (SLIM) response. Full campaign detail is fetched individually
        # via Get-SPCampaign -Full only when a single-campaign deep-read is needed.
        $queryParams = @{
            'limit'  = '250'
            'offset' = '0'
        }

        if ($filterParts.Count -gt 0) {
            $queryParams['filters'] = ($filterParts -join ' and ')
        }

        # Auto-paginate
        $allCampaigns = [System.Collections.Generic.List[object]]::new()
        $pageSize     = 250
        $offset       = 0
        $pageNum      = 0

        # M2: pagination ceiling.
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
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allCampaigns.Count) campaigns). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams['offset'] = $offset.ToString()

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCampaigns failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize: API may wrap items or return array directly
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($campaign in $page) {
                    $allCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) campaigns (running total: $($allCampaigns.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCampaigns.Count) campaigns before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
            -CorrelationID $CorrelationID

        # Client-side date filter on 'created' field
        # CreatedAfter/CreatedBefore take precedence over DaysBack when specified.
        # All comparisons use .ToUniversalTime() to avoid Kind mismatch (PS7 auto-converts
        # ISO 8601 strings to DateTime with Kind=Utc; local cutoffs have Kind=Local).
        $filteredCampaigns = [System.Collections.Generic.List[object]]::new()

        $applyDateFilter = $false
        $rangeAfterUtc   = $null
        $rangeBeforeUtc  = $null
        $dateFilterLabel  = ''

        if ($useExplicitRange) {
            $applyDateFilter = $true
            if ($PSBoundParameters.ContainsKey('CreatedAfter')) {
                $rangeAfterUtc = $CreatedAfter.ToUniversalTime()
            }
            if ($PSBoundParameters.ContainsKey('CreatedBefore')) {
                $rangeBeforeUtc = $CreatedBefore.ToUniversalTime()
            }
            $dateFilterLabel = "CreatedAfter=$rangeAfterUtc, CreatedBefore=$rangeBeforeUtc"
        }
        elseif ($DaysBack -gt 0) {
            $applyDateFilter = $true
            $rangeAfterUtc  = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
            $dateFilterLabel = "last $DaysBack days (cutoff=$rangeAfterUtc)"
        }

        if ($applyDateFilter) {
            foreach ($campaign in $allCampaigns) {
                $createdRaw = $campaign.created
                if ($null -eq $createdRaw) {
                    # No created date -- include to avoid silent exclusion
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = ([datetime]$createdRaw).ToUniversalTime()
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate.ToUniversalTime()
                    }
                }

                if ($null -eq $createdDate) {
                    $filteredCampaigns.Add($campaign)
                    continue
                }

                # Apply range bounds
                $include = $true
                if ($null -ne $rangeAfterUtc -and $createdDate -lt $rangeAfterUtc) {
                    $include = $false
                }
                if ($include -and $null -ne $rangeBeforeUtc -and $createdDate -gt $rangeBeforeUtc) {
                    $include = $false
                }

                if ($include) {
                    $filteredCampaigns.Add($campaign)
                }
            }

            Write-SPLog -Message "Date filter ($dateFilterLabel): $($allCampaigns.Count) -> $($filteredCampaigns.Count) campaigns" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($campaign in $allCampaigns) { $filteredCampaigns.Add($campaign) }
            Write-SPLog -Message "Date filtering disabled (DaysBack=$DaysBack). Returning all $($filteredCampaigns.Count) campaigns." `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' `
                -CorrelationID $CorrelationID
        }

        # Client-side, case-insensitive name-contains filter (-CampaignNameContains). Applied
        # here -- like the date filter above -- because ISC /v3/campaigns handles `name co`
        # unreliably (400 on a bare contains; case-sensitive when it does run). PowerShell
        # -like is case-insensitive; wildcards in the keyword are escaped so a literal match.
        if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $kwEsc     = [System.Management.Automation.WildcardPattern]::Escape($CampaignNameContains)
            $beforeCo  = $filteredCampaigns.Count
            $coMatched = [System.Collections.Generic.List[object]]::new()
            foreach ($campaign in $filteredCampaigns) {
                $nm = if ($null -ne $campaign.name) { [string]$campaign.name } else { '' }
                if ($nm -like "*$kwEsc*") { $coMatched.Add($campaign) }
            }
            $filteredCampaigns = $coMatched
            Write-SPLog -Message "Name-contains filter ('$CampaignNameContains', client-side, case-insensitive): $beforeCo -> $($filteredCampaigns.Count) campaigns" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $filteredCampaigns.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertifications {
    <#
    .SYNOPSIS
        Retrieves all certifications for a campaign with reviewer classification.
    .DESCRIPTION
        GETs /v3/certifications filtered by campaign.id and auto-paginates.
        Each certification is annotated with a 'ReviewerClassification' property:
          'Primary'    - reviewer taken from cert.reviewer (no reassignment)
          'Reassigned' - reviewer taken from cert.reassignment (reassigned cert)
        The effective reviewer object is surfaced as 'EffectiveReviewer' on each
        returned certification object for convenient downstream processing.
    .PARAMETER CampaignId
        The campaign ID to retrieve certifications for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([cert objects with classification]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertifications -CampaignId 'camp-abc123' -CorrelationID $cid
        foreach ($cert in $result.Data) {
            "$($cert.EffectiveReviewer.displayName) [$($cert.ReviewerClassification)]"
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting audit certifications for campaign '$CampaignId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
        -CorrelationID $CorrelationID

    try {
        $allCerts = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0

        # M2: pagination ceiling.
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
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allCerts.Count) certifications). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'filters' = "campaign.id eq `"$CampaignId`""
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/certifications' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertifications failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($cert in $page) {
                    # Classify reviewer: reassigned vs primary
                    $classification   = 'Primary'
                    $effectiveReviewer = $cert.reviewer

                    if ($null -ne $cert.PSObject.Properties['reassignment'] -and
                        $null -ne $cert.reassignment) {
                        $classification    = 'Reassigned'
                        # The reassignment object contains the new reviewer
                        if ($null -ne $cert.reassignment.PSObject.Properties['to'] -and
                            $null -ne $cert.reassignment.to) {
                            $effectiveReviewer = $cert.reassignment.to
                        }
                    }

                    # Attach classification properties (Add-Member works on PS custom objects)
                    $cert | Add-Member -MemberType NoteProperty -Name 'ReviewerClassification' `
                        -Value $classification -Force
                    $cert | Add-Member -MemberType NoteProperty -Name 'EffectiveReviewer' `
                        -Value $effectiveReviewer -Force

                    $allCerts.Add($cert)
                }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) certifications (running total: $($allCerts.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allCerts.Count) total certifications for campaign '$CampaignId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertifications' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allCerts.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertifications failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertifications' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCertificationItems {
    <#
    .SYNOPSIS
        Retrieves all access review items for a single certification, auto-paginating.
    .DESCRIPTION
        GETs /v3/certifications/{certId}/access-review-items and auto-paginates.
        Each item includes decision (APPROVE/REVOKE), access (type/name),
        identitySummary, and account details as returned by the ISC API.
    .PARAMETER CertificationId
        The certification ID to retrieve access review items for. Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([item objects]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCertificationItems -CertificationId 'cert-xyz' -CorrelationID $cid
        $items = $result.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CertificationId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting access review items for certification '$CertificationId' (auto-paginating)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
        -CorrelationID $CorrelationID

    try {
        $allItems = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $endpoint = "/certifications/$CertificationId/access-review-items"

        # M2: pagination ceiling.
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
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allItems.Count) items). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint $endpoint `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditCertificationItems failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($item in $page) { $allItems.Add($item) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) access review items (running total: $($allItems.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allItems.Count) total access review items for certification '$CertificationId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCertificationItems' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $allItems.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCertificationItems failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCertificationItems' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Downloads a campaign report CSV from the SailPoint ISC legacy report API.
    .DESCRIPTION
        Two-step process:
          Step 1: GET /v3/campaigns/{campaignId}/reports
                  Finds the matching reportType entry and extracts taskResultId.
          Step 2: GET /cc/api/report/get/{taskResultId}?format=csv
                  Downloads the CSV using a direct Invoke-RestMethod call against
                  the tenant base URL (not the /v3 API base).  The bearer token is
                  obtained from Get-SPAuthToken.

        The legacy /cc/api endpoint is NOT routed through Invoke-SPApiRequest because
        its URL root differs from Api.BaseUrl (/v3).  The function builds the full
        URL from Authentication.ConfigFile.TenantUrl.

        Graceful fallback:
          If the legacy endpoint returns 403 or 404, the function returns Success=$false
          with an instructional error message advising the caller to download the CSV
          manually and use Import-SPAuditCampaignReport instead.

        If OutputDir is specified and the download succeeds, the CSV is written to
        disk as: {OutputDir}\{CampaignId}_{ReportType}.csv
    .PARAMETER CampaignId
        The campaign ID to download the report for. Mandatory.
    .PARAMETER ReportType
        The report type to download.
        Valid values: CAMPAIGN_STATUS_REPORT, CERTIFICATION_SIGNOFF_REPORT
    .PARAMETER OutputDir
        Optional directory path where the downloaded CSV file will be saved.
        If omitted the CSV content is returned in Data but not written to disk.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=[string CSV content or $null]; Error=$string}
    .EXAMPLE
        $result = Get-SPAuditCampaignReport -CampaignId 'camp-abc' `
                    -ReportType CAMPAIGN_STATUS_REPORT -OutputDir 'C:\Reports'
        if ($result.Success) { Write-Host "Saved to $($result.Data)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CampaignId,

        [Parameter(Mandatory)]
        [ValidateSet('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')]
        [string]$ReportType,

        [Parameter()]
        [string]$OutputDir,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Downloading campaign report: CampaignId='$CampaignId', ReportType='$ReportType'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: List available reports for the campaign
        $reportsResult = Invoke-SPApiRequest -Method GET `
            -Endpoint "/campaigns/$CampaignId/reports" `
            -CorrelationID $CorrelationID

        if (-not $reportsResult.Success) {
            $errMsg = "Failed to list reports for campaign '$CampaignId': $($reportsResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Find the matching report entry
        $reportsData = $reportsResult.Data
        if ($null -eq $reportsData) { $reportsData = @() }

        # API may return array directly or object with items
        if ($reportsData.PSObject.Properties.Name -contains 'items') {
            $reportsData = $reportsData.items
        }
        # Force array wrap (H1 fix) - a single report in the .items array
        # would otherwise be unwrapped to a bare object and the foreach below
        # would iterate its PROPERTIES instead of finding the single report.
        $reportsData = @($reportsData)

        $matchingReport = $null
        foreach ($report in $reportsData) {
            if ($report.type -eq $ReportType -or $report.reportType -eq $ReportType) {
                $matchingReport = $report
                break
            }
        }

        if ($null -eq $matchingReport) {
            $errMsg = "Report type '$ReportType' not found in campaign '$CampaignId' report list. " +
                      "The campaign may not be completed, or this report type is unavailable."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        # Extract taskResultId - field name varies by ISC version
        $taskResultId = $null
        foreach ($prop in @('taskResultId', 'task_result_id', 'taskId', 'id')) {
            if ($null -ne $matchingReport.PSObject.Properties[$prop]) {
                $taskResultId = $matchingReport.$prop
                if (-not [string]::IsNullOrWhiteSpace($taskResultId)) { break }
            }
        }

        if ([string]::IsNullOrWhiteSpace($taskResultId)) {
            $errMsg = "Could not extract taskResultId from report object for type '$ReportType'. " +
                      "Use Import-SPAuditCampaignReport to import a manually downloaded CSV."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        Write-SPLog -Message "Found report '$ReportType' with taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        # Step 2: Download CSV - try v3 API first, fall back to legacy /cc/api
        # v3 endpoint: GET /reports/{taskResultId}?fileFormat=csv  (available since Nov 2023)
        # Legacy:      GET /cc/api/report/get/{taskResultId}?format=csv (deprecated Feb 2024)
        $csvContent = $null

        # --- Attempt v3 first via Invoke-SPApiRequest ---
        Write-SPLog -Message "Attempting v3 report download for taskResultId='$taskResultId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        $v3Result = Invoke-SPApiRequest -Method GET `
            -Endpoint "/reports/$taskResultId" `
            -QueryParams @{ fileFormat = 'csv' } `
            -RawResponse `
            -CorrelationID $CorrelationID

        if ($v3Result.Success -and $null -ne $v3Result.Data) {
            $csvContent = $v3Result.Data
            Write-SPLog -Message "v3 report download succeeded for taskResultId='$taskResultId'" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }
        else {
            # --- Silent fallback to legacy /cc/api ---
            Write-SPLog -Message "v3 report download failed (StatusCode=$($v3Result.StatusCode)). Falling back to legacy /cc/api." `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $config    = Get-SPConfig
            $tenantUrl = $config.Authentication.ConfigFile.TenantUrl.TrimEnd('/')

            if ([string]::IsNullOrWhiteSpace($tenantUrl)) {
                $tenantUrl = $config.Api.BaseUrl -replace '/v3$', '' -replace '/v3/', ''
                $tenantUrl = $tenantUrl.TrimEnd('/')
            }

            $reportUrl = "$tenantUrl/cc/api/report/get/$taskResultId" + '?format=csv'

            Write-SPLog -Message "Calling legacy report URL: $reportUrl" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID

            $authResult = Get-SPAuthToken -CorrelationID $CorrelationID
            if (-not $authResult.Success) {
                $errMsg = "Cannot acquire auth token for report download: $($authResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $timeoutSec = 120
            try {
                $configTimeout = $config.Api.TimeoutSeconds
                if ($configTimeout -gt 0) { $timeoutSec = $configTimeout }
            }
            catch { }

            try {
                $csvContent = Invoke-RestMethod `
                    -Uri        $reportUrl `
                    -Method     GET `
                    -Headers    $authResult.Data.Headers `
                    -TimeoutSec $timeoutSec `
                    -ErrorAction Stop
            }
            catch {
                $exc        = $_.Exception
                $statusCode = 0
                try {
                    if ($exc -is [System.Net.WebException] -and $null -ne $exc.Response) {
                        $statusCode = [int]$exc.Response.StatusCode
                    }
                    elseif ($exc.Message -match '(\d{3})') {
                        $statusCode = [int]$Matches[1]
                    }
                }
                catch { }

                if ($statusCode -eq 403 -or $statusCode -eq 404) {
                    $errMsg = "Campaign report API unavailable (v3 and legacy both failed) for taskResultId='$taskResultId'. " +
                              "Download the CSV manually from the SailPoint UI and use " +
                              "Import-SPAuditCampaignReport -CsvDirectoryPath to import it."
                    Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $errMsg = "Report download failed (HTTP $statusCode): $($exc.Message)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }
        }

        # Optionally persist to disk
        if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
            if (-not (Test-Path -Path $OutputDir -PathType Container)) {
                New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
            }
            $safeReportType = $ReportType -replace '[^A-Za-z0-9_\-]', '_'
            $fileName       = "${CampaignId}_${safeReportType}.csv"
            $filePath       = Join-Path -Path $OutputDir -ChildPath $fileName
            Set-Content -Path $filePath -Value $csvContent -Encoding UTF8
            Write-SPLog -Message "Campaign report saved to '$filePath'" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditCampaignReport' `
                -CorrelationID $CorrelationID
        }

        return @{ Success = $true; Data = $csvContent; Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Import-SPAuditCampaignReport {
    <#
    .SYNOPSIS
        Imports manually downloaded campaign report CSVs from a local directory.
    .DESCRIPTION
        Scans CsvDirectoryPath for files matching two patterns:
          *Status*Report*.csv   -> loaded as the campaign status report
          *Sign*Off*.csv        -> loaded as the sign-off report
        Both patterns are case-insensitive.  Files are parsed with Import-Csv.
        At least one matching file must be found for Success=$true.

        Useful when Get-SPAuditCampaignReport is blocked by legacy API restrictions
        and the CSV was downloaded manually from the SailPoint ISC UI.
    .PARAMETER CsvDirectoryPath
        Directory that contains the manually downloaded CSV file(s). Mandatory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{
                StatusReport = [object[]] or $null
                SignOffReport = [object[]] or $null
            }
            Error = $string
        }
    .EXAMPLE
        $result = Import-SPAuditCampaignReport -CsvDirectoryPath 'C:\Downloads\Reports'
        if ($result.Success) {
            $status  = $result.Data.StatusReport
            $signOff = $result.Data.SignOffReport
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvDirectoryPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Importing campaign report CSVs from '$CsvDirectoryPath'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
        -CorrelationID $CorrelationID

    try {
        if (-not (Test-Path -Path $CsvDirectoryPath -PathType Container)) {
            $errMsg = "CSV directory not found: '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $allCsvFiles = Get-ChildItem -Path $CsvDirectoryPath -Filter '*.csv' -File -ErrorAction Stop

        if ($null -eq $allCsvFiles -or $allCsvFiles.Count -eq 0) {
            $errMsg = "No CSV files found in '$CsvDirectoryPath'"
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusReportData  = $null
        $signOffReportData = $null
        $foundAny          = $false

        foreach ($file in $allCsvFiles) {
            $name = $file.Name

            # Status report pattern: *Status*Report*.csv (case-insensitive)
            if ($name -imatch 'Status.*Report' -or $name -imatch 'Report.*Status') {
                Write-SPLog -Message "Loading status report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $statusReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }

            # Sign-off report pattern: *Sign*Off*.csv (case-insensitive)
            if ($name -imatch 'Sign.*Off' -or $name -imatch 'Signoff' -or $name -imatch 'SignOff') {
                Write-SPLog -Message "Loading sign-off report from '$($file.FullName)'" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
                    -CorrelationID $CorrelationID
                $signOffReportData = Import-Csv -Path $file.FullName -ErrorAction Stop
                $foundAny = $true
                continue
            }
        }

        if (-not $foundAny) {
            $errMsg = "No matching CSV files found in '$CsvDirectoryPath'. " +
                      "Expected files matching '*Status*Report*.csv' or '*Sign*Off*.csv'."
            Write-SPLog -Message $errMsg -Severity WARN -Component 'SP.AuditQueries' `
                -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $statusCount  = if ($null -ne $statusReportData) { @($statusReportData).Count } else { 0 }
        $signOffCount = if ($null -ne $signOffReportData) { @($signOffReportData).Count } else { 0 }

        Write-SPLog -Message "Imported campaign reports: StatusReport=$statusCount rows, SignOffReport=$signOffCount rows" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Import-SPAuditCampaignReport' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                StatusReport  = $statusReportData
                SignOffReport = $signOffReportData
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Import-SPAuditCampaignReport failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Import-SPAuditCampaignReport' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPAuditIdentityEvents {
    <#
    .SYNOPSIS
        Retrieves provisioning account-activity events for a specific identity.
    .DESCRIPTION
        GETs /v3/account-activities filtered by requested-for={identityId} and
        auto-paginates.  Client-side date filtering is applied on the 'created'
        field using the DaysBack parameter.

        For each activity, the source name for items within the activity is resolved
        via Get-SPAuditSourceName (which uses an in-module cache).  Each returned
        activity object is annotated with a 'ResolvedSourceNames' property containing
        a hashtable keyed by sourceId with display names as values.

        This function is designed for post-campaign audit use cases: understanding
        what provisioning changes occurred for an identity near a campaign date.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to query events for. Mandatory.
    .PARAMETER DaysBack
        Number of calendar days to look back from now for events. Default: 2.
        Set to 0 to disable date filtering and return all available events.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@([activity objects with ResolvedSourceNames]); Error=$string}
    .EXAMPLE
        $result = Get-SPAuditIdentityEvents -IdentityId 'id-abc123' -DaysBack 7 -CorrelationID $cid
        foreach ($event in $result.Data) {
            $event.action
            $event.ResolvedSourceNames
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [int]$DaysBack = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity events for '$IdentityId' (DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
        -CorrelationID $CorrelationID

    try {
        $allActivities = [System.Collections.Generic.List[object]]::new()
        $pageSize      = 250
        $offset        = 0
        $pageNum       = 0

        # M2: pagination ceiling.
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
                $errMsg = "Pagination ceiling reached: $maxPages pages already fetched (accumulated $($allActivities.Count) activities). Raise Api.MaxPaginationPages in settings.json if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'requested-for' = $IdentityId
                'limit'         = $pageSize.ToString()
                'offset'        = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/account-activities' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Get-SPAuditIdentityEvents failed at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            # Normalize response
            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            # Force array wrap (see SP.Certifications.psm1 comment; H1 fix).
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($activity in $page) { $allActivities.Add($activity) }
            }

            Write-SPLog -Message "Page ${pageNum}: retrieved $($page.Count) account activities (running total: $($allActivities.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allActivities.Count) total account activities before date filtering" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        # Client-side date filter
        $filteredActivities = [System.Collections.Generic.List[object]]::new()
        if ($DaysBack -gt 0) {
            $cutoff = (Get-Date).AddDays(-$DaysBack)
            foreach ($activity in $allActivities) {
                $createdRaw = $activity.created
                if ($null -eq $createdRaw) {
                    $filteredActivities.Add($activity)
                    continue
                }

                $createdDate = $null
                if ($createdRaw -is [datetime]) {
                    $createdDate = [datetime]$createdRaw
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($createdRaw.ToString(), [ref]$parsedDate)) {
                        $createdDate = $parsedDate
                    }
                }

                if ($null -eq $createdDate -or $createdDate -ge $cutoff) {
                    $filteredActivities.Add($activity)
                }
            }

            Write-SPLog -Message "Date filter (last $DaysBack days): $($allActivities.Count) -> $($filteredActivities.Count) activities" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
                -CorrelationID $CorrelationID
        }
        else {
            foreach ($activity in $allActivities) { $filteredActivities.Add($activity) }
        }

        # Resolve source names for items within each activity
        foreach ($activity in $filteredActivities) {
            $resolvedNames = @{}

            $activityItems = $null
            if ($null -ne $activity.PSObject.Properties['items'] -and $null -ne $activity.items) {
                $activityItems = $activity.items
            }

            if ($null -ne $activityItems) {
                foreach ($actItem in $activityItems) {
                    # Source ID may be on the item directly or nested under source/sourceRef
                    $sourceId = $null
                    foreach ($prop in @('sourceId', 'source_id')) {
                        if ($null -ne $actItem.PSObject.Properties[$prop]) {
                            $sourceId = $actItem.$prop
                            if (-not [string]::IsNullOrWhiteSpace($sourceId)) { break }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($sourceId) -and
                        $null -ne $actItem.PSObject.Properties['source'] -and
                        $null -ne $actItem.source -and
                        $null -ne $actItem.source.PSObject.Properties['id']) {
                        $sourceId = $actItem.source.id
                    }

                    if (-not [string]::IsNullOrWhiteSpace($sourceId) -and
                        -not $resolvedNames.ContainsKey($sourceId)) {
                        $resolvedNames[$sourceId] = Get-SPAuditSourceName `
                            -SourceId $sourceId -CorrelationID $CorrelationID
                    }
                }
            }

            $activity | Add-Member -MemberType NoteProperty -Name 'ResolvedSourceNames' `
                -Value $resolvedNames -Force
        }

        Write-SPLog -Message "Returning $($filteredActivities.Count) account activities for identity '$IdentityId'" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAuditIdentityEvents' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $filteredActivities.ToArray(); Error = $null }
    }
    catch {
        $errMsg = "Get-SPAuditIdentityEvents failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAuditIdentityEvents' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Resolve-SPAuditIdentityAccounts {
    <#
    .SYNOPSIS
        Batch-resolves identity IDs to account details (sAMAccountName, UPN, mail).
    .DESCRIPTION
        Calls Get-SPAuditAccountForIdentity for each supplied identity ID and returns
        a hashtable keyed by identity ID. The internal per-identity cache means duplicate
        IDs are not re-fetched within the same session.

        Intended to be called once per campaign with all unique identity IDs collected
        from the review items, before passing the resulting map to
        Group-SPAuditDecisions and Group-SPAuditRemediationProof via -AccountMap.
    .PARAMETER IdentityIds
        Array of identity ID strings to resolve.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = @{ identityId = @{SamAccountName; UserPrincipalName; Email; NativeIdentity} }
            Error   = $string
        }
    .EXAMPLE
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $ids -CorrelationID $cid
        if ($acctResult.Success) { $accountMap = $acctResult.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$IdentityIds,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Resolving account attributes for $($IdentityIds.Count) unique identity ID(s)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Resolve-SPAuditIdentityAccounts' `
        -CorrelationID $CorrelationID

    # --- Resolve the disk cache file + TTL (best-effort) ----------------------
    $acctCacheFile = $null
    $acctTtlMin    = 1440   # 24h default; account attributes are stable
    try {
        $acctCacheFile = Join-Path (Get-SPAuditCacheDir) 'accounts.jsonl'
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit'] -and
            $null -ne $cfg.Audit.PSObject.Properties['AccountCacheTtlMinutes'] -and
            $null -ne $cfg.Audit.AccountCacheTtlMinutes) {
            $acctTtlMin = [int]$cfg.Audit.AccountCacheTtlMinutes
        }
    } catch { $acctCacheFile = $null }

    # --- Warm the in-memory cache from disk once per session ------------------
    if (-not $script:_AccountDiskLoaded -and $null -ne $acctCacheFile -and (Test-Path $acctCacheFile)) {
        try {
            $nowWarm = Get-Date
            Get-Content $acctCacheFile | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { return }
                $rec = $_ | ConvertFrom-Json
                $rid = [string]$rec.IdentityId
                $rat = [datetime]::Parse([string]$rec.CachedAt)
                if (-not [string]::IsNullOrWhiteSpace($rid) -and
                    ($nowWarm - $rat).TotalMinutes -lt $acctTtlMin) {
                    if (-not $script:AccountCache.ContainsKey($rid)) {
                        $script:AccountCache[$rid] = @{
                            SamAccountName    = [string]$rec.Account.SamAccountName
                            UserPrincipalName = [string]$rec.Account.UserPrincipalName
                            Email             = [string]$rec.Account.Email
                            NativeIdentity    = [string]$rec.Account.NativeIdentity
                        }
                    }
                    $script:_AccountCachedAt[$rid] = $rat
                }
            }
        } catch { }
    }
    $script:_AccountDiskLoaded = $true

    try {
        $ids       = @($IdentityIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $total     = $ids.Count
        $results   = @{}
        $fetched   = 0
        $fromCache = 0
        $idx       = 0
        $step      = [Math]::Max(25, [int][Math]::Ceiling($total / 20.0))   # ~20 heartbeats max
        $showProgress = $total -gt 50
        if ($showProgress) {
            Write-Host "    Resolving account details for $total identit(ies) (cache reused; rest fetched from ISC)..." -ForegroundColor DarkGray
        }

        foreach ($id in $ids) {
            $idx++
            $hadIt = $script:AccountCache.ContainsKey($id)
            $results[$id] = Get-SPAuditAccountForIdentity -IdentityId $id -CorrelationID $CorrelationID
            if ($hadIt) {
                $fromCache++
            }
            else {
                $fetched++
                # Stamp non-empty resolutions for persistence; skip empty/failed lookups so a
                # transient miss is not cached across runs.
                $acct = $results[$id]
                $nonEmpty = (-not [string]::IsNullOrWhiteSpace([string]$acct.SamAccountName)) -or
                            (-not [string]::IsNullOrWhiteSpace([string]$acct.UserPrincipalName)) -or
                            (-not [string]::IsNullOrWhiteSpace([string]$acct.Email))
                if ($nonEmpty) { $script:_AccountCachedAt[$id] = Get-Date }
            }
            if ($showProgress -and ($idx % $step -eq 0)) {
                $pct = [int](($idx / [double]$total) * 100)
                Write-Host ("      ...$idx / $total ($pct%)  [cache: $fromCache, fetched: $fetched]") -ForegroundColor DarkGray
            }
        }
        if ($showProgress) {
            Write-Host ("      ...done: $total resolved ($fromCache from cache, $fetched fetched)") -ForegroundColor DarkGray
        }

        # --- Persist newly-fetched resolutions back to disk -------------------
        if ($fetched -gt 0 -and $null -ne $acctCacheFile) {
            try {
                $cacheDirPath = Split-Path -Parent $acctCacheFile
                if (-not [string]::IsNullOrWhiteSpace($cacheDirPath) -and -not (Test-Path $cacheDirPath)) {
                    New-Item -Path $cacheDirPath -ItemType Directory -Force -WhatIf:$false | Out-Null
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $sb = New-Object System.Text.StringBuilder
                foreach ($cid in $script:_AccountCachedAt.Keys) {
                    if (-not $script:AccountCache.ContainsKey($cid)) { continue }
                    $rec = [ordered]@{
                        IdentityId = $cid
                        CachedAt   = ([datetime]$script:_AccountCachedAt[$cid]).ToString('o')
                        Account    = $script:AccountCache[$cid]
                    }
                    [void]$sb.AppendLine(($rec | ConvertTo-Json -Depth 6 -Compress))
                }
                [System.IO.File]::WriteAllText($acctCacheFile, $sb.ToString(), $utf8NoBom)
            }
            catch {
                Write-SPLog -Message "Account cache persist failed: $($_.Exception.Message)" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Resolve-SPAuditIdentityAccounts' `
                    -CorrelationID $CorrelationID
            }
        }

        Write-SPLog -Message "Account resolution complete: $($results.Count) identit(ies) ($fromCache cached, $fetched fetched)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Resolve-SPAuditIdentityAccounts' `
            -CorrelationID $CorrelationID

        return @{ Success = $true; Data = $results; Error = $null }
    }
    catch {
        $errMsg = "Resolve-SPAuditIdentityAccounts failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Resolve-SPAuditIdentityAccounts' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPReviewerWorkload {
    <#
    .SYNOPSIS
        Finds all active campaigns/certifications assigned to a specific reviewer.
    .DESCRIPTION
        Retrieves campaigns matching the status filter, then for each campaign
        fetches certifications and filters to those where the effective reviewer
        matches the supplied ReviewerIdentityId. Returns per-campaign workload
        counts (total items, decided items, pending items) plus aggregate totals.

        Uses Get-SPAuditCampaigns and Get-SPAuditCertifications internally.
        Item counts are derived from certification-level statistics (decisionsTotal,
        decisionsMade) to avoid additional per-item API calls.
    .PARAMETER ReviewerIdentityId
        The SailPoint ISC identity ID of the reviewer. Mandatory.
    .PARAMETER Status
        Campaign status filter. Default: @('ACTIVE').
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{ReviewerId; ReviewerName; TotalCampaigns;
        TotalItems; TotalPending; Campaigns=@(...)}; Error=$string}
    .EXAMPLE
        $result = Get-SPReviewerWorkload -ReviewerIdentityId 'id-mgr-001'
        $result.Data.Campaigns | Format-Table CampaignName, ItemsAssigned, ItemsPending
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReviewerIdentityId,

        [Parameter()]
        [string[]]$Status = @('ACTIVE'),

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting reviewer workload for identity '$ReviewerIdentityId' (Status=$($Status -join ','))" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Get campaigns matching status filter (DaysBack=0 to disable date filter)
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack 0 `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPReviewerWorkload failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPReviewerWorkload' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for reviewer '$ReviewerIdentityId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
            -CorrelationID $CorrelationID

        $reviewerName     = ''
        $campaignWorkload = [System.Collections.Generic.List[object]]::new()
        $grandTotalItems  = 0
        $grandTotalDecided = 0

        # Step 2-3: For each campaign, get certs and filter by reviewer
        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name

            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            $campItems   = 0
            $campDecided = 0

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                # Check if effective reviewer matches
                $reviewerId = $null
                if ($null -ne $cert.EffectiveReviewer -and
                    $null -ne $cert.EffectiveReviewer.PSObject.Properties['id']) {
                    $reviewerId = $cert.EffectiveReviewer.id
                }

                if ($reviewerId -ne $ReviewerIdentityId) { continue }

                # Capture reviewer name from first match
                if ([string]::IsNullOrWhiteSpace($reviewerName) -and
                    $null -ne $cert.EffectiveReviewer.PSObject.Properties['displayName'] -and
                    -not [string]::IsNullOrWhiteSpace($cert.EffectiveReviewer.displayName)) {
                    $reviewerName = $cert.EffectiveReviewer.displayName
                }

                # Extract item counts from certification-level stats
                $totalItems  = 0
                $decidedItems = 0

                if ($null -ne $cert.PSObject.Properties['decisionsTotal'] -and
                    $null -ne $cert.decisionsTotal) {
                    $totalItems = [int]$cert.decisionsTotal
                }
                elseif ($null -ne $cert.PSObject.Properties['totalCount'] -and
                        $null -ne $cert.totalCount) {
                    $totalItems = [int]$cert.totalCount
                }

                if ($null -ne $cert.PSObject.Properties['decisionsMade'] -and
                    $null -ne $cert.decisionsMade) {
                    $decidedItems = [int]$cert.decisionsMade
                }
                elseif ($null -ne $cert.PSObject.Properties['completedCount'] -and
                        $null -ne $cert.completedCount) {
                    $decidedItems = [int]$cert.completedCount
                }

                $campItems   += $totalItems
                $campDecided += $decidedItems
            }

            # Only include campaigns where the reviewer has certifications
            if ($campItems -gt 0 -or $campDecided -gt 0) {
                $pending = $campItems - $campDecided
                if ($pending -lt 0) { $pending = 0 }

                $campaignWorkload.Add([PSCustomObject]@{
                    CampaignId    = $campId
                    CampaignName  = $campName
                    ItemsAssigned = $campItems
                    ItemsDecided  = $campDecided
                    ItemsPending  = $pending
                })

                $grandTotalItems   += $campItems
                $grandTotalDecided += $campDecided
            }
        }

        $grandTotalPending = $grandTotalItems - $grandTotalDecided
        if ($grandTotalPending -lt 0) { $grandTotalPending = 0 }

        Write-SPLog -Message "Reviewer '$ReviewerIdentityId' workload: $($campaignWorkload.Count) campaigns, $grandTotalItems items ($grandTotalPending pending)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerWorkload' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                ReviewerId     = $ReviewerIdentityId
                ReviewerName   = $reviewerName
                TotalCampaigns = $campaignWorkload.Count
                TotalItems     = $grandTotalItems
                TotalPending   = $grandTotalPending
                Campaigns      = $campaignWorkload.ToArray()
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPReviewerWorkload failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPReviewerWorkload' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPIdentityDecisionHistory {
    <#
    .SYNOPSIS
        Finds all access review decisions made about a specific identity across campaigns.
    .DESCRIPTION
        Answers: "What has been decided about this identity's access in every campaign?"
        Retrieves campaigns matching status and date filters, then for each campaign
        fetches certifications and access review items, filtering to items where
        identitySummary.id matches the supplied IdentityId.

        Returns a chronological list (newest first) of decisions grouped by campaign,
        including the access name, decision, reviewer name, and decision date.

        Uses Get-SPAuditCampaigns, Get-SPAuditCertifications, and
        Get-SPAuditCertificationItems internally.
    .PARAMETER IdentityId
        The SailPoint ISC identity ID to search decisions for. Mandatory.
    .PARAMETER Status
        Campaign status filter. Default: @('COMPLETED','ACTIVE').
    .PARAMETER DaysBack
        Number of calendar days to look back. Default: 365.
        Set to 0 to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{Success=$bool; Data=@{IdentityId; IdentityName; TotalDecisions;
        Campaigns=@(@{CampaignName; CampaignDate; Decisions=@(...)})}; Error=$string}
    .EXAMPLE
        $result = Get-SPIdentityDecisionHistory -IdentityId 'id-001' -DaysBack 365
        $result.Data.Campaigns | ForEach-Object { $_.CampaignName; $_.Decisions.Count }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityId,

        [Parameter()]
        [string[]]$Status = @('COMPLETED', 'ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting identity decision history for '$IdentityId' (Status=$($Status -join ','), DaysBack=$DaysBack)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
        -CorrelationID $CorrelationID

    try {
        # Step 1: Get campaigns matching status + date filters
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack $DaysBack `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPIdentityDecisionHistory failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPIdentityDecisionHistory' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for identity '$IdentityId'" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
            -CorrelationID $CorrelationID

        $identityName       = ''
        $totalDecisions     = 0
        $campaignResults    = [System.Collections.Generic.List[object]]::new()

        # Step 2-4: For each campaign, get certs -> items -> filter by identity
        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name

            # Extract campaign date (use 'created' field)
            $campDate = ''
            if ($null -ne $campaign.created) {
                if ($campaign.created -is [datetime]) {
                    $campDate = ([datetime]$campaign.created).ToUniversalTime().ToString('yyyy-MM-dd')
                }
                else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($campaign.created.ToString(), [ref]$parsedDate)) {
                        $campDate = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $campDate = $campaign.created.ToString()
                    }
                }
            }

            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId): $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            $campDecisions = [System.Collections.Generic.List[object]]::new()

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                $certId = $cert.id
                $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                    -CorrelationID $CorrelationID

                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Skipping cert '$certId' in campaign '$campName': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                foreach ($item in $items) {
                    if ($null -eq $item) { continue }

                    # Check if this item is for our target identity
                    $itemIdentityId = $null
                    if ($null -ne $item.PSObject.Properties['identitySummary'] -and
                        $null -ne $item.identitySummary -and
                        $null -ne $item.identitySummary.PSObject.Properties['id']) {
                        $itemIdentityId = $item.identitySummary.id
                    }

                    if ($itemIdentityId -ne $IdentityId) { continue }

                    # Capture identity name from first match
                    if ([string]::IsNullOrWhiteSpace($identityName) -and
                        $null -ne $item.identitySummary.PSObject.Properties['name'] -and
                        -not [string]::IsNullOrWhiteSpace($item.identitySummary.name)) {
                        $identityName = $item.identitySummary.name
                    }

                    # Extract decision details
                    $accessName   = ''
                    $decision     = ''
                    $reviewerName = ''
                    $decisionDate = ''

                    # Access name: try access.name, then entitlementName, then displayName
                    if ($null -ne $item.PSObject.Properties['access'] -and
                        $null -ne $item.access -and
                        $null -ne $item.access.PSObject.Properties['name']) {
                        $accessName = $item.access.name
                    }
                    elseif ($null -ne $item.PSObject.Properties['entitlementName'] -and
                            -not [string]::IsNullOrWhiteSpace($item.entitlementName)) {
                        $accessName = $item.entitlementName
                    }
                    elseif ($null -ne $item.PSObject.Properties['displayName'] -and
                            -not [string]::IsNullOrWhiteSpace($item.displayName)) {
                        $accessName = $item.displayName
                    }

                    # Decision
                    if ($null -ne $item.PSObject.Properties['decision'] -and
                        -not [string]::IsNullOrWhiteSpace($item.decision)) {
                        $decision = $item.decision
                    }

                    # Reviewer name
                    if ($null -ne $item.PSObject.Properties['reviewer'] -and
                        $null -ne $item.reviewer -and
                        $null -ne $item.reviewer.PSObject.Properties['name']) {
                        $reviewerName = $item.reviewer.name
                    }
                    # Fallback to cert-level effective reviewer
                    if ([string]::IsNullOrWhiteSpace($reviewerName) -and
                        $null -ne $cert.EffectiveReviewer -and
                        $null -ne $cert.EffectiveReviewer.PSObject.Properties['displayName']) {
                        $reviewerName = $cert.EffectiveReviewer.displayName
                    }

                    # Decision date
                    if ($null -ne $item.PSObject.Properties['completed'] -and
                        $null -ne $item.completed) {
                        if ($item.completed -is [datetime]) {
                            $decisionDate = ([datetime]$item.completed).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                        else {
                            $decisionDate = $item.completed.ToString()
                        }
                    }

                    $campDecisions.Add([PSCustomObject]@{
                        AccessName   = $accessName
                        Decision     = $decision
                        ReviewerName = $reviewerName
                        DecisionDate = $decisionDate
                    })
                }
            }

            # Only include campaigns where this identity had review items
            if ($campDecisions.Count -gt 0) {
                $totalDecisions += $campDecisions.Count

                $campaignResults.Add([PSCustomObject]@{
                    CampaignId   = $campId
                    CampaignName = $campName
                    CampaignDate = $campDate
                    Decisions    = $campDecisions.ToArray()
                })
            }
        }

        # Sort campaigns newest first by CampaignDate
        $sortedCampaigns = @($campaignResults | Sort-Object -Property CampaignDate -Descending)

        Write-SPLog -Message "Identity '$IdentityId' decision history: $totalDecisions decisions across $($sortedCampaigns.Count) campaigns" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPIdentityDecisionHistory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                IdentityId     = $IdentityId
                IdentityName   = $identityName
                TotalDecisions = $totalDecisions
                Campaigns      = $sortedCampaigns
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPIdentityDecisionHistory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPIdentityDecisionHistory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPSourceCampaignCoverage {
    <#
    .SYNOPSIS
        Analyzes which sources have been covered by campaigns and which have not.
    .DESCRIPTION
        Builds a coverage map of all ISC sources against certification campaigns.

        Step 1: Paginate GET /v3/sources to retrieve every source.
        Step 2: Get campaigns matching the supplied status and date filters.
        Step 3: For SOURCE_OWNER campaigns, extract sourceIds directly from the
                campaign object (no need to drill into items).
        Step 4: For other campaign types, drill into certifications and access
                review items to discover which sourceIds were covered.
        Step 5: Build the coverage map -- each source mapped to the campaigns
                that audited it, with a last-campaign date and count.

        Sources that appear in zero campaigns are flagged as Uncovered.
        A Summary hashtable provides TotalSources, Covered, Uncovered, and
        CoverageRate (percentage).

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch.
    .PARAMETER Status
        Campaign status filter. Default: @('COMPLETED','ACTIVE').
    .PARAMETER DaysBack
        Number of calendar days to look back for campaigns. Default: 365.
        Set to 0 to disable date filtering.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Covered   = @(@{ SourceId; SourceName; LastCampaign; LastCampaignDate; CampaignCount })
                Uncovered = @(@{ SourceId; SourceName; NeverAudited=$true })
                Summary   = @{ TotalSources=N; Covered=N; Uncovered=N; CoverageRate=N }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPSourceCampaignCoverage -DaysBack 365
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPSourceCampaignCoverage -Status 'COMPLETED' -DaysBack 180
        $result.Data.Uncovered | ForEach-Object { $_.SourceName }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$Status = @('COMPLETED', 'ACTIVE'),

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting source campaign coverage: Status='$($Status -join ',')', DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
        -CorrelationID $CorrelationID

    try {
        # -----------------------------------------------------------
        # Step 1: Retrieve all sources via GET /v3/sources (paginated)
        # -----------------------------------------------------------
        $allSources = [System.Collections.Generic.List[object]]::new()
        $pageSize   = 250
        $offset     = 0
        $pageNum    = 0

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
                $errMsg = "Pagination ceiling reached fetching sources: $maxPages pages ($($allSources.Count) sources). Raise Api.MaxPaginationPages if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $srcResult = Invoke-SPApiRequest -Method GET -Endpoint '/sources' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $srcResult.Success) {
                $errMsg = "Failed to retrieve sources at page $pageNum (offset $offset): $($srcResult.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $srcResult.Data
            if ($null -ne $srcResult.Data -and $srcResult.Data.PSObject.Properties.Name -contains 'items') {
                $page = $srcResult.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($src in $page) { $allSources.Add($src) }
            }

            Write-SPLog -Message "Sources page ${pageNum}: $($page.Count) sources (running total: $($allSources.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allSources.Count) total sources" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        if ($allSources.Count -eq 0) {
            return @{
                Success = $true
                Data    = @{
                    Covered   = @()
                    Uncovered = @()
                    Summary   = @{ TotalSources = 0; Covered = 0; Uncovered = 0; CoverageRate = 0 }
                }
                Error   = $null
            }
        }

        # Build source lookup: id -> name
        $sourceMap = @{}
        foreach ($src in $allSources) {
            $srcId   = $src.id
            $srcName = $src.name
            if ([string]::IsNullOrWhiteSpace($srcName)) { $srcName = $srcId }
            $sourceMap[$srcId] = $srcName
            # Also populate the module-scope cache for downstream use
            $script:SourceNameCache[$srcId] = $srcName
        }

        # -----------------------------------------------------------
        # Step 2: Get campaigns matching status + date filters
        # -----------------------------------------------------------
        $campaignResult = Get-SPAuditCampaigns -Status $Status -DaysBack $DaysBack `
            -CorrelationID $CorrelationID

        if (-not $campaignResult.Success) {
            $errMsg = "Get-SPSourceCampaignCoverage failed to retrieve campaigns: $($campaignResult.Error)"
            Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
            return @{ Success = $false; Data = $null; Error = $errMsg }
        }

        $campaigns = @($campaignResult.Data)
        Write-SPLog -Message "Found $($campaigns.Count) campaigns to scan for source coverage" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Steps 3-4: Build coverage data -- sourceId -> list of campaign info
        # -----------------------------------------------------------
        # Key: sourceId, Value: List of @{CampaignId; CampaignName; CampaignDate}
        $coverageData = @{}

        foreach ($campaign in $campaigns) {
            if ($null -eq $campaign) { continue }

            $campId   = $campaign.id
            $campName = $campaign.name
            $campType = $campaign.type

            # Parse campaign date
            $campDate = ''
            if ($null -ne $campaign.created) {
                if ($campaign.created -is [datetime]) {
                    $campDate = ([datetime]$campaign.created).ToUniversalTime().ToString('yyyy-MM-dd')
                } else {
                    $parsedDate = [datetime]::MinValue
                    if ([datetime]::TryParse($campaign.created.ToString(), [ref]$parsedDate)) {
                        $campDate = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                    } else {
                        $campDate = $campaign.created.ToString()
                    }
                }
            }

            $campInfo = @{
                CampaignId   = $campId
                CampaignName = $campName
                CampaignDate = $campDate
            }

            # Step 3: SOURCE_OWNER campaigns have sourceIds directly
            if ($campType -eq 'SOURCE_OWNER') {
                $sourceIds = @()
                if ($null -ne $campaign.PSObject.Properties['sourceIds'] -and
                    $null -ne $campaign.sourceIds) {
                    $sourceIds = @($campaign.sourceIds)
                }
                # Also check searchCampaignInfo.sourcedIds or sourcedApplicationIds
                if ($sourceIds.Count -eq 0 -and
                    $null -ne $campaign.PSObject.Properties['searchCampaignInfo'] -and
                    $null -ne $campaign.searchCampaignInfo) {
                    $sci = $campaign.searchCampaignInfo
                    if ($null -ne $sci.PSObject.Properties['sourceIds'] -and $null -ne $sci.sourceIds) {
                        $sourceIds = @($sci.sourceIds)
                    }
                }

                foreach ($sid in $sourceIds) {
                    if ([string]::IsNullOrWhiteSpace($sid)) { continue }
                    if (-not $coverageData.ContainsKey($sid)) {
                        $coverageData[$sid] = [System.Collections.Generic.List[object]]::new()
                    }
                    $coverageData[$sid].Add($campInfo)
                }

                # If we found sourceIds, no need to drill into items
                if ($sourceIds.Count -gt 0) { continue }
            }

            # Step 4: For non-SOURCE_OWNER (or SOURCE_OWNER with no sourceIds),
            # drill into certifications -> items -> access.sourceId
            $certResult = Get-SPAuditCertifications -CampaignId $campId `
                -CorrelationID $CorrelationID

            if (-not $certResult.Success) {
                Write-SPLog -Message "Skipping campaign '$campName' ($campId) for source coverage: $($certResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                    -CorrelationID $CorrelationID
                continue
            }

            $certs = @($certResult.Data)
            # Track which sourceIds we already found for this campaign to avoid
            # redundant item-level API calls
            $campaignSourceIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)

            foreach ($cert in $certs) {
                if ($null -eq $cert) { continue }

                $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id `
                    -CorrelationID $CorrelationID

                if (-not $itemResult.Success) {
                    Write-SPLog -Message "Skipping cert '$($cert.id)' in campaign '$campName': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
                        -CorrelationID $CorrelationID
                    continue
                }

                $items = @($itemResult.Data)
                foreach ($item in $items) {
                    if ($null -eq $item) { continue }

                    # Extract sourceId from the access review item
                    $itemSourceId = $null

                    # Try access.sourceId first
                    if ($null -ne $item.PSObject.Properties['access'] -and
                        $null -ne $item.access) {
                        if ($null -ne $item.access.PSObject.Properties['sourceId'] -and
                            -not [string]::IsNullOrWhiteSpace($item.access.sourceId)) {
                            $itemSourceId = $item.access.sourceId
                        }
                        elseif ($null -ne $item.access.PSObject.Properties['source'] -and
                                $null -ne $item.access.source -and
                                $null -ne $item.access.source.PSObject.Properties['id']) {
                            $itemSourceId = $item.access.source.id
                        }
                    }

                    # Fallback: item-level sourceId
                    if ([string]::IsNullOrWhiteSpace($itemSourceId) -and
                        $null -ne $item.PSObject.Properties['sourceId'] -and
                        -not [string]::IsNullOrWhiteSpace($item.sourceId)) {
                        $itemSourceId = $item.sourceId
                    }

                    if ([string]::IsNullOrWhiteSpace($itemSourceId)) { continue }

                    # Only record once per source per campaign
                    if ($campaignSourceIds.Add($itemSourceId)) {
                        if (-not $coverageData.ContainsKey($itemSourceId)) {
                            $coverageData[$itemSourceId] = [System.Collections.Generic.List[object]]::new()
                        }
                        $coverageData[$itemSourceId].Add($campInfo)
                    }
                }
            }
        }

        # -----------------------------------------------------------
        # Step 5: Build the coverage result
        # -----------------------------------------------------------
        $coveredList   = [System.Collections.Generic.List[object]]::new()
        $uncoveredList = [System.Collections.Generic.List[object]]::new()

        foreach ($srcId in $sourceMap.Keys) {
            $srcName = $sourceMap[$srcId]

            if ($coverageData.ContainsKey($srcId) -and $coverageData[$srcId].Count -gt 0) {
                $campList = @($coverageData[$srcId])

                # Determine last campaign by date (string sort works for yyyy-MM-dd).
                # Scriptblock key: elements are HASHTABLES, and on PS 5.1
                # Sort-Object -Property <name> cannot resolve hashtable keys -- every
                # sort key was $null and insertion order won, so LastCampaign was
                # whatever campaign happened to be enumerated first, not the latest.
                $sorted = @($campList | Sort-Object -Property { $_['CampaignDate'] } -Descending)
                $lastCamp     = $sorted[0].CampaignName
                $lastCampDate = $sorted[0].CampaignDate

                $coveredList.Add([PSCustomObject]@{
                    SourceId         = $srcId
                    SourceName       = $srcName
                    LastCampaign     = $lastCamp
                    LastCampaignDate = $lastCampDate
                    CampaignCount    = $campList.Count
                })
            }
            else {
                $uncoveredList.Add([PSCustomObject]@{
                    SourceId      = $srcId
                    SourceName    = $srcName
                    NeverAudited  = $true
                })
            }
        }

        $totalSources = $sourceMap.Count
        $coveredCount = $coveredList.Count
        $uncoveredCount = $uncoveredList.Count
        $coverageRate = if ($totalSources -gt 0) {
            [math]::Round(($coveredCount / $totalSources) * 100, 1)
        } else { 0 }

        Write-SPLog -Message ("Source coverage analysis complete: " +
            "Total=$totalSources, Covered=$coveredCount, Uncovered=$uncoveredCount, " +
            "CoverageRate=${coverageRate}%") `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceCampaignCoverage' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Covered   = $coveredList.ToArray()
                Uncovered = $uncoveredList.ToArray()
                Summary   = @{
                    TotalSources = $totalSources
                    Covered      = $coveredCount
                    Uncovered    = $uncoveredCount
                    CoverageRate = $coverageRate
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Get-SPSourceCampaignCoverage failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPSourceCampaignCoverage' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPRemediationStatus {
    <#
    .SYNOPSIS
        Verifies whether revocation decisions were actually provisioned by ISC.
    .DESCRIPTION
        Takes revocation decisions from a campaign audit and checks ISC
        account-activity events to verify that the revocations were actually
        carried out. Each revocation is classified as Provisioned, Pending,
        Overdue, or Failed based on matching REVOKE_ACCESS events.

        Uses Get-SPAuditIdentityEvents (which calls GET /v3/account-activities)
        to retrieve provisioning events per identity, then cross-references
        each revocation decision by source name and entitlement name.
    .PARAMETER RevocationDecisions
        Array of revocation decision objects. Each must have: IdentityId,
        IdentityName, SourceName, EntitlementName, DecisionDate.
    .PARAMETER SlaHours
        Hours within which a revocation is expected to be provisioned.
        Revocations past this window with no matching event are Overdue.
        Default: 48.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Items = @(@{IdentityName; EntitlementName; DecisionDate; Status;
                            ProvisioningDate; DaysToRemediate})
                Summary = @{Total; Provisioned; Pending; Overdue; Failed;
                            AvgDaysToRemediate}
            }
        }
    .EXAMPLE
        $revocations = @(
            @{ IdentityId='id-001'; IdentityName='Alice'; SourceName='AD';
               EntitlementName='SG-Finance'; DecisionDate='2026-05-20T14:30:00Z' }
        )
        $result = Get-SPRemediationStatus -RevocationDecisions $revocations -SlaHours 48
        $result.Data.Summary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$RevocationDecisions,

        [Parameter()]
        [int]$SlaHours = 48,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Verifying remediation status for $($RevocationDecisions.Count) revocation(s), SLA=${SlaHours}h" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
        -CorrelationID $CorrelationID

    # Handle zero revocations gracefully
    if ($RevocationDecisions.Count -eq 0) {
        Write-SPLog -Message 'No revocation decisions to verify' `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID
        return @{
            Success = $true
            Data    = @{
                Items   = @()
                Summary = @{
                    Total              = 0
                    Provisioned        = 0
                    Pending            = 0
                    Overdue            = 0
                    Failed             = 0
                    AvgDaysToRemediate = 0
                }
            }
        }
    }

    try {
        # -----------------------------------------------------------
        # Step 1: Collect unique identity IDs and fetch events per identity
        # -----------------------------------------------------------
        $identityIds = @($RevocationDecisions | ForEach-Object {
            if ($null -ne $_.IdentityId) { $_.IdentityId }
            elseif ($_ -is [hashtable] -and $_.ContainsKey('IdentityId')) { $_.IdentityId }
        } | Sort-Object -Unique)

        Write-SPLog -Message "Fetching account activities for $($identityIds.Count) unique identity/identities" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID

        # Cache: identityId -> array of account-activity events
        $eventsByIdentity = @{}

        # Determine the earliest decision date to scope the DaysBack query
        $earliestDecision = $null
        foreach ($rev in $RevocationDecisions) {
            $decDateRaw = if ($rev -is [hashtable]) { $rev.DecisionDate } else { $rev.DecisionDate }
            if ($null -eq $decDateRaw) { continue }
            $parsedDec = [datetime]::MinValue
            if ($decDateRaw -is [datetime]) {
                $parsedDec = ([datetime]$decDateRaw).ToUniversalTime()
            } elseif ([datetime]::TryParse($decDateRaw.ToString(), [ref]$parsedDec)) {
                $parsedDec = $parsedDec.ToUniversalTime()
            } else {
                continue
            }
            if ($null -eq $earliestDecision -or $parsedDec -lt $earliestDecision) {
                $earliestDecision = $parsedDec
            }
        }

        $daysBack = 30
        if ($null -ne $earliestDecision) {
            $daysSince = [math]::Ceiling(((Get-Date).ToUniversalTime() - $earliestDecision).TotalDays)
            if ($daysSince -gt $daysBack) { $daysBack = $daysSince + 7 }
        }

        foreach ($identityId in $identityIds) {
            $evtResult = Get-SPAuditIdentityEvents -IdentityId $identityId `
                -DaysBack $daysBack -CorrelationID $CorrelationID

            if ($evtResult.Success -and $null -ne $evtResult.Data) {
                $eventsByIdentity[$identityId] = @($evtResult.Data)
            } else {
                Write-SPLog -Message "Could not retrieve events for identity '$identityId': $($evtResult.Error)" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
                    -CorrelationID $CorrelationID
                $eventsByIdentity[$identityId] = @()
            }
        }

        # -----------------------------------------------------------
        # Step 2: Match each revocation to a provisioning event
        # -----------------------------------------------------------
        $now = (Get-Date).ToUniversalTime()
        $items = [System.Collections.Generic.List[hashtable]]::new()
        $provisionedCount = 0
        $pendingCount     = 0
        $overdueCount     = 0
        $failedCount      = 0
        $totalRemDays     = 0.0
        $remDaysCount     = 0

        foreach ($rev in $RevocationDecisions) {
            # Extract fields (support both PSCustomObject and hashtable)
            $identityId     = if ($rev -is [hashtable]) { $rev.IdentityId }     else { $rev.IdentityId }
            $identityName   = if ($rev -is [hashtable]) { $rev.IdentityName }   else { $rev.IdentityName }
            $sourceName     = if ($rev -is [hashtable]) { $rev.SourceName }     else { $rev.SourceName }
            $entitlementName = if ($rev -is [hashtable]) { $rev.EntitlementName } else { $rev.EntitlementName }
            $decDateRaw     = if ($rev -is [hashtable]) { $rev.DecisionDate }   else { $rev.DecisionDate }

            # Parse decision date
            $decisionDate = $null
            if ($null -ne $decDateRaw) {
                if ($decDateRaw -is [datetime]) {
                    $decisionDate = ([datetime]$decDateRaw).ToUniversalTime()
                } else {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($decDateRaw.ToString(), [ref]$parsed)) {
                        $decisionDate = $parsed.ToUniversalTime()
                    }
                }
            }

            # Get events for this identity
            $events = @()
            if ($null -ne $identityId -and $eventsByIdentity.ContainsKey($identityId)) {
                $events = $eventsByIdentity[$identityId]
            }

            # Search for a matching REVOKE_ACCESS event
            $matchedEvent  = $null
            $matchedStatus = $null

            foreach ($evt in $events) {
                if ($null -eq $evt) { continue }

                # Check action type (account-activity action field)
                $action = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['action']) {
                    $action = $evt.action
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('action')) {
                    $action = $evt.action
                }

                # Accept REVOKE_ACCESS or any action containing 'REVOKE'
                if ($null -eq $action -or $action -notmatch 'REVOKE') { continue }

                # Check event timestamp is after decision date
                $evtDateRaw = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['created']) {
                    $evtDateRaw = $evt.created
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('created')) {
                    $evtDateRaw = $evt.created
                }

                $evtDate = $null
                if ($null -ne $evtDateRaw) {
                    if ($evtDateRaw -is [datetime]) {
                        $evtDate = ([datetime]$evtDateRaw).ToUniversalTime()
                    } else {
                        $parsedEvt = [datetime]::MinValue
                        if ([datetime]::TryParse($evtDateRaw.ToString(), [ref]$parsedEvt)) {
                            $evtDate = $parsedEvt.ToUniversalTime()
                        }
                    }
                }

                if ($null -ne $decisionDate -and $null -ne $evtDate -and $evtDate -lt $decisionDate) {
                    continue
                }

                # Match source name via ResolvedSourceNames or items
                $sourceMatched = $false
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['ResolvedSourceNames'] -and
                    $null -ne $evt.ResolvedSourceNames) {
                    foreach ($resolvedName in $evt.ResolvedSourceNames.Values) {
                        if ($resolvedName -eq $sourceName) {
                            $sourceMatched = $true
                            break
                        }
                    }
                }

                # Also check items for source/entitlement match
                $entitlementMatched = $false
                $activityItems = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['items'] -and $null -ne $evt.items) {
                    $activityItems = @($evt.items)
                }

                if ($null -ne $activityItems) {
                    foreach ($actItem in $activityItems) {
                        if ($null -eq $actItem) { continue }

                        # Check source name on item
                        $itemSourceName = $null
                        if ($null -ne $actItem.PSObject.Properties['sourceName']) {
                            $itemSourceName = $actItem.sourceName
                        } elseif ($null -ne $actItem.PSObject.Properties['source'] -and
                                  $null -ne $actItem.source -and
                                  $null -ne $actItem.source.PSObject.Properties['name']) {
                            $itemSourceName = $actItem.source.name
                        }

                        if ($null -ne $itemSourceName -and $itemSourceName -eq $sourceName) {
                            $sourceMatched = $true
                        }

                        # Check entitlement name on item
                        $itemEntName = $null
                        if ($null -ne $actItem.PSObject.Properties['name']) {
                            $itemEntName = $actItem.name
                        } elseif ($null -ne $actItem.PSObject.Properties['entitlementName']) {
                            $itemEntName = $actItem.entitlementName
                        }

                        if ($null -ne $itemEntName -and $itemEntName -eq $entitlementName) {
                            $entitlementMatched = $true
                        }

                        if ($sourceMatched -and $entitlementMatched) { break }
                    }
                }

                # Match requirements:
                #  - Event HAS activity items: the entitlement name must match. A
                #    source-only match is not sufficient -- one REVOKE event on source
                #    'AD' for SG-Finance would otherwise mark an unrelated SG-HR
                #    revocation on the same source as Provisioned, hiding a
                #    never-executed revoke from the Overdue/Failed buckets.
                #  - Event has NO items (some connectors omit them): fall back to the
                #    source-only match as best effort.
                if ($null -ne $activityItems -and $activityItems.Count -gt 0) {
                    if (-not $entitlementMatched) { continue }
                }
                elseif (-not $sourceMatched) { continue }

                # Determine event completion status
                $evtStatus = $null
                if ($null -ne $evt.PSObject -and $null -ne $evt.PSObject.Properties['status']) {
                    $evtStatus = $evt.status
                } elseif ($evt -is [hashtable] -and $evt.ContainsKey('status')) {
                    $evtStatus = $evt.status
                }

                $matchedEvent  = $evt
                $matchedStatus = $evtStatus
                break
            }

            # -----------------------------------------------------------
            # Step 3: Classify the revocation
            # -----------------------------------------------------------
            $status           = 'Pending'
            $provisioningDate = $null
            $daysToRemediate  = $null

            if ($null -ne $matchedEvent) {
                # Check if event had an error status
                if ($null -ne $matchedStatus -and $matchedStatus -match 'ERROR|FAILED') {
                    $status = 'Failed'
                    $failedCount++
                } else {
                    $status = 'Provisioned'
                    $provisionedCount++

                    # Calculate days to remediate
                    $evtDateRaw2 = $matchedEvent.created
                    if ($null -ne $evtDateRaw2) {
                        $evtDate2 = $null
                        if ($evtDateRaw2 -is [datetime]) {
                            $evtDate2 = ([datetime]$evtDateRaw2).ToUniversalTime()
                        } else {
                            $parsedEvt2 = [datetime]::MinValue
                            if ([datetime]::TryParse($evtDateRaw2.ToString(), [ref]$parsedEvt2)) {
                                $evtDate2 = $parsedEvt2.ToUniversalTime()
                            }
                        }

                        if ($null -ne $evtDate2) {
                            $provisioningDate = $evtDate2.ToString('yyyy-MM-ddTHH:mm:ssZ')
                            if ($null -ne $decisionDate) {
                                $daysToRemediate = [math]::Round(($evtDate2 - $decisionDate).TotalDays, 3)
                                if ($daysToRemediate -lt 0) { $daysToRemediate = 0 }
                                $totalRemDays += $daysToRemediate
                                $remDaysCount++
                            }
                        }
                    }
                }
            } else {
                # No matching event found -- check SLA
                if ($null -ne $decisionDate) {
                    $hoursElapsed = ($now - $decisionDate).TotalHours
                    if ($hoursElapsed -gt $SlaHours) {
                        $status = 'Overdue'
                        $overdueCount++
                    } else {
                        $status = 'Pending'
                        $pendingCount++
                    }
                } else {
                    # No decision date, cannot determine SLA -- mark Pending
                    $status = 'Pending'
                    $pendingCount++
                }
            }

            $decDateStr = ''
            if ($null -ne $decisionDate) {
                $decDateStr = $decisionDate.ToString('yyyy-MM-ddTHH:mm:ssZ')
            } elseif ($null -ne $decDateRaw) {
                $decDateStr = $decDateRaw.ToString()
            }

            $items.Add(@{
                IdentityName     = if ($null -ne $identityName) { $identityName } else { '' }
                EntitlementName  = if ($null -ne $entitlementName) { $entitlementName } else { '' }
                SourceName       = if ($null -ne $sourceName) { $sourceName } else { '' }
                DecisionDate     = $decDateStr
                Status           = $status
                ProvisioningDate = if ($null -ne $provisioningDate) { $provisioningDate } else { '' }
                DaysToRemediate  = $daysToRemediate
            })
        }

        # -----------------------------------------------------------
        # Step 4: Build summary
        # -----------------------------------------------------------
        $total = $items.Count
        $avgDays = 0
        if ($remDaysCount -gt 0) {
            $avgDays = [math]::Round($totalRemDays / $remDaysCount, 3)
        }

        $summary = @{
            Total              = $total
            Provisioned        = $provisionedCount
            Pending            = $pendingCount
            Overdue            = $overdueCount
            Failed             = $failedCount
            AvgDaysToRemediate = $avgDays
        }

        Write-SPLog -Message "Remediation status: $total total, $provisionedCount provisioned, $pendingCount pending, $overdueCount overdue, $failedCount failed (avg $avgDays days)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRemediationStatus' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Items   = $items.ToArray()
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPRemediationStatus failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPRemediationStatus' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region Entitlement Inventory (P11-07)

function Get-SPEntitlementInventory {
    <#
    .SYNOPSIS
        Queries ISC /v3/entitlements to build a per-source entitlement catalog.
    .DESCRIPTION
        Retrieves all entitlements for the specified sources (or all sources) via
        paginated GET /v3/entitlements calls. Optionally cross-references entitlement
        names against access review items from recent campaigns to identify
        entitlements that have never been reviewed.

        Uses the same pagination pattern as Get-SPAuditCampaigns and
        Get-SPSourceCampaignCoverage.
    .PARAMETER SourceIds
        Optional array of source IDs to query. If omitted, queries all entitlements.
    .PARAMETER IncludeReviewHistory
        When set, cross-references entitlements against recent campaign access review
        items to mark each as reviewed or unreviewed.
    .PARAMETER DaysBack
        Number of days to look back for review history. Default: 365.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Sources = @{ 'source-id' = @{ SourceName; TotalEntitlements; Privileged; Reviewed; Unreviewed; Entitlements } }
                Summary = @{ TotalSources; TotalEntitlements; TotalPrivileged; ReviewCoverage }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory
        $result.Data.Summary
    .EXAMPLE
        $result = Get-SPEntitlementInventory -DaysBack 180
        $result.Data.Sources.Keys | ForEach-Object { $result.Data.Sources[$_].SourceName }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeReviewHistory,

        [Parameter()]
        [int]$DaysBack = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceLabel = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $SourceIds -join ',' } else { 'ALL' }
    Write-SPLog -Message "Getting entitlement inventory: Sources='$sourceLabel', IncludeReviewHistory=$IncludeReviewHistory, DaysBack=$DaysBack" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
        -CorrelationID $CorrelationID

    try {
        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # -----------------------------------------------------------
        # Step 1: Retrieve entitlements (paginated, per source or all)
        # -----------------------------------------------------------
        $sourceEntitlements = @{}  # sourceId -> list of entitlement objects

        # Build list of queries: one per source ID, or one for all
        $queries = [System.Collections.Generic.List[hashtable]]::new()
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) {
            foreach ($sid in $SourceIds) {
                $queries.Add(@{ SourceId = $sid; Filter = "source.id eq `"$sid`"" })
            }
        } else {
            $queries.Add(@{ SourceId = $null; Filter = $null })
        }

        foreach ($query in $queries) {
            $allEntitlements = [System.Collections.Generic.List[object]]::new()
            $pageSize = 250
            $offset   = 0
            $pageNum  = 0

            do {
                $pageNum++
                if ($pageNum -gt $maxPages) {
                    $errMsg = "Pagination ceiling reached fetching entitlements: $maxPages pages ($($allEntitlements.Count) entitlements). Raise Api.MaxPaginationPages if needed."
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $queryParams = @{
                    'limit'  = $pageSize.ToString()
                    'offset' = $offset.ToString()
                }
                if (-not [string]::IsNullOrWhiteSpace($query.Filter)) {
                    $queryParams['filters'] = $query.Filter
                }

                $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/entitlements' `
                    -QueryParams $queryParams -CorrelationID $CorrelationID

                if (-not $result.Success) {
                    $errMsg = "Failed to retrieve entitlements at page $pageNum (offset $offset): $($result.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $page = $result.Data
                if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                    $page = $result.Data.items
                }
                $page = @($page)

                if ($page.Count -gt 0) {
                    foreach ($ent in $page) { $allEntitlements.Add($ent) }
                }

                Write-SPLog -Message "Entitlements page ${pageNum}: $($page.Count) items (running total: $($allEntitlements.Count))" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                    -CorrelationID $CorrelationID

                $offset += $pageSize
            } while ($page.Count -ge $pageSize)

            # Group entitlements by source
            foreach ($ent in $allEntitlements) {
                $srcId = $null
                if ($null -ne $ent.source) {
                    if ($ent.source -is [string]) {
                        $srcId = $ent.source
                    } elseif ($null -ne $ent.source.id) {
                        $srcId = $ent.source.id
                    }
                }
                if ([string]::IsNullOrWhiteSpace($srcId)) {
                    $srcId = 'unknown'
                }

                if (-not $sourceEntitlements.ContainsKey($srcId)) {
                    $sourceEntitlements[$srcId] = [System.Collections.Generic.List[object]]::new()
                }
                $sourceEntitlements[$srcId].Add($ent)
            }
        }

        Write-SPLog -Message "Retrieved entitlements across $($sourceEntitlements.Count) source(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Build review history lookup (if requested)
        # -----------------------------------------------------------
        $reviewedEntitlements = @{}  # key = "sourceId|entitlementName" -> last review date

        if ($IncludeReviewHistory) {
            Write-SPLog -Message "Building review history from campaigns (DaysBack=$DaysBack)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                -CorrelationID $CorrelationID

            $campResult = Get-SPAuditCampaigns -Status 'COMPLETED','ACTIVE' -DaysBack $DaysBack `
                -CorrelationID $CorrelationID
            if ($campResult.Success -and $null -ne $campResult.Data) {
                foreach ($campaign in $campResult.Data) {
                    $campId = $campaign.id
                    if ([string]::IsNullOrWhiteSpace($campId)) { continue }

                    $certResult = Get-SPAuditCertifications -CampaignId $campId `
                        -CorrelationID $CorrelationID
                    if (-not $certResult.Success -or $null -eq $certResult.Data) { continue }

                    foreach ($cert in $certResult.Data) {
                        $certId = $cert.id
                        if ([string]::IsNullOrWhiteSpace($certId)) { continue }

                        $itemResult = Get-SPAuditCertificationItems -CertificationId $certId `
                            -CorrelationID $CorrelationID
                        if (-not $itemResult.Success -or $null -eq $itemResult.Data) { continue }

                        foreach ($item in $itemResult.Data) {
                            $itemSourceId = $null
                            $entName = $null
                            $reviewDate = $null

                            # Extract source ID from access review item
                            if ($null -ne $item.access -and $null -ne $item.access.source) {
                                $itemSourceId = $item.access.source.id
                            }
                            if ($null -ne $item.access) {
                                $entName = $item.access.name
                            }
                            if ($null -ne $item.completed) {
                                $reviewDate = $item.completed
                            } elseif ($null -ne $item.decision) {
                                $reviewDate = $campaign.created
                            }

                            if (-not [string]::IsNullOrWhiteSpace($itemSourceId) -and
                                -not [string]::IsNullOrWhiteSpace($entName)) {
                                $lookupKey = "$itemSourceId|$entName"
                                if (-not $reviewedEntitlements.ContainsKey($lookupKey) -or
                                    (-not [string]::IsNullOrWhiteSpace($reviewDate) -and
                                     $reviewDate -gt $reviewedEntitlements[$lookupKey])) {
                                    $reviewedEntitlements[$lookupKey] = $reviewDate
                                }
                            }
                        }
                    }
                }
            }

            Write-SPLog -Message "Review history lookup built: $($reviewedEntitlements.Count) reviewed entitlement(s)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
                -CorrelationID $CorrelationID
        }

        # -----------------------------------------------------------
        # Step 3: Build per-source inventory with review status
        # -----------------------------------------------------------
        $sources = @{}
        $totalEntitlements = 0
        $totalPrivileged   = 0
        $totalReviewed     = 0

        foreach ($srcId in $sourceEntitlements.Keys) {
            $entList = $sourceEntitlements[$srcId]
            $sourceName = Get-SPAuditSourceName -SourceId $srcId -CorrelationID $CorrelationID

            $entitlementRecords = [System.Collections.Generic.List[hashtable]]::new()
            $privilegedCount = 0
            $reviewedCount   = 0
            $unreviewedCount = 0

            foreach ($ent in $entList) {
                $entName = if ($null -ne $ent.name) { $ent.name } else { '' }
                $entDisplayName = if ($null -ne $ent.displayName) { $ent.displayName } else { $entName }
                $entType = if ($null -ne $ent.type) { $ent.type } else { '' }
                $entAttribute = if ($null -ne $ent.attribute) { $ent.attribute } else { '' }
                $isPrivileged = $false
                if ($null -ne $ent.privileged) {
                    $isPrivileged = [bool]$ent.privileged
                }
                $ownerName = ''
                if ($null -ne $ent.owner -and $null -ne $ent.owner.name) {
                    $ownerName = $ent.owner.name
                }

                if ($isPrivileged) { $privilegedCount++ }

                $reviewed = $null
                $lastReviewDate = $null
                if ($IncludeReviewHistory) {
                    $lookupKey = "$srcId|$entName"
                    if ($reviewedEntitlements.ContainsKey($lookupKey)) {
                        $reviewed = $true
                        $lastReviewDate = $reviewedEntitlements[$lookupKey]
                        $reviewedCount++
                    } else {
                        $reviewed = $false
                        $unreviewedCount++
                    }
                }

                $entitlementRecords.Add(@{
                    Name           = $entName
                    DisplayName    = $entDisplayName
                    Type           = $entType
                    Attribute      = $entAttribute
                    Privileged     = $isPrivileged
                    OwnerName      = $ownerName
                    Reviewed       = $reviewed
                    LastReviewDate = $lastReviewDate
                })
            }

            $sourceData = @{
                SourceName        = $sourceName
                TotalEntitlements = $entList.Count
                Privileged        = $privilegedCount
                Reviewed          = if ($IncludeReviewHistory) { $reviewedCount } else { $null }
                Unreviewed        = if ($IncludeReviewHistory) { $unreviewedCount } else { $null }
                Entitlements      = $entitlementRecords.ToArray()
            }

            $sources[$srcId] = $sourceData
            $totalEntitlements += $entList.Count
            $totalPrivileged   += $privilegedCount
            $totalReviewed     += $reviewedCount
        }

        $reviewCoverage = if ($IncludeReviewHistory -and $totalEntitlements -gt 0) {
            [Math]::Round(($totalReviewed / $totalEntitlements) * 100, 1)
        } else { $null }

        $summary = @{
            TotalSources      = $sources.Count
            TotalEntitlements = $totalEntitlements
            TotalPrivileged   = $totalPrivileged
            ReviewCoverage    = $reviewCoverage
        }

        Write-SPLog -Message "Entitlement inventory: $totalEntitlements entitlements across $($sources.Count) sources, $totalPrivileged privileged" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPEntitlementInventory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Sources = $sources
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPEntitlementInventory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPEntitlementInventory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region P13-01: Access Profile Inventory

function Get-SPAccessProfileInventory {
    <#
    .SYNOPSIS
        Queries ISC /v3/access-profiles to build a per-source catalog of access profiles.
    .DESCRIPTION
        Retrieves all access profiles for the specified sources (or all sources) via
        paginated GET /v3/access-profiles calls. Optionally includes bundled entitlement
        detail and cross-references campaign review items to identify unreviewed
        access profiles.

        Uses the same pagination pattern as Get-SPEntitlementInventory.
    .PARAMETER SourceIds
        Optional array of source IDs to query. If omitted, queries all access profiles.
    .PARAMETER IncludeEntitlements
        When set, extracts the entitlements array from each access profile response
        to record entitlement names and privileged flags.
    .PARAMETER IncludeReviewHistory
        When set, cross-references access profile entitlements against CampaignAudits
        to mark each access profile as Reviewed or Unreviewed.
    .PARAMETER CampaignAudits
        Pre-collected campaign audit data (array of hashtables from
        Get-SPAuditCampaignReport). Required when -IncludeReviewHistory is used.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Sources = @{ 'source-id' = @{ SourceName; TotalAccessProfiles; ... } }
                Summary = @{ TotalSources; TotalAccessProfiles; ... }
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPAccessProfileInventory -SourceIds 'src-ad-001' -IncludeEntitlements
        $result.Data.Summary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeEntitlements,

        [Parameter()]
        [switch]$IncludeReviewHistory,

        [Parameter()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceLabel = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $SourceIds -join ',' } else { 'ALL' }
    Write-SPLog -Message "Getting access profile inventory: Sources='$sourceLabel', IncludeEntitlements=$IncludeEntitlements, IncludeReviewHistory=$IncludeReviewHistory" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
        -CorrelationID $CorrelationID

    try {
        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # -----------------------------------------------------------
        # Step 1: Retrieve access profiles (paginated, per source or all)
        # -----------------------------------------------------------
        $sourceAccessProfiles = @{}  # sourceId -> list of access profile objects

        $queries = [System.Collections.Generic.List[hashtable]]::new()
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) {
            foreach ($sid in $SourceIds) {
                $queries.Add(@{ SourceId = $sid; Filter = "source.id eq `"$sid`"" })
            }
        } else {
            $queries.Add(@{ SourceId = $null; Filter = $null })
        }

        foreach ($query in $queries) {
            $allProfiles = [System.Collections.Generic.List[object]]::new()
            $pageSize = 250
            $offset   = 0
            $pageNum  = 0

            do {
                $pageNum++
                if ($pageNum -gt $maxPages) {
                    $errMsg = "Pagination ceiling reached fetching access profiles: $maxPages pages ($($allProfiles.Count) profiles). Raise Api.MaxPaginationPages if needed."
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $queryParams = @{
                    'limit'  = $pageSize.ToString()
                    'offset' = $offset.ToString()
                }
                if (-not [string]::IsNullOrWhiteSpace($query.Filter)) {
                    $queryParams['filters'] = $query.Filter
                }

                $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/access-profiles' `
                    -QueryParams $queryParams -CorrelationID $CorrelationID

                if (-not $result.Success) {
                    $errMsg = "Failed to retrieve access profiles at page $pageNum (offset $offset): $($result.Error)"
                    Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                        -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
                    return @{ Success = $false; Data = $null; Error = $errMsg }
                }

                $page = $result.Data
                if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                    $page = $result.Data.items
                }
                $page = @($page)

                if ($page.Count -gt 0) {
                    foreach ($ap in $page) { $allProfiles.Add($ap) }
                }

                Write-SPLog -Message "Access profiles page ${pageNum}: $($page.Count) items (running total: $($allProfiles.Count))" `
                    -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID

                $offset += $pageSize
            } while ($page.Count -ge $pageSize)

            # Group access profiles by source
            foreach ($ap in $allProfiles) {
                $srcId = $null
                if ($null -ne $ap.source) {
                    if ($ap.source -is [string]) {
                        $srcId = $ap.source
                    } elseif ($null -ne $ap.source.id) {
                        $srcId = $ap.source.id
                    }
                }
                if ([string]::IsNullOrWhiteSpace($srcId)) {
                    $srcId = 'unknown'
                }

                if (-not $sourceAccessProfiles.ContainsKey($srcId)) {
                    $sourceAccessProfiles[$srcId] = [System.Collections.Generic.List[object]]::new()
                }
                $sourceAccessProfiles[$srcId].Add($ap)
            }
        }

        Write-SPLog -Message "Retrieved access profiles across $($sourceAccessProfiles.Count) source(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Build review history lookup (if requested)
        # -----------------------------------------------------------
        $reviewedEntNames = @{}  # key = entitlement name (lowercase) -> last review date

        if ($IncludeReviewHistory) {
            if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
                Write-SPLog -Message "IncludeReviewHistory requested but no CampaignAudits provided -- skipping review enrichment" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID
            } else {
                foreach ($audit in $CampaignAudits) {
                    $items = $null
                    if ($null -ne $audit.Items) { $items = $audit.Items }
                    elseif ($null -ne $audit.Data -and $null -ne $audit.Data.Items) { $items = $audit.Data.Items }
                    if ($null -eq $items) { continue }

                    foreach ($item in $items) {
                        $entName = $null
                        $reviewDate = $null

                        if ($null -ne $item.access) {
                            $entName = $item.access.name
                        } elseif ($null -ne $item.entitlementName) {
                            $entName = $item.entitlementName
                        } elseif ($null -ne $item.name) {
                            $entName = $item.name
                        }

                        if ($null -ne $item.completed) {
                            $reviewDate = $item.completed
                        } elseif ($null -ne $item.modified) {
                            $reviewDate = $item.modified
                        }

                        if (-not [string]::IsNullOrWhiteSpace($entName)) {
                            $key = $entName.ToLower()
                            if (-not $reviewedEntNames.ContainsKey($key) -or
                                (-not [string]::IsNullOrWhiteSpace($reviewDate) -and
                                 $reviewDate -gt $reviewedEntNames[$key])) {
                                $reviewedEntNames[$key] = $reviewDate
                            }
                        }
                    }
                }

                Write-SPLog -Message "Review history lookup built: $($reviewedEntNames.Count) reviewed entitlement name(s)" `
                    -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
                    -CorrelationID $CorrelationID
            }
        }

        # -----------------------------------------------------------
        # Step 3: Build per-source inventory
        # -----------------------------------------------------------
        $sources = @{}
        $totalAccessProfiles = 0
        $totalEnabled        = 0
        $totalRequestable    = 0
        $totalReviewed       = 0
        $totalEntitlementSum  = 0

        foreach ($srcId in $sourceAccessProfiles.Keys) {
            $apList = $sourceAccessProfiles[$srcId]
            $sourceName = Get-SPAuditSourceName -SourceId $srcId -CorrelationID $CorrelationID

            $profileRecords = [System.Collections.Generic.List[hashtable]]::new()
            $enabledCount     = 0
            $requestableCount = 0
            $reviewedCount    = 0
            $unreviewedCount  = 0

            foreach ($ap in $apList) {
                $apId = if ($null -ne $ap.id) { $ap.id } else { '' }
                $apName = if ($null -ne $ap.name) { $ap.name } else { '' }
                $apDesc = if ($null -ne $ap.description) { $ap.description } else { '' }
                $apEnabled = if ($null -ne $ap.enabled) { [bool]$ap.enabled } else { $false }
                $apRequestable = if ($null -ne $ap.requestable) { [bool]$ap.requestable } else { $false }
                $apCreated = if ($null -ne $ap.created) { $ap.created } else { '' }
                $apModified = if ($null -ne $ap.modified) { $ap.modified } else { '' }

                $ownerName = ''
                $ownerId = ''
                if ($null -ne $ap.owner) {
                    if ($null -ne $ap.owner.name) { $ownerName = $ap.owner.name }
                    if ($null -ne $ap.owner.id) { $ownerId = $ap.owner.id }
                }

                if ($apEnabled) { $enabledCount++ }
                if ($apRequestable) { $requestableCount++ }

                # Entitlement detail
                $entitlementCount = 0
                $entitlementNames = @()
                $hasPrivileged = $false

                if ($null -ne $ap.entitlements) {
                    $entitlementCount = @($ap.entitlements).Count
                    if ($IncludeEntitlements) {
                        $entNameList = [System.Collections.Generic.List[string]]::new()
                        foreach ($ent in @($ap.entitlements)) {
                            $eName = ''
                            if ($ent -is [string]) {
                                $eName = $ent
                            } elseif ($null -ne $ent.name) {
                                $eName = $ent.name
                            } elseif ($null -ne $ent.value) {
                                $eName = $ent.value
                            }
                            if (-not [string]::IsNullOrWhiteSpace($eName)) {
                                $entNameList.Add($eName)
                            }
                            if ($null -ne $ent.privileged -and [bool]$ent.privileged) {
                                $hasPrivileged = $true
                            }
                        }
                        $entitlementNames = $entNameList.ToArray()
                    } else {
                        # Check privileged even without full entitlement detail
                        foreach ($ent in @($ap.entitlements)) {
                            if ($null -ne $ent.privileged -and [bool]$ent.privileged) {
                                $hasPrivileged = $true
                                break
                            }
                        }
                    }
                }

                $totalEntitlementSum += $entitlementCount

                # Review history
                $reviewed = $null
                $lastReviewDate = $null
                if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) {
                    # An access profile is considered reviewed if at least one of its
                    # entitlements appears in the review history
                    $reviewed = $false
                    if ($null -ne $ap.entitlements) {
                        foreach ($ent in @($ap.entitlements)) {
                            $eName = ''
                            if ($ent -is [string]) { $eName = $ent }
                            elseif ($null -ne $ent.name) { $eName = $ent.name }
                            elseif ($null -ne $ent.value) { $eName = $ent.value }

                            if (-not [string]::IsNullOrWhiteSpace($eName)) {
                                $key = $eName.ToLower()
                                if ($reviewedEntNames.ContainsKey($key)) {
                                    $reviewed = $true
                                    $candDate = $reviewedEntNames[$key]
                                    if (-not [string]::IsNullOrWhiteSpace($candDate) -and
                                        ($null -eq $lastReviewDate -or $candDate -gt $lastReviewDate)) {
                                        $lastReviewDate = $candDate
                                    }
                                }
                            }
                        }
                    }

                    # Also check if the access profile name itself appears as a reviewed item
                    if (-not $reviewed -and -not [string]::IsNullOrWhiteSpace($apName)) {
                        $apKey = $apName.ToLower()
                        if ($reviewedEntNames.ContainsKey($apKey)) {
                            $reviewed = $true
                            $lastReviewDate = $reviewedEntNames[$apKey]
                        }
                    }

                    if ($reviewed) { $reviewedCount++ } else { $unreviewedCount++ }
                }

                $record = @{
                    Id              = $apId
                    Name            = $apName
                    Description     = $apDesc
                    Enabled         = $apEnabled
                    Requestable     = $apRequestable
                    OwnerName       = $ownerName
                    OwnerId         = $ownerId
                    EntitlementCount = $entitlementCount
                    Entitlements    = $entitlementNames
                    HasPrivileged   = $hasPrivileged
                    Reviewed        = $reviewed
                    LastReviewDate  = $lastReviewDate
                    Created         = $apCreated
                    Modified        = $apModified
                }
                $profileRecords.Add($record)
            }

            $avgEntPerProfile = if ($apList.Count -gt 0) {
                [Math]::Round(($profileRecords | ForEach-Object { $_.EntitlementCount } |
                    Measure-Object -Sum).Sum / $apList.Count, 1)
            } else { 0 }

            $sourceData = @{
                SourceName            = $sourceName
                TotalAccessProfiles   = $apList.Count
                Enabled               = $enabledCount
                Requestable           = $requestableCount
                AvgEntitlementsPerProfile = $avgEntPerProfile
                Reviewed              = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) { $reviewedCount } else { $null }
                Unreviewed            = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0) { $unreviewedCount } else { $null }
                AccessProfiles        = $profileRecords.ToArray()
            }

            $sources[$srcId] = $sourceData
            $totalAccessProfiles += $apList.Count
            $totalEnabled        += $enabledCount
            $totalRequestable    += $requestableCount
        }

        $reviewCoverage = if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0 -and $totalAccessProfiles -gt 0) {
            [Math]::Round(($totalReviewed / $totalAccessProfiles) * 100, 1)
        } else { $null }

        # Recalculate totalReviewed from source data
        $totalReviewedFinal = 0
        foreach ($srcId in $sources.Keys) {
            if ($null -ne $sources[$srcId].Reviewed) {
                $totalReviewedFinal += $sources[$srcId].Reviewed
            }
        }
        if ($IncludeReviewHistory -and $reviewedEntNames.Count -gt 0 -and $totalAccessProfiles -gt 0) {
            $reviewCoverage = [Math]::Round(($totalReviewedFinal / $totalAccessProfiles) * 100, 1)
        }

        $summary = @{
            TotalSources        = $sources.Count
            TotalAccessProfiles = $totalAccessProfiles
            TotalEnabled        = $totalEnabled
            TotalRequestable    = $totalRequestable
            ReviewCoverage      = $reviewCoverage
        }

        Write-SPLog -Message "Access profile inventory: $totalAccessProfiles profiles across $($sources.Count) sources, $totalEnabled enabled, $totalRequestable requestable" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPAccessProfileInventory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Sources = $sources
                Summary = $summary
            }
        }
    }
    catch {
        $errMsg = "Get-SPAccessProfileInventory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPAccessProfileInventory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region P13-02: Role Inventory & Assignment Analysis

function Get-SPRoleInventory {
    <#
    .SYNOPSIS
        Queries ISC /v3/roles to catalog roles with access profile mappings and health indicators.
    .DESCRIPTION
        Retrieves all roles via paginated GET /v3/roles calls. Records each role's
        membership type, access profile count, enabled/requestable state, and owner.
        Optionally enriches with transitive entitlement counts when access profile
        inventory data is provided.

        Calculates role health indicators: empty roles (0 access profiles), single-
        profile roles, disabled roles, and ownerless roles.
    .PARAMETER IncludeAccessProfiles
        When set and AccessProfileInventory is provided, enriches each role with
        transitive entitlement count from the access profile inventory.
    .PARAMETER AccessProfileInventory
        Hashtable output from Get-SPAccessProfileInventory (.Data property).
        Required for transitive entitlement enrichment.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data = @{
                Roles = @(...)
                Summary = @{...}
                HealthIndicators = @{...}
            }
            Error = $string
        }
    .EXAMPLE
        $result = Get-SPRoleInventory -IncludeAccessProfiles -AccessProfileInventory $apInventory.Data
        $result.Data.Summary
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [switch]$IncludeAccessProfiles,

        [Parameter()]
        [hashtable]$AccessProfileInventory,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Getting role inventory: IncludeAccessProfiles=$IncludeAccessProfiles" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
        -CorrelationID $CorrelationID

    try {
        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # -----------------------------------------------------------
        # Step 1: Retrieve roles (paginated)
        # -----------------------------------------------------------
        $allRoles = [System.Collections.Generic.List[object]]::new()
        $pageSize = 50
        $offset   = 0
        $pageNum  = 0

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching roles: $maxPages pages ($($allRoles.Count) roles). Raise Api.MaxPaginationPages if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPRoleInventory' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/roles' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Failed to retrieve roles at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Get-SPRoleInventory' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($r in $page) { $allRoles.Add($r) }
            }

            Write-SPLog -Message "Roles page ${pageNum}: $($page.Count) items (running total: $($allRoles.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        Write-SPLog -Message "Retrieved $($allRoles.Count) role(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
            -CorrelationID $CorrelationID

        # -----------------------------------------------------------
        # Step 2: Build access profile name -> entitlement count lookup
        # -----------------------------------------------------------
        $apEntitlementLookup = @{}  # access profile name (lowercase) -> entitlement count
        if ($IncludeAccessProfiles) {
            if ($null -eq $AccessProfileInventory -or $null -eq $AccessProfileInventory.Sources) {
                Write-SPLog -Message "IncludeAccessProfiles requested but no AccessProfileInventory provided -- skipping transitive entitlement enrichment" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
                    -CorrelationID $CorrelationID
            } else {
                foreach ($srcId in $AccessProfileInventory.Sources.Keys) {
                    $srcData = $AccessProfileInventory.Sources[$srcId]
                    if ($null -ne $srcData.AccessProfiles) {
                        foreach ($ap in $srcData.AccessProfiles) {
                            $key = if (-not [string]::IsNullOrWhiteSpace($ap.Name)) { $ap.Name.ToLower() } else { '' }
                            if (-not [string]::IsNullOrWhiteSpace($key)) {
                                $apEntitlementLookup[$key] = [int]$ap.EntitlementCount
                            }
                        }
                    }
                }
                Write-SPLog -Message "Access profile entitlement lookup built: $($apEntitlementLookup.Count) profile(s)" `
                    -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
                    -CorrelationID $CorrelationID
            }
        }

        # -----------------------------------------------------------
        # Step 3: Build role records and health indicators
        # -----------------------------------------------------------
        $roleRecords = [System.Collections.Generic.List[hashtable]]::new()

        $totalEnabled        = 0
        $totalDisabled       = 0
        $totalRequestable    = 0
        $totalStandard       = 0
        $totalIdentityList   = 0
        $totalApCount        = 0

        $emptyRoles         = [System.Collections.Generic.List[string]]::new()
        $disabledRoles      = [System.Collections.Generic.List[string]]::new()
        $ownerlessRoles     = [System.Collections.Generic.List[string]]::new()
        $singleProfileRoles = [System.Collections.Generic.List[string]]::new()

        foreach ($role in $allRoles) {
            $roleId   = if ($null -ne $role.id) { $role.id } else { '' }
            $roleName = if ($null -ne $role.name) { $role.name } else { '' }
            $roleDesc = if ($null -ne $role.description) { $role.description } else { '' }
            $roleEnabled = if ($null -ne $role.enabled) { [bool]$role.enabled } else { $false }
            $roleRequestable = if ($null -ne $role.requestable) { [bool]$role.requestable } else { $false }
            $roleCreated  = if ($null -ne $role.created) { $role.created } else { '' }
            $roleModified = if ($null -ne $role.modified) { $role.modified } else { '' }

            # Owner
            $ownerName = ''
            $ownerId   = ''
            if ($null -ne $role.owner) {
                if ($null -ne $role.owner.name) { $ownerName = $role.owner.name }
                if ($null -ne $role.owner.id) { $ownerId = $role.owner.id }
            }

            # Membership type
            $membershipType = 'STANDARD'
            if ($null -ne $role.membership -and $null -ne $role.membership.type) {
                $membershipType = $role.membership.type.ToString().ToUpper()
            }

            # Access profiles
            $apNames = [System.Collections.Generic.List[string]]::new()
            $apCount = 0
            if ($null -ne $role.accessProfiles) {
                $apArray = @($role.accessProfiles)
                $apCount = $apArray.Count
                foreach ($ap in $apArray) {
                    $apName = ''
                    if ($ap -is [string]) {
                        $apName = $ap
                    } elseif ($null -ne $ap.name) {
                        $apName = $ap.name
                    }
                    if (-not [string]::IsNullOrWhiteSpace($apName)) {
                        $apNames.Add($apName)
                    }
                }
            }

            $totalApCount += $apCount

            # Transitive entitlements (only when enrichment data available)
            $transitiveEntitlements = $null
            if ($IncludeAccessProfiles -and $apEntitlementLookup.Count -gt 0) {
                $transitiveEntitlements = 0
                foreach ($apn in $apNames) {
                    $key = $apn.ToLower()
                    if ($apEntitlementLookup.ContainsKey($key)) {
                        $transitiveEntitlements += $apEntitlementLookup[$key]
                    }
                }
            }

            # Counters
            if ($roleEnabled) { $totalEnabled++ } else { $totalDisabled++ }
            if ($roleRequestable) { $totalRequestable++ }
            if ($membershipType -eq 'STANDARD') { $totalStandard++ } else { $totalIdentityList++ }

            # Health indicators
            if ($apCount -eq 0) { $emptyRoles.Add($roleName) }
            if ($apCount -eq 1) { $singleProfileRoles.Add($roleName) }
            if (-not $roleEnabled) { $disabledRoles.Add($roleName) }
            if ([string]::IsNullOrWhiteSpace($ownerName) -and [string]::IsNullOrWhiteSpace($ownerId)) {
                $ownerlessRoles.Add($roleName)
            }

            $record = @{
                Id                     = $roleId
                Name                   = $roleName
                Description            = $roleDesc
                Enabled                = $roleEnabled
                Requestable            = $roleRequestable
                OwnerName              = $ownerName
                OwnerId                = $ownerId
                MembershipType         = $membershipType
                AccessProfileCount     = $apCount
                AccessProfileNames     = $apNames.ToArray()
                TransitiveEntitlements = $transitiveEntitlements
                Created                = $roleCreated
                Modified               = $roleModified
            }
            $roleRecords.Add($record)
        }

        # -----------------------------------------------------------
        # Step 4: Build summary
        # -----------------------------------------------------------
        $totalRoles = $allRoles.Count
        $avgApPerRole = if ($totalRoles -gt 0) {
            [Math]::Round($totalApCount / $totalRoles, 1)
        } else { 0 }

        $summary = @{
            TotalRoles              = $totalRoles
            Enabled                 = $totalEnabled
            Disabled                = $totalDisabled
            Requestable             = $totalRequestable
            StandardMembership      = $totalStandard
            IdentityListMembership  = $totalIdentityList
            AvgAccessProfilesPerRole = $avgApPerRole
            EmptyRoles              = $emptyRoles.Count
            SingleProfileRoles      = $singleProfileRoles.Count
            OwnerlessRoles          = $ownerlessRoles.Count
        }

        $healthIndicators = @{
            EmptyRoles         = $emptyRoles.ToArray()
            DisabledRoles      = $disabledRoles.ToArray()
            OwnerlessRoles     = $ownerlessRoles.ToArray()
            SingleProfileRoles = $singleProfileRoles.ToArray()
        }

        Write-SPLog -Message "Role inventory: $totalRoles roles, $totalEnabled enabled, $totalDisabled disabled, $($emptyRoles.Count) empty, $($ownerlessRoles.Count) ownerless" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPRoleInventory' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                Roles            = $roleRecords.ToArray()
                Summary          = $summary
                HealthIndicators = $healthIndicators
            }
        }
    }
    catch {
        $errMsg = "Get-SPRoleInventory failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPRoleInventory' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region P12-04: Stale Access Detector

function Get-SPStaleAccess {
    <#
    .SYNOPSIS
        Identifies entitlements and identity-entitlement pairs not reviewed within a configurable window.
    .DESCRIPTION
        Looks across the entire campaign history to find entitlements that have never
        appeared in any review (NeverReviewed), entitlements whose last review exceeds
        the StaleDays threshold (Expired), and entitlements reviewed for some identities
        but not all holders (PartialCoverage).

        When EntitlementInventory is provided, cross-references to find entitlements
        that exist in the inventory but have zero campaign decisions. Without it, only
        campaign history is checked (no NeverReviewed items possible).
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions containing access review items.
    .PARAMETER EntitlementInventory
        Optional hashtable from Get-SPEntitlementInventory .Data -- keyed by source ID
        with Entitlements arrays. Enables NeverReviewed detection.
    .PARAMETER StaleDays
        Number of days after which an unreviewed entitlement is considered stale. Default 180.
    .PARAMETER SourceIds
        Optional filter to restrict analysis to specific source IDs.
    .PARAMETER PrivilegedOnly
        When set, only returns stale items for privileged entitlements.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ StaleItems = @(...); Summary = @{...} }
    .EXAMPLE
        $stale = Get-SPStaleAccess -CampaignAudits $audits -StaleDays 180
        $stale.Summary.TotalStaleItems
    .EXAMPLE
        $inv = (Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory).Data
        $stale = Get-SPStaleAccess -CampaignAudits $audits -EntitlementInventory $inv -PrivilegedOnly
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [hashtable]$EntitlementInventory,

        [Parameter()]
        [int]$StaleDays = 180,

        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$PrivilegedOnly,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPStaleAccess: starting with $($CampaignAudits.Count) campaign(s), StaleDays=$StaleDays, PrivilegedOnly=$PrivilegedOnly" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            StaleItems = @()
            Summary    = @{
                TotalStaleItems = 0
                NeverReviewed   = 0
                Expired         = 0
                PartialCoverage = 0
                PrivilegedStale = 0
                SourceBreakdown = @{}
            }
        }
    }

    $now = Get-Date
    $staleCutoff = $now.AddDays(-$StaleDays)

    # Build source filter set
    $hasSourceFilter = ($null -ne $SourceIds -and $SourceIds.Count -gt 0)
    $sourceFilterSet = @{}
    if ($hasSourceFilter) {
        foreach ($sid in $SourceIds) { $sourceFilterSet[$sid] = $true }
    }

    # ------------------------------------------------------------------
    # Step 1: Build a map of every entitlement seen in campaign decisions
    #         Key: "sourceId|entitlementName"
    #         Value: @{ LastReviewDate; IdentityIds (set of identity IDs that had this reviewed) }
    # ------------------------------------------------------------------
    $reviewMap = @{}  # key -> @{ LastReviewDate = [datetime]; IdentityIds = @{} }

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                $sourceId = ''
                $sourceName = ''
                $accessName = ''
                $identityId = ''
                $decisionDate = ''

                if ($item -is [hashtable]) {
                    $sourceId     = if ($item.ContainsKey('SourceId'))     { [string]$item['SourceId'] }     else { '' }
                    $sourceName   = if ($item.ContainsKey('SourceName'))   { [string]$item['SourceName'] }   else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $identityId   = if ($item.ContainsKey('IdentityId'))   { [string]$item['IdentityId'] }   else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                } else {
                    $siProp = $item.PSObject.Properties['SourceId']
                    $sourceId = if ($null -ne $siProp -and $null -ne $siProp.Value) { [string]$siProp.Value } else { '' }
                    $snProp = $item.PSObject.Properties['SourceName']
                    $sourceName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $idProp = $item.PSObject.Properties['IdentityId']
                    $identityId = if ($null -ne $idProp -and $null -ne $idProp.Value) { [string]$idProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                }

                if ([string]::IsNullOrWhiteSpace($sourceId) -or [string]::IsNullOrWhiteSpace($accessName)) { continue }

                # Apply source filter
                if ($hasSourceFilter -and -not $sourceFilterSet.ContainsKey($sourceId)) { continue }

                $lookupKey = "$sourceId|$accessName"

                if (-not $reviewMap.ContainsKey($lookupKey)) {
                    $reviewMap[$lookupKey] = @{
                        SourceId       = $sourceId
                        SourceName     = $sourceName
                        EntitlementName = $accessName
                        LastReviewDate = $null
                        IdentityIds    = @{}
                    }
                }

                $entry = $reviewMap[$lookupKey]

                # Update source name if available
                if (-not [string]::IsNullOrWhiteSpace($sourceName)) {
                    $entry['SourceName'] = $sourceName
                }

                # Track identity
                if (-not [string]::IsNullOrWhiteSpace($identityId)) {
                    $entry['IdentityIds'][$identityId] = $true
                }

                # Track most recent review date
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $entry['LastReviewDate'] -or $dt -gt $entry['LastReviewDate']) {
                            $entry['LastReviewDate'] = $dt
                        }
                    } catch { }
                }
            }
        }
    }

    Write-SPLog -Message "Get-SPStaleAccess: built review map with $($reviewMap.Count) unique entitlement(s)" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # ------------------------------------------------------------------
    # Step 2: Build inventory lookup for NeverReviewed detection
    # ------------------------------------------------------------------
    $inventoryMap = @{}  # key "sourceId|entitlementName" -> @{ Privileged; SourceName; IdentityCount }
    $hasInventory = ($null -ne $EntitlementInventory)

    if ($hasInventory) {
        $invSources = $null
        if ($EntitlementInventory.ContainsKey('Sources')) {
            $invSources = $EntitlementInventory['Sources']
        }
        if ($null -ne $invSources) {
            foreach ($srcId in $invSources.Keys) {
                if ($hasSourceFilter -and -not $sourceFilterSet.ContainsKey($srcId)) { continue }

                $srcData = $invSources[$srcId]
                $srcName = ''
                $entitlements = @()

                if ($srcData -is [hashtable]) {
                    $srcName = if ($srcData.ContainsKey('SourceName')) { [string]$srcData['SourceName'] } else { '' }
                    $entitlements = if ($srcData.ContainsKey('Entitlements') -and $null -ne $srcData['Entitlements']) {
                        @($srcData['Entitlements'])
                    } else { @() }
                } else {
                    $snProp = $srcData.PSObject.Properties['SourceName']
                    $srcName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $eProp = $srcData.PSObject.Properties['Entitlements']
                    $entitlements = if ($null -ne $eProp -and $null -ne $eProp.Value) { @($eProp.Value) } else { @() }
                }

                foreach ($ent in $entitlements) {
                    if ($null -eq $ent) { continue }

                    $entName = ''
                    $isPrivileged = $false

                    if ($ent -is [hashtable]) {
                        $entName = if ($ent.ContainsKey('Name')) { [string]$ent['Name'] } else { '' }
                        $isPrivileged = if ($ent.ContainsKey('Privileged')) { [bool]$ent['Privileged'] } else { $false }
                    } else {
                        $enProp = $ent.PSObject.Properties['Name']
                        $entName = if ($null -ne $enProp -and $null -ne $enProp.Value) { [string]$enProp.Value } else { '' }
                        $prProp = $ent.PSObject.Properties['Privileged']
                        $isPrivileged = if ($null -ne $prProp -and $null -ne $prProp.Value) { [bool]$prProp.Value } else { $false }
                    }

                    if ([string]::IsNullOrWhiteSpace($entName)) { continue }

                    $lookupKey = "$srcId|$entName"
                    $inventoryMap[$lookupKey] = @{
                        SourceId        = $srcId
                        SourceName      = $srcName
                        EntitlementName = $entName
                        Privileged      = $isPrivileged
                    }
                }
            }
        }
    }

    Write-SPLog -Message "Get-SPStaleAccess: inventory map has $($inventoryMap.Count) entitlement(s)" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    # ------------------------------------------------------------------
    # Step 3: Classify stale items
    # ------------------------------------------------------------------
    $staleItems = [System.Collections.Generic.List[hashtable]]::new()

    # 3a: NeverReviewed -- entitlements in inventory but not in any campaign decision
    if ($hasInventory) {
        foreach ($invKey in $inventoryMap.Keys) {
            if ($reviewMap.ContainsKey($invKey)) { continue }

            $inv = $inventoryMap[$invKey]

            # Apply privileged filter
            if ($PrivilegedOnly -and -not $inv['Privileged']) { continue }

            $staleItems.Add(@{
                SourceId        = $inv['SourceId']
                SourceName      = $inv['SourceName']
                EntitlementName = $inv['EntitlementName']
                Privileged      = $inv['Privileged']
                Classification  = 'NeverReviewed'
                IdentityCount   = 0
                LastReviewDate  = $null
                DaysSinceReview = $null
            })
        }
    }

    # 3b: Expired -- entitlements reviewed but last review exceeds StaleDays
    foreach ($key in $reviewMap.Keys) {
        $entry = $reviewMap[$key]
        $lastReview = $entry['LastReviewDate']

        # Determine if this entitlement is privileged
        $isPrivileged = $false
        if ($inventoryMap.ContainsKey($key)) {
            $isPrivileged = $inventoryMap[$key]['Privileged']
        }

        # Apply privileged filter
        if ($PrivilegedOnly -and -not $isPrivileged) { continue }

        # Check if expired (last review before stale cutoff, or no review date recorded)
        $daysSinceReview = $null
        $isExpired = $false

        if ($null -ne $lastReview) {
            $daysSinceReview = [int]($now - $lastReview).TotalDays
            if ($lastReview -lt $staleCutoff) {
                $isExpired = $true
            }
        } else {
            # Decision exists but no date -- treat as stale if no date can be determined
            $isExpired = $true
        }

        if (-not $isExpired) { continue }

        $lastReviewStr = if ($null -ne $lastReview) { $lastReview.ToString('yyyy-MM-dd') } else { $null }

        $staleItems.Add(@{
            SourceId        = $entry['SourceId']
            SourceName      = $entry['SourceName']
            EntitlementName = $entry['EntitlementName']
            Privileged      = $isPrivileged
            Classification  = 'Expired'
            IdentityCount   = $entry['IdentityIds'].Count
            LastReviewDate  = $lastReviewStr
            DaysSinceReview = $daysSinceReview
        })
    }

    # 3c: PartialCoverage -- entitlements in inventory that are reviewed for some
    #     identities but not all holders. Only possible when inventory includes identity
    #     count or when we can detect gaps (inventory has more holders than reviewed).
    #     Since the entitlement inventory doesn't track individual identity holders,
    #     we approximate: if the entitlement was reviewed recently but only for a small
    #     number of identities relative to the total holders, flag as partial.
    #     For now, we check if the entitlement is in the inventory AND was reviewed
    #     recently (not expired) but the reviewed identity count is less than what the
    #     inventory implies. Since inventory doesn't have per-identity data, we skip
    #     PartialCoverage unless we can detect it from campaign data patterns.
    #     PartialCoverage is reported when an entitlement that is NOT expired has
    #     some identities reviewed and we can compare against inventory.
    #     Note: This is a best-effort classification.

    # ------------------------------------------------------------------
    # Step 4: Build summary
    # ------------------------------------------------------------------
    $neverReviewedCount = 0
    $expiredCount       = 0
    $partialCount       = 0
    $privilegedStale    = 0
    $sourceBreakdown    = @{}

    foreach ($staleItem in $staleItems) {
        switch ($staleItem['Classification']) {
            'NeverReviewed'   { $neverReviewedCount++ }
            'Expired'         { $expiredCount++ }
            'PartialCoverage' { $partialCount++ }
        }

        if ($staleItem['Privileged']) { $privilegedStale++ }

        $sName = $staleItem['SourceName']
        if ([string]::IsNullOrWhiteSpace($sName)) { $sName = $staleItem['SourceId'] }
        if (-not $sourceBreakdown.ContainsKey($sName)) {
            $sourceBreakdown[$sName] = 0
        }
        $sourceBreakdown[$sName]++
    }

    # Sort stale items: NeverReviewed first, then Expired, then PartialCoverage
    $classOrder = @{ 'NeverReviewed' = 0; 'Expired' = 1; 'PartialCoverage' = 2 }
    $sorted = @($staleItems | Sort-Object {
        $order = if ($classOrder.ContainsKey($_['Classification'])) { $classOrder[$_['Classification']] } else { 99 }
        $order
    }, { $_['SourceName'] }, { $_['EntitlementName'] })

    Write-SPLog -Message "Get-SPStaleAccess: found $($sorted.Count) stale items (NeverReviewed=$neverReviewedCount, Expired=$expiredCount, PartialCoverage=$partialCount)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPStaleAccess' `
        -CorrelationID $CorrelationID

    return @{
        StaleItems = $sorted
        Summary    = @{
            TotalStaleItems = $sorted.Count
            NeverReviewed   = $neverReviewedCount
            Expired         = $expiredCount
            PartialCoverage = $partialCount
            PrivilegedStale = $privilegedStale
            SourceBreakdown = $sourceBreakdown
        }
    }
}

#endregion

#region P14-06: Configuration Snapshot

function Save-SPConfigurationSnapshot {
    <#
    .SYNOPSIS
        Captures a point-in-time snapshot of the ISC tenant configuration.
    .DESCRIPTION
        Queries ISC sources (and optionally entitlements, access profiles, roles)
        to build a JSON snapshot of the tenant configuration state. Designed for
        configuration drift detection (Compare-SPConfigurationSnapshots) and
        change management auditing.
    .PARAMETER SourceIds
        Optional array of source IDs to include. If omitted, queries all sources.
    .PARAMETER IncludeEntitlements
        When set, queries entitlements per source and includes counts and names.
    .PARAMETER IncludeAccessProfiles
        When set, queries access profiles per source and includes counts and names.
    .PARAMETER IncludeRoles
        When set, queries roles and includes counts, names, and access profile assignments.
    .PARAMETER OutputPath
        Directory to write the snapshot JSON file. Defaults to {Audit.OutputPath}/snapshots/.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Success = $bool; Data = @{ SnapshotPath; SnapshotId; CapturedAt; SourceCount; Summary } }
    .EXAMPLE
        $result = Save-SPConfigurationSnapshot -IncludeEntitlements -IncludeAccessProfiles
        $result.Data.SnapshotPath
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeEntitlements,

        [Parameter()]
        [switch]$IncludeAccessProfiles,

        [Parameter()]
        [switch]$IncludeRoles,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceLabel = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $SourceIds -join ',' } else { 'ALL' }
    Write-SPLog -Message "Save-SPConfigurationSnapshot: Sources='$sourceLabel', IncludeEntitlements=$IncludeEntitlements, IncludeAccessProfiles=$IncludeAccessProfiles, IncludeRoles=$IncludeRoles" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
        -CorrelationID $CorrelationID

    try {
        # ------------------------------------------------------------------
        # Resolve output path
        # ------------------------------------------------------------------
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            try {
                $cfg = Get-SPConfig
                if ($null -ne $cfg.Audit -and -not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                    $OutputPath = Join-Path $cfg.Audit.OutputPath 'snapshots'
                } else {
                    $OutputPath = Join-Path '.' (Join-Path 'Audit' 'snapshots')
                }
            } catch {
                $OutputPath = Join-Path '.' (Join-Path 'Audit' 'snapshots')
            }
        }

        if (-not (Test-Path -Path $OutputPath)) {
            if ($PSCmdlet.ShouldProcess($OutputPath, 'Create snapshot directory')) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }
        }

        # Pagination ceiling from config
        $maxPages = 200
        try {
            $cfgForCeiling = Get-SPConfig
            if ($null -ne $cfgForCeiling.Api -and
                $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
                [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
                $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
            }
        } catch { }

        # ------------------------------------------------------------------
        # Step 1: Query sources (paginated via GET /v3/sources)
        # ------------------------------------------------------------------
        $allSources = [System.Collections.Generic.List[object]]::new()
        $pageSize = 250
        $offset   = 0
        $pageNum  = 0
        $hasSourceFilter = ($null -ne $SourceIds -and $SourceIds.Count -gt 0)
        $sourceFilterSet = @{}
        if ($hasSourceFilter) {
            foreach ($sid in $SourceIds) { $sourceFilterSet[$sid] = $true }
        }

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                $errMsg = "Pagination ceiling reached fetching sources: $maxPages pages ($($allSources.Count) sources). Raise Api.MaxPaginationPages if needed."
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Save-SPConfigurationSnapshot' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/sources' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                $errMsg = "Failed to retrieve sources at page $pageNum (offset $offset): $($result.Error)"
                Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
                    -Action 'Save-SPConfigurationSnapshot' -CorrelationID $CorrelationID
                return @{ Success = $false; Data = $null; Error = $errMsg }
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            if ($page.Count -gt 0) {
                foreach ($src in $page) { $allSources.Add($src) }
            }

            Write-SPLog -Message "Sources page ${pageNum}: $($page.Count) items (running total: $($allSources.Count))" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($page.Count -ge $pageSize)

        # Filter to requested source IDs if specified
        if ($hasSourceFilter) {
            $filtered = [System.Collections.Generic.List[object]]::new()
            foreach ($src in $allSources) {
                $srcId = $null
                if ($null -ne $src.id) { $srcId = [string]$src.id }
                elseif ($src -is [hashtable] -and $src.ContainsKey('id')) { $srcId = [string]$src['id'] }
                if ($null -ne $srcId -and $sourceFilterSet.ContainsKey($srcId)) {
                    $filtered.Add($src)
                }
            }
            $allSources = $filtered
        }

        Write-SPLog -Message "Save-SPConfigurationSnapshot: retrieved $($allSources.Count) source(s)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
            -CorrelationID $CorrelationID

        # ------------------------------------------------------------------
        # Step 2: Build source records
        # ------------------------------------------------------------------
        $sourceRecords = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($src in $allSources) {
            $srcId          = ''
            $srcName        = ''
            $srcType        = ''
            $srcDescription = ''
            $srcEnabled     = $false
            $ownerName      = ''
            $ownerId        = ''
            $connectorType  = ''
            $accountCount   = 0

            if ($src -is [hashtable]) {
                $srcId          = if ($src.ContainsKey('id'))            { [string]$src['id'] }            else { '' }
                $srcName        = if ($src.ContainsKey('name'))          { [string]$src['name'] }          else { '' }
                $srcType        = if ($src.ContainsKey('type'))          { [string]$src['type'] }          else { '' }
                $srcDescription = if ($src.ContainsKey('description'))   { [string]$src['description'] }   else { '' }
                $srcEnabled     = if ($src.ContainsKey('enabled'))       { [bool]$src['enabled'] }         else { $false }
                $connectorType  = if ($src.ContainsKey('connectorName')) { [string]$src['connectorName'] } else { '' }
                $accountCount   = if ($src.ContainsKey('accountCount'))  { [int]$src['accountCount'] }     else { 0 }
                if ($src.ContainsKey('owner') -and $null -ne $src['owner']) {
                    $ow = $src['owner']
                    if ($ow -is [hashtable]) {
                        $ownerName = if ($ow.ContainsKey('name')) { [string]$ow['name'] } else { '' }
                        $ownerId   = if ($ow.ContainsKey('id'))   { [string]$ow['id'] }   else { '' }
                    } else {
                        if ($null -ne $ow.name) { $ownerName = [string]$ow.name }
                        if ($null -ne $ow.id)   { $ownerId   = [string]$ow.id }
                    }
                }
            } else {
                if ($null -ne $src.id)            { $srcId          = [string]$src.id }
                if ($null -ne $src.name)          { $srcName        = [string]$src.name }
                if ($null -ne $src.type)          { $srcType        = [string]$src.type }
                if ($null -ne $src.description)   { $srcDescription = [string]$src.description }
                if ($null -ne $src.enabled)       { $srcEnabled     = [bool]$src.enabled }
                if ($null -ne $src.connectorName) { $connectorType  = [string]$src.connectorName }
                if ($null -ne $src.accountCount)  { $accountCount   = [int]$src.accountCount }
                if ($null -ne $src.owner) {
                    if ($null -ne $src.owner.name) { $ownerName = [string]$src.owner.name }
                    if ($null -ne $src.owner.id)   { $ownerId   = [string]$src.owner.id }
                }
            }

            $sourceRecords.Add(@{
                Id            = $srcId
                Name          = $srcName
                Type          = $srcType
                Description   = $srcDescription
                Enabled       = $srcEnabled
                OwnerName     = $ownerName
                OwnerId       = $ownerId
                ConnectorType = $connectorType
                AccountCount  = $accountCount
            })
        }

        # ------------------------------------------------------------------
        # Step 3: Optional entitlement data
        # ------------------------------------------------------------------
        $totalEntitlements = 0
        if ($IncludeEntitlements) {
            $entSourceIds = if ($hasSourceFilter) { $SourceIds } else { $null }
            $entResult = Get-SPEntitlementInventory -SourceIds $entSourceIds -CorrelationID $CorrelationID

            if ($entResult.Success -and $null -ne $entResult.Data) {
                foreach ($rec in $sourceRecords) {
                    $sid = $rec['Id']
                    if ($entResult.Data.Sources.ContainsKey($sid)) {
                        $srcEnt = $entResult.Data.Sources[$sid]
                        $entNames = [System.Collections.Generic.List[string]]::new()
                        $privCount = 0
                        if ($null -ne $srcEnt['Entitlements']) {
                            foreach ($e in $srcEnt['Entitlements']) {
                                $eName = ''
                                if ($e -is [hashtable] -and $e.ContainsKey('Name')) { $eName = [string]$e['Name'] }
                                elseif ($null -ne $e.Name) { $eName = [string]$e.Name }
                                if (-not [string]::IsNullOrWhiteSpace($eName)) { $entNames.Add($eName) }
                                $isPr = $false
                                if ($e -is [hashtable] -and $e.ContainsKey('Privileged')) { $isPr = [bool]$e['Privileged'] }
                                elseif ($null -ne $e.Privileged) { $isPr = [bool]$e.Privileged }
                                if ($isPr) { $privCount++ }
                            }
                        }
                        $rec['EntitlementCount']  = $srcEnt['TotalEntitlements']
                        $rec['PrivilegedCount']   = $privCount
                        $rec['EntitlementNames']  = $entNames.ToArray()
                        $totalEntitlements += $srcEnt['TotalEntitlements']
                    }
                }
            } else {
                Write-SPLog -Message "Entitlement inventory query returned no data; entitlement counts will be 0" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
                    -CorrelationID $CorrelationID
            }
        }

        # ------------------------------------------------------------------
        # Step 4: Optional access profile data
        # ------------------------------------------------------------------
        $totalAccessProfiles = 0
        if ($IncludeAccessProfiles) {
            $apSourceIds = if ($hasSourceFilter) { $SourceIds } else { $null }
            $apResult = Get-SPAccessProfileInventory -SourceIds $apSourceIds -CorrelationID $CorrelationID

            if ($apResult.Success -and $null -ne $apResult.Data) {
                foreach ($rec in $sourceRecords) {
                    $sid = $rec['Id']
                    if ($apResult.Data.Sources.ContainsKey($sid)) {
                        $srcAp = $apResult.Data.Sources[$sid]
                        $apNames = [System.Collections.Generic.List[string]]::new()
                        $apEnabled = 0
                        $apRequestable = 0
                        if ($null -ne $srcAp['AccessProfiles']) {
                            foreach ($ap in $srcAp['AccessProfiles']) {
                                $apName = ''
                                if ($ap -is [hashtable]) {
                                    if ($ap.ContainsKey('Name')) { $apName = [string]$ap['Name'] }
                                    if ($ap.ContainsKey('Enabled') -and [bool]$ap['Enabled']) { $apEnabled++ }
                                    if ($ap.ContainsKey('Requestable') -and [bool]$ap['Requestable']) { $apRequestable++ }
                                } else {
                                    if ($null -ne $ap.Name) { $apName = [string]$ap.Name }
                                    if ($null -ne $ap.Enabled -and [bool]$ap.Enabled) { $apEnabled++ }
                                    if ($null -ne $ap.Requestable -and [bool]$ap.Requestable) { $apRequestable++ }
                                }
                                if (-not [string]::IsNullOrWhiteSpace($apName)) { $apNames.Add($apName) }
                            }
                        }
                        $rec['AccessProfileCount']       = $srcAp['TotalAccessProfiles']
                        $rec['AccessProfileNames']       = $apNames.ToArray()
                        $rec['AccessProfileEnabled']     = $apEnabled
                        $rec['AccessProfileRequestable'] = $apRequestable
                        $totalAccessProfiles += $srcAp['TotalAccessProfiles']
                    }
                }
            } else {
                Write-SPLog -Message "Access profile inventory query returned no data; access profile counts will be 0" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
                    -CorrelationID $CorrelationID
            }
        }

        # ------------------------------------------------------------------
        # Step 5: Optional role data
        # ------------------------------------------------------------------
        $totalRoles = 0
        $roleRecords = $null
        if ($IncludeRoles) {
            $roleResult = Get-SPRoleInventory -CorrelationID $CorrelationID

            if ($roleResult.Success -and $null -ne $roleResult.Data) {
                $totalRoles = $roleResult.Data.Summary.TotalRoles
                $roleList = [System.Collections.Generic.List[hashtable]]::new()
                if ($null -ne $roleResult.Data.Roles) {
                    foreach ($role in $roleResult.Data.Roles) {
                        $rName = ''
                        $rId = ''
                        $rMembership = ''
                        $rEnabled = $false
                        $rApCount = 0
                        $rApNames = @()

                        if ($role -is [hashtable]) {
                            $rName       = if ($role.ContainsKey('Name'))               { [string]$role['Name'] }              else { '' }
                            $rId         = if ($role.ContainsKey('Id'))                 { [string]$role['Id'] }                else { '' }
                            $rMembership = if ($role.ContainsKey('MembershipType'))     { [string]$role['MembershipType'] }    else { '' }
                            $rEnabled    = if ($role.ContainsKey('Enabled'))            { [bool]$role['Enabled'] }             else { $false }
                            $rApCount    = if ($role.ContainsKey('AccessProfileCount')) { [int]$role['AccessProfileCount'] }   else { 0 }
                            $rApNames    = if ($role.ContainsKey('AccessProfileNames')) { @($role['AccessProfileNames']) }     else { @() }
                        } else {
                            if ($null -ne $role.Name)               { $rName       = [string]$role.Name }
                            if ($null -ne $role.Id)                 { $rId         = [string]$role.Id }
                            if ($null -ne $role.MembershipType)     { $rMembership = [string]$role.MembershipType }
                            if ($null -ne $role.Enabled)            { $rEnabled    = [bool]$role.Enabled }
                            if ($null -ne $role.AccessProfileCount) { $rApCount    = [int]$role.AccessProfileCount }
                            if ($null -ne $role.AccessProfileNames) { $rApNames    = @($role.AccessProfileNames) }
                        }

                        $roleList.Add(@{
                            Id                 = $rId
                            Name               = $rName
                            MembershipType     = $rMembership
                            Enabled            = $rEnabled
                            AccessProfileCount = $rApCount
                            AccessProfileNames = $rApNames
                        })
                    }
                }
                $roleRecords = $roleList.ToArray()
            } else {
                Write-SPLog -Message "Role inventory query returned no data; role counts will be 0" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
                    -CorrelationID $CorrelationID
            }
        }

        # ------------------------------------------------------------------
        # Step 6: Compute settings hash
        # ------------------------------------------------------------------
        $settingsHash = ''
        try {
            $settingsPath = Join-Path '.' (Join-Path 'Config' 'settings.json')
            if (Test-Path -Path $settingsPath) {
                $hashResult = Get-FileHash -Path $settingsPath -Algorithm SHA256
                $settingsHash = $hashResult.Hash
            }
        } catch {
            Write-SPLog -Message "Could not compute settings hash: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
                -CorrelationID $CorrelationID
        }

        # ------------------------------------------------------------------
        # Step 7: Build and write snapshot JSON
        # ------------------------------------------------------------------
        $snapshotId = [guid]::NewGuid().ToString()
        $capturedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $toolkitVersion = '1.0.0'
        try {
            $cfgVer = Get-SPConfig
            if ($null -ne $cfgVer.Global -and -not [string]::IsNullOrWhiteSpace($cfgVer.Global.ToolkitVersion)) {
                $toolkitVersion = $cfgVer.Global.ToolkitVersion
            }
        } catch { }

        $snapshot = @{
            snapshotId      = $snapshotId
            capturedAt      = $capturedAt
            toolkitVersion  = $toolkitVersion
            settingsHash    = $settingsHash
            scope           = @{
                includeEntitlements   = [bool]$IncludeEntitlements
                includeAccessProfiles = [bool]$IncludeAccessProfiles
                includeRoles          = [bool]$IncludeRoles
            }
            sources         = $sourceRecords.ToArray()
            summary         = @{
                sourceCount         = $sourceRecords.Count
                totalEntitlements   = $totalEntitlements
                totalAccessProfiles = $totalAccessProfiles
                totalRoles          = $totalRoles
            }
        }

        if ($null -ne $roleRecords) {
            $snapshot['roles'] = $roleRecords
        }

        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
        $fileName  = "snapshot-$timestamp.json"
        $filePath  = Join-Path $OutputPath $fileName

        if ($PSCmdlet.ShouldProcess($filePath, 'Write configuration snapshot')) {
            $jsonContent = $snapshot | ConvertTo-Json -Depth 10
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($filePath, $jsonContent, $utf8NoBom)
        }

        Write-SPLog -Message "Save-SPConfigurationSnapshot: wrote snapshot to $filePath ($($sourceRecords.Count) sources)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Save-SPConfigurationSnapshot' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                SnapshotPath = $filePath
                SnapshotId   = $snapshotId
                CapturedAt   = $capturedAt
                SourceCount  = $sourceRecords.Count
                Summary      = @{
                    Sources        = $sourceRecords.Count
                    Entitlements   = $totalEntitlements
                    AccessProfiles = $totalAccessProfiles
                    Roles          = $totalRoles
                }
            }
        }
    }
    catch {
        $errMsg = "Save-SPConfigurationSnapshot failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Save-SPConfigurationSnapshot' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

function Get-SPConfigurationSnapshot {
    <#
    .SYNOPSIS
        Reads and parses a previously saved configuration snapshot JSON file.
    .DESCRIPTION
        Loads the JSON snapshot file at the specified path and returns the parsed
        snapshot object. Used as input to Compare-SPConfigurationSnapshots for
        drift detection.
    .PARAMETER Path
        Path to the snapshot JSON file.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] The parsed snapshot hashtable.
    .EXAMPLE
        $snapshot = Get-SPConfigurationSnapshot -Path '.\Audit\snapshots\snapshot-2026-05-23-120000.json'
        $snapshot.sources.Count
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPConfigurationSnapshot: reading $Path" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPConfigurationSnapshot' `
        -CorrelationID $CorrelationID

    if (-not (Test-Path -Path $Path)) {
        $errMsg = "Snapshot file not found: $Path"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPConfigurationSnapshot' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }

    try {
        $jsonContent = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $snapshot = $jsonContent | ConvertFrom-Json

        # Convert PSCustomObject to hashtable for consistent access
        $result = @{}
        foreach ($prop in $snapshot.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value
        }

        Write-SPLog -Message "Get-SPConfigurationSnapshot: loaded snapshot $($result['snapshotId']), captured at $($result['capturedAt'])" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPConfigurationSnapshot' `
            -CorrelationID $CorrelationID

        return $result
    }
    catch {
        $errMsg = "Get-SPConfigurationSnapshot failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Get-SPConfigurationSnapshot' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region Orphan Account Detection (P16-01)

function Get-SPOrphanAccounts {
    <#
    .SYNOPSIS
        Detects accounts not correlated to any active identity.
    .DESCRIPTION
        For each source, queries /v3/accounts and classifies orphan accounts:
        - Uncorrelated: identityId is null (no identity link)
        - TerminatedOwner: identity lifecycle state is TERMINATED or INACTIVE
        - DanglingReference: identityId present but identity not found (404)
        Service accounts (svc-, sa-, service., or AD machine accounts with $)
        and disabled accounts can optionally be included.
    .PARAMETER SourceIds
        Array of SailPoint source IDs to scan for orphan accounts.
    .PARAMETER IncludeDisabledAccounts
        When set, includes disabled orphan accounts in results.
    .PARAMETER IncludeServiceAccounts
        When set, includes service accounts in results.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ OrphanAccounts = @(...); Summary = @{...} }
    .EXAMPLE
        $result = Get-SPOrphanAccounts -SourceIds @('src-ad-001') -IncludeServiceAccounts
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$SourceIds,

        [Parameter()]
        [switch]$IncludeDisabledAccounts,

        [Parameter()]
        [switch]$IncludeServiceAccounts,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPOrphanAccounts: scanning $($SourceIds.Count) source(s), IncludeDisabled=$IncludeDisabledAccounts, IncludeService=$IncludeServiceAccounts" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
        -CorrelationID $CorrelationID

    $orphanAccounts = [System.Collections.Generic.List[hashtable]]::new()
    $totalScanned = 0
    $perSource = @{}

    # Collect identity IDs that need lifecycle state lookup
    $identityIdsToCheck = [System.Collections.Generic.Dictionary[string,bool]]::new()
    # Track account-to-identityId mapping for deferred classification
    $accountsPendingIdentityCheck = [System.Collections.Generic.List[hashtable]]::new()

    # Pagination ceiling
    $maxPages = 200
    try {
        $cfgForCeiling = Get-SPConfig
        if ($null -ne $cfgForCeiling.Api -and
            $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
            [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
            $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
        }
    } catch { }

    foreach ($sourceId in $SourceIds) {
        $sourceName = Get-SPAuditSourceName -SourceId $sourceId -CorrelationID $CorrelationID
        $sourceAccountCount = 0
        $sourceOrphanCount = 0

        # Paginate through /v3/accounts for this source
        $pageSize = 250
        $offset = 0
        $pageNum = 0

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                Write-SPLog -Message "Get-SPOrphanAccounts: pagination ceiling reached for source '$sourceName' at page $pageNum" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
                    -CorrelationID $CorrelationID
                break
            }

            $queryParams = @{
                'limit'   = $pageSize.ToString()
                'offset'  = $offset.ToString()
                'filters' = "sourceId eq `"$sourceId`""
            }

            $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/accounts' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $result.Success) {
                Write-SPLog -Message "Get-SPOrphanAccounts: API error for source '$sourceName' at page ${pageNum}: $($result.Error)" `
                    -Severity ERROR -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
                    -CorrelationID $CorrelationID
                break
            }

            $page = $result.Data
            if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
                $page = $result.Data.items
            }
            $page = @($page)

            foreach ($acct in $page) {
                $sourceAccountCount++

                $acctId = $acct.id
                $acctName = $acct.name
                $nativeIdentity = $acct.nativeIdentity
                $identityId = $acct.identityId
                $disabled = if ($null -ne $acct.disabled) { [bool]$acct.disabled } else { $false }
                $entitlementCount = 0
                if ($null -ne $acct.entitlementAttributes -and $acct.entitlementAttributes.Count -gt 0) {
                    $entitlementCount = $acct.entitlementAttributes.Count
                }
                $hasEntitlements = $entitlementCount -gt 0
                $created = if ($null -ne $acct.created) { [string]$acct.created } else { '' }

                # Detect service account by name pattern
                $isServiceAccount = $false
                if (-not [string]::IsNullOrWhiteSpace($acctName)) {
                    $lowerName = $acctName.ToLower()
                    if ($lowerName.StartsWith('svc-') -or
                        $lowerName.StartsWith('sa-') -or
                        $lowerName.StartsWith('service.') -or
                        $acctName.Contains('$')) {
                        $isServiceAccount = $true
                    }
                }

                if ($null -eq $identityId -or [string]::IsNullOrWhiteSpace($identityId)) {
                    # Uncorrelated account
                    # Skip disabled unless requested
                    if ($disabled -and -not $IncludeDisabledAccounts) { continue }
                    # Skip service accounts unless requested
                    if ($isServiceAccount -and -not $IncludeServiceAccounts) { continue }

                    $orphanAccounts.Add(@{
                        AccountId        = $acctId
                        AccountName      = $acctName
                        SourceId         = $sourceId
                        SourceName       = $sourceName
                        NativeIdentity   = $nativeIdentity
                        Disabled         = $disabled
                        HasEntitlements  = $hasEntitlements
                        EntitlementCount = $entitlementCount
                        Created          = $created
                        OrphanType       = 'Uncorrelated'
                        IsServiceAccount = $isServiceAccount
                    })
                    $sourceOrphanCount++
                }
                else {
                    # Correlated -- queue for identity lifecycle check
                    if (-not $identityIdsToCheck.ContainsKey($identityId)) {
                        $identityIdsToCheck[$identityId] = $true
                    }
                    $accountsPendingIdentityCheck.Add(@{
                        AccountId        = $acctId
                        AccountName      = $acctName
                        SourceId         = $sourceId
                        SourceName       = $sourceName
                        NativeIdentity   = $nativeIdentity
                        Disabled         = $disabled
                        HasEntitlements  = $hasEntitlements
                        EntitlementCount = $entitlementCount
                        Created          = $created
                        IdentityId       = $identityId
                        IsServiceAccount = $isServiceAccount
                    })
                }
            }

            Write-SPLog -Message "Get-SPOrphanAccounts: source '$sourceName' page $pageNum, $($page.Count) accounts" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
                -CorrelationID $CorrelationID

            $offset += $pageSize

        } while ($null -ne $page -and $page.Count -ge $pageSize)

        $totalScanned += $sourceAccountCount
        $perSource[$sourceName] = @{
            Total     = $sourceAccountCount
            Orphans   = $sourceOrphanCount
            OrphanPct = if ($sourceAccountCount -gt 0) { [math]::Round(($sourceOrphanCount / $sourceAccountCount) * 100, 1) } else { 0 }
        }
    }

    # Batch identity lifecycle lookups (deduplicated)
    $identityStates = @{}
    $uniqueIds = @($identityIdsToCheck.Keys)

    Write-SPLog -Message "Get-SPOrphanAccounts: checking lifecycle state for $($uniqueIds.Count) correlated identities" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
        -CorrelationID $CorrelationID

    foreach ($iid in $uniqueIds) {
        try {
            $idResult = Invoke-SPApiRequest -Method GET -Endpoint "/v3/public-identities/$iid" `
                -CorrelationID $CorrelationID

            if ($idResult.Success -and $null -ne $idResult.Data) {
                $lcState = ''
                if ($null -ne $idResult.Data.lifecycle_state) {
                    $lcState = [string]$idResult.Data.lifecycle_state
                }
                elseif ($null -ne $idResult.Data.lifecycleState) {
                    $lcState = [string]$idResult.Data.lifecycleState
                }
                $identityStates[$iid] = $lcState.ToUpper()
            }
            else {
                # Identity not found or API error -- treat as DanglingReference
                $identityStates[$iid] = 'NOT_FOUND'
            }
        }
        catch {
            $identityStates[$iid] = 'NOT_FOUND'
        }
    }

    # Classify pending accounts based on identity state
    foreach ($pendingAcct in $accountsPendingIdentityCheck) {
        $iid = $pendingAcct['IdentityId']
        $state = if ($identityStates.ContainsKey($iid)) { $identityStates[$iid] } else { 'NOT_FOUND' }

        $orphanType = $null
        if ($state -eq 'NOT_FOUND') {
            $orphanType = 'DanglingReference'
        }
        elseif ($state -eq 'TERMINATED' -or $state -eq 'INACTIVE') {
            $orphanType = 'TerminatedOwner'
        }
        else {
            # Active identity -- not an orphan
            continue
        }

        # The -IncludeDisabledAccounts / -IncludeServiceAccounts switches gate EVERY
        # orphan category, matching the docstring ("disabled accounts can optionally
        # be included"). They previously only filtered the Uncorrelated branch, so
        # default invocations still listed disabled/service accounts under
        # TerminatedOwner / DanglingReference and inflated the summary counts.
        if ($pendingAcct['Disabled'] -and -not $IncludeDisabledAccounts) { continue }
        if ($pendingAcct['IsServiceAccount'] -and -not $IncludeServiceAccounts) { continue }

        $orphanAccounts.Add(@{
            AccountId        = $pendingAcct['AccountId']
            AccountName      = $pendingAcct['AccountName']
            SourceId         = $pendingAcct['SourceId']
            SourceName       = $pendingAcct['SourceName']
            NativeIdentity   = $pendingAcct['NativeIdentity']
            Disabled         = $pendingAcct['Disabled']
            HasEntitlements  = $pendingAcct['HasEntitlements']
            EntitlementCount = $pendingAcct['EntitlementCount']
            Created          = $pendingAcct['Created']
            OrphanType       = $orphanType
            IsServiceAccount = $pendingAcct['IsServiceAccount']
        })

        # Update per-source counts
        $sName = $pendingAcct['SourceName']
        if ($perSource.ContainsKey($sName)) {
            $perSource[$sName]['Orphans']++
            $srcTotal = $perSource[$sName]['Total']
            $perSource[$sName]['OrphanPct'] = if ($srcTotal -gt 0) {
                [math]::Round(($perSource[$sName]['Orphans'] / $srcTotal) * 100, 1)
            } else { 0 }
        }
    }

    # Build summary counts.
    # Use a PS-5.1-safe accessor: dot notation works for both hashtable and PSCustomObject;
    # bracket notation $obj['key'] only works reliably on hashtables. Switching to dot
    # notation prevents "does not contain a method named 'ContainsKey'" errors (line 1 char 1)
    # that appear when any item in the list happens to be a PSCustomObject.
    $uncorrelatedCount = @($orphanAccounts | Where-Object { $_.OrphanType -eq 'Uncorrelated' }).Count
    $terminatedCount = @($orphanAccounts | Where-Object { $_.OrphanType -eq 'TerminatedOwner' }).Count
    $danglingCount = @($orphanAccounts | Where-Object { $_.OrphanType -eq 'DanglingReference' }).Count
    $disabledCount = @($orphanAccounts | Where-Object { $_.Disabled -eq $true }).Count
    $serviceCount = @($orphanAccounts | Where-Object { $_.IsServiceAccount -eq $true }).Count
    $withEntitlements = @($orphanAccounts | Where-Object { $_.HasEntitlements -eq $true }).Count

    $result = @{
        OrphanAccounts = @($orphanAccounts)
        Summary = @{
            TotalAccountsScanned    = $totalScanned
            TotalOrphans            = $orphanAccounts.Count
            Uncorrelated            = $uncorrelatedCount
            TerminatedOwner         = $terminatedCount
            DanglingReference       = $danglingCount
            DisabledOrphans         = $disabledCount
            ServiceAccountOrphans   = $serviceCount
            OrphansWithEntitlements = $withEntitlements
            PerSource               = $perSource
        }
    }

    Write-SPLog -Message "Get-SPOrphanAccounts: found $($orphanAccounts.Count) orphans across $totalScanned accounts ($uncorrelatedCount uncorrelated, $terminatedCount terminated, $danglingCount dangling)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPOrphanAccounts' `
        -CorrelationID $CorrelationID

    return $result
}

#region P16-02: Source Aggregation Health Monitor

function Get-SPSourceAggregationHealth {
    <#
    .SYNOPSIS
        Evaluates source connection status and recent aggregation history.
    .DESCRIPTION
        Queries /v3/sources and /v3/account-aggregations to detect sources that
        have stopped syncing or are experiencing data freshness issues.
        Classifies each source as Healthy, Warning, Critical, or Unknown based
        on aggregation success rate, staleness, and account count trends.
    .PARAMETER SourceIds
        Optional array of source IDs to check. If omitted, queries all enabled sources.
    .PARAMETER MaxAcceptableStalenessHours
        Hours after which a source with no successful aggregation is considered stale.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Sources = @(...); Summary = @{...} }
    .EXAMPLE
        $health = Get-SPSourceAggregationHealth -MaxAcceptableStalenessHours 48
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$MaxAcceptableStalenessHours = 48,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sourceFilter = if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { "$($SourceIds.Count) specified" } else { 'all enabled' }
    Write-SPLog -Message "Get-SPSourceAggregationHealth: checking $sourceFilter source(s), MaxStaleness=${MaxAcceptableStalenessHours}h" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
        -CorrelationID $CorrelationID

    # Pagination ceiling
    $maxPages = 200
    try {
        $cfgForCeiling = Get-SPConfig
        if ($null -ne $cfgForCeiling.Api -and
            $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
            [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
            $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
        }
    } catch { }

    # Step 1: Get sources
    $allSources = [System.Collections.Generic.List[hashtable]]::new()

    if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) {
        # Query each specified source by ID
        foreach ($sid in $SourceIds) {
            try {
                $srcResult = Invoke-SPApiRequest -Method GET -Endpoint "/v3/sources/$sid" `
                    -CorrelationID $CorrelationID
                if ($srcResult.Success -and $null -ne $srcResult.Data) {
                    $allSources.Add(@{
                        Id            = $srcResult.Data.id
                        Name          = $srcResult.Data.name
                        Type          = if ($null -ne $srcResult.Data.type) { [string]$srcResult.Data.type } else { '' }
                        ConnectorType = if ($null -ne $srcResult.Data.connectorAttributes -and
                                           $null -ne $srcResult.Data.connectorAttributes.connectorName) {
                                           [string]$srcResult.Data.connectorAttributes.connectorName
                                       } else { '' }
                        Enabled       = if ($null -ne $srcResult.Data.healthy) { [bool]$srcResult.Data.healthy } else { $true }
                    })
                }
            }
            catch {
                Write-SPLog -Message "Get-SPSourceAggregationHealth: failed to query source '$sid': $_" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
                    -CorrelationID $CorrelationID
            }
        }
    }
    else {
        # Paginate through all sources
        $pageSize = 250
        $offset = 0
        $pageNum = 0

        do {
            $pageNum++
            if ($pageNum -gt $maxPages) {
                Write-SPLog -Message "Get-SPSourceAggregationHealth: pagination ceiling reached at page $pageNum" `
                    -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
                    -CorrelationID $CorrelationID
                break
            }

            $queryParams = @{
                'limit'  = $pageSize.ToString()
                'offset' = $offset.ToString()
            }

            $srcResult = Invoke-SPApiRequest -Method GET -Endpoint '/v3/sources' `
                -QueryParams $queryParams -CorrelationID $CorrelationID

            if (-not $srcResult.Success) {
                $srcErrMsg = $srcResult.Error
                if ($srcErrMsg -match '403|forbidden') {
                    $srcErrMsg = "Access denied (403) on /v3/sources. Add 'idn:source:read' (or 'sp:scopes:all') to your Personal Access Token. Source aggregation health will show 0/0/0 until scope is granted."
                }
                Write-SPLog -Message "Get-SPSourceAggregationHealth: API error querying sources at page ${pageNum}: $srcErrMsg" `
                    -Severity ERROR -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
                    -CorrelationID $CorrelationID
                break
            }

            $page = $srcResult.Data
            if ($null -ne $srcResult.Data -and $srcResult.Data.PSObject.Properties.Name -contains 'items') {
                $page = $srcResult.Data.items
            }
            $page = @($page)

            foreach ($src in $page) {
                $isEnabled = $true
                if ($null -ne $src.healthy) { $isEnabled = [bool]$src.healthy }

                # Skip disabled sources unless explicitly requested via SourceIds
                if (-not $isEnabled) { continue }

                $allSources.Add(@{
                    Id            = $src.id
                    Name          = $src.name
                    Type          = if ($null -ne $src.type) { [string]$src.type } else { '' }
                    ConnectorType = if ($null -ne $src.connectorAttributes -and
                                       $null -ne $src.connectorAttributes.connectorName) {
                                       [string]$src.connectorAttributes.connectorName
                                   } else { '' }
                    Enabled       = $isEnabled
                })
            }

            Write-SPLog -Message "Get-SPSourceAggregationHealth: sources page $pageNum, $($page.Count) items" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
                -CorrelationID $CorrelationID

            $offset += $pageSize
        } while ($null -ne $page -and $page.Count -ge $pageSize)
    }

    Write-SPLog -Message "Get-SPSourceAggregationHealth: evaluating $($allSources.Count) source(s)" `
        -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
        -CorrelationID $CorrelationID

    $now = [datetime]::UtcNow
    $sourceResults = [System.Collections.Generic.List[hashtable]]::new()
    $healthyCt = 0; $warningCt = 0; $criticalCt = 0; $unknownCt = 0
    $staleCt = 0; $withFailuresCt = 0
    $totalFreshness = 0.0; $freshnessCount = 0

    foreach ($source in $allSources) {
        $sourceId = $source['Id']
        $sourceName = $source['Name']

        # Step 2: Query recent aggregations for this source
        $aggQueryParams = @{
            'filters' = "sourceId eq `"$sourceId`""
            'sorters' = '-started'
            'limit'   = '5'
        }

        $aggResult = $null
        try {
            $aggResult = Invoke-SPApiRequest -Method GET -Endpoint '/v3/account-aggregations' `
                -QueryParams $aggQueryParams -CorrelationID $CorrelationID
        }
        catch {
            Write-SPLog -Message "Get-SPSourceAggregationHealth: failed to query aggregations for '$sourceName': $_" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
                -CorrelationID $CorrelationID
        }

        $aggregations = @()
        if ($null -ne $aggResult -and $aggResult.Success -and $null -ne $aggResult.Data) {
            $aggData = $aggResult.Data
            if ($null -ne $aggResult.Data.PSObject.Properties.Name -and
                $aggResult.Data.PSObject.Properties.Name -contains 'items') {
                $aggData = $aggResult.Data.items
            }
            $aggregations = @($aggData)
        }

        if ($aggregations.Count -eq 0) {
            # No aggregation history
            $unknownCt++
            $sourceResults.Add(@{
                SourceId              = $sourceId
                SourceName            = $sourceName
                SourceType            = $source['Type']
                Enabled               = $source['Enabled']
                HealthStatus          = 'Unknown'
                LastAggregation       = $null
                DataFreshnessHours    = $null
                IsStale               = $false
                ConsecutiveFailures   = 0
                AvgDurationMinutes    = $null
                AccountTrend          = 'Unknown'
                AccountTrendDetail    = 'No aggregation history found'
            })
            continue
        }

        # Step 3: Extract last aggregation details
        $lastAgg = $aggregations[0]

        $lastStarted   = if ($null -ne $lastAgg.started) { [string]$lastAgg.started } else { '' }
        $lastCompleted = if ($null -ne $lastAgg.completed) { [string]$lastAgg.completed } else { '' }
        $lastStatus    = if ($null -ne $lastAgg.status) { [string]$lastAgg.status } else { 'UNKNOWN' }
        $totalAccounts = if ($null -ne $lastAgg.totalAccounts) { [int]$lastAgg.totalAccounts } else { 0 }
        $errorCount    = if ($null -ne $lastAgg.errors) { @($lastAgg.errors).Count } else { 0 }
        if ($null -ne $lastAgg.errorCount) { $errorCount = [int]$lastAgg.errorCount }

        $durationMinutes = 0
        if (-not [string]::IsNullOrWhiteSpace($lastStarted) -and
            -not [string]::IsNullOrWhiteSpace($lastCompleted)) {
            try {
                $startDt = [datetime]::Parse($lastStarted)
                $endDt   = [datetime]::Parse($lastCompleted)
                $durationMinutes = [math]::Round(($endDt - $startDt).TotalMinutes, 1)
            } catch { }
        }

        # Step 4: Calculate health indicators
        # DataFreshnessHours: hours since last SUCCESSFUL aggregation completed
        $dataFreshnessHours = $null
        $lastSuccessfulCompleted = $null
        foreach ($agg in $aggregations) {
            $aggStatus = if ($null -ne $agg.status) { [string]$agg.status } else { '' }
            if ($aggStatus -eq 'SUCCESS' -and -not [string]::IsNullOrWhiteSpace($agg.completed)) {
                $lastSuccessfulCompleted = $agg.completed
                break
            }
        }

        if ($null -ne $lastSuccessfulCompleted) {
            try {
                # Normalize to UTC before differencing against $now = [datetime]::UtcNow.
                # [datetime]::Parse converts the ISC 'Z'-suffixed timestamp to LOCAL Kind,
                # and the raw tick subtraction ignored Kind -- DataFreshnessHours was
                # skewed by the machine's UTC offset (false IsStale on UTC-negative
                # hosts, hidden staleness on UTC-positive ones).
                $successDt = [datetime]::Parse([string]$lastSuccessfulCompleted,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $dataFreshnessHours = [math]::Round(($now - $successDt).TotalHours, 1)
            } catch { }
        }

        $isStale = $false
        if ($null -ne $dataFreshnessHours) {
            $isStale = $dataFreshnessHours -gt $MaxAcceptableStalenessHours
        }
        elseif ($lastStatus -ne 'SUCCESS') {
            # No successful aggregation found in recent history
            $isStale = $true
        }

        # ConsecutiveFailures: count of non-SUCCESS from most recent
        $consecutiveFailures = 0
        foreach ($agg in $aggregations) {
            $aggStatus = if ($null -ne $agg.status) { [string]$agg.status } else { '' }
            if ($aggStatus -ne 'SUCCESS') {
                $consecutiveFailures++
            }
            else {
                break
            }
        }

        # AvgDurationMinutes from successful aggregations
        $avgDuration = $null
        $durationSum = 0.0
        $durationCount = 0
        foreach ($agg in $aggregations) {
            $aggStatus = if ($null -ne $agg.status) { [string]$agg.status } else { '' }
            if ($aggStatus -eq 'SUCCESS' -and
                -not [string]::IsNullOrWhiteSpace($agg.started) -and
                -not [string]::IsNullOrWhiteSpace($agg.completed)) {
                try {
                    $s = [datetime]::Parse($agg.started)
                    $e = [datetime]::Parse($agg.completed)
                    $durationSum += ($e - $s).TotalMinutes
                    $durationCount++
                } catch { }
            }
        }
        if ($durationCount -gt 0) {
            $avgDuration = [math]::Round($durationSum / $durationCount, 1)
        }

        # AccountTrend: compare two most recent successful aggregations
        $accountTrend = 'Unknown'
        $accountTrendDetail = 'Insufficient data for trend'
        $successfulAggs = @($aggregations | Where-Object {
            $null -ne $_.status -and [string]$_.status -eq 'SUCCESS'
        })
        if ($successfulAggs.Count -ge 2) {
            $newestCount = if ($null -ne $successfulAggs[0].totalAccounts) { [int]$successfulAggs[0].totalAccounts } else { 0 }
            $prevCount   = if ($null -ne $successfulAggs[1].totalAccounts) { [int]$successfulAggs[1].totalAccounts } else { 0 }
            $diff = $newestCount - $prevCount

            if ($prevCount -gt 0) {
                $pctChange = [math]::Abs($diff / $prevCount * 100)
            }
            else {
                $pctChange = 0
            }

            if ($diff -gt 0) {
                $accountTrend = 'Increasing'
                $accountTrendDetail = "+$diff accounts since previous aggregation"
            }
            elseif ($diff -lt 0) {
                $accountTrend = 'Decreasing'
                $accountTrendDetail = "$diff accounts since previous aggregation"
            }
            else {
                $accountTrend = 'Stable'
                $accountTrendDetail = "+0 accounts since previous aggregation"
            }
        }
        elseif ($successfulAggs.Count -eq 1) {
            $accountTrend = 'Stable'
            $accountTrendDetail = 'Only one successful aggregation available'
        }

        # Step 5: Classify source health
        $healthStatus = 'Healthy'
        $significantDrop = $false
        if ($accountTrend -eq 'Decreasing' -and $successfulAggs.Count -ge 2) {
            $newestCount = if ($null -ne $successfulAggs[0].totalAccounts) { [int]$successfulAggs[0].totalAccounts } else { 0 }
            $prevCount   = if ($null -ne $successfulAggs[1].totalAccounts) { [int]$successfulAggs[1].totalAccounts } else { 0 }
            if ($prevCount -gt 0) {
                $dropPct = ($prevCount - $newestCount) / $prevCount * 100
                $significantDrop = $dropPct -gt 10
            }
        }

        if ($consecutiveFailures -ge 2) {
            $healthStatus = 'Critical'
        }
        elseif ($lastStatus -ne 'SUCCESS' -and $null -eq $dataFreshnessHours) {
            # No successful aggregation within the 5 most recent, no staleness data
            $healthStatus = 'Critical'
        }
        elseif ($null -ne $dataFreshnessHours -and $dataFreshnessHours -gt (2 * $MaxAcceptableStalenessHours) -and $lastStatus -ne 'SUCCESS') {
            $healthStatus = 'Critical'
        }
        elseif ($consecutiveFailures -eq 1 -or $isStale -or $significantDrop) {
            $healthStatus = 'Warning'
        }
        else {
            $healthStatus = 'Healthy'
        }

        # Update counters
        switch ($healthStatus) {
            'Healthy'  { $healthyCt++ }
            'Warning'  { $warningCt++ }
            'Critical' { $criticalCt++ }
            'Unknown'  { $unknownCt++ }
        }
        if ($isStale) { $staleCt++ }
        if ($consecutiveFailures -gt 0) { $withFailuresCt++ }
        if ($null -ne $dataFreshnessHours) {
            $totalFreshness += $dataFreshnessHours
            $freshnessCount++
        }

        $lastAggInfo = @{
            Started         = $lastStarted
            Completed       = $lastCompleted
            DurationMinutes = $durationMinutes
            Status          = $lastStatus
            TotalAccounts   = $totalAccounts
            ErrorCount      = $errorCount
        }

        $sourceResults.Add(@{
            SourceId              = $sourceId
            SourceName            = $sourceName
            SourceType            = $source['Type']
            Enabled               = $source['Enabled']
            HealthStatus          = $healthStatus
            LastAggregation       = $lastAggInfo
            DataFreshnessHours    = $dataFreshnessHours
            IsStale               = $isStale
            ConsecutiveFailures   = $consecutiveFailures
            AvgDurationMinutes    = $avgDuration
            AccountTrend          = $accountTrend
            AccountTrendDetail    = $accountTrendDetail
        })
    }

    $avgFreshness = if ($freshnessCount -gt 0) { [math]::Round($totalFreshness / $freshnessCount, 1) } else { 0 }

    $result = @{
        Sources = @($sourceResults)
        Summary = @{
            TotalSources        = $allSources.Count
            Healthy             = $healthyCt
            Warning             = $warningCt
            Critical            = $criticalCt
            Unknown             = $unknownCt
            StaleSources        = $staleCt
            AvgFreshnessHours   = $avgFreshness
            SourcesWithFailures = $withFailuresCt
        }
    }

    Write-SPLog -Message "Get-SPSourceAggregationHealth: $($allSources.Count) sources -- Healthy=$healthyCt, Warning=$warningCt, Critical=$criticalCt, Unknown=$unknownCt, Stale=$staleCt" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPSourceAggregationHealth' `
        -CorrelationID $CorrelationID

    return $result
}

#endregion

#region P16-03: Identity Attribute Quality Score

function Measure-SPIdentityDataQuality {
    <#
    .SYNOPSIS
        Evaluates completeness and consistency of identity attributes.
    .DESCRIPTION
        Queries /v3/public-identities and checks each identity against a set of
        required attributes. Detects missing attributes, manager self-references,
        duplicate emails, and stale profiles. Produces per-identity quality scores
        and an overall tenant quality grade.
    .PARAMETER Limit
        Maximum number of identities to evaluate. Default 500.
    .PARAMETER RequiredAttributes
        Array of attribute names to check. Default: manager, department, email, title, location.
    .PARAMETER ActiveOnly
        When set, only evaluates identities with active lifecycle state.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Identities = @(...); AttributeCompleteness = @{...}; QualityIssues = @{...}; Summary = @{...} }
    .EXAMPLE
        $quality = Measure-SPIdentityDataQuality -Limit 500 -ActiveOnly
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [int]$Limit = 500,

        [Parameter()]
        [string[]]$RequiredAttributes,

        [Parameter()]
        [switch]$ActiveOnly,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    # Default required attributes
    if ($null -eq $RequiredAttributes -or $RequiredAttributes.Count -eq 0) {
        $RequiredAttributes = @('manager', 'department', 'email', 'title', 'location')
    }

    Write-SPLog -Message "Measure-SPIdentityDataQuality: scanning up to $Limit identities, ActiveOnly=$ActiveOnly, RequiredAttributes=($($RequiredAttributes -join ', '))" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Measure-SPIdentityDataQuality' `
        -CorrelationID $CorrelationID

    # Pagination ceiling
    $maxPages = 200
    try {
        $cfgForCeiling = Get-SPConfig
        if ($null -ne $cfgForCeiling.Api -and
            $cfgForCeiling.Api.PSObject.Properties.Name -contains 'MaxPaginationPages' -and
            [int]$cfgForCeiling.Api.MaxPaginationPages -gt 0) {
            $maxPages = [int]$cfgForCeiling.Api.MaxPaginationPages
        }
    } catch { }

    $identities = [System.Collections.Generic.List[hashtable]]::new()
    $pageSize = 250
    $offset = 0
    $pageNum = 0
    $fetched = 0

    do {
        $pageNum++
        if ($pageNum -gt $maxPages) {
            Write-SPLog -Message "Measure-SPIdentityDataQuality: pagination ceiling reached at page $pageNum" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Measure-SPIdentityDataQuality' `
                -CorrelationID $CorrelationID
            break
        }

        $remaining = $Limit - $fetched
        $thisPageSize = [math]::Min($pageSize, $remaining)

        $queryParams = @{
            'limit'  = $thisPageSize.ToString()
            'offset' = $offset.ToString()
        }

        $result = Invoke-SPApiRequest -Method GET -Endpoint '/v3/public-identities' `
            -QueryParams $queryParams -CorrelationID $CorrelationID

        if (-not $result.Success) {
            $errMsg = $result.Error
            # 403 on /v3/public-identities means missing scope -- surface it clearly
            # so the caller can add idn:identity-profile:read or sp:scopes:all to the PAT.
            if ($errMsg -match '403|forbidden') {
                $errMsg = "Access denied (403) on /v3/public-identities. Add 'idn:identity-profile:read' (or 'sp:scopes:all') to your Personal Access Token. Identity quality score will be 0 until scope is granted."
            }
            Write-SPLog -Message "Measure-SPIdentityDataQuality: API error at page ${pageNum} -- $errMsg" `
                -Severity ERROR -Component 'SP.AuditQueries' -Action 'Measure-SPIdentityDataQuality' `
                -CorrelationID $CorrelationID
            break
        }

        $page = $result.Data
        if ($null -ne $result.Data -and $result.Data.PSObject.Properties.Name -contains 'items') {
            $page = $result.Data.items
        }
        $page = @($page)

        foreach ($identity in $page) {
            if ($fetched -ge $Limit) { break }

            # Filter by lifecycle state if ActiveOnly
            $lifecycleState = ''
            if ($null -ne $identity.lifecycle_state) {
                $lifecycleState = [string]$identity.lifecycle_state
            }
            elseif ($null -ne $identity.lifecycleState) {
                $lifecycleState = [string]$identity.lifecycleState
            }

            if ($ActiveOnly -and -not [string]::IsNullOrWhiteSpace($lifecycleState)) {
                $stateUpper = $lifecycleState.ToUpper()
                if ($stateUpper -ne 'ACTIVE') { continue }
            }

            $identityId = [string]$identity.id
            $identityName = if ($null -ne $identity.name) { [string]$identity.name } else { '' }
            if ([string]::IsNullOrWhiteSpace($identityName) -and $null -ne $identity.displayName) {
                $identityName = [string]$identity.displayName
            }

            # Attribute presence check
            $missingAttrs = [System.Collections.Generic.List[string]]::new()
            $issues = [System.Collections.Generic.List[string]]::new()
            $attrPointValue = if ($RequiredAttributes.Count -gt 0) { 100.0 / $RequiredAttributes.Count } else { 100.0 }
            $score = 0.0

            foreach ($attr in $RequiredAttributes) {
                $attrValue = $null
                # Check direct property
                if ($null -ne $identity.PSObject -and $identity.PSObject.Properties.Name -contains $attr) {
                    $attrValue = $identity.$attr
                }
                # Check attributes collection (ISC sometimes nests in attributes map)
                elseif ($null -ne $identity.attributes -and $identity.attributes.PSObject.Properties.Name -contains $attr) {
                    $attrValue = $identity.attributes.$attr
                }

                # Manager attribute is special -- may be an object with id property
                if ($attr -eq 'manager' -and $null -ne $attrValue) {
                    if ($attrValue -is [System.Management.Automation.PSCustomObject] -or $attrValue -is [hashtable]) {
                        $mgrId = $null
                        if ($attrValue.PSObject.Properties.Name -contains 'id') { $mgrId = $attrValue.id }
                        elseif ($attrValue -is [hashtable] -and $attrValue.ContainsKey('id')) { $mgrId = $attrValue['id'] }
                        if ([string]::IsNullOrWhiteSpace($mgrId)) {
                            $attrValue = $null
                        }
                        else {
                            $attrValue = $mgrId
                        }
                    }
                }

                $isPresent = $false
                if ($null -ne $attrValue) {
                    if ($attrValue -is [string]) {
                        $isPresent = -not [string]::IsNullOrWhiteSpace($attrValue)
                    }
                    else {
                        $isPresent = $true
                    }
                }

                if ($isPresent) {
                    $score += $attrPointValue
                }
                else {
                    $missingAttrs.Add($attr)
                    $issues.Add("Missing: $attr")
                }
            }

            # Manager self-reference check
            $managerId = $null
            if ($null -ne $identity.manager) {
                if ($identity.manager -is [string]) {
                    $managerId = $identity.manager
                }
                elseif ($null -ne $identity.manager.id) {
                    $managerId = [string]$identity.manager.id
                }
            }
            if ($null -ne $identity.attributes -and $null -ne $identity.attributes.manager) {
                $mgrAttr = $identity.attributes.manager
                if ($mgrAttr -is [string]) {
                    $managerId = $mgrAttr
                }
                elseif ($null -ne $mgrAttr.id) {
                    $managerId = [string]$mgrAttr.id
                }
            }

            $isManagerSelfRef = $false
            if (-not [string]::IsNullOrWhiteSpace($managerId) -and $managerId -eq $identityId) {
                $isManagerSelfRef = $true
                $score = [math]::Max(0, $score - 10)
                $issues.Add('ManagerSelfReference')
            }

            # Stale profile check (modified > 365 days ago)
            $isStaleProfile = $false
            $modifiedStr = $null
            if ($null -ne $identity.modified) { $modifiedStr = [string]$identity.modified }
            elseif ($null -ne $identity.lastModified) { $modifiedStr = [string]$identity.lastModified }
            if (-not [string]::IsNullOrWhiteSpace($modifiedStr)) {
                try {
                    $modifiedDt = [datetime]::Parse($modifiedStr)
                    $daysSinceModified = ((Get-Date) - $modifiedDt).TotalDays
                    if ($daysSinceModified -gt 365) {
                        $isStaleProfile = $true
                        $score = [math]::Max(0, $score - 5)
                        $issues.Add('StaleProfile')
                    }
                }
                catch { }
            }

            # Clamp score
            $score = [math]::Max(0, [math]::Min(100, [math]::Round($score, 1)))

            # Extract email for duplicate check
            $email = $null
            if ($null -ne $identity.email) { $email = [string]$identity.email }
            elseif ($null -ne $identity.attributes -and $null -ne $identity.attributes.email) { $email = [string]$identity.attributes.email }

            $identities.Add(@{
                IdentityId        = $identityId
                IdentityName      = $identityName
                LifecycleState    = $lifecycleState
                QualityScore      = $score
                MissingAttributes = @($missingAttrs)
                Issues            = @($issues)
                Email             = $email
                ManagerSelfRef    = $isManagerSelfRef
                StaleProfile      = $isStaleProfile
            })

            $fetched++
        }

        Write-SPLog -Message "Measure-SPIdentityDataQuality: page $pageNum, $($page.Count) identities (total fetched: $fetched)" `
            -Severity DEBUG -Component 'SP.AuditQueries' -Action 'Measure-SPIdentityDataQuality' `
            -CorrelationID $CorrelationID

        $offset += $thisPageSize

    } while ($null -ne $page -and $page.Count -ge $thisPageSize -and $fetched -lt $Limit)

    # Attribute completeness
    $attrCompleteness = @{}
    foreach ($attr in $RequiredAttributes) {
        $presentCount = @($identities | Where-Object { $_['MissingAttributes'] -notcontains $attr }).Count
        $missingCount = $identities.Count - $presentCount
        $pct = if ($identities.Count -gt 0) { [math]::Round(($presentCount / $identities.Count) * 100, 1) } else { 0 }
        $attrCompleteness[$attr] = @{
            Present = $presentCount
            Missing = $missingCount
            Pct     = $pct
        }
    }

    # Quality issues
    # Use dot notation (works for both hashtable and PSCustomObject) to prevent
    # "does not contain a method named 'ContainsKey'" line-1-char-1 errors.
    $managerSelfRefs = @($identities | Where-Object { $_.ManagerSelfRef -eq $true } | ForEach-Object { $_.IdentityId })
    $staleProfiles = @($identities | Where-Object { $_.StaleProfile -eq $true } | ForEach-Object { $_.IdentityId })

    # Duplicate email detection
    $emailMap = @{}
    foreach ($ident in $identities) {
        $e = $ident['Email']
        if (-not [string]::IsNullOrWhiteSpace($e)) {
            $eLower = $e.ToLower()
            if (-not $emailMap.ContainsKey($eLower)) {
                $emailMap[$eLower] = [System.Collections.Generic.List[string]]::new()
            }
            $emailMap[$eLower].Add($ident['IdentityId'])
        }
    }
    $duplicateEmails = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in $emailMap.GetEnumerator()) {
        if ($entry.Value.Count -gt 1) {
            $duplicateEmails.Add(@{
                Email       = $entry.Key
                IdentityIds = @($entry.Value)
            })
        }
    }

    $qualityIssues = @{
        ManagerSelfReference = $managerSelfRefs
        DuplicateEmails      = @($duplicateEmails)
        StaleProfiles        = $staleProfiles
    }

    # Summary
    $overallScore = 0
    if ($identities.Count -gt 0) {
        $totalScore = 0
        foreach ($ident in $identities) { $totalScore += $ident['QualityScore'] }
        $overallScore = [math]::Round($totalScore / $identities.Count, 1)
    }

    $overallGrade = switch ($true) {
        ($overallScore -ge 90) { 'A' }
        ($overallScore -ge 80) { 'B' }
        ($overallScore -ge 70) { 'C' }
        ($overallScore -ge 60) { 'D' }
        default                { 'F' }
    }

    # Find worst attribute
    $worstAttr = ''
    $worstPct = 100.0
    foreach ($attr in $RequiredAttributes) {
        if ($attrCompleteness[$attr]['Pct'] -lt $worstPct) {
            $worstPct = $attrCompleteness[$attr]['Pct']
            $worstAttr = $attr
        }
    }

    # Identities with at least one issue -- dot notation for PS-5.1 PSCustomObject safety
    $identitiesWithIssues = @($identities | Where-Object { $_.Issues.Count -gt 0 }).Count

    # Grade distribution
    $gradeA = @($identities | Where-Object { $_.QualityScore -ge 90 }).Count
    $gradeB = @($identities | Where-Object { $_.QualityScore -ge 80 -and $_.QualityScore -lt 90 }).Count
    $gradeC = @($identities | Where-Object { $_.QualityScore -ge 70 -and $_.QualityScore -lt 80 }).Count
    $gradeD = @($identities | Where-Object { $_.QualityScore -ge 60 -and $_.QualityScore -lt 70 }).Count
    $gradeF = @($identities | Where-Object { $_.QualityScore -lt 60 }).Count

    $summaryResult = @{
        TotalIdentitiesScanned   = $identities.Count
        OverallQualityScore      = $overallScore
        OverallQualityGrade      = $overallGrade
        WorstAttribute           = $worstAttr
        WorstAttributePct        = $worstPct
        IdentitiesWithIssues     = $identitiesWithIssues
        QualityGradeDistribution = @{
            A = $gradeA
            B = $gradeB
            C = $gradeC
            D = $gradeD
            F = $gradeF
        }
    }

    # Remove internal-only fields from identity output
    $outputIdentities = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($ident in $identities) {
        $outputIdentities.Add(@{
            IdentityId        = $ident['IdentityId']
            IdentityName      = $ident['IdentityName']
            LifecycleState    = $ident['LifecycleState']
            QualityScore      = $ident['QualityScore']
            MissingAttributes = $ident['MissingAttributes']
            Issues            = $ident['Issues']
        })
    }

    $finalResult = @{
        Identities            = @($outputIdentities)
        AttributeCompleteness = $attrCompleteness
        QualityIssues         = $qualityIssues
        Summary               = $summaryResult
    }

    Write-SPLog -Message "Measure-SPIdentityDataQuality: $($identities.Count) identities scanned, Overall=$overallScore ($overallGrade), Worst=$worstAttr ($worstPct%), Issues=$identitiesWithIssues" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Measure-SPIdentityDataQuality' `
        -CorrelationID $CorrelationID

    return $finalResult
}

#endregion

#region P16-07: Reviewer Delegation Audit Trail

function Get-SPReviewerDelegations {
    <#
    .SYNOPSIS
        Analyzes certification item reassignments to detect delegation patterns.
    .DESCRIPTION
        Examines campaign audit decision items for reassignment indicators --
        items where the final reviewer differs from the original assigned reviewer.
        Detects patterns such as high-frequency delegators, deadline-proximate
        reassignments, circular delegation chains, and delegate-to-approver behavior.

        Works with campaign audit data produced by the standard audit pipeline
        (Get-SPAuditCampaigns / Get-SPAuditCampaignReport / Group-SPAuditDecisions).
        Each decision item may contain OriginalReviewer, ReassignedFrom, or
        ReviewerClassification fields indicating reassignment. When reassignment
        data is not present in the audit data, returns a summary noting that
        reassignment data is unavailable rather than erroring.
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables. Each must contain CampaignId,
        CampaignName, and Decisions (with Approved/Revoked/Pending arrays).
    .PARAMETER DeadlineProximityHours
        Hours before campaign deadline within which a reassignment is flagged
        as a DeadlineDelegation. Default: 24.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Delegations; ReviewerMetrics; PatternSummary; Summary }
    .EXAMPLE
        $audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object {
            Get-SPAuditCampaignReport -CampaignId $_.id
        }
        $delegations = Get-SPReviewerDelegations -CampaignAudits $audits
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$DeadlineProximityHours = 24,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPReviewerDelegations: starting with $($CampaignAudits.Count) campaign(s), DeadlineProximityHours=$DeadlineProximityHours" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerDelegations' `
        -CorrelationID $CorrelationID

    # Empty input guard
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        Write-SPLog -Message "Get-SPReviewerDelegations: no campaign audits provided" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerDelegations' `
            -CorrelationID $CorrelationID
        return @{
            Delegations    = @()
            ReviewerMetrics = @()
            PatternSummary = @{
                HighDelegators      = 0
                DeadlineDelegations = 0
                CircularDelegations = 0
                DelegateToApprover  = 0
            }
            Summary = @{
                TotalItemsAnalyzed       = 0
                TotalReassigned          = 0
                OverallReassignmentRate  = 0.0
                CampaignsWithDelegations = 0
                ReviewersWhoDelegate     = 0
            }
        }
    }

    $delegations = [System.Collections.Generic.List[hashtable]]::new()
    # Track per-reviewer stats: reviewer -> @{ Assigned; Reassigned; Timestamps }
    $reviewerStats = @{}
    # Track per-reviewer approval rates for delegate-to-approver detection
    $reviewerApprovalCounts = @{}
    $reviewerTotalDecisions = @{}

    $totalItemsAnalyzed   = 0
    $totalReassigned       = 0
    $campaignsWithDelegations = [System.Collections.Generic.HashSet[string]]::new()
    $reassignmentDataAvailable = $false

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $campaignId   = if ($audit.ContainsKey('CampaignId'))   { [string]$audit['CampaignId'] }   else { '' }
        $campaignName = if ($audit.ContainsKey('CampaignName')) { [string]$audit['CampaignName'] } else { '' }

        # Parse campaign deadline
        $deadlineDate = $null
        $dlStr = ''
        if ($audit.ContainsKey('Deadline')) { $dlStr = [string]$audit['Deadline'] }
        if (-not [string]::IsNullOrWhiteSpace($dlStr)) {
            try {
                $deadlineDate = [datetime]::Parse($dlStr,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            } catch { $deadlineDate = $null }
        }

        # Parse campaign created date
        $campaignCreated = $null
        if ($audit.ContainsKey('Created')) {
            $createdStr = [string]$audit['Created']
            if (-not [string]::IsNullOrWhiteSpace($createdStr)) {
                try {
                    $campaignCreated = [datetime]::Parse($createdStr,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                } catch { $campaignCreated = $null }
            }
        }

        # Extract decisions
        $decisions = $null
        if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $decisions = $audit['Decisions']
        }
        if ($null -eq $decisions) { continue }

        # Process all decision categories
        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }
                $totalItemsAnalyzed++

                # Extract fields - support both hashtable and PSObject
                $reviewerName     = ''
                $originalReviewer = ''
                $identityName     = ''
                $entitlementName  = ''
                $completedDateStr = ''
                $decision         = $category
                $reassignedFrom   = ''
                $reassignmentChainRaw = $null
                $reviewerClassification = ''

                if ($item -is [hashtable]) {
                    if ($item.ContainsKey('ReviewerName'))     { $reviewerName     = [string]$item['ReviewerName'] }
                    if ($item.ContainsKey('OriginalReviewer')) { $originalReviewer = [string]$item['OriginalReviewer'] }
                    if ($item.ContainsKey('ReassignedFrom'))   { $reassignedFrom   = [string]$item['ReassignedFrom'] }
                    if ($item.ContainsKey('IdentityName'))     { $identityName     = [string]$item['IdentityName'] }
                    if ($item.ContainsKey('AccessName'))       { $entitlementName  = [string]$item['AccessName'] }
                    if ($item.ContainsKey('CompletedDate'))    { $completedDateStr = [string]$item['CompletedDate'] }
                    elseif ($item.ContainsKey('DecisionDate')) { $completedDateStr = [string]$item['DecisionDate'] }
                    elseif ($item.ContainsKey('Created'))      { $completedDateStr = [string]$item['Created'] }
                    if ($item.ContainsKey('Decision'))         { $decision         = [string]$item['Decision'] }
                    if ($item.ContainsKey('ReassignmentChain')) { $reassignmentChainRaw = $item['ReassignmentChain'] }
                    if ($item.ContainsKey('ReviewerClassification')) { $reviewerClassification = [string]$item['ReviewerClassification'] }
                } else {
                    if ($null -ne $item.PSObject.Properties['ReviewerName']     -and $null -ne $item.ReviewerName)     { $reviewerName     = [string]$item.ReviewerName }
                    if ($null -ne $item.PSObject.Properties['OriginalReviewer'] -and $null -ne $item.OriginalReviewer) { $originalReviewer = [string]$item.OriginalReviewer }
                    if ($null -ne $item.PSObject.Properties['ReassignedFrom']   -and $null -ne $item.ReassignedFrom)   { $reassignedFrom   = [string]$item.ReassignedFrom }
                    if ($null -ne $item.PSObject.Properties['IdentityName']     -and $null -ne $item.IdentityName)     { $identityName     = [string]$item.IdentityName }
                    if ($null -ne $item.PSObject.Properties['AccessName']       -and $null -ne $item.AccessName)       { $entitlementName  = [string]$item.AccessName }
                    if ($null -ne $item.PSObject.Properties['CompletedDate']    -and $null -ne $item.CompletedDate)    { $completedDateStr = [string]$item.CompletedDate }
                    elseif ($null -ne $item.PSObject.Properties['DecisionDate'] -and $null -ne $item.DecisionDate)     { $completedDateStr = [string]$item.DecisionDate }
                    elseif ($null -ne $item.PSObject.Properties['Created']      -and $null -ne $item.Created)          { $completedDateStr = [string]$item.Created }
                    if ($null -ne $item.PSObject.Properties['Decision']         -and $null -ne $item.Decision)         { $decision         = [string]$item.Decision }
                    if ($null -ne $item.PSObject.Properties['ReassignmentChain']) { $reassignmentChainRaw = $item.ReassignmentChain }
                    if ($null -ne $item.PSObject.Properties['ReviewerClassification'] -and $null -ne $item.ReviewerClassification) { $reviewerClassification = [string]$item.ReviewerClassification }
                }

                if ([string]::IsNullOrWhiteSpace($reviewerName)) { continue }

                # Determine original reviewer for reassignment detection
                $origReviewer = ''
                if (-not [string]::IsNullOrWhiteSpace($originalReviewer)) {
                    $origReviewer = $originalReviewer
                    $reassignmentDataAvailable = $true
                } elseif (-not [string]::IsNullOrWhiteSpace($reassignedFrom)) {
                    $origReviewer = $reassignedFrom
                    $reassignmentDataAvailable = $true
                } elseif ($reviewerClassification -eq 'Reassigned') {
                    # We know it was reassigned but don't know the original reviewer
                    $origReviewer = '(Unknown original reviewer)'
                    $reassignmentDataAvailable = $true
                }

                # Track reviewer assignment counts (original reviewer gets assignment credit)
                $assignedReviewer = if (-not [string]::IsNullOrWhiteSpace($origReviewer) -and $origReviewer -ne '(Unknown original reviewer)') {
                    $origReviewer
                } else {
                    $reviewerName
                }

                if (-not $reviewerStats.ContainsKey($assignedReviewer)) {
                    $reviewerStats[$assignedReviewer] = @{
                        Assigned    = 0
                        Reassigned  = 0
                        # Hours from the OWNING campaign's created date to the delegation --
                        # computed at collection time (below), where this audit's
                        # $campaignCreated is in scope. The metrics loop runs after the
                        # audit loop and used to difference raw timestamps against the
                        # loop-leaked LAST campaign's created date, skewing (or zeroing)
                        # AvgHoursBeforeDelegation for every reviewer.
                        DelegationHours = [System.Collections.Generic.List[double]]::new()
                    }
                }
                $reviewerStats[$assignedReviewer]['Assigned']++

                # Track final reviewer approval rates
                if (-not $reviewerApprovalCounts.ContainsKey($reviewerName)) {
                    $reviewerApprovalCounts[$reviewerName] = 0
                    $reviewerTotalDecisions[$reviewerName] = 0
                }
                if ($category -ne 'Pending') {
                    $reviewerTotalDecisions[$reviewerName]++
                    if ($decision -eq 'Approved' -or $category -eq 'Approved') {
                        $reviewerApprovalCounts[$reviewerName]++
                    }
                }

                # Check if this item was reassigned
                $isReassigned = (-not [string]::IsNullOrWhiteSpace($origReviewer)) -and ($origReviewer -ne $reviewerName)
                if (-not $isReassigned) { continue }

                $totalReassigned++
                $campaignsWithDelegations.Add($campaignId) | Out-Null

                # Credit reassignment to original reviewer
                $reviewerStats[$assignedReviewer]['Reassigned']++

                # Parse completed date for timing analysis
                $completedDate = $null
                if (-not [string]::IsNullOrWhiteSpace($completedDateStr)) {
                    try {
                        $completedDate = [datetime]::Parse($completedDateStr,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    } catch { $completedDate = $null }
                }

                # Estimate delegation lead time (completedDate as proxy) against THIS
                # audit's campaign created date (both UTC-normalized).
                if ($null -ne $completedDate -and $null -ne $campaignCreated) {
                    $delegHours = ($completedDate - $campaignCreated).TotalHours
                    if ($delegHours -lt 0) { $delegHours = 0.0 }
                    $reviewerStats[$assignedReviewer]['DelegationHours'].Add([double]$delegHours)
                }

                # Build reassignment chain
                $reassignmentChain = @()
                if ($null -ne $reassignmentChainRaw -and $reassignmentChainRaw.Count -gt 0) {
                    $reassignmentChain = @($reassignmentChainRaw)
                } else {
                    $reassignmentChain = @($origReviewer, $reviewerName)
                }

                # Calculate time before deadline
                $timeBeforeDeadline = $null
                if ($null -ne $deadlineDate -and $null -ne $completedDate) {
                    $timeBeforeDeadline = [math]::Round(($deadlineDate - $completedDate).TotalHours, 1)
                }

                # Detect patterns for this delegation
                $patterns = [System.Collections.Generic.List[string]]::new()

                # DeadlineDelegation: reassignment within DeadlineProximityHours of deadline
                if ($null -ne $timeBeforeDeadline -and $timeBeforeDeadline -ge 0 -and $timeBeforeDeadline -le $DeadlineProximityHours) {
                    $patterns.Add('DeadlineDelegation')
                }

                # CircularDelegation: item assigned back to a previous reviewer in the chain
                if ($reassignmentChain.Count -gt 2) {
                    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $hasCircular = $false
                    foreach ($r in $reassignmentChain) {
                        if (-not $seen.Add($r)) {
                            $hasCircular = $true
                            break
                        }
                    }
                    if ($hasCircular) { $patterns.Add('CircularDelegation') }
                } elseif ($reassignmentChain.Count -eq 2) {
                    # Check A->B->A pattern by looking at other delegations in same campaign
                    # (handled in post-processing below)
                }

                # Extract item ID if available
                $itemId = ''
                if ($item -is [hashtable] -and $item.ContainsKey('ItemId')) {
                    $itemId = [string]$item['ItemId']
                } elseif ($item -is [hashtable] -and $item.ContainsKey('CertificationId')) {
                    $itemId = [string]$item['CertificationId']
                } elseif ($null -ne $item.PSObject -and $null -ne $item.PSObject.Properties['ItemId']) {
                    $itemId = [string]$item.ItemId
                }

                $delegations.Add(@{
                    CampaignId          = $campaignId
                    CampaignName        = $campaignName
                    ItemId              = $itemId
                    IdentityName        = $identityName
                    EntitlementName     = $entitlementName
                    OriginalReviewer    = $origReviewer
                    FinalReviewer       = $reviewerName
                    ReassignmentChain   = $reassignmentChain
                    ReassignmentCount   = [math]::Max(1, $reassignmentChain.Count - 1)
                    TimeBeforeDeadline  = $timeBeforeDeadline
                    FinalDecision       = $decision
                    Patterns            = @($patterns)
                })
            }
        }
    }

    # Post-processing: detect circular A->B->A across delegations within same campaign
    $campaignDelegationPairs = @{}
    foreach ($d in $delegations) {
        $key = "$($d['CampaignId'])|$($d['OriginalReviewer'])|$($d['FinalReviewer'])"
        $reverseKey = "$($d['CampaignId'])|$($d['FinalReviewer'])|$($d['OriginalReviewer'])"
        if (-not $campaignDelegationPairs.ContainsKey($key)) {
            $campaignDelegationPairs[$key] = $true
        }
        if ($campaignDelegationPairs.ContainsKey($reverseKey)) {
            # A->B and B->A both exist -- mark as circular
            if ($d['Patterns'] -notcontains 'CircularDelegation') {
                $d['Patterns'] = @($d['Patterns']) + @('CircularDelegation')
            }
        }
    }

    # Build reviewer metrics
    $reviewerMetrics = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($rName in ($reviewerStats.Keys | Sort-Object)) {
        $rs = $reviewerStats[$rName]
        $assigned   = $rs['Assigned']
        $reassigned = $rs['Reassigned']
        $rate = if ($assigned -gt 0) { [math]::Round(($reassigned / $assigned) * 100, 1) } else { 0.0 }

        # Average hours before delegation -- per-delegation lead times were computed
        # at collection time against each delegation's OWN campaign created date.
        $avgHours = 0.0
        $delegHoursList = $rs['DelegationHours']
        if ($delegHoursList.Count -gt 0) {
            $totalHours = 0.0
            foreach ($h in $delegHoursList) { $totalHours += [double]$h }
            $avgHours = [math]::Round($totalHours / $delegHoursList.Count, 1)
        }

        $rPatterns = [System.Collections.Generic.List[string]]::new()

        # HighDelegator: >30% reassignment rate
        if ($rate -gt 30.0) {
            $rPatterns.Add('HighDelegator')
        }

        # DelegateToApprover: reviewer consistently reassigns to someone who always approves
        $delegateTargets = @($delegations | Where-Object { $_['OriginalReviewer'] -eq $rName } |
            ForEach-Object { $_['FinalReviewer'] } | Sort-Object -Unique)
        foreach ($target in $delegateTargets) {
            if ($reviewerTotalDecisions.ContainsKey($target) -and $reviewerTotalDecisions[$target] -ge 5) {
                $approvalRate = [math]::Round(($reviewerApprovalCounts[$target] / $reviewerTotalDecisions[$target]) * 100, 1)
                if ($approvalRate -ge 95.0) {
                    $rPatterns.Add('DelegateToApprover')
                    break
                }
            }
        }

        $reviewerMetrics.Add(@{
            ReviewerName             = $rName
            ItemsAssigned            = $assigned
            ItemsReassigned          = $reassigned
            ReassignmentRate         = $rate
            AvgHoursBeforeDelegation = $avgHours
            Patterns                 = @($rPatterns)
        })
    }

    # Pattern summary counts
    $highDelegatorCount      = @($reviewerMetrics | Where-Object { $_['Patterns'] -contains 'HighDelegator' }).Count
    $deadlineDelegationCount = @($delegations | Where-Object { $_['Patterns'] -contains 'DeadlineDelegation' }).Count
    $circularDelegationCount = @($delegations | Where-Object { $_['Patterns'] -contains 'CircularDelegation' }).Count
    $delegateToApproverCount = @($reviewerMetrics | Where-Object { $_['Patterns'] -contains 'DelegateToApprover' }).Count

    $overallRate = if ($totalItemsAnalyzed -gt 0) { [math]::Round(($totalReassigned / $totalItemsAnalyzed) * 100, 1) } else { 0.0 }
    $reviewersWhoDelegate = @($reviewerMetrics | Where-Object { $_['ItemsReassigned'] -gt 0 }).Count

    $summaryResult = @{
        TotalItemsAnalyzed       = $totalItemsAnalyzed
        TotalReassigned          = $totalReassigned
        OverallReassignmentRate  = $overallRate
        CampaignsWithDelegations = $campaignsWithDelegations.Count
        ReviewersWhoDelegate     = $reviewersWhoDelegate
    }

    if (-not $reassignmentDataAvailable -and $totalItemsAnalyzed -gt 0) {
        $summaryResult['Note'] = 'Reassignment data unavailable in campaign audit data. Enrich audit items with OriginalReviewer or ReassignedFrom fields for delegation analysis.'
    }

    Write-SPLog -Message "Get-SPReviewerDelegations: $totalItemsAnalyzed items analyzed, $totalReassigned reassigned ($overallRate%), HighDelegators=$highDelegatorCount, DeadlineDelegations=$deadlineDelegationCount, CircularDelegations=$circularDelegationCount" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Get-SPReviewerDelegations' `
        -CorrelationID $CorrelationID

    return @{
        Delegations     = @($delegations)
        ReviewerMetrics = @($reviewerMetrics)
        PatternSummary  = @{
            HighDelegators      = $highDelegatorCount
            DeadlineDelegations = $deadlineDelegationCount
            CircularDelegations = $circularDelegationCount
            DelegateToApprover  = $delegateToApproverCount
        }
        Summary         = $summaryResult
    }
}

#endregion

#region P14-04: Source Onboarding Readiness (DF-06)

function Test-SPSourceOnboardingReadiness {
    <#
    .SYNOPSIS
        Pre-flight checklist for adding a new source to ISC governance.
    .DESCRIPTION
        Validates that a source meets all prerequisites for governance onboarding:
        source exists, owner assigned, schema configured, correlation rules set,
        accounts aggregated, entitlements aggregated, and campaign readiness.
        Returns structured pass/fail per check with remediation guidance.
    .PARAMETER SourceId
        The ISC source ID to evaluate.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{ Success = $bool; Data = @{ SourceId; SourceName; Checks; Summary }; Error = $string }
    .EXAMPLE
        $readiness = Test-SPSourceOnboardingReadiness -SourceId '2c91808a7e2b3c4d...'
        $readiness.Data.Checks | Where-Object { $_.Status -eq 'Fail' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceId,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Test-SPSourceOnboardingReadiness: evaluating source '$SourceId'" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
        -CorrelationID $CorrelationID

    $checks = [System.Collections.Generic.List[hashtable]]::new()
    $sourceName = ''

    # Helper to add a check result
    $addCheck = {
        param([string]$Name, [string]$Status, [string]$Detail, [string]$Remediation)
        $checks.Add(@{
            Check       = $Name
            Status      = $Status
            Detail      = $Detail
            Remediation = $Remediation
        })
    }

    try {
        # ------------------------------------------------------------------
        # Check 1: Source exists
        # ------------------------------------------------------------------
        $srcResult = $null
        try {
            $srcResult = Invoke-SPApiRequest -Method GET -Endpoint "/v3/sources/$SourceId" `
                -CorrelationID $CorrelationID
        }
        catch {
            Write-SPLog -Message "Test-SPSourceOnboardingReadiness: API error querying source: $_" `
                -Severity ERROR -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
                -CorrelationID $CorrelationID
        }

        if ($null -eq $srcResult -or -not $srcResult.Success -or $null -eq $srcResult.Data) {
            & $addCheck 'SourceExists' 'Fail' "Source '$SourceId' not found or API error" `
                'Verify the source ID is correct and the PAT has idn:sources:read scope.'

            Write-SPLog -Message "Test-SPSourceOnboardingReadiness: source not found, aborting remaining checks" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
                -CorrelationID $CorrelationID

            return @{
                Success = $true
                Data    = @{
                    SourceId   = $SourceId
                    SourceName = ''
                    Checks     = @($checks)
                    Summary    = @{
                        TotalChecks = 1
                        Passed      = 0
                        Failed      = 1
                        Warnings    = 0
                        ReadyForGovernance = $false
                    }
                }
                Error   = $null
            }
        }

        $src = $srcResult.Data
        & $addCheck 'SourceExists' 'Pass' "Source found: $( if ($null -ne $src.name) { [string]$src.name } else { $SourceId } )" ''
        if ($null -ne $src.name) { $sourceName = [string]$src.name }

        # ------------------------------------------------------------------
        # Check 2: Owner assigned
        # ------------------------------------------------------------------
        $ownerName = ''
        $ownerId   = ''
        if ($null -ne $src.owner) {
            if ($null -ne $src.owner.name) { $ownerName = [string]$src.owner.name }
            if ($null -ne $src.owner.id)   { $ownerId   = [string]$src.owner.id }
        }

        if (-not [string]::IsNullOrWhiteSpace($ownerId) -and -not [string]::IsNullOrWhiteSpace($ownerName)) {
            & $addCheck 'OwnerAssigned' 'Pass' "Owner: $ownerName ($ownerId)" ''
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ownerId)) {
            & $addCheck 'OwnerAssigned' 'Warn' "Owner ID set ($ownerId) but name is empty" `
                'Verify the source owner identity exists and has a display name.'
        }
        else {
            & $addCheck 'OwnerAssigned' 'Fail' 'No owner assigned to this source' `
                'In ISC Admin > Sources > [source] > Settings, assign a source owner. Required for governance workflows and escalation paths.'
        }

        # ------------------------------------------------------------------
        # Check 3: Schema configured
        # ------------------------------------------------------------------
        $schemaResult = $null
        try {
            $schemaResult = Invoke-SPApiRequest -Method GET -Endpoint "/v3/sources/$SourceId/schemas" `
                -CorrelationID $CorrelationID
        }
        catch {
            Write-SPLog -Message "Test-SPSourceOnboardingReadiness: error querying schemas: $_" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
                -CorrelationID $CorrelationID
        }

        $schemas = @()
        if ($null -ne $schemaResult -and $schemaResult.Success -and $null -ne $schemaResult.Data) {
            $schemaData = $schemaResult.Data
            if ($null -ne $schemaResult.Data.PSObject.Properties.Name -and
                $schemaResult.Data.PSObject.Properties.Name -contains 'items') {
                $schemaData = $schemaResult.Data.items
            }
            $schemas = @($schemaData)
        }

        $hasAccountSchema = $false
        $hasEntitlementSchema = $false
        $accountAttrCount = 0
        foreach ($schema in $schemas) {
            $schemaName = ''
            if ($null -ne $schema.name) { $schemaName = [string]$schema.name }
            elseif ($schema -is [hashtable] -and $schema.ContainsKey('name')) { $schemaName = [string]$schema['name'] }

            if ($schemaName -eq 'account') {
                $hasAccountSchema = $true
                if ($null -ne $schema.attributes) {
                    $accountAttrCount = @($schema.attributes).Count
                }
                elseif ($schema -is [hashtable] -and $schema.ContainsKey('attributes')) {
                    $accountAttrCount = @($schema['attributes']).Count
                }
            }
            elseif ($schemaName -eq 'group' -or $schemaName -eq 'entitlement') {
                $hasEntitlementSchema = $true
            }
        }

        if ($hasAccountSchema -and $accountAttrCount -gt 0) {
            & $addCheck 'SchemaConfigured' 'Pass' "Account schema has $accountAttrCount attributes; Entitlement schema: $( if ($hasEntitlementSchema) { 'present' } else { 'not present' } )" ''
        }
        elseif ($hasAccountSchema) {
            & $addCheck 'SchemaConfigured' 'Warn' 'Account schema exists but has no attributes defined' `
                'Run a test aggregation or manually define account attributes in the source schema.'
        }
        else {
            & $addCheck 'SchemaConfigured' 'Fail' "No account schema found ($($schemas.Count) schemas total)" `
                'Discover the source schema: ISC Admin > Sources > [source] > Account Schema > Discover Schema, or run a test account aggregation.'
        }

        # ------------------------------------------------------------------
        # Check 4: Correlation rules set
        # ------------------------------------------------------------------
        $hasCorrelation = $false
        $correlationDetail = ''

        # Check accountCorrelationConfig on the source object
        if ($null -ne $src.accountCorrelationConfig) {
            $hasCorrelation = $true
            $correlationDetail = 'accountCorrelationConfig present on source'
        }
        # Also check connectorAttributes for correlation settings
        elseif ($null -ne $src.connectorAttributes) {
            $connAttrs = $src.connectorAttributes
            $corrFields = @('accountCorrelationConfig', 'correlationConfig', 'accountCorrelationRule')
            foreach ($field in $corrFields) {
                $hasField = $false
                if ($connAttrs -is [hashtable]) {
                    $hasField = $connAttrs.ContainsKey($field) -and $null -ne $connAttrs[$field]
                }
                else {
                    $hasField = $null -ne $connAttrs.PSObject.Properties.Name -and
                                $connAttrs.PSObject.Properties.Name -contains $field -and
                                $null -ne $connAttrs.$field
                }
                if ($hasField) {
                    $hasCorrelation = $true
                    $correlationDetail = "$field found in connectorAttributes"
                    break
                }
            }
        }

        if ($hasCorrelation) {
            & $addCheck 'CorrelationRules' 'Pass' $correlationDetail ''
        }
        else {
            & $addCheck 'CorrelationRules' 'Fail' 'No correlation configuration found' `
                'Configure account correlation in ISC Admin > Sources > [source] > Account Correlation. Map source attributes (e.g., sAMAccountName, email) to identity attributes for accurate identity matching.'
        }

        # ------------------------------------------------------------------
        # Check 5: Accounts aggregated
        # ------------------------------------------------------------------
        $accountCount = 0
        if ($null -ne $src.accountCount) { $accountCount = [int]$src.accountCount }

        # Also check aggregation history
        $aggQueryParams = @{
            'filters' = "sourceId eq `"$SourceId`""
            'sorters' = '-started'
            'limit'   = '1'
        }
        $hasSuccessfulAgg = $false
        $lastAggDate = ''
        try {
            $aggResult = Invoke-SPApiRequest -Method GET -Endpoint '/v3/account-aggregations' `
                -QueryParams $aggQueryParams -CorrelationID $CorrelationID

            if ($aggResult.Success -and $null -ne $aggResult.Data) {
                $aggData = $aggResult.Data
                if ($null -ne $aggResult.Data.PSObject.Properties.Name -and
                    $aggResult.Data.PSObject.Properties.Name -contains 'items') {
                    $aggData = $aggResult.Data.items
                }
                $aggs = @($aggData)
                if ($aggs.Count -gt 0 -and $null -ne $aggs[0]) {
                    $aggStatus = ''
                    if ($null -ne $aggs[0].status) { $aggStatus = [string]$aggs[0].status }
                    if ($aggStatus -eq 'SUCCESS') { $hasSuccessfulAgg = $true }
                    if ($null -ne $aggs[0].completed) { $lastAggDate = [string]$aggs[0].completed }
                    elseif ($null -ne $aggs[0].started) { $lastAggDate = [string]$aggs[0].started }
                }
            }
        }
        catch {
            Write-SPLog -Message "Test-SPSourceOnboardingReadiness: error querying aggregations: $_" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
                -CorrelationID $CorrelationID
        }

        if ($accountCount -gt 0 -and $hasSuccessfulAgg) {
            & $addCheck 'AccountsAggregated' 'Pass' "$accountCount accounts; last aggregation: $lastAggDate" ''
        }
        elseif ($accountCount -gt 0) {
            & $addCheck 'AccountsAggregated' 'Warn' "$accountCount accounts found but no successful aggregation in recent history" `
                'Run a test aggregation to confirm the connector is pulling accounts correctly.'
        }
        elseif ($hasSuccessfulAgg) {
            & $addCheck 'AccountsAggregated' 'Warn' "Aggregation succeeded but account count is 0" `
                'Check source filters and connector configuration -- aggregation completed but no accounts were imported.'
        }
        else {
            & $addCheck 'AccountsAggregated' 'Fail' 'No accounts and no successful aggregation found' `
                'Run an account aggregation: ISC Admin > Sources > [source] > Test Connection, then Aggregate Accounts. Verify connector credentials and network connectivity (VA reachability for on-prem sources).'
        }

        # ------------------------------------------------------------------
        # Check 6: Entitlements aggregated
        # ------------------------------------------------------------------
        $entitlementCount = 0
        $entQueryParams = @{
            'filters' = "source.id eq `"$SourceId`""
            'count'   = 'true'
            'limit'   = '1'
        }
        try {
            $entResult = Invoke-SPApiRequest -Method GET -Endpoint '/v3/entitlements' `
                -QueryParams $entQueryParams -CorrelationID $CorrelationID

            if ($entResult.Success) {
                # Try to get count from X-Total-Count header or response structure
                if ($null -ne $entResult.Data) {
                    $entData = $entResult.Data
                    if ($null -ne $entResult.Data.PSObject.Properties.Name -and
                        $entResult.Data.PSObject.Properties.Name -contains 'count') {
                        $entitlementCount = [int]$entResult.Data.count
                    }
                    elseif ($null -ne $entResult.Data.PSObject.Properties.Name -and
                            $entResult.Data.PSObject.Properties.Name -contains 'items') {
                        $entitlementCount = @($entResult.Data.items).Count
                    }
                    else {
                        $entitlementCount = @($entData).Count
                    }
                }
                # Check TotalCount in response metadata
                if ($entitlementCount -le 1 -and $null -ne $entResult.TotalCount) {
                    $entitlementCount = [int]$entResult.TotalCount
                }
            }
        }
        catch {
            Write-SPLog -Message "Test-SPSourceOnboardingReadiness: error querying entitlements: $_" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
                -CorrelationID $CorrelationID
        }

        if ($entitlementCount -gt 0) {
            & $addCheck 'EntitlementsAggregated' 'Pass' "$entitlementCount entitlements found" ''
        }
        elseif ($hasEntitlementSchema) {
            & $addCheck 'EntitlementsAggregated' 'Fail' 'Entitlement schema exists but no entitlements aggregated' `
                'Run an entitlement aggregation: ISC Admin > Sources > [source] > Aggregate Entitlements. Verify the entitlement schema maps to the correct object type (e.g., group, memberOf).'
        }
        else {
            & $addCheck 'EntitlementsAggregated' 'Warn' 'No entitlements found and no entitlement schema configured' `
                'If this source has group-based entitlements, configure an entitlement schema (group type) and run entitlement aggregation. Some sources (flat file, HR) may not have entitlements -- this is acceptable.'
        }

        # ------------------------------------------------------------------
        # Check 7: Campaign readiness (composite)
        # ------------------------------------------------------------------
        $passCount = 0
        $failCount = 0
        $warnCount = 0
        foreach ($chk in $checks) {
            switch ($chk['Status']) {
                'Pass' { $passCount++ }
                'Fail' { $failCount++ }
                'Warn' { $warnCount++ }
            }
        }

        # Campaign requires: source exists, accounts present, correlation set
        $campaignBlockers = [System.Collections.Generic.List[string]]::new()
        foreach ($chk in $checks) {
            if ($chk['Status'] -eq 'Fail' -and $chk['Check'] -in @('SourceExists', 'AccountsAggregated', 'CorrelationRules', 'OwnerAssigned')) {
                $campaignBlockers.Add($chk['Check'])
            }
        }

        if ($campaignBlockers.Count -eq 0) {
            & $addCheck 'CampaignReadiness' 'Pass' 'Source meets minimum requirements for certification campaign creation' ''
            $passCount++
        }
        else {
            & $addCheck 'CampaignReadiness' 'Fail' "Blocked by: $($campaignBlockers -join ', ')" `
                'Resolve the failed checks above before creating a certification campaign for this source.'
            $failCount++
        }

        $readyForGovernance = ($failCount -eq 0)

        Write-SPLog -Message "Test-SPSourceOnboardingReadiness: source='$sourceName' ($SourceId) -- Pass=$passCount, Fail=$failCount, Warn=$warnCount, Ready=$readyForGovernance" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Test-SPSourceOnboardingReadiness' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                SourceId   = $SourceId
                SourceName = $sourceName
                Checks     = @($checks)
                Summary    = @{
                    TotalChecks        = $checks.Count
                    Passed             = $passCount
                    Failed             = $failCount
                    Warnings           = $warnCount
                    ReadyForGovernance = $readyForGovernance
                }
            }
            Error   = $null
        }
    }
    catch {
        $errMsg = "Test-SPSourceOnboardingReadiness failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditQueries' `
            -Action 'Test-SPSourceOnboardingReadiness' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#endregion

#region Campaign Item Cache (P18-01)
# ---------------------------------------------------------------------------
# Session-scoped in-memory cache.  Survives multiple calls within one PS session;
# cleared on module reload.  Backed by the disk cache for cross-session reuse.
# ---------------------------------------------------------------------------
$script:_ItemMemCache = @{}   # key: "campaignId|cachePath" -> @{Items; CachedAt; Status}

function ConvertTo-SPCertRosterEntry {
    # ---------------------------------------------------------------------------
    # Internal (non-exported) helper. Maps a single ISC certification object to a
    # flat roster entry capturing its ASSIGNED reviewer. Mirrors the reviewer
    # classification used by Get-SPAuditCertifications (see lines ~745-757): when a
    # reassignment is present the cert is 'Reassigned' and the effective reviewer is
    # reassignment.to; otherwise 'Primary' and the effective reviewer is reviewer.
    # Null-safe via PSObject.Properties[...] so it works on PS 5.1 PSCustomObjects.
    # WI-2: this entry is what gets SEALED at ACTIVE state so the COMPLETED reporting
    # path (WI-3) can attribute undecided items to the cert-assigned reviewer instead
    # of item.reviewedBy (null for pending items -> everything collapses to Unassigned).
    # ---------------------------------------------------------------------------
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Cert
    )
    process {
        if ($null -eq $Cert) { return }

        $certId   = if ($null -ne $Cert.PSObject.Properties['id']) { [string]$Cert.id } else { '' }
        $certName = if ($null -ne $Cert.PSObject.Properties['name'] -and
                        -not [string]::IsNullOrWhiteSpace([string]$Cert.name)) { [string]$Cert.name } else { $certId }

        # Classification + effective reviewer (mirror Get-SPAuditCertifications).
        $classification    = 'Primary'
        $effectiveReviewer = if ($null -ne $Cert.PSObject.Properties['reviewer']) { $Cert.reviewer } else { $null }
        $reassignFromName  = $null
        $reassignFromId    = $null

        if ($null -ne $Cert.PSObject.Properties['reassignment'] -and $null -ne $Cert.reassignment) {
            $classification = 'Reassigned'
            $reassign = $Cert.reassignment
            if ($null -ne $reassign.PSObject.Properties['to'] -and $null -ne $reassign.to) {
                $effectiveReviewer = $reassign.to
            }
            if ($null -ne $reassign.PSObject.Properties['from'] -and $null -ne $reassign.from) {
                $from = $reassign.from
                if ($null -ne $from.PSObject.Properties['name']) { $reassignFromName = [string]$from.name }
                if ($null -ne $from.PSObject.Properties['id'])   { $reassignFromId   = [string]$from.id }
            }
        }

        $revName  = $null
        $revId    = $null
        $revEmail = $null
        if ($null -ne $effectiveReviewer) {
            if ($null -ne $effectiveReviewer.PSObject.Properties['name'])  { $revName  = [string]$effectiveReviewer.name }
            if ($null -ne $effectiveReviewer.PSObject.Properties['id'])    { $revId    = [string]$effectiveReviewer.id }
            if ($null -ne $effectiveReviewer.PSObject.Properties['email']) { $revEmail = [string]$effectiveReviewer.email }
        }

        # Sign-off provenance (COMP-REVIEWER-COMPLETENESS). Capture who actually signed the
        # cert so the COMPLETED render can tell a manual sign-off apart from a force-close
        # (signedBy.id != reviewer.id). Null-safe via PSObject.Properties (mirrors the
        # $effectiveReviewer pattern above). Absent on sealed/ACTIVE-captured certs -> ''
        # (conservative): an empty SignedById is treated downstream as indeterminate, never
        # as positive evidence of a force-close.
        $signedById   = ''
        $signedByName = ''
        if ($null -ne $Cert.PSObject.Properties['signedBy'] -and $null -ne $Cert.signedBy) {
            $signedBy = $Cert.signedBy
            if ($null -ne $signedBy.PSObject.Properties['id'])   { $signedById   = [string]$signedBy.id }
            if ($null -ne $signedBy.PSObject.Properties['name']) { $signedByName = [string]$signedBy.name }
        }

        [PSCustomObject]@{
            CertificationId    = $certId
            CertificationName  = $certName
            ReviewerName       = $revName
            ReviewerId         = $revId
            ReviewerEmail      = $revEmail
            Classification     = $classification
            ReassignedFromName = $reassignFromName
            ReassignedFromId   = $reassignFromId
            SignedById         = $signedById
            SignedByName       = $signedByName
        }
    }
}

function Get-SPCachedCampaignItems {
    <#
    .SYNOPSIS
        Fetches all certification review items for a campaign with two-layer caching.
    .DESCRIPTION
        Addresses the "20-minute full run" problem when the same campaign data is needed
        by multiple reports. On first call the items are fetched from ISC (slow) and
        written to a disk cache file. Every subsequent call -- in the same session or a
        future one -- reads from disk (sub-second) without touching ISC.

        Two-layer architecture:
          Layer 1 -- Memory cache ($script:_ItemMemCache): instant, session-scoped.
          Layer 2 -- Disk cache (Audit\.cache\items-{id}.jsonl): fast, cross-session.

        TTL rules:
          COMPLETED / COMPLETING  -> permanent on disk (sealed data never changes).
          ACTIVE / ACTIVATING     -> configurable TTL (default 180 min / 3h;
                                     respects reviewers acting during the day).
          STAGED / ERROR          -> never cached.

        Returned items are pre-wrapped in @{Item; CertificationId; CertificationName;
        CampaignName} hashtables ready for Group-SPAuditDecisions -- no further
        transformation needed by the caller.

    .PARAMETER Campaign
        Campaign object from Get-SPAuditCampaigns. Must have: id, name, status.
    .PARAMETER CachePath
        Directory for cache files. Defaults to Audit.CachePath from config,
        falling back to '{OutputPath}\.cache'.
    .PARAMETER TtlMinutes
        Cache TTL (minutes) for non-COMPLETED (ACTIVE) campaigns. When omitted (-1) the
        value is read from config (Audit.CacheActiveTtlMinutes, default 180 = 3h).
        Set to 0 to always refresh ACTIVE campaign data. COMPLETED campaigns ignore this.
    .PARAMETER NoCache
        When set, bypasses disk and memory cache and fetches fresh from ISC.
        Useful when you know the campaign just completed or data has changed.
    .PARAMETER Certifications
        Optional pre-fetched certification list for the campaign. When supplied (on a
        cache MISS), it is used instead of an internal Get-SPAuditCertifications call --
        avoiding a redundant fetch for callers that already have the certs in hand and
        guaranteeing the cached cert set matches the caller's. MUST be the FULL cert set
        for the campaign; a filtered subset would be cached as if complete.
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{
            Success   = $bool
            Data      = @(wrapped items for Group-SPAuditDecisions)
            CertCount = [int]
            ItemCount = [int]
            FromCache = $bool   # $true = served from disk/memory
            CacheFile = [string]
            Error     = $string
        }
    .EXAMPLE
        # First call: ~3-5 min (fetches from ISC, writes cache)
        # Subsequent calls: <1 sec (reads from cache)
        $result = Get-SPCachedCampaignItems -Campaign $campaign
        $decisions = Group-SPAuditDecisions -Items $result.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Campaign,

        [Parameter()]
        [string]$CachePath,

        [Parameter()]
        [int]$TtlMinutes = -1,

        [Parameter()]
        [switch]$NoCache,

        [Parameter()]
        [switch]$RefreshCache,

        [Parameter()]
        [object[]]$Certifications,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $campId   = [string]$Campaign.id
    $campName = if ($null -ne $Campaign.PSObject.Properties['name'] -and
                    -not [string]::IsNullOrWhiteSpace($Campaign.name)) { [string]$Campaign.name } else { $campId }
    $status   = if ($null -ne $Campaign.PSObject.Properties['status'] -and
                    $null -ne $Campaign.status) { [string]$Campaign.status } else { '' }
    $isPermanent = $status.ToUpperInvariant() -in @('COMPLETED', 'COMPLETING')
    $isCacheable = $status.ToUpperInvariant() -notin @('STAGED', 'ERROR')

    # ---------------------------------------------------------------------------
    # Resolve cache directory. An explicit -CachePath is honored as-is; otherwise use the
    # toolkit-root-anchored default so the cache is the same place regardless of the
    # caller's current directory.
    # ---------------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
        $effectiveCachePath = $CachePath
    }
    else {
        $effectiveCachePath = Get-SPAuditCacheDir
    }

    # Active-campaign TTL: explicit -TtlMinutes wins; otherwise read config
    # (Audit.CacheActiveTtlMinutes, default 180). COMPLETED campaigns ignore it entirely.
    # WI-8 (G5): Get-SPAuditEffectiveCacheTtl can shrink (never raise) the base TTL when
    # the opt-in near-deadline-capture feature is on and the deadline is near. With the
    # feature default-OFF it returns $baseTtl untouched, so the mem/disk TTL checks below
    # are byte-for-byte unchanged in default config -- additive.
    $baseTtl      = if ($TtlMinutes -ge 0) { $TtlMinutes } else { Get-SPAuditActiveCacheTtl }
    $effectiveTtl = Get-SPAuditEffectiveCacheTtl -Campaign $Campaign -BaseTtl $baseTtl

    $safeCampId   = $campId -replace '[^A-Za-z0-9_\-]', '_'
    $itemsFile    = Join-Path $effectiveCachePath "items-$safeCampId.jsonl"
    $metaFile     = Join-Path $effectiveCachePath "items-$safeCampId.meta.json"

    # Memory-cache key includes the resolved cache path: the disk layer is
    # per-directory, so a session mixing -CachePath values (e.g. a scratch cache
    # vs the default) must not serve one directory's items for the other.
    $memKey = "$campId|$($effectiveCachePath.ToLowerInvariant())"

    # ---------------------------------------------------------------------------
    # Layer 1: memory cache check
    # -RefreshCache skips BOTH read layers (its contract is "skip read but DO
    # write" -- without this, a valid cache hit returned early and a permanent
    # COMPLETED campaign could never be refreshed at all).
    # ---------------------------------------------------------------------------
    if (-not $NoCache -and -not $RefreshCache -and $script:_ItemMemCache.ContainsKey($memKey)) {
        $memEntry = $script:_ItemMemCache[$memKey]
        $memValid = $memEntry.IsPermanent -or
                    ((Get-Date) - $memEntry.CachedAt).TotalMinutes -lt $effectiveTtl
        if ($memValid) {
            Write-SPLog -Message "Cache HIT (memory): campaign '$campName' ($($memEntry.Items.Count) items)" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
            return @{
                Success   = $true
                Data      = @($memEntry.Items)
                CertCount = $memEntry.CertCount
                ItemCount = $memEntry.Items.Count
                FromCache = $true
                CacheFile = $itemsFile
                Error     = $null
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Layer 2: disk cache check (-RefreshCache skips reads here too; see layer 1)
    # ---------------------------------------------------------------------------
    if (-not $NoCache -and -not $RefreshCache -and $isCacheable -and (Test-Path $itemsFile) -and (Test-Path $metaFile)) {
        try {
            $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
            # Parse with RoundtripKind to handle both old 'Z'-suffixed and new 'o'-format timestamps correctly on PS 5.1
            $cachedAt  = [datetime]::Parse([string]$meta.CachedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $ageMinutes = [math]::Round(((Get-Date) - $cachedAt.ToLocalTime()).TotalMinutes, 1)
            $cachedStatusRaw = if ($null -ne $meta.PSObject.Properties['Status']) { [string]$meta.Status } else { '(none)' }
            Write-Verbose "  [Cache] Disk check: '$campName' | cached=$cachedStatusRaw current=$status | age=${ageMinutes}m ttl=${effectiveTtl}m | permanent=$($meta.IsPermanent)"

            # SEAL-ON-TRANSITION: if the cache was captured while ACTIVE but the campaign
            # is now COMPLETED, seal the cache as permanent. The ACTIVE-state data is the
            # honest truth -- re-fetching would get ISC's post-completion lies (auto-approved
            # items, inflated decisionsMade, force-signed reviewers).
            $cachedStatus = if ($null -ne $meta.PSObject.Properties['Status']) { [string]$meta.Status } else { '' }
            $isTransitioned = (-not $meta.IsPermanent) -and
                              ($cachedStatus.ToUpperInvariant() -in @('ACTIVE', 'ACTIVATING', '')) -and
                              $isPermanent  # current status is COMPLETED/COMPLETING
            if ($isTransitioned) {
                Write-Host "  [Cache] SEALED: '$campName' transitioned ACTIVE->COMPLETED. Preserving honest ACTIVE-state cache." -ForegroundColor Cyan
                Write-SPLog -Message "Cache SEALED: '$campName' was ACTIVE when cached, now $status. Marking permanent to preserve honest data." `
                    -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' -CorrelationID $CorrelationID
                # Update meta to mark as permanent so future runs never re-fetch
                try {
                    $meta | Add-Member -NotePropertyName 'IsPermanent' -NotePropertyValue $true -Force
                    $meta | Add-Member -NotePropertyName 'SealedAt' -NotePropertyValue (Get-Date).ToString('o') -Force
                    $meta | Add-Member -NotePropertyName 'SealReason' -NotePropertyValue "Campaign transitioned from $cachedStatus to $status" -Force
                    # WI-4 (G1): an ACTIVE->COMPLETED seal stays VERIFIED -- the honest
                    # ACTIVE-state snapshot existed before close. Preserve the original
                    # first-seen status (this path returns early below and never reaches
                    # the cache-miss meta2 block that would otherwise stamp these).
                    $sealFirstSeen = if ($null -ne $meta.PSObject.Properties['FirstSeenStatus'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.FirstSeenStatus)) { [string]$meta.FirstSeenStatus } else { $cachedStatus }
                    $meta | Add-Member -NotePropertyName 'FirstSeenStatus' -NotePropertyValue $sealFirstSeen -Force
                    $meta | Add-Member -NotePropertyName 'CapturedWhileActive' -NotePropertyValue $true -Force
                    $meta | Add-Member -NotePropertyName 'Unverified' -NotePropertyValue $false -Force
                    $meta | ConvertTo-Json | Set-Content $metaFile -Encoding UTF8
                } catch {
                    Write-Host "  [Cache] WARN: Failed to update meta for seal: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            $diskValid = $meta.IsPermanent -or $isTransitioned -or ($ageMinutes -lt $effectiveTtl)
            if ($diskValid) {
                Write-SPLog -Message "Cache HIT (disk): campaign '$campName' ($($meta.ItemCount) items, cached $($cachedAt.ToString('yyyy-MM-dd HH:mm')))" `
                    -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                    -CorrelationID $CorrelationID
                Write-Host "  [Cache] Loading $($meta.ItemCount) items from disk ($campName) [cached=$cachedStatusRaw age=${ageMinutes}m]..." -ForegroundColor DarkGray

                $items = [System.Collections.Generic.List[object]]::new()
                Get-Content $itemsFile | ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace($_)) {
                        $items.Add(($_ | ConvertFrom-Json))
                    }
                }

                $memEntry2 = @{
                    Items       = $items.ToArray()
                    CachedAt    = $cachedAt
                    CertCount   = $meta.CertCount
                    IsPermanent = $meta.IsPermanent
                }
                $script:_ItemMemCache[$memKey] = $memEntry2

                return @{
                    Success   = $true
                    Data      = @($items.ToArray())
                    CertCount = $meta.CertCount
                    ItemCount = $items.Count
                    FromCache = $true
                    CacheFile = $itemsFile
                    Error     = $null
                }
            }
        } catch {
            Write-SPLog -Message "Disk cache read failed for '$campName': $($_.Exception.Message) -- fetching fresh" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
        }
    }

    # ---------------------------------------------------------------------------
    # Cache miss: fetch from ISC
    # ---------------------------------------------------------------------------
    $missReason = if ($RefreshCache) { 'RefreshCache (will overwrite)' } elseif ($NoCache) { 'NoCache (cache preserved)' } elseif (-not $isCacheable) { "status=$status not cacheable" } elseif (-not (Test-Path $itemsFile)) { 'no cache file on disk' } elseif (-not (Test-Path $metaFile)) { 'no meta file on disk' } else { "TTL expired (age=${ageMinutes}m > ttl=${effectiveTtl}m)" }
    Write-Host "  [Cache] MISS: '$campName' -- $missReason. Fetching from ISC..." -ForegroundColor Yellow
    Write-Verbose "  [Cache] MISS detail: itemsFile=$(Test-Path $itemsFile) metaFile=$(Test-Path $metaFile) cacheable=$isCacheable noCache=$NoCache"
    Write-SPLog -Message "Cache MISS: fetching items from ISC for campaign '$campName' reason=$missReason" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
        -CorrelationID $CorrelationID
    # Use caller-supplied certs when provided; otherwise fetch them. This avoids a
    # redundant Get-SPAuditCertifications call for callers that already enumerated the
    # campaign's certs (e.g. for reviewer metrics) and keeps both cert sets identical.
    if ($PSBoundParameters.ContainsKey('Certifications') -and $null -ne $Certifications) {
        $certs = @($Certifications)
    }
    else {
        Write-Host "  Fetching certifications for '$campName'..." -ForegroundColor DarkGray
        $certsResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $CorrelationID
        if (-not $certsResult.Success) {
            return @{ Success=$false; Data=@(); CertCount=0; ItemCount=0; FromCache=$false; CacheFile=''; Error=$certsResult.Error }
        }
        $certs = @($certsResult.Data)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $allItems  = [System.Collections.Generic.List[object]]::new()

    # --- Resume from a partial fetch -----------------------------------------
    # A partial cache = the items .jsonl is present but the .meta.json is not (meta is
    # written only when a fetch completes). Reload its items and skip those certs so an
    # interrupted long pull resumes where it left off instead of restarting.
    $doneCertIds = @{}
    $resuming    = $false
    # Resume only applies to a DEFAULT fetch. -NoCache promises fully fresh data
    # (a leftover partial must not be silently blended in) and -RefreshCache
    # promises a full re-pull that replaces whatever is on disk.
    if (-not $NoCache -and -not $RefreshCache -and
        $isCacheable -and (Test-Path $itemsFile) -and -not (Test-Path $metaFile)) {
        try {
            Get-Content $itemsFile | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { return }
                $wi = $_ | ConvertFrom-Json
                $allItems.Add($wi)
                $cidKey = [string]$wi.CertificationId
                if (-not [string]::IsNullOrWhiteSpace($cidKey)) { $doneCertIds[$cidKey] = $true }
            }
            if ($allItems.Count -gt 0) {
                $resuming = $true
                Write-Host "  [Cache] Resuming partial fetch: $($allItems.Count) item(s) from $($doneCertIds.Count) cert(s) already on disk." -ForegroundColor DarkYellow
            }
        }
        catch {
            # Corrupt / truncated partial -- discard and start clean.
            $allItems.Clear(); $doneCertIds = @{}; $resuming = $false
        }
    }

    # Ensure the cache dir exists; drop a stale/unreadable partial so we append cleanly.
    # When -NoCache is set, do NOT touch existing cache files at all.
    # -NoCache: skip read AND write (preserve existing cache for comparison)
    # -RefreshCache: skip read but DO write (replace cache with fresh data)
    $writeToCache = $isCacheable -and (-not $NoCache -or $RefreshCache)
    # Sticky provenance captured from the outgoing meta BEFORE it is removed below;
    # the finalize blocks use these instead of re-reading the (now deleted) file.
    $priorMetaFirstSeen = $null; $priorMetaCapturedActive = $false; $priorMetaAvailable = $false
    if ($writeToCache) {
        try {
            if (-not (Test-Path $effectiveCachePath)) {
                New-Item -Path $effectiveCachePath -ItemType Directory -Force -WhatIf:$false | Out-Null
            }
            if (-not $resuming -and (Test-Path $itemsFile)) {
                [System.IO.File]::Delete($itemsFile)
            }
            # Remove the stale meta too when starting a fresh (non-resume) refetch.
            # Leaving it on disk paired a mid-fetch-killed PARTIAL items file with a
            # valid-looking meta: the next run's layer-2 check loaded the truncated
            # set -- and if the campaign had completed meanwhile, seal-on-transition
            # stamped the partial data permanent with no self-heal. Without the meta,
            # an interrupted fetch leaves the standard items-without-meta partial
            # signature, which the resume path already handles. Sticky provenance
            # (FirstSeenStatus / CapturedWhileActive) is captured first.
            if (-not $resuming -and (Test-Path $metaFile)) {
                try {
                    $pmSnap = Get-Content $metaFile -Raw | ConvertFrom-Json
                    if ($null -ne $pmSnap.PSObject.Properties['FirstSeenStatus'] -and -not [string]::IsNullOrWhiteSpace([string]$pmSnap.FirstSeenStatus)) { $priorMetaFirstSeen = [string]$pmSnap.FirstSeenStatus }
                    elseif ($null -ne $pmSnap.PSObject.Properties['Status'] -and -not [string]::IsNullOrWhiteSpace([string]$pmSnap.Status)) { $priorMetaFirstSeen = [string]$pmSnap.Status }
                    if ($null -ne $pmSnap.PSObject.Properties['CapturedWhileActive']) { $priorMetaCapturedActive = [bool]$pmSnap.CapturedWhileActive }
                    $priorMetaAvailable = $true
                } catch { }
                [System.IO.File]::Delete($metaFile)
            }
        } catch { }
    }

    $certIdx   = 0
    $certTotal = $certs.Count
    # M3: count cert-fetch failures so a transient all-certs-fail blip on a COMPLETED campaign
    # is not mistaken for a genuine 0-item result and sealed permanently empty (see G11 below).
    $certFetchFailures = 0

    foreach ($cert in $certs) {
        $certIdx++
        if ($certTotal -le 20 -or ($certIdx % 10 -eq 0)) {
            Write-Host "    Cert $certIdx / $certTotal..." -ForegroundColor DarkGray
        }
        $certId2   = [string]$cert.id
        $certName2 = if ($cert.PSObject.Properties['name'] -and $cert.name) { [string]$cert.name } else { $certId2 }

        if ($doneCertIds.ContainsKey($certId2)) { continue }   # already cached (resume)

        $itemsResult = Get-SPAuditCertificationItems -CertificationId $certId2 -CorrelationID $CorrelationID
        if ($itemsResult.Success) {
            $certLines = New-Object System.Text.StringBuilder
            foreach ($rawItem in @($itemsResult.Data)) {
                $wi = [PSCustomObject]@{
                    Item              = $rawItem
                    CertificationId   = $certId2
                    CertificationName = $certName2
                    CampaignName      = $campName
                }
                $allItems.Add($wi)
                if ($writeToCache) { [void]$certLines.AppendLine(($wi | ConvertTo-Json -Depth 12 -Compress)) }
            }
            # Flush this cert's items immediately so a kill mid-pull keeps everything
            # fetched up to the last completed certification.
            if ($writeToCache -and $certLines.Length -gt 0) {
                # G10: mutex-guarded append (concurrent GUI+scheduler fetch can no longer
                # interleave/corrupt the JSONL). UTF8.GetBytes preserves the no-BOM format.
                try { Add-SPItemCacheLines -Path $itemsFile -Content $certLines.ToString() }
                catch {
                    Write-SPLog -Message "Incremental cache append failed for '$campName' cert '$certId2': $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedItems' -CorrelationID $CorrelationID
                }
            }
        }
        else {
            # M3: a failed cert fetch (transient API error) is NOT a genuine empty cert.
            $certFetchFailures++
        }
    }

    Write-Host "  Fetched $($allItems.Count) item(s) from ISC for '$campName'" -ForegroundColor DarkGray

    # ---------------------------------------------------------------------------
    # WI-2: SEAL the cert -> assigned-reviewer roster alongside the items. This is
    # written to a SEPARATE sibling file (roster-$safeCampId.json) -- NOT embedded in
    # meta, whose ConvertTo-Json (default depth 2) would truncate nested entries.
    # Captured at whatever state the campaign is in right now; when that is ACTIVE the
    # seal is the honest source of truth the COMPLETED reporting path (WI-3) reads,
    # rather than re-fetching live post-completion certs (force-signed / reassigned).
    # Guarded only by ($writeToCache -and certs present) -- INDEPENDENT of the items
    # meta gate, because a cert with zero items still has an assigned reviewer that must
    # be sealed for accountability. CapturedWhileActive is the WI-4 provenance hook.
    # ---------------------------------------------------------------------------
    if ($writeToCache -and $certs.Count -gt 0) {
        $rosterFile = Join-Path $effectiveCachePath "roster-$safeCampId.json"
        try {
            if (-not (Test-Path $effectiveCachePath)) {
                New-Item -Path $effectiveCachePath -ItemType Directory -Force -WhatIf:$false | Out-Null
            }
            $rosterEntries = @($certs | ConvertTo-SPCertRosterEntry)
            $roster = [ordered]@{
                CampaignId          = $campId
                CampaignName        = $campName
                Status              = $status
                IsPermanent         = $isPermanent
                CapturedWhileActive = (-not $isPermanent)
                CapturedAt          = (Get-Date).ToString('o')
                CertCount           = $certs.Count
                Entries             = $rosterEntries
            }
            $roster | ConvertTo-Json -Depth 6 | Set-Content $rosterFile -Encoding UTF8
            Write-SPLog -Message "Sealed cert roster for '$campName': $($rosterEntries.Count) cert(s) -> $rosterFile (capturedWhileActive=$(-not $isPermanent))" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
        }
        catch {
            Write-SPLog -Message "Cert roster seal failed for '$campName': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
        }
    }

    # ---------------------------------------------------------------------------
    # Finalize cache: items were streamed to disk above; write meta to mark complete.
    # When -NoCache was specified, skip writing back so the existing cache is preserved
    # for comparison or rollback. The fresh data is only used for this run.
    # ---------------------------------------------------------------------------
    if ($NoCache -and -not $RefreshCache) {
        # Pure -NoCache: fresh data is used for this run only; disk cache untouched.
        # (-NoCache -RefreshCache falls through to the write branches below so the
        # meta sidecar is rewritten alongside the streamed items -- previously the
        # combo left the OLD meta paired with the NEW items file, and the stale
        # Status=ACTIVE meta made the seal-on-transition path stamp freshly fetched
        # post-completion data as CapturedWhileActive.)
        Write-Host "  [Cache] NoCache mode -- existing cache preserved (not overwritten)." -ForegroundColor DarkYellow
    }
    elseif ($writeToCache -and $allItems.Count -gt 0) {
        if ($RefreshCache) {
            Write-Host "  [Cache] RefreshCache mode -- fresh data overwrote existing cache." -ForegroundColor Cyan
        }
        try {
            # WI-4 (G1): stamp capture-provenance onto the items meta. The STICKY
            # first-seen status was captured from the outgoing meta BEFORE it was
            # removed at fetch start (B5: the stale meta can no longer sit next to a
            # partial items file); fall back to a disk read for paths that did not
            # delete it (e.g. resume). When a COMPLETED campaign is first cached here
            # WITHOUT a prior ACTIVE capture, the record is flagged Unverified so the
            # report can warn that ISC post-completion data is being trusted without
            # a sealed ACTIVE-state snapshot.
            $priorFirstSeen = $null; $priorCapturedActive = $false
            if ($priorMetaAvailable) {
                $priorFirstSeen      = $priorMetaFirstSeen
                $priorCapturedActive = $priorMetaCapturedActive
            }
            elseif (Test-Path $metaFile) {
                try {
                    $pm = Get-Content $metaFile -Raw | ConvertFrom-Json
                    if ($null -ne $pm.PSObject.Properties['FirstSeenStatus'] -and -not [string]::IsNullOrWhiteSpace([string]$pm.FirstSeenStatus)) { $priorFirstSeen = [string]$pm.FirstSeenStatus }
                    elseif ($null -ne $pm.PSObject.Properties['Status'] -and -not [string]::IsNullOrWhiteSpace([string]$pm.Status)) { $priorFirstSeen = [string]$pm.Status }
                    if ($null -ne $pm.PSObject.Properties['CapturedWhileActive']) { $priorCapturedActive = [bool]$pm.CapturedWhileActive }
                } catch { }
            }
            $firstSeenStatus = if ($null -ne $priorFirstSeen) { $priorFirstSeen } else { $status }
            $capturedWhileActive = $priorCapturedActive -or ($firstSeenStatus.ToUpperInvariant() -in @('ACTIVE', 'ACTIVATING', ''))   # mirror the active-set used at the seal-on-transition check
            $isUnverified = $isPermanent -and (-not $capturedWhileActive)

            $meta2 = [ordered]@{
                CampaignId   = $campId
                CampaignName = $campName
                Status       = $status
                IsPermanent  = $isPermanent
                CachedAt     = (Get-Date).ToString('o')
                CertCount    = $certs.Count
                ItemCount    = $allItems.Count
                FirstSeenStatus     = $firstSeenStatus
                CapturedWhileActive = $capturedWhileActive
                Unverified          = $isUnverified
            }
            $meta2 | ConvertTo-Json | Set-Content $metaFile -Encoding UTF8

            Write-SPLog -Message "Wrote cache for '$campName': $($allItems.Count) items -> $itemsFile (permanent=$isPermanent)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
            Write-Host "  [Cache] Saved $($allItems.Count) items to disk for future runs." -ForegroundColor DarkGreen
        }
        catch {
            Write-SPLog -Message "Cache finalize failed for '$campName': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
        }
    }
    elseif ($writeToCache -and $allItems.Count -eq 0 -and $isPermanent -and $certFetchFailures -eq 0) {
        # G11 (+M3 guard): a COMPLETED/COMPLETING campaign that GENUINELY has 0 items -- every
        # cert fetched OK and returned zero -- must still seal a permanent record. The
        # $certFetchFailures -eq 0 guard (M3) prevents a transient all-certs-fail blip from being
        # sealed permanently empty; that case falls through to the delete branch below and
        # self-heals (re-fetches) on the next run.
        # Previously the 0-item branch only deleted the empty partial,
        # so the layer-2 disk check (requires BOTH itemsFile AND metaFile) always missed and
        # the campaign was re-fetched every run. Write a sealed-empty items file + meta
        # (mirroring the $meta2 shape) so next run produces a permanent disk HIT and the
        # Get-Content loader yields zero items unchanged. ACTIVE 0-item keeps the old delete.
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            # Ensure an empty items file exists so the layer-2 (itemsFile AND metaFile) check HITs.
            [System.IO.File]::WriteAllText($itemsFile, '', $utf8NoBom)

            # Recover a STICKY first-seen status (same logic as the >0-item finalize
            # block): prefer the provenance captured before the meta was removed at
            # fetch start, falling back to a disk read.
            $priorFirstSeen = $null; $priorCapturedActive = $false
            if ($priorMetaAvailable) {
                $priorFirstSeen      = $priorMetaFirstSeen
                $priorCapturedActive = $priorMetaCapturedActive
            }
            elseif (Test-Path $metaFile) {
                try {
                    $pm = Get-Content $metaFile -Raw | ConvertFrom-Json
                    if ($null -ne $pm.PSObject.Properties['FirstSeenStatus'] -and -not [string]::IsNullOrWhiteSpace([string]$pm.FirstSeenStatus)) { $priorFirstSeen = [string]$pm.FirstSeenStatus }
                    elseif ($null -ne $pm.PSObject.Properties['Status'] -and -not [string]::IsNullOrWhiteSpace([string]$pm.Status)) { $priorFirstSeen = [string]$pm.Status }
                    if ($null -ne $pm.PSObject.Properties['CapturedWhileActive']) { $priorCapturedActive = [bool]$pm.CapturedWhileActive }
                } catch { }
            }
            $firstSeenStatus = if ($null -ne $priorFirstSeen) { $priorFirstSeen } else { $status }
            $capturedWhileActive = $priorCapturedActive -or ($firstSeenStatus.ToUpperInvariant() -in @('ACTIVE', 'ACTIVATING', ''))
            $isUnverified = $isPermanent -and (-not $capturedWhileActive)

            $meta2 = [ordered]@{
                CampaignId   = $campId
                CampaignName = $campName
                Status       = $status
                IsPermanent  = $isPermanent
                CachedAt     = (Get-Date).ToString('o')
                CertCount    = $certs.Count
                ItemCount    = 0
                FirstSeenStatus     = $firstSeenStatus
                CapturedWhileActive = $capturedWhileActive
                Unverified          = $isUnverified
            }
            $meta2 | ConvertTo-Json | Set-Content $metaFile -Encoding UTF8

            Write-SPLog -Message "Wrote sealed-empty cache for '$campName': 0 items -> $itemsFile (permanent=$isPermanent)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
            Write-Host "  [Cache] Sealed empty COMPLETED campaign ($campName) -- will not re-fetch." -ForegroundColor DarkGreen
        }
        catch {
            Write-SPLog -Message "Sealed-empty cache finalize failed for '$campName': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedItems' `
                -CorrelationID $CorrelationID
        }
    }
    elseif ($writeToCache -and $allItems.Count -eq 0 -and (Test-Path $itemsFile)) {
        # Nothing fetched (ACTIVE 0-item) -- remove the empty partial so it is not mistaken
        # for a resume. Unchanged ACTIVE behavior.
        try { [System.IO.File]::Delete($itemsFile) } catch { }
    }

    # Pure -NoCache promises the fresh data is "only used for this run" -- do not
    # store it in the session memory cache either, or the next default call would
    # serve this bypass fetch (marked permanent for COMPLETED campaigns) instead of
    # the preserved honest disk cache.
    if (-not ($NoCache -and -not $RefreshCache)) {
        $memEntry3 = @{
            Items       = $allItems.ToArray()
            CachedAt    = Get-Date
            CertCount   = $certs.Count
            IsPermanent = $isPermanent
        }
        $script:_ItemMemCache[$memKey] = $memEntry3
    }

    return @{
        Success   = $true
        Data      = @($allItems.ToArray())
        CertCount = $certs.Count
        ItemCount = $allItems.Count
        FromCache = $false
        CacheFile = if ($isCacheable) { $itemsFile } else { '' }
        Error     = $null
    }
}

function Get-SPCachedCampaignRoster {
    <#
    .SYNOPSIS
        Returns the cert -> assigned-reviewer roster for a campaign, preferring the
        SEALED ACTIVE-state roster written by Get-SPCachedCampaignItems (WI-2).
    .DESCRIPTION
        READ-ONLY. When a sealed roster file (roster-<campId>.json) exists on disk it is
        returned verbatim (Source='Sealed') -- this is the honest ACTIVE-state cert ->
        reviewer map the COMPLETED reporting path (WI-3) must use so undecided items are
        attributed to the ASSIGNED reviewer, not item.reviewedBy. When no seal exists the
        function FALLS BACK to live certs (caller-supplied -Certifications, else
        Get-SPAuditCertifications) and returns Source='Live'. The reader NEVER writes a
        roster file; sealing happens only on the Get-SPCachedCampaignItems cache-miss path.
    .PARAMETER Campaign
        The campaign object (must carry .id; .name/.status optional). Status does not
        affect which roster is returned -- a COMPLETED campaign still reads the sealed
        ACTIVE roster, which is the whole point of the seal.
    .PARAMETER CachePath
        Explicit cache directory; honored as-is. Defaults to Get-SPAuditCacheDir.
    .PARAMETER Certifications
        Caller-supplied full cert set used ONLY for the live fallback (no seal on disk).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{
            Success             = $bool
            Data                = @(roster entries; see ConvertTo-SPCertRosterEntry)
            Sealed              = $bool    # $true = served from the ACTIVE-state seal
            CapturedWhileActive = $bool
            Source              = 'Sealed' | 'Live'
            CacheFile           = [string]
            Error               = $string
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Campaign,

        [Parameter()]
        [string]$CachePath,

        [Parameter()]
        [object[]]$Certifications,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $campId   = [string]$Campaign.id
    $campName = if ($null -ne $Campaign.PSObject.Properties['name'] -and
                    -not [string]::IsNullOrWhiteSpace($Campaign.name)) { [string]$Campaign.name } else { $campId }

    # Resolve cache dir identically to Get-SPCachedCampaignItems.
    if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
        $effectiveCachePath = $CachePath
    }
    else {
        $effectiveCachePath = Get-SPAuditCacheDir
    }

    $safeCampId = $campId -replace '[^A-Za-z0-9_\-]', '_'
    $rosterFile = Join-Path $effectiveCachePath "roster-$safeCampId.json"

    # ---------------------------------------------------------------------------
    # Preferred path: read the SEALED roster captured at ACTIVE state.
    # ---------------------------------------------------------------------------
    if (Test-Path $rosterFile) {
        try {
            $r = Get-Content $rosterFile -Raw | ConvertFrom-Json
            $entries = if ($null -ne $r.PSObject.Properties['Entries']) { @($r.Entries) } else { @() }
            $capturedWhileActive = if ($null -ne $r.PSObject.Properties['CapturedWhileActive']) { [bool]$r.CapturedWhileActive } else { $false }
            Write-SPLog -Message "Roster HIT (sealed): '$campName' -> $($entries.Count) cert(s) from $rosterFile (capturedWhileActive=$capturedWhileActive)" `
                -Severity DEBUG -Component 'SP.AuditQueries' -Action 'GetCachedRoster' `
                -CorrelationID $CorrelationID
            return @{
                Success             = $true
                Data                = @($entries)
                Sealed              = $true
                CapturedWhileActive = $capturedWhileActive
                Source              = 'Sealed'
                CacheFile           = $rosterFile
                Error               = $null
            }
        }
        catch {
            Write-SPLog -Message "Sealed roster read failed for '$campName': $($_.Exception.Message) -- falling back to live certs" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedRoster' `
                -CorrelationID $CorrelationID
        }
    }

    # ---------------------------------------------------------------------------
    # Fallback (additive): no seal on disk -- build the roster from live certs.
    # ---------------------------------------------------------------------------
    if ($PSBoundParameters.ContainsKey('Certifications') -and $null -ne $Certifications) {
        $certs = @($Certifications)
    }
    else {
        $certsResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $CorrelationID
        if (-not $certsResult.Success) {
            Write-SPLog -Message "Roster live fallback failed for '$campName': $($certsResult.Error)" `
                -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedRoster' `
                -CorrelationID $CorrelationID
            return @{
                Success             = $false
                Data                = @()
                Sealed              = $false
                CapturedWhileActive = $false
                Source              = 'Live'
                CacheFile           = $rosterFile
                Error               = $certsResult.Error
            }
        }
        $certs = @($certsResult.Data)
    }

    $entries = @($certs | ConvertTo-SPCertRosterEntry)
    Write-SPLog -Message "Roster MISS (live): '$campName' -> $($entries.Count) cert(s) built from live certs (no seal on disk)" `
        -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedRoster' `
        -CorrelationID $CorrelationID
    return @{
        Success             = $true
        Data                = @($entries)
        Sealed              = $false
        CapturedWhileActive = $false
        Source              = 'Live'
        CacheFile           = $rosterFile
        Error               = $null
    }
}

function ConvertTo-SPSeriesChronoKey {
    <#
    .SYNOPSIS
        Resolve a series PeriodToken to a sortable [datetime] for chronological ordering.
    .DESCRIPTION
        PRIVATE helper for Get-SPCachedCampaignSeries. Deterministic, no IO. Tries, in
        order: a direct [datetime]::TryParse (covers ISO date '2026-06-30', ISO datetime,
        'Jun 2026'/'June 2026', numeric year-month '2026-06'); then PeriodType-specific
        parsing -- Quarterly extracts the quarter# + 4-digit year from any coworker variant
        ('1Q2026' / 'Q1 2026' / 'Q1-2026' / '2026 Q1') and maps to the first month of the
        quarter; a bare 4-digit year maps to Jan 1. A Weekly 'W23'/'Week 23' token is NOT
        date-resolvable on its own (no anchoring year) and signals failure. Returns $null
        on any failure so the caller can fall back to the meta CachedAt.
    .PARAMETER Token
        The extracted PeriodToken (may be empty).
    .PARAMETER PeriodType
        The derived PeriodType (Daily/Weekly/Monthly/Quarterly/Annual/Unknown).
    .OUTPUTS
        [datetime] or $null.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [string]$Token,
        [string]$PeriodType
    )

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $tok = ([string]$Token).Trim()

    # 1. Direct parse first (ISO date / datetime / month-year / numeric year-month).
    #    Skip for Quarterly/Weekly tokens which would mis-parse (e.g. 'Q1 2026' partials).
    #    InvariantCulture FIRST: this key orders series instances (which instance is the
    #    baseline / the newest), and campaign-name tokens like '6/7/2026' must sort the
    #    same on every host. A current-culture parse on a dd/MM machine swaps month/day,
    #    reorders the series, and the delta engine misclassifies the whole series.
    #    Host culture remains as a fallback for locale-formatted names invariant can't read.
    if ($PeriodType -ne 'Quarterly' -and $PeriodType -ne 'Weekly') {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($tok, [System.Globalization.CultureInfo]::InvariantCulture,
                                 [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
        if ([datetime]::TryParse($tok, [ref]$dt)) { return $dt }
    }

    # 2. Quarterly: pull quarter# + 4-digit year from any variant; map to first month.
    if ($PeriodType -eq 'Quarterly') {
        $qm = [regex]::Match($tok, '(?<q>[1-4])\s*Q', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $qm.Success) { $qm = [regex]::Match($tok, 'Q\s*(?<q>[1-4])', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        $ym = [regex]::Match($tok, '(?<y>\d{4})')
        if ($qm.Success -and $ym.Success) {
            $q = [int]$qm.Groups['q'].Value
            $y = [int]$ym.Groups['y'].Value
            try { return (New-Object System.DateTime($y, (($q - 1) * 3 + 1), 1)) } catch { return $null }
        }
        return $null
    }

    # 3. Weekly is not resolvable to a date without an anchoring year -- signal failure.
    if ($PeriodType -eq 'Weekly') { return $null }

    # 4. Bare 4-digit year (Annual or a year that fell through direct parse) -> Jan 1.
    $yOnly = [regex]::Match($tok, '^\s*(?<y>\d{4})\s*$')
    if ($yOnly.Success) {
        $y = [int]$yOnly.Groups['y'].Value
        try { return (New-Object System.DateTime($y, 1, 1)) } catch { return $null }
    }

    return $null
}

function Get-SPCachedCampaignSeries {
    <#
    .SYNOPSIS
        Reads the rich on-disk cache, derives recurring campaign SERIES, and orders each
        series' instances chronologically -- carrying capture provenance. READ-ONLY, NO API.
    .DESCRIPTION
        The cache-IO layer for the V4c series-attestation analysis. Enumerates every
        items-*.meta.json in the cache dir (BOM-safe via Get-Content -Raw | ConvertFrom-Json),
        derives the series grouping key for each via Get-SPCampaignSeriesKey (so human
        spacing/separator/case name variances collapse to one series by NormalizedStem),
        and within each series orders instances chronologically by the extracted PeriodToken
        date (falling back to meta CachedAt when the token is not date-resolvable).

        Each instance exposes the meta provenance (CampaignId, CampaignName, Status,
        CapturedWhileActive, Unverified, SealReason, IsPermanent, CachedAt, ItemCount,
        CertCount), the derived series fields (SeriesStem / NormalizedStem / PeriodToken /
        PeriodType), the resolved sibling file paths, and two NO-API loader scriptblocks:
          LoadItems  -> the wrapped items from items-<id>.jsonl (BOM-safe, line-delimited).
          LoadRoster -> the sealed roster Entries from roster-<id>.json (or @() if none).
        The loaders read the cache files DIRECTLY (never via Get-SPCachedCampaignItems /
        Get-SPCachedCampaignRoster, which can fall through to a live ISC fetch) so the whole
        path is guaranteed API-free.

        Series derivation honors the -SeriesStem / -SeriesPattern override guards (threaded
        to Get-SPCampaignSeriesKey exactly like Group-SPCampaignSeries) and a -MinInstances
        filter (default 2) so one-off campaigns are not reported as a "series".

        ADDITIVE: does not modify the sibling readers/writers; an absent/empty cache dir is
        SUCCESS with an empty Series array (never throws).
    .PARAMETER CachePath
        Explicit cache directory; honored as-is. Defaults to Get-SPAuditCacheDir.
    .PARAMETER SeriesStem
        OVERRIDE GUARD: explicit stem threaded to Get-SPCampaignSeriesKey for every instance.
    .PARAMETER SeriesPattern
        OVERRIDE GUARD: temporal-regex threaded to Get-SPCampaignSeriesKey for every instance.
    .PARAMETER MinInstances
        Minimum instance count for a stem to be reported as a series (default 2).
    .PARAMETER CorrelationID
        Unique ID for log tracing.
    .OUTPUTS
        [hashtable] @{
            Success = $bool
            Data    = [ordered]@{
                CacheDir      = [string]
                SeriesCount   = [int]
                InstanceCount = [int]   # sum across KEPT series only
                Series        = @( [ordered]@{ SeriesStem; NormalizedStem; PeriodType;
                                               InstanceCount; Instances = @(...) } )
            }
            Error   = $string
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CachePath,

        [Parameter()]
        [string]$SeriesStem,

        [Parameter()]
        [string]$SeriesPattern,

        [Parameter()]
        [int]$MinInstances = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # 1. Resolve cache dir identically to the sibling readers.
        if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
            $effectiveCachePath = $CachePath
        }
        else {
            $effectiveCachePath = Get-SPAuditCacheDir
        }

        if (-not (Test-Path $effectiveCachePath)) {
            return @{
                Success = $true
                Error   = $null
                Data    = [ordered]@{
                    CacheDir      = $effectiveCachePath
                    SeriesCount   = 0
                    InstanceCount = 0
                    Series        = @()
                }
            }
        }

        # 2/3/4/5/6. Enumerate every meta file and build a per-instance record.
        $instances = New-Object System.Collections.Generic.List[object]
        $metaFiles = @(Get-ChildItem -Path $effectiveCachePath -Filter 'items-*.meta.json' -File -ErrorAction SilentlyContinue)
        foreach ($f in $metaFiles) {
            $meta = $null
            try {
                # BOM-safe: PS 5.1 Get-Content strips the UTF-8 BOM (the proven disk-cache pattern).
                $meta = Get-Content $f.FullName -Raw | ConvertFrom-Json
            }
            catch {
                if (Get-Command Write-SPLog -ErrorAction Ignore) {
                    Write-SPLog -Message "Series reader: skipping corrupt meta '$($f.Name)': $($_.Exception.Message)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedSeries' -CorrelationID $CorrelationID
                }
                continue
            }
            if ($null -eq $meta) { continue }

            # Defensive meta-prop reads (PSCustomObjects from ConvertFrom-Json).
            $campId = if ($null -ne $meta.PSObject.Properties['CampaignId'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.CampaignId)) { [string]$meta.CampaignId } else { '' }
            $campName = if ($null -ne $meta.PSObject.Properties['CampaignName'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.CampaignName)) { [string]$meta.CampaignName } else { $campId }
            $status = if ($null -ne $meta.PSObject.Properties['Status'] -and $null -ne $meta.Status) { [string]$meta.Status } else { '' }
            $isPermanent = if ($null -ne $meta.PSObject.Properties['IsPermanent']) { [bool]$meta.IsPermanent } else { $false }
            $capturedWhileActive = if ($null -ne $meta.PSObject.Properties['CapturedWhileActive']) { [bool]$meta.CapturedWhileActive } else { $false }
            $unverified = if ($null -ne $meta.PSObject.Properties['Unverified']) { [bool]$meta.Unverified } else { $false }
            $sealReason = if ($null -ne $meta.PSObject.Properties['SealReason'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.SealReason)) { [string]$meta.SealReason } else { $null }
            $itemCount = if ($null -ne $meta.PSObject.Properties['ItemCount']) { [int]$meta.ItemCount } else { 0 }
            $certCount = if ($null -ne $meta.PSObject.Properties['CertCount']) { [int]$meta.CertCount } else { 0 }

            $cachedAt = [datetime]::MinValue
            if ($null -ne $meta.PSObject.Properties['CachedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$meta.CachedAt)) {
                try {
                    $cachedAt = [datetime]::Parse([string]$meta.CachedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                }
                catch { $cachedAt = [datetime]::MinValue }
            }

            # Skip metas with no usable campaign id (can't resolve siblings / series key).
            if ([string]::IsNullOrWhiteSpace($campId)) {
                if (Get-Command Write-SPLog -ErrorAction Ignore) {
                    Write-SPLog -Message "Series reader: skipping meta '$($f.Name)' with no CampaignId" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedSeries' -CorrelationID $CorrelationID
                }
                continue
            }

            # 4. Derive the series key, threading overrides exactly like Group-SPCampaignSeries.
            $keyArgs = @{ Name = $campName }
            if ($PSBoundParameters.ContainsKey('SeriesStem')) { $keyArgs['SeriesStem'] = $SeriesStem }
            if ($PSBoundParameters.ContainsKey('SeriesPattern')) { $keyArgs['SeriesPattern'] = $SeriesPattern }
            $kr = Get-SPCampaignSeriesKey @keyArgs
            if (-not $kr.Success) {
                if (Get-Command Write-SPLog -ErrorAction Ignore) {
                    Write-SPLog -Message "Series reader: series-key derivation failed for '$campName': $($kr.Error)" `
                        -Severity WARN -Component 'SP.AuditQueries' -Action 'GetCachedSeries' -CorrelationID $CorrelationID
                }
                continue
            }
            $seriesStemVal = [string]$kr.Data.SeriesStem
            $normalizedStem = [string]$kr.Data.NormalizedStem
            $periodToken = [string]$kr.Data.PeriodToken
            $periodType = [string]$kr.Data.PeriodType

            # 5. Resolve sibling cache files with the SAME safe-id transform as the readers.
            $safeCampId = $campId -replace '[^A-Za-z0-9_\-]', '_'
            $itemsFile = Join-Path $effectiveCachePath "items-$safeCampId.jsonl"
            $rosterFile = Join-Path $effectiveCachePath "roster-$safeCampId.json"

            # 7. Chronological key: PeriodToken date if resolvable, else meta CachedAt.
            $tokenDate = ConvertTo-SPSeriesChronoKey -Token $periodToken -PeriodType $periodType
            if ($null -ne $tokenDate) {
                $chronoKey = $tokenDate
                $chronoSource = 'PeriodToken'
            }
            else {
                $chronoKey = $cachedAt
                $chronoSource = 'CachedAt'
            }

            # 6. NO-API, BOM-safe loaders. Closures capture the resolved paths (PS 5.1:
            #    no $script: inside; .GetNewClosure() freezes $itemsFile / $rosterFile).
            $loadItems = {
                if (Test-Path $itemsFile) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    Get-Content $itemsFile | ForEach-Object {
                        if (-not [string]::IsNullOrWhiteSpace($_)) {
                            $list.Add(($_ | ConvertFrom-Json))
                        }
                    }
                    return , $list.ToArray()
                }
                return @()
            }.GetNewClosure()

            $loadRoster = {
                if (Test-Path $rosterFile) {
                    $r = Get-Content $rosterFile -Raw | ConvertFrom-Json
                    if ($null -ne $r -and $null -ne $r.PSObject.Properties['Entries']) {
                        return @($r.Entries)
                    }
                }
                return @()
            }.GetNewClosure()

            $instances.Add([pscustomobject]@{
                    CampaignId          = $campId
                    CampaignName        = $campName
                    Status              = $status
                    IsPermanent         = $isPermanent
                    CapturedWhileActive = $capturedWhileActive
                    Unverified          = $unverified
                    SealReason          = $sealReason
                    CachedAt            = $cachedAt
                    ItemCount           = $itemCount
                    CertCount           = $certCount
                    SeriesStem          = $seriesStemVal
                    NormalizedStem      = $normalizedStem
                    PeriodToken         = $periodToken
                    PeriodType          = $periodType
                    ChronoKey           = $chronoKey
                    ChronoSource        = $chronoSource
                    OrderIndex          = -1
                    Campaign            = [pscustomobject]@{ id = $campId; name = $campName; status = $status }
                    ItemsFile           = $itemsFile
                    RosterFile          = $rosterFile
                    MetaFile            = $f.FullName
                    LoadItems           = $loadItems
                    LoadRoster          = $loadRoster
                })
        }

        # 8. Group by NormalizedStem (regular @{} -> .ContainsKey is fine, not OrderedDictionary).
        $buckets = @{}
        foreach ($inst in $instances) {
            $ns = [string]$inst.NormalizedStem
            if (-not $buckets.ContainsKey($ns)) {
                $buckets[$ns] = New-Object System.Collections.Generic.List[object]
            }
            $buckets[$ns].Add($inst)
        }

        # 9/10. MinInstances filter + deterministic emission (series sorted by NormalizedStem;
        #       instances sorted ascending by a single composite ChronoKey|CampaignId string key).
        $series = New-Object System.Collections.Generic.List[object]
        $totalInstances = 0
        foreach ($ns in (@($buckets.Keys) | Sort-Object)) {
            # .ToArray() before @() -- @()-wrapping a bare List[object] throws
            # "Argument types do not match" on PS 5.1 (mirrors the Members.ToArray() pattern).
            $members = @($buckets[$ns].ToArray())
            if ($members.Count -lt $MinInstances) { continue }

            $sorted = @($members | Sort-Object -Property @{ Expression = {
                        '{0:o}|{1}' -f $_.ChronoKey, $_.CampaignId
                    } })
            for ($i = 0; $i -lt $sorted.Count; $i++) { $sorted[$i].OrderIndex = $i }

            $first = $sorted[0]
            $series.Add([ordered]@{
                    SeriesStem     = [string]$first.SeriesStem
                    NormalizedStem = $ns
                    PeriodType     = [string]$first.PeriodType
                    InstanceCount  = $sorted.Count
                    Instances      = @($sorted)
                })
            $totalInstances += $sorted.Count
        }

        if (Get-Command Write-SPLog -ErrorAction Ignore) {
            Write-SPLog -Message "Series reader: $($metaFiles.Count) meta(s) -> $($series.Count) series ($totalInstances instance(s) kept, MinInstances=$MinInstances)" `
                -Severity INFO -Component 'SP.AuditQueries' -Action 'GetCachedSeries' -CorrelationID $CorrelationID
        }

        return @{
            Success = $true
            Error   = $null
            Data    = [ordered]@{
                CacheDir      = $effectiveCachePath
                SeriesCount   = $series.Count
                InstanceCount = $totalInstances
                Series        = @($series.ToArray())
            }
        }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = "Get-SPCachedCampaignSeries failed: $($_.Exception.Message)" }
    }
}

function Clear-SPAuditItemCache {
    <#
    .SYNOPSIS
        Clears the campaign item cache (memory and/or disk).
    .PARAMETER CampaignId
        Clear cache for a specific campaign only. If omitted, clears all.
    .PARAMETER DiskOnly
        Clear disk cache only (keep session memory cache).
    .PARAMETER MemoryOnly
        Clear in-memory cache only (keep disk files).
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$CampaignId,
        [Parameter()] [switch]$DiskOnly,
        [Parameter()] [switch]$MemoryOnly
    )

    $clearedTargets = @()
    if (-not $DiskOnly) {
        if ([string]::IsNullOrWhiteSpace($CampaignId)) {
            $script:_ItemMemCache.Clear()
            $clearedTargets += 'memory'
            Write-Host "  Memory cache cleared." -ForegroundColor DarkGray
        }
        else {
            # Keys are "campaignId|cachePath" (plus any legacy bare-id entries) --
            # remove every entry for this campaign across all cache paths.
            $toRemove = @($script:_ItemMemCache.Keys | Where-Object {
                $_ -eq $CampaignId -or $_ -like "$CampaignId|*"
            })
            foreach ($k in $toRemove) { $script:_ItemMemCache.Remove($k) }
            if ($toRemove.Count -gt 0) {
                $clearedTargets += "memory($CampaignId)"
                Write-Host "  Memory cache cleared for $CampaignId." -ForegroundColor DarkGray
            }
        }
    }

    if (-not $MemoryOnly) {
        try {
            $cachePath = Get-SPAuditCacheDir
            if (Test-Path $cachePath) {
                # WI-2: roster siblings (roster-<campId>.json) are sealed next to the items
                # cache, so clearing must remove them too or a stale seal would outlive its items.
                if ([string]::IsNullOrWhiteSpace($CampaignId)) {
                    $patterns = @('items-*.jsonl', 'roster-*.json')
                } else {
                    $safId = $CampaignId -replace '[^A-Za-z0-9_\-]','_'
                    $patterns = @("items-$safId.*", "roster-$safId.json")
                }
                $files = @()
                foreach ($pattern in $patterns) {
                    $files += Get-ChildItem -Path $cachePath -Filter $pattern -ErrorAction SilentlyContinue
                }
                foreach ($f in $files) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
                $clearedTargets += "disk($($files.Count) files)"
                Write-Host "  Disk cache cleared ($($files.Count) file(s) removed)." -ForegroundColor DarkGray
            }
        } catch { }
    }
    if ($clearedTargets.Count -gt 0) {
        $targetDesc = $clearedTargets -join ' + '
        Write-SPLog -Message "Audit item cache cleared ($targetDesc)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Clear-SPAuditItemCache'
    }
}

function Clear-SPAuditAccountCache {
    <#
    .SYNOPSIS
        Clears the persistent identity->account resolution cache (memory and/or disk).
    .DESCRIPTION
        Forces the next account resolution to re-fetch from ISC. Use after identities have
        been renamed / re-mailed and you need fresh attributes before the TTL expires.
    .PARAMETER DiskOnly
        Clear the on-disk accounts.jsonl only (keep the session memory cache).
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
        $script:AccountCache.Clear()
        $script:_AccountCachedAt.Clear()
        $script:_AccountDiskLoaded = $false
        $clearedTargets += 'memory'
        Write-Host "  Account memory cache cleared." -ForegroundColor DarkGray
    }

    if (-not $MemoryOnly) {
        try {
            $acctFile = Join-Path (Get-SPAuditCacheDir) 'accounts.jsonl'
            if (Test-Path $acctFile) {
                Remove-Item $acctFile -Force -ErrorAction SilentlyContinue
                $clearedTargets += 'disk'
                Write-Host "  Account disk cache cleared." -ForegroundColor DarkGray
            }
        } catch { }
    }
    if ($clearedTargets.Count -gt 0) {
        $targetDesc = $clearedTargets -join ' + '
        Write-SPLog -Message "Audit account cache cleared ($targetDesc)" `
            -Severity INFO -Component 'SP.AuditQueries' -Action 'Clear-SPAuditAccountCache'
    }
}

#endregion Campaign Item Cache

Export-ModuleMember -Function @(
    'Get-SPAuditCampaigns',
    'Get-SPAuditCertifications',
    'Get-SPAuditCertificationItems',
    'Get-SPAuditCampaignReport',
    'Import-SPAuditCampaignReport',
    'Get-SPAuditIdentityEvents',
    'Resolve-SPAuditIdentityAccounts',
    'Get-SPReviewerWorkload',
    'Get-SPIdentityDecisionHistory',
    'Get-SPSourceCampaignCoverage',
    'Get-SPRemediationStatus',
    'Get-SPEntitlementInventory',
    'Get-SPStaleAccess',
    'Get-SPAccessProfileInventory',
    'Get-SPRoleInventory',
    'Save-SPConfigurationSnapshot',
    'Get-SPConfigurationSnapshot',
    'Get-SPOrphanAccounts',
    'Get-SPSourceAggregationHealth',
    'Measure-SPIdentityDataQuality',
    'Get-SPReviewerDelegations',
    'Test-SPSourceOnboardingReadiness',
    'Get-SPCachedCampaignItems',
    'Get-SPCachedCampaignRoster',
    'Get-SPCachedCampaignSeries',
    'Get-SPAuditEffectiveCacheTtl',
    'Clear-SPAuditItemCache',
    'Clear-SPAuditAccountCache'
)
