<#
.SYNOPSIS
    SP.IscReconciliation -- the ISC-side operand for the cross-project
    AD <-> ISC <-> HR reconciliation contract.

.DESCRIPTION
    The Group Enumerator (AD-facing) emits an AD reconciliation model whose per-identity
    `recon` block has the AD side filled and the ISC/HR side null. A future merge script
    joins that AD export with THIS ISC export (and an HR export) on `employeeID` to surface
    drift (MGR_MISMATCH, STATUS_MISMATCH, ACCESS_NOT_GOVERNED, ...). This module produces the
    ISC export: a complete, self-describing operand keyed the same way, so the merge fills the
    ISC side and never re-reads ISC.

    Source of truth for the interface:
      docs/AD-Reconciliation-Contract-from-GroupEnumerator.md

    Design mirrors the AD side's `Export-AdReconciliationModel` and this repo's
    SP.CampaignDelta snapshot pattern:
      * Build-SPIscReconciliationModel  -- PURE, deterministic. Hashtables/PSCustomObjects in,
        model hashtable out. No API, no IO, no Get-Date (timestamps are injected via -Provenance)
        so a byte-identical re-run produces a byte-identical model + contentHash.
      * Save-SPIscReconciliationExport   -- writes the model as UTF-8 NO-BOM JSON + a CSV twin +
        a SHA-256 sidecar (tamper-evidence), mirroring Save-SPCampaignSnapshot.

    The join-key ladder, finding-code vocabulary and provenance fields are kept identical to the
    AD side per the contract's coordination rules. The ISC export pre-stages ONLY the findings the
    ISC side can determine alone (JOINKEY_MISSING, MAIL_NE_UPN); every cross-source finding
    (MGR_MISMATCH, STATUS_MISMATCH, ACCESS_NOT_GOVERNED, STATUS_TERMINATED, ...) is computed at
    MERGE time from the matched operands and is intentionally NOT invented here.

    Read-only. Never reassigns / escalates / mutates ISC.

    Version: 1.0.0  (schemaVersion 1.0.0 -- semver; the merge pins the major)
#>

Set-StrictMode -Version 1

# Contract schema version. Semver; a breaking change requires a coordinated bump with the AD side.
$script:SPIscReconSchemaVersion = '1.0.0'

#region Internal helpers

function Get-SPReconProp {
    # Dual-mode property read: works for a hashtable/OrderedDictionary (fixtures, CLI-built) OR a
    # PSCustomObject (ConvertFrom-Json / API). Returns $Default when absent/null. Uses .Contains
    # (NOT .ContainsKey) so OrderedDictionary is safe under this repo's PS 5.1 rule.
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

function Resolve-SPIscJoinKey {
    # The shared join-key ladder (employeeID > mail > upn). Returns @{ Value; Source; Confidence }.
    # Only employeeID is high-confidence; a mail/upn fall-back is a Low-confidence join (itself a
    # signal the merge flags). Mirrors the AD side's joinKeyResolved{value,source,confidence}.
    param([string]$EmployeeId, [string]$Mail, [string]$Upn)
    if (-not [string]::IsNullOrWhiteSpace($EmployeeId)) { return @{ Value = $EmployeeId.Trim(); Source = 'employeeID'; Confidence = 'High' } }
    if (-not [string]::IsNullOrWhiteSpace($Mail))       { return @{ Value = $Mail.Trim();       Source = 'mail';       Confidence = 'Low' } }
    if (-not [string]::IsNullOrWhiteSpace($Upn))        { return @{ Value = $Upn.Trim();        Source = 'upn';        Confidence = 'Low' } }
    return @{ Value = ''; Source = 'none'; Confidence = 'None' }
}

function Get-SPIscReconDir {
    # Absolute export root: Audit.ReconciliationPath, else {Audit.OutputPath}\Reconciliation,
    # else <root>\Audit\Reconciliation. Mirrors Get-SPSnapshotDir's resolution shape.
    $dir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit']) {
            if ($null -ne $cfg.Audit.PSObject.Properties['ReconciliationPath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Audit.ReconciliationPath)) {
                $dir = [string]$cfg.Audit.ReconciliationPath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                $dir = Join-Path ([string]$cfg.Audit.OutputPath) 'Reconciliation'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\Reconciliation' }
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir  = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
    }
    return $dir
}

function Get-SPIscContentHash {
    # SHA-256 over the canonical JSON of the stable content (schemaVersion + identities + summary,
    # provenance EXCLUDED so the hash can be embedded into provenance without a chicken/egg cycle).
    # Compressed + invariant so re-runs of identical data hash identically (reproducibility triple).
    param([object]$Payload)
    $json = ($Payload | ConvertTo-Json -Depth 20 -Compress)
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

#endregion

#region Public: build (pure)

function Build-SPIscReconciliationModel {
    <#
    .SYNOPSIS
        Assembles the ISC reconciliation model (per-identity operand keyed by employeeID) from
        already-fetched ISC identity + governed-access data. PURE and deterministic.
    .DESCRIPTION
        Decoupled from the API: a caller fetches identities and their governed access (e.g. from a
        campaign audit decision set, or an identity/entitlement search) and passes them here. This
        function joins them, resolves each manager's employeeID (the cert reviewer routing target)
        via the identity population, applies the shared join-key ladder, pre-stages the ISC-side
        findings (JOINKEY_MISSING, MAIL_NE_UPN) and computes a summary + an embedded SHA-256
        contentHash. No Get-Date / no IO: timestamps come from -Provenance so the output is
        byte-stable for a given input (audit reproducibility).
    .PARAMETER Identities
        Array of identity records (hashtable or PSCustomObject). Recognised fields:
          IscIdentityId (req), EmployeeId, DisplayName, Email, Upn, LifecycleState,
          Active (bool), ManagerIscIdentityId.
    .PARAMETER AccessGrants
        Array of per-identity governed-access records. Recognised fields:
          IscIdentityId (req), Name, Source, Type, Privileged (bool).
    .PARAMETER Provenance
        Hashtable: SnapshotAsOfUtc, GeneratedAtUtc, ExtractMethod, ToolVersion, ConfigHash,
        TenantUrl, Environment. (snapshotAsOfUtc = as-of of the ISC data; generatedAtUtc = when this
        export was produced -- the contract requires these be distinct.)
    .PARAMETER JoinKeyAttribute
        The ISC attribute the EmployeeId field was sourced from (default 'employeeNumber'). Recorded
        in provenance for symmetry with the AD side's JoinKeyAttribute; the coverage KPI is computed
        from whether EmployeeId is populated, NOT from this name, so a custom attribute can never
        collapse coverage to 0%.
    .OUTPUTS
        [hashtable] the ISC reconciliation model.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Identities,
        [Parameter()][AllowEmptyCollection()][object[]]$AccessGrants = @(),
        [Parameter()][hashtable]$Provenance,
        [Parameter()][string]$JoinKeyAttribute = 'employeeNumber'
    )

    # --- Index identities by ISC id (for manager -> employeeID resolution) ---
    $byId = @{}
    foreach ($idn in @($Identities)) {
        if ($null -eq $idn) { continue }
        $iid = [string](Get-SPReconProp $idn 'IscIdentityId' '')
        if ([string]::IsNullOrWhiteSpace($iid)) { continue }
        if (-not $byId.ContainsKey($iid)) { $byId[$iid] = $idn }
    }

    # --- Bucket governed access by ISC id ---
    $grantsById = @{}
    $grantTotal = 0
    $privTotal  = 0
    foreach ($g in @($AccessGrants)) {
        if ($null -eq $g) { continue }
        $iid = [string](Get-SPReconProp $g 'IscIdentityId' '')
        if ([string]::IsNullOrWhiteSpace($iid)) { continue }
        if (-not $grantsById.ContainsKey($iid)) { $grantsById[$iid] = [System.Collections.Generic.List[object]]::new() }
        $name = [string](Get-SPReconProp $g 'Name' '')
        $src  = [string](Get-SPReconProp $g 'Source' '')
        $type = [string](Get-SPReconProp $g 'Type' '')
        $priv = $false
        try { $priv = [bool](Get-SPReconProp $g 'Privileged' $false) } catch { $priv = $false }
        $grantsById[$iid].Add([ordered]@{ Name = $name; Source = $src; Type = $type; Privileged = $priv })
        $grantTotal++
        if ($priv) { $privTotal++ }
    }

    # --- Per-identity records (sorted for determinism) ---
    $records = [System.Collections.Generic.List[object]]::new()
    $findingCounts = [ordered]@{ JOINKEY_MISSING = 0; MAIL_NE_UPN = 0 }
    $activeCount = 0
    $joinKeyResolvedCount = 0
    $lowConfidenceCount = 0
    $managerResolvedCount = 0

    foreach ($idn in @($Identities)) {
        if ($null -eq $idn) { continue }
        $iid = [string](Get-SPReconProp $idn 'IscIdentityId' '')
        if ([string]::IsNullOrWhiteSpace($iid)) { continue }

        $emp   = [string](Get-SPReconProp $idn 'EmployeeId' '')
        $mail  = [string](Get-SPReconProp $idn 'Email' '')
        $upn   = [string](Get-SPReconProp $idn 'Upn' '')
        $disp  = [string](Get-SPReconProp $idn 'DisplayName' '')
        $life  = [string](Get-SPReconProp $idn 'LifecycleState' '')
        $active = $false
        try { $active = [bool](Get-SPReconProp $idn 'Active' $false) } catch { $active = $false }
        if ($active) { $activeCount++ }

        $jk = Resolve-SPIscJoinKey -EmployeeId $emp -Mail $mail -Upn $upn
        if ($jk.Source -eq 'employeeID') { $joinKeyResolvedCount++ }
        if ($jk.Confidence -eq 'Low')    { $lowConfidenceCount++ }

        # --- Manager / reviewer resolution: the cert routing target's employeeID ---
        $mgrIid = [string](Get-SPReconProp $idn 'ManagerIscIdentityId' '')
        $mgrEmp = ''
        $mgrDisp = ''
        if ($mgrIid -and $byId.ContainsKey($mgrIid)) {
            $mgrNode = $byId[$mgrIid]
            $mgrEmp  = [string](Get-SPReconProp $mgrNode 'EmployeeId' '')
            $mgrDisp = [string](Get-SPReconProp $mgrNode 'DisplayName' '')
        }
        $mgrResolved = ($mgrIid -ne '' -and $byId.ContainsKey($mgrIid) -and -not [string]::IsNullOrWhiteSpace($mgrEmp))
        if ($mgrResolved) { $managerResolvedCount++ }

        # --- Governed entitlements (sorted: source then name) ---
        $ents = [System.Collections.Generic.List[object]]::new()
        $idPriv = $false
        if ($grantsById.ContainsKey($iid)) {
            $sorted = @($grantsById[$iid] | Sort-Object @{ Expression = { [string]$_.Source } }, @{ Expression = { [string]$_.Name } })
            foreach ($e in $sorted) { $ents.Add($e); if ([bool]$e.Privileged) { $idPriv = $true } }
        }

        # --- ISC-side pre-staged findings (only what the ISC side can determine alone) ---
        $findings = [System.Collections.Generic.List[object]]::new()
        if ([string]::IsNullOrWhiteSpace($emp)) {
            # A missing join key blocks the merge entirely; privileged access makes it material.
            $findings.Add([ordered]@{ Code = 'JOINKEY_MISSING'; Privileged = $idPriv; Detail = "no $JoinKeyAttribute on identity" })
            $findingCounts.JOINKEY_MISSING++
        }
        if ((-not [string]::IsNullOrWhiteSpace($mail)) -and (-not [string]::IsNullOrWhiteSpace($upn)) -and
            ($mail.Trim().ToLowerInvariant() -ne $upn.Trim().ToLowerInvariant())) {
            $findings.Add([ordered]@{ Code = 'MAIL_NE_UPN'; Privileged = $idPriv; Detail = "mail '$mail' != upn '$upn'" })
            $findingCounts.MAIL_NE_UPN++
        }

        $records.Add([ordered]@{
            EmployeeId      = $emp
            JoinKeyResolved = [ordered]@{ Value = [string]$jk.Value; Source = [string]$jk.Source; Confidence = [string]$jk.Confidence }
            IscIdentityId   = $iid
            DisplayName     = $disp
            Active          = $active
            LifecycleState  = $life
            Email           = $mail
            Upn             = $upn
            Manager         = [ordered]@{ IscIdentityId = $mgrIid; EmployeeId = $mgrEmp; DisplayName = $mgrDisp; Resolved = $mgrResolved }
            Privileged      = $idPriv
            GovernedEntitlements = $ents.ToArray()
            Findings        = $findings.ToArray()
        })
    }

    # Deterministic order: identities WITH an employeeID first (the boolean key sorts $false before
    # $true, so missing-key rows sort last), then by employeeID, then by ISC id as a stable tie-break.
    $ordered = @($records | Sort-Object `
        @{ Expression = { [string]::IsNullOrWhiteSpace($_.EmployeeId) } }, `
        @{ Expression = { [string]$_.EmployeeId } }, `
        @{ Expression = { [string]$_.IscIdentityId } })

    $idCount = $ordered.Count
    $coveragePct = if ($idCount -gt 0) { [math]::Round($joinKeyResolvedCount * 100.0 / $idCount, 1) } else { 0 }

    $summary = [ordered]@{
        IdentityCount           = $idCount
        ActiveCount             = $activeCount
        JoinKeyResolvedCount    = $joinKeyResolvedCount
        JoinKeyCoveragePct      = $coveragePct
        LowConfidenceJoinCount  = $lowConfidenceCount
        ManagerResolvedCount    = $managerResolvedCount
        GovernedEntitlementCount = $grantTotal
        PrivilegedGrantCount    = $privTotal
        FindingCounts           = $findingCounts
    }

    # Provenance (timestamps injected -> deterministic). contentHash filled after hashing.
    $prov = [ordered]@{
        SourceSystem   = 'SailPointISC'
        SnapshotAsOfUtc = if ($Provenance -and $Provenance.Contains('SnapshotAsOfUtc')) { [string]$Provenance['SnapshotAsOfUtc'] } else { '' }
        GeneratedAtUtc = if ($Provenance -and $Provenance.Contains('GeneratedAtUtc')) { [string]$Provenance['GeneratedAtUtc'] } else { '' }
        ExtractMethod  = if ($Provenance -and $Provenance.Contains('ExtractMethod'))  { [string]$Provenance['ExtractMethod'] }  else { '' }
        ToolVersion    = if ($Provenance -and $Provenance.Contains('ToolVersion'))    { [string]$Provenance['ToolVersion'] }    else { '' }
        JoinKeyAttribute = $JoinKeyAttribute
        TenantUrl      = if ($Provenance -and $Provenance.Contains('TenantUrl'))      { [string]$Provenance['TenantUrl'] }      else { '' }
        Environment    = if ($Provenance -and $Provenance.Contains('Environment'))    { [string]$Provenance['Environment'] }    else { '' }
        ConfigHash     = if ($Provenance -and $Provenance.Contains('ConfigHash'))     { [string]$Provenance['ConfigHash'] }     else { '' }
        RecordCount    = $idCount
        ContentHash    = ''
    }

    # Stable content for the hash (provenance excluded). Embed the digest into provenance.
    $content = [ordered]@{
        SchemaVersion = $script:SPIscReconSchemaVersion
        Identities    = $ordered
        Summary       = $summary
    }
    $prov.ContentHash = Get-SPIscContentHash -Payload $content

    return [ordered]@{
        SchemaVersion = $script:SPIscReconSchemaVersion
        Generated     = $prov
        Identities    = $ordered
        Summary       = $summary
    }
}

#endregion

#region Public: persist (IO)

function Save-SPIscReconciliationExport {
    <#
    .SYNOPSIS
        Writes the ISC reconciliation model as UTF-8 NO-BOM JSON + a CSV twin + a SHA-256 sidecar.
    .DESCRIPTION
        Mirrors Save-SPCampaignSnapshot: ConvertTo-Json via [System.IO.File]::WriteAllText with a
        BOM-less UTF8Encoding, then a `.sha256` tamper-evidence sidecar over the written bytes. The
        CSV twin is one row per identity (entitlements summarised as counts; the JSON carries the
        full nested list) and is also written BOM-less.
    .PARAMETER Model
        The object from Build-SPIscReconciliationModel.
    .PARAMETER OutputDir
        Override the export root (default: resolved from config, toolkit-root absolute).
    .PARAMETER StampOverride
        Optional explicit file stamp (yyyy-MM-ddTHHmmss). Default: derived from
        Generated.SnapshotAsOfUtc, else Generated.GeneratedAtUtc.
    .OUTPUTS
        [hashtable] @{ Success; Data=<jsonPath>; Csv=<csvPath>; Sha256; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Model,
        [Parameter()][string]$OutputDir,
        [Parameter()][string]$StampOverride
    )
    try {
        if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Get-SPIscReconDir }
        if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force -WhatIf:$false | Out-Null }

        # File stamp: prefer the data as-of time (stable across re-runs of the same snapshot).
        $stamp = $StampOverride
        if ([string]::IsNullOrWhiteSpace($stamp)) {
            $src = [string](Get-SPReconProp $Model.Generated 'SnapshotAsOfUtc' '')
            if ([string]::IsNullOrWhiteSpace($src)) { $src = [string](Get-SPReconProp $Model.Generated 'GeneratedAtUtc' '') }
            if (-not [string]::IsNullOrWhiteSpace($src)) {
                try { $stamp = ([datetime]::Parse($src, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().ToString('yyyy-MM-ddTHHmmss') } catch { }
            }
        }
        if ([string]::IsNullOrWhiteSpace($stamp)) { $stamp = 'isc-reconciliation' }

        $base = "isc-recon-$stamp"
        $jsonFile = Join-Path $OutputDir "$base.json"
        $csvFile  = Join-Path $OutputDir "$base.csv"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($jsonFile, ($Model | ConvertTo-Json -Depth 20), $utf8NoBom)

        # CSV twin: one row per identity (flat; entitlements -> counts; findings -> joined codes).
        $rows = foreach ($idn in @($Model.Identities)) {
            $codes = @(@($idn.Findings) | ForEach-Object { [string]$_.Code }) -join ';'
            [pscustomobject][ordered]@{
                EmployeeId          = [string]$idn.EmployeeId
                JoinKeySource       = [string]$idn.JoinKeyResolved.Source
                JoinConfidence      = [string]$idn.JoinKeyResolved.Confidence
                IscIdentityId       = [string]$idn.IscIdentityId
                DisplayName         = [string]$idn.DisplayName
                Active              = [bool]$idn.Active
                LifecycleState      = [string]$idn.LifecycleState
                ManagerEmployeeId   = [string]$idn.Manager.EmployeeId
                ManagerResolved     = [bool]$idn.Manager.Resolved
                Privileged          = [bool]$idn.Privileged
                GovernedEntitlementCount = @($idn.GovernedEntitlements).Count
                Findings            = $codes
            }
        }
        $csvText = if ($rows) { (@($rows) | ConvertTo-Csv -NoTypeInformation) -join "`r`n" } else { '"EmployeeId"' }
        [System.IO.File]::WriteAllText($csvFile, $csvText, $utf8NoBom)

        # Tamper-evidence sidecar over the JSON bytes (SOX/ITGC evidence integrity).
        $hash = $null
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($jsonFile)
                $hash  = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            } finally { $sha.Dispose() }
            [System.IO.File]::WriteAllText("$jsonFile.sha256", "$hash  $base.json", $utf8NoBom)
        } catch { }

        return @{ Success = $true; Data = $jsonFile; Csv = $csvFile; Error = $null; Sha256 = $hash }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Save-SPIscReconciliationExport failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'Build-SPIscReconciliationModel'
    'Save-SPIscReconciliationExport'
    'Resolve-SPIscJoinKey'
)
