<#
.SYNOPSIS
    SP.CertTracker -- executive "certification progress tracker" (a Domino's-style pipeline
    tracker) for recurring attestation campaigns, plus the data behind the leadership reports.

.DESCRIPTION
    Campaigns are ALMOST ALWAYS ACTIVE and incomplete -- closure is the rare event (typically
    2-7 days, sometimes up to 30). So this is deliberately PACE-CENTRIC, not completion-centric:
    a campaign sitting in "In Review" for a week is the normal state, and the story leadership
    needs is *movement* -- velocity, projected close vs deadline, momentum, and where it's
    stalling -- which always has signal from hour 8 to day 30. The 6-stage rail
    (Launched -> In Review -> Decisions Done -> Signed Off -> Remediation -> Closed) is kept as
    CONTEXT, but the daily value is the pace.

    Build-SPCertTrackerData consumes campaign SNAPSHOTS (current + previous, from
    SP.CampaignDelta) -- the same time-series the diff/trend use -- and derives, per campaign:
    stage, completion (by-decision AND by-reviewer -- both framings shown, leadership picks),
    velocity/day, projected close + on-track/at-risk/behind vs the deadline, momentum vs the
    prior capture, a days-in phase (ramp / pace / long-tail), stall/aging signals, and a RAG.
    Plus a program-level rollup (pipeline board counts).

    Read-only. Degrades gracefully: missing dates / no prior capture / zero velocity are handled
    (it shows the stage it can prove, never guesses a projection it can't support).

    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Internal

function Get-CTProp {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { $v = $Object[$Name]; if ($null -ne $v) { return $v } } ; return $Default }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function ConvertTo-CTDate {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return [datetime]::Parse($Raw) } catch { return $null }
}

# Point-in-time stats + stage for a single snapshot.
function Get-CTSnapshotStats {
    param([object]$Snapshot)
    $meta = Get-CTProp $Snapshot 'Meta'
    $kpi  = Get-CTProp $Snapshot 'Kpi'
    $status = ([string](Get-CTProp $meta 'Status' '')).ToUpperInvariant()
    $total    = [int](Get-CTProp $kpi 'Total' 0)
    $approved = [int](Get-CTProp $kpi 'Approved' 0)
    $revoked  = [int](Get-CTProp $kpi 'Revoked' 0)
    $pending  = [int](Get-CTProp $kpi 'Pending' 0)
    $decided  = $approved + $revoked
    $revTotal = [int](Get-CTProp $kpi 'ReviewersTotal' 0)
    $revSigned = [int](Get-CTProp $kpi 'ReviewersSigned' 0)
    $revNotStarted = [int](Get-CTProp $kpi 'ReviewersNotStarted' 0)
    $remPending = [int](Get-CTProp $kpi 'RemediationPending' 0)
    $complByDecision = [double](Get-CTProp $kpi 'CompletionPct' 0)
    $complByReviewer = [double](Get-CTProp $kpi 'CompletionPctByReviewer' 0)

    $allDecided = ($total -gt 0 -and $pending -eq 0)
    $allSigned  = ($revTotal -gt 0 -and $revSigned -ge $revTotal)

    # Stage rail (context). Index 1..6.
    if ($status -eq 'COMPLETED') { $stage = 'Closed'; $idx = 6 }
    elseif ($decided -eq 0)      { $stage = 'Launched'; $idx = 1 }
    elseif (-not $allDecided)    { $stage = 'In Review'; $idx = 2 }
    elseif (-not $allSigned)     { $stage = 'Decisions Done'; $idx = 3 }
    elseif ($remPending -gt 0)   { $stage = 'Remediation'; $idx = 5 }
    else                         { $stage = 'Signed Off'; $idx = 4 }

    return [ordered]@{
        Status = $status
        Total = $total; Approved = $approved; Revoked = $revoked; Pending = $pending; Decided = $decided
        ReviewersTotal = $revTotal; ReviewersSigned = $revSigned; ReviewersNotStarted = $revNotStarted
        RemediationPending = $remPending
        CompletionByDecision = $complByDecision; CompletionByReviewer = $complByReviewer
        Stage = $stage; StageIndex = $idx
        CapturedAt = ConvertTo-CTDate ([string](Get-CTProp $meta 'CapturedAt' ''))
    }
}

#endregion

#region Public

function Build-SPCertTrackerData {
    <#
    .SYNOPSIS
        Builds per-campaign tracker records (stage + pace + projection) and a program rollup.
    .PARAMETER Campaigns
        Array of @{ Current = <snapshot>; Previous = <snapshot or $null> } (snapshots from
        Build-SPCampaignSnapshotData / Get-SPCampaignSnapshot).
    .PARAMETER AtRiskBufferDays
        Days past the deadline a projection may slip before it's 'Behind' rather than 'AtRisk'.
        Default 1.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Campaigns=@(records); Program=@{...} }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Campaigns,
        [Parameter()][double]$AtRiskBufferDays = 1
    )
    try {
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($Campaigns)) {
            if ($null -eq $entry) { continue }
            $cur = Get-CTProp $entry 'Current'
            if ($null -eq $cur) { continue }
            $prev = Get-CTProp $entry 'Previous'
            $meta = Get-CTProp $cur 'Meta'
            $s = Get-CTSnapshotStats -Snapshot $cur
            $ps = if ($null -ne $prev) { Get-CTSnapshotStats -Snapshot $prev } else { $null }

            $capturedAt = $s.CapturedAt
            $startDate  = ConvertTo-CTDate ([string](Get-CTProp $meta 'StartDate' ''))
            $dueDate    = ConvertTo-CTDate ([string](Get-CTProp $meta 'DueDate' ''))

            $daysIn = $null
            if ($null -ne $startDate -and $null -ne $capturedAt) { $daysIn = [math]::Round(($capturedAt - $startDate).TotalDays, 1) }
            $daysToDeadline = $null
            if ($null -ne $dueDate -and $null -ne $capturedAt) { $daysToDeadline = [math]::Round(($dueDate - $capturedAt).TotalDays, 1) }
            $overdue = ($null -ne $daysToDeadline -and $daysToDeadline -lt 0 -and $s.Stage -ne 'Closed')

            # --- velocity (decisions/day) ---
            $velocityPerDay = $null
            if ($null -ne $ps -and $null -ne $ps.CapturedAt -and $null -ne $capturedAt) {
                $hrs = ($capturedAt - $ps.CapturedAt).TotalHours
                if ($hrs -gt 0) { $velocityPerDay = [math]::Round((($s.Decided - $ps.Decided) / ($hrs / 24.0)), 1) }
            }
            elseif ($null -ne $daysIn -and $daysIn -gt 0) {
                $velocityPerDay = [math]::Round($s.Decided / $daysIn, 1)   # average since start (no prior capture)
            }

            # --- projection ---
            $remaining = $s.Pending
            $projectedClose = $null; $projectedVsDeadline = 'NoData'
            if ($remaining -le 0) { $projectedVsDeadline = 'Decided'; $projectedClose = $capturedAt }
            elseif ($null -ne $velocityPerDay -and $velocityPerDay -gt 0 -and $null -ne $capturedAt) {
                $daysToClose = $remaining / $velocityPerDay
                $projectedClose = $capturedAt.AddDays($daysToClose)
                if ($null -eq $dueDate) { $projectedVsDeadline = 'NoDeadline' }
                elseif ($projectedClose -le $dueDate) { $projectedVsDeadline = 'OnTrack' }
                elseif ($projectedClose -le $dueDate.AddDays($AtRiskBufferDays)) { $projectedVsDeadline = 'AtRisk' }
                else { $projectedVsDeadline = 'Behind' }
            }
            else { $projectedVsDeadline = 'Stalled' }

            # --- momentum vs prior capture ---
            $momentum = 'NoData'; $stagesAdvanced = 0; $completionDelta = 0
            if ($null -ne $ps) {
                $stagesAdvanced = $s.StageIndex - $ps.StageIndex
                $completionDelta = [math]::Round($s.CompletionByDecision - $ps.CompletionByDecision, 1)
                if ($stagesAdvanced -gt 0) { $momentum = 'Advanced' }
                elseif ($completionDelta -gt 0) { $momentum = 'Moving' }
                elseif ($completionDelta -lt 0) { $momentum = 'Slipped' }
                else { $momentum = 'Stalled' }
            }

            # --- days-in phase (ramp / pace / long-tail) ---
            $phase = 'Pace'
            if ($null -eq $daysIn) { $phase = 'Pace' }
            elseif ($daysIn -lt 1) { $phase = 'Ramp' }
            elseif ($daysIn -gt 7 -or $overdue) { $phase = 'LongTail' }

            # --- RAG ---
            $rag = 'Green'
            if ($s.Stage -eq 'Closed') { $rag = 'Green' }
            elseif ($overdue -or $projectedVsDeadline -eq 'Behind') { $rag = 'Red' }
            elseif ($projectedVsDeadline -eq 'AtRisk' -or
                    ($momentum -eq 'Stalled' -and $s.Stage -in @('In Review', 'Decisions Done')) -or
                    ($s.ReviewersNotStarted -gt 0 -and $null -ne $daysIn -and $daysIn -gt 2)) { $rag = 'Amber' }
            else { $rag = 'Green' }

            $records.Add([ordered]@{
                CampaignId          = [string](Get-CTProp $meta 'CampaignId' '')
                CampaignName        = [string](Get-CTProp $meta 'CampaignName' '')
                Status              = $s.Status
                Stage               = $s.Stage
                StageIndex          = $s.StageIndex
                StartDate           = if ($startDate) { $startDate.ToString('o') } else { '' }
                DueDate             = if ($dueDate) { $dueDate.ToString('o') } else { '' }
                CapturedAt          = if ($capturedAt) { $capturedAt.ToString('o') } else { '' }
                DaysIn              = $daysIn
                DaysToDeadline      = $daysToDeadline
                Overdue             = $overdue
                Phase               = $phase
                ItemsTotal          = $s.Total
                ItemsDecided        = $s.Decided
                ItemsRemaining      = $remaining
                CompletionByDecision = $s.CompletionByDecision
                CompletionByReviewer = $s.CompletionByReviewer
                ReviewersTotal      = $s.ReviewersTotal
                ReviewersSigned     = $s.ReviewersSigned
                ReviewersNotStarted = $s.ReviewersNotStarted
                PrivilegedPending   = [int](Get-CTProp (Get-CTProp $cur 'Kpi') 'PrivilegedPending' 0)
                RemediationPending  = $s.RemediationPending
                VelocityPerDay      = $velocityPerDay
                ProjectedClose      = if ($projectedClose) { $projectedClose.ToString('o') } else { '' }
                ProjectedVsDeadline = $projectedVsDeadline
                Momentum            = $momentum
                StagesAdvanced      = $stagesAdvanced
                CompletionDelta     = $completionDelta
                HasPrevious         = ($null -ne $ps)
                Rag                 = $rag
            })
        }

        # --- program rollup (pipeline board) ---
        $byStage = [ordered]@{ 'Launched' = 0; 'In Review' = 0; 'Decisions Done' = 0; 'Signed Off' = 0; 'Remediation' = 0; 'Closed' = 0 }
        $byRag = [ordered]@{ Red = 0; Amber = 0; Green = 0 }
        $active = 0; $overdueCount = 0
        foreach ($r in $records) {
            if ($byStage.Contains($r.Stage)) { $byStage[$r.Stage]++ }
            if ($byRag.Contains($r.Rag)) { $byRag[$r.Rag]++ }
            if ($r.Stage -ne 'Closed') { $active++ }
            if ($r.Overdue) { $overdueCount++ }
        }
        $program = [ordered]@{
            TotalCampaigns = $records.Count
            ActiveCampaigns = $active
            OverdueCampaigns = $overdueCount
            AtRiskCampaigns = ($byRag.Red + $byRag.Amber)
            ByStage = $byStage
            ByRag = $byRag
        }

        return @{ Success = $true; Data = @{ Campaigns = $records.ToArray(); Program = $program }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Build-SPCertTrackerData failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: HTML

function Get-CTEnc { param([object]$v) if ($null -eq $v) { return '' } return [System.Web.HttpUtility]::HtmlEncode([string]$v) }

function Export-SPCertTrackerHtml {
    <#
    .SYNOPSIS
        Renders the executive Certification Progress Tracker (pipeline board + pace cards).
    .PARAMETER TrackerData
        Output of Build-SPCertTrackerData (.Data) -- @{ Campaigns; Program }.
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$TrackerData,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $prog = Get-CTProp $TrackerData 'Program'
        $camps = @(Get-CTProp $TrackerData 'Campaigns' @())
        $ragColor = @{ Red = '#b00020'; Amber = '#9a6700'; Green = '#0a7d2c' }
        $stages = @('Launched', 'In Review', 'Decisions Done', 'Signed Off', 'Remediation', 'Closed')

        $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:22px;background:#f4f7fb;}
h1{font-size:21px;color:#1f3a5f;margin:0 0 2px;}
.sub{color:#566;font-size:12px;margin-bottom:14px;}
.kpis{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;}
.kpi{background:#fff;border:1px solid #d4dce6;border-radius:8px;padding:10px 16px;min-width:120px;}
.kpi .n{font-size:26px;font-weight:700;color:#1f3a5f;display:block;line-height:1;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.pipe{display:flex;gap:6px;margin-bottom:18px;flex-wrap:wrap;}
.pipe .seg{background:#fff;border:1px solid #d4dce6;border-radius:6px;padding:6px 10px;font-size:11px;color:#566;}
.pipe .seg b{color:#1f3a5f;font-size:15px;}
.card{background:#fff;border:1px solid #d4dce6;border-left-width:5px;border-radius:8px;padding:14px 16px;margin-bottom:12px;}
.card h2{font-size:15px;margin:0 0 2px;color:#1f3a5f;display:flex;align-items:center;gap:8px;}
.dot{width:11px;height:11px;border-radius:50%;display:inline-block;}
.rail{display:flex;gap:3px;margin:10px 0 6px;}
.pill{flex:1;text-align:center;font-size:9.5px;padding:4px 2px;border-radius:4px;background:#e7edf4;color:#8a99ab;border:1px solid #dde5ee;}
.pill.done{background:#0a7d2c;color:#fff;border-color:#0a7d2c;}
.pill.cur{background:#1f3a5f;color:#fff;border-color:#1f3a5f;font-weight:700;}
.heads{display:flex;gap:24px;margin:8px 0;flex-wrap:wrap;}
.head .v{font-size:20px;font-weight:700;color:#1f3a5f;}
.head .l{font-size:10px;color:#777;text-transform:uppercase;}
.proj{font-size:13px;font-weight:700;}
.bar{height:10px;background:#e7edf4;border-radius:5px;overflow:hidden;margin-top:4px;}
.bar > span{display:block;height:100%;background:#3a6ea5;}
.pace{font-size:11.5px;color:#566;margin-top:8px;}
.tag{display:inline-block;padding:1px 7px;border-radius:10px;font-size:10px;font-weight:700;color:#fff;}
.note{font-size:11px;color:#777;margin-top:14px;}
'@
        $title = 'Certification Progress Tracker'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$(Get-CTEnc $title)</title><style>$css</style></head><body>")
        [void]$sb.Append("<h1>$(Get-CTEnc $title)</h1>")
        [void]$sb.Append("<div class='sub'>Where each active certification campaign stands &mdash; pace, projection, and movement. Active &amp; incomplete is the normal state; the story is whether it's moving toward its deadline.</div>")

        # Program KPIs
        [void]$sb.Append("<div class='kpis'>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($prog.ActiveCampaigns)</span><span class='l'>Active campaigns</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n' style='color:#9a6700'>$($prog.AtRiskCampaigns)</span><span class='l'>At-risk (amber+red)</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n' style='color:#b00020'>$($prog.OverdueCampaigns)</span><span class='l'>Overdue</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$($prog.TotalCampaigns)</span><span class='l'>Total tracked</span></div>")
        [void]$sb.Append("</div>")

        # Pipeline board (counts per stage)
        [void]$sb.Append("<div class='pipe'>")
        foreach ($st in $stages) { $c = if ($prog.ByStage.Contains($st)) { $prog.ByStage[$st] } else { 0 }; [void]$sb.Append("<div class='seg'><b>$c</b> $(Get-CTEnc $st)</div>") }
        [void]$sb.Append("</div>")

        # Cards, worst-first (Red, Amber, Green), then least complete
        $order = @{ Red = 0; Amber = 1; Green = 2 }
        $sorted = $camps | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Rag)) { $order[$_.Rag] } else { 3 } } }, @{ Expression = { [double]$_.CompletionByReviewer } }
        foreach ($c in $sorted) {
            $rc = if ($ragColor.ContainsKey($c.Rag)) { $ragColor[$c.Rag] } else { '#888' }
            [void]$sb.Append("<div class='card' style='border-left-color:$rc'>")
            [void]$sb.Append("<h2><span class='dot' style='background:$rc'></span>$(Get-CTEnc $c.CampaignName)</h2>")
            # stage rail
            [void]$sb.Append("<div class='rail'>")
            for ($i = 0; $i -lt $stages.Count; $i++) {
                $idx = $i + 1
                $cls = if ($idx -lt $c.StageIndex) { 'pill done' } elseif ($idx -eq $c.StageIndex) { 'pill cur' } else { 'pill' }
                [void]$sb.Append("<div class='$cls'>$(Get-CTEnc $stages[$i])</div>")
            }
            [void]$sb.Append("</div>")
            # headline numbers (BOTH framings)
            $projLabel = switch ($c.ProjectedVsDeadline) {
                'OnTrack'   { "<span class='proj' style='color:#0a7d2c'>On track</span>" }
                'AtRisk'    { "<span class='proj' style='color:#9a6700'>At risk</span>" }
                'Behind'    { "<span class='proj' style='color:#b00020'>Behind</span>" }
                'Decided'   { "<span class='proj' style='color:#3a6ea5'>All decided</span>" }
                'Stalled'   { "<span class='proj' style='color:#888'>Stalled (no pace)</span>" }
                'NoDeadline'{ "<span class='proj' style='color:#888'>No deadline set</span>" }
                default     { "<span class='proj' style='color:#888'>&mdash;</span>" }
            }
            $projWhen = if ($c.ProjectedClose) { try { ([datetime]::Parse($c.ProjectedClose)).ToString('MMM d') } catch { '' } } else { '' }
            $dueWhen  = if ($c.DueDate) { try { ([datetime]::Parse($c.DueDate)).ToString('MMM d') } catch { '' } } else { '' }
            [void]$sb.Append("<div class='heads'>")
            [void]$sb.Append("<div class='head'><div class='v'>$($c.CompletionByReviewer)%</div><div class='l'>Reviewers complete</div></div>")
            [void]$sb.Append("<div class='head'><div class='v'>$($c.CompletionByDecision)%</div><div class='l'>Decisions complete</div></div>")
            [void]$sb.Append("<div class='head'><div>$projLabel</div><div class='l'>Projected $(Get-CTEnc $projWhen) vs due $(Get-CTEnc $dueWhen)</div></div>")
            [void]$sb.Append("</div>")
            # burndown bar (decided / total)
            $pct = if ([int]$c.ItemsTotal -gt 0) { [math]::Round([int]$c.ItemsDecided * 100.0 / [int]$c.ItemsTotal) } else { 0 }
            [void]$sb.Append("<div class='bar'><span style='width:$pct%'></span></div>")
            # pace line
            $vel = if ($null -eq $c.VelocityPerDay) { 'n/a' } else { "$($c.VelocityPerDay)/day" }
            $dIn = if ($null -eq $c.DaysIn) { '?' } else { $c.DaysIn }
            $mom = $c.Momentum
            $momTag = switch ($mom) { 'Advanced' {"<span class='tag' style='background:#0a7d2c'>advanced</span>"} 'Moving' {"<span class='tag' style='background:#3a6ea5'>moving</span>"} 'Stalled' {"<span class='tag' style='background:#9a6700'>stalled</span>"} 'Slipped' {"<span class='tag' style='background:#b00020'>slipped</span>"} default {"<span class='tag' style='background:#888'>baseline</span>"} }
            [void]$sb.Append("<div class='pace'>Day $dIn &middot; velocity $vel &middot; $momTag &middot; $($c.ItemsRemaining) items remaining &middot; $($c.ReviewersNotStarted) reviewer(s) not started &middot; $($c.PrivilegedPending) privileged pending &middot; $($c.RemediationPending) revocation(s) to remediate &middot; <i>$($c.Phase)</i></div>")
            [void]$sb.Append("</div>")
        }
        if (@($camps).Count -eq 0) { [void]$sb.Append("<div class='note'>No campaigns to track.</div>") }
        [void]$sb.Append("<div class='note'>Read-only. Projected close = remaining items &divide; recent decision velocity; it is an estimate, not a commitment. No reassignment or escalation is performed.</div>")
        [void]$sb.Append("</body></html>")

        $file = $OutputPath
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
            $file = Join-Path $OutputPath 'cert-tracker.html'
        }
        $u = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $u)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCertTrackerHtml failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: Attestation Evidence Pack (compliance/audit)

function Export-SPAttestationEvidenceHtml {
    <#
    .SYNOPSIS
        Renders the Attestation Evidence Pack -- the ACTUAL recorded certification decisions
        (decision, reviewer, date, justification, remediation) for a campaign. The audit-grade
        artifact an audit reviewer samples. Works on partial/active campaigns (the norm).
    .PARAMETER CampaignMeta
        Hashtable: Name; Id; Status; StartDate; DueDate; CapturedAt; ReviewersSigned; ReviewersTotal.
    .PARAMETER Decisions
        Group-SPAuditDecisions output: @{ Approved; Revoked; Pending } of decision items carrying
        IdentityName/AccessName/SourceName/Privileged/ReviewerName/ReviewerEmail/DecisionDate/
        Justification/RemediationStatus/RemediationDate.
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$CampaignMeta,
        [Parameter(Mandatory)][object]$Decisions,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($cat in @('Approved', 'Revoked', 'Pending')) {
            foreach ($it in @(Get-CTProp $Decisions $cat @())) {
                if ($null -eq $it) { continue }
                $rows.Add([ordered]@{
                    Decision     = $cat
                    IdentityName = [string](Get-CTProp $it 'IdentityName' '')
                    AccessName   = [string](Get-CTProp $it 'AccessName' '')
                    SourceName   = [string](Get-CTProp $it 'SourceName' '')
                    Privileged   = [bool](Get-CTProp $it 'Privileged' $false)
                    Reviewer     = [string](Get-CTProp $it 'ReviewerName' (Get-CTProp $it 'ReviewerEmail' ''))
                    DecisionDate = [string](Get-CTProp $it 'DecisionDate' '')
                    Justification = [string](Get-CTProp $it 'Justification' '')
                    RemediationStatus = [string](Get-CTProp $it 'RemediationStatus' '')
                    RemediationDate   = [string](Get-CTProp $it 'RemediationDate' '')
                })
            }
        }
        $approved = @($rows | Where-Object { $_.Decision -eq 'Approved' }).Count
        $revoked  = @($rows | Where-Object { $_.Decision -eq 'Revoked' }).Count
        $pending  = @($rows | Where-Object { $_.Decision -eq 'Pending' }).Count
        $total = $rows.Count
        $decided = $approved + $revoked
        $complPct = if ($total -gt 0) { [math]::Round($decided * 100.0 / $total, 1) } else { 0 }
        $revRows = @($rows | Where-Object { $_.Decision -eq 'Revoked' })
        $remProvisioned = @($revRows | Where-Object { $_.RemediationStatus -match 'Provision' }).Count
        $remPending = @($revRows | Where-Object { $_.RemediationStatus -match 'Pending' }).Count

        $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;}
h2{font-size:14px;color:#1f3a5f;margin-top:22px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
.meta{color:#566;font-size:12px;margin:6px 0;}
.kpis{margin:10px 0;}
.kpi{display:inline-block;min-width:96px;margin-right:10px;padding:8px 12px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;}
.kpi .n{font-size:20px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:10px;color:#566;text-transform:uppercase;}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:11.5px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:5px 7px;}
td{border-bottom:1px solid #e3e9f0;padding:4px 7px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.priv td{background:#fdecec !important;}
.d-app{color:#0a7d2c;font-weight:700;} .d-rev{color:#b00020;font-weight:700;} .d-pen{color:#9a6700;font-weight:700;}
.badge{display:inline-block;padding:1px 6px;border-radius:9px;font-size:9px;font-weight:700;background:#b00020;color:#fff;}
.note{font-size:11px;color:#777;margin-top:10px;}
'@
        $name = [string]$CampaignMeta['Name']
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$(Get-CTEnc "Attestation Evidence -- $name")</title><style>$css</style></head><body>")
        [void]$sb.Append("<h1>Access Certification &mdash; Attestation Evidence Pack</h1>")
        [void]$sb.Append("<div class='meta'><b>$(Get-CTEnc $name)</b> [$(Get-CTEnc ([string]$CampaignMeta['Id']))] &middot; Status $(Get-CTEnc ([string]$CampaignMeta['Status']))</div>")
        $sd = [string]$CampaignMeta['StartDate']; $dd = [string]$CampaignMeta['DueDate']; $ca = [string]$CampaignMeta['CapturedAt']
        [void]$sb.Append("<div class='meta'>Opened $(Get-CTEnc $sd) &middot; Due $(Get-CTEnc $dd) &middot; Evidence captured $(Get-CTEnc $ca)</div>")
        $rs = [int]($CampaignMeta['ReviewersSigned']); $rt = [int]($CampaignMeta['ReviewersTotal'])
        [void]$sb.Append("<div class='kpis'>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$complPct%</span><span class='l'>Decisions complete</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$approved</span><span class='l'>Approved</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$revoked</span><span class='l'>Revoked</span></div>")
        [void]$sb.Append("<div class='kpi'><span class='n'>$pending</span><span class='l'>Pending</span></div>")
        if ($rt -gt 0) { [void]$sb.Append("<div class='kpi'><span class='n'>$rs/$rt</span><span class='l'>Reviewers signed off</span></div>") }
        [void]$sb.Append("</div>")
        [void]$sb.Append("<div class='note'>This pack reflects the decisions ISC had recorded as of the capture time. Active campaigns are normally partial &mdash; pending items are not yet decided, not errors. 'Signed off' is the audit-authoritative attestation.</div>")

        # Decision evidence
        [void]$sb.Append("<h2>Decision record ($total items)</h2>")
        if ($total -eq 0) { [void]$sb.Append("<div class='note'>No decision items.</div>") }
        else {
            $sorted = $rows | Sort-Object @{ Expression = { switch ($_.Decision) { 'Revoked' {0} 'Approved' {1} default {2} } } }, @{ Expression = { -[int]$_.Privileged } }, @{ Expression = { $_.Reviewer } }
            [void]$sb.Append("<table><tr><th>Identity</th><th>Access</th><th>Source</th><th>Decision</th><th>Reviewer</th><th>Date</th><th>Justification</th><th>Remediation</th></tr>")
            foreach ($r in $sorted) {
                $cls = if ($r.Privileged) { " class='priv'" } else { '' }
                $pb = if ($r.Privileged) { " <span class='badge'>PRIV</span>" } else { '' }
                $dc = switch ($r.Decision) { 'Approved' {"<span class='d-app'>Approve</span>"} 'Revoked' {"<span class='d-rev'>Revoke</span>"} default {"<span class='d-pen'>Pending</span>"} }
                $dt = if ($r.DecisionDate) { try { ([datetime]::Parse($r.DecisionDate)).ToString('yyyy-MM-dd') } catch { $r.DecisionDate } } else { '&mdash;' }
                $rem = if ($r.Decision -eq 'Revoked') { if ($r.RemediationStatus) { Get-CTEnc $r.RemediationStatus } else { 'Pending' } } else { '' }
                [void]$sb.Append("<tr$cls><td>$(Get-CTEnc $r.IdentityName)</td><td>$(Get-CTEnc $r.AccessName)$pb</td><td>$(Get-CTEnc $r.SourceName)</td><td>$dc</td><td>$(Get-CTEnc $r.Reviewer)</td><td>$dt</td><td>$(Get-CTEnc $r.Justification)</td><td>$rem</td></tr>")
            }
            [void]$sb.Append("</table>")
        }

        # Revocation closure
        [void]$sb.Append("<h2>Revocation closure ($revoked revoked &mdash; $remProvisioned removed, $remPending pending)</h2>")
        if ($revoked -eq 0) { [void]$sb.Append("<div class='note'>No revocations in this capture.</div>") }
        else {
            [void]$sb.Append("<table><tr><th>Identity</th><th>Access</th><th>Source</th><th>Reviewer</th><th>Removal status</th><th>Removed date</th></tr>")
            foreach ($r in @($revRows | Sort-Object @{ Expression = { if ($_.RemediationStatus -match 'Pending') { 0 } else { 1 } } })) {
                $st = if ($r.RemediationStatus -match 'Provision') { "<span class='d-app'>Removed</span>" } else { "<span class='d-pen'>Pending removal</span>" }
                $rd = if ($r.RemediationDate) { try { ([datetime]::Parse($r.RemediationDate)).ToString('yyyy-MM-dd') } catch { $r.RemediationDate } } else { '&mdash;' }
                [void]$sb.Append("<tr><td>$(Get-CTEnc $r.IdentityName)</td><td>$(Get-CTEnc $r.AccessName)</td><td>$(Get-CTEnc $r.SourceName)</td><td>$(Get-CTEnc $r.Reviewer)</td><td>$st</td><td>$rd</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append("<div class='note'>Read-only evidence. No reassignment or escalation is performed by this report.</div>")
        [void]$sb.Append("</body></html>")

        $file = $OutputPath
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
            $safeId = ([string]$CampaignMeta['Id']) -replace '[^A-Za-z0-9_\-]', '_'
            $file = Join-Path $OutputPath "attestation-evidence-$safeId.html"
        }
        $u = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $u)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPAttestationEvidenceHtml failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @('Build-SPCertTrackerData', 'Export-SPCertTrackerHtml', 'Export-SPAttestationEvidenceHtml')
