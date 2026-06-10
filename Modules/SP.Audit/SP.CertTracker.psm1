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

Export-ModuleMember -Function @('Build-SPCertTrackerData')
