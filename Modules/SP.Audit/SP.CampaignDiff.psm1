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
        [Parameter()][object]$Previous
    )
    try {
        $curMeta = Get-SPDiffProp $Current 'Meta'
        if ($null -eq $curMeta) { return @{ Success = $false; Data = $null; Error = 'Current snapshot has no Meta' } }
        $hasPrev  = ($null -ne $Previous)
        $prevMeta = if ($hasPrev) { Get-SPDiffProp $Previous 'Meta' } else { $null }

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
        $newlyCompleted = 0; $stalled = 0; $notStarted = 0; $outstanding = 0
        foreach ($k in $curCertMap.Keys) {
            $cc = $curCertMap[$k]
            $pc = if ($prevCertMap.ContainsKey($k)) { $prevCertMap[$k] } else { $null }
            $cMade = [int](Get-SPDiffProp $cc 'DecisionsMade' 0)
            $cTot  = [int](Get-SPDiffProp $cc 'DecisionsTotal' 0)
            $cDone = [bool](Get-SPDiffProp $cc 'Completed' $false)
            $pMade = if ($pc) { [int](Get-SPDiffProp $pc 'DecisionsMade' 0) } else { 0 }
            $pDone = if ($pc) { [bool](Get-SPDiffProp $pc 'Completed' $false) } else { $false }
            $delta = $cMade - $pMade
            $isNew  = $cDone -and -not $pDone
            $isNot  = ($cMade -eq 0)
            $isStall = (-not $cDone) -and ($delta -le 0) -and ($cTot -gt 0)
            if ($isNew)  { $newlyCompleted++ }
            if (-not $cDone) { $outstanding++ }
            if ($isNot)  { $notStarted++ }
            if ($isStall -and -not $isNot) { $stalled++ }
            $pct = if ($cTot -gt 0) { [math]::Round($cMade * 100.0 / $cTot, 1) } else { 0 }
            $reviewers.Add([ordered]@{
                CertId         = [string](Get-SPDiffProp $cc 'CertId' '')
                ReviewerId     = [string](Get-SPDiffProp $cc 'ReviewerId' '')
                ReviewerName   = [string](Get-SPDiffProp $cc 'ReviewerName' '')
                PrevMade       = $pMade
                CurrMade       = $cMade
                MadeDelta      = $delta
                Total          = $cTot
                CompletionPct  = $pct
                Completed      = $cDone
                NewlyCompleted = $isNew
                NotStarted     = $isNot
                Stalled        = ($isStall -and -not $isNot)
                IsNew          = (-not $pc)
            })
        }

        # --- Scope view ---
        $added = [System.Collections.Generic.List[object]]::new()
        $removed = [System.Collections.Generic.List[object]]::new()
        $changed = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $curMap.Keys) {
            $ci = $curMap[$k]
            if (-not $prevMap.ContainsKey($k)) {
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
                        SourceName   = [string](Get-SPDiffProp $ci 'SourceName' '')
                        Privileged   = [bool](Get-SPDiffProp $ci 'Privileged' $false)
                        PrevDecision = $pd
                        CurrDecision = $cd
                    })
                }
            }
        }
        foreach ($k in $prevMap.Keys) {
            if (-not $curMap.ContainsKey($k)) { $removed.Add($prevMap[$k]) }
        }

        # --- Compliance summary ---
        $newPriv = [System.Collections.Generic.List[object]]::new()
        foreach ($it in $added) { if ([bool](Get-SPDiffProp $it 'Privileged' $false)) { $newPriv.Add($it) } }

        $stalledReviewers = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $reviewers) { if ($r.NotStarted -or $r.Stalled) { $stalledReviewers.Add($r) } }

        # Overdue undecided: PENDING now AND present+PENDING in the prior capture
        # (persistently undecided across >= 2 captures). First run -> empty.
        $overdue = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $curMap.Keys) {
            $ci = $curMap[$k]
            if ([string](Get-SPDiffProp $ci 'Decision' '') -ne 'PENDING') { continue }
            if ($prevMap.ContainsKey($k) -and [string](Get-SPDiffProp $prevMap[$k] 'Decision' '') -eq 'PENDING') {
                $overdue.Add($ci)
            }
        }

        # Privileged approved (advisory): privileged grants whose decision is APPROVE now
        # and was NOT APPROVE before (newly approved this capture). On the first run, all
        # currently-approved privileged grants count as "newly seen approved".
        $privApproved = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $curMap.Keys) {
            $ci = $curMap[$k]
            if (-not [bool](Get-SPDiffProp $ci 'Privileged' $false)) { continue }
            if ([string](Get-SPDiffProp $ci 'Decision' '') -ne 'APPROVE') { continue }
            $wasApprove = $prevMap.ContainsKey($k) -and ([string](Get-SPDiffProp $prevMap[$k] 'Decision' '') -eq 'APPROVE')
            if (-not $wasApprove) { $privApproved.Add($ci) }
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
            }
            Completion = [ordered]@{
                Reviewers           = $reviewers.ToArray()
                NewlyCompletedCount = $newlyCompleted
                OutstandingCount    = $outstanding
                StalledCount        = $stalled
                NotStartedCount     = $notStarted
                PrevCompletionPct   = $kpiDelta.PrevCompletionPct
                CurrCompletionPct   = $kpiDelta.CurrCompletionPct
            }
            Scope = [ordered]@{
                Added               = $added.ToArray()
                Removed             = $removed.ToArray()
                Changed             = $changed.ToArray()
                AddedCount          = $added.Count
                RemovedCount        = $removed.Count
                ChangedCount        = $changed.Count
                AddedPrivilegedCount = $newPriv.Count
            }
            Compliance = [ordered]@{
                NewlyAddedPrivileged = $newPriv.ToArray()
                StalledReviewers     = $stalledReviewers.ToArray()
                OverdueUndecided     = $overdue.ToArray()
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
        [void]$sb.Append("<div class='meta'>Campaign $(Get-SPDiffEnc $meta.CampaignId) | Status $(Get-SPDiffEnc $meta.Status)<br/>$window</div>")
        if (-not $meta.HasPrevious) { [void]$sb.Append("<div class='first'>No prior snapshot &mdash; this is the baseline capture. Progress deltas appear from the next run onward.</div>") }

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
        [void]$sb.Append("</div>")

        # Reviewer table (sorted: stalled/not-started first, then by completion asc)
        [void]$sb.Append("<h2>Reviewer progress</h2>")
        $rows = @($comp.Reviewers) | Sort-Object @{ Expression = { if ($_.NotStarted) { 0 } elseif ($_.Stalled) { 1 } elseif (-not $_.Completed) { 2 } else { 3 } } }, @{ Expression = { $_.CompletionPct } }
        if (@($rows).Count -eq 0) { [void]$sb.Append("<div class='empty'>No certifications in this capture.</div>") }
        else {
            [void]$sb.Append("<table><tr><th>Reviewer</th><th>Status</th><th>Made</th><th>&Delta; since prev</th><th>Total</th><th>Completion</th></tr>")
            foreach ($r in $rows) {
                $status = if ($r.Completed) { if ($r.NewlyCompleted) { "<span class='badge b-add'>NEWLY DONE</span>" } else { 'Done' } }
                          elseif ($r.NotStarted) { "<span class='badge b-rem'>NOT STARTED</span>" }
                          elseif ($r.Stalled) { "<span class='badge b-chg'>STALLED</span>" }
                          else { 'In progress' }
                $nm = if ([string]::IsNullOrWhiteSpace($r.ReviewerName)) { $r.ReviewerId } else { $r.ReviewerName }
                [void]$sb.Append("<tr><td>$(Get-SPDiffEnc $nm)</td><td>$status</td><td>$($r.CurrMade)</td><td>$(Get-SPDiffDelta ([int]$r.MadeDelta))</td><td>$($r.Total)</td><td>$($r.CompletionPct)%</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append("<div class='note'>Read-only progress view. No reassignment or escalation is performed by this report.</div>")
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
        [void]$sb.Append("<div class='meta'>Campaign $(Get-SPDiffEnc $meta.CampaignId) | Status $(Get-SPDiffEnc $meta.Status)<br/>$window</div>")
        if (-not $meta.HasPrevious) { [void]$sb.Append("<div class='first'>No prior snapshot &mdash; everything below is reported as the baseline (added). Add/remove deltas become meaningful from the next run.</div>") }

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
        [void]$sb.Append("<tr><td>Stalled / not-started reviewers</td><td>$(@($comp.StalledReviewers).Count)</td><td>No progress between captures or zero decisions made.</td></tr>")
        [void]$sb.Append("<tr><td>Overdue undecided items</td><td>$(@($comp.OverdueUndecided).Count)</td><td>Still PENDING across at least two captures.</td></tr>")
        [void]$sb.Append("<tr><td>Privileged approved (advisory)</td><td>$(@($comp.PrivilegedApproved).Count)</td><td>Privileged grants newly set to APPROVE &mdash; a maturity signal, not an accusation.</td></tr>")
        [void]$sb.Append("</table>")
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
                NewlyCompleted= $r.NewlyCompleted
                NotStarted    = $r.NotStarted
                Stalled       = $r.Stalled
            }
        }
        $completionCsv = Join-Path $OutputDir "completion-diff-$campSafe-$stamp.csv"
        # Pin an explicit, identical column set/order on every row -- PS 5.1 Export-Csv
        # throws "Argument types do not match" when objects in a List[object] disagree on
        # member ordering. -Property <list> forces a stable projection.
        $completionCols = @('CampaignId','CampaignName','CapturedAt','ReviewerName','ReviewerId','CertId','PrevMade','CurrMade','MadeDelta','Total','CompletionPct','Completed','NewlyCompleted','NotStarted','Stalled')
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
        $scopeCols = @('CampaignId','CampaignName','CapturedAt','Change','IdentityName','IdentityId','AccessName','SourceName','Privileged','Decision','PrevDecision','CurrDecision','Key')
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
        IdentityName = [string](Get-SPDiffProp $Item 'IdentityName' '')
        IdentityId   = [string](Get-SPDiffProp $Item 'IdentityId' '')
        AccessName   = [string](Get-SPDiffProp $Item 'AccessName' '')
        SourceName   = [string](Get-SPDiffProp $Item 'SourceName' '')
        Privileged   = [bool](Get-SPDiffProp $Item 'Privileged' $false)
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

Export-ModuleMember -Function @(
    'Compare-SPCampaignSnapshots',
    'Export-SPCampaignCompletionDiffHtml',
    'Export-SPCampaignScopeDiffHtml',
    'Export-SPCampaignDiffCsv'
)
