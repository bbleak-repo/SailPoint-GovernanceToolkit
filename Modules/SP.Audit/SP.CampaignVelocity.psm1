<#
.SYNOPSIS
    SP.CampaignVelocity -- OPT-IN review-velocity ADVISORY (a respectful rubber-stamp prompt).

.DESCRIPTION
    Measures, per reviewer, how QUICKLY decisions were made in a campaign capture:
    time-to-start, active span, decisions-per-minute (burst), and approval ratio. A very
    fast, all-approve burst across many privileged items is the classic rubber-stamp shape.

    This is deliberately quarantined in its own module and is OFF unless the caller asks for
    it, because it attributes pace to an individual and is easy to mis-read. The framing
    rules, enforced here and in the report:
      * It is an ADVISORY, never a determination or evidence of misconduct.
      * Review pace is GAMEABLE and a fast pace is NOT proof of a bad review -- experienced
        reviewers with clear context legitimately move quickly.
      * Fields are DESCRIPTIVE (DecisionsPerMinute, PaceNote='fast-pace'), never
        conclusion-shaped (no "RubberStamper=true"). HTML only -- no discoverable CSV.
      * It needs ISC decision timestamps; where ISC didn't expose them (e.g. active certs
        not yet signed) it degrades to 'insufficient-timing-data', it does not guess.

    Read-only. Never mutates ISC.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Internal

function Get-SPVelVal {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { $v = $Object[$Name]; if ($null -ne $v) { return $v } } ; return $Default }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function Get-SPVelEnc { param([object]$v) if ($null -eq $v) { return '' } return [System.Web.HttpUtility]::HtmlEncode([string]$v) }

#endregion

#region Public

function Measure-SPReviewerVelocity {
    <#
    .SYNOPSIS
        Computes per-reviewer decision-velocity from a single snapshot's decision timestamps.
    .PARAMETER Snapshot
        A snapshot from Build-SPCampaignSnapshotData (current capture; ideally a signed/
        completed campaign where ISC has committed decision timestamps).
    .PARAMETER MinDecisions
        Minimum timestamped decisions before a reviewer can be flagged 'fast-pace' (avoids
        flagging tiny certs). Default 10.
    .PARAMETER FastPaceDecisionsPerMin
        Decisions/minute at or above which the pace is 'fast' (combined with approval ratio).
        Default 15 (a decision every ~4s sustained -- implausible for careful privileged review).
    .PARAMETER FastPaceApprovalRatio
        Approval ratio at or above which 'fast-pace' applies. Default 1.0 (all approved).
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Reviewers; Summary }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter()][int]$MinDecisions = 10,
        [Parameter()][double]$FastPaceDecisionsPerMin = 15,
        [Parameter()][double]$FastPaceApprovalRatio = 1.0
    )
    try {
        $meta  = Get-SPVelVal $Snapshot 'Meta'
        $items = @(Get-SPVelVal $Snapshot 'Items' @())
        $certs = @(Get-SPVelVal $Snapshot 'Certs' @())
        $startRaw = [string](Get-SPVelVal $meta 'StartDate' '')
        $startDate = $null; if ($startRaw) { try { $startDate = [datetime]::Parse($startRaw) } catch { } }

        # reviewerId -> name (from certs)
        $nameMap = @{}
        foreach ($c in $certs) { $rid = [string](Get-SPVelVal $c 'ReviewerId' ''); $rn = [string](Get-SPVelVal $c 'ReviewerName' ''); if ($rid -and $rn -and -not $nameMap.ContainsKey($rid)) { $nameMap[$rid] = $rn } }

        # group decided, timestamped items by reviewer
        $byRev = @{}
        $itemsDecided = 0; $itemsTimed = 0
        foreach ($it in $items) {
            $dec = [string](Get-SPVelVal $it 'Decision' '')
            if ($dec -ne 'APPROVE' -and $dec -ne 'REVOKE') { continue }   # PENDING has no decision time
            $itemsDecided++
            $ddRaw = [string](Get-SPVelVal $it 'DecisionDate' '')
            if ([string]::IsNullOrWhiteSpace($ddRaw)) { continue }
            $dd = $null; try { $dd = [datetime]::Parse($ddRaw) } catch { continue }
            $itemsTimed++
            $rid = [string](Get-SPVelVal $it 'ReviewerId' ''); if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '__unattributed__' }
            if (-not $byRev.ContainsKey($rid)) { $byRev[$rid] = [System.Collections.Generic.List[object]]::new() }
            $byRev[$rid].Add(@{ When = $dd; Decision = $dec; Privileged = [bool](Get-SPVelVal $it 'Privileged' $false) })
        }

        $reviewers = [System.Collections.Generic.List[object]]::new()
        $fastCount = 0
        foreach ($rid in $byRev.Keys) {
            if ($rid -eq '__unattributed__') { continue }
            $list = @($byRev[$rid] | Sort-Object { $_.When })
            $count = $list.Count
            $approvals = @($list | Where-Object { $_.Decision -eq 'APPROVE' }).Count
            $privApprovals = @($list | Where-Object { $_.Decision -eq 'APPROVE' -and $_.Privileged }).Count
            $first = $list[0].When; $last = $list[$count - 1].When
            $spanMin = [math]::Round(($last - $first).TotalMinutes, 2)
            $ratePerMin = if ($spanMin -gt 0) { [math]::Round($count / $spanMin, 2) } else { [double]$count }
            $approvalRatio = if ($count -gt 0) { [math]::Round($approvals / [double]$count, 4) } else { 0 }
            $ttsHours = $null; if ($null -ne $startDate) { $ttsHours = [math]::Round(($first - $startDate).TotalHours, 1) }

            $pace = 'normal-pace'
            if ($count -lt $MinDecisions) { $pace = 'insufficient-data' }
            elseif ($approvalRatio -ge $FastPaceApprovalRatio -and ($spanMin -le 0 -or $ratePerMin -ge $FastPaceDecisionsPerMin)) { $pace = 'fast-pace'; $fastCount++ }

            $reviewers.Add([ordered]@{
                ReviewerId        = $rid
                ReviewerName      = if ($nameMap.ContainsKey($rid)) { $nameMap[$rid] } else { $rid }
                DecisionsTimed    = $count
                Approvals         = $approvals
                ApprovalRatio     = $approvalRatio
                PrivilegedApprovals = $privApprovals
                ActiveSpanMinutes = $spanMin
                DecisionsPerMinute = $ratePerMin
                TimeToStartHours  = $ttsHours
                PaceNote          = $pace
            })
        }

        $summary = [ordered]@{
            TotalReviewers   = $reviewers.Count
            FastPace         = $fastCount
            ItemsDecided     = $itemsDecided
            ItemsTimed       = $itemsTimed
            TimingCoveragePct = if ($itemsDecided -gt 0) { [math]::Round($itemsTimed * 100.0 / $itemsDecided, 1) } else { 0 }
            HasStartDate     = ($null -ne $startDate)
            Thresholds       = [ordered]@{ MinDecisions = $MinDecisions; FastPaceDecisionsPerMin = $FastPaceDecisionsPerMin; FastPaceApprovalRatio = $FastPaceApprovalRatio }
            CampaignId       = [string](Get-SPVelVal $meta 'CampaignId' '')
            CampaignName     = [string](Get-SPVelVal $meta 'CampaignName' '')
            CapturedAt       = [string](Get-SPVelVal $meta 'CapturedAt' '')
        }
        return @{ Success = $true; Data = @{ Reviewers = $reviewers.ToArray(); Summary = $summary }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Measure-SPReviewerVelocity failed: $($_.Exception.Message)" } }
}

function Export-SPReviewerVelocityHtml {
    <#
    .SYNOPSIS
        Renders the review-velocity ADVISORY (HTML only -- never a CSV) with mandatory caveats.
    .PARAMETER Velocity
        Output of Measure-SPReviewerVelocity (.Data).
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Velocity,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $s = $Velocity.Summary
        $title = "Review-Velocity Advisory (opt-in) -- $($s.CampaignName)"
        $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;}
h1{font-size:19px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;}
.meta{color:#566;font-size:12px;margin-bottom:8px;}
.warn{background:#fdecec;border:1px solid #e3a0a0;border-radius:6px;padding:12px 16px;margin:12px 0;color:#7a0014;font-size:13px;}
.warn b{color:#5a0010;}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;}
tr.fast td{background:#fff3cd;}
.badge{display:inline-block;padding:1px 7px;border-radius:10px;font-size:10px;font-weight:700;}
.b-fast{background:#9a6700;color:#fff;} .b-norm{background:#888;color:#fff;} .b-insuf{background:#bbb;color:#333;}
.note{font-size:11px;color:#777;margin-top:8px;}
'@
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$(Get-SPVelEnc $title)</title><style>$css</style></head><body>")
        [void]$sb.Append("<h1>$(Get-SPVelEnc $title)</h1>")
        [void]$sb.Append("<div class='meta'>Campaign $(Get-SPVelEnc $s.CampaignId) | Captured $(Get-SPVelEnc $s.CapturedAt)</div>")
        # Mandatory, unmissable caveat.
        [void]$sb.Append("<div class='warn'><b>This is an advisory, not a determination.</b> Review pace is <b>gameable</b> and a fast pace is <b>not</b> proof that a review was improper &mdash; experienced reviewers with clear context legitimately move quickly, and a slow pace is not proof of diligence. Use these figures only as a prompt for a <b>respectful conversation</b> about review quality, never as evidence of misconduct or as an individual performance score. Figures cover only items where ISC exposed a decision timestamp.</div>")

        if ([int]$s.ItemsTimed -eq 0) {
            [void]$sb.Append("<div class='note'>No decision timestamps were available in this capture (common for active certs not yet signed). Re-run on a signed/completed campaign for velocity context.</div>")
        }
        else {
            [void]$sb.Append("<div class='meta'>Timing coverage: $($s.ItemsTimed) of $($s.ItemsDecided) decided items had timestamps ($($s.TimingCoveragePct)%). Thresholds: &ge;$($s.Thresholds.MinDecisions) decisions, &ge;$($s.Thresholds.FastPaceDecisionsPerMin)/min, approval &ge;$([math]::Round($s.Thresholds.FastPaceApprovalRatio*100))%.$(if (-not $s.HasStartDate) { ' (No campaign start date captured &mdash; time-to-start omitted.)' } else { '' })</div>")
            $rows = @($Velocity.Reviewers) | Sort-Object @{ Expression = { if ($_.PaceNote -eq 'fast-pace') { 0 } elseif ($_.PaceNote -eq 'normal-pace') { 1 } else { 2 } } }, @{ Expression = { -$_.DecisionsPerMinute } }
            if (@($rows).Count -eq 0) { [void]$sb.Append("<div class='note'>No reviewers with timestamped decisions.</div>") }
            else {
                [void]$sb.Append("<table><tr><th>Reviewer</th><th>Decisions (timed)</th><th>Approval %</th><th>Active span (min)</th><th>Decisions/min</th><th>Time-to-start (h)</th><th>Pace</th></tr>")
                foreach ($r in $rows) {
                    $cls = if ($r.PaceNote -eq 'fast-pace') { " class='fast'" } else { '' }
                    $pb = switch ($r.PaceNote) { 'fast-pace' { "<span class='badge b-fast'>fast-pace</span>" } 'normal-pace' { "<span class='badge b-norm'>normal</span>" } default { "<span class='badge b-insuf'>insufficient data</span>" } }
                    $tts = if ($null -eq $r.TimeToStartHours) { '&mdash;' } else { $r.TimeToStartHours }
                    [void]$sb.Append("<tr$cls><td>$(Get-SPVelEnc $r.ReviewerName)</td><td>$($r.DecisionsTimed)</td><td>$([math]::Round($r.ApprovalRatio*100,1))%</td><td>$($r.ActiveSpanMinutes)</td><td>$($r.DecisionsPerMinute)</td><td>$tts</td><td>$pb</td></tr>")
                }
                [void]$sb.Append("</table>")
            }
        }
        [void]$sb.Append("<div class='note'>'fast-pace' = at least the threshold number of decisions, at or above the per-minute rate, with an approval ratio at or above the threshold. It is a descriptive flag for follow-up, not a finding. Read-only; no reassignment or escalation is performed.</div>")
        [void]$sb.Append("</body></html>")

        $file = $OutputPath
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
            $safeId = ([string]$s.CampaignId) -replace '[^A-Za-z0-9_\-]', '_'
            $stamp = try { ([datetime]::Parse([string]$s.CapturedAt)).ToString('yyyy-MM-ddTHHmmss') } catch { 'capture' }
            $file = Join-Path $OutputPath "velocity-advisory-$safeId-$stamp.html"
        }
        $u = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $u)
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPReviewerVelocityHtml failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @('Measure-SPReviewerVelocity', 'Export-SPReviewerVelocityHtml')
