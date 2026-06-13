<#
.SYNOPSIS
    SP.CampaignTrend -- a per-campaign KPI time-series (the "trend" layer) for showing how
    a recurring attestation campaign moves over days / weeks / months.

.DESCRIPTION
    Each capture appends ONE small row (counts + scope-growth-robust RATES) to a per-campaign
    append-only JSONL file -- separate from the heavy item-level snapshots (which are pruned
    at 90 days) and separate from the whole-tenant governance-metrics.jsonl. The trend store
    is the LONG-TERM (multi-year) record for "is privileged access trending in a direction?"

    Layout : {Metrics.CampaignTrendPath}\{environment}\{safeCampaignId}.jsonl
    Row     : { timestamp; campaignId; campaignName; status; environment; dueDate;
                metrics:{ flat numeric name -> value, null when a rate denominator is 0 } }
    Read    : Get-SPCampaignTrend rolls the rows up Daily/Weekly/Monthly (min/max/avg/latest
              per period) + a DIRECTION-NEUTRAL arrow (Up/Down/Flat -- rising privileged
              approval is NOT "improvement", so no value-laden labels) + data completeness
              (captures per period) so a sparse week isn't misread as a real dip.

    Mirrors the proven append (copy->append->prune->rename, BOM-free UTF-8) + period-rollup
    pattern from Save-SPGovernanceMetrics / Get-SPGovernanceMetricsTrend. Read-only reporting;
    never mutates ISC.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

# Ensure SP.Shared is loaded (provides ConvertTo-SPHtmlSafe, Get-SPObjectProperty, Format-SPHtmlDate).
$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

#region Internal helpers

function Get-SPCampaignTrendDir {
    param([string]$Environment = '')
    $dir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Metrics']) {
            if ($null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendPath'] -and -not [string]::IsNullOrWhiteSpace($cfg.Metrics.CampaignTrendPath)) {
                $dir = [string]$cfg.Metrics.CampaignTrendPath
            }
            elseif ($null -ne $cfg.Metrics.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace($cfg.Metrics.Path)) {
                $dir = Join-Path ([string]$cfg.Metrics.Path) 'campaign-trend'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = '.\Audit\metrics\campaign-trend' }
    if (-not [System.IO.Path]::IsPathRooted($dir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $dir  = [System.IO.Path]::GetFullPath((Join-Path $root $dir))
    }
    if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $safeEnv = $Environment -replace '[^A-Za-z0-9_\-]', '_'
        $dir = Join-Path $dir $safeEnv
    }
    return $dir
}

function Get-SPCampaignTrendRetentionDays {
    $days = 1825
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Metrics'] -and $null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendRetentionDays'] -and $null -ne $cfg.Metrics.CampaignTrendRetentionDays) {
            $days = [int]$cfg.Metrics.CampaignTrendRetentionDays
        }
    } catch { }
    return $days
}

function Get-SPTrendVal {
    param([object]$Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { $v = $Object[$Name]; if ($null -ne $v) { return $v } } ; return $Default }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function Get-SPTrendPeriodKey {
    param([datetime]$Dt, [string]$Gran)
    switch ($Gran) {
        'Daily'   { return $Dt.ToString('yyyy-MM-dd') }
        'Weekly'  {
            $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
            $wn  = $cal.GetWeekOfYear($Dt, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
            return "$($Dt.ToString('yyyy'))-W$($wn.ToString('D2'))"
        }
        'Monthly' { return $Dt.ToString('yyyy-MM') }
    }
    return $Dt.ToString('yyyy-MM-dd')
}

#endregion

#region Public: write

function Save-SPCampaignTrendPoint {
    <#
    .SYNOPSIS
        Appends one KPI row for a campaign capture to the per-campaign trend JSONL.
    .PARAMETER Snapshot
        A snapshot from Build-SPCampaignSnapshotData (or reloaded).
    .PARAMETER Diff
        Optional Compare-SPCampaignSnapshots result (.Data) -- used to derive completion
        velocity (decisions/hour) from MadeDelta + IntervalHours.
    .PARAMETER TrendDir
        Override the trend root (default: resolved from config, toolkit-root absolute,
        environment-scoped).
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ FilePath; Timestamp }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter()][object]$Diff,
        [Parameter()][string]$TrendDir
    )
    try {
        $meta = Get-SPTrendVal $Snapshot 'Meta'
        $kpi  = Get-SPTrendVal $Snapshot 'Kpi'
        if ($null -eq $meta -or $null -eq $kpi) { return @{ Success = $false; Data = $null; Error = 'Snapshot missing Meta/Kpi' } }
        $campId = [string](Get-SPTrendVal $meta 'CampaignId' '')
        if ([string]::IsNullOrWhiteSpace($campId)) { return @{ Success = $false; Data = $null; Error = 'Snapshot has no CampaignId' } }
        $prov = Get-SPTrendVal $meta 'Provenance'
        $env  = [string](Get-SPTrendVal $prov 'Environment' '')

        if ([string]::IsNullOrWhiteSpace($TrendDir)) { $TrendDir = Get-SPCampaignTrendDir -Environment $env }
        if (-not (Test-Path $TrendDir)) { New-Item -Path $TrendDir -ItemType Directory -Force -WhatIf:$false | Out-Null }
        $safeId = $campId -replace '[^A-Za-z0-9_\-]', '_'
        $file   = Join-Path $TrendDir "$safeId.jsonl"

        $rates = Get-SPTrendVal $kpi 'Rates'
        # Velocity (decisions/hour) from the diff, if supplied.
        $velocity = $null
        if ($null -ne $Diff) {
            $ih = Get-SPTrendVal (Get-SPTrendVal $Diff 'Meta') 'IntervalHours'
            if ($null -ne $ih -and [double]$ih -gt 0) {
                $sumDelta = 0
                foreach ($r in @(Get-SPTrendVal (Get-SPTrendVal $Diff 'Completion') 'Reviewers' @())) { $sumDelta += [int](Get-SPTrendVal $r 'MadeDelta' 0) }
                $velocity = [math]::Round($sumDelta / [double]$ih, 2)
            }
        }

        $metrics = [ordered]@{
            'counts.total'              = [int](Get-SPTrendVal $kpi 'Total' 0)
            'counts.approved'           = [int](Get-SPTrendVal $kpi 'Approved' 0)
            'counts.revoked'            = [int](Get-SPTrendVal $kpi 'Revoked' 0)
            'counts.pending'            = [int](Get-SPTrendVal $kpi 'Pending' 0)
            'counts.privTotal'          = [int](Get-SPTrendVal $kpi 'PrivilegedTotal' 0)
            'counts.privApproved'       = [int](Get-SPTrendVal $kpi 'PrivilegedApproved' 0)
            'counts.privRevoked'        = [int](Get-SPTrendVal $kpi 'PrivilegedRevoked' 0)
            'counts.privPending'        = [int](Get-SPTrendVal $kpi 'PrivilegedPending' 0)
            'counts.privReviewed'       = [int](Get-SPTrendVal $kpi 'PrivilegedReviewed' 0)
            'counts.privConfirmed'      = [int](Get-SPTrendVal $kpi 'PrivilegedConfirmed' 0)
            'counts.privSuspected'      = [int](Get-SPTrendVal $kpi 'PrivilegedSuspected' 0)
            'counts.reviewersTotal'     = [int](Get-SPTrendVal $kpi 'ReviewersTotal' 0)
            'counts.reviewersSigned'    = [int](Get-SPTrendVal $kpi 'ReviewersSigned' 0)
            'counts.reviewersNotStarted'= [int](Get-SPTrendVal $kpi 'ReviewersNotStarted' 0)
            'rates.privApprovalRate'    = Get-SPTrendVal $rates 'PrivApprovalRate'
            'rates.privRevokeRate'      = Get-SPTrendVal $rates 'PrivRevokeRate'
            'rates.privShareOfScope'    = Get-SPTrendVal $rates 'PrivShareOfScope'
            'rates.approvalRate'        = Get-SPTrendVal $rates 'ApprovalRate'
            'rates.revokeRate'          = Get-SPTrendVal $rates 'RevokeRate'
            'completion.byDecisionPct'  = [double](Get-SPTrendVal $kpi 'CompletionPct' 0)
            'completion.byReviewerPct'  = [double](Get-SPTrendVal $kpi 'CompletionPctByReviewer' 0)
            'velocity.decisionsPerHour' = $velocity
        }

        $capturedAt = [string](Get-SPTrendVal $meta 'CapturedAt' '')
        $tsUtc = if ($capturedAt) { try { ([datetime]::Parse($capturedAt)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

        $record = [ordered]@{
            timestamp    = $tsUtc
            campaignId   = $campId
            campaignName = [string](Get-SPTrendVal $meta 'CampaignName' '')
            status       = [string](Get-SPTrendVal $meta 'Status' '')
            environment  = $env
            dueDate      = [string](Get-SPTrendVal $meta 'DueDate' '')
            metrics      = $metrics
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $line = $record | ConvertTo-Json -Depth 6 -Compress
        $tmp  = "$file.tmp"
        if (Test-Path $file) { Copy-Item -Path $file -Destination $tmp -Force } else { [System.IO.File]::WriteAllText($tmp, '', $utf8) }
        [System.IO.File]::AppendAllText($tmp, "$line`n", $utf8)
        # Retention sweep (multi-year by default).
        $cutoff = (Get-Date).AddDays(-(Get-SPCampaignTrendRetentionDays)).ToUniversalTime()
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($ln in [System.IO.File]::ReadAllLines($tmp, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $p = $ln | ConvertFrom-Json; $lt = [datetime]::Parse([string]$p.timestamp).ToUniversalTime(); if ($lt -lt $cutoff) { continue } } catch { }
            $kept.Add($ln)
        }
        $content = ($kept -join "`n"); if ($kept.Count -gt 0) { $content += "`n" }
        [System.IO.File]::WriteAllText($tmp, $content, $utf8)
        if (Test-Path $file) { Remove-Item -Path $file -Force }
        Move-Item -Path $tmp -Destination $file -Force
        return @{ Success = $true; Data = @{ FilePath = $file; Timestamp = $tsUtc }; Error = $null }
    }
    catch {
        if ($TrendDir -and (Test-Path "$TrendDir")) { $t = Join-Path $TrendDir "*.tmp"; Get-ChildItem $t -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
        return @{ Success = $false; Data = $null; Error = "Save-SPCampaignTrendPoint failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Public: read + rollup

function Get-SPCampaignTrend {
    <#
    .SYNOPSIS
        Reads a campaign's KPI series and rolls it up by Daily/Weekly/Monthly period.
    .PARAMETER CampaignId
        Campaign id whose series to read.
    .PARAMETER DaysBack
        Window in days. Default 365.
    .PARAMETER Granularity
        Daily | Weekly | Monthly. Default Weekly.
    .PARAMETER Environment
        Environment subfolder (matches what was captured). Optional.
    .PARAMETER TrendDir
        Override the trend root.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ CampaignId; Granularity; PointCount; Trends=@{metric->@{Periods;Direction;Change}}; Periods=@(period completeness) }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CampaignId,
        [Parameter()][int]$DaysBack = 365,
        [Parameter()][ValidateSet('Daily', 'Weekly', 'Monthly')][string]$Granularity = 'Weekly',
        [Parameter()][string]$Environment = '',
        [Parameter()][string]$TrendDir
    )
    try {
        if ([string]::IsNullOrWhiteSpace($TrendDir)) { $TrendDir = Get-SPCampaignTrendDir -Environment $Environment }
        $safeId = $CampaignId -replace '[^A-Za-z0-9_\-]', '_'
        $file = Join-Path $TrendDir "$safeId.jsonl"
        if (-not (Test-Path $file)) { return @{ Success = $true; Data = @{ CampaignId = $CampaignId; Granularity = $Granularity; PointCount = 0; Trends = @{}; Periods = @() }; Error = $null } }

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()
        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($ln in [System.IO.File]::ReadAllLines($file, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try {
                $rec = $ln | ConvertFrom-Json
                $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime()
                if ($ts -ge $cutoff) { $records.Add($rec) }
            } catch { }
        }
        $records = @($records | Sort-Object { [datetime]::Parse([string]$_.timestamp) })
        if ($records.Count -eq 0) { return @{ Success = $true; Data = @{ CampaignId = $CampaignId; Granularity = $Granularity; PointCount = 0; Trends = @{}; Periods = @() }; Error = $null } }

        # All metric names present
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($rec in $records) {
            if ($null -ne $rec.metrics) {
                foreach ($p in $rec.metrics.PSObject.Properties.Name) { if (-not $names.Contains($p)) { $names.Add($p) } }
            }
        }

        # Period completeness (captures per period)
        $periodCounts = [ordered]@{}
        foreach ($rec in $records) {
            $pk = Get-SPTrendPeriodKey -Dt ([datetime]::Parse([string]$rec.timestamp).ToUniversalTime()) -Gran $Granularity
            if (-not $periodCounts.Contains($pk)) { $periodCounts[$pk] = 0 }
            $periodCounts[$pk]++
        }
        $periodCompleteness = foreach ($pk in $periodCounts.Keys) { [PSCustomObject]@{ Period = $pk; Captures = $periodCounts[$pk] } }

        $trends = @{}
        foreach ($name in $names) {
            $buckets = [ordered]@{}
            foreach ($rec in $records) {
                $val = $null
                if ($null -ne $rec.metrics -and $null -ne $rec.metrics.PSObject.Properties[$name]) { $val = $rec.metrics.$name }
                if ($null -eq $val) { continue }   # skip nulls (e.g. rate with zero denominator)
                $num = 0.0; try { $num = [double]$val } catch { continue }
                $pk = Get-SPTrendPeriodKey -Dt ([datetime]::Parse([string]$rec.timestamp).ToUniversalTime()) -Gran $Granularity
                if (-not $buckets.Contains($pk)) { $buckets[$pk] = [System.Collections.Generic.List[double]]::new() }
                $buckets[$pk].Add($num)
            }
            if ($buckets.Count -eq 0) { continue }
            $periods = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($pk in $buckets.Keys) {
                $vals = $buckets[$pk]
                $min = ($vals | Measure-Object -Minimum).Minimum
                $max = ($vals | Measure-Object -Maximum).Maximum
                $avg = [math]::Round(($vals | Measure-Object -Average).Average, 4)
                $periods.Add(@{ Period = $pk; Min = $min; Max = $max; Avg = $avg; Latest = $vals[$vals.Count - 1]; DataPoints = $vals.Count })
            }
            $first = $periods[0].Avg; $last = $periods[$periods.Count - 1].Avg
            $change = [math]::Round($last - $first, 4)
            $changePct = if ($first -ne 0) { [math]::Round(($change / [math]::Abs($first)) * 100, 1) } else { 0.0 }
            # DIRECTION-NEUTRAL (Up/Down/Flat) -- no value judgement (a rising privileged
            # approval rate is not "improvement").
            $direction = 'Flat'; if ($changePct -gt 2) { $direction = 'Up' } elseif ($changePct -lt -2) { $direction = 'Down' }
            $trends[$name] = @{ Periods = @($periods); Direction = $direction; Change = $change; ChangePercent = $changePct }
        }

        return @{ Success = $true; Data = @{
            CampaignId   = $CampaignId
            CampaignName = [string]$records[$records.Count - 1].campaignName
            Granularity  = $Granularity
            PointCount   = $records.Count
            Trends       = $trends
            Periods      = @($periodCompleteness)
        }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPCampaignTrend failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: HTML export

function Export-SPCampaignTrendHtml {
    <#
    .SYNOPSIS
        Renders a campaign KPI trend report (rate small-multiples + direction + completeness).
    .PARAMETER Trend
        Output of Get-SPCampaignTrend (.Data).
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Trend,
        [Parameter(Mandatory)][string]$OutputPath
    )
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $enc = { param($v) if ($null -eq $v) { '' } else { ConvertTo-SPHtmlSafe ([string]$v) } }
        $title = "Campaign KPI Trend -- $($Trend.CampaignName)"
        $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;}
h2{font-size:14px;color:#1f3a5f;margin-top:22px;}
table{border-collapse:collapse;margin-top:6px;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:5px 9px;}
td{border-bottom:1px solid #e3e9f0;padding:4px 9px;}
.up{color:#9a6700;font-weight:700;} .down{color:#0a7d2c;font-weight:700;} .flat{color:#888;}
.meta{color:#566;font-size:12px;margin-bottom:8px;}
.note{font-size:11px;color:#777;margin-top:8px;}
.mv{background:#fff7e6;border:1px solid #ffd97a;border-radius:6px;padding:8px 12px;margin:8px 0;color:#7a5a00;font-size:12px;}
'@
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$(& $enc $title)</title><style>$css</style></head><body>")
        [void]$sb.Append("<h1>$(& $enc $title)</h1>")
        [void]$sb.Append("<div class='meta'>Campaign $(& $enc $Trend.CampaignId) | $($Trend.Granularity) rollup | $($Trend.PointCount) capture(s)</div>")
        [void]$sb.Append("<div class='mv'>Management / maturity view &mdash; aggregate trend, NOT certification evidence. The immutable per-capture snapshots remain the record of who attested to what. A rising privileged-approval rate is a discussion prompt, not a finding.</div>")

        if ([int]$Trend.PointCount -lt 2) {
            [void]$sb.Append("<div class='note'>Need at least two captures for a trend. Re-run on the campaign's cadence to accumulate the series.</div>")
        }

        # Friendly labels + ordering: rates first (the leadership story), then completion, counts.
        $order = [ordered]@{
            'rates.privApprovalRate'   = 'Privileged approval rate'
            'rates.privRevokeRate'     = 'Privileged revoke rate'
            'rates.privShareOfScope'   = 'Privileged share of scope'
            'rates.approvalRate'       = 'Overall approval rate'
            'rates.revokeRate'         = 'Overall revoke rate'
            'completion.byReviewerPct' = 'Completion % (by reviewer)'
            'completion.byDecisionPct' = 'Completion % (by decision)'
            'velocity.decisionsPerHour'= 'Decision velocity (per hour)'
            'counts.privTotal'         = 'Privileged in scope (count)'
            'counts.privPending'       = 'Privileged pending (count)'
            'counts.total'             = 'Total items (scope size)'
        }
        $arrow = { param($d) switch ($d) { 'Up' { "<span class='up'>&#9650; up</span>" } 'Down' { "<span class='down'>&#9660; down</span>" } default { "<span class='flat'>flat</span>" } } }
        foreach ($mk in $order.Keys) {
            if (-not $Trend.Trends.ContainsKey($mk)) { continue }
            $t = $Trend.Trends[$mk]
            [void]$sb.Append("<h2>$(& $enc $order[$mk]) &mdash; $(& $arrow $t.Direction) ($($t.ChangePercent)%)</h2>")
            [void]$sb.Append("<table><tr><th>Period</th><th>Avg</th><th>Min</th><th>Max</th><th>Latest</th><th>Captures</th></tr>")
            foreach ($p in @($t.Periods)) {
                [void]$sb.Append("<tr><td>$(& $enc $p.Period)</td><td>$($p.Avg)</td><td>$($p.Min)</td><td>$($p.Max)</td><td>$($p.Latest)</td><td>$($p.DataPoints)</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        # Data completeness strip
        if (@($Trend.Periods).Count -gt 0) {
            [void]$sb.Append("<h2>Data completeness (captures per period)</h2><table><tr><th>Period</th><th>Captures</th></tr>")
            foreach ($p in @($Trend.Periods)) { [void]$sb.Append("<tr><td>$(& $enc $p.Period)</td><td>$($p.Captures)</td></tr>") }
            [void]$sb.Append("</table><div class='note'>Sparse periods (few captures) can swing the average &mdash; read direction alongside this.</div>")
        }
        [void]$sb.Append("</body></html>")

        $file = $OutputPath
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
            $safeId = ([string]$Trend.CampaignId) -replace '[^A-Za-z0-9_\-]', '_'
            $file = Join-Path $OutputPath "trend-$safeId-$($Trend.Granularity).html"
        }
        Write-SPHtmlFile -Path $file -Content $sb.ToString()
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPCampaignTrendHtml failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: program (cross-campaign) trend

function Get-SPProgramTrend {
    <#
    .SYNOPSIS
        Aggregates ALL per-campaign KPI series into a PROGRAM-level trend: how many campaigns
        close per period and how privileged-approval / completion move ACROSS the program over
        time (the leadership "are we trending the right way as a whole" view). Fed by the
        per-campaign series that every diff/tracker run appends; closure shows up as COMPLETED
        rows.
    .PARAMETER DaysBack
        Window in days. Default 365.
    .PARAMETER Granularity
        Daily | Weekly | Monthly. Default Monthly.
    .PARAMETER Environment
        Environment subfolder. Optional.
    .PARAMETER TrendDir
        Override the trend root.
    .OUTPUTS
        [hashtable] @{ Success; Data=@{ Granularity; RowCount; CampaignCount; Periods; Direction }; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][int]$DaysBack = 365,
        [Parameter()][ValidateSet('Daily', 'Weekly', 'Monthly')][string]$Granularity = 'Monthly',
        [Parameter()][string]$Environment = '',
        [Parameter()][string]$TrendDir
    )
    try {
        if ([string]::IsNullOrWhiteSpace($TrendDir)) { $TrendDir = Get-SPCampaignTrendDir -Environment $Environment }
        if (-not (Test-Path $TrendDir)) { return @{ Success = $true; Data = @{ Granularity = $Granularity; RowCount = 0; CampaignCount = 0; Periods = @(); Direction = @{} }; Error = $null } }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()

        $buckets = [ordered]@{}   # periodKey -> @{ Campaigns; Closed; PrivRates; Compl; Captures }
        $allCampaigns = @{}; $rowCount = 0
        foreach ($f in Get-ChildItem -Path $TrendDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
            foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, $utf8)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                $rec = $null; try { $rec = $ln | ConvertFrom-Json } catch { continue }
                $ts = $null; try { $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime() } catch { continue }
                if ($ts -lt $cutoff) { continue }
                $rowCount++
                $cid = [string]$rec.campaignId
                if ($cid) { $allCampaigns[$cid] = $true }
                $pk = Get-SPTrendPeriodKey -Dt $ts -Gran $Granularity
                if (-not $buckets.Contains($pk)) { $buckets[$pk] = @{ Campaigns = @{}; Closed = @{}; PrivRates = (New-Object System.Collections.Generic.List[double]); Compl = (New-Object System.Collections.Generic.List[double]); Captures = 0 } }
                $b = $buckets[$pk]; $b.Captures++
                if ($cid) { $b.Campaigns[$cid] = $true; if (([string]$rec.status).ToUpperInvariant() -eq 'COMPLETED') { $b.Closed[$cid] = $true } }
                $m = $rec.metrics
                if ($null -ne $m) {
                    $pr = if ($null -ne $m.PSObject.Properties['rates.privApprovalRate']) { $m.'rates.privApprovalRate' } else { $null }
                    if ($null -ne $pr) { try { $b.PrivRates.Add([double]$pr) } catch { } }
                    $cp = if ($null -ne $m.PSObject.Properties['completion.byReviewerPct']) { $m.'completion.byReviewerPct' } else { $null }
                    if ($null -ne $cp) { try { $b.Compl.Add([double]$cp) } catch { } }
                }
            }
        }
        if ($buckets.Count -eq 0) { return @{ Success = $true; Data = @{ Granularity = $Granularity; RowCount = 0; CampaignCount = 0; Periods = @(); Direction = @{} }; Error = $null } }

        $periods = [System.Collections.Generic.List[object]]::new()
        foreach ($pk in $buckets.Keys) {
            $b = $buckets[$pk]
            $avgPriv = if ($b.PrivRates.Count -gt 0) { [math]::Round((($b.PrivRates | Measure-Object -Average).Average), 4) } else { $null }
            $avgCompl = if ($b.Compl.Count -gt 0) { [math]::Round((($b.Compl | Measure-Object -Average).Average), 1) } else { $null }
            $periods.Add([PSCustomObject]@{ Period = $pk; Campaigns = $b.Campaigns.Count; Closed = $b.Closed.Count; AvgPrivApprovalRate = $avgPriv; AvgCompletion = $avgCompl; Captures = $b.Captures })
        }
        $periods = @($periods | Sort-Object Period)

        function _dir([object[]]$vals) {
            $nn = @($vals | Where-Object { $null -ne $_ })
            if ($nn.Count -lt 2) { return 'Flat' }
            $first = [double]$nn[0]; $last = [double]$nn[$nn.Count - 1]
            if ($first -eq 0) { return 'Flat' }
            $pct = (($last - $first) / [math]::Abs($first)) * 100
            if ($pct -gt 2) { return 'Up' } elseif ($pct -lt -2) { return 'Down' } else { return 'Flat' }
        }
        $direction = @{
            PrivApprovalRate = _dir @($periods | ForEach-Object { $_.AvgPrivApprovalRate })
            Closed           = _dir @($periods | ForEach-Object { [double]$_.Closed })
            Completion       = _dir @($periods | ForEach-Object { $_.AvgCompletion })
        }

        return @{ Success = $true; Data = @{ Granularity = $Granularity; RowCount = $rowCount; CampaignCount = $allCampaigns.Count; Periods = $periods; Direction = $direction }; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPProgramTrend failed: $($_.Exception.Message)" } }
}

function Export-SPProgramTrendHtml {
    <#
    .SYNOPSIS
        Renders the cross-campaign program trend (throughput + privileged-approval direction).
    .PARAMETER Trend
        Output of Get-SPProgramTrend (.Data).
    .PARAMETER OutputPath
        Target .html file (or directory).
    .OUTPUTS
        [hashtable] @{ Success; Data=<path>; Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Trend, [Parameter(Mandatory)][string]$OutputPath)
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $enc = { param($v) if ($null -eq $v) { '' } else { ConvertTo-SPHtmlSafe ([string]$v) } }
        $arrow = { param($d) switch ($d) { 'Up' { "<span style='color:#9a6700;font-weight:700'>&#9650; up</span>" } 'Down' { "<span style='color:#0a7d2c;font-weight:700'>&#9660; down</span>" } default { "<span style='color:#888'>flat</span>" } } }
        $css = "body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;}h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;}table{border-collapse:collapse;margin-top:8px;font-size:12px;}th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 10px;}td{border-bottom:1px solid #e3e9f0;padding:5px 10px;}.mv{background:#fff7e6;border:1px solid #ffd97a;border-radius:6px;padding:8px 12px;margin:8px 0;color:#7a5a00;font-size:12px;}.note{font-size:11px;color:#777;margin-top:8px;}"
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Program Governance Trend</title><style>$css</style></head><body>")
        [void]$sb.Append("<h1>Program Governance Trend</h1>")
        [void]$sb.Append("<div class='mv'>Across-the-program movement ($($Trend.Granularity) rollup, $($Trend.CampaignCount) campaign(s), $($Trend.RowCount) capture(s)). Privileged-approval rate: $(& $arrow $Trend.Direction.PrivApprovalRate) &middot; Campaigns closing: $(& $arrow $Trend.Direction.Closed) &middot; Completion: $(& $arrow $Trend.Direction.Completion). Management view &mdash; not certification evidence.</div>")
        if (@($Trend.Periods).Count -eq 0) { [void]$sb.Append("<div class='note'>No program trend data yet. It accumulates as diff/tracker runs append per-campaign KPI rows; closures appear as COMPLETED captures.</div>") }
        else {
            [void]$sb.Append("<table><tr><th>Period</th><th>Campaigns</th><th>Closed</th><th>Avg priv-approval rate</th><th>Avg completion</th><th>Captures</th></tr>")
            foreach ($p in @($Trend.Periods)) {
                $pr = if ($null -eq $p.AvgPrivApprovalRate) { '&mdash;' } else { "$([math]::Round($p.AvgPrivApprovalRate*100,1))%" }
                $cp = if ($null -eq $p.AvgCompletion) { '&mdash;' } else { "$($p.AvgCompletion)%" }
                [void]$sb.Append("<tr><td>$(& $enc $p.Period)</td><td>$($p.Campaigns)</td><td>$($p.Closed)</td><td>$pr</td><td>$cp</td><td>$($p.Captures)</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        [void]$sb.Append("<div class='note'>Privileged-approval rate is normalized (approved of privileged reviewed), so it is robust to scope/throughput growth. A rising rate is a discussion prompt, not a finding.</div>")
        [void]$sb.Append("</body></html>")
        $file = $OutputPath
        if ($OutputPath -notmatch '\.html?$') {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null }
            $file = Join-Path $OutputPath "program-trend-$($Trend.Granularity).html"
        }
        Write-SPHtmlFile -Path $file -Content $sb.ToString()
        return @{ Success = $true; Data = $file; Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Export-SPProgramTrendHtml failed: $($_.Exception.Message)" } }
}

#endregion

Export-ModuleMember -Function @(
    'Save-SPCampaignTrendPoint',
    'Get-SPCampaignTrend',
    'Export-SPCampaignTrendHtml',
    'Get-SPProgramTrend',
    'Export-SPProgramTrendHtml'
)
