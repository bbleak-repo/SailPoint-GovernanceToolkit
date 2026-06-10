<#
.SYNOPSIS
    SP.CampaignDiff -- the comparison + reporting layer over dated campaign snapshots.

.DESCRIPTION
    Compare-SPCampaignSnapshots takes two snapshots produced by
    Build-SPCampaignSnapshotData (a Current and an optional Previous -- $null on the
    first run) and computes two derived views plus a compliance summary:

      Completion view -- per reviewer/certification: progress since the prior capture
        (decisions made delta, completion %, newly completed, stalled, not started).
        Answers "who is doing their attestations day over day."

      Scope view -- per grant (Key = identity|access|source): what is NEW in scope,
        what is GONE, and where the decision CHANGED. Answers "what access showed up
        that was not in yesterday's report" -- the same campaign grows as entitlement
        groups and sources (AD, disconnected CSV, ...) onboard.

      Compliance summary -- the four leadership signals the user asked for:
        * Newly-added privileged access      (new privileged grants this capture)
        * Stalled / not-started reviewers     (no progress between captures / 0 made)
        * Overdue undecided items             (PENDING across at least two captures)
        * Privileged approved (advisory)      (privileged grants newly set to APPROVE)
          -- surfaced respectfully as a maturity signal, NOT an accusation; the
             rubber-stamp / review-velocity detection is a separate opt-in advisory.

    Two HTML reports (Word-compatible, self-contained inline CSS) + a flat CSV pair are
    rendered from the single diff object. Read-only throughout: this layer never
    reassigns, escalates, or mutates ISC -- it only describes change.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Internal helpers

function Get-SPDiffProp {
    # Uniform read across the two shapes a snapshot can arrive in: freshly built
    # ([ordered] hashtables) or round-tripped from JSON (PSCustomObjects). Returns
    # $Default when the member is absent or null.
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $v = $Object[$Name]; if ($null -ne $v) { return $v } }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function ConvertTo-SPDiffMap {
    # key -> last item, from a snapshot's Items collection.
    param([object[]]$Items)
    $map = @{}
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $k = [string](Get-SPDiffProp $it 'Key' '')
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        $map[$k] = $it
    }
    return $map
}

function ConvertTo-SPDiffCertMap {
    # cert identity (CertId, else ReviewerId) -> cert record.
    param([object[]]$Certs)
    $map = @{}
    foreach ($c in @($Certs)) {
        if ($null -eq $c) { continue }
        $k = [string](Get-SPDiffProp $c 'CertId' '')
        if ([string]::IsNullOrWhiteSpace($k)) { $k = 'rev:' + [string](Get-SPDiffProp $c 'ReviewerId' '') }
        if ([string]::IsNullOrWhiteSpace($k) -or $k -eq 'rev:') { continue }
        $map[$k] = $c
    }
    return $map
}

function Get-SPDiffHtmlHead {
    param([string]$Title)
    $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#ffffff;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:15px;color:#1f3a5f;margin-top:26px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
.meta{color:#566; font-size:12px;margin-bottom:8px;}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:120px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;}
.kpi .n{font-size:22px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.up{color:#0a7d2c;font-weight:600;} .down{color:#b00020;font-weight:600;} .flat{color:#888;}
.priv{background:#fdecec !important;} .priv td{color:#7a0014;}
.badge{display:inline-block;padding:1px 7px;border-radius:10px;font-size:10px;font-weight:700;}
.b-priv{background:#b00020;color:#fff;} .b-add{background:#0a7d2c;color:#fff;}
.b-rem{background:#888;color:#fff;} .b-chg{background:#9a6700;color:#fff;}
.empty{color:#888;font-style:italic;padding:8px 0;}
.note{font-size:11px;color:#777;margin-top:4px;}
.first{background:#fff7e6;border:1px solid #ffd97a;border-radius:6px;padding:10px 14px;margin:10px 0;color:#7a5a00;}
'@
    return "<!DOCTYPE html><html><head><meta charset='utf-8'><title>$([System.Web.HttpUtility]::HtmlEncode($Title))</title><style>$css</style></head><body>"
}

function Get-SPDiffEnc {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Web.HttpUtility]::HtmlEncode([string]$Value)
}

function Get-SPDiffDelta {
    # signed integer delta rendered as a coloured span.
    param([int]$Delta)
    if ($Delta -gt 0) { return "<span class='up'>+$Delta</span>" }
    if ($Delta -lt 0) { return "<span class='down'>$Delta</span>" }
    return "<span class='flat'>0</span>"
}

#endregion

#region Public: compare

function Compare-SPCampaignSnapshots {
    <#
    .SYNOPSIS
        Computes completion + scope deltas and a compliance summary between two snapshots.
    .PARAMETER Current
        The newer snapshot (from Build-SPCampaignSnapshotData or Get-SPCampaignSnapshot).
    .PARAMETER Previous
        The older snapshot to compare against, or $null/omitted on the first run.
    .OUTPUTS
        [hashtable] @{ Success; Data=<diff>; Error }
        Diff = @{ Meta; Completion; Scope; Compliance; KpiDelta }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Current,
        [Parameter()][object]$Previous,
        # Display-only cadence label (Adjacent/IntraDay/Daily/Weekly/Monthly) chosen by the
        # caller when it selected $Previous; surfaced in the report headers.
        [Parameter()][string]$Cadence = 'Adjacent',
        # Cross-campaign: Current and Previous are DIFFERENT campaigns (today's daily attestation
        # vs yesterday's). The scope view (key = identity|access|source) is campaign-agnostic and
        # stays meaningful; the completion view is not a progression across two separate review
        # cycles, so its progress-deltas are suppressed.
        [Parameter()][switch]$CrossCampaign
    )
    try {
        $curMeta = Get-SPDiffProp $Current 'Meta'
        if ($null -eq $curMeta) { return @{ Success = $false; Data = $null; Error = 'Current snapshot has no Meta' } }
        $hasPrev  = ($null -ne $Previous)
        $prevMeta = if ($hasPrev) { Get-SPDiffProp $Previous 'Meta' } else { $null }
        # Completion deltas are a real "progression" only when comparing the SAME campaign over
        # time. On a baseline (no prior) OR in cross-campaign mode they are not meaningful.
        $completionIsProgress = $hasPrev -and -not $CrossCampaign

        $curItems = @(Get-SPDiffProp $Current 'Items' @())
        $prevItems = if ($hasPrev) { @(Get-SPDiffProp $Previous 'Items' @()) } else { @() }
        $curCerts = @(Get-SPDiffProp $Current 'Certs' @())
        $prevCerts = if ($hasPrev) { @(Get-SPDiffProp $Previous 'Certs' @()) } else { @() }

        $curMap  = ConvertTo-SPDiffMap  -Items $curItems
        $prevMap = ConvertTo-SPDiffMap  -Items $prevItems
        $curCertMap  = ConvertTo-SPDiffCertMap -Certs $curCerts
        $prevCertMap = ConvertTo-SPDiffCertMap -Certs $prevCerts

        # --- Completion view ---
        $reviewers = [System.Collections.Generic.List[object]]::new()
        $newlyCompleted = 0; $stalled = 0; $notStarted = 0; $outstanding = 0; $reassignedCount = 0
        foreach ($k in $curCertMap.Keys) {
            $cc = $curCertMap[$k]
            $pc = if ($prevCertMap.ContainsKey($k)) { $prevCertMap[$k] } else { $null }
            $cMade = [int](Get-SPDiffProp $cc 'DecisionsMade' 0)
            $cTot  = [int](Get-SPDiffProp $cc 'DecisionsTotal' 0)
            $cDone = [bool](Get-SPDiffProp $cc 'Completed' $false)
            $cSigned = [bool](Get-SPDiffProp $cc 'Signed' $false)
            $cDecidedAwaiting = [bool](Get-SPDiffProp $cc 'DecidedAwaitingSignoff' $false)
            $cRevId = [string](Get-SPDiffProp $cc 'ReviewerId' '')
            $pMade = if ($pc) { [int](Get-SPDiffProp $pc 'DecisionsMade' 0) } else { 0 }
            $pDone = if ($pc) { [bool](Get-SPDiffProp $pc 'Completed' $false) } else { $false }
            $pRevId = if ($pc) { [string](Get-SPDiffProp $pc 'ReviewerId' '') } else { '' }
            $delta = $cMade - $pMade
            $isNew  = $cDone -and -not $pDone
            $isNot  = ($cMade -eq 0)
            $isStall = (-not $cDone) -and ($delta -le 0) -and ($cTot -gt 0)
            # Reassigned: same cert, different effective reviewer than the prior capture.
            $isReassigned = ($pc -and $pRevId -and $cRevId -and ($pRevId -ne $cRevId))
            # When the completion view is not a progression (baseline with no prior, OR a
            # cross-campaign comparison of two separate review cycles), the delta-based signals are
            # NOT meaningful -- an already-signed cert is not "newly completed", and progress/stall/
            # reassign are undefined. Suppress them; absolute state (Completed / CompletionPct /
            # NotStarted / Outstanding) is still reported.
            if (-not $completionIsProgress) { $delta = 0; $isNew = $false; $isStall = $false; $isReassigned = $false }
            if ($isNew)  { $newlyCompleted++ }
            if (-not $cDone) { $outstanding++ }
            if ($isNot)  { $notStarted++ }
            if ($isStall -and -not $isNot) { $stalled++ }
            if ($isReassigned) { $reassignedCount++ }
            $pct = if ($cTot -gt 0) { [math]::Round($cMade * 100.0 / $cTot, 1) } else { 0 }
            $reviewers.Add([ordered]@{
                CertId         = [string](Get-SPDiffProp $cc 'CertId' '')
                ReviewerId     = $cRevId
                ReviewerName   = [string](Get-SPDiffProp $cc 'ReviewerName' '')
                PrevMade       = $pMade
                CurrMade       = $cMade
                MadeDelta      = $delta
                Total          = $cTot
                CompletionPct  = $pct
                Completed      = $cDone
                Signed         = $cSigned
                DecidedAwaitingSignoff = $cDecidedAwaiting
                NewlyCompleted = $isNew
                NotStarted     = $isNot
                Stalled        = ($isStall -and -not $isNot)
                Reassigned     = [bool]$isReassigned
                PrevReviewerId = $pRevId
                IsNew          = (-not $pc)
            })
        }
        # Per-reviewer (person) rollup: one human may hold several certs -- aggregate so
        # leadership gets a "is this person behind?" answer, not N partial rows.
        $byReviewer = @{}
        foreach ($r in $reviewers) {
            $rid = if ([string]::IsNullOrWhiteSpace($r.ReviewerId)) { '__unknown__' } else { $r.ReviewerId }
            if (-not $byReviewer.ContainsKey($rid)) {
                $byReviewer[$rid] = [ordered]@{ ReviewerId = $r.ReviewerId; ReviewerName = $r.ReviewerName; Certs = 0; Made = 0; Total = 0; Signed = 0; Reassigned = $false }
            }
            $agg = $byReviewer[$rid]
            $agg.Certs++; $agg.Made += [int]$r.CurrMade; $agg.Total += [int]$r.Total
            if ($r.Signed) { $agg.Signed++ }
            if ($r.Reassigned) { $agg.Reassigned = $true }
        }
        $reviewerRollup = [System.Collections.Generic.List[object]]::new()
        foreach ($rid in $byReviewer.Keys) {
            $agg = $byReviewer[$rid]
            $agg.CompletionPct = if ([int]$agg.Total -gt 0) { [math]::Round([int]$agg.Made * 100.0 / [int]$agg.Total, 1) } else { 0 }
            $reviewerRollup.Add($agg)
        }

        # --- Scope view ---
        # Source set present in the previous capture -- lets us tell "a whole new SOURCE
        # onboarded" from "an existing source granted new access" (very different events).
        $prevSourceSet = @{}
        foreach ($pi in $prevItems) {
            $sid = [string](Get-SPDiffProp $pi 'SourceId' '')
            if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string](Get-SPDiffProp $pi 'SourceName' '') }
            if (-not [string]::IsNullOrWhiteSpace($sid)) { $prevSourceSet[$sid] = $true }
        }
        $newSources = @{}
        $added = [System.Collections.Generic.List[object]]::new()
        $removed = [System.Collections.Generic.List[object]]::new()
        $changed = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $curMap.Keys) {
            $ci = $curMap[$k]
            if (-not $prevMap.ContainsKey($k)) {
                $sid = [string](Get-SPDiffProp $ci 'SourceId' '')
                if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string](Get-SPDiffProp $ci 'SourceName' '') }
                $fromNewSource = $hasPrev -and (-not [string]::IsNullOrWhiteSpace($sid)) -and (-not $prevSourceSet.ContainsKey($sid))
                if ($fromNewSource) { $newSources[$sid] = [string](Get-SPDiffProp $ci 'SourceName' '') }
                # annotate the item with its onboarding class (additive; doesn't affect the key)
                $cls = if ($fromNewSource) { 'NewSource' } else { 'NewGrant' }
                if ($ci -is [System.Collections.IDictionary]) { $ci['ChangeClass'] = $cls }
                else { try { $ci | Add-Member -NotePropertyName 'ChangeClass' -NotePropertyValue $cls -Force } catch { } }
                $added.Add($ci)
            }
            else {
                $pi = $prevMap[$k]
                $cd = [string](Get-SPDiffProp $ci 'Decision' '')
                $pd = [string](Get-SPDiffProp $pi 'Decision' '')
                if ($cd -ne $pd) {
                    $changed.Add([ordered]@{
                        Key          = $k
                        IdentityName = [string](Get-SPDiffProp $ci 'IdentityName' '')
                        AccessName   = [string](Get-SPDiffProp $ci 'AccessName' '')
                        AccessType   = [string](Get-SPDiffProp $ci 'AccessType' '')
                        SourceName   = [string](Get-SPDiffProp $ci 'SourceName' '')
                        Privileged   = [bool](Get-SPDiffProp $ci 'Privileged' $false)
                        PrevDecision = $pd
                        CurrDecision = $cd
                        # ReviewerId carried so the per-director split can attribute a decision
                        # change to the reviewer (manager) who owns the cert it belongs to.
                        ReviewerId   = [string](Get-SPDiffProp $ci 'ReviewerId' '')
                    })
                }
            }
        }
        foreach ($k in $prevMap.Keys) {
            if (-not $curMap.ContainsKey($k)) { $removed.Add($prevMap[$k]) }
        }

        # --- Compliance summary ---
        # Baseline run (no previous): suppress delta-shaped advisories so the first capture
        # doesn't fire "everything is newly-added/newly-approved" alarms at leadership.
        $newPriv = [System.Collections.Generic.List[object]]::new()
        if ($hasPrev) {
            foreach ($it in $added) { if ([bool](Get-SPDiffProp $it 'Privileged' $false)) { $newPriv.Add($it) } }
        }

        $stalledReviewers = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $reviewers) { if ($r.NotStarted -or $r.Stalled) { $stalledReviewers.Add($r) } }

        # True OVERDUE: PENDING now AND the campaign due date has passed (wall-clock, from
        # snapshot Meta.DueDate). This is the defensible "overdue" -- it references a deadline.
        $dueDate = $null
        $dueRaw = [string](Get-SPDiffProp $curMeta 'DueDate' '')
        if (-not [string]::IsNullOrWhiteSpace($dueRaw)) { try { $dueDate = [datetime]::Parse($dueRaw) } catch { $dueDate = $null } }
        $nowRef = $null
        $curCapForOverdue = [string](Get-SPDiffProp $curMeta 'CapturedAt' '')
        if ($curCapForOverdue) { try { $nowRef = [datetime]::Parse($curCapForOverdue) } catch { } }
        $overdue = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $dueDate -and $null -ne $nowRef -and $nowRef -gt $dueDate) {
            foreach ($k in $curMap.Keys) {
                $ci = $curMap[$k]
                if ([string](Get-SPDiffProp $ci 'Decision' '') -eq 'PENDING') { $overdue.Add($ci) }
            }
        }

        # PERSISTENTLY PENDING: PENDING now AND PENDING in the prior capture (undecided
        # across >= 2 captures). NOT a deadline breach -- a separate, softer signal.
        $persistentPending = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $curMap.Keys) {
            $ci = $curMap[$k]
            if ([string](Get-SPDiffProp $ci 'Decision' '') -ne 'PENDING') { continue }
            if ($prevMap.ContainsKey($k) -and [string](Get-SPDiffProp $prevMap[$k] 'Decision' '') -eq 'PENDING') {
                $persistentPending.Add($ci)
            }
        }

        # Privileged approved (advisory): privileged grants newly set to APPROVE this capture.
        # Suppressed on the baseline run (everything would look "newly approved").
        $privApproved = [System.Collections.Generic.List[object]]::new()
        if ($hasPrev) {
            foreach ($k in $curMap.Keys) {
                $ci = $curMap[$k]
                if (-not [bool](Get-SPDiffProp $ci 'Privileged' $false)) { continue }
                if ([string](Get-SPDiffProp $ci 'Decision' '') -ne 'APPROVE') { continue }
                $wasApprove = $prevMap.ContainsKey($k) -and ([string](Get-SPDiffProp $prevMap[$k] 'Decision' '') -eq 'APPROVE')
                if (-not $wasApprove) { $privApproved.Add($ci) }
            }
        }

        # --- KPI delta (cheap, from rolled-up Kpi) ---
        $curKpi = Get-SPDiffProp $Current 'Kpi'
        $prevKpi = if ($hasPrev) { Get-SPDiffProp $Previous 'Kpi' } else { $null }
        function _kd([object]$k, [string]$n) { if ($null -eq $k) { return 0 } return [int](Get-SPDiffProp $k $n 0) }
        $kpiDelta = [ordered]@{
            CurrApproved  = (_kd $curKpi 'Approved');  PrevApproved  = (_kd $prevKpi 'Approved')
            CurrRevoked   = (_kd $curKpi 'Revoked');   PrevRevoked   = (_kd $prevKpi 'Revoked')
            CurrPending   = (_kd $curKpi 'Pending');   PrevPending   = (_kd $prevKpi 'Pending')
            CurrPrivTotal = (_kd $curKpi 'PrivilegedTotal'); PrevPrivTotal = (_kd $prevKpi 'PrivilegedTotal')
            CurrCompletionPct = [double](Get-SPDiffProp $curKpi 'CompletionPct' 0)
            PrevCompletionPct = if ($prevKpi) { [double](Get-SPDiffProp $prevKpi 'CompletionPct' 0) } else { 0 }
        }

        $curCap = [string](Get-SPDiffProp $curMeta 'CapturedAt' '')
        $prevCap = if ($prevMeta) { [string](Get-SPDiffProp $prevMeta 'CapturedAt' '') } else { '' }
        $intervalHours = $null
        if ($curCap -and $prevCap) {
            try { $intervalHours = [math]::Round((([datetime]::Parse($curCap)) - ([datetime]::Parse($prevCap))).TotalHours, 1) } catch { }
        }

        $diff = @{
            Meta = [ordered]@{
                CampaignId        = [string](Get-SPDiffProp $curMeta 'CampaignId' '')
                CampaignName      = [string](Get-SPDiffProp $curMeta 'CampaignName' '')
                Status            = [string](Get-SPDiffProp $curMeta 'Status' '')
                CurrentCapturedAt = $curCap
                PreviousCapturedAt = $prevCap
                HasPrevious       = $hasPrev
                IntervalHours     = $intervalHours
                Cadence           = $Cadence
                CrossCampaign        = [bool]$CrossCampaign
                PreviousCampaignId   = if ($hasPrev) { [string](Get-SPDiffProp $prevMeta 'CampaignId' '') } else { '' }
                PreviousCampaignName = if ($hasPrev) { [string](Get-SPDiffProp $prevMeta 'CampaignName' '') } else { '' }
            }
            Completion = [ordered]@{
                Reviewers           = $reviewers.ToArray()
                ByReviewer          = $reviewerRollup.ToArray()
                NewlyCompletedCount = $newlyCompleted
                OutstandingCount    = $outstanding
                StalledCount        = $stalled
                NotStartedCount     = $notStarted
                ReassignedCount     = $reassignedCount
                PrevCompletionPct   = $kpiDelta.PrevCompletionPct
                CurrCompletionPct   = $kpiDelta.CurrCompletionPct
                CurrCompletionPctByReviewer = [double](Get-SPDiffProp $curKpi 'CompletionPctByReviewer' 0)
            }
            Scope = [ordered]@{
                Added               = $added.ToArray()
                Removed             = $removed.ToArray()
                Changed             = $changed.ToArray()
                AddedCount          = $added.Count
                RemovedCount        = $removed.Count
                ChangedCount        = $changed.Count
                AddedPrivilegedCount = $newPriv.Count
                NewSources          = @($newSources.Values)
                NewSourceCount      = $newSources.Count
            }
            Compliance = [ordered]@{
                NewlyAddedPrivileged = $newPriv.ToArray()
                StalledReviewers     = $stalledReviewers.ToArray()
                Overdue              = $overdue.ToArray()
                PersistentlyPending  = $persistentPending.ToArray()
                PrivilegedApproved   = $privApproved.ToArray()
            }
            KpiDelta = $kpiDelta
        }
        return @{ Success = $true; Data = $diff; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Compare-SPCampaignSnapshots failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: HTML exporters

function Export-SPCampaignCompletionDiffHtml {
    <#
    .SYNOPSIS
        Renders the completion-progress diff (who is attesting day over day).
    .PARAMETER Diff
        Output of Compare-SPCampaignSnapshots (.Data).
    .PARAMETER OutputPath
        Target .html file (or a directory; a filename is generated).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Diff,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $meta = $Diff.Meta; $comp = $Diff.Completion
        $title = "Campaign Completion Diff -- $($meta.CampaignName)"
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Get-SPDiffHtmlHead -Title $title))
        [void]$sb.Append("<h1>$(Get-SPDiffEnc $title)</h1>")
        if ($meta.HasPrevious) {
            $apart = if ($null -ne $meta.IntervalHours) { " ($($meta.IntervalHours)h apart)" } else { '' }
            $window = "$(Get-SPDiffEnc $meta.PreviousCapturedAt) &rarr; $(Get-SPDiffEnc $meta.CurrentCapturedAt)$apart"
        }
        else { $window = "First capture: $(Get-SPDiffEnc $meta.CurrentCapturedAt)" }
        $cadLabel = [string](Get-SPDiffProp $meta 'Cadence' 'Adjacent')
        $cadSuffix = if ($meta.HasPrevious -and $cadLabel) { " | Cadence: $(Get-SPDiffEnc $cadLabel)" } else { '' }
        [void]$sb.Append("<div class='meta'>Campaign $(Get-SPDiffEnc $meta.CampaignId) | Status $(Get-SPDiffEnc $meta.Status)$cadSuffix<br/>$window</div>")
        if (-not $meta.HasPrevious) { [void]$sb.Append("<div class='first'>No prior snapshot &mdash; this is the baseline capture. Progress deltas appear from the next run onward.</div>") }
        if (Get-SPDiffProp $meta 'CrossCampaign' $false) { [void]$sb.Append("<div class='first'>Cross-campaign comparison: <b>$(Get-SPDiffEnc (Get-SPDiffProp $meta 'PreviousCampaignName' ''))</b> &rarr; <b>$(Get-SPDiffEnc $meta.CampaignName)</b> &mdash; two SEPARATE campaigns. Completion below is each campaign's own state, NOT progress on one campaign (the prior column is suppressed). The <b>access added/removed</b> in the scope diff is the meaningful day-over-day view.</div>") }

        # KPIs
        $cp = $comp.CurrCompletionPct; $pp = $comp.PrevCompletionPct
        $pctDelta = [math]::Round($cp - $pp, 1)
        $pctSpan = if ($pctDelta -gt 0) { "<span class='up'>+$pctDelta pts</span>" } elseif ($pctDelta -lt 0) { "<span class='down'>$pctDelta pts</span>" } else { "<span class='flat'>0</span>" }
        [void]$sb.Append("<div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$cp%</span><span class='l'>Completion ($pctSpan)</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($comp.NewlyCompletedCount)</span><span class='l'>Newly completed</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($comp.OutstandingCount)</span><span class='l'>Still outstanding</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($comp.NotStartedCount)</span><span class='l'>Not started</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($comp.StalledCount)</span><span class='l'>Stalled (no progress)</span></div>")
        $rbr = if ($null -ne $comp.PSObject.Properties['CurrCompletionPctByReviewer']) { $comp.CurrCompletionPctByReviewer } else { (Get-SPDiffProp $comp 'CurrCompletionPctByReviewer' 0) }
        [void]$sb.Append("<div class='kpi'><span class='n'>$rbr%</span><span class='l'>Completion (by reviewer)</span></div>")
        [void]$sb.Append("</div>")
        [void]$sb.Append("<div class='note'>Two completion measures: by-decision (volume-weighted) and by-reviewer (people-weighted). A high by-decision % with a low by-reviewer % means a few large reviewers are masking a stalled majority.</div>")

        # Per-reviewer (person) rollup -- one human may hold several certs.
        $rollup = @(Get-SPDiffProp $comp 'ByReviewer' @())
        if (@($rollup).Count -gt 0) {
            [void]$sb.Append("<h2>By reviewer (person)</h2>")
            $rr = $rollup | Sort-Object @{ Expression = { [double](Get-SPDiffProp $_ 'CompletionPct' 0) } }
            [void]$sb.Append("<table><tr><th>Reviewer</th><th>Certs</th><th>Made</th><th>Total</th><th>Completion</th><th>Reassigned</th></tr>")
            foreach ($a in $rr) {
                $nm = [string](Get-SPDiffProp $a 'ReviewerName' ''); if ([string]::IsNullOrWhiteSpace($nm)) { $nm = [string](Get-SPDiffProp $a 'ReviewerId' 'Unknown') }
                $rf = if ([bool](Get-SPDiffProp $a 'Reassigned' $false)) { "<span class='badge b-chg'>REASSIGNED</span>" } else { '' }
                [void]$sb.Append("<tr><td>$(Get-SPDiffEnc $nm)</td><td>$(Get-SPDiffProp $a 'Certs' 0)</td><td>$(Get-SPDiffProp $a 'Made' 0)</td><td>$(Get-SPDiffProp $a 'Total' 0)</td><td>$(Get-SPDiffProp $a 'CompletionPct' 0)%</td><td>$rf</td></tr>")
            }
            [void]$sb.Append("</table>")
        }

        # Per-cert table (sorted: stalled/not-started first, then by completion asc)
        [void]$sb.Append("<h2>Certification progress</h2>")
        $rows = @($comp.Reviewers) | Sort-Object @{ Expression = { if ($_.NotStarted) { 0 } elseif ($_.Stalled) { 1 } elseif (-not $_.Completed) { 2 } else { 3 } } }, @{ Expression = { $_.CompletionPct } }
        if (@($rows).Count -eq 0) { [void]$sb.Append("<div class='empty'>No certifications in this capture.</div>") }
        else {
            [void]$sb.Append("<table><tr><th>Reviewer</th><th>Status</th><th>Made</th><th>&Delta; since prev</th><th>Total</th><th>Completion</th></tr>")
            foreach ($r in $rows) {
                $status = if ($r.Completed) { if ($r.Signed) { if ($r.NewlyCompleted) { "<span class='badge b-add'>NEWLY SIGNED</span>" } else { 'Signed' } } elseif ($r.DecidedAwaitingSignoff) { "<span class='badge b-chg'>DECIDED, AWAITING SIGN-OFF</span>" } else { 'Done' } }
                          elseif ($r.NotStarted) { "<span class='badge b-rem'>NOT STARTED</span>" }
                          elseif ($r.Stalled) { "<span class='badge b-chg'>STALLED</span>" }
                          else { 'In progress' }
                if ($r.Reassigned) { $status += " <span class='badge b-chg'>REASSIGNED</span>" }
                $nm = if ([string]::IsNullOrWhiteSpace($r.ReviewerName)) { $r.ReviewerId } else { $r.ReviewerName }
                [void]$sb.Append("<tr><td>$(Get-SPDiffEnc $nm)</td><td>$status</td><td>$($r.CurrMade)</td><td>$(Get-SPDiffDelta ([int]$r.MadeDelta))</td><td>$($r.Total)</td><td>$($r.CompletionPct)%</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append("<div class='note'>Read-only progress view. 'Signed' is the audit-authoritative attestation; 'decided, awaiting sign-off' means all decisions were entered but the reviewer has not certified. Stalled may reflect timing/OOO &mdash; not a finding. No reassignment or escalation is performed by this report.</div>")
        [void]$sb.Append("</body></html>")

        $file = Resolve-SPDiffOutFile -OutputPath $OutputPath -Default ("completion-diff-{0}.html" -f (Get-SPDiffStamp $meta))
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $utf8)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCampaignCompletionDiffHtml failed: $($_.Exception.Message)" } }
}

function Export-SPCampaignScopeDiffHtml {
    <#
    .SYNOPSIS
        Renders the scope-change diff (new/removed/changed access) + compliance summary.
    .PARAMETER Diff
        Output of Compare-SPCampaignSnapshots (.Data).
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Diff,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $meta = $Diff.Meta; $scope = $Diff.Scope; $comp = $Diff.Compliance
        $title = "Campaign Scope Diff -- $($meta.CampaignName)"
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Get-SPDiffHtmlHead -Title $title))
        [void]$sb.Append("<h1>$(Get-SPDiffEnc $title)</h1>")
        $window = if ($meta.HasPrevious) { "$(Get-SPDiffEnc $meta.PreviousCapturedAt) &rarr; $(Get-SPDiffEnc $meta.CurrentCapturedAt)" } else { "First capture: $(Get-SPDiffEnc $meta.CurrentCapturedAt)" }
        $cadLabel = [string](Get-SPDiffProp $meta 'Cadence' 'Adjacent')
        $cadSuffix = if ($meta.HasPrevious -and $cadLabel) { " | Cadence: $(Get-SPDiffEnc $cadLabel)" } else { '' }
        [void]$sb.Append("<div class='meta'>Campaign $(Get-SPDiffEnc $meta.CampaignId) | Status $(Get-SPDiffEnc $meta.Status)$cadSuffix<br/>$window</div>")
        if (-not $meta.HasPrevious) { [void]$sb.Append("<div class='first'>No prior snapshot &mdash; everything below is reported as the baseline (added). Add/remove deltas become meaningful from the next run.</div>") }
        if (Get-SPDiffProp $meta 'CrossCampaign' $false) { [void]$sb.Append("<div class='first'>Cross-campaign comparison: <b>$(Get-SPDiffEnc (Get-SPDiffProp $meta 'PreviousCampaignName' ''))</b> &rarr; <b>$(Get-SPDiffEnc $meta.CampaignName)</b>. <b>Added</b> = access in scope today that was not in the prior campaign; <b>Removed</b> = was in the prior campaign, not today. This is the day-over-day access drift across your two daily campaigns.</div>") }

        # KPIs
        [void]$sb.Append("<div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($scope.AddedCount)</span><span class='l'>Added to scope</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($scope.RemovedCount)</span><span class='l'>Removed from scope</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($scope.ChangedCount)</span><span class='l'>Decision changed</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($scope.AddedPrivilegedCount)</span><span class='l'>New privileged</span></div>")
        [void]$sb.Append("</div>")

        # Compliance summary band
        [void]$sb.Append("<h2>Compliance signals</h2>")
        [void]$sb.Append("<table><tr><th>Signal</th><th>Count</th><th>Notes</th></tr>")
        [void]$sb.Append("<tr><td>Newly-added privileged access</td><td>$(@($comp.NewlyAddedPrivileged).Count)</td><td>New privileged grants in scope this capture.</td></tr>")
        [void]$sb.Append("<tr><td>Stalled / not-started reviewers</td><td>$(@($comp.StalledReviewers).Count)</td><td>No progress between captures or zero decisions made &mdash; context required (timing/OOO), not a finding.</td></tr>")
        [void]$sb.Append("<tr><td>Overdue (past due date)</td><td>$(@($comp.Overdue).Count)</td><td>PENDING and the campaign due date has passed.</td></tr>")
        [void]$sb.Append("<tr><td>Persistently pending</td><td>$(@($comp.PersistentlyPending).Count)</td><td>Still PENDING across at least two captures (not necessarily past due).</td></tr>")
        [void]$sb.Append("<tr><td>Privileged approved (advisory)</td><td>$(@($comp.PrivilegedApproved).Count)</td><td>Privileged grants newly set to APPROVE &mdash; a maturity signal, not an accusation.</td></tr>")
        [void]$sb.Append("</table>")
        if (-not $meta.HasPrevious) { [void]$sb.Append("<div class='note'>Baseline run: delta-based advisories (newly-added privileged, privileged-approved) are suppressed until the next capture.</div>") }
        if (@($scope.NewSources).Count -gt 0) { [void]$sb.Append("<div class='note'>Sources onboarded this capture: $(Get-SPDiffEnc (@($scope.NewSources) -join ', ')) &mdash; their grants are expected additions, not anomalies.</div>") }
        [void]$sb.Append("<div class='note'>Approving privileged access can be entirely legitimate. This count is a conversation starter for review quality, reviewed respectfully alongside review-velocity context &mdash; never an automatic finding.</div>")

        # Added (privileged first)
        [void]$sb.Append("<h2>Added to scope ($($scope.AddedCount))</h2>")
        Append-SPScopeItemTable -Sb $sb -Items @($scope.Added) -ShowDecision
        # Newly-added privileged callout
        if (@($comp.NewlyAddedPrivileged).Count -gt 0) {
            [void]$sb.Append("<h2>&#9888; Newly-added privileged access ($(@($comp.NewlyAddedPrivileged).Count))</h2>")
            Append-SPScopeItemTable -Sb $sb -Items @($comp.NewlyAddedPrivileged) -ShowDecision -ForcePriv
        }
        # Removed
        [void]$sb.Append("<h2>Removed from scope ($($scope.RemovedCount))</h2>")
        Append-SPScopeItemTable -Sb $sb -Items @($scope.Removed) -ShowDecision
        # Changed
        [void]$sb.Append("<h2>Decision changed ($($scope.ChangedCount))</h2>")
        if (@($scope.Changed).Count -eq 0) { [void]$sb.Append("<div class='empty'>No decision changes.</div>") }
        else {
            [void]$sb.Append("<table><tr><th>Identity</th><th>Access</th><th>Source</th><th>Was</th><th>Now</th></tr>")
            foreach ($c in @($scope.Changed)) {
                $cls = if ($c.Privileged) { " class='priv'" } else { '' }
                $pb = if ($c.Privileged) { " <span class='badge b-priv'>PRIV</span>" } else { '' }
                [void]$sb.Append("<tr$cls><td>$(Get-SPDiffEnc $c.IdentityName)</td><td>$(Get-SPDiffEnc $c.AccessName)$pb</td><td>$(Get-SPDiffEnc $c.SourceName)</td><td>$(Get-SPDiffEnc $c.PrevDecision)</td><td>$(Get-SPDiffEnc $c.CurrDecision)</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append("<div class='note'>Read-only scope view. No reassignment or escalation is performed by this report.</div>")
        [void]$sb.Append("</body></html>")

        $file = Resolve-SPDiffOutFile -OutputPath $OutputPath -Default ("scope-diff-{0}.html" -f (Get-SPDiffStamp $meta))
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $utf8)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCampaignScopeDiffHtml failed: $($_.Exception.Message)" } }
}

function Append-SPScopeItemTable {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        [Parameter()][object[]]$Items = @(),
        [switch]$ShowDecision,
        [switch]$ForcePriv
    )
    $items = @($Items)
    if ($items.Count -eq 0) { [void]$Sb.Append("<div class='empty'>None.</div>"); return }
    $decCol = if ($ShowDecision) { '<th>Decision</th>' } else { '' }
    [void]$Sb.Append("<table><tr><th>Identity</th><th>Access</th><th>Source</th>$decCol</tr>")
    # privileged first
    $sorted = $items | Sort-Object @{ Expression = { if ([bool](Get-SPDiffProp $_ 'Privileged' $false)) { 0 } else { 1 } } }, @{ Expression = { [string](Get-SPDiffProp $_ 'AccessName' '') } }
    foreach ($it in $sorted) {
        $priv = $ForcePriv -or [bool](Get-SPDiffProp $it 'Privileged' $false)
        $cls = if ($priv) { " class='priv'" } else { '' }
        $pb  = if ($priv) { " <span class='badge b-priv'>PRIV</span>" } else { '' }
        $dec = if ($ShowDecision) { "<td>$(Get-SPDiffEnc (Get-SPDiffProp $it 'Decision' ''))</td>" } else { '' }
        [void]$Sb.Append("<tr$cls><td>$(Get-SPDiffEnc (Get-SPDiffProp $it 'IdentityName' ''))</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $it 'AccessName' ''))$pb</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $it 'SourceName' ''))</td>$dec</tr>")
    }
    [void]$Sb.Append("</table>")
}

#endregion

#region Public: CSV exporter

function Export-SPCampaignDiffCsv {
    <#
    .SYNOPSIS
        Writes flat CSVs for the diff -- a completion CSV and a scope CSV -- for Excel /
        leadership consumption.
    .PARAMETER Diff
        Output of Compare-SPCampaignSnapshots (.Data).
    .PARAMETER OutputDir
        Directory to write {completion,scope}-diff-<stamp>.csv into.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ CompletionCsv; ScopeCsv }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Diff,
        [Parameter(Mandatory)][string]$OutputDir
    )
    try {
        if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force -WhatIf:$false | Out-Null }
        $meta = $Diff.Meta
        $stamp = Get-SPDiffStamp $meta
        $campSafe = ([string]$meta.CampaignId) -replace '[^A-Za-z0-9_\-]', '_'

        $completionRows = foreach ($r in @($Diff.Completion.Reviewers)) {
            [PSCustomObject]@{
                CampaignId    = $meta.CampaignId
                CampaignName  = $meta.CampaignName
                CapturedAt    = $meta.CurrentCapturedAt
                ReviewerName  = $r.ReviewerName
                ReviewerId    = $r.ReviewerId
                CertId        = $r.CertId
                PrevMade      = $r.PrevMade
                CurrMade      = $r.CurrMade
                MadeDelta     = $r.MadeDelta
                Total         = $r.Total
                CompletionPct = $r.CompletionPct
                Completed     = $r.Completed
                Signed        = $r.Signed
                DecidedAwaitingSignoff = $r.DecidedAwaitingSignoff
                NewlyCompleted= $r.NewlyCompleted
                NotStarted    = $r.NotStarted
                Stalled       = $r.Stalled
                Reassigned    = $r.Reassigned
            }
        }
        $completionCsv = Join-Path $OutputDir "completion-diff-$campSafe-$stamp.csv"
        # Pin an explicit, identical column set/order on every row -- PS 5.1 Export-Csv
        # throws "Argument types do not match" when objects in a List[object] disagree on
        # member ordering. -Property <list> forces a stable projection.
        $completionCols = @('CampaignId','CampaignName','CapturedAt','ReviewerName','ReviewerId','CertId','PrevMade','CurrMade','MadeDelta','Total','CompletionPct','Completed','Signed','DecidedAwaitingSignoff','NewlyCompleted','NotStarted','Stalled','Reassigned')
        @($completionRows) | Select-Object -Property $completionCols | Export-Csv -Path $completionCsv -NoTypeInformation -Encoding UTF8 -WhatIf:$false

        $scopeRows = New-Object System.Collections.Generic.List[object]
        foreach ($it in @($Diff.Scope.Added))   { $scopeRows.Add((New-SPScopeCsvRow -Meta $meta -Item $it -Change 'Added')) }
        foreach ($it in @($Diff.Scope.Removed)) { $scopeRows.Add((New-SPScopeCsvRow -Meta $meta -Item $it -Change 'Removed')) }
        foreach ($c in @($Diff.Scope.Changed)) {
            $row = New-SPScopeCsvRow -Meta $meta -Item $c -Change 'Changed'
            $row.PrevDecision = $c.PrevDecision; $row.CurrDecision = $c.CurrDecision
            $scopeRows.Add($row)
        }
        $scopeCsv = Join-Path $OutputDir "scope-diff-$campSafe-$stamp.csv"
        $scopeCols = @('CampaignId','CampaignName','CapturedAt','Change','ChangeClass','IdentityName','IdentityId','AccessName','SourceName','Privileged','PrivilegedSource','Decision','PrevDecision','CurrDecision','Key')
        # Pipe the List via .ToArray(): wrapping a generic List in @(...) breaks the
        # downstream Select-Object/Export-Csv binding in PS 5.1 ("Argument types do not match").
        $scopeRows.ToArray() | Select-Object -Property $scopeCols | Export-Csv -Path $scopeCsv -NoTypeInformation -Encoding UTF8 -WhatIf:$false

        return @{ Success = $true; Data = @{ CompletionCsv = $completionCsv; ScopeCsv = $scopeCsv }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCampaignDiffCsv failed: $($_.Exception.Message)" } }
}

function New-SPScopeCsvRow {
    param([object]$Meta, [object]$Item, [string]$Change)
    [PSCustomObject]@{
        CampaignId   = $Meta.CampaignId
        CampaignName = $Meta.CampaignName
        CapturedAt   = $Meta.CurrentCapturedAt
        Change       = $Change
        ChangeClass  = [string](Get-SPDiffProp $Item 'ChangeClass' '')
        IdentityName = [string](Get-SPDiffProp $Item 'IdentityName' '')
        IdentityId   = [string](Get-SPDiffProp $Item 'IdentityId' '')
        AccessName   = [string](Get-SPDiffProp $Item 'AccessName' '')
        SourceName   = [string](Get-SPDiffProp $Item 'SourceName' '')
        Privileged   = [bool](Get-SPDiffProp $Item 'Privileged' $false)
        PrivilegedSource = [string](Get-SPDiffProp $Item 'PrivilegedSource' '')
        Decision     = [string](Get-SPDiffProp $Item 'Decision' '')
        PrevDecision = ''
        CurrDecision = ''
        Key          = [string](Get-SPDiffProp $Item 'Key' '')
    }
}

#endregion

#region Internal: output path helpers

function Get-SPDiffStamp {
    param([object]$Meta)
    $cap = [string](Get-SPDiffProp $Meta 'CurrentCapturedAt' '')
    if ([string]::IsNullOrWhiteSpace($cap)) { $cap = [string](Get-SPDiffProp $Meta 'CapturedAt' '') }
    try { return ([datetime]::Parse($cap)).ToString('yyyy-MM-ddTHHmmss') } catch { return 'snapshot' }
}

function Resolve-SPDiffOutFile {
    param([string]$OutputPath, [string]$Default)
    # If OutputPath ends in .html treat as a file; otherwise treat as a directory.
    if ($OutputPath -match '\.html?$') {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
        return $OutputPath
    }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
    return (Join-Path $OutputPath $Default)
}

#endregion

#region Public: per-director diff (one HTML per director)

function Resolve-SPDiffDirector {
    # The 'director' for a cert reviewer = the reviewer's MANAGER (one level up in the org tree):
    # the person who should receive a report of what changed across their team's attestations.
    # Returns @{ Id; Name }. Reviewers with no manager in the tree fall into a shared bucket.
    param([object]$Nodes, [string]$ReviewerId)
    if (-not [string]::IsNullOrWhiteSpace($ReviewerId) -and $null -ne $Nodes -and ($Nodes -is [System.Collections.IDictionary]) -and $Nodes.Contains($ReviewerId)) {
        $n   = $Nodes[$ReviewerId]
        $idn = Get-SPDiffProp $n 'Identity'
        $mid = [string](Get-SPDiffProp $n 'ManagerId' '')
        if ([string]::IsNullOrWhiteSpace($mid)) { $mid = [string](Get-SPDiffProp $idn 'ManagerId' '') }
        if (-not [string]::IsNullOrWhiteSpace($mid)) {
            $dname = ''
            if ($Nodes.Contains($mid)) { $dname = [string](Get-SPDiffProp (Get-SPDiffProp $Nodes[$mid] 'Identity') 'Name' '') }
            if ([string]::IsNullOrWhiteSpace($dname)) { $dname = [string](Get-SPDiffProp $idn 'ManagerName' '') }
            if ([string]::IsNullOrWhiteSpace($dname)) { $dname = $mid }
            return @{ Id = $mid; Name = $dname }
        }
    }
    return @{ Id = '__unassigned__'; Name = 'Unassigned (reviewer has no manager in the org tree)' }
}

function Split-SPCampaignDiffByDirector {
    <#
    .SYNOPSIS
        Slices a campaign diff into per-director views. Each director (a reviewer's manager) gets
        the completion progress of the reviewers reporting to them + the access added/removed/
        changed for those reviewers' certs. PURE: diff + org tree in, sliced views out.
    .PARAMETER Diff
        Output of Compare-SPCampaignSnapshots (.Data).
    .PARAMETER OrgTree
        .Data from Build-SPOrgTree, built on the diff's reviewer identity ids.
    .OUTPUTS
        [hashtable] @{ Meta; Directors=@(@{DirectorId;DirectorName;Reviewers;Added;Removed;Changed;NewlyAddedPrivileged;Counts}) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Diff,
        [Parameter(Mandatory)][object]$OrgTree
    )
    $nodes = Get-SPDiffProp $OrgTree 'Nodes'
    if ($null -eq $nodes) { $nodes = @{} }

    $completion = Get-SPDiffProp $Diff 'Completion'
    $scope      = Get-SPDiffProp $Diff 'Scope'
    $comp       = Get-SPDiffProp $Diff 'Compliance'

    # Pass A: gather every reviewer id that appears anywhere in the diff.
    $revIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in @(Get-SPDiffProp $completion 'Reviewers' @())) { [void]$revIds.Add([string](Get-SPDiffProp $r 'ReviewerId' '')) }
    foreach ($sk in @('Added', 'Removed', 'Changed')) { foreach ($it in @(Get-SPDiffProp $scope $sk @())) { [void]$revIds.Add([string](Get-SPDiffProp $it 'ReviewerId' '')) } }
    foreach ($it in @(Get-SPDiffProp $comp 'NewlyAddedPrivileged' @())) { [void]$revIds.Add([string](Get-SPDiffProp $it 'ReviewerId' '')) }

    # Pass B: resolve each reviewer -> director and create an (ordered) bucket per director.
    $dirOf   = @{}
    $buckets = [ordered]@{}
    foreach ($rid in $revIds) {
        $d = Resolve-SPDiffDirector -Nodes $nodes -ReviewerId $rid
        $dirOf[$rid] = $d
        if (-not $buckets.Contains($d.Id)) {
            $buckets[$d.Id] = [ordered]@{
                DirectorId           = $d.Id
                DirectorName         = $d.Name
                Reviewers            = [System.Collections.Generic.List[object]]::new()
                Added                = [System.Collections.Generic.List[object]]::new()
                Removed              = [System.Collections.Generic.List[object]]::new()
                Changed              = [System.Collections.Generic.List[object]]::new()
                NewlyAddedPrivileged = [System.Collections.Generic.List[object]]::new()
            }
        }
    }

    # Pass C: distribute each payload into its director's bucket.
    foreach ($r in @(Get-SPDiffProp $completion 'Reviewers' @())) { $buckets[$dirOf[[string](Get-SPDiffProp $r 'ReviewerId' '')].Id].Reviewers.Add($r) }
    foreach ($it in @(Get-SPDiffProp $scope 'Added' @()))   { $buckets[$dirOf[[string](Get-SPDiffProp $it 'ReviewerId' '')].Id].Added.Add($it) }
    foreach ($it in @(Get-SPDiffProp $scope 'Removed' @()))  { $buckets[$dirOf[[string](Get-SPDiffProp $it 'ReviewerId' '')].Id].Removed.Add($it) }
    foreach ($it in @(Get-SPDiffProp $scope 'Changed' @()))  { $buckets[$dirOf[[string](Get-SPDiffProp $it 'ReviewerId' '')].Id].Changed.Add($it) }
    foreach ($it in @(Get-SPDiffProp $comp 'NewlyAddedPrivileged' @())) { $buckets[$dirOf[[string](Get-SPDiffProp $it 'ReviewerId' '')].Id].NewlyAddedPrivileged.Add($it) }

    # Finalize: arrays + per-director counts; sort by name with the unassigned bucket last.
    $dirs = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $buckets.Keys) {
        $b = $buckets[$id]
        $revs = @($b.Reviewers)
        $dirs.Add([ordered]@{
            DirectorId           = $b.DirectorId
            DirectorName         = $b.DirectorName
            Reviewers            = $revs
            Added                = @($b.Added)
            Removed              = @($b.Removed)
            Changed              = @($b.Changed)
            NewlyAddedPrivileged = @($b.NewlyAddedPrivileged)
            Counts = [ordered]@{
                Reviewers       = $revs.Count
                Added           = @($b.Added).Count
                Removed         = @($b.Removed).Count
                Changed         = @($b.Changed).Count
                AddedPrivileged = @($b.NewlyAddedPrivileged).Count
                NewlyCompleted  = @($revs | Where-Object { [bool](Get-SPDiffProp $_ 'NewlyCompleted' $false) }).Count
                Stalled         = @($revs | Where-Object { [bool](Get-SPDiffProp $_ 'Stalled' $false) }).Count
                NotStarted      = @($revs | Where-Object { [bool](Get-SPDiffProp $_ 'NotStarted' $false) }).Count
                Outstanding     = @($revs | Where-Object { -not [bool](Get-SPDiffProp $_ 'Completed' $false) }).Count
            }
        })
    }
    $sorted = @($dirs | Sort-Object `
        @{ Expression = { if ($_.DirectorId -eq '__unassigned__') { 1 } else { 0 } } }, `
        @{ Expression = { [string]$_.DirectorName } })

    return @{ Meta = (Get-SPDiffProp $Diff 'Meta'); Directors = $sorted }
}

function Get-SPDiffDirectorBodyHtml {
    # Renders one director's change report (completion of their reviewers + scope changes).
    param([object]$Director, [object]$Meta, [string]$Window)
    $d = $Director; $c = $d.Counts
    $title = "Attestation Change Report -- $($d.DirectorName)"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Get-SPDiffHtmlHead -Title $title))
    [void]$sb.Append("<h1>$(Get-SPDiffEnc $title)</h1>")
    $cad = [string](Get-SPDiffProp $Meta 'Cadence' 'Adjacent')
    [void]$sb.Append("<div class='meta'>Campaign $(Get-SPDiffEnc $Meta.CampaignName) ($(Get-SPDiffEnc $Meta.CampaignId)) | Status $(Get-SPDiffEnc $Meta.Status) | Cadence $(Get-SPDiffEnc $cad)<br/>$Window</div>")
    if (-not $Meta.HasPrevious) { [void]$sb.Append("<div class='first'>First capture &mdash; baseline. Add/remove deltas become meaningful from the next run.</div>") }
    if (Get-SPDiffProp $Meta 'CrossCampaign' $false) { [void]$sb.Append("<div class='first'>Cross-campaign: <b>$(Get-SPDiffEnc (Get-SPDiffProp $Meta 'PreviousCampaignName' ''))</b> &rarr; <b>$(Get-SPDiffEnc $Meta.CampaignName)</b>. Access added/removed is the day-over-day change; completion reflects today's campaign only.</div>") }

    [void]$sb.Append("<div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.Reviewers)</span><span class='l'>Reviewers (your team)</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.NewlyCompleted)</span><span class='l'>Newly completed</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.Outstanding)</span><span class='l'>Outstanding</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.Added)</span><span class='l'>Access added</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.Removed)</span><span class='l'>Access removed</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n'>$($c.AddedPrivileged)</span><span class='l'>New privileged</span></div>")
    [void]$sb.Append("</div>")

    [void]$sb.Append("<h2>Reviewer progress ($($c.Reviewers))</h2>")
    $revs = @($d.Reviewers)
    if ($revs.Count -eq 0) { [void]$sb.Append("<div class='empty'>No reviewers mapped to you in this campaign.</div>") }
    else {
        [void]$sb.Append("<table><tr><th>Reviewer</th><th>Made (delta)</th><th>Total</th><th>Completion</th><th>Status</th></tr>")
        foreach ($r in ($revs | Sort-Object @{ Expression = { [double](Get-SPDiffProp $_ 'CompletionPct' 0) } })) {
            $made  = [int](Get-SPDiffProp $r 'CurrMade' 0)
            $delta = [int](Get-SPDiffProp $r 'MadeDelta' 0)
            $total = [int](Get-SPDiffProp $r 'Total' 0)
            $pct   = [double](Get-SPDiffProp $r 'CompletionPct' 0)
            $status = if ([bool](Get-SPDiffProp $r 'NewlyCompleted' $false)) { "<span class='up'>Newly completed</span>" }
                      elseif ([bool](Get-SPDiffProp $r 'Signed' $false) -or [bool](Get-SPDiffProp $r 'Completed' $false)) { 'Completed' }
                      elseif ([bool](Get-SPDiffProp $r 'NotStarted' $false)) { "<span class='down'>Not started</span>" }
                      elseif ([bool](Get-SPDiffProp $r 'Stalled' $false)) { "<span class='down'>Stalled</span>" }
                      else { 'In progress' }
            [void]$sb.Append("<tr><td>$(Get-SPDiffEnc (Get-SPDiffProp $r 'ReviewerName' ''))</td><td>$made ($(Get-SPDiffDelta $delta))</td><td>$total</td><td>$([math]::Round($pct,1))%</td><td>$status</td></tr>")
        }
        [void]$sb.Append("</table>")
    }

    [void]$sb.Append("<h2>Access added to scope ($($c.Added))</h2>")
    Append-SPScopeItemTable -Sb $sb -Items @($d.Added) -ShowDecision
    if (@($d.NewlyAddedPrivileged).Count -gt 0) {
        [void]$sb.Append("<h2>&#9888; Newly-added privileged access ($($c.AddedPrivileged))</h2>")
        Append-SPScopeItemTable -Sb $sb -Items @($d.NewlyAddedPrivileged) -ShowDecision -ForcePriv
    }
    [void]$sb.Append("<h2>Access removed from scope ($($c.Removed))</h2>")
    Append-SPScopeItemTable -Sb $sb -Items @($d.Removed) -ShowDecision
    [void]$sb.Append("<h2>Decision changed ($($c.Changed))</h2>")
    if (@($d.Changed).Count -eq 0) { [void]$sb.Append("<div class='empty'>No decision changes.</div>") }
    else {
        [void]$sb.Append("<table><tr><th>Identity</th><th>Access</th><th>Source</th><th>Was</th><th>Now</th></tr>")
        foreach ($ch in @($d.Changed)) {
            $priv = [bool](Get-SPDiffProp $ch 'Privileged' $false)
            $cls = if ($priv) { " class='priv'" } else { '' }
            $pb  = if ($priv) { " <span class='badge b-priv'>PRIV</span>" } else { '' }
            [void]$sb.Append("<tr$cls><td>$(Get-SPDiffEnc (Get-SPDiffProp $ch 'IdentityName' ''))</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $ch 'AccessName' ''))$pb</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $ch 'SourceName' ''))</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $ch 'PrevDecision' ''))</td><td>$(Get-SPDiffEnc (Get-SPDiffProp $ch 'CurrDecision' ''))</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    [void]$sb.Append("<div class='note'>Read-only change report for your org. No reassignment or escalation is performed. 'Newly completed' / 'Stalled' are context signals (timing / out-of-office), not findings.</div>")
    [void]$sb.Append("</body></html>")
    return $sb.ToString()
}

function Export-SPCampaignDiffByDirectorHtml {
    <#
    .SYNOPSIS
        Writes ONE HTML file per director (their team's attestation progress + access changes),
        plus an index.html, suitable for sending to each director individually.
    .PARAMETER Diff
        Output of Compare-SPCampaignSnapshots (.Data).
    .PARAMETER OrgTree
        .Data from Build-SPOrgTree (built on the diff's reviewer ids).
    .PARAMETER OutputPath
        Directory under which a per-director-<stamp> run folder is created.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ RunDir; Index; Files; DirectorCount }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Diff,
        [Parameter(Mandatory)][object]$OrgTree,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $split = Split-SPCampaignDiffByDirector -Diff $Diff -OrgTree $OrgTree
        $meta  = $split.Meta
        $stamp = Get-SPDiffStamp $meta
        $runDir = Join-Path $OutputPath ("per-director-" + $stamp)
        if (-not (Test-Path $runDir)) { New-Item -Path $runDir -ItemType Directory -Force -WhatIf:$false | Out-Null }

        $window = if ($meta.HasPrevious) { "$(Get-SPDiffEnc $meta.PreviousCapturedAt) &rarr; $(Get-SPDiffEnc $meta.CurrentCapturedAt)" } else { "First capture: $(Get-SPDiffEnc $meta.CurrentCapturedAt)" }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $files = [System.Collections.Generic.List[string]]::new()

        foreach ($d in @($split.Directors)) {
            $safe = ([string]$d.DirectorName) -replace '[^A-Za-z0-9_\-]', '_'
            if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'director' }
            $file = Join-Path $runDir ("director-diff-$safe.html")
            $d['File'] = (Split-Path $file -Leaf)   # for the index links
            [System.IO.File]::WriteAllText($file, (Get-SPDiffDirectorBodyHtml -Director $d -Meta $meta -Window $window), $utf8)
            [void]$files.Add($file)
        }

        # Index: campaign header + a roster row per director linking their file.
        $title = "Per-Director Attestation Change Reports -- $($meta.CampaignName)"
        $ib = New-Object System.Text.StringBuilder
        [void]$ib.Append((Get-SPDiffHtmlHead -Title $title))
        [void]$ib.Append("<h1>$(Get-SPDiffEnc $title)</h1>")
        [void]$ib.Append("<div class='meta'>$window | $(@($split.Directors).Count) director report(s)</div>")
        [void]$ib.Append("<table><tr><th>Director</th><th>Reviewers</th><th>Newly completed</th><th>Outstanding</th><th>Added</th><th>Removed</th><th>Changed</th><th>New priv</th><th>Report</th></tr>")
        foreach ($d in @($split.Directors)) {
            $c = $d.Counts
            $fn = [string](Get-SPDiffProp $d 'File' '')
            $link = if ($fn) { "<a href='$(Get-SPDiffEnc $fn)'>$(Get-SPDiffEnc $fn)</a>" } else { '' }
            [void]$ib.Append("<tr><td>$(Get-SPDiffEnc $d.DirectorName)</td><td>$($c.Reviewers)</td><td>$($c.NewlyCompleted)</td><td>$($c.Outstanding)</td><td>$($c.Added)</td><td>$($c.Removed)</td><td>$($c.Changed)</td><td>$($c.AddedPrivileged)</td><td>$link</td></tr>")
        }
        [void]$ib.Append("</table>")
        [void]$ib.Append("<div class='note'>One HTML file per director &mdash; their team's attestation progress + access changes &mdash; suitable to send individually. Read-only; no reassignment or escalation.</div>")
        [void]$ib.Append("</body></html>")
        $indexPath = Join-Path $runDir 'index.html'
        [System.IO.File]::WriteAllText($indexPath, $ib.ToString(), $utf8)

        return @{ Success = $true; Data = @{ RunDir = $runDir; Index = $indexPath; Files = @($files); DirectorCount = @($split.Directors).Count }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCampaignDiffByDirectorHtml failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'Compare-SPCampaignSnapshots',
    'Export-SPCampaignCompletionDiffHtml',
    'Export-SPCampaignScopeDiffHtml',
    'Export-SPCampaignDiffCsv',
    'Split-SPCampaignDiffByDirector',
    'Export-SPCampaignDiffByDirectorHtml'
)
