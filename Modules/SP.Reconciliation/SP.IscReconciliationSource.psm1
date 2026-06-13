<#
.SYNOPSIS
    SP.IscReconciliationSource -- ISC data acquisition + a NON-EXPIRING cache for the ISC
    reconciliation export (SP.IscReconciliation builds the model from this data).

.DESCRIPTION
    Fetches the two operands the reconciliation model needs, from ISC (read-only):
      * IDENTITIES via POST /v3/search/identities (paged) -> per-identity records carrying the
        configurable join key (default attribute employeeNumber), lifecycle/active, manager id.
      * GOVERNED ACCESS via GET /v3/entitlements (paged) using each entitlement's members[] list
        -- "who holds what" -- tagged with the entitlement's own privileged flag + source. (The
        mock / ISC expose no per-identity access endpoint; entitlement membership is the durable,
        complete source.)

    THE CACHE DOES NOT EXPIRE. Distinct from the toolkit's identity-detail cache
    (Audit.IdentityCacheTtlMinutes, 24h TTL, staleness-pruned on reload), this cache is a single
    durable JSON of the raw fetched operands with NO TTL and NO age check -- so a generated
    baseline survives indefinitely for repeated "generate -> change the source -> regenerate ->
    compare" testing. Refresh is explicit (the caller re-fetches), never automatic.

    Reuses Invoke-SPApiRequest / Get-SPAuthToken / Get-SPConfig as-is. Adds nothing to and changes
    nothing in the existing modules. Read-only.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Internal helpers

function Get-SPReconProp {
    # Dual-mode property read (hashtable/OrderedDictionary OR PSCustomObject). A private copy lives
    # here too: nested/flat modules do NOT share each other's private functions, so the source
    # module cannot rely on the identical helper inside SP.IscReconciliation.psm1.
    param([object]$Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { $v = $Obj[$Name]; if ($null -ne $v) { return $v } }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-SPIscSrcAttr {
    # Read identity-document attributes.<name> (PSCustomObject from JSON OR hashtable fixture).
    param([object]$Doc, [string]$Name, $Default = '')
    $attrs = Get-SPReconProp $Doc 'attributes' $null
    if ($null -eq $attrs) { return $Default }
    return [string](Get-SPReconProp $attrs $Name $Default)
}

function Test-SPIscActive {
    # ISC lifecycle -> active bool. Mirrors Get-SPDeltaIdentityDetail: terminated/inactive/leaver/
    # prehire are inactive; missing/unrecognised states are treated as active.
    param([string]$LifecycleState)
    if ([string]::IsNullOrWhiteSpace($LifecycleState)) { return $true }
    return ($LifecycleState.Trim().ToLowerInvariant() -notin @('terminated', 'inactive', 'leaver', 'prehire'))
}

function Get-SPIscReconCachePath {
    # Resolve the non-expiring cache file. Override dir via -CacheDir; else Audit.CachePath\
    # reconciliation; else {Audit.OutputPath}\.cache\reconciliation; else <root>\Audit\.cache\reconciliation.
    param([string]$CacheDir)
    $dir = $CacheDir
    if ([string]::IsNullOrWhiteSpace($dir)) {
        try {
            $cfg = Get-SPConfig
            if ($null -ne $cfg.PSObject.Properties['Audit']) {
                if ($null -ne $cfg.Audit.PSObject.Properties['CachePath'] -and -not [string]::IsNullOrWhiteSpace($cfg.Audit.CachePath)) {
                    $dir = Join-Path ([string]$cfg.Audit.CachePath) 'reconciliation'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                    $dir = Join-Path (Join-Path ([string]$cfg.Audit.OutputPath) '.cache') 'reconciliation'
                }
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\.cache\reconciliation' }
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir  = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
    }
    return (Join-Path $dir 'isc-recon-cache.json')
}

#endregion

#region Public: pure converters

function ConvertTo-SPIscIdentityRecord {
    <#
    .SYNOPSIS
        Maps a raw ISC identity document (search result) to the reconciliation identity record
        shape consumed by Build-SPIscReconciliationModel. PURE.
    .PARAMETER IdentityDoc
        One identity object from /v3/search/identities (PSCustomObject or hashtable).
    .PARAMETER JoinKeyAttribute
        The attributes.* field holding the SuccessFactors join key (default 'employeeNumber').
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$IdentityDoc,
        [Parameter()][string]$JoinKeyAttribute = 'employeeNumber'
    )
    $life = Get-SPIscSrcAttr $IdentityDoc 'cloudLifecycleState' ''
    $email = Get-SPIscSrcAttr $IdentityDoc 'email' ''
    if ([string]::IsNullOrWhiteSpace($email)) { $email = [string](Get-SPReconProp $IdentityDoc 'email' '') }
    $upn = Get-SPIscSrcAttr $IdentityDoc 'userPrincipalName' ''
    if ([string]::IsNullOrWhiteSpace($upn)) { $upn = Get-SPIscSrcAttr $IdentityDoc 'upn' '' }
    $disp = [string](Get-SPReconProp $IdentityDoc 'displayName' '')
    if ([string]::IsNullOrWhiteSpace($disp)) { $disp = [string](Get-SPReconProp $IdentityDoc 'name' '') }

    $mgrId = ''
    $mgr = Get-SPReconProp $IdentityDoc 'manager' $null
    if ($null -ne $mgr) { $mgrId = [string](Get-SPReconProp $mgr 'id' '') }

    return [ordered]@{
        IscIdentityId        = [string](Get-SPReconProp $IdentityDoc 'id' '')
        EmployeeId           = Get-SPIscSrcAttr $IdentityDoc $JoinKeyAttribute ''
        DisplayName          = $disp
        Email                = $email
        Upn                  = $upn
        LifecycleState       = $life
        Active               = (Test-SPIscActive -LifecycleState $life)
        ManagerIscIdentityId = $mgrId
    }
}

function Expand-SPIscEntitlementMembers {
    <#
    .SYNOPSIS
        Expands one ISC entitlement (with a members[] list of identity ids) into per-member
        governed-access grant records. PURE.
    .PARAMETER Entitlement
        One entitlement object from /v3/entitlements (PSCustomObject or hashtable) carrying
        name, type, sourceName/source.name, privileged, members[].
    .OUTPUTS
        [object[]] zero or more grant records @{ IscIdentityId; Name; Source; Type; Privileged }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entitlement)

    $name = [string](Get-SPReconProp $Entitlement 'name' '')
    $type = [string](Get-SPReconProp $Entitlement 'type' 'ENTITLEMENT')
    $src  = [string](Get-SPReconProp $Entitlement 'sourceName' '')
    if ([string]::IsNullOrWhiteSpace($src)) {
        $srcObj = Get-SPReconProp $Entitlement 'source' $null
        if ($null -ne $srcObj) { $src = [string](Get-SPReconProp $srcObj 'name' '') }
    }
    if ([string]::IsNullOrWhiteSpace($src)) { $src = [string](Get-SPReconProp $Entitlement 'sourceId' '') }

    $priv = $false
    $pv = Get-SPReconProp $Entitlement 'privileged' $null
    if ($null -eq $pv) {
        $attrs = Get-SPReconProp $Entitlement 'attributes' $null
        if ($null -ne $attrs) { $pv = Get-SPReconProp $attrs 'privileged' $null }
    }
    if ($null -ne $pv) { try { $priv = [bool]$pv } catch { $priv = $false } }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @(Get-SPReconProp $Entitlement 'members' @())) {
        $mid = [string]$m
        if ([string]::IsNullOrWhiteSpace($mid)) { continue }
        $out.Add([ordered]@{ IscIdentityId = $mid; Name = $name; Source = $src; Type = $type; Privileged = $priv })
    }
    return $out.ToArray()
}

#endregion

#region Public: fetch (IO)

function Get-SPIscReconciliationData {
    <#
    .SYNOPSIS
        Fetches ISC identities + governed-access grants for the reconciliation export (read-only).
    .DESCRIPTION
        Identities: POST /v3/search/identities, paged with a seen-id guard that stops on a short
        page OR a page that adds no new ids (robust against mocks/APIs that ignore offset).
        Governed access: GET /v3/entitlements, paged the same way, expanded via members[].
        No silent caps -- the per-collection counts are returned and logged.
    .PARAMETER JoinKeyAttribute
        attributes.* field holding the join key (default 'employeeNumber').
    .PARAMETER PageSize
        Page size for both collections (default 250).
    .PARAMETER CorrelationID
        Trace id threaded into Invoke-SPApiRequest / Write-SPLog.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Identities; AccessGrants; FetchedAtUtc; SourceCounts }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$JoinKeyAttribute = 'employeeNumber',
        [Parameter()][int]$PageSize = 250,
        [Parameter()][string]$CorrelationID
    )
    if ([string]::IsNullOrWhiteSpace($CorrelationID)) { $CorrelationID = [guid]::NewGuid().ToString() }
    try {
        # --- Identities (POST search, defensive paging) ---
        $idDocs = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        $off = 0
        while ($true) {
            $r = Invoke-SPApiRequest -Method POST -Endpoint '/search/identities' `
                -Body @{ query = @{ query = '*' }; limit = $PageSize; offset = $off } -CorrelationID $CorrelationID
            if (-not $r.Success) { return @{ Success = $false; Data = $null; Error = "identity search failed: $($r.Error)" } }
            $page = @($r.Data)
            if ($page.Count -eq 0) { break }
            $new = 0
            foreach ($d in $page) {
                $iid = [string](Get-SPReconProp $d 'id' '')
                if ([string]::IsNullOrWhiteSpace($iid) -or $seen.ContainsKey($iid)) { continue }
                $seen[$iid] = $true; $idDocs.Add($d); $new++
            }
            if ($new -eq 0 -or $page.Count -lt $PageSize) { break }
            $off += $page.Count
        }

        # --- Entitlements (GET, defensive paging) -> governed-access grants via members[] ---
        $grants = [System.Collections.Generic.List[object]]::new()
        $entSeen = @{}
        $entCount = 0
        $off = 0
        while ($true) {
            $r = Invoke-SPApiRequest -Method GET -Endpoint '/entitlements' `
                -QueryParams @{ limit = $PageSize; offset = $off } -CorrelationID $CorrelationID
            if (-not $r.Success) { return @{ Success = $false; Data = $null; Error = "entitlement fetch failed: $($r.Error)" } }
            $page = @($r.Data)
            if ($page.Count -eq 0) { break }
            $new = 0
            foreach ($e in $page) {
                $eid = [string](Get-SPReconProp $e 'id' '')
                if ([string]::IsNullOrWhiteSpace($eid) -or $entSeen.ContainsKey($eid)) { continue }
                $entSeen[$eid] = $true; $entCount++; $new++
                foreach ($g in (Expand-SPIscEntitlementMembers -Entitlement $e)) { $grants.Add($g) }
            }
            if ($new -eq 0 -or $page.Count -lt $PageSize) { break }
            $off += $page.Count
        }

        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $idDocs) { $records.Add((ConvertTo-SPIscIdentityRecord -IdentityDoc $d -JoinKeyAttribute $JoinKeyAttribute)) }

        $fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        try {
            Write-SPLog -Message "Recon fetch: identities=$($records.Count) entitlements=$entCount grants=$($grants.Count)" `
                -Severity INFO -Component 'SP.IscReconciliationSource' -Action 'Get-SPIscReconciliationData' -CorrelationID $CorrelationID
        } catch { }

        return @{
            Success = $true
            Data = @{
                Identities   = $records.ToArray()
                AccessGrants = $grants.ToArray()
                FetchedAtUtc = $fetchedAt
                SourceCounts = [ordered]@{ Identities = $records.Count; Entitlements = $entCount; Grants = $grants.Count }
            }
            Error = $null
        }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPIscReconciliationData failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: non-expiring cache (IO)

function Save-SPIscReconCache {
    <#
    .SYNOPSIS
        Writes the raw fetched operands to the NON-EXPIRING reconciliation cache (UTF-8 no-BOM).
    .PARAMETER Data
        The Data object from Get-SPIscReconciliationData (Identities, AccessGrants, FetchedAtUtc).
    .PARAMETER CacheDir
        Override the cache directory (default: config-resolved).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Data,
        [Parameter()][string]$CacheDir
    )
    try {
        $file = Get-SPIscReconCachePath -CacheDir $CacheDir
        $dir = Split-Path -Parent $file
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force -WhatIf:$false | Out-Null }
        $payload = [ordered]@{
            SchemaVersion = '1.0.0'
            FetchedAtUtc  = [string](Get-SPReconProp $Data 'FetchedAtUtc' '')
            Identities    = @(Get-SPReconProp $Data 'Identities' @())
            AccessGrants  = @(Get-SPReconProp $Data 'AccessGrants' @())
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Depth 20), $utf8NoBom)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Save-SPIscReconCache failed: $($_.Exception.Message)" } }
}

function Get-SPIscReconCache {
    <#
    .SYNOPSIS
        Loads the NON-EXPIRING reconciliation cache. There is deliberately NO TTL / age check:
        a baseline persists until the caller explicitly refreshes it.
    .PARAMETER CacheDir
        Override the cache directory (default: config-resolved).
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Identities; AccessGrants; FetchedAtUtc }; Path; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][string]$CacheDir)
    try {
        $file = Get-SPIscReconCachePath -CacheDir $CacheDir
        if (-not (Test-Path $file)) { return @{ Success = $false; Data = $null; Path = $file; Error = 'no cache' } }
        $obj = Get-Content $file -Raw | ConvertFrom-Json
        # ConvertFrom-Json in PS 5.1 auto-converts ISO 8601 strings to [datetime].
        # Re-serialise to the original round-trip format ('o') when that happens.
        $fetchedAt = $obj.FetchedAtUtc
        if ($fetchedAt -is [datetime]) {
            $fetchedAt = $fetchedAt.ToUniversalTime().ToString('o')
        } else {
            $fetchedAt = [string]$fetchedAt
        }
        return @{
            Success = $true
            Data = @{
                Identities   = @($obj.Identities)
                AccessGrants = @($obj.AccessGrants)
                FetchedAtUtc = $fetchedAt
            }
            Path = $file
            Error = $null
        }
    }
    catch { return @{ Success = $false; Data = $null; Path = $null; Error = "Get-SPIscReconCache failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'ConvertTo-SPIscIdentityRecord'
    'Expand-SPIscEntitlementMembers'
    'Get-SPIscReconciliationData'
    'Save-SPIscReconCache'
    'Get-SPIscReconCache'
)
