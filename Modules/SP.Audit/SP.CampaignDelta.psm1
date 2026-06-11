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
        RemediationPending = 0; RemediationRemoved = 0; RemediationQueued = 0
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
            $srcType = if ($null -ne $d.PSObject.Properties['SourceType']) { [string]$d.SourceType } else { '' }
            $remStatus = if ($null -ne $d.PSObject.Properties['RemediationStatus']) { [string]$d.RemediationStatus } else { '' }
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
                SourceType      = $srcType
                Privileged      = $priv
                PrivilegedSource = $privSrc
                Decision        = $b.Name
                RemediationStatus = $remStatus
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
            # Revoked access awaiting de-provisioning (remediation backlog) -- drives the
            # tracker's Remediation stage and the evidence pack's closure section.
            if ($b.Name -eq 'REVOKE' -and $remStatus -match 'Pending') { $kpi.RemediationPending++ }
            # Source-aware split of COMPLETED revokes: only connected-AD removals are confirmed
            # de-provisioned; everything else is queued for downstream/manual fulfilment.
            if ($b.Name -eq 'REVOKE' -and $remStatus -match 'Provision') {
                $disp = Get-SPRevocationDisposition -Decision 'REVOKE' -Completed $true -SourceType $srcType -SourceName $src
                if ($disp.IsRemoved) { $kpi.RemediationRemoved++ } else { $kpi.RemediationQueued++ }
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
        # unmodified after capture (access-review audit evidence).
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

function Get-SPCampaignSnapshotSet {
    <#
    .SYNOPSIS
        Resolves an ORDERED set of snapshot objects from disk for multi-snapshot history
        analysis -- read-only, no API. Two modes:
          * Cross-campaign (default): the LATEST capture of EACH campaign whose snapshots match
            a name filter, ordered by campaign start date -- the "one point per daily campaign"
            timeline (admin_xyz across Mon/Tue/Wed).
          * -WithinCampaign: EVERY capture of ONE campaign, ordered by capture time -- how that
            single long-lived campaign's decisions evolved as laggards/reviewers acted.
    .DESCRIPTION
        Pure disk walk over {SnapshotDir}\{campaignId}\{stamp}.json. Reuses
        Get-SPCampaignSnapshotList + Get-SPCampaignSnapshot. Name matching is on each campaign's
        Meta.CampaignName (precedence: exact -> starts-with -> contains), or pin one with
        -CampaignId. Feeds Get-SPEntitlementHistory.
    .PARAMETER SnapshotDir
        Snapshot root (default: resolved from config, toolkit-root absolute).
    .PARAMETER CampaignId
        Resolve a single campaign by id (its sanitized snapshot sub-dir).
    .PARAMETER CampaignName / -CampaignNameStartsWith / -CampaignNameContains
        Match campaigns by their snapshot Meta.CampaignName.
    .PARAMETER WithinCampaign
        Walk every capture of ONE campaign instead of one-per-campaign. Requires the filters to
        resolve to exactly one campaign (else an error asking to narrow / use -CampaignId).
    .OUTPUTS
        [hashtable] @{ Success; Data=@(<ordered snapshot objects>); Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$SnapshotDir,
        [Parameter()][string]$CampaignId,
        [Parameter()][string]$CampaignName,
        [Parameter()][string]$CampaignNameStartsWith,
        [Parameter()][string]$CampaignNameContains,
        [Parameter()][switch]$WithinCampaign
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SnapshotDir)) { $SnapshotDir = Get-SPSnapshotDir }
        if (-not (Test-Path $SnapshotDir)) { return @{ Success = $true; Data = @(); Error = $null } }

        # --- enumerate the candidate campaign sub-dirs ---
        $campDirs = @()
        if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
            $safeId = $CampaignId -replace '[^A-Za-z0-9_\-]', '_'
            $one = Join-Path $SnapshotDir $safeId
            if (Test-Path $one) { $campDirs = @($safeId) }
        }
        else {
            $campDirs = @(Get-ChildItem -LiteralPath $SnapshotDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        if ($campDirs.Count -eq 0) { return @{ Success = $true; Data = @(); Error = $null } }

        # --- for each campaign dir, load its latest snapshot to read identity + apply name filter ---
        $matched = [System.Collections.Generic.List[object]]::new()
        foreach ($dirName in $campDirs) {
            $listR = Get-SPCampaignSnapshotList -CampaignId $dirName -SnapshotDir $SnapshotDir
            if (-not $listR.Success -or @($listR.Data).Count -eq 0) { continue }
            $latestRef = @($listR.Data)[0]   # newest first
            $loadR = Get-SPCampaignSnapshot -Path $latestRef.Path
            if (-not $loadR.Success) { continue }
            $latest = $loadR.Data
            $name = ''
            if ($null -ne $latest.Meta) {
                $p = $latest.Meta.PSObject.Properties['CampaignName']
                if ($null -ne $p -and $null -ne $p.Value) { $name = [string]$p.Value }
            }
            # name filter precedence: exact -> starts-with -> contains (skip when none supplied)
            $keep = $true
            if (-not [string]::IsNullOrWhiteSpace($CampaignName)) { $keep = ($name -ieq $CampaignName) }
            elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { $keep = ($name -like "$CampaignNameStartsWith*") }
            elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) { $keep = ($name -match [regex]::Escape($CampaignNameContains)) }
            if (-not $keep) { continue }
            $startRaw = ''
            if ($null -ne $latest.Meta) {
                $sp = $latest.Meta.PSObject.Properties['StartDate']
                if ($null -ne $sp -and $null -ne $sp.Value) { $startRaw = [string]$sp.Value }
            }
            $sortDate = $latestRef.CapturedAt
            if (-not [string]::IsNullOrWhiteSpace($startRaw)) { try { $sortDate = [datetime]::Parse($startRaw) } catch { } }
            $matched.Add([PSCustomObject]@{ DirName = $dirName; CampaignName = $name; SortDate = $sortDate; LatestPath = $latestRef.Path; LatestSnapshot = $latest })
        }
        if ($matched.Count -eq 0) { return @{ Success = $true; Data = @(); Error = $null } }

        if ($WithinCampaign) {
            if ($matched.Count -gt 1) {
                return @{ Success = $false; Data = $null; Error = "-WithinCampaign matched $($matched.Count) campaigns ($(@($matched | ForEach-Object { $_.CampaignName }) -join '; ')) -- narrow the name filter or use -CampaignId." }
            }
            $only = $matched[0]
            $allR = Get-SPCampaignSnapshotList -CampaignId $only.DirName -SnapshotDir $SnapshotDir
            $ordered = [System.Collections.Generic.List[object]]::new()
            foreach ($ref in (@($allR.Data) | Sort-Object CapturedAt)) {   # oldest -> newest
                $lr = Get-SPCampaignSnapshot -Path $ref.Path
                if ($lr.Success) { $ordered.Add($lr.Data) }
            }
            return @{ Success = $true; Data = @($ordered.ToArray()); Error = $null }
        }

        # Cross-campaign: one (latest) snapshot per matched campaign, ordered by start date.
        $ordered = @($matched | Sort-Object SortDate | ForEach-Object { $_.LatestSnapshot })
        return @{ Success = $true; Data = @($ordered); Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPCampaignSnapshotSet failed: $($_.Exception.Message)" } }
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

function Test-SPCampaignSnapshotIntegrity {
    <#
    .SYNOPSIS
        Validates a campaign snapshot JSON (or a raw items-cache .jsonl) for data
        completeness and internal consistency -- no HTML, no API. Surfaces the data-quality
        problems that silently produce bad diffs/reports.
    .DESCRIPTION
        Read-only. Auto-detects the file kind and runs the relevant checks:

          Snapshot (Build-SPCampaignSnapshotData object: Meta/Items/Kpi)
            * Field coverage  -- IdentityId/AccessName/SourceName/Decision/DecisionDate
              populated on >= -FieldCoverageWarnPct of items (this is the "approve with no
              date / blank source" class of bug).
            * Decision validity -- every Decision in APPROVE/REVOKE/PENDING.
            * Decided-with-no-date -- APPROVE/REVOKE items missing a DecisionDate.
            * KPI consistency -- Kpi.Total and Approved+Revoked+Pending vs item count;
              Meta.ItemCount vs item count.
            * Key integrity -- blank or duplicate identity|access|source keys.
            * Date sanity -- decision dates after the capture time.
            * Empty capture -- 0 items (API hiccup / partial auth = a "bad run").

          ItemsCache (items-{id}.jsonl + sibling .meta.json)
            * Every line parses as JSON.
            * .meta.json present -- a MISSING meta = an interrupted/partial fetch (meta is
              written only on completion); the next run resumes it.
            * meta.ItemCount vs the actual line count on disk.

        Returns a findings list (Severity Error/Warn/Info) plus a summary; Ok = no Error.
    .PARAMETER Path
        A snapshot .json, an items-*.jsonl, or a directory (newest *.json snapshot is used).
    .PARAMETER FieldCoverageWarnPct
        Warn when a key field is populated on fewer than this percent of items. Default 90.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Kind; File; Ok; Findings; Summary }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][double]$FieldCoverageWarnPct = 90
    )
    try {
        # Local safe property reader -- nested sibling modules do NOT share Get-SPDiffProp,
        # and the file always round-trips through JSON to a PSCustomObject (or IDictionary
        # when a freshly-built snapshot is piped in by a test).
        function _prop($o, $n, $d = '') {
            if ($null -eq $o) { return $d }
            if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n) -and $null -ne $o[$n]) { return $o[$n] }; return $d }
            $p = $o.PSObject.Properties[$n]
            if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
            return $d
        }
        $findings = [System.Collections.Generic.List[object]]::new()
        function _add($sev, $code, $msg, $count) { $findings.Add([ordered]@{ Severity = $sev; Code = $code; Message = $msg; Count = [int]$count }) }

        # Resolve a directory to its newest snapshot json (recursive, excluding .meta.json).
        $target = $Path
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $newest = Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notlike '*.meta.json' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -eq $newest) { return @{ Success = $false; Data = $null; Error = "No *.json snapshot found under directory: $Path" } }
            $target = $newest.FullName
        }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return @{ Success = $false; Data = $null; Error = "File not found: $target" } }

        $isJsonl = ($target -match '\.jsonl$')
        $rawFirst = ''
        try { $rawFirst = (Get-Content -LiteralPath $target -TotalCount 1 -ErrorAction Stop) -join '' } catch { }

        # ----- ItemsCache (.jsonl) -----
        if ($isJsonl -or ($rawFirst -match '"CertificationId"' -and $rawFirst -match '"Item"')) {
            $lines = @(Get-Content -LiteralPath $target | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $parsed = 0; $bad = 0
            foreach ($ln in $lines) { try { [void]($ln | ConvertFrom-Json); $parsed++ } catch { $bad++ } }
            if ($bad -gt 0)    { _add 'Error' 'CACHE_PARSE' "$bad cache line(s) are not valid JSON (truncated/corrupt)." $bad }
            if ($parsed -eq 0) { _add 'Error' 'CACHE_EMPTY' 'Items cache has no parseable items.' 0 }

            $metaPath = ''
            $cand1 = [regex]::Replace($target, '\.jsonl$', '.meta.json')
            if (Test-Path -LiteralPath $cand1) { $metaPath = $cand1 }
            if (-not $metaPath) {
                _add 'Warn' 'CACHE_PARTIAL' 'No .meta.json sidecar -- PARTIAL/interrupted fetch (meta is written only on completion). The next run resumes it.' 0
            }
            else {
                try {
                    $m = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
                    $metaCount = [int](_prop $m 'ItemCount' 0)
                    if ($metaCount -ne $parsed) { _add 'Warn' 'CACHE_COUNT' "meta.ItemCount ($metaCount) != items on disk ($parsed)." ([math]::Abs($metaCount - $parsed)) }
                } catch { _add 'Warn' 'CACHE_META' 'meta.json present but unreadable.' 0 }
            }
            $summary = [ordered]@{ Kind = 'ItemsCache'; CampaignName = ''; ItemCount = $parsed; BadLines = $bad; HasMeta = [bool]$metaPath }
            $ok = (@($findings | Where-Object { $_.Severity -eq 'Error' }).Count -eq 0)
            return @{ Success = $true; Data = @{ Kind = 'ItemsCache'; File = $target; Ok = [bool]$ok; Findings = $findings.ToArray(); Summary = $summary }; Error = $null }
        }

        # ----- Snapshot (.json) -----
        $snap = $null
        try { $snap = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json }
        catch { return @{ Success = $false; Data = $null; Error = "Snapshot is not valid JSON: $($_.Exception.Message)" } }

        $meta = _prop $snap 'Meta' $null
        if ($null -eq $meta) { _add 'Error' 'NO_META' 'Snapshot has no Meta block.' 0 }
        $items = @(); $rawItems = _prop $snap 'Items' $null
        if ($null -ne $rawItems) { $items = @($rawItems) }
        $itemCount = $items.Count
        if ($itemCount -eq 0) { _add 'Error' 'EMPTY' 'Snapshot has 0 items -- likely a bad/empty capture (API hiccup or partial auth).' 0 }

        # Field coverage.
        foreach ($f in @('IdentityId', 'AccessName', 'SourceName', 'Decision', 'DecisionDate')) {
            if ($itemCount -eq 0) { break }
            $blank = 0
            foreach ($it in $items) { if ([string]::IsNullOrWhiteSpace([string](_prop $it $f ''))) { $blank++ } }
            if ($blank -gt 0) {
                $pct = [math]::Round((($itemCount - $blank) * 100.0 / $itemCount), 1)
                if ($pct -lt $FieldCoverageWarnPct) {
                    $sev = if ($f -eq 'IdentityId' -or $f -eq 'Decision') { 'Error' } else { 'Warn' }
                    _add $sev "BLANK_$($f.ToUpperInvariant())" "$f blank on $blank/$itemCount items ($pct% populated)." $blank
                }
            }
        }
        # AccessId/SourceId blanks weaken the cross-campaign join (it falls back to names) -- info only.
        foreach ($f in @('AccessId', 'SourceId')) {
            if ($itemCount -eq 0) { break }
            $blank = 0
            foreach ($it in $items) { if ([string]::IsNullOrWhiteSpace([string](_prop $it $f ''))) { $blank++ } }
            if ($blank -gt 0) { _add 'Info' "BLANK_$($f.ToUpperInvariant())" "$f blank on $blank/$itemCount items -- cross-campaign join falls back to names (churns on rename)." $blank }
        }

        # KPI / count consistency.
        $kpi = _prop $snap 'Kpi' $null
        if ($null -ne $kpi -and $itemCount -gt 0) {
            $kTotal = [int](_prop $kpi 'Total' 0)
            $kSum = [int](_prop $kpi 'Approved' 0) + [int](_prop $kpi 'Revoked' 0) + [int](_prop $kpi 'Pending' 0)
            if ($kTotal -ne $itemCount) { _add 'Warn' 'KPI_TOTAL' "Kpi.Total ($kTotal) != item count ($itemCount)." ([math]::Abs($kTotal - $itemCount)) }
            if ($kSum -ne $itemCount)   { _add 'Warn' 'KPI_SUM' "Approved+Revoked+Pending ($kSum) != item count ($itemCount)." ([math]::Abs($kSum - $itemCount)) }
        }
        $metaItemCount = [int](_prop $meta 'ItemCount' -1)
        if ($metaItemCount -ge 0 -and $metaItemCount -ne $itemCount) { _add 'Warn' 'META_COUNT' "Meta.ItemCount ($metaItemCount) != actual items ($itemCount)." ([math]::Abs($metaItemCount - $itemCount)) }

        # Decision validity, decided-with-no-date, key integrity, date sanity (single pass).
        $cap = $null
        $capRaw = [string](_prop $meta 'CapturedAt' '')
        if ($capRaw) { try { $cap = [datetime]::Parse($capRaw) } catch { } }
        $badDec = 0; $decidedNoDate = 0; $dupKeys = 0; $blankKey = 0; $futureDate = 0
        $seen = @{}
        foreach ($it in $items) {
            $dec = ([string](_prop $it 'Decision' '')).ToUpperInvariant()
            if ($dec -and @('APPROVE', 'REVOKE', 'PENDING') -notcontains $dec) { $badDec++ }
            $dd = [string](_prop $it 'DecisionDate' '')
            if (($dec -eq 'APPROVE' -or $dec -eq 'REVOKE') -and [string]::IsNullOrWhiteSpace($dd)) { $decidedNoDate++ }
            elseif ($dd -and $null -ne $cap) { try { if (([datetime]::Parse($dd)) -gt $cap.AddMinutes(5)) { $futureDate++ } } catch { } }
            $k = [string](_prop $it 'Key' '')
            if ([string]::IsNullOrWhiteSpace($k)) { $blankKey++ }
            elseif ($seen.ContainsKey($k)) { $dupKeys++ } else { $seen[$k] = $true }
        }
        if ($badDec -gt 0)        { _add 'Error' 'DECISION_INVALID' "$badDec item(s) have a Decision outside APPROVE/REVOKE/PENDING." $badDec }
        if ($decidedNoDate -gt 0) { _add 'Warn'  'DECIDED_NO_DATE' "$decidedNoDate decided (APPROVE/REVOKE) item(s) have no DecisionDate -- 'when' can't be shown." $decidedNoDate }
        if ($blankKey -gt 0)      { _add 'Error' 'BLANK_KEY' "$blankKey item(s) have a blank join Key (identity|access|source) -- they cannot be diffed." $blankKey }
        if ($dupKeys -gt 0)       { _add 'Warn'  'DUP_KEY' "$dupKeys duplicate identity|access|source key(s) -- a grant is represented more than once." $dupKeys }
        if ($futureDate -gt 0)    { _add 'Warn'  'FUTURE_DATE' "$futureDate decision date(s) are after the capture time." $futureDate }

        $summary = [ordered]@{
            Kind         = 'Snapshot'
            CampaignName = [string](_prop $meta 'CampaignName' '')
            CampaignId   = [string](_prop $meta 'CampaignId' '')
            Status       = [string](_prop $meta 'Status' '')
            CapturedAt   = $capRaw
            ItemCount    = $itemCount
        }
        $ok = (@($findings | Where-Object { $_.Severity -eq 'Error' }).Count -eq 0)
        return @{ Success = $true; Data = @{ Kind = 'Snapshot'; File = $target; Ok = [bool]$ok; Findings = $findings.ToArray(); Summary = $summary }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Test-SPCampaignSnapshotIntegrity failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'Build-SPCampaignSnapshotData',
    'Save-SPCampaignSnapshot',
    'Get-SPCampaignSnapshot',
    'Get-SPCampaignSnapshotList',
    'Get-SPCampaignPreviousSnapshot',
    'Get-SPCampaignSnapshotSet',
    'Remove-SPCampaignOldSnapshots',
    'Test-SPCampaignSnapshotIntegrity'
)
