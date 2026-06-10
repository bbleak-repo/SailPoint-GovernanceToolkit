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
    # "Both", with classification PROVENANCE so reports can distinguish CONFIRMED
    # (ISC attribute) from SUSPECTED (name pattern). Returns @{ Privileged; Source }
    # where Source is 'attribute' | 'pattern' | 'none'.
    # OR semantics (matches DeltaCert's privileged rule): an explicit truthy ISC
    # attribute makes it privileged; a false/absent attribute is NOT authoritative
    # (ISC may simply not classify the entitlement), so fall through to name patterns.
    param([object]$Decision, [string[]]$Patterns)
    foreach ($p in @('Privileged', 'IsPrivileged')) {
        if ($null -ne $Decision.PSObject.Properties[$p] -and $null -ne $Decision.$p) {
            try { if ([bool]$Decision.$p) { return @{ Privileged = $true; Source = 'attribute' } } } catch { }
        }
    }
    $name = [string]$Decision.AccessName
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        foreach ($pat in $Patterns) {
            if ([string]::IsNullOrWhiteSpace($pat)) { continue }
            try {
                # Word-boundary a plain-text pattern (letters/digits/space/hyphen) so 'Admin'
                # matches "Domain Admin" but NOT "Administrative Assistant" / "Badminton".
                # Patterns containing regex metachars (e.g. '^SVC-') are used verbatim.
                $rx = if ($pat -match '^[\w\s\-]+$') { '\b' + [regex]::Escape($pat) + '\b' } else { $pat }
                if ($name -match $rx) { return @{ Privileged = $true; Source = 'pattern' } }
            } catch { }
        }
    }
    return @{ Privileged = $false; Source = 'none' }
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
        [Parameter(Mandatory)][object]$Decisions,
        # Optional evidence provenance (operator/tenant/version/environment) stamped into Meta.
        [Parameter()][hashtable]$Provenance
    )

    $patterns = Get-SPPrivilegedPatterns
    $capturedAt = (Get-Date)

    # Campaign due date (ISC 'deadline') -- drives true "overdue" vs "persistently pending".
    $dueDate = ''
    foreach ($p in @('deadline', 'due', 'dueDate', 'endDate')) {
        if ($null -ne $Campaign.PSObject.Properties[$p] -and -not [string]::IsNullOrWhiteSpace([string]$Campaign.$p)) { $dueDate = [string]$Campaign.$p; break }
    }

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
        # Audit-honest distinction: a cert with all decisions entered but NOT signed is
        # "decided, awaiting sign-off" -- not the same as attested/done for evidence.
        $decidedAwaitingSignoff = ($total -gt 0 -and $made -ge $total -and -not $signed)
        if ($revId) { $certReviewer[$certId] = $revId }
        $certRecords.Add([ordered]@{
            CertId = $certId; ReviewerId = $revId; ReviewerName = $revName
            DecisionsTotal = $total; DecisionsMade = $made; Completed = $completed
            Signed = $signed; DecidedAwaitingSignoff = $decidedAwaitingSignoff
        })
    }

    # --- Items (scope) from grouped decisions ---
    $items = [System.Collections.Generic.List[object]]::new()
    $kpi = [ordered]@{
        Total = 0; Approved = 0; Revoked = 0; Pending = 0
        PrivilegedTotal = 0; PrivilegedApproved = 0; PrivilegedRevoked = 0; PrivilegedPending = 0
        PrivilegedReviewed = 0
        PrivilegedConfirmed = 0; PrivilegedSuspected = 0
        CompletionPct = 0; BySource = @{}
    }
    $buckets = @(@{ Name = 'APPROVE'; List = @($Decisions.Approved) }, @{ Name = 'REVOKE'; List = @($Decisions.Revoked) }, @{ Name = 'PENDING'; List = @($Decisions.Pending) })
    foreach ($b in $buckets) {
        foreach ($d in @($b.List)) {
            if ($null -eq $d) { continue }
            $idId   = [string]$d.IdentityId
            $access = [string]$d.AccessName
            $src    = [string]$d.SourceName
            $accId  = if ($null -ne $d.PSObject.Properties['AccessId']) { [string]$d.AccessId } else { '' }
            $srcId  = if ($null -ne $d.PSObject.Properties['SourceId']) { [string]$d.SourceId } else { '' }
            $certId = if ($null -ne $d.PSObject.Properties['CertificationId']) { [string]$d.CertificationId } else { '' }
            $privInfo = Test-SPGrantPrivileged -Decision $d -Patterns $patterns
            $priv     = [bool]$privInfo.Privileged
            $privSrc  = [string]$privInfo.Source
            # Stable scope key: prefer immutable IDs (entitlement/source) so an entitlement or
            # source RENAME doesn't churn as remove+add; fall back to names when IDs absent.
            $keyAccess = if (-not [string]::IsNullOrWhiteSpace($accId)) { $accId } else { $access }
            $keySource = if (-not [string]::IsNullOrWhiteSpace($srcId)) { $srcId } else { $src }
            $items.Add([ordered]@{
                Key             = "$idId|$keyAccess|$keySource"
                IdentityId      = $idId
                IdentityName    = [string]$d.IdentityName
                AccessName      = $access
                AccessId        = $accId
                AccessType      = [string]$d.AccessType
                SourceName      = $src
                SourceId        = $srcId
                Privileged      = $priv
                PrivilegedSource = $privSrc
                Decision        = $b.Name
                CertId          = $certId
                ReviewerId      = if ($certReviewer.ContainsKey($certId)) { $certReviewer[$certId] } else { '' }
                DecisionDate    = [string]$d.DecisionDate
            })
            $kpi.Total++
            switch ($b.Name) {
                'APPROVE' { $kpi.Approved++; if ($priv) { $kpi.PrivilegedApproved++ } }
                'REVOKE'  { $kpi.Revoked++;  if ($priv) { $kpi.PrivilegedRevoked++ } }
                default   { $kpi.Pending++;  if ($priv) { $kpi.PrivilegedPending++ } }
            }
            if ($priv) {
                $kpi.PrivilegedTotal++
                if ($privSrc -eq 'attribute') { $kpi.PrivilegedConfirmed++ } else { $kpi.PrivilegedSuspected++ }
            }
            if (-not [string]::IsNullOrWhiteSpace($src)) {
                if (-not $kpi.BySource.ContainsKey($src)) { $kpi.BySource[$src] = @{ Total = 0; Approved = 0; Revoked = 0; Pending = 0 } }
                $kpi.BySource[$src].Total++
                switch ($b.Name) { 'APPROVE' { $kpi.BySource[$src].Approved++ } 'REVOKE' { $kpi.BySource[$src].Revoked++ } default { $kpi.BySource[$src].Pending++ } }
            }
        }
    }
    # Decision-weighted completion (one huge reviewer can dominate this).
    $sumTotal = 0; $sumMade = 0
    foreach ($c in $certRecords) { $sumTotal += [int]$c.DecisionsTotal; $sumMade += [int]$c.DecisionsMade }
    $kpi.CompletionPct = if ($sumTotal -gt 0) { [math]::Round($sumMade * 100.0 / $sumTotal, 1) } else { 0 }

    # Reviewer-weighted completion (so a few large reviewers can't mask a stalled majority).
    $revTotal = $certRecords.Count; $revSigned = 0; $revDecided = 0; $revNotStarted = 0
    foreach ($c in $certRecords) {
        if ([bool]$c.Signed) { $revSigned++ }
        if (($c.DecidedAwaitingSignoff) -or [bool]$c.Signed) { $revDecided++ }   # all decisions entered
        if ([int]$c.DecisionsMade -eq 0) { $revNotStarted++ }
    }
    $kpi.ReviewersTotal       = $revTotal
    $kpi.ReviewersSigned      = $revSigned
    $kpi.ReviewersDecided     = $revDecided
    $kpi.ReviewersNotStarted  = $revNotStarted
    $kpi.CompletionPctByReviewer = if ($revTotal -gt 0) { [math]::Round($revDecided * 100.0 / $revTotal, 1) } else { 0 }
    $kpi.PrivilegedReviewed   = $kpi.PrivilegedApproved + $kpi.PrivilegedRevoked

    # Rates -- scope-growth-robust governance signals. Null when the denominator is 0
    # (a 0 rate and "no data" are different; trend rollups must skip nulls).
    function _rate([int]$num, [int]$den) { if ($den -le 0) { return $null } return [math]::Round($num * 1.0 / $den, 4) }
    $kpi.Rates = [ordered]@{
        # "is privileged access trending in a direction": approval rate among REVIEWED privileged grants
        PrivApprovalRate  = _rate $kpi.PrivilegedApproved $kpi.PrivilegedReviewed
        PrivRevokeRate    = _rate $kpi.PrivilegedRevoked  $kpi.PrivilegedReviewed
        PrivShareOfScope  = _rate $kpi.PrivilegedTotal    $kpi.Total
        ApprovalRate      = _rate $kpi.Approved ($kpi.Approved + $kpi.Revoked)
        RevokeRate        = _rate $kpi.Revoked  ($kpi.Approved + $kpi.Revoked)
    }

    $provenance = [ordered]@{
        ToolkitVersion = if ($Provenance -and $Provenance.ContainsKey('ToolkitVersion')) { [string]$Provenance['ToolkitVersion'] } else { '' }
        TenantUrl      = if ($Provenance -and $Provenance.ContainsKey('TenantUrl'))      { [string]$Provenance['TenantUrl'] }      else { '' }
        Environment    = if ($Provenance -and $Provenance.ContainsKey('Environment'))    { [string]$Provenance['Environment'] }    else { '' }
        CapturedBy     = if ($Provenance -and $Provenance.ContainsKey('CapturedBy'))     { [string]$Provenance['CapturedBy'] }     else { [string]$env:USERNAME }
    }

    return @{
        Meta  = [ordered]@{
            SchemaVersion     = 2
            CampaignId        = [string]$Campaign.id
            CampaignName      = if ($null -ne $Campaign.PSObject.Properties['name']) { [string]$Campaign.name } else { [string]$Campaign.id }
            Status            = if ($null -ne $Campaign.PSObject.Properties['status']) { [string]$Campaign.status } else { '' }
            CapturedAt        = $capturedAt.ToString('o')
            StartDate         = if ($null -ne $Campaign.PSObject.Properties['created']) { [string]$Campaign.created } else { '' }
            DueDate           = $dueDate
            CertCount         = $certRecords.Count
            ItemCount         = $items.Count
            # Reproducibility: the privileged-pattern set in force at capture time.
            PrivilegedPatterns = @($patterns)
            Provenance        = $provenance
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
        # Tamper-evidence: write a SHA-256 sidecar so a cited snapshot can be proven
        # unmodified after capture (SOX/ITGC access-review evidence).
        $hash = $null
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file)
                $hash  = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            } finally { $sha.Dispose() }
            [System.IO.File]::WriteAllText("$file.sha256", "$hash  $stamp.json", $utf8NoBom)
        } catch { }
        return @{ Success = $true; Data = $file; Error = $null; Sha256 = $hash }
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
        [Parameter()][datetime]$Before = (Get-Date),
        # Cadence selection: when > 0, pick the prior snapshot CLOSEST to
        # ($Before - TargetAgoHours) instead of the immediately-prior one. This is what makes
        # "week-over-week" compare this week's capture to last week's (~168h), not to
        # yesterday's. 0 (default) keeps the adjacent-prior behaviour.
        [Parameter()][double]$TargetAgoHours = 0,
        # IntraDay: restrict candidates to the SAME calendar day as $Before (e.g. "before
        # noon vs now"); falls back to adjacent-prior if none earlier the same day.
        [Parameter()][switch]$IntraDay
    )
    $listResult = Get-SPCampaignSnapshotList -CampaignId $CampaignId -SnapshotDir $SnapshotDir -Before $Before
    if (-not $listResult.Success) { return $listResult }
    $candidates = @($listResult.Data)
    if ($candidates.Count -eq 0) { return @{ Success = $true; Data = $null; Error = $null } }

    if ($IntraDay) {
        $sameDay = @($candidates | Where-Object { $_.CapturedAt.Date -eq $Before.Date })
        if ($sameDay.Count -gt 0) { return @{ Success = $true; Data = ($sameDay | Select-Object -First 1); Error = $null } }
        # no earlier capture today -> fall through to adjacent
    }

    if ($TargetAgoHours -gt 0) {
        $target = $Before.AddHours(-$TargetAgoHours)
        $best = $null; $bestDelta = [double]::MaxValue
        foreach ($c in $candidates) {
            $d = [math]::Abs(($c.CapturedAt - $target).TotalHours)
            if ($d -lt $bestDelta) { $bestDelta = $d; $best = $c }
        }
        return @{ Success = $true; Data = $best; Error = $null }
    }

    return @{ Success = $true; Data = ($candidates | Select-Object -First 1); Error = $null }
}

function Remove-SPCampaignOldSnapshots {
    <#
    .SYNOPSIS
        Retention sweep: deletes OPERATIONAL snapshot files older than RetentionDays, but
        NEVER deletes a snapshot that is certification EVIDENCE.
    .DESCRIPTION
        Keeps recent full snapshots (default Audit.SnapshotRetentionDays = 90) for diffing;
        long-term TREND lives in the small KPI time-series, not the full snapshots. BUT a
        snapshot of a COMPLETED campaign (or one whose certs are all signed) is the
        attestation evidence an auditor needs for the full audit period (often years), so
        the sweep is LIFECYCLE-AWARE: it skips any snapshot whose Meta.Status is COMPLETED/
        COMPLETING/SIGNED. Those are preserved (archive/WORM is a separate concern). Pass
        -IncludeEvidence to force-delete regardless (use only with an external archive).
        SHA-256 sidecars are removed alongside the snapshots they cover.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Removed; PreservedEvidence }; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$SnapshotDir,
        [Parameter()][int]$RetentionDays = -1,
        [Parameter()][switch]$IncludeEvidence
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Get-SPSnapshotDir }
        if ($RetentionDays -lt 0) { $RetentionDays = Get-SPSnapshotRetentionDays }
        if (-not (Test-Path $SnapshotDir)) { return @{ Success = $true; Data = @{ Removed = 0; PreservedEvidence = 0 }; Error = $null } }
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        $removed = 0; $preserved = 0
        foreach ($f in Get-ChildItem -Path $SnapshotDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue) {
            $dt = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($f.BaseName, 'yyyy-MM-ddTHHmmss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
            if ($dt -ge $cutoff) { continue }
            if (-not $IncludeEvidence) {
                # Peek at the snapshot's lifecycle: never delete terminal/evidence captures.
                $isEvidence = $false
                try {
                    $obj = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                    $status = if ($null -ne $obj.Meta -and $null -ne $obj.Meta.PSObject.Properties['Status']) { ([string]$obj.Meta.Status).ToUpperInvariant() } else { '' }
                    if ($status -in @('COMPLETED', 'COMPLETING', 'SIGNED', 'ARCHIVED')) { $isEvidence = $true }
                    elseif ($null -ne $obj.Certs -and @($obj.Certs | Where-Object { $_.Signed }).Count -gt 0 -and @($obj.Certs | Where-Object { -not $_.Signed }).Count -eq 0) { $isEvidence = $true }
                } catch { $isEvidence = $true }   # if unreadable, err on the side of preserving
                if ($isEvidence) { $preserved++; continue }
            }
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath "$($f.FullName).sha256") { Remove-Item -LiteralPath "$($f.FullName).sha256" -Force -ErrorAction SilentlyContinue }
                $removed++
            } catch { }
        }
        return @{ Success = $true; Data = @{ Removed = $removed; PreservedEvidence = $preserved }; Error = $null }
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
