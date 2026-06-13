<#
.SYNOPSIS
    SP.GovernanceTrendQuery -- read-only query layer that unifies both trend stores
    (per-campaign JSONL + governance-metrics.jsonl) into dashboard-ready outputs.

.DESCRIPTION
    Three functions:
      Get-SPGovernanceDashboardData  -- unified KPIs, sparklines, alerts, campaign throughput
      Compare-SPGovernancePeriods    -- period-over-period metric comparison
      Get-SPGovernanceAlerts         -- scan trend data for concerning patterns

    All functions are read-only. They never mutate the trend stores or call ISC APIs.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

# Ensure SP.Shared is loaded (provides ConvertTo-SPHtmlSafe, Get-SPObjectProperty, etc.)
$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

#region Internal helpers

function _TQ_SafeVal {
    # Safe property access for hashtable or PSCustomObject.
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

function _TQ_GetPeriodKey {
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

function _TQ_ComputeDirection {
    # Returns 'Up', 'Down', or 'Flat' based on >5% threshold.
    param([double]$Current, [double]$Previous)
    if ($Previous -eq 0) {
        if ($Current -eq 0) { return 'Flat' }
        return 'Up'
    }
    $changePct = (($Current - $Previous) / [math]::Abs($Previous)) * 100
    if ($changePct -gt 5)  { return 'Up' }
    if ($changePct -lt -5) { return 'Down' }
    return 'Flat'
}

function _TQ_PeriodDays {
    param([string]$Period)
    switch ($Period) {
        'Last7Days'  { return 7 }
        'Last30Days' { return 30 }
        'Last90Days' { return 90 }
        'AllTime'    { return 3650 }
    }
    return 30
}

function _TQ_ReadAllCampaignTrends {
    # Reads all campaign JSONL files from the trend directory and returns raw records.
    param([int]$DaysBack = 30)

    $trendDir = $null
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.PSObject.Properties['Metrics']) {
            if ($null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendPath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Metrics.CampaignTrendPath)) {
                $trendDir = [string]$cfg.Metrics.CampaignTrendPath
            }
            elseif ($null -ne $cfg.Metrics.PSObject.Properties['Path'] -and
                    -not [string]::IsNullOrWhiteSpace($cfg.Metrics.Path)) {
                $trendDir = Join-Path ([string]$cfg.Metrics.Path) 'campaign-trend'
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($trendDir)) { $trendDir = '.\Audit\metrics\campaign-trend' }
    if (-not [System.IO.Path]::IsPathRooted($trendDir)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $trendDir = [System.IO.Path]::GetFullPath((Join-Path $root $trendDir))
    }

    $records = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $trendDir)) { return @($records) }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $cutoff = (Get-Date).AddDays(-$DaysBack).ToUniversalTime()

    # Search the root and one level of subdirectories (env subfolders)
    $searchDirs = @($trendDir)
    try {
        $subDirs = Get-ChildItem -Path $trendDir -Directory -ErrorAction SilentlyContinue
        foreach ($sd in $subDirs) { $searchDirs += $sd.FullName }
    } catch { }

    foreach ($dir in $searchDirs) {
        foreach ($f in Get-ChildItem -Path $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
            try {
                foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, $utf8)) {
                    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                    try {
                        $rec = $ln | ConvertFrom-Json
                        $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime()
                        if ($ts -ge $cutoff) { $records.Add($rec) }
                    } catch { }
                }
            } catch { }
        }
    }
    return @($records | Sort-Object { [datetime]::Parse([string]$_.timestamp) })
}

#endregion

#region Public: Get-SPGovernanceDashboardData

function Get-SPGovernanceDashboardData {
    <#
    .SYNOPSIS
        Reads both trend stores and computes unified KPIs with direction arrows.
    .DESCRIPTION
        Reads governance metrics via Get-SPGovernanceMetricsTrend and all campaign
        trend files by globbing the CampaignTrendPath directory. For each metric,
        computes: current value, previous period value, direction (Up/Down/Flat),
        delta. Builds sparkline data bucketed weekly.
    .PARAMETER Period
        Time window: Last7Days, Last30Days, Last90Days, AllTime. Default Last30Days.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] Unified dashboard data with KPIs, Sparklines, Alerts, Campaigns.
    .EXAMPLE
        $dashboard = Get-SPGovernanceDashboardData -Period Last30Days
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Last7Days','Last30Days','Last90Days','AllTime')]
        [string]$Period = 'Last30Days',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.GovernanceTrendQuery'
    $action    = 'Get-SPGovernanceDashboardData'

    Write-SPLog -Message "Get-SPGovernanceDashboardData: Period=$Period" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    $daysBack = _TQ_PeriodDays $Period

    # Empty result template
    $emptyKPI = @{ Value = $null; Direction = 'Flat'; Delta = $null; Periods = 0 }
    $emptyResult = @{
        CapturedAt = (Get-Date).ToUniversalTime()
        Period     = $Period
        KPIs       = @{
            MaturityScore      = $emptyKPI.Clone()
            ActiveCampaigns    = $emptyKPI.Clone()
            PrivApprovalRate   = $emptyKPI.Clone()
            ReviewerCompletion = $emptyKPI.Clone()
            StaleAccessCount   = $emptyKPI.Clone()
        }
        Sparklines = @{
            MaturityScore      = @()
            ActiveCampaigns    = @()
            PrivApprovalRate   = @()
            ReviewerCompletion = @()
            StaleAccessCount   = @()
        }
        Alerts     = @()
        Campaigns  = @{
            Active    = @{ Count = 0; Overdue = 0 }
            Completed = @{ Count = 0; AvgDays = $null }
        }
    }

    # 1. Read governance metrics
    $govRecords = @()
    try {
        $govRecords = @(Get-SPGovernanceMetrics -DaysBack $daysBack -CorrelationID $CorrelationID)
    } catch {
        Write-SPLog -Message "Failed to read governance metrics: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    # 2. Read all campaign trend records
    $campRecords = @()
    try {
        $campRecords = @(_TQ_ReadAllCampaignTrends -DaysBack $daysBack)
    } catch {
        Write-SPLog -Message "Failed to read campaign trends: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    if ($govRecords.Count -eq 0 -and $campRecords.Count -eq 0) {
        Write-SPLog -Message 'No trend data available for dashboard' `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return $emptyResult
    }

    # --- Extract metric series from governance metrics ---
    $maturitySeries    = [System.Collections.Generic.List[object]]::new()
    $activeCampSeries  = [System.Collections.Generic.List[object]]::new()
    $reviewerCompSeries= [System.Collections.Generic.List[object]]::new()
    $staleAccessSeries = [System.Collections.Generic.List[object]]::new()

    foreach ($rec in $govRecords) {
        $ts = $null
        try { $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime() } catch { continue }
        $m = _TQ_SafeVal $rec 'metrics'
        if ($null -eq $m) { continue }

        $matVal = _TQ_SafeVal $m 'maturity.overallScore'
        if ($null -ne $matVal) { $maturitySeries.Add(@{ Timestamp = $ts; Value = [double]$matVal }) }

        $acVal = _TQ_SafeVal $m 'campaigns.activeCount'
        if ($null -ne $acVal) { $activeCampSeries.Add(@{ Timestamp = $ts; Value = [double]$acVal }) }

        $rcVal = _TQ_SafeVal $m 'reviewers.avgCompletionPct'
        if ($null -ne $rcVal) { $reviewerCompSeries.Add(@{ Timestamp = $ts; Value = [double]$rcVal }) }

        $saVal = _TQ_SafeVal $m 'staleAccess.totalItems'
        if ($null -ne $saVal) { $staleAccessSeries.Add(@{ Timestamp = $ts; Value = [double]$saVal }) }
    }

    # --- Extract priv approval rate series from campaign trends ---
    $privApprovalSeries = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $campRecords) {
        $ts = $null
        try { $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime() } catch { continue }
        $m = $null
        if ($null -ne $rec.metrics) {
            $pr = $null
            try {
                if ($rec.metrics -is [System.Collections.IDictionary]) {
                    if ($rec.metrics.Contains('rates.privApprovalRate')) { $pr = $rec.metrics['rates.privApprovalRate'] }
                } else {
                    $prop = $rec.metrics.PSObject.Properties['rates.privApprovalRate']
                    if ($null -ne $prop) { $pr = $prop.Value }
                }
            } catch { }
            if ($null -ne $pr) {
                $privApprovalSeries.Add(@{ Timestamp = $ts; Value = [double]$pr })
            }
        }
    }

    # --- Helper: compute KPI from a series ---
    function _BuildKPI {
        param(
            [System.Collections.Generic.List[object]]$Series,
            [string]$FormatStr,
            [bool]$AsPercent = $false
        )
        if ($null -eq $Series -or $Series.Count -eq 0) {
            return @{ Value = $null; Direction = 'Flat'; Delta = $null; Periods = 0 }
        }
        $sorted = @($Series | Sort-Object { $_.Timestamp })
        $current = $sorted[$sorted.Count - 1].Value

        # Bucket into weeks for period count
        $weekBuckets = @{}
        foreach ($pt in $sorted) {
            $wk = _TQ_GetPeriodKey -Dt $pt.Timestamp -Gran 'Weekly'
            $weekBuckets[$wk] = $pt.Value
        }
        $periodCount = $weekBuckets.Count

        # Previous value: the earliest value in the window
        $previous = $sorted[0].Value

        $dir = _TQ_ComputeDirection -Current $current -Previous $previous
        $delta = [math]::Round($current - $previous, 2)
        $deltaStr = ''
        if ($AsPercent) {
            $currentStr = "$([math]::Round($current * 100, 1))%"
            $deltaStr   = "$(if ($delta -gt 0) { '+' })$([math]::Round($delta * 100, 1))%"
        } else {
            $currentStr = $current
            $deltaStr   = "$(if ($delta -gt 0) { '+' })$delta"
        }

        return @{
            Value     = $currentStr
            Direction = $dir
            Delta     = $deltaStr
            Periods   = $periodCount
        }
    }

    # --- Helper: build sparkline array from series (weekly buckets, latest per week) ---
    function _BuildSparkline {
        param([System.Collections.Generic.List[object]]$Series)
        if ($null -eq $Series -or $Series.Count -eq 0) { return @() }
        $sorted = @($Series | Sort-Object { $_.Timestamp })
        $weekBuckets = [ordered]@{}
        foreach ($pt in $sorted) {
            $wk = _TQ_GetPeriodKey -Dt $pt.Timestamp -Gran 'Weekly'
            $weekBuckets[$wk] = $pt.Value
        }
        return @($weekBuckets.Values)
    }

    # --- Build KPIs ---
    $kpis = @{
        MaturityScore      = _BuildKPI -Series $maturitySeries
        ActiveCampaigns    = _BuildKPI -Series $activeCampSeries
        PrivApprovalRate   = _BuildKPI -Series $privApprovalSeries -AsPercent $true
        ReviewerCompletion = _BuildKPI -Series $reviewerCompSeries -AsPercent $false
        StaleAccessCount   = _BuildKPI -Series $staleAccessSeries
    }

    # --- Build Sparklines ---
    $sparklines = @{
        MaturityScore      = _BuildSparkline -Series $maturitySeries
        ActiveCampaigns    = _BuildSparkline -Series $activeCampSeries
        PrivApprovalRate   = _BuildSparkline -Series $privApprovalSeries
        ReviewerCompletion = _BuildSparkline -Series $reviewerCompSeries
        StaleAccessCount   = _BuildSparkline -Series $staleAccessSeries
    }

    # --- Build Campaign throughput from the latest governance metrics record ---
    $campaignData = @{
        Active    = @{ Count = 0; Overdue = 0 }
        Completed = @{ Count = 0; AvgDays = $null }
    }
    if ($govRecords.Count -gt 0) {
        $latest = $govRecords[$govRecords.Count - 1]
        $lm = _TQ_SafeVal $latest 'metrics'
        if ($null -ne $lm) {
            $ac = _TQ_SafeVal $lm 'campaigns.activeCount'
            $od = _TQ_SafeVal $lm 'campaigns.overdueCount'
            $cc = _TQ_SafeVal $lm 'campaigns.completedCount'
            $ad = _TQ_SafeVal $lm 'campaigns.avgDaysToComplete'
            $campaignData = @{
                Active    = @{
                    Count   = if ($null -ne $ac) { [int]$ac } else { 0 }
                    Overdue = if ($null -ne $od) { [int]$od } else { 0 }
                }
                Completed = @{
                    Count   = if ($null -ne $cc) { [int]$cc } else { 0 }
                    AvgDays = if ($null -ne $ad) { [math]::Round([double]$ad, 1) } else { $null }
                }
            }
        }
    }

    # --- Generate Alerts ---
    $alerts = @()
    try {
        $alerts = @(Get-SPGovernanceAlerts -LookbackDays $daysBack -CorrelationID $CorrelationID)
    } catch {
        Write-SPLog -Message "Alert generation failed: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    Write-SPLog -Message "Get-SPGovernanceDashboardData: $($govRecords.Count) gov records, $($campRecords.Count) campaign records, $($alerts.Count) alerts" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        CapturedAt = (Get-Date).ToUniversalTime()
        Period     = $Period
        KPIs       = $kpis
        Sparklines = $sparklines
        Alerts     = $alerts
        Campaigns  = $campaignData
    }
}

#endregion

#region Public: Compare-SPGovernancePeriods

function Compare-SPGovernancePeriods {
    <#
    .SYNOPSIS
        Compares governance metrics between two periods.
    .DESCRIPTION
        Reads governance metrics, filters to each period, aggregates (average for
        rates, sum for counts, latest for scores), returns comparison with deltas.
    .PARAMETER Period1
        First period label, e.g. 'YYYY-MM' for months or 'YYYY-Wnn' for weeks.
    .PARAMETER Period2
        Second period label.
    .PARAMETER Granularity
        How to bucket records: Month or Week. Default Month.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Period1; Period2; Metrics = @{ metricName -> @{ Before; After; Delta; Direction } } }
    .EXAMPLE
        Compare-SPGovernancePeriods -Period1 '2026-05' -Period2 '2026-06'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Period1,

        [Parameter(Mandatory)]
        [string]$Period2,

        [Parameter()]
        [ValidateSet('Month','Week')]
        [string]$Granularity = 'Month',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.GovernanceTrendQuery'
    $action    = 'Compare-SPGovernancePeriods'

    Write-SPLog -Message "Compare-SPGovernancePeriods: $Period1 vs $Period2 ($Granularity)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    # Determine days back -- enough to cover both periods (generous: 365 days)
    $govRecords = @()
    try {
        $govRecords = @(Get-SPGovernanceMetrics -DaysBack 365 -CorrelationID $CorrelationID)
    } catch {
        Write-SPLog -Message "Failed to read governance metrics: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    $emptyResult = @{
        Period1 = $Period1
        Period2 = $Period2
        Metrics = @{}
    }

    if ($govRecords.Count -eq 0) { return $emptyResult }

    # Map granularity to trend granularity key
    $gran = if ($Granularity -eq 'Week') { 'Weekly' } else { 'Monthly' }

    # Bucket records into their period
    $p1Records = [System.Collections.Generic.List[hashtable]]::new()
    $p2Records = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($rec in $govRecords) {
        $ts = $null
        try { $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime() } catch { continue }
        $pk = _TQ_GetPeriodKey -Dt $ts -Gran $gran
        if ($pk -eq $Period1) { $p1Records.Add($rec) }
        elseif ($pk -eq $Period2) { $p2Records.Add($rec) }
    }

    # Collect all metric names across both periods
    $allMetricNames = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($rec in @($p1Records) + @($p2Records)) {
        $m = _TQ_SafeVal $rec 'metrics'
        if ($null -eq $m) { continue }
        if ($m -is [System.Collections.IDictionary]) {
            foreach ($k in $m.Keys) { [void]$allMetricNames.Add($k) }
        } else {
            foreach ($p in $m.PSObject.Properties) { [void]$allMetricNames.Add($p.Name) }
        }
    }

    if ($allMetricNames.Count -eq 0) { return $emptyResult }

    # Metrics that should use 'latest' aggregation (scores, levels)
    $latestMetrics = @('maturity.overallScore', 'maturity.overallLevel')
    # Metrics that should use 'sum' aggregation (counts)
    $sumMetrics = @('campaigns.completedCount')

    # Aggregate: for each metric, compute the aggregate for each period
    $metrics = @{}
    foreach ($metricName in $allMetricNames) {
        $p1Values = [System.Collections.Generic.List[double]]::new()
        $p2Values = [System.Collections.Generic.List[double]]::new()

        foreach ($rec in $p1Records) {
            $m = _TQ_SafeVal $rec 'metrics'
            $v = _TQ_SafeVal $m $metricName
            if ($null -ne $v) { try { $p1Values.Add([double]$v) } catch { } }
        }
        foreach ($rec in $p2Records) {
            $m = _TQ_SafeVal $rec 'metrics'
            $v = _TQ_SafeVal $m $metricName
            if ($null -ne $v) { try { $p2Values.Add([double]$v) } catch { } }
        }

        # Both empty -- skip
        if ($p1Values.Count -eq 0 -and $p2Values.Count -eq 0) { continue }

        # Determine aggregation method
        $p1Agg = $null
        $p2Agg = $null

        if ($metricName -in $latestMetrics) {
            if ($p1Values.Count -gt 0) { $p1Agg = $p1Values[$p1Values.Count - 1] }
            if ($p2Values.Count -gt 0) { $p2Agg = $p2Values[$p2Values.Count - 1] }
        }
        elseif ($metricName -in $sumMetrics) {
            if ($p1Values.Count -gt 0) { $p1Agg = 0; foreach ($v in $p1Values) { $p1Agg += $v } }
            if ($p2Values.Count -gt 0) { $p2Agg = 0; foreach ($v in $p2Values) { $p2Agg += $v } }
        }
        else {
            # Default: average
            if ($p1Values.Count -gt 0) { $p1Agg = [math]::Round(($p1Values | Measure-Object -Average).Average, 4) }
            if ($p2Values.Count -gt 0) { $p2Agg = [math]::Round(($p2Values | Measure-Object -Average).Average, 4) }
        }

        $delta = $null
        $dir   = 'Flat'
        if ($null -ne $p1Agg -and $null -ne $p2Agg) {
            $delta = [math]::Round($p2Agg - $p1Agg, 4)
            $dir   = _TQ_ComputeDirection -Current $p2Agg -Previous $p1Agg
        }
        elseif ($null -eq $p1Agg -and $null -ne $p2Agg) {
            $delta = $p2Agg
            $dir = 'Up'
        }
        elseif ($null -ne $p1Agg -and $null -eq $p2Agg) {
            $delta = -$p1Agg
            $dir = 'Down'
        }

        $metrics[$metricName] = @{
            Before    = $p1Agg
            After     = $p2Agg
            Delta     = $delta
            Direction = $dir
        }
    }

    Write-SPLog -Message "Compare-SPGovernancePeriods: $($metrics.Count) metrics compared" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @{
        Period1 = $Period1
        Period2 = $Period2
        Metrics = $metrics
    }
}

#endregion

#region Public: Get-SPGovernanceAlerts

function Get-SPGovernanceAlerts {
    <#
    .SYNOPSIS
        Scans trend data for concerning patterns and returns alert objects.
    .DESCRIPTION
        Reads governance metrics and campaign trends, then checks for:
        - Metrics declining for N+ consecutive periods
        - Maturity score dropped
        - Stale access count growing
        - High rubber-stamp percentage (if available)
        - Overdue campaigns
    .PARAMETER LookbackDays
        Number of days to examine. Default 30.
    .PARAMETER ConsecutiveDeclineThreshold
        How many consecutive declining periods trigger an alert. Default 3.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable[]] Array of alert objects.
    .EXAMPLE
        $alerts = Get-SPGovernanceAlerts -LookbackDays 30
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$LookbackDays = 30,

        [Parameter()]
        [int]$ConsecutiveDeclineThreshold = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $component = 'SP.GovernanceTrendQuery'
    $action    = 'Get-SPGovernanceAlerts'

    Write-SPLog -Message "Get-SPGovernanceAlerts: LookbackDays=$LookbackDays ConsecutiveDeclineThreshold=$ConsecutiveDeclineThreshold" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    $alerts = [System.Collections.Generic.List[hashtable]]::new()

    # Read governance metrics
    $govRecords = @()
    try {
        $govRecords = @(Get-SPGovernanceMetrics -DaysBack $LookbackDays -CorrelationID $CorrelationID)
    } catch {
        Write-SPLog -Message "Failed to read governance metrics for alerts: $($_.Exception.Message)" `
            -Severity WARN -Component $component -Action $action -CorrelationID $CorrelationID
    }

    if ($govRecords.Count -lt 2) {
        Write-SPLog -Message 'Not enough data points for alert analysis' `
            -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID
        return @($alerts)
    }

    # --- Check: Maturity score decline ---
    $maturityValues = [System.Collections.Generic.List[double]]::new()
    foreach ($rec in $govRecords) {
        $m = _TQ_SafeVal $rec 'metrics'
        $v = _TQ_SafeVal $m 'maturity.overallScore'
        if ($null -ne $v) { try { $maturityValues.Add([double]$v) } catch { } }
    }
    if ($maturityValues.Count -ge 2) {
        $first = $maturityValues[0]
        $last  = $maturityValues[$maturityValues.Count - 1]
        if ($last -lt $first) {
            $severity = if (($first - $last) -gt 0.5) { 'Red' } else { 'Amber' }
            $alerts.Add(@{
                Severity   = $severity
                Metric     = 'maturity.overallScore'
                Message    = "Maturity score dropped from $first to $last over ${LookbackDays} days"
                Value      = $last
                PriorValue = $first
            })
        }
    }

    # --- Check: Stale access growing ---
    $staleValues = [System.Collections.Generic.List[double]]::new()
    foreach ($rec in $govRecords) {
        $m = _TQ_SafeVal $rec 'metrics'
        $v = _TQ_SafeVal $m 'staleAccess.totalItems'
        if ($null -ne $v) { try { $staleValues.Add([double]$v) } catch { } }
    }
    if ($staleValues.Count -ge 2) {
        $first = $staleValues[0]
        $last  = $staleValues[$staleValues.Count - 1]
        if ($last -gt $first -and $first -gt 0) {
            $pctChange = [math]::Round((($last - $first) / $first) * 100, 1)
            if ($pctChange -gt 5) {
                $severity = if ($pctChange -gt 20) { 'Red' } else { 'Amber' }
                $alerts.Add(@{
                    Severity   = $severity
                    Metric     = 'staleAccess.totalItems'
                    Message    = "Stale access items rose from $([int]$first) to $([int]$last) (+${pctChange}%) over ${LookbackDays} days"
                    Value      = [int]$last
                    PriorValue = [int]$first
                })
            }
        }
    }

    # --- Check: Overdue campaigns ---
    if ($govRecords.Count -gt 0) {
        $latestRec = $govRecords[$govRecords.Count - 1]
        $lm = _TQ_SafeVal $latestRec 'metrics'
        $overdue = _TQ_SafeVal $lm 'campaigns.overdueCount'
        if ($null -ne $overdue -and [int]$overdue -gt 0) {
            $severity = if ([int]$overdue -gt 2) { 'Red' } else { 'Amber' }
            $alerts.Add(@{
                Severity   = $severity
                Metric     = 'campaigns.overdueCount'
                Message    = "$([int]$overdue) campaign(s) are past deadline but not completed"
                Value      = [int]$overdue
                PriorValue = $null
            })
        }
    }

    # --- Check: Consecutive declining metrics ---
    # Track specific metrics for consecutive decline detection
    $metricsToWatch = @(
        'maturity.overallScore',
        'reviewers.avgCompletionPct',
        'sourceGovernance.coveragePct',
        'sourceGovernance.avgScore',
        'campaigns.avgApprovalRate'
    )

    foreach ($metricName in $metricsToWatch) {
        $vals = [System.Collections.Generic.List[double]]::new()
        foreach ($rec in $govRecords) {
            $m = _TQ_SafeVal $rec 'metrics'
            $v = _TQ_SafeVal $m $metricName
            if ($null -ne $v) { try { $vals.Add([double]$v) } catch { } }
        }
        if ($vals.Count -lt $ConsecutiveDeclineThreshold + 1) { continue }

        # Count consecutive declines from the latest backward
        $consecutiveDeclines = 0
        for ($i = $vals.Count - 1; $i -gt 0; $i--) {
            if ($vals[$i] -lt $vals[$i - 1]) {
                $consecutiveDeclines++
            } else {
                break
            }
        }

        if ($consecutiveDeclines -ge $ConsecutiveDeclineThreshold) {
            $firstVal = $vals[$vals.Count - 1 - $consecutiveDeclines]
            $lastVal  = $vals[$vals.Count - 1]
            $alerts.Add(@{
                Severity   = 'Amber'
                Metric     = $metricName
                Message    = "$metricName declined for $consecutiveDeclines consecutive periods (from $firstVal to $lastVal)"
                Value      = $lastVal
                PriorValue = $firstVal
            })
        }
    }

    # --- Check: High rubber-stamp / at-risk reviewer count ---
    if ($govRecords.Count -gt 0) {
        $latestRec = $govRecords[$govRecords.Count - 1]
        $lm = _TQ_SafeVal $latestRec 'metrics'
        $atRisk = _TQ_SafeVal $lm 'reviewers.atRiskCount'
        if ($null -ne $atRisk -and [int]$atRisk -gt 0) {
            $totalActive = _TQ_SafeVal $lm 'reviewers.totalActive'
            $pctAtRisk = 0
            if ($null -ne $totalActive -and [int]$totalActive -gt 0) {
                $pctAtRisk = [math]::Round(([int]$atRisk / [int]$totalActive) * 100, 1)
            }
            if ($pctAtRisk -gt 20) {
                $alerts.Add(@{
                    Severity   = 'Red'
                    Metric     = 'reviewers.atRiskCount'
                    Message    = "$([int]$atRisk) reviewer(s) at risk (${pctAtRisk}% of active reviewers)"
                    Value      = [int]$atRisk
                    PriorValue = $null
                })
            } elseif ([int]$atRisk -gt 0) {
                $alerts.Add(@{
                    Severity   = 'Amber'
                    Metric     = 'reviewers.atRiskCount'
                    Message    = "$([int]$atRisk) reviewer(s) at risk"
                    Value      = [int]$atRisk
                    PriorValue = $null
                })
            }
        }
    }

    Write-SPLog -Message "Get-SPGovernanceAlerts: generated $($alerts.Count) alert(s)" `
        -Severity INFO -Component $component -Action $action -CorrelationID $CorrelationID

    return @($alerts)
}

#endregion
