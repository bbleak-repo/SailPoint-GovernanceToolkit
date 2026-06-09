<#
.SYNOPSIS
    SP.CampaignDelta -- dated, immutable campaign snapshots and the foundation for
    day-over-day (and weekly/monthly) diff + trend reporting.

.DESCRIPTION
    A campaign snapshot is the single source of truth from which every derived product is
    computed: completion-progress diffs (who attested), scope-change diffs (what access is
    new/gone, privileged-tagged), and KPI trends. Mirrors the proven SP.DisconnectedApp
    snapshot pattern (Save -> Get-Previous -> Compare), extended to datetime granularity so
    intra-day / daily / weekly / monthly all reduce to "which two snapshots".

    Snapshot file: {SnapshotPath}\{safeCampaignId}\{yyyy-MM-ddTHHmmss}.json
      Meta  -- campaign id/name/status, captured time, counts
      Certs -- per reviewer: decisionsMade/Total, completed, signed   (completion diff)
      Items -- per grant: identity, access, source, PRIVILEGED, decision, cert/reviewer (scope diff)
      Kpi   -- rolled-up counts (approve/revoke/pending, privileged, by-source, completion%) (trend)

    This module only CAPTURES and RETRIEVES snapshots. Comparison + reporting live in the
    diff layer; trend rollups in the metrics layer. Read-only; never reassigns/escalates.

    Version: 1.0.0
#>

#region Internal helpers

function Get-SPSnapshotDir {
    # Absolute snapshot root (Audit.SnapshotPath is toolkit-root-resolved by Get-SPConfig),
    # falling back to {Audit.OutputPath}\Snapshots, then <root>\Audit\Snapshots.
    $dir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit']) {
            if ($null -ne $cfg.Audit.PSObject.Properties['SnapshotPath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Audit.SnapshotPath)) {
                $dir = [string]$cfg.Audit.SnapshotPath
            }
            elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                $dir = Join-Path ([string]$cfg.Audit.OutputPath) 'Snapshots'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\Snapshots' }
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir  = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
    }
    return $dir
}

function Get-SPSnapshotRetentionDays {
    $days = 90
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit'] -and
            $null -ne $cfg.Audit.PSObject.Properties['SnapshotRetentionDays'] -and
            $null -ne $cfg.Audit.SnapshotRetentionDays) {
            $days = [int]$cfg.Audit.SnapshotRetentionDays
        }
    } catch { }
    return $days
}

function Get-SPPrivilegedPatterns {
    # From Audit.RiskIndicators.PrivilegedPatterns; sensible defaults if absent.
    $patterns = @('Admin', 'Root', 'DBA', 'Domain Admins', 'Enterprise Admins', 'Privileged')
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Audit'] -and
            $null -ne $cfg.Audit.PSObject.Properties['RiskIndicators'] -and
            $null -ne $cfg.Audit.RiskIndicators.PSObject.Properties['PrivilegedPatterns'] -and
            $null -ne $cfg.Audit.RiskIndicators.PrivilegedPatterns) {
            $cfgPats = @($cfg.Audit.RiskIndicators.PrivilegedPatterns)
            if ($cfgPats.Count -gt 0) { $patterns = $cfgPats }
        }
    } catch { }
    return $patterns
}

function Test-SPGrantPrivileged {
    # "Both": prefer an explicit privileged attribute on the decision/access object when
    # present, otherwise fall back to entitlement-name patterns.
    param([object]$Decision, [string[]]$Patterns)
    foreach ($p in @('Privileged', 'IsPrivileged')) {
        if ($null -ne $Decision.PSObject.Properties[$p] -and $null -ne $Decision.$p) {
            try { return [bool]$Decision.$p } catch { }
        }
    }
    $name = [string]$Decision.AccessName
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    foreach ($pat in $Patterns) {
        if (-not [string]::IsNullOrWhiteSpace($pat)) {
            try { if ($name -match $pat) { return $true } } catch { }
        }
    }
    return $false
}

#endregion

#region Public: build + persist

function Build-SPCampaignSnapshotData {
    <#
    .SYNOPSIS
        Assembles an immutable campaign snapshot object from already-fetched campaign data.
    .DESCRIPTION
        Decoupled from the API: callers fetch the campaign, certifications and grouped
        decisions, then pass them here. Produces Meta/Certs/Items/Kpi (see module help).
        Each item is tagged Privileged (attribute or name pattern) and carries its source.
    .PARAMETER Campaign
        Campaign object (id, name, status).
    .PARAMETER Certifications
        Array of certification objects (id, reviewer/certifier, decisionsTotal, decisionsMade,
        phase/signed) -- drives the completion view.
    .PARAMETER Decisions
        Group-SPAuditDecisions output: @{ Approved; Revoked; Pending } arrays of decision
        objects (CertificationId, IdentityId, IdentityName, AccessName, AccessType,
        SourceName, Decision, DecisionDate) -- drives the scope view.
    .OUTPUTS
        [hashtable] the snapshot object.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Campaign,
        [Parameter()][object[]]$Certifications = @(),
        [Parameter(Mandatory)][object]$Decisions
    )

    $patterns = Get-SPPrivilegedPatterns
    $capturedAt = (Get-Date)

    # --- Certs (completion) + a certId -> reviewer map for the items ---
    $certRecords = [System.Collections.Generic.List[object]]::new()
    $certReviewer = @{}
    foreach ($cert in @($Certifications)) {
        $certId = [string]$cert.id
        $revId = ''; $revName = ''
        foreach ($prop in @('certifier', 'reviewer')) {
            if ($null -ne $cert.PSObject.Properties[$prop] -and $null -ne $cert.$prop) {
                if ($null -ne $cert.$prop.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace($cert.$prop.id)) { $revId = [string]$cert.$prop.id }
                if ($null -ne $cert.$prop.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace($cert.$prop.name)) { $revName = [string]$cert.$prop.name }
                if ($revId) { break }
            }
        }
        $total = if ($null -ne $cert.PSObject.Properties['decisionsTotal'] -and $null -ne $cert.decisionsTotal) { [int]$cert.decisionsTotal } else { 0 }
        $made  = if ($null -ne $cert.PSObject.Properties['decisionsMade']  -and $null -ne $cert.decisionsMade)  { [int]$cert.decisionsMade }  else { 0 }
        $signed = $false
        if ($null -ne $cert.PSObject.Properties['signed'] -and $null -ne $cert.signed) { try { $signed = [bool]$cert.signed } catch { } }
        elseif ($null -ne $cert.PSObject.Properties['phase'] -and "$($cert.phase)" -match 'SIGN') { $signed = $true }
        $completed = $signed -or ($total -gt 0 -and $made -ge $total)
        if ($revId) { $certReviewer[$certId] = $revId }
        $certRecords.Add([ordered]@{
            CertId = $certId; ReviewerId = $revId; ReviewerName = $revName
            DecisionsTotal = $total; DecisionsMade = $made; Completed = $completed; Signed = $signed
        })
    }

    # --- Items (scope) from grouped decisions ---
    $items = [System.Collections.Generic.List[object]]::new()
    $kpi = [ordered]@{
        Total = 0; Approved = 0; Revoked = 0; Pending = 0
        PrivilegedTotal = 0; PrivilegedApproved = 0; PrivilegedRevoked = 0; PrivilegedPending = 0
        CompletionPct = 0; BySource = @{}
    }
    $buckets = @(@{ Name = 'APPROVE'; List = @($Decisions.Approved) }, @{ Name = 'REVOKE'; List = @($Decisions.Revoked) }, @{ Name = 'PENDING'; List = @($Decisions.Pending) })
    foreach ($b in $buckets) {
        foreach ($d in @($b.List)) {
            if ($null -eq $d) { continue }
            $idId   = [string]$d.IdentityId
            $access = [string]$d.AccessName
            $src    = [string]$d.SourceName
            $certId = if ($null -ne $d.PSObject.Properties['CertificationId']) { [string]$d.CertificationId } else { '' }
            $priv   = Test-SPGrantPrivileged -Decision $d -Patterns $patterns
            $items.Add([ordered]@{
                Key          = "$idId|$access|$src"
                IdentityId   = $idId
                IdentityName = [string]$d.IdentityName
                AccessName   = $access
                AccessType   = [string]$d.AccessType
                SourceName   = $src
                Privileged   = $priv
                Decision     = $b.Name
                CertId       = $certId
                ReviewerId   = if ($certReviewer.ContainsKey($certId)) { $certReviewer[$certId] } else { '' }
                DecisionDate = [string]$d.DecisionDate
            })
            $kpi.Total++
            switch ($b.Name) {
                'APPROVE' { $kpi.Approved++; if ($priv) { $kpi.PrivilegedApproved++ } }
                'REVOKE'  { $kpi.Revoked++;  if ($priv) { $kpi.PrivilegedRevoked++ } }
                default   { $kpi.Pending++;  if ($priv) { $kpi.PrivilegedPending++ } }
            }
            if ($priv) { $kpi.PrivilegedTotal++ }
            if (-not [string]::IsNullOrWhiteSpace($src)) {
                if (-not $kpi.BySource.ContainsKey($src)) { $kpi.BySource[$src] = @{ Total = 0; Approved = 0; Revoked = 0; Pending = 0 } }
                $kpi.BySource[$src].Total++
                switch ($b.Name) { 'APPROVE' { $kpi.BySource[$src].Approved++ } 'REVOKE' { $kpi.BySource[$src].Revoked++ } default { $kpi.BySource[$src].Pending++ } }
            }
        }
    }
    $sumTotal = 0; $sumMade = 0
    foreach ($c in $certRecords) { $sumTotal += [int]$c.DecisionsTotal; $sumMade += [int]$c.DecisionsMade }
    $kpi.CompletionPct = if ($sumTotal -gt 0) { [math]::Round($sumMade * 100.0 / $sumTotal, 1) } else { 0 }

    return @{
        Meta  = [ordered]@{
            SchemaVersion = 1
            CampaignId    = [string]$Campaign.id
            CampaignName  = if ($null -ne $Campaign.PSObject.Properties['name']) { [string]$Campaign.name } else { [string]$Campaign.id }
            Status        = if ($null -ne $Campaign.PSObject.Properties['status']) { [string]$Campaign.status } else { '' }
            CapturedAt    = $capturedAt.ToString('o')
            CertCount     = $certRecords.Count
            ItemCount     = $items.Count
        }
        Certs = $certRecords.ToArray()
        Items = $items.ToArray()
        Kpi   = $kpi
    }
}

function Save-SPCampaignSnapshot {
    <#
    .SYNOPSIS
        Writes a datetime-stamped immutable snapshot to {SnapshotPath}\{campaign}\{stamp}.json.
    .PARAMETER Snapshot
        The object from Build-SPCampaignSnapshotData.
    .PARAMETER SnapshotDir
        Override the snapshot root (default: resolved from config, toolkit-root absolute).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter()][string]$SnapshotDir
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Get-SPSnapshotDir }
        $campId  = [string]$Snapshot.Meta.CampaignId
        if ([string]::IsNullOrWhiteSpace($campId)) { return @{ Success = $false; Data = $null; Error = 'Snapshot has no CampaignId' } }
        $safeId  = $campId -replace '[^A-Za-z0-9_\-]', '_'
        $campDir = Join-Path $SnapshotDir $safeId
        if (-not (Test-Path $campDir)) { New-Item -Path $campDir -ItemType Directory -Force -WhatIf:$false | Out-Null }
        $stamp = ([datetime]::Parse($Snapshot.Meta.CapturedAt)).ToString('yyyy-MM-ddTHHmmss')
        $file  = Join-Path $campDir "$stamp.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, ($Snapshot | ConvertTo-Json -Depth 8), $utf8NoBom)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Save-SPCampaignSnapshot failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: retrieve + retention

function Get-SPCampaignSnapshot {
    <#
    .SYNOPSIS
        Loads a snapshot object from a file path.
    .OUTPUTS
        [hashtable] @{ Success; Data=<snapshot>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return @{ Success = $false; Data = $null; Error = "Snapshot not found: $Path" } }
        $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return @{ Success = $true; Data = $obj; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPCampaignSnapshot failed: $($_.Exception.Message)" } }
}

function Get-SPCampaignSnapshotList {
    <#
    .SYNOPSIS
        Lists snapshot files for a campaign, newest first, optionally within a time window.
    .OUTPUTS
        [hashtable] @{ Success; Data=@(@{Path; CapturedAt}); Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CampaignId,
        [Parameter()][string]$SnapshotDir,
        [Parameter()][datetime]$After,
        [Parameter()][datetime]$Before
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Get-SPSnapshotDir }
        $safeId  = $CampaignId -replace '[^A-Za-z0-9_\-]', '_'
        $campDir = Join-Path $SnapshotDir $safeId
        if (-not (Test-Path $campDir)) { return @{ Success = $true; Data = @(); Error = $null } }
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($f in Get-ChildItem -Path $campDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $stampPart = $f.BaseName
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($stampPart, 'yyyy-MM-ddTHHmmss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
            if ($PSBoundParameters.ContainsKey('After')  -and $dt -le $After)  { continue }
            if ($PSBoundParameters.ContainsKey('Before') -and $dt -ge $Before) { continue }
            $list.Add([PSCustomObject]@{ Path = $f.FullName; CapturedAt = $dt })
        }
        return @{ Success = $true; Data = @($list | Sort-Object CapturedAt -Descending); Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPCampaignSnapshotList failed: $($_.Exception.Message)" } }
}

function Get-SPCampaignPreviousSnapshot {
    <#
    .SYNOPSIS
        Returns the most recent snapshot for a campaign strictly BEFORE a cutoff (default now).
    .DESCRIPTION
        For "today vs the prior capture": pass -Before <today's capture time> to get the
        previous one. Returns Data=$null (not an error) on the first run.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{Path; CapturedAt} or $null; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CampaignId,
        [Parameter()][string]$SnapshotDir,
        [Parameter()][datetime]$Before = (Get-Date)
    )
    $listResult = Get-SPCampaignSnapshotList -CampaignId $CampaignId -SnapshotDir $SnapshotDir -Before $Before
    if (-not $listResult.Success) { return $listResult }
    $prev = @($listResult.Data) | Select-Object -First 1
    return @{ Success = $true; Data = $prev; Error = $null }
}

function Remove-SPCampaignOldSnapshots {
    <#
    .SYNOPSIS
        Retention sweep: deletes full snapshot files older than RetentionDays.
    .DESCRIPTION
        Keeps recent full snapshots (default Audit.SnapshotRetentionDays = 90) for diffing;
        long-term trend lives in the small KPI time-series, not the full snapshots, so this
        bounds disk without losing trend history.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Removed=<int> }; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$SnapshotDir,
        [Parameter()][int]$RetentionDays = -1
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Get-SPSnapshotDir }
        if ($RetentionDays -lt 0) { $RetentionDays = Get-SPSnapshotRetentionDays }
        if (-not (Test-Path $SnapshotDir)) { return @{ Success = $true; Data = @{ Removed = 0 }; Error = $null } }
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        $removed = 0
        foreach ($f in Get-ChildItem -Path $SnapshotDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue) {
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($f.BaseName, 'yyyy-MM-ddTHHmmss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
            if ($dt -lt $cutoff) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removed++ } catch { }
            }
        }
        return @{ Success = $true; Data = @{ Removed = $removed }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Remove-SPCampaignOldSnapshots failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'Build-SPCampaignSnapshotData',
    'Save-SPCampaignSnapshot',
    'Get-SPCampaignSnapshot',
    'Get-SPCampaignSnapshotList',
    'Get-SPCampaignPreviousSnapshot',
    'Remove-SPCampaignOldSnapshots'
)
