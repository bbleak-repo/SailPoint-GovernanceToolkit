#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Campaign Audit Analytics
.DESCRIPTION
    Provides trend analysis, risk scoring, cross-campaign comparison, source governance
    scoring, and reviewer reputation analytics. Consumes structured output from
    SP.AuditReportCore and produces analysis objects suitable for HTML export by
    SP.AuditReportHtml.
.NOTES
    Module: SP.Audit / SP.AuditAnalytics
    Version: 1.0.0
    Component: Audit Analytics

    Color taxonomy:
        Green  #339933 - Approved / success
        Red    #CC3333 - Revoked / error
        Orange #FF8800 - Pending / warn
        Blue   #336699 - Info / neutral
        Gray   #777777 - N/A / footer
#>

#region Campaign Comparison

function Compare-SPCampaigns {
    <#
    .SYNOPSIS
        Side-by-side comparison of metrics for two or more campaigns.
    .DESCRIPTION
        Accepts campaign IDs (resolved via API) or pre-fetched campaign objects,
        runs Measure-SPCampaignMetrics on each, then returns a comparison table
        with per-metric delta highlighting.

        Output options:
          - PSCustomObject comparison table (default)
          - HTML comparison report via Export-SPCampaignComparisonHtml
          - CSV export via Export-Csv pipeline

        All DateTime comparisons use .ToUniversalTime() to avoid Kind mismatch.
    .PARAMETER CampaignIds
        Two or more campaign IDs to compare. Campaigns are fetched from the API.
    .PARAMETER Campaigns
        Pre-fetched campaign objects (as from Get-SPAuditCampaigns). Use instead
        of CampaignIds to avoid redundant API calls.
    .PARAMETER OutputMode
        Console (default), HTML, or CSV.
    .PARAMETER OutputPath
        Directory for HTML/CSV output. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID for log tracing.
    .OUTPUTS
        [hashtable] @{ Success; Data; Error }
        Data contains: Metrics (array of per-campaign metric objects),
                       ComparisonTable (array of row objects for display),
                       HtmlPath (if OutputMode=HTML)
    .EXAMPLE
        $result = Compare-SPCampaigns -CampaignIds 'camp-001','camp-002'
        $result.Data.ComparisonTable | Format-Table
    .EXAMPLE
        Compare-SPCampaigns -CampaignIds 'camp-001','camp-002' -OutputMode HTML -OutputPath '.\Reports'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateCount(2, 20)]
        [string[]]$CampaignIds,

        [Parameter(Mandatory, ParameterSetName = 'ByObject')]
        [ValidateCount(2, 20)]
        [object[]]$Campaigns,

        [Parameter()]
        [ValidateSet('Console', 'HTML', 'CSV')]
        [string]$OutputMode = 'Console',

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Compare-SPCampaigns: starting comparison" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
        -CorrelationID $CorrelationID

    try {
        # --- Resolve campaigns ---
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            # Fetch each campaign by searching all campaigns and filtering
            $allCampsResult = Get-SPAuditCampaigns -Status @('STAGED','ACTIVATING','ACTIVE','COMPLETING','COMPLETED') `
                -DaysBack 3650 -CorrelationID $CorrelationID
            if (-not $allCampsResult.Success) {
                return @{ Success = $false; Data = $null; Error = "Failed to fetch campaigns: $($allCampsResult.Error)" }
            }

            $campObjects = [System.Collections.Generic.List[object]]::new()
            foreach ($cid in $CampaignIds) {
                $match = $allCampsResult.Data | Where-Object { $_.id -eq $cid }
                if ($null -eq $match) {
                    return @{ Success = $false; Data = $null; Error = "Campaign not found: $cid" }
                }
                $campObjects.Add($match)
            }
            $Campaigns = $campObjects.ToArray()
        }

        # --- Compute metrics via Measure-SPCampaignMetrics ---
        $metricsResult = Measure-SPCampaignMetrics -Campaigns $Campaigns -CorrelationID $CorrelationID
        if (-not $metricsResult.Success) {
            return @{ Success = $false; Data = $null; Error = "Metrics calculation failed: $($metricsResult.Error)" }
        }

        $metrics = @($metricsResult.Data)
        if ($metrics.Count -lt 2) {
            return @{ Success = $false; Data = $null; Error = "Need metrics for at least 2 campaigns, got $($metrics.Count)" }
        }

        # --- Build comparison table (metric-per-row, campaign-per-column) ---
        $metricDefs = @(
            @{ Label = 'Campaign Name';       Prop = 'CampaignName';            Format = 'string' }
            @{ Label = 'Type';                 Prop = 'CampaignType';            Format = 'string' }
            @{ Label = 'Status';               Prop = 'CampaignStatus';          Format = 'string' }
            @{ Label = 'Created';              Prop = 'CampaignCreated';         Format = 'date' }
            @{ Label = 'Deadline';             Prop = 'CampaignDeadline';        Format = 'date' }
            @{ Label = 'Total Items';          Prop = 'TotalItems';              Format = 'int' }
            @{ Label = 'Approved';             Prop = 'ApprovedCount';           Format = 'int' }
            @{ Label = 'Revoked';              Prop = 'RevokedCount';            Format = 'int' }
            @{ Label = 'Pending';              Prop = 'PendingCount';            Format = 'int' }
            @{ Label = 'Approval Rate (%)';    Prop = 'ApprovalRate';            Format = 'pct' }
            @{ Label = 'Revocation Rate (%)';  Prop = 'RevocationRate';          Format = 'pct' }
            @{ Label = 'Completion Rate (%)';  Prop = 'CompletionRate';          Format = 'pct' }
            @{ Label = 'Reviewer Count';       Prop = 'ReviewerCount';           Format = 'int' }
            @{ Label = 'Reassignment Count';   Prop = 'ReassignmentCount';       Format = 'int' }
            @{ Label = 'Avg Response (hours)'; Prop = 'AvgResponseTimeHours';    Format = 'hours' }
            @{ Label = 'Fastest Reviewer';     Prop = 'FastestReviewer';         Format = 'string' }
            @{ Label = 'Slowest Reviewer';     Prop = 'SlowestReviewer';         Format = 'string' }
            @{ Label = 'Deadline Status';      Prop = 'DeadlineStatus';          Format = 'string' }
        )

        $comparisonRows = [System.Collections.Generic.List[object]]::new()
        foreach ($mdef in $metricDefs) {
            $row = [ordered]@{ Metric = $mdef.Label }
            for ($i = 0; $i -lt $metrics.Count; $i++) {
                $val = $metrics[$i].PSObject.Properties[$mdef.Prop].Value
                $colName = "Campaign_$($i + 1)"
                $row[$colName] = $val
            }

            # Delta column (first two campaigns only, numeric types)
            if ($metrics.Count -ge 2 -and $mdef.Format -in @('int', 'pct', 'hours')) {
                $v1 = $metrics[0].PSObject.Properties[$mdef.Prop].Value
                $v2 = $metrics[1].PSObject.Properties[$mdef.Prop].Value
                if ($null -ne $v1 -and $null -ne $v2) {
                    $delta = [Math]::Round(([double]$v2 - [double]$v1), 1)
                    $sign = if ($delta -gt 0) { '+' } else { '' }
                    $row['Delta_1v2'] = "${sign}${delta}"
                }
                else {
                    $row['Delta_1v2'] = 'N/A'
                }
            }

            $comparisonRows.Add([PSCustomObject]$row)
        }

        $resultData = @{
            Metrics         = $metrics
            ComparisonTable = $comparisonRows.ToArray()
            HtmlPath        = $null
            CsvPath         = $null
        }

        # --- Output mode handling ---
        if ($OutputMode -eq 'HTML') {
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = (Get-Location).Path
            }
            $htmlPath = Export-SPCampaignComparisonHtml -Metrics $metrics `
                -MetricDefs $metricDefs -OutputPath $OutputPath -CorrelationID $CorrelationID
            $resultData.HtmlPath = $htmlPath
            Write-SPLog -Message "HTML comparison report written: $htmlPath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
                -CorrelationID $CorrelationID
        }
        elseif ($OutputMode -eq 'CSV') {
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = (Get-Location).Path
            }
            if (-not (Test-Path -Path $OutputPath -PathType Container)) {
                New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
            }
            $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $csvPath = Join-Path $OutputPath "CampaignComparison-${timestamp}.csv"
            $comparisonRows.ToArray() | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            $resultData.CsvPath = $csvPath
            Write-SPLog -Message "CSV comparison written: $csvPath" `
                -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
                -CorrelationID $CorrelationID
        }

        Write-SPLog -Message "Compare-SPCampaigns: compared $($metrics.Count) campaigns" `
            -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPCampaigns' `
            -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = $resultData
            Error   = $null
        }
    }
    catch {
        $errMsg = "Compare-SPCampaigns failed: $($_.Exception.Message)"
        Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.AuditReport' `
            -Action 'Compare-SPCampaigns' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = $errMsg }
    }
}

#endregion

#region Audit Trail Consolidator

function Get-SPAuditTrail {
    <#
    .SYNOPSIS
        Reads all JSONL audit files and produces a unified, chronologically sorted timeline.
    .DESCRIPTION
        Consolidates events from three JSONL sources:
          - {Audit.OutputPath}/audit-*.jsonl   (campaign audit events)
          - {DeltaCert.OutputPath}/deltacert-audit.jsonl  (delta cert run events)
          - {DeltaCert.OutputPath}/deltacert-escalation.jsonl  (escalation events)

        Each event is normalised to a common schema: Timestamp, EventType, Action,
        CorrelationID, SourceIds, Summary, Details, FilePath.

        Supports filtering by date range, correlation ID, event type, and source ID.
        Returns newest-first, capped at MaxEvents.
    .PARAMETER After
        Only include events after this datetime.
    .PARAMETER Before
        Only include events before this datetime.
    .PARAMETER CorrelationID
        Filter to events matching this correlation ID.
    .PARAMETER EventType
        Filter to specific event types: 'CampaignAudit', 'DeltaCertRun', 'Escalation'.
    .PARAMETER SourceId
        Filter to events involving this source ID.
    .PARAMETER AuditOutputPath
        Directory containing campaign audit JSONL files. Resolved from config if omitted.
    .PARAMETER DeltaCertOutputPath
        Directory containing delta cert JSONL files. Resolved from config if omitted.
    .PARAMETER MaxEvents
        Maximum number of events to return. Default: 500.
    .OUTPUTS
        [PSCustomObject[]] Array of normalised audit trail events.
    .EXAMPLE
        $trail = Get-SPAuditTrail -After (Get-Date).AddDays(-7) -EventType 'Escalation'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()][DateTime]$After,
        [Parameter()][DateTime]$Before,
        [Parameter()][string]$CorrelationID,
        [Parameter()][string[]]$EventType,
        [Parameter()][string]$SourceId,
        [Parameter()][string]$AuditOutputPath,
        [Parameter()][string]$DeltaCertOutputPath,
        [Parameter()][int]$MaxEvents = 500
    )

    $logCorrelation = if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        [guid]::NewGuid().ToString()
    } else { $CorrelationID }

    Write-SPLog -Message "Get-SPAuditTrail: starting consolidation" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
        -CorrelationID $logCorrelation

    # Resolve paths from config if not provided
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or
        [string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) {
        try {
            $config = Get-SPConfig
            if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'Audit' -and
                $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
                $AuditOutputPath = $config.Audit.OutputPath
            }
            if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath) -and
                $null -ne $config -and
                $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                $DeltaCertOutputPath = $config.DeltaCert.OutputPath
            }
        }
        catch {
            Write-SPLog -Message "Could not load config for path resolution: $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                -CorrelationID $logCorrelation
        }
    }
    if ([string]::IsNullOrWhiteSpace($AuditOutputPath))     { $AuditOutputPath     = '.\Audit' }
    if ([string]::IsNullOrWhiteSpace($DeltaCertOutputPath)) { $DeltaCertOutputPath = '.\DeltaCert' }

    $allEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Collect JSONL files and their event type mappings
    $fileMappings = [System.Collections.Generic.List[hashtable]]::new()

    # Campaign audit files: audit-*.jsonl
    if (Test-Path -Path $AuditOutputPath -PathType Container) {
        $auditFiles = Get-ChildItem -Path $AuditOutputPath -Filter 'audit-*.jsonl' -File -ErrorAction SilentlyContinue
        foreach ($f in $auditFiles) {
            $fileMappings.Add(@{ Path = $f.FullName; DefaultEventType = 'CampaignAudit' })
        }
    }

    # Delta cert audit file
    if (Test-Path -Path $DeltaCertOutputPath -PathType Container) {
        $dcAuditPath = Join-Path $DeltaCertOutputPath 'deltacert-audit.jsonl'
        if (Test-Path -Path $dcAuditPath -PathType Leaf) {
            $fileMappings.Add(@{ Path = $dcAuditPath; DefaultEventType = 'DeltaCertRun' })
        }

        $dcEscPath = Join-Path $DeltaCertOutputPath 'deltacert-escalation.jsonl'
        if (Test-Path -Path $dcEscPath -PathType Leaf) {
            $fileMappings.Add(@{ Path = $dcEscPath; DefaultEventType = 'Escalation' })
        }
    }

    # Read and normalise each file
    foreach ($mapping in $fileMappings) {
        $filePath      = $mapping.Path
        $defaultEvType = $mapping.DefaultEventType

        try {
            $lines = [System.IO.File]::ReadAllLines($filePath)
        }
        catch {
            Write-SPLog -Message "Failed to read JSONL file '$filePath': $($_.Exception.Message)" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                -CorrelationID $logCorrelation
            continue
        }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $parsed = $line | ConvertFrom-Json
            }
            catch {
                Write-SPLog -Message "Malformed JSONL line in '$filePath': $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
                    -CorrelationID $logCorrelation
                continue
            }

            # Extract timestamp
            $tsString = $null
            if ($null -ne $parsed.Timestamp) { $tsString = [string]$parsed.Timestamp }
            $ts = $null
            if (-not [string]::IsNullOrWhiteSpace($tsString)) {
                try { $ts = [datetime]::Parse($tsString).ToUniversalTime() } catch { $ts = $null }
            }

            # Extract correlation ID from event
            $eventCorrId = ''
            if ($null -ne $parsed.CorrelationID) { $eventCorrId = [string]$parsed.CorrelationID }

            # Extract action
            $action = ''
            if ($null -ne $parsed.Action) { $action = [string]$parsed.Action }

            # Extract source IDs
            $sourceIds = @()
            if ($null -ne $parsed.SourceIds) {
                $sourceIds = @($parsed.SourceIds)
            }
            elseif ($null -ne $parsed.Data -and $null -ne $parsed.Data.SourceIds) {
                $sourceIds = @($parsed.Data.SourceIds)
            }

            # Build summary based on event type
            $summary = ''
            switch ($defaultEvType) {
                'CampaignAudit' {
                    $summary = $action
                }
                'DeltaCertRun' {
                    $campCount = 0
                    $idCount   = 0
                    if ($null -ne $parsed.CampaignsCreated) { $campCount = [int]$parsed.CampaignsCreated }
                    if ($null -ne $parsed.IdentitiesProcessed) { $idCount = [int]$parsed.IdentitiesProcessed }
                    $summary = "Created $campCount campaigns for $idCount identities"
                }
                'Escalation' {
                    $escCount = 0
                    if ($null -ne $parsed.Escalated) { $escCount = [int]$parsed.Escalated }
                    $summary = "Escalated $escCount certifications"
                }
            }

            $normalized = [PSCustomObject]@{
                Timestamp     = $ts
                EventType     = $defaultEvType
                Action        = $action
                CorrelationID = $eventCorrId
                SourceIds     = $sourceIds
                Summary       = $summary
                Details       = $parsed
                FilePath      = $filePath
            }

            # Apply filters
            if ($PSBoundParameters.ContainsKey('After') -and $null -ne $ts -and $ts -lt $After.ToUniversalTime()) { continue }
            if ($PSBoundParameters.ContainsKey('Before') -and $null -ne $ts -and $ts -gt $Before.ToUniversalTime()) { continue }
            if (-not [string]::IsNullOrWhiteSpace($CorrelationID) -and $eventCorrId -ne $CorrelationID) { continue }
            if ($null -ne $EventType -and $EventType.Count -gt 0 -and $defaultEvType -notin $EventType) { continue }
            if (-not [string]::IsNullOrWhiteSpace($SourceId) -and $SourceId -notin $sourceIds) { continue }

            $allEvents.Add($normalized)
        }
    }

    # Sort by Timestamp descending (newest first), nulls last
    $sorted = $allEvents | Sort-Object -Property {
        if ($null -ne $_.Timestamp) { $_.Timestamp } else { [datetime]::MinValue }
    } -Descending

    # Cap at MaxEvents
    $result = @($sorted | Select-Object -First $MaxEvents)

    Write-SPLog -Message "Get-SPAuditTrail: returning $($result.Count) events from $($fileMappings.Count) files" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPAuditTrail' `
        -CorrelationID $logCorrelation

    return $result
}

#endregion

#region Campaign Trend Analytics

function Measure-SPCampaignTrends {
    <#
    .SYNOPSIS
        Compares metrics across multiple campaign cycles to identify governance trends.
    .DESCRIPTION
        Groups campaign metrics by time period (Week, Month, Quarter, Year), aggregates
        KPIs per period, calculates deltas between consecutive periods, and classifies
        multi-period trends as Improving, Degrading, or Stable.

        Answers: "Are approval rates going up? Are reviewers getting faster?"

        Input is the Data array from Measure-SPCampaignMetrics (array of PSCustomObject
        with CampaignCreated, ApprovalRate, RevocationRate, CompletionRate,
        AvgResponseTimeHours, ReviewerCount, TotalItems, etc.).
    .PARAMETER CampaignMetrics
        Array of campaign metric objects from Measure-SPCampaignMetrics.Data.
    .PARAMETER GroupBy
        Time period for grouping: Week, Month, Quarter, Year. Default: Month.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Periods = @(...)   # per-period aggregates with deltas
            Trends  = @{...}   # multi-period trend classification
            Summary = @{...}   # overall summary
        }
    .EXAMPLE
        $camps = (Get-SPAuditCampaigns -Status 'COMPLETED' -DaysBack 365).Data
        $metrics = (Measure-SPCampaignMetrics -Campaigns $camps).Data
        $trends = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Quarter'
        $trends.Trends
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CampaignMetrics,

        [Parameter()]
        [ValidateSet('Week','Month','Quarter','Year')]
        [string]$GroupBy = 'Month',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measuring campaign trends for $($CampaignMetrics.Count) metric(s), grouped by $GroupBy" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
        -CorrelationID $CorrelationID

    # --- Helper: parse a date string to DateTime (UTC) ---
    function _ParseDateUtc([string]$dateStr) {
        if ([string]::IsNullOrWhiteSpace($dateStr)) { return $null }
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($dateStr, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) {
            return $dt.ToUniversalTime()
        }
        return $null
    }

    # --- Helper: assign a period label based on a DateTime ---
    function _PeriodLabel([datetime]$dt, [string]$group) {
        switch ($group) {
            'Week' {
                # ISO week: year-Www
                $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
                $weekNum = $cal.GetWeekOfYear($dt,
                    [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                    [System.DayOfWeek]::Monday)
                return '{0}-W{1:D2}' -f $dt.Year, $weekNum
            }
            'Month'   { return '{0}-{1:D2}' -f $dt.Year, $dt.Month }
            'Quarter' {
                $q = [Math]::Ceiling($dt.Month / 3)
                return '{0}-Q{1}' -f $dt.Year, $q
            }
            'Year'    { return [string]$dt.Year }
        }
    }

    # --- Helper: sort key for period labels ---
    function _PeriodSortKey([string]$label) {
        # All label formats sort lexicographically except Quarter vs Month;
        # they all start with YYYY so standard string sort works.
        return $label
    }

    # --- Parse dates and group by period ---
    $periodBuckets = @{}
    $earliestDate  = $null
    $latestDate    = $null

    foreach ($m in $CampaignMetrics) {
        if ($null -eq $m) { continue }

        $created = $null
        if ($null -ne $m.PSObject.Properties['CampaignCreated'] -and
            -not [string]::IsNullOrWhiteSpace($m.CampaignCreated)) {
            $created = _ParseDateUtc $m.CampaignCreated
        }
        if ($null -eq $created) {
            Write-SPLog -Message "Skipping campaign '$($m.CampaignName)' -- no CampaignCreated date" `
                -Severity WARN -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
                -CorrelationID $CorrelationID
            continue
        }

        if ($null -eq $earliestDate -or $created -lt $earliestDate) { $earliestDate = $created }
        if ($null -eq $latestDate   -or $created -gt $latestDate)   { $latestDate   = $created }

        $label = _PeriodLabel $created $GroupBy
        if (-not $periodBuckets.ContainsKey($label)) {
            $periodBuckets[$label] = [System.Collections.Generic.List[object]]::new()
        }
        $periodBuckets[$label].Add($m)
    }

    # --- Sort period labels chronologically ---
    $sortedLabels = @($periodBuckets.Keys | Sort-Object)

    # --- Aggregate metrics per period ---
    $periods = [System.Collections.Generic.List[object]]::new()

    foreach ($label in $sortedLabels) {
        $bucket = $periodBuckets[$label]

        $totalItems    = 0
        $totalApproved = 0
        $totalRevoked  = 0
        $totalDecided  = 0
        $totalTotal    = 0
        $responseHrSum = 0.0
        $responseHrCt  = 0
        $reviewerTotal = 0

        foreach ($m in $bucket) {
            $ti = if ($null -ne $m.TotalItems) { [int]$m.TotalItems } else { 0 }
            $totalTotal += $ti

            $app = if ($null -ne $m.ApprovedCount) { [int]$m.ApprovedCount } else { 0 }
            $rev = if ($null -ne $m.RevokedCount)  { [int]$m.RevokedCount }  else { 0 }
            $totalApproved += $app
            $totalRevoked  += $rev
            $totalDecided  += ($app + $rev)

            if ($null -ne $m.AvgResponseTimeHours -and $m.AvgResponseTimeHours -gt 0) {
                $responseHrSum += [double]$m.AvgResponseTimeHours
                $responseHrCt++
            }

            $rc = if ($null -ne $m.ReviewerCount) { [int]$m.ReviewerCount } else { 0 }
            $reviewerTotal += $rc
        }

        $approvalRate   = if ($totalTotal -gt 0) { [Math]::Round(($totalApproved / $totalTotal) * 100, 1) } else { 0.0 }
        $revocationRate = if ($totalTotal -gt 0) { [Math]::Round(($totalRevoked  / $totalTotal) * 100, 1) } else { 0.0 }
        $completionRate = if ($totalTotal -gt 0) { [Math]::Round(($totalDecided  / $totalTotal) * 100, 1) } else { 0.0 }
        $avgRespHrs     = if ($responseHrCt -gt 0) { [Math]::Round($responseHrSum / $responseHrCt, 1) } else { 0.0 }

        $periods.Add(@{
            Label          = $label
            CampaignCount  = $bucket.Count
            TotalItems     = $totalTotal
            ApprovalRate   = $approvalRate
            RevocationRate = $revocationRate
            CompletionRate = $completionRate
            AvgResponseHrs = $avgRespHrs
            ReviewerCount  = $reviewerTotal
            Deltas         = @{}
        })
    }

    # --- Calculate deltas between consecutive periods ---
    for ($i = 1; $i -lt $periods.Count; $i++) {
        $prev = $periods[$i - 1]
        $curr = $periods[$i]
        $curr['Deltas'] = @{
            ApprovalRate   = [Math]::Round($curr['ApprovalRate']   - $prev['ApprovalRate'],   1)
            RevocationRate = [Math]::Round($curr['RevocationRate'] - $prev['RevocationRate'], 1)
            CompletionRate = [Math]::Round($curr['CompletionRate'] - $prev['CompletionRate'], 1)
            AvgResponseHrs = [Math]::Round($curr['AvgResponseHrs'] - $prev['AvgResponseHrs'], 1)
        }
    }

    # --- Classify trends (need 3+ periods) ---
    $trendMetrics = @('ApprovalRate', 'RevocationRate', 'CompletionRate', 'AvgResponseHrs')
    $trends = @{}

    if ($periods.Count -lt 3) {
        foreach ($metric in $trendMetrics) {
            $trends[$metric] = 'Insufficient Data'
        }
    }
    else {
        foreach ($metric in $trendMetrics) {
            # Collect deltas from period index 1 onward
            $deltas = @()
            for ($i = 1; $i -lt $periods.Count; $i++) {
                $d = $periods[$i]['Deltas'][$metric]
                if ($null -ne $d) { $deltas += $d }
            }

            # For AvgResponseHrs, "improving" means decreasing (faster)
            $improvingCount = 0
            $degradingCount = 0
            $stableCount    = 0
            $threshold      = 2.0

            foreach ($d in $deltas) {
                if ($metric -eq 'AvgResponseHrs') {
                    # Negative delta = faster = improving
                    if ($d -lt (-$threshold))     { $improvingCount++ }
                    elseif ($d -gt $threshold)    { $degradingCount++ }
                    else                          { $stableCount++ }
                }
                elseif ($metric -eq 'RevocationRate') {
                    # For revocation rate, direction is context-dependent;
                    # treat decreasing as improving (fewer access removals needed)
                    if ($d -lt (-$threshold))     { $improvingCount++ }
                    elseif ($d -gt $threshold)    { $degradingCount++ }
                    else                          { $stableCount++ }
                }
                else {
                    # ApprovalRate, CompletionRate: higher = better
                    if ($d -gt $threshold)        { $improvingCount++ }
                    elseif ($d -lt (-$threshold)) { $degradingCount++ }
                    else                          { $stableCount++ }
                }
            }

            # Majority-based classification
            if ($improvingCount -gt $degradingCount -and $improvingCount -gt $stableCount) {
                $trends[$metric] = 'Improving'
            }
            elseif ($degradingCount -gt $improvingCount -and $degradingCount -gt $stableCount) {
                $trends[$metric] = 'Degrading'
            }
            else {
                $trends[$metric] = 'Stable'
            }
        }
    }

    # --- Overall direction: majority of trends ---
    $improvingTrends = @($trends.Values | Where-Object { $_ -eq 'Improving' }).Count
    $degradingTrends = @($trends.Values | Where-Object { $_ -eq 'Degrading' }).Count
    if ($periods.Count -lt 3) {
        $overallDirection = 'Insufficient Data'
    }
    elseif ($improvingTrends -gt $degradingTrends) {
        $overallDirection = 'Improving'
    }
    elseif ($degradingTrends -gt $improvingTrends) {
        $overallDirection = 'Degrading'
    }
    else {
        $overallDirection = 'Stable'
    }

    $earliestStr = if ($null -ne $earliestDate) { $earliestDate.ToString('yyyy-MM-dd') } else { '' }
    $latestStr   = if ($null -ne $latestDate)   { $latestDate.ToString('yyyy-MM-dd') }   else { '' }

    $result = @{
        Periods = $periods.ToArray()
        Trends  = $trends
        Summary = @{
            EarliestCampaign = $earliestStr
            LatestCampaign   = $latestStr
            TotalCampaigns   = ($CampaignMetrics | Where-Object { $null -ne $_ }).Count
            OverallDirection = $overallDirection
        }
    }

    Write-SPLog -Message "Campaign trends: $($periods.Count) period(s), overall=$overallDirection" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPCampaignTrends' `
        -CorrelationID $CorrelationID

    return $result
}

#endregion

#region Cross-Campaign Reviewer Analysis

function Measure-SPReviewerReputation {
    <#
    .SYNOPSIS
        Aggregates reviewer performance across multiple campaigns to build reputation profiles.
    .DESCRIPTION
        Takes an array of campaign audit data (same structure produced by Invoke-SPCampaignAudit)
        and builds a per-reviewer reputation profile spanning all campaigns. Identifies systemic
        issues (consistently slow reviewers, chronic rubber-stampers) vs one-time anomalies.

        Each reviewer receives a ReputationScore (0-100) based on weighted factors:
          - Response time (30%): Faster = higher score
          - Completion rate (25%): Higher = better
          - Decision diversity (20%): Mix of approve/revoke = higher (100% approve = lower)
          - Consistency (15%): Low variance across campaigns = higher
          - Escalation history (10%): Fewer escalations = higher

        Reviewers with fewer campaigns than MinCampaigns are excluded (insufficient data).
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables, each containing: CampaignName, Created, Decisions
        (from Group-SPAuditDecisions), ReviewerMetrics (from Measure-SPAuditReviewerMetrics),
        RubberStampRisk (from Measure-SPAuditRubberStampRisk).
    .PARAMETER MinCampaigns
        Minimum number of campaigns a reviewer must have participated in to be included.
        Default: 2.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] @{
            Reviewers = @( ... )   # sorted by ReputationScore ascending (worst first)
            Summary   = @{ TotalReviewers; Excellent; Good; NeedsAttention; AtRisk }
        }
    .EXAMPLE
        $rep = Measure-SPReviewerReputation -CampaignAudits $allCampaignAudits -MinCampaigns 2
        $rep.Reviewers | Where-Object { $_.ReputationTier -eq 'At Risk' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$MinCampaigns = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measuring reviewer reputation across $($CampaignAudits.Count) campaign(s), MinCampaigns=$MinCampaigns" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPReviewerReputation' `
        -CorrelationID $CorrelationID

    # --- Accumulator per reviewer keyed by name ---
    # Each entry tracks cross-campaign totals and per-campaign snapshots
    $reviewerMap = @{}

    foreach ($audit in $CampaignAudits) {
        $campaignName = if ($audit.ContainsKey('CampaignName')) { $audit['CampaignName'] } else { '' }

        # Parse campaign creation date for chronological ordering
        $campaignCreated = $null
        $createdStr = if ($audit.ContainsKey('Created')) { $audit['Created'] } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($createdStr)) {
            try {
                $campaignCreated = [datetime]::Parse($createdStr,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
            }
            catch { $campaignCreated = $null }
        }

        # --- Extract reviewer metrics from this campaign ---
        $metricsData = $null
        if ($audit.ContainsKey('ReviewerMetrics') -and $null -ne $audit['ReviewerMetrics']) {
            $rm = $audit['ReviewerMetrics']
            if ($rm -is [hashtable] -and $rm.ContainsKey('ReviewerMetrics')) {
                $metricsData = @($rm['ReviewerMetrics'])
            }
        }

        # --- Extract rubber-stamp risk from this campaign ---
        $riskData = $null
        if ($audit.ContainsKey('RubberStampRisk') -and $null -ne $audit['RubberStampRisk']) {
            $rs = $audit['RubberStampRisk']
            if ($rs -is [hashtable] -and $rs.ContainsKey('ReviewerRisks')) {
                $riskData = @($rs['ReviewerRisks'])
            }
        }

        # --- Extract per-reviewer decision counts from Decisions ---
        $decisionsByReviewer = @{}
        if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $decisions = $audit['Decisions']
            foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                if (-not $decisions.ContainsKey($category) -or $null -eq $decisions[$category]) { continue }
                foreach ($item in @($decisions[$category])) {
                    $rName = ''
                    if ($null -ne $item.ReviewerName -and -not [string]::IsNullOrWhiteSpace($item.ReviewerName)) {
                        $rName = $item.ReviewerName
                    }
                    if ([string]::IsNullOrWhiteSpace($rName)) { continue }

                    if (-not $decisionsByReviewer.ContainsKey($rName)) {
                        $decisionsByReviewer[$rName] = @{ Approved = 0; Revoked = 0; Pending = 0 }
                    }
                    $decisionsByReviewer[$rName][$category]++
                }
            }
        }

        # --- Build per-reviewer lookup for metrics and risk ---
        $metricsLookup = @{}
        if ($null -ne $metricsData) {
            foreach ($m in $metricsData) {
                $mName = if ($null -ne $m.Name) { $m.Name } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($mName)) {
                    $metricsLookup[$mName] = $m
                }
            }
        }

        $riskLookup = @{}
        if ($null -ne $riskData) {
            foreach ($r in $riskData) {
                $rName = if ($null -ne $r.ReviewerName) { $r.ReviewerName } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($rName)) {
                    $riskLookup[$rName] = $r
                }
            }
        }

        # --- Collect all reviewer names seen in this campaign ---
        $allReviewerNames = @{}
        foreach ($k in $decisionsByReviewer.Keys) { $allReviewerNames[$k] = $true }
        foreach ($k in $metricsLookup.Keys)       { $allReviewerNames[$k] = $true }

        # --- Accumulate per reviewer ---
        foreach ($reviewerName in $allReviewerNames.Keys) {
            if (-not $reviewerMap.ContainsKey($reviewerName)) {
                $reviewerMap[$reviewerName] = @{
                    Name               = $reviewerName
                    IdentityId         = ''
                    CampaignsParticipated = 0
                    TotalApproved      = 0
                    TotalRevoked       = 0
                    TotalPending       = 0
                    AvgHoursPerCampaign = [System.Collections.Generic.List[double]]::new()
                    RubberStampCount   = 0
                    EscalationCount    = 0
                    CampaignSnapshots  = [System.Collections.Generic.List[object]]::new()
                    CompletionRates    = [System.Collections.Generic.List[double]]::new()
                }
            }

            $entry = $reviewerMap[$reviewerName]
            $entry['CampaignsParticipated']++

            # Decisions
            if ($decisionsByReviewer.ContainsKey($reviewerName)) {
                $d = $decisionsByReviewer[$reviewerName]
                $entry['TotalApproved'] += $d['Approved']
                $entry['TotalRevoked']  += $d['Revoked']
                $entry['TotalPending']  += $d['Pending']

                $campTotal = $d['Approved'] + $d['Revoked'] + $d['Pending']
                $campDecided = $d['Approved'] + $d['Revoked']
                if ($campTotal -gt 0) {
                    $entry['CompletionRates'].Add([Math]::Round(($campDecided / $campTotal) * 100, 1))
                }
            }

            # Response time
            if ($metricsLookup.ContainsKey($reviewerName)) {
                $met = $metricsLookup[$reviewerName]
                if ($null -ne $met.AvgHours) {
                    $entry['AvgHoursPerCampaign'].Add([double]$met.AvgHours)
                }
            }

            # Rubber-stamp risk
            if ($riskLookup.ContainsKey($reviewerName)) {
                $rsk = $riskLookup[$reviewerName]
                $sev = if ($null -ne $rsk.Severity) { $rsk.Severity } else { 'None' }
                if ($sev -eq 'Medium' -or $sev -eq 'High') {
                    $entry['RubberStampCount']++
                }
            }

            # Campaign snapshot for trend analysis
            $campApprovalRate = 0
            if ($decisionsByReviewer.ContainsKey($reviewerName)) {
                $d = $decisionsByReviewer[$reviewerName]
                $decided = $d['Approved'] + $d['Revoked']
                if ($decided -gt 0) {
                    $campApprovalRate = [Math]::Round(($d['Approved'] / $decided) * 100, 1)
                }
            }

            $campAvgHours = $null
            if ($metricsLookup.ContainsKey($reviewerName) -and $null -ne $metricsLookup[$reviewerName].AvgHours) {
                $campAvgHours = [double]$metricsLookup[$reviewerName].AvgHours
            }

            $entry['CampaignSnapshots'].Add(@{
                CampaignName  = $campaignName
                Created       = $campaignCreated
                ApprovalRate  = $campApprovalRate
                AvgHours      = $campAvgHours
            })
        }
    }

    # --- Score and filter reviewers ---
    $reviewerResults = [System.Collections.Generic.List[object]]::new()

    foreach ($reviewerName in $reviewerMap.Keys) {
        $entry = $reviewerMap[$reviewerName]

        # Skip reviewers with insufficient campaigns
        if ($entry['CampaignsParticipated'] -lt $MinCampaigns) {
            continue
        }

        $totalItems   = $entry['TotalApproved'] + $entry['TotalRevoked'] + $entry['TotalPending']
        $totalDecided = $entry['TotalApproved'] + $entry['TotalRevoked']

        # --- Lifetime approval rate ---
        $lifetimeApprovalRate = 0
        if ($totalDecided -gt 0) {
            $lifetimeApprovalRate = [Math]::Round(($entry['TotalApproved'] / $totalDecided) * 100, 1)
        }

        # --- Average response hours (weighted across campaigns) ---
        $avgResponseHours = 0
        $hoursList = @($entry['AvgHoursPerCampaign'])
        if ($hoursList.Count -gt 0) {
            $avgResponseHours = [Math]::Round(($hoursList | Measure-Object -Average).Average, 1)
        }

        # --- Response trend (improving = getting faster) ---
        $responseTrend = 'Stable'
        $snapshots = @($entry['CampaignSnapshots'] | Where-Object { $null -ne $_['Created'] } | Sort-Object { $_['Created'] })
        $hoursOverTime = @($snapshots | Where-Object { $null -ne $_['AvgHours'] } | ForEach-Object { $_['AvgHours'] })
        if ($hoursOverTime.Count -ge 3) {
            $improving = 0
            $degrading = 0
            for ($i = 1; $i -lt $hoursOverTime.Count; $i++) {
                $delta = $hoursOverTime[$i] - $hoursOverTime[$i - 1]
                if ($delta -lt -0.5) { $improving++ }
                elseif ($delta -gt 0.5) { $degrading++ }
            }
            if ($improving -gt $degrading -and $improving -ge 2) { $responseTrend = 'Improving' }
            elseif ($degrading -gt $improving -and $degrading -ge 2) { $responseTrend = 'Degrading' }
        }

        # ===== REPUTATION SCORE (0-100) =====

        # Component 1: Response time score (30%) -- faster is better
        # Baseline: 24h = 50 points, 0h = 100 points, 72h+ = 0 points
        $responseScore = 0
        if ($hoursList.Count -gt 0) {
            $clampedHours = [Math]::Min([Math]::Max($avgResponseHours, 0), 72)
            $responseScore = [Math]::Round((1 - ($clampedHours / 72)) * 100, 1)
        }
        else {
            $responseScore = 50  # no data -> neutral
        }

        # Component 2: Completion rate score (25%) -- higher is better
        $completionScore = 0
        $completionRates = @($entry['CompletionRates'])
        if ($completionRates.Count -gt 0) {
            $completionScore = [Math]::Round(($completionRates | Measure-Object -Average).Average, 1)
        }
        else {
            $completionScore = 50  # no data -> neutral
        }

        # Component 3: Decision diversity score (20%) -- mix of approve/revoke is healthier
        # 100% approval = low diversity = score 20; 50/50 = max diversity = score 100
        $diversityScore = 50
        if ($totalDecided -gt 0) {
            $revocationRate = $entry['TotalRevoked'] / $totalDecided
            # Optimal revocation rate is around 10-30%. Score peaks at 20% and drops toward 0% and 100%.
            # Use a simple bell-curve approximation centered at 0.2
            $deviation = [Math]::Abs($revocationRate - 0.2)
            # max deviation from 0.2 is 0.8 (at 100% revocation); scale to 0-100
            $diversityScore = [Math]::Round((1 - [Math]::Min($deviation / 0.8, 1)) * 100, 1)
        }

        # Component 4: Consistency score (15%) -- low variance in approval rate across campaigns
        $consistencyScore = 50
        $campApprovalRates = @($snapshots | ForEach-Object { $_['ApprovalRate'] })
        if ($campApprovalRates.Count -ge 2) {
            $mean = ($campApprovalRates | Measure-Object -Average).Average
            $sumSqDiff = 0
            foreach ($rate in $campApprovalRates) {
                $sumSqDiff += ($rate - $mean) * ($rate - $mean)
            }
            $stdDev = [Math]::Sqrt($sumSqDiff / $campApprovalRates.Count)
            # stdDev of 0 = perfect consistency (100), stdDev of 50 = terrible (0)
            $consistencyScore = [Math]::Round([Math]::Max(0, (1 - ($stdDev / 50)) * 100), 1)
        }

        # Component 5: Escalation history score (10%) -- fewer escalations is better
        $escalationScore = 100
        $escCount = $entry['EscalationCount']
        $campCount = $entry['CampaignsParticipated']
        if ($campCount -gt 0 -and $escCount -gt 0) {
            $escRatio = $escCount / $campCount
            $escalationScore = [Math]::Round([Math]::Max(0, (1 - $escRatio) * 100), 1)
        }

        # Weighted composite
        $reputationScore = [Math]::Round(
            ($responseScore    * 0.30) +
            ($completionScore  * 0.25) +
            ($diversityScore   * 0.20) +
            ($consistencyScore * 0.15) +
            ($escalationScore  * 0.10),
            0
        )
        # Clamp to 0-100
        $reputationScore = [Math]::Min(100, [Math]::Max(0, $reputationScore))

        # Tier classification
        $reputationTier = if ($reputationScore -ge 80) { 'Excellent' }
                          elseif ($reputationScore -ge 60) { 'Good' }
                          elseif ($reputationScore -ge 40) { 'Needs Attention' }
                          else { 'At Risk' }

        $reviewerResults.Add([PSCustomObject]@{
            ReviewerName          = $reviewerName
            ReviewerIdentityId    = $entry['IdentityId']
            CampaignsParticipated = $entry['CampaignsParticipated']
            TotalItemsReviewed    = $totalItems
            AvgResponseHours      = $avgResponseHours
            ResponseTrend         = $responseTrend
            LifetimeApprovalRate  = $lifetimeApprovalRate
            RubberStampCount      = $entry['RubberStampCount']
            EscalationCount       = $entry['EscalationCount']
            ReputationScore       = $reputationScore
            ReputationTier        = $reputationTier
        })
    }

    # Sort by ReputationScore ascending (worst first for actionability)
    $sorted = @($reviewerResults | Sort-Object ReputationScore)

    # Build summary
    $excellent      = @($sorted | Where-Object { $_.ReputationTier -eq 'Excellent' }).Count
    $good           = @($sorted | Where-Object { $_.ReputationTier -eq 'Good' }).Count
    $needsAttention = @($sorted | Where-Object { $_.ReputationTier -eq 'Needs Attention' }).Count
    $atRisk         = @($sorted | Where-Object { $_.ReputationTier -eq 'At Risk' }).Count

    Write-SPLog -Message "Reviewer reputation: $($sorted.Count) reviewers scored -- Excellent=$excellent, Good=$good, NeedsAttention=$needsAttention, AtRisk=$atRisk" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPReviewerReputation' `
        -CorrelationID $CorrelationID

    return @{
        Reviewers = $sorted
        Summary   = @{
            TotalReviewers = $sorted.Count
            Excellent      = $excellent
            Good           = $good
            NeedsAttention = $needsAttention
            AtRisk         = $atRisk
        }
    }
}

#endregion

#region Identity Risk Scoring

function Measure-SPIdentityRisk {
    <#
    .SYNOPSIS
        Aggregates risk signals per identity across all audited campaigns.
    .DESCRIPTION
        Consumes an array of campaign audit hashtables (same structure used by
        Export-SPAuditCsv) and produces a composite risk score (0-100) per identity.
        Answers: "Which identities should we prioritize for access review?"

        Risk signals accumulated per identity across campaigns:
        - StaleAccessCount: Items flagged STALE (>90 days unreviewed)
        - PrivilegedAccessCount: Entitlements matching privileged patterns
        - RubberStampApprovals: Items approved by reviewers flagged for rubber-stamping
        - OrphanAccountFlag: Identity has orphan accounts
        - OverdueRemediations: Revocations past SLA not provisioned
        - ApprovalOnlyHistory: Never had access revoked across all campaigns
        - CampaignsReviewed: How many campaigns included this identity
        - LastReviewDate: Most recent campaign decision date
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions, RubberStampRisk, etc.
    .PARAMETER HighRiskThreshold
        Score at or above which an identity is classified High risk. Default 70.
    .PARAMETER MediumRiskThreshold
        Score at or above which an identity is classified Medium risk. Default 40.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Identities = @(...); Summary = @{...} }
    .EXAMPLE
        $risk = Measure-SPIdentityRisk -CampaignAudits $audits
        $risk.Identities | Where-Object { $_.RiskTier -eq 'High' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$HighRiskThreshold = 70,

        [Parameter()]
        [int]$MediumRiskThreshold = 40,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measure-SPIdentityRisk: starting with $($CampaignAudits.Count) campaign(s)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPIdentityRisk' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            Identities = @()
            Summary    = @{
                TotalIdentities = 0
                High            = 0
                Medium          = 0
                Low             = 0
                AvgRiskScore    = 0
            }
        }
    }

    # Per-identity accumulator: keyed by IdentityId
    $identityMap = @{}

    # Build rubber-stamp reviewer set per campaign
    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        # Identify rubber-stamp reviewers (Medium or High severity)
        $rubberStampReviewers = @{}
        if ($audit.ContainsKey('RubberStampRisk') -and $null -ne $audit['RubberStampRisk']) {
            $rsRisk = $audit['RubberStampRisk']
            $reviewerRisks = if ($rsRisk.ContainsKey('ReviewerRisks') -and $null -ne $rsRisk['ReviewerRisks']) {
                @($rsRisk['ReviewerRisks'])
            } else { @() }
            foreach ($rr in $reviewerRisks) {
                if ($null -eq $rr) { continue }
                $sev = ''
                if ($rr -is [hashtable]) {
                    $sev = if ($rr.ContainsKey('Severity')) { [string]$rr['Severity'] } else { '' }
                } else {
                    $sevProp = $rr.PSObject.Properties['Severity']
                    $sev = if ($null -ne $sevProp) { [string]$sevProp.Value } else { '' }
                }
                if ($sev -eq 'Medium' -or $sev -eq 'High') {
                    $name = ''
                    if ($rr -is [hashtable]) {
                        $name = if ($rr.ContainsKey('ReviewerName')) { [string]$rr['ReviewerName'] } else { '' }
                    } else {
                        $nameProp = $rr.PSObject.Properties['ReviewerName']
                        $name = if ($null -ne $nameProp) { [string]$nameProp.Value } else { '' }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $rubberStampReviewers[$name] = $true
                    }
                }
            }
        }

        # Process all decision categories
        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                # Extract identity info
                $identityId = ''
                $identityName = ''
                $accessName = ''
                $reviewerName = ''
                $decisionDate = ''
                $riskFlags = @()

                if ($item -is [hashtable]) {
                    $identityId   = if ($item.ContainsKey('IdentityId'))   { [string]$item['IdentityId'] }   else { '' }
                    $identityName = if ($item.ContainsKey('IdentityName')) { [string]$item['IdentityName'] } else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $reviewerName = if ($item.ContainsKey('ReviewerName')) { [string]$item['ReviewerName'] } else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                    $riskFlags    = if ($item.ContainsKey('RiskFlags') -and $null -ne $item['RiskFlags']) { @($item['RiskFlags']) } else { @() }
                } else {
                    $idProp = $item.PSObject.Properties['IdentityId']
                    $identityId = if ($null -ne $idProp -and $null -ne $idProp.Value) { [string]$idProp.Value } else { '' }
                    $nmProp = $item.PSObject.Properties['IdentityName']
                    $identityName = if ($null -ne $nmProp -and $null -ne $nmProp.Value) { [string]$nmProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $rnProp = $item.PSObject.Properties['ReviewerName']
                    $reviewerName = if ($null -ne $rnProp -and $null -ne $rnProp.Value) { [string]$rnProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                    $rfProp = $item.PSObject.Properties['RiskFlags']
                    $riskFlags = if ($null -ne $rfProp -and $null -ne $rfProp.Value) { @($rfProp.Value) } else { @() }
                }

                if ([string]::IsNullOrWhiteSpace($identityId)) { continue }

                # Initialize identity record if not seen
                if (-not $identityMap.ContainsKey($identityId)) {
                    $identityMap[$identityId] = @{
                        IdentityId            = $identityId
                        IdentityName          = $identityName
                        StaleAccessCount      = 0
                        PrivilegedAccessCount = 0
                        RubberStampApprovals  = 0
                        OrphanAccountFlag     = $false
                        OverdueRemediations   = 0
                        HasRevocation         = $false
                        CampaignSet           = @{}
                        LastReviewDate        = $null
                    }
                }

                $idRec = $identityMap[$identityId]

                # Update identity name if we have a better one
                if (-not [string]::IsNullOrWhiteSpace($identityName)) {
                    $idRec['IdentityName'] = $identityName
                }

                # Track campaign participation
                $campaignName = ''
                if ($audit.ContainsKey('CampaignName')) { $campaignName = [string]$audit['CampaignName'] }
                if ($audit.ContainsKey('CampaignId'))   { $campaignName = [string]$audit['CampaignId'] }
                if (-not [string]::IsNullOrWhiteSpace($campaignName)) {
                    $idRec['CampaignSet'][$campaignName] = $true
                }

                # Track last review date
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $idRec['LastReviewDate'] -or $dt -gt $idRec['LastReviewDate']) {
                            $idRec['LastReviewDate'] = $dt
                        }
                    } catch { }
                }

                # Accumulate risk flags
                foreach ($flag in $riskFlags) {
                    switch ($flag) {
                        'STALE'      { $idRec['StaleAccessCount']++ }
                        'PRIVILEGED' { $idRec['PrivilegedAccessCount']++ }
                        'ORPHAN'     { $idRec['OrphanAccountFlag'] = $true }
                    }
                }

                # Track revocations
                if ($category -eq 'Revoked') {
                    $idRec['HasRevocation'] = $true
                }

                # Track rubber-stamp approvals
                if ($category -eq 'Approved' -and
                    -not [string]::IsNullOrWhiteSpace($reviewerName) -and
                    $rubberStampReviewers.ContainsKey($reviewerName)) {
                    $idRec['RubberStampApprovals']++
                }

                # Track overdue remediations (revoked items with overdue remediation)
                if ($category -eq 'Revoked') {
                    $remStatus = ''
                    if ($item -is [hashtable] -and $item.ContainsKey('RemediationStatus')) {
                        $remStatus = [string]$item['RemediationStatus']
                    } elseif ($item -isnot [hashtable]) {
                        $rsProp = $item.PSObject.Properties['RemediationStatus']
                        if ($null -ne $rsProp -and $null -ne $rsProp.Value) {
                            $remStatus = [string]$rsProp.Value
                        }
                    }
                    if ($remStatus -eq 'Overdue' -or $remStatus -eq 'overdue') {
                        $idRec['OverdueRemediations']++
                    }
                }
            }
        }
    }

    # Calculate risk scores
    $now = Get-Date
    $identityResults = [System.Collections.Generic.List[hashtable]]::new()
    $highCount = 0
    $mediumCount = 0
    $lowCount = 0
    $totalScore = 0.0

    foreach ($idKey in $identityMap.Keys) {
        $idRec = $identityMap[$idKey]

        $score = 0

        # Privileged access: +15 per privileged entitlement (max 30)
        $privScore = [Math]::Min($idRec['PrivilegedAccessCount'] * 15, 30)
        $score += $privScore

        # Stale access: +10 per stale item (max 20)
        $staleScore = [Math]::Min($idRec['StaleAccessCount'] * 10, 20)
        $score += $staleScore

        # Rubber-stamp approvals: +10 per rubber-stamp approval (max 20)
        $rsScore = [Math]::Min($idRec['RubberStampApprovals'] * 10, 20)
        $score += $rsScore

        # Orphan account: +15 (flat)
        if ($idRec['OrphanAccountFlag']) { $score += 15 }

        # Overdue remediation: +15 per overdue item (max 15)
        $overdueScore = [Math]::Min($idRec['OverdueRemediations'] * 15, 15)
        $score += $overdueScore

        # Approval-only history with 3+ campaigns: +10
        $campaignsReviewed = $idRec['CampaignSet'].Count
        $approvalOnly = (-not $idRec['HasRevocation']) -and ($campaignsReviewed -ge 3)
        if ($approvalOnly) { $score += 10 }

        # Not reviewed in 180+ days: +10
        $daysSinceReview = $null
        if ($null -ne $idRec['LastReviewDate']) {
            $daysSinceReview = [int]($now - $idRec['LastReviewDate']).TotalDays
            if ($daysSinceReview -ge 180) { $score += 10 }
        }

        # Clamp to 0-100
        $score = [Math]::Max(0, [Math]::Min(100, $score))

        # Determine risk tier
        $tier = if ($score -ge $HighRiskThreshold) { 'High' }
                elseif ($score -ge $MediumRiskThreshold) { 'Medium' }
                else { 'Low' }

        # Build top risk factors list
        $topFactors = [System.Collections.Generic.List[string]]::new()
        if ($idRec['PrivilegedAccessCount'] -gt 0) { $topFactors.Add('Privileged Access') }
        if ($idRec['StaleAccessCount'] -gt 0)      { $topFactors.Add('Stale Access') }
        if ($idRec['RubberStampApprovals'] -gt 0)   { $topFactors.Add('Rubber-Stamp Approvals') }
        if ($idRec['OrphanAccountFlag'])            { $topFactors.Add('Orphan Account') }
        if ($idRec['OverdueRemediations'] -gt 0)    { $topFactors.Add('Overdue Remediation') }
        if ($approvalOnly)                          { $topFactors.Add('Approval-Only History') }
        if ($null -ne $daysSinceReview -and $daysSinceReview -ge 180) { $topFactors.Add('Not Recently Reviewed') }

        $lastReviewStr = if ($null -ne $idRec['LastReviewDate']) {
            $idRec['LastReviewDate'].ToString('yyyy-MM-dd')
        } else { $null }

        $identityResults.Add(@{
            IdentityId            = $idRec['IdentityId']
            IdentityName          = $idRec['IdentityName']
            RiskScore             = $score
            RiskTier              = $tier
            StaleAccessCount      = $idRec['StaleAccessCount']
            PrivilegedAccessCount = $idRec['PrivilegedAccessCount']
            RubberStampApprovals  = $idRec['RubberStampApprovals']
            OrphanAccountFlag     = $idRec['OrphanAccountFlag']
            OverdueRemediations   = $idRec['OverdueRemediations']
            ApprovalOnlyHistory   = $approvalOnly
            CampaignsReviewed     = $campaignsReviewed
            LastReviewDate        = $lastReviewStr
            TopRiskFactors        = @($topFactors)
        })

        $totalScore += $score
        switch ($tier) {
            'High'   { $highCount++ }
            'Medium' { $mediumCount++ }
            'Low'    { $lowCount++ }
        }
    }

    # Sort by risk score descending
    $sorted = @($identityResults | Sort-Object { $_['RiskScore'] } -Descending)

    $totalIdentities = $sorted.Count
    $avgScore = if ($totalIdentities -gt 0) {
        [Math]::Round($totalScore / $totalIdentities, 1)
    } else { 0 }

    Write-SPLog -Message "Measure-SPIdentityRisk: scored $totalIdentities identities (High=$highCount, Medium=$mediumCount, Low=$lowCount)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPIdentityRisk' `
        -CorrelationID $CorrelationID

    return @{
        Identities = $sorted
        Summary    = @{
            TotalIdentities = $totalIdentities
            High            = $highCount
            Medium          = $mediumCount
            Low             = $lowCount
            AvgRiskScore    = $avgScore
        }
    }
}

#endregion

#region Source Governance Scorecard

function Measure-SPSourceGovernance {
    <#
    .SYNOPSIS
        Calculates a governance coverage score per configured source.
    .DESCRIPTION
        Combines entitlement inventory data with campaign review history to produce
        a per-source governance grade (A-F). Answers: "How well is each source
        being governed? Where are the blind spots?"

        Grade calculation (weighted):
        - Entitlement coverage (40%): Higher coverage = better grade
        - Privileged coverage (25%): Privileged entitlements reviewed more strictly
        - Review recency (20%): Recent review within window = better
        - Campaign frequency (15%): Multiple campaigns = better
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions, RubberStampRisk, etc.
    .PARAMETER EntitlementInventory
        Hashtable from Get-SPEntitlementInventory .Data output containing Sources
        and Summary. Optional -- if not provided, grades based on campaign data only.
    .PARAMETER ReviewWindowDays
        Number of days within which a review is considered recent. Default 365.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Sources = @(...); Summary = @{...} }
    .EXAMPLE
        $inv = Get-SPEntitlementInventory -SourceIds 'src-ad-001' -IncludeReviewHistory
        $audits = Get-SPAuditCampaigns -DaysBack 90 | ForEach-Object { Get-SPAuditCampaignReport -CampaignId $_.id }
        $result = Measure-SPSourceGovernance -CampaignAudits $audits -EntitlementInventory $inv.Data
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [hashtable]$EntitlementInventory,

        [Parameter()]
        [int]$ReviewWindowDays = 365,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measure-SPSourceGovernance: starting with $($CampaignAudits.Count) campaign(s), ReviewWindowDays=$ReviewWindowDays" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPSourceGovernance' `
        -CorrelationID $CorrelationID

    # Return empty result for empty input
    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            Sources = @()
            Summary = @{
                TotalSources       = 0
                GradeDistribution  = @{ A = 0; B = 0; C = 0; D = 0; F = 0 }
                OverallCoveragePct = 0
                AvgGovernanceScore = 0
            }
        }
    }

    $now = Get-Date

    # -------------------------------------------------------------------
    # Step 1: Build per-source review data from campaign decision items
    # -------------------------------------------------------------------
    # sourceMap: SourceName -> @{ ReviewedEntitlements (set); PrivilegedReviewed (set);
    #   CampaignSet (set); LastReviewDate; DecisionDates (list) }
    $sourceMap = @{}

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        $campaignName = ''
        if ($audit.ContainsKey('CampaignName')) { $campaignName = [string]$audit['CampaignName'] }
        if ([string]::IsNullOrWhiteSpace($campaignName) -and $audit.ContainsKey('CampaignId')) {
            $campaignName = [string]$audit['CampaignId']
        }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                # Extract fields -- support both hashtable and PSObject
                $sourceName = ''
                $accessName = ''
                $decisionDate = ''
                $riskFlags = @()

                if ($item -is [hashtable]) {
                    $sourceName   = if ($item.ContainsKey('SourceName'))   { [string]$item['SourceName'] }   else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                    $riskFlags    = if ($item.ContainsKey('RiskFlags') -and $null -ne $item['RiskFlags']) { @($item['RiskFlags']) } else { @() }
                } else {
                    $snProp = $item.PSObject.Properties['SourceName']
                    $sourceName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                    $rfProp = $item.PSObject.Properties['RiskFlags']
                    $riskFlags = if ($null -ne $rfProp -and $null -ne $rfProp.Value) { @($rfProp.Value) } else { @() }
                }

                if ([string]::IsNullOrWhiteSpace($sourceName)) { continue }

                # Initialize source record
                if (-not $sourceMap.ContainsKey($sourceName)) {
                    $sourceMap[$sourceName] = @{
                        SourceId             = ''
                        ReviewedEntitlements = @{}
                        PrivilegedReviewed   = @{}
                        CampaignSet          = @{}
                        LastReviewDate       = $null
                        DecisionDates        = [System.Collections.Generic.List[datetime]]::new()
                    }
                }

                $srcRec = $sourceMap[$sourceName]

                # Track reviewed entitlements
                if (-not [string]::IsNullOrWhiteSpace($accessName)) {
                    $srcRec['ReviewedEntitlements'][$accessName] = $true

                    # Check if privileged
                    $isPrivileged = $false
                    foreach ($flag in $riskFlags) {
                        if ($flag -eq 'PRIVILEGED') { $isPrivileged = $true; break }
                    }
                    if ($isPrivileged) {
                        $srcRec['PrivilegedReviewed'][$accessName] = $true
                    }
                }

                # Track campaign participation
                if (-not [string]::IsNullOrWhiteSpace($campaignName)) {
                    $srcRec['CampaignSet'][$campaignName] = $true
                }

                # Track review dates
                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $srcRec['LastReviewDate'] -or $dt -gt $srcRec['LastReviewDate']) {
                            $srcRec['LastReviewDate'] = $dt
                        }
                        $srcRec['DecisionDates'].Add($dt)
                    } catch { }
                }
            }
        }
    }

    # -------------------------------------------------------------------
    # Step 2: Cross-reference with entitlement inventory if provided
    # -------------------------------------------------------------------
    # Build inventory lookup: SourceName -> @{ TotalEntitlements; PrivilegedCount; SourceId }
    $inventoryLookup = @{}
    if ($null -ne $EntitlementInventory -and $EntitlementInventory.ContainsKey('Sources')) {
        $invSources = $EntitlementInventory['Sources']
        foreach ($srcId in $invSources.Keys) {
            $srcData = $invSources[$srcId]
            $srcName = ''
            if ($srcData -is [hashtable]) {
                $srcName = if ($srcData.ContainsKey('SourceName')) { [string]$srcData['SourceName'] } else { '' }
            } else {
                $snProp = $srcData.PSObject.Properties['SourceName']
                $srcName = if ($null -ne $snProp) { [string]$snProp.Value } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($srcName)) { continue }

            $totalEnt = 0
            $privCount = 0
            if ($srcData -is [hashtable]) {
                $totalEnt  = if ($srcData.ContainsKey('TotalEntitlements')) { [int]$srcData['TotalEntitlements'] } else { 0 }
                $privCount = if ($srcData.ContainsKey('Privileged'))       { [int]$srcData['Privileged'] }       else { 0 }
            } else {
                $teProp = $srcData.PSObject.Properties['TotalEntitlements']
                $totalEnt = if ($null -ne $teProp) { [int]$teProp.Value } else { 0 }
                $ppProp = $srcData.PSObject.Properties['Privileged']
                $privCount = if ($null -ne $ppProp) { [int]$ppProp.Value } else { 0 }
            }

            $inventoryLookup[$srcName] = @{
                TotalEntitlements    = $totalEnt
                PrivilegedEntitlements = $privCount
                SourceId             = [string]$srcId
            }

            # Ensure this source appears in sourceMap even if no campaign data
            if (-not $sourceMap.ContainsKey($srcName)) {
                $sourceMap[$srcName] = @{
                    SourceId             = [string]$srcId
                    ReviewedEntitlements = @{}
                    PrivilegedReviewed   = @{}
                    CampaignSet          = @{}
                    LastReviewDate       = $null
                    DecisionDates        = [System.Collections.Generic.List[datetime]]::new()
                }
            }
            if ([string]::IsNullOrWhiteSpace($sourceMap[$srcName]['SourceId'])) {
                $sourceMap[$srcName]['SourceId'] = [string]$srcId
            }
        }
    }

    # -------------------------------------------------------------------
    # Step 3: Calculate per-source governance grade
    # -------------------------------------------------------------------
    $sourceResults = [System.Collections.Generic.List[hashtable]]::new()
    $gradeDistribution = @{ A = 0; B = 0; C = 0; D = 0; F = 0 }
    $totalCoverage = 0.0
    $totalGovernanceScore = 0.0
    $sourcesWithCoverage = 0

    foreach ($srcName in $sourceMap.Keys) {
        $srcRec = $sourceMap[$srcName]
        $invData = if ($inventoryLookup.ContainsKey($srcName)) { $inventoryLookup[$srcName] } else { $null }

        $sourceId = $srcRec['SourceId']
        $reviewedCount = $srcRec['ReviewedEntitlements'].Count
        $privReviewedCount = $srcRec['PrivilegedReviewed'].Count
        $campaignCount = $srcRec['CampaignSet'].Count
        $lastReviewDate = $srcRec['LastReviewDate']

        # Total entitlements and privileged from inventory
        $totalEntitlements = $null
        $privilegedEntitlements = 0
        if ($null -ne $invData) {
            $totalEntitlements = $invData['TotalEntitlements']
            $privilegedEntitlements = $invData['PrivilegedEntitlements']
            if ([string]::IsNullOrWhiteSpace($sourceId)) {
                $sourceId = $invData['SourceId']
            }
        }

        # Entitlement coverage percentage
        $entCoveragePct = $null
        if ($null -ne $totalEntitlements -and $totalEntitlements -gt 0) {
            $entCoveragePct = [Math]::Round(($reviewedCount / $totalEntitlements) * 100, 1)
            if ($entCoveragePct -gt 100) { $entCoveragePct = 100.0 }
        }

        # Privileged reviewed percentage
        $privReviewedPct = $null
        if ($privilegedEntitlements -gt 0) {
            $privReviewedPct = [Math]::Round(($privReviewedCount / $privilegedEntitlements) * 100, 1)
            if ($privReviewedPct -gt 100) { $privReviewedPct = 100.0 }
        } elseif ($null -ne $invData) {
            # Source is in inventory but has 0 privileged -- full privileged coverage by default
            $privReviewedPct = 100.0
        }

        # Days since last review
        $daysSinceLastReview = $null
        $lastReviewStr = $null
        if ($null -ne $lastReviewDate) {
            $daysSinceLastReview = [int]($now - $lastReviewDate).TotalDays
            $lastReviewStr = $lastReviewDate.ToString('yyyy-MM-dd')
        }

        # Average review cycle days
        $avgReviewCycleDays = $null
        $decisionDates = $srcRec['DecisionDates']
        if ($decisionDates.Count -ge 2) {
            $sortedDates = @($decisionDates | Sort-Object)
            $totalGap = ($sortedDates[-1] - $sortedDates[0]).TotalDays
            $avgReviewCycleDays = [int][Math]::Round($totalGap / ($sortedDates.Count - 1))
        }

        # --- Governance score calculation (0-100 weighted) ---
        $entCoverageScore = 0.0
        $privCoverageScore = 0.0
        $recencyScore = 0.0
        $frequencyScore = 0.0

        # Entitlement coverage (40% weight)
        if ($null -ne $entCoveragePct) {
            $entCoverageScore = $entCoveragePct
        } elseif ($campaignCount -gt 0) {
            # No inventory data but has campaign reviews -- assume partial coverage
            $entCoverageScore = 50.0
        }
        # else: 0 (no inventory, no campaigns)

        # Privileged coverage (25% weight)
        if ($null -ne $privReviewedPct) {
            $privCoverageScore = $privReviewedPct
        } elseif ($campaignCount -gt 0) {
            # No inventory data but has campaigns -- assume moderate
            $privCoverageScore = 50.0
        }

        # Review recency (20% weight)
        if ($null -ne $daysSinceLastReview) {
            if ($daysSinceLastReview -le 0) {
                $recencyScore = 100.0
            } elseif ($daysSinceLastReview -le $ReviewWindowDays) {
                $recencyScore = [Math]::Round((1 - ($daysSinceLastReview / $ReviewWindowDays)) * 100, 1)
                if ($recencyScore -lt 0) { $recencyScore = 0.0 }
            }
            # else: beyond window -> 0
        }

        # Campaign frequency (15% weight)
        if ($campaignCount -ge 4) {
            $frequencyScore = 100.0
        } elseif ($campaignCount -ge 3) {
            $frequencyScore = 80.0
        } elseif ($campaignCount -ge 2) {
            $frequencyScore = 60.0
        } elseif ($campaignCount -ge 1) {
            $frequencyScore = 40.0
        }

        $governanceScore = [Math]::Round(
            ($entCoverageScore * 0.40) +
            ($privCoverageScore * 0.25) +
            ($recencyScore * 0.20) +
            ($frequencyScore * 0.15),
            1
        )

        # Grade assignment
        $grade = if     ($governanceScore -ge 90) { 'A' }
                 elseif ($governanceScore -ge 75) { 'B' }
                 elseif ($governanceScore -ge 60) { 'C' }
                 elseif ($governanceScore -ge 40) { 'D' }
                 else                             { 'F' }

        $gradeDistribution[$grade]++
        $totalGovernanceScore += $governanceScore

        if ($null -ne $entCoveragePct) {
            $totalCoverage += $entCoveragePct
            $sourcesWithCoverage++
        }

        $sourceResults.Add(@{
            SourceId               = $sourceId
            SourceName             = $srcName
            TotalEntitlements      = if ($null -ne $totalEntitlements) { $totalEntitlements } else { 'Unknown' }
            ReviewedEntitlements   = $reviewedCount
            EntitlementCoveragePct = if ($null -ne $entCoveragePct) { $entCoveragePct } else { 'Unknown' }
            PrivilegedEntitlements = $privilegedEntitlements
            PrivilegedReviewedPct  = if ($null -ne $privReviewedPct) { $privReviewedPct } else { 'Unknown' }
            CampaignCount          = $campaignCount
            LastReviewDate         = $lastReviewStr
            DaysSinceLastReview    = $daysSinceLastReview
            AvgReviewCycleDays     = $avgReviewCycleDays
            GovernanceGrade        = $grade
            GovernanceScore        = $governanceScore
        })
    }

    # Sort by governance score ascending (worst first for attention)
    $sorted = @($sourceResults | Sort-Object { $_['GovernanceScore'] })

    $totalSources = $sorted.Count
    $avgGovScore = if ($totalSources -gt 0) {
        [Math]::Round($totalGovernanceScore / $totalSources, 1)
    } else { 0 }
    $overallCoverage = if ($sourcesWithCoverage -gt 0) {
        [Math]::Round($totalCoverage / $sourcesWithCoverage, 1)
    } else { 0 }

    Write-SPLog -Message "Measure-SPSourceGovernance: scored $totalSources source(s) (A=$($gradeDistribution['A']), B=$($gradeDistribution['B']), C=$($gradeDistribution['C']), D=$($gradeDistribution['D']), F=$($gradeDistribution['F']))" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPSourceGovernance' `
        -CorrelationID $CorrelationID

    return @{
        Sources = $sorted
        Summary = @{
            TotalSources       = $totalSources
            GradeDistribution  = $gradeDistribution
            OverallCoveragePct = $overallCoverage
            AvgGovernanceScore = $avgGovScore
        }
    }
}

#endregion

#region P14-01: Governance Maturity Scorecard

function Measure-SPGovernanceMaturity {
    <#
    .SYNOPSIS
        Produces a composite governance maturity assessment across six dimensions.
    .DESCRIPTION
        Scores the organization across six governance dimensions (Coverage, Timeliness,
        Enforcement, Accountability, Documentation, Automation) from 0 to 100, then maps
        to a five-level maturity model aligned with CMMI / ISO 27001 Annex A.9.

        Consumes pre-computed analytics outputs from existing toolkit functions. Dimensions
        with null input data score 0 with note "Insufficient data". All null inputs returns
        Level 1 with all dimensions at 0.
    .PARAMETER SourceGovernance
        Hashtable output from Measure-SPSourceGovernance.
    .PARAMETER IdentityRisk
        Hashtable output from Measure-SPIdentityRisk.
    .PARAMETER ReviewerReputation
        Hashtable output from Measure-SPReviewerReputation.
    .PARAMETER CampaignMetrics
        Hashtable output from Measure-SPCampaignMetrics.
    .PARAMETER StaleAccess
        Hashtable output from Get-SPStaleAccess.
    .PARAMETER PolicyCompliance
        Hashtable output from Test-SPGovernancePolicy.
    .PARAMETER RemediationStatus
        Hashtable output from Get-SPRemediationStatus.
    .PARAMETER OrchestratorHistory
        Hashtable output from Get-SPOrchestratorHistory.
    .PARAMETER EntitlementInventory
        Hashtable output from Get-SPEntitlementInventory.
    .PARAMETER CorrelationID
        Unique ID for tracing related log entries. Auto-generated if omitted.
    .OUTPUTS
        [hashtable] Maturity scorecard with OverallScore, OverallLevel, Dimensions, TopImprovements.
    .EXAMPLE
        $maturity = Measure-SPGovernanceMaturity -SourceGovernance $gov -ReviewerReputation $rep
        $maturity.OverallLevelName   # 'Managed'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [hashtable]$SourceGovernance,

        [Parameter()]
        [hashtable]$IdentityRisk,

        [Parameter()]
        [hashtable]$ReviewerReputation,

        [Parameter()]
        [hashtable]$CampaignMetrics,

        [Parameter()]
        [hashtable]$StaleAccess,

        [Parameter()]
        [hashtable]$PolicyCompliance,

        [Parameter()]
        [hashtable]$RemediationStatus,

        [Parameter()]
        [hashtable]$OrchestratorHistory,

        [Parameter()]
        [hashtable]$EntitlementInventory,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Measure-SPGovernanceMaturity: starting maturity assessment" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPGovernanceMaturity' `
        -CorrelationID $CorrelationID

    # Helper: get maturity level from score
    $getLevel = {
        param([double]$score)
        if ($score -le 20) { return @{ Level = 1; Name = 'Initial' } }
        if ($score -le 40) { return @{ Level = 2; Name = 'Developing' } }
        if ($score -le 60) { return @{ Level = 3; Name = 'Defined' } }
        if ($score -le 80) { return @{ Level = 4; Name = 'Managed' } }
        return @{ Level = 5; Name = 'Optimizing' }
    }

    # Helper: safely read hashtable key
    $safeGet = {
        param([hashtable]$ht, [string]$key)
        if ($null -eq $ht) { return $null }
        if ($ht.ContainsKey($key)) { return $ht[$key] }
        return $null
    }

    # ===================================================================
    # Dimension 1: Coverage (weight 20%)
    # ===================================================================
    $coverageScore = 0.0
    $coverageFactors = [System.Collections.Generic.List[string]]::new()
    $coverageImprovement = 'Provide source governance data to assess coverage'

    if ($null -ne $SourceGovernance) {
        $summary = & $safeGet $SourceGovernance 'Summary'
        $sources = $SourceGovernance['Sources']

        $overallCoverage = 0.0
        if ($null -ne $summary -and $summary -is [hashtable] -and $summary.ContainsKey('OverallCoveragePct')) {
            $overallCoverage = [double]$summary['OverallCoveragePct']
        }

        $coverageScore = $overallCoverage
        $coverageFactors.Add("Overall coverage $($overallCoverage)%")

        # Penalty: -15 per Grade F source
        $gradeFCount = 0
        if ($null -ne $sources) {
            foreach ($src in @($sources)) {
                if ($null -eq $src) { continue }
                $grade = ''
                if ($src -is [hashtable] -and $src.ContainsKey('GovernanceGrade')) {
                    $grade = [string]$src['GovernanceGrade']
                } elseif ($null -ne $src.PSObject -and $null -ne $src.PSObject.Properties['GovernanceGrade']) {
                    $grade = [string]$src.GovernanceGrade
                }
                if ($grade -eq 'F') { $gradeFCount++ }
            }
        }

        if ($gradeFCount -gt 0) {
            $penalty = $gradeFCount * 15
            $coverageScore = $coverageScore - $penalty
            $coverageFactors.Add("$gradeFCount source(s) at Grade F (-$penalty)")
            $fSourceNames = @(@($sources) | Where-Object {
                $g = ''
                if ($_ -is [hashtable] -and $_.ContainsKey('GovernanceGrade')) { $g = $_['GovernanceGrade'] }
                elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['GovernanceGrade']) { $g = $_.GovernanceGrade }
                $g -eq 'F'
            } | ForEach-Object {
                if ($_ -is [hashtable] -and $_.ContainsKey('SourceName')) { $_['SourceName'] }
                elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['SourceName']) { $_.SourceName }
                else { 'Unknown' }
            })
            $coverageImprovement = "Bring $($fSourceNames -join ', ') source(s) to Grade C or above"
        } else {
            if ($overallCoverage -lt 90) {
                $coverageImprovement = "Increase overall coverage from $($overallCoverage)% toward 90%+"
            } else {
                $coverageImprovement = 'Maintain current coverage level'
            }
        }
    } else {
        $coverageFactors.Add('Insufficient data')
    }

    $coverageScore = [Math]::Min(100, [Math]::Max(0, $coverageScore))

    # ===================================================================
    # Dimension 2: Timeliness (weight 20%)
    # ===================================================================
    $timelinessScore = 0.0
    $timelinessFactors = [System.Collections.Generic.List[string]]::new()
    $timelinessImprovement = 'Provide campaign metrics data to assess timeliness'

    if ($null -ne $CampaignMetrics) {
        # CampaignMetrics from Measure-SPCampaignMetrics: @{Success; Data=@(PSCustomObject...)}
        $metricsData = @()
        if ($CampaignMetrics.ContainsKey('Data') -and $null -ne $CampaignMetrics['Data']) {
            $metricsData = @($CampaignMetrics['Data'])
        }

        if ($metricsData.Count -gt 0) {
            # Avg response hours across all campaigns
            $responseHours = @($metricsData | ForEach-Object {
                $h = $null
                if ($_ -is [hashtable] -and $_.ContainsKey('AvgResponseTimeHours')) { $h = $_['AvgResponseTimeHours'] }
                elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['AvgResponseTimeHours']) { $h = $_.AvgResponseTimeHours }
                if ($null -ne $h) { [double]$h }
            } | Where-Object { $_ -ge 0 })

            $avgResponse = 36.0
            if ($responseHours.Count -gt 0) {
                $avgResponse = ($responseHours | Measure-Object -Average).Average
            }

            # Linear scale: <12h = 100, >72h = 0
            $clamped = [Math]::Min(72, [Math]::Max(12, $avgResponse))
            $timelinessScore = [Math]::Round((1 - (($clamped - 12) / 60)) * 100, 1)
            $timelinessFactors.Add("Avg response $([Math]::Round($avgResponse, 1)) hours")

            # Bonus/Penalty: deadline status
            $overdueCount = 0
            $totalCampaigns = $metricsData.Count
            foreach ($m in $metricsData) {
                $status = ''
                if ($m -is [hashtable] -and $m.ContainsKey('DeadlineStatus')) { $status = [string]$m['DeadlineStatus'] }
                elseif ($null -ne $m.PSObject -and $null -ne $m.PSObject.Properties['DeadlineStatus']) { $status = [string]$m.DeadlineStatus }
                if ($status -eq 'Overdue') { $overdueCount++ }
            }

            if ($overdueCount -eq 0 -and $totalCampaigns -gt 0) {
                $timelinessScore += 10
                $timelinessFactors.Add('100% on-time completion (+10)')
            }

            if ($overdueCount -gt 0) {
                $penalty = $overdueCount * 10
                $timelinessScore -= $penalty
                $timelinessFactors.Add("$overdueCount overdue campaign(s) (-$penalty)")
            }

            if ($avgResponse -gt 12) {
                $timelinessImprovement = "Reduce avg response time below 12 hours (currently $([Math]::Round($avgResponse, 1))h)"
            } else {
                $timelinessImprovement = 'Maintain current response time performance'
            }
        } else {
            $timelinessFactors.Add('No campaign metrics data available')
        }
    } else {
        $timelinessFactors.Add('Insufficient data')
    }

    $timelinessScore = [Math]::Min(100, [Math]::Max(0, $timelinessScore))

    # ===================================================================
    # Dimension 3: Enforcement (weight 20%)
    # ===================================================================
    $enforcementScore = 0.0
    $enforcementFactors = [System.Collections.Generic.List[string]]::new()
    $enforcementImprovement = 'Provide remediation status data to assess enforcement'

    if ($null -ne $RemediationStatus) {
        $remData = $null
        if ($RemediationStatus.ContainsKey('Data') -and $null -ne $RemediationStatus['Data']) {
            $remData = $RemediationStatus['Data']
        }

        $remSummary = $null
        if ($null -ne $remData -and $remData -is [hashtable] -and $remData.ContainsKey('Summary')) {
            $remSummary = $remData['Summary']
        }

        if ($null -ne $remSummary -and $remSummary -is [hashtable]) {
            $total = if ($remSummary.ContainsKey('Total')) { [int]$remSummary['Total'] } else { 0 }
            $overdue = if ($remSummary.ContainsKey('Overdue')) { [int]$remSummary['Overdue'] } else { 0 }
            $failed = if ($remSummary.ContainsKey('Failed')) { [int]$remSummary['Failed'] } else { 0 }

            if ($total -gt 0) {
                $slaCompliance = [Math]::Round((($total - $overdue - $failed) / $total) * 100, 1)
                $enforcementScore = $slaCompliance
                $enforcementFactors.Add("SLA compliance $($slaCompliance)%")

                # Penalty: -5 per overdue item (max -20)
                if ($overdue -gt 0) {
                    $penalty = [Math]::Min(20, $overdue * 5)
                    $enforcementScore -= $penalty
                    $enforcementFactors.Add("$overdue overdue remediation(s) (-$penalty)")
                    $enforcementImprovement = "Clear $overdue overdue remediation(s)"
                } else {
                    $enforcementImprovement = 'Maintain current SLA compliance'
                }
            } else {
                $enforcementScore = 100
                $enforcementFactors.Add('No remediations required (full compliance)')
                $enforcementImprovement = 'No action needed'
            }
        } else {
            $enforcementFactors.Add('Remediation summary not available')
        }
    } else {
        $enforcementFactors.Add('Insufficient data')
    }

    # Bonus: Stale access < 5% of total entitlements
    if ($null -ne $StaleAccess -and $null -ne $EntitlementInventory) {
        $staleCount = 0
        $staleSummary = & $safeGet $StaleAccess 'Summary'
        if ($null -ne $staleSummary -and $staleSummary -is [hashtable] -and $staleSummary.ContainsKey('TotalStaleItems')) {
            $staleCount = [int]$staleSummary['TotalStaleItems']
        }

        $totalEnts = 0
        if ($EntitlementInventory -is [hashtable] -and $EntitlementInventory.ContainsKey('Data')) {
            $invData = $EntitlementInventory['Data']
            if ($null -ne $invData -and $invData -is [hashtable] -and $invData.ContainsKey('TotalEntitlements')) {
                $totalEnts = [int]$invData['TotalEntitlements']
            }
        }

        if ($totalEnts -gt 0) {
            $stalePct = [Math]::Round(($staleCount / $totalEnts) * 100, 1)
            if ($stalePct -lt 5) {
                $enforcementScore += 10
                $enforcementFactors.Add("Stale access $($stalePct)% (< 5%, +10)")
            }
        }
    }

    $enforcementScore = [Math]::Min(100, [Math]::Max(0, $enforcementScore))

    # ===================================================================
    # Dimension 4: Accountability (weight 15%)
    # ===================================================================
    $accountabilityScore = 0.0
    $accountabilityFactors = [System.Collections.Generic.List[string]]::new()
    $accountabilityImprovement = 'Provide reviewer reputation data to assess accountability'

    if ($null -ne $ReviewerReputation) {
        $reviewers = @()
        if ($ReviewerReputation.ContainsKey('Reviewers') -and $null -ne $ReviewerReputation['Reviewers']) {
            $reviewers = @($ReviewerReputation['Reviewers'])
        }

        if ($reviewers.Count -gt 0) {
            # Avg reputation score maps directly
            $repScores = @($reviewers | ForEach-Object {
                if ($_ -is [hashtable] -and $_.ContainsKey('ReputationScore')) { [double]$_['ReputationScore'] }
                elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['ReputationScore']) { [double]$_.ReputationScore }
            } | Where-Object { $_ -ge 0 })

            $avgReputation = 50.0
            if ($repScores.Count -gt 0) {
                $avgReputation = [Math]::Round(($repScores | Measure-Object -Average).Average, 1)
            }

            $accountabilityScore = $avgReputation
            $accountabilityFactors.Add("Avg reputation $avgReputation")

            # Penalty: -10 per At Risk reviewer (max -20)
            $atRiskReviewers = @($reviewers | Where-Object {
                $tier = ''
                if ($_ -is [hashtable] -and $_.ContainsKey('ReputationTier')) { $tier = $_['ReputationTier'] }
                elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['ReputationTier']) { $tier = $_.ReputationTier }
                $tier -eq 'At Risk'
            })

            if ($atRiskReviewers.Count -gt 0) {
                $penalty = [Math]::Min(20, $atRiskReviewers.Count * 10)
                $accountabilityScore -= $penalty
                $accountabilityFactors.Add("$($atRiskReviewers.Count) At Risk reviewer(s) (-$penalty)")

                $atRiskNames = @($atRiskReviewers | ForEach-Object {
                    if ($_ -is [hashtable] -and $_.ContainsKey('ReviewerName')) { $_['ReviewerName'] }
                    elseif ($null -ne $_.PSObject -and $null -ne $_.PSObject.Properties['ReviewerName']) { $_.ReviewerName }
                    else { 'Unknown' }
                })
                $accountabilityImprovement = "Address $($atRiskNames -join ', ') performance (At Risk tier)"
            }

            # Bonus: All Good or Excellent
            $repSummary = & $safeGet $ReviewerReputation 'Summary'
            $allGoodOrExcellent = $false
            if ($null -ne $repSummary -and $repSummary -is [hashtable]) {
                $atRiskCount = if ($repSummary.ContainsKey('AtRisk')) { [int]$repSummary['AtRisk'] } else { 0 }
                $needsAttCount = if ($repSummary.ContainsKey('NeedsAttention')) { [int]$repSummary['NeedsAttention'] } else { 0 }
                if ($atRiskCount -eq 0 -and $needsAttCount -eq 0 -and $reviewers.Count -gt 0) {
                    $allGoodOrExcellent = $true
                }
            }

            if ($allGoodOrExcellent) {
                $accountabilityScore += 10
                $accountabilityFactors.Add('All reviewers Good or Excellent (+10)')
                $accountabilityImprovement = 'Maintain current reviewer performance'
            } elseif ($atRiskReviewers.Count -eq 0) {
                $accountabilityImprovement = 'Improve Needs Attention reviewers to Good tier'
            }
        } else {
            $accountabilityFactors.Add('No reviewer data available')
        }
    } else {
        $accountabilityFactors.Add('Insufficient data')
    }

    $accountabilityScore = [Math]::Min(100, [Math]::Max(0, $accountabilityScore))

    # ===================================================================
    # Dimension 5: Documentation (weight 10%)
    # ===================================================================
    $documentationScore = 0.0
    $documentationFactors = [System.Collections.Generic.List[string]]::new()
    $documentationImprovement = 'Implement governance policy engine and run policy compliance checks'

    if ($null -ne $PolicyCompliance) {
        # PolicyCompliance from Test-SPGovernancePolicy:
        # @{ OverallCompliant; Policies=@(@{Result='PASS'/'FAIL'/'SKIPPED'; ...}); Summary=@{...} }
        $policies = @()
        if ($PolicyCompliance.ContainsKey('Policies') -and $null -ne $PolicyCompliance['Policies']) {
            $policies = @($PolicyCompliance['Policies'])
        }

        if ($policies.Count -gt 0) {
            $skippedCount = 0
            $totalPolicies = $policies.Count
            $passedCount = 0

            foreach ($pol in $policies) {
                $result = ''
                if ($pol -is [hashtable] -and $pol.ContainsKey('Result')) { $result = [string]$pol['Result'] }
                elseif ($null -ne $pol.PSObject -and $null -ne $pol.PSObject.Properties['Result']) { $result = [string]$pol.Result }
                if ($result -eq 'SKIPPED') { $skippedCount++ }
                if ($result -eq 'PASS') { $passedCount++ }
            }

            # Baseline: All policies evaluated (not skipped) = 80
            $evaluated = $totalPolicies - $skippedCount
            if ($evaluated -eq $totalPolicies -and $totalPolicies -gt 0) {
                $documentationScore = 80
                $documentationFactors.Add("$totalPolicies/$totalPolicies policies evaluated")
            } elseif ($totalPolicies -gt 0) {
                $documentationScore = [Math]::Round(($evaluated / $totalPolicies) * 80, 1)
                $documentationFactors.Add("$evaluated/$totalPolicies policies evaluated ($skippedCount skipped)")
            }

            # Bonus: policy compliance rate > 80%
            if ($evaluated -gt 0) {
                $complianceRate = [Math]::Round(($passedCount / $evaluated) * 100, 1)
                $documentationFactors.Add("$([Math]::Round($complianceRate, 0))% policy compliance")
                if ($complianceRate -gt 80) {
                    $documentationScore += 10
                    $documentationFactors.Add('Policy compliance > 80% (+10)')
                }

                if ($complianceRate -le 80) {
                    $documentationImprovement = "Improve policy compliance above 80% (currently $($complianceRate)%)"
                } else {
                    $documentationImprovement = 'Maintain current policy compliance'
                }
            }

            # Bonus: compliance evidence packages generated (+10)
            $overallCompliant = $false
            if ($PolicyCompliance.ContainsKey('OverallCompliant')) {
                $overallCompliant = [bool]$PolicyCompliance['OverallCompliant']
            }
            if ($overallCompliant) {
                $documentationScore += 10
                $documentationFactors.Add('Compliance evidence generated (+10)')
            }
        } else {
            $documentationFactors.Add('No policies configured')
        }
    } else {
        $documentationFactors.Add('Insufficient data')
    }

    $documentationScore = [Math]::Min(100, [Math]::Max(0, $documentationScore))

    # ===================================================================
    # Dimension 6: Automation (weight 15%)
    # ===================================================================
    $automationScore = 0.0
    $automationFactors = [System.Collections.Generic.List[string]]::new()
    $automationImprovement = 'Configure and run the daily orchestrator to assess automation maturity'

    if ($null -ne $OrchestratorHistory) {
        $metrics = & $safeGet $OrchestratorHistory 'Metrics'

        if ($null -ne $metrics -and $metrics -is [hashtable]) {
            $successRate = if ($metrics.ContainsKey('SuccessRate')) { [double]$metrics['SuccessRate'] } else { 0 }
            $consecutiveFailures = if ($metrics.ContainsKey('ConsecutiveFailures')) { [int]$metrics['ConsecutiveFailures'] } else { 0 }
            $runCount = if ($metrics.ContainsKey('RunCount')) { [int]$metrics['RunCount'] } else { 0 }

            # Success rate maps directly
            $automationScore = $successRate
            $automationFactors.Add("Orchestrator success $($successRate)%")

            # Penalty: consecutive failures > 2 = -15
            if ($consecutiveFailures -gt 2) {
                $automationScore -= 15
                $automationFactors.Add("$consecutiveFailures consecutive failures (-15)")
                $automationImprovement = "Investigate $consecutiveFailures consecutive orchestrator failures"
            }

            # Bonus: daily runs for 30+ days
            if ($runCount -ge 30) {
                $automationScore += 10
                $automationFactors.Add("$runCount runs (30+ days, +10)")
                if ($consecutiveFailures -le 2) {
                    $failedRuns = $runCount - [Math]::Round($runCount * $successRate / 100)
                    if ($failedRuns -gt 0) {
                        $automationImprovement = "Investigate $failedRuns failed run(s) for root cause"
                    } else {
                        $automationImprovement = 'Maintain current automation reliability'
                    }
                }
            } else {
                if ($consecutiveFailures -le 2) {
                    $automationImprovement = "Increase orchestrator run frequency (currently $runCount runs, target 30+)"
                }
            }
        } else {
            $automationFactors.Add('No orchestrator metrics available')
        }
    } else {
        $automationFactors.Add('Insufficient data')
    }

    $automationScore = [Math]::Min(100, [Math]::Max(0, $automationScore))

    # ===================================================================
    # Build dimension results and weighted overall score
    # ===================================================================
    $weights = @{
        Coverage       = 0.20
        Timeliness     = 0.20
        Enforcement    = 0.20
        Accountability = 0.15
        Documentation  = 0.10
        Automation     = 0.15
    }

    $dimensionScores = @{
        Coverage       = $coverageScore
        Timeliness     = $timelinessScore
        Enforcement    = $enforcementScore
        Accountability = $accountabilityScore
        Documentation  = $documentationScore
        Automation     = $automationScore
    }

    $overallScore = 0.0
    foreach ($dim in $weights.Keys) {
        $overallScore += $dimensionScores[$dim] * $weights[$dim]
    }
    $overallScore = [Math]::Round($overallScore, 1)
    $overallScore = [Math]::Min(100, [Math]::Max(0, $overallScore))

    $overall = & $getLevel $overallScore

    $dimensions = @{
        Coverage = @{
            Score       = [Math]::Round($coverageScore, 1)
            Level       = (& $getLevel $coverageScore).Level
            Weight      = $weights['Coverage']
            KeyFactors  = @($coverageFactors)
            Improvement = $coverageImprovement
        }
        Timeliness = @{
            Score       = [Math]::Round($timelinessScore, 1)
            Level       = (& $getLevel $timelinessScore).Level
            Weight      = $weights['Timeliness']
            KeyFactors  = @($timelinessFactors)
            Improvement = $timelinessImprovement
        }
        Enforcement = @{
            Score       = [Math]::Round($enforcementScore, 1)
            Level       = (& $getLevel $enforcementScore).Level
            Weight      = $weights['Enforcement']
            KeyFactors  = @($enforcementFactors)
            Improvement = $enforcementImprovement
        }
        Accountability = @{
            Score       = [Math]::Round($accountabilityScore, 1)
            Level       = (& $getLevel $accountabilityScore).Level
            Weight      = $weights['Accountability']
            KeyFactors  = @($accountabilityFactors)
            Improvement = $accountabilityImprovement
        }
        Documentation = @{
            Score       = [Math]::Round($documentationScore, 1)
            Level       = (& $getLevel $documentationScore).Level
            Weight      = $weights['Documentation']
            KeyFactors  = @($documentationFactors)
            Improvement = $documentationImprovement
        }
        Automation = @{
            Score       = [Math]::Round($automationScore, 1)
            Level       = (& $getLevel $automationScore).Level
            Weight      = $weights['Automation']
            KeyFactors  = @($automationFactors)
            Improvement = $automationImprovement
        }
    }

    # ===================================================================
    # Top improvements sorted by potential score impact (highest first)
    # ===================================================================
    $improvements = [System.Collections.Generic.List[hashtable]]::new()
    $maintainPhrases = @(
        'Maintain current coverage level',
        'Maintain current response time performance',
        'Maintain current SLA compliance',
        'Maintain current reviewer performance',
        'Maintain current policy compliance',
        'Maintain current automation reliability',
        'No action needed'
    )

    foreach ($dimName in @('Coverage','Timeliness','Enforcement','Accountability','Documentation','Automation')) {
        $dim = $dimensions[$dimName]
        $potential = [Math]::Round((100 - $dim['Score']) * $dim['Weight'] * 100 / 100, 0)
        if ($potential -gt 0 -and $dim['Improvement'] -notin $maintainPhrases) {
            $improvements.Add(@{
                Dimension   = $dimName
                Improvement = $dim['Improvement']
                Potential   = $potential
            })
        }
    }

    $sortedImprovements = @($improvements | Sort-Object { $_['Potential'] } -Descending)
    $topImprovements = @($sortedImprovements | Select-Object -First 3 | ForEach-Object {
        "$($_['Improvement']) ($($_['Dimension']): +$($_['Potential']) potential)"
    })

    Write-SPLog -Message "Measure-SPGovernanceMaturity: Overall=$overallScore (Level $($overall.Level) - $($overall.Name)), Coverage=$([Math]::Round($coverageScore,1)), Timeliness=$([Math]::Round($timelinessScore,1)), Enforcement=$([Math]::Round($enforcementScore,1)), Accountability=$([Math]::Round($accountabilityScore,1)), Documentation=$([Math]::Round($documentationScore,1)), Automation=$([Math]::Round($automationScore,1))" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Measure-SPGovernanceMaturity' `
        -CorrelationID $CorrelationID

    return @{
        OverallScore     = $overallScore
        OverallLevel     = $overall.Level
        OverallLevelName = $overall.Name
        EvaluatedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Dimensions       = $dimensions
        TopImprovements  = $topImprovements
    }
}

#endregion

#region Multi-Source Identity Correlation (P13-03)

function Get-SPIdentityAccessSpread {
    <#
    .SYNOPSIS
        Analyzes campaign audit data to identify identities with access spanning multiple sources.
    .DESCRIPTION
        Iterates campaign audit decision items to build a per-identity map of unique
        sources they hold access on. Filters to identities meeting a minimum source
        count threshold, with optional filtering to privileged-only sources.

        Answers: "Which identities have the broadest access footprint across our
        environment? Who has accounts on 5+ sources? Where is privilege concentrated?"
    .PARAMETER CampaignAudits
        Array of campaign audit hashtables with Decisions (Approved/Revoked/Pending arrays).
    .PARAMETER MinSources
        Minimum number of unique sources an identity must have access on to be included. Default 3.
    .PARAMETER PrivilegedOnly
        When set, only count sources where the identity holds at least one privileged entitlement.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Identities = @(...); Summary = @{...} }
    .EXAMPLE
        $spread = Get-SPIdentityAccessSpread -CampaignAudits $audits -MinSources 3
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$CampaignAudits,

        [Parameter()]
        [int]$MinSources = 3,

        [Parameter()]
        [switch]$PrivilegedOnly,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPIdentityAccessSpread: starting with $($CampaignAudits.Count) campaign(s), MinSources=$MinSources, PrivilegedOnly=$PrivilegedOnly" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPIdentityAccessSpread' `
        -CorrelationID $CorrelationID

    if ($null -eq $CampaignAudits -or $CampaignAudits.Count -eq 0) {
        return @{
            Identities = @()
            Summary    = @{
                TotalIdentitiesAnalyzed        = 0
                IdentitiesAboveThreshold       = 0
                AvgSourceCount                 = 0
                MaxSourceCount                 = 0
                IdentitiesWithPrivilegedSpread = 0
            }
        }
    }

    $identityMap = @{}

    foreach ($audit in $CampaignAudits) {
        if ($null -eq $audit) { continue }

        $decisions = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) {
            $audit['Decisions']
        } else { @{ Approved = @(); Revoked = @(); Pending = @() } }

        foreach ($category in @('Approved', 'Revoked', 'Pending')) {
            $items = @()
            if ($decisions -is [hashtable] -and $decisions.ContainsKey($category) -and $null -ne $decisions[$category]) {
                $items = @($decisions[$category])
            }

            foreach ($item in $items) {
                if ($null -eq $item) { continue }

                $identityId   = ''
                $identityName = ''
                $sourceName   = ''
                $accessName   = ''
                $decisionDate = ''
                $decision     = ''
                $riskFlags    = @()

                if ($item -is [hashtable]) {
                    $identityId   = if ($item.ContainsKey('IdentityId'))   { [string]$item['IdentityId'] }   else { '' }
                    $identityName = if ($item.ContainsKey('IdentityName')) { [string]$item['IdentityName'] } else { '' }
                    $sourceName   = if ($item.ContainsKey('SourceName'))   { [string]$item['SourceName'] }   else { '' }
                    $accessName   = if ($item.ContainsKey('AccessName'))   { [string]$item['AccessName'] }   else { '' }
                    $decisionDate = if ($item.ContainsKey('DecisionDate')) { [string]$item['DecisionDate'] } else { '' }
                    $decision     = if ($item.ContainsKey('Decision'))     { [string]$item['Decision'] }     else { '' }
                    $riskFlags    = if ($item.ContainsKey('RiskFlags') -and $null -ne $item['RiskFlags']) { @($item['RiskFlags']) } else { @() }
                } else {
                    $idProp = $item.PSObject.Properties['IdentityId']
                    $identityId = if ($null -ne $idProp -and $null -ne $idProp.Value) { [string]$idProp.Value } else { '' }
                    $nmProp = $item.PSObject.Properties['IdentityName']
                    $identityName = if ($null -ne $nmProp -and $null -ne $nmProp.Value) { [string]$nmProp.Value } else { '' }
                    $snProp = $item.PSObject.Properties['SourceName']
                    $sourceName = if ($null -ne $snProp -and $null -ne $snProp.Value) { [string]$snProp.Value } else { '' }
                    $anProp = $item.PSObject.Properties['AccessName']
                    $accessName = if ($null -ne $anProp -and $null -ne $anProp.Value) { [string]$anProp.Value } else { '' }
                    $ddProp = $item.PSObject.Properties['DecisionDate']
                    $decisionDate = if ($null -ne $ddProp -and $null -ne $ddProp.Value) { [string]$ddProp.Value } else { '' }
                    $dcProp = $item.PSObject.Properties['Decision']
                    $decision = if ($null -ne $dcProp -and $null -ne $dcProp.Value) { [string]$dcProp.Value } else { '' }
                    $rfProp = $item.PSObject.Properties['RiskFlags']
                    $riskFlags = if ($null -ne $rfProp -and $null -ne $rfProp.Value) { @($rfProp.Value) } else { @() }
                }

                if ([string]::IsNullOrWhiteSpace($identityId)) { continue }
                if ([string]::IsNullOrWhiteSpace($sourceName)) { continue }

                $isPrivileged = $false
                foreach ($flag in $riskFlags) {
                    if ($flag -eq 'PRIVILEGED') { $isPrivileged = $true; break }
                }

                if ([string]::IsNullOrWhiteSpace($decision)) {
                    $decision = switch ($category) {
                        'Approved' { 'APPROVE' }
                        'Revoked'  { 'REVOKE' }
                        default    { '' }
                    }
                }

                if (-not $identityMap.ContainsKey($identityId)) {
                    $identityMap[$identityId] = @{
                        IdentityId    = $identityId
                        IdentityName  = $identityName
                        Sources       = @{}
                        HasRevocation = $false
                    }
                }

                $idRec = $identityMap[$identityId]

                if (-not [string]::IsNullOrWhiteSpace($identityName)) {
                    $idRec['IdentityName'] = $identityName
                }

                if ($decision.ToUpperInvariant() -eq 'REVOKE') {
                    $idRec['HasRevocation'] = $true
                }

                if (-not $idRec['Sources'].ContainsKey($sourceName)) {
                    $idRec['Sources'][$sourceName] = @{
                        SourceName       = $sourceName
                        EntitlementCount = 0
                        PrivilegedCount  = 0
                        LastReviewDate   = $null
                        Entitlements     = @{}
                    }
                }

                $srcRec = $idRec['Sources'][$sourceName]

                if (-not [string]::IsNullOrWhiteSpace($accessName) -and -not $srcRec['Entitlements'].ContainsKey($accessName)) {
                    $srcRec['Entitlements'][$accessName] = $true
                    $srcRec['EntitlementCount']++
                    if ($isPrivileged) {
                        $srcRec['PrivilegedCount']++
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($decisionDate)) {
                    try {
                        $dt = [datetime]::Parse($decisionDate,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        if ($null -eq $srcRec['LastReviewDate'] -or $dt -gt $srcRec['LastReviewDate']) {
                            $srcRec['LastReviewDate'] = $dt
                        }
                    } catch { }
                }
            }
        }
    }

    $totalAnalyzed = $identityMap.Count
    $identityResults = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($idKey in $identityMap.Keys) {
        $idRec = $identityMap[$idKey]
        $sources = $idRec['Sources']

        $effectiveSources = @{}
        foreach ($srcName in $sources.Keys) {
            $srcRec = $sources[$srcName]
            if ($PrivilegedOnly) {
                if ($srcRec['PrivilegedCount'] -gt 0) {
                    $effectiveSources[$srcName] = $srcRec
                }
            } else {
                $effectiveSources[$srcName] = $srcRec
            }
        }

        $sourceCount = $effectiveSources.Count
        if ($sourceCount -lt $MinSources) { continue }

        $totalEntitlements = 0
        $privilegedEntitlements = 0
        $broadestSourceName = ''
        $broadestSourceCount = 0

        $sourceDetails = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($srcName in $effectiveSources.Keys) {
            $srcRec = $effectiveSources[$srcName]
            $totalEntitlements += $srcRec['EntitlementCount']
            $privilegedEntitlements += $srcRec['PrivilegedCount']

            if ($srcRec['EntitlementCount'] -gt $broadestSourceCount) {
                $broadestSourceCount = $srcRec['EntitlementCount']
                $broadestSourceName = $srcName
            }

            $lastReviewStr = if ($null -ne $srcRec['LastReviewDate']) {
                $srcRec['LastReviewDate'].ToString('yyyy-MM-dd')
            } else { $null }

            $sourceDetails.Add(@{
                SourceId         = ''
                SourceName       = $srcName
                EntitlementCount = $srcRec['EntitlementCount']
                PrivilegedCount  = $srcRec['PrivilegedCount']
                LastReviewDate   = $lastReviewStr
            })
        }

        $sortedSources = @($sourceDetails | Sort-Object { $_['EntitlementCount'] } -Descending)

        $identityResults.Add(@{
            IdentityId             = $idRec['IdentityId']
            IdentityName           = $idRec['IdentityName']
            SourceCount            = $sourceCount
            TotalEntitlements      = $totalEntitlements
            PrivilegedEntitlements = $privilegedEntitlements
            ApprovalOnlyFlag       = (-not $idRec['HasRevocation'])
            BroadestSource         = $broadestSourceName
            Sources                = $sortedSources
        })
    }

    $sorted = @($identityResults | Sort-Object @(
        @{ Expression = { $_['SourceCount'] }; Descending = $true },
        @{ Expression = { $_['PrivilegedEntitlements'] }; Descending = $true }
    ))

    $aboveThreshold = $sorted.Count
    $maxSourceCount = 0
    $totalSourceCounts = 0
    $privilegedSpreadCount = 0

    foreach ($id in $sorted) {
        $totalSourceCounts += $id['SourceCount']
        if ($id['SourceCount'] -gt $maxSourceCount) {
            $maxSourceCount = $id['SourceCount']
        }
        $privSourceCount = 0
        foreach ($src in $id['Sources']) {
            if ($src['PrivilegedCount'] -gt 0) { $privSourceCount++ }
        }
        if ($privSourceCount -ge 2) { $privilegedSpreadCount++ }
    }

    $avgSourceCount = if ($aboveThreshold -gt 0) {
        [Math]::Round($totalSourceCounts / $aboveThreshold, 1)
    } else { 0 }

    Write-SPLog -Message "Get-SPIdentityAccessSpread: analyzed $totalAnalyzed identities, $aboveThreshold above threshold (MinSources=$MinSources)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPIdentityAccessSpread' `
        -CorrelationID $CorrelationID

    return @{
        Identities = $sorted
        Summary    = @{
            TotalIdentitiesAnalyzed        = $totalAnalyzed
            IdentitiesAboveThreshold       = $aboveThreshold
            AvgSourceCount                 = $avgSourceCount
            MaxSourceCount                 = $maxSourceCount
            IdentitiesWithPrivilegedSpread = $privilegedSpreadCount
        }
    }
}

#endregion


#region P13-06: Audit Period Comparison

function Compare-SPAuditPeriods {
    <#
    .SYNOPSIS
        Compares two time windows across all governance dimensions.
    .DESCRIPTION
        Accepts two period hashtables, each containing pre-computed analytics output
        (campaign metrics, identity risk, source governance, reviewer reputation,
        stale access, remediation status), and produces a structured side-by-side
        comparison with delta calculations and governance direction classification.

        Direction classification:
        - Improved: Metric moved in the governance-positive direction
        - Degraded: Metric moved in the governance-negative direction
        - Stable: Change within +/- 2% threshold

        Answers: "How did our governance posture change between Q1 and Q2?"
    .PARAMETER PeriodA
        Hashtable for the baseline period. Expected keys: Label, DateRange,
        CampaignMetrics, IdentityRisk, SourceGovernance, ReviewerReputation,
        StaleAccess, RemediationStatus (optional).
    .PARAMETER PeriodB
        Hashtable for the comparison period (same structure as PeriodA).
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] Comparison result with Dimensions, OverallDirection, Summary.
    .EXAMPLE
        $q1 = @{ Label='Q1 2026'; DateRange=@{After='2026-01-01';Before='2026-03-31'}; CampaignMetrics=$cm1; IdentityRisk=$ir1 }
        $q2 = @{ Label='Q2 2026'; DateRange=@{After='2026-04-01';Before='2026-06-30'}; CampaignMetrics=$cm2; IdentityRisk=$ir2 }
        $result = Compare-SPAuditPeriods -PeriodA $q1 -PeriodB $q2
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$PeriodA,

        [Parameter(Mandatory)]
        [hashtable]$PeriodB,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Compare-SPAuditPeriods: comparing '$($PeriodA['Label'])' vs '$($PeriodB['Label'])'" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPAuditPeriods' `
        -CorrelationID $CorrelationID

    # --- Helper: safe hashtable key access ---
    function Get-SafeValue {
        param([object]$Obj, [string]$Key)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [hashtable]) {
            if ($Obj.ContainsKey($Key)) { return $Obj[$Key] }
            return $null
        }
        $prop = $Obj.PSObject.Properties[$Key]
        if ($null -ne $prop) { return $prop.Value }
        return $null
    }

    # --- Helper: classify governance direction ---
    function Get-Direction {
        param(
            [object]$ValA,
            [object]$ValB,
            [string]$PositiveDirection,  # 'higher', 'lower', 'none'
            [double]$Threshold = 2.0
        )
        if ($null -eq $ValA -or $null -eq $ValB) { return 'N/A' }
        $a = [double]$ValA
        $b = [double]$ValB
        $delta = [Math]::Round($b - $a, 2)
        if ([Math]::Abs($delta) -le $Threshold) { return 'Stable' }
        if ($PositiveDirection -eq 'none') { return 'Stable' }
        if ($PositiveDirection -eq 'higher') {
            return $(if ($delta -gt 0) { 'Improved' } else { 'Degraded' })
        }
        if ($PositiveDirection -eq 'lower') {
            return $(if ($delta -lt 0) { 'Improved' } else { 'Degraded' })
        }
        return 'Stable'
    }

    # --- Helper: build metric comparison object ---
    function New-MetricComparison {
        param(
            [object]$ValA,
            [object]$ValB,
            [string]$PositiveDirection,
            [double]$Threshold = 2.0
        )
        if ($null -eq $ValA -and $null -eq $ValB) {
            return @{ A = $null; B = $null; Delta = $null; Direction = 'N/A' }
        }
        if ($null -eq $ValA -or $null -eq $ValB) {
            return @{
                A = $ValA
                B = $ValB
                Delta = $null
                Direction = 'N/A'
            }
        }
        $a = [Math]::Round([double]$ValA, 1)
        $b = [Math]::Round([double]$ValB, 1)
        $delta = [Math]::Round($b - $a, 1)
        $direction = Get-Direction -ValA $a -ValB $b -PositiveDirection $PositiveDirection -Threshold $Threshold
        return @{ A = $a; B = $b; Delta = $delta; Direction = $direction }
    }

    # Direction counters for overall summary
    $improvedCount = 0
    $degradedCount = 0
    $stableCount = 0

    function Update-DirectionCounts {
        param([string]$Dir)
        switch ($Dir) {
            'Improved' { $script:improvedCount++ }
            'Degraded' { $script:degradedCount++ }
            'Stable'   { $script:stableCount++ }
        }
    }

    # ========================================
    # 1. Campaign Metrics Delta
    # ========================================
    $campaignMetricsDim = $null
    $cmA = Get-SafeValue $PeriodA 'CampaignMetrics'
    $cmB = Get-SafeValue $PeriodB 'CampaignMetrics'

    if ($null -ne $cmA -or $null -ne $cmB) {
        # Extract aggregate values from Measure-SPCampaignMetrics output
        # Output is @{ Success; Data = @(PSCustomObject[]) }
        function Get-CampaignAggregates {
            param([object]$CmOutput)
            if ($null -eq $CmOutput) { return $null }
            $data = $null
            if ($CmOutput -is [hashtable] -and $CmOutput.ContainsKey('Data') -and $null -ne $CmOutput['Data']) {
                $data = @($CmOutput['Data'])
            } elseif ($CmOutput -is [array]) {
                $data = @($CmOutput)
            } else {
                return $null
            }
            if ($data.Count -eq 0) { return $null }
            $totalCampaigns = $data.Count
            $sumApproval = 0.0; $sumRevocation = 0.0; $sumResponse = 0.0; $sumCompletion = 0.0
            $responseCount = 0
            foreach ($c in $data) {
                $ar = Get-SafeValue $c 'ApprovalRate'
                $rr = Get-SafeValue $c 'RevocationRate'
                $rt = Get-SafeValue $c 'AvgResponseTimeHours'
                $cr = Get-SafeValue $c 'CompletionRate'
                if ($null -ne $ar) { $sumApproval += [double]$ar }
                if ($null -ne $rr) { $sumRevocation += [double]$rr }
                if ($null -ne $rt -and [double]$rt -gt 0) { $sumResponse += [double]$rt; $responseCount++ }
                if ($null -ne $cr) { $sumCompletion += [double]$cr }
            }
            return @{
                TotalCampaigns = $totalCampaigns
                AvgApprovalRate = [Math]::Round($sumApproval / $totalCampaigns, 1)
                AvgRevocationRate = [Math]::Round($sumRevocation / $totalCampaigns, 1)
                AvgResponseHrs = if ($responseCount -gt 0) { [Math]::Round($sumResponse / $responseCount, 1) } else { $null }
                AvgCompletionRate = [Math]::Round($sumCompletion / $totalCampaigns, 1)
            }
        }

        $aggA = Get-CampaignAggregates $cmA
        $aggB = Get-CampaignAggregates $cmB

        $approvalComp = New-MetricComparison -ValA (Get-SafeValue $aggA 'AvgApprovalRate') `
            -ValB (Get-SafeValue $aggB 'AvgApprovalRate') -PositiveDirection 'none'
        Update-DirectionCounts $approvalComp['Direction']

        $revocationComp = New-MetricComparison -ValA (Get-SafeValue $aggA 'AvgRevocationRate') `
            -ValB (Get-SafeValue $aggB 'AvgRevocationRate') -PositiveDirection 'higher'
        Update-DirectionCounts $revocationComp['Direction']

        $responseComp = New-MetricComparison -ValA (Get-SafeValue $aggA 'AvgResponseHrs') `
            -ValB (Get-SafeValue $aggB 'AvgResponseHrs') -PositiveDirection 'lower'
        Update-DirectionCounts $responseComp['Direction']

        $completionComp = New-MetricComparison -ValA (Get-SafeValue $aggA 'AvgCompletionRate') `
            -ValB (Get-SafeValue $aggB 'AvgCompletionRate') -PositiveDirection 'higher'
        Update-DirectionCounts $completionComp['Direction']

        $campaignMetricsDim = @{
            ApprovalRate   = $approvalComp
            RevocationRate = $revocationComp
            AvgResponseHrs = $responseComp
            CompletionRate = $completionComp
        }
    }

    # ========================================
    # 2. Identity Risk Delta
    # ========================================
    $identityRiskDim = $null
    $irA = Get-SafeValue $PeriodA 'IdentityRisk'
    $irB = Get-SafeValue $PeriodB 'IdentityRisk'

    if ($null -ne $irA -or $null -ne $irB) {
        $irSumA = Get-SafeValue $irA 'Summary'
        $irSumB = Get-SafeValue $irB 'Summary'

        $highComp = New-MetricComparison -ValA (Get-SafeValue $irSumA 'High') `
            -ValB (Get-SafeValue $irSumB 'High') -PositiveDirection 'lower' -Threshold 0
        Update-DirectionCounts $highComp['Direction']

        $avgRiskComp = New-MetricComparison -ValA (Get-SafeValue $irSumA 'AvgRiskScore') `
            -ValB (Get-SafeValue $irSumB 'AvgRiskScore') -PositiveDirection 'lower'
        Update-DirectionCounts $avgRiskComp['Direction']

        # Identify new High-risk identities in B not in A
        $newHighRisk = @()
        $identsA = Get-SafeValue $irA 'Identities'
        $identsB = Get-SafeValue $irB 'Identities'
        if ($null -ne $identsA -and $null -ne $identsB) {
            $highA = @{}
            foreach ($id in @($identsA)) {
                $tier = Get-SafeValue $id 'RiskTier'
                if ($tier -eq 'High') {
                    $idId = Get-SafeValue $id 'IdentityId'
                    if (-not [string]::IsNullOrWhiteSpace($idId)) { $highA[$idId] = $true }
                }
            }
            foreach ($id in @($identsB)) {
                $tier = Get-SafeValue $id 'RiskTier'
                if ($tier -eq 'High') {
                    $idId = Get-SafeValue $id 'IdentityId'
                    $idName = Get-SafeValue $id 'IdentityName'
                    if (-not [string]::IsNullOrWhiteSpace($idId) -and -not $highA.ContainsKey($idId)) {
                        $newHighRisk += if (-not [string]::IsNullOrWhiteSpace($idName)) { $idName } else { $idId }
                    }
                }
            }
        }

        $identityRiskDim = @{
            HighCount    = $highComp
            AvgRiskScore = $avgRiskComp
            NewHighRisk  = $newHighRisk
        }
    }

    # ========================================
    # 3. Source Governance Delta
    # ========================================
    $sourceGovernanceDim = $null
    $sgA = Get-SafeValue $PeriodA 'SourceGovernance'
    $sgB = Get-SafeValue $PeriodB 'SourceGovernance'

    if ($null -ne $sgA -or $null -ne $sgB) {
        $sgSumA = Get-SafeValue $sgA 'Summary'
        $sgSumB = Get-SafeValue $sgB 'Summary'

        $coverageComp = New-MetricComparison -ValA (Get-SafeValue $sgSumA 'OverallCoveragePct') `
            -ValB (Get-SafeValue $sgSumB 'OverallCoveragePct') -PositiveDirection 'higher'
        Update-DirectionCounts $coverageComp['Direction']

        # Per-source grade changes
        $gradeChanges = @()
        $sourcesA = Get-SafeValue $sgA 'Sources'
        $sourcesB = Get-SafeValue $sgB 'Sources'
        if ($null -ne $sourcesA -and $null -ne $sourcesB) {
            $gradeOrder = @{ 'A' = 5; 'B' = 4; 'C' = 3; 'D' = 2; 'F' = 1 }
            $srcMapA = @{}
            foreach ($s in @($sourcesA)) {
                $sName = Get-SafeValue $s 'SourceName'
                $sId = Get-SafeValue $s 'SourceId'
                $key = if (-not [string]::IsNullOrWhiteSpace($sId)) { $sId } else { $sName }
                if (-not [string]::IsNullOrWhiteSpace($key)) { $srcMapA[$key] = $s }
            }
            foreach ($sB in @($sourcesB)) {
                $sName = Get-SafeValue $sB 'SourceName'
                $sId = Get-SafeValue $sB 'SourceId'
                $key = if (-not [string]::IsNullOrWhiteSpace($sId)) { $sId } else { $sName }
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if ($srcMapA.ContainsKey($key)) {
                    $sA = $srcMapA[$key]
                    $gradeA = [string](Get-SafeValue $sA 'GovernanceGrade')
                    $gradeB = [string](Get-SafeValue $sB 'GovernanceGrade')
                    if ($gradeA -ne $gradeB) {
                        $ordA = if ($gradeOrder.ContainsKey($gradeA)) { $gradeOrder[$gradeA] } else { 0 }
                        $ordB = if ($gradeOrder.ContainsKey($gradeB)) { $gradeOrder[$gradeB] } else { 0 }
                        $dir = if ($ordB -gt $ordA) { 'Improved' } elseif ($ordB -lt $ordA) { 'Degraded' } else { 'Stable' }
                        $displayName = if (-not [string]::IsNullOrWhiteSpace($sName)) { $sName } else { $key }
                        $gradeChanges += @{
                            Source     = $displayName
                            GradeA     = $gradeA
                            GradeB     = $gradeB
                            Direction  = $dir
                        }
                    }
                }
            }
        }

        $sourceGovernanceDim = @{
            OverallCoverage = $coverageComp
            GradeChanges    = $gradeChanges
        }
    }

    # ========================================
    # 4. Reviewer Reputation Delta
    # ========================================
    $reviewerReputationDim = $null
    $rrA = Get-SafeValue $PeriodA 'ReviewerReputation'
    $rrB = Get-SafeValue $PeriodB 'ReviewerReputation'

    if ($null -ne $rrA -or $null -ne $rrB) {
        # Compute average reputation score from Reviewers array
        function Get-AvgReputationScore {
            param([object]$RepData)
            if ($null -eq $RepData) { return $null }
            $reviewers = Get-SafeValue $RepData 'Reviewers'
            if ($null -eq $reviewers -or @($reviewers).Count -eq 0) { return $null }
            $total = 0.0
            $count = 0
            foreach ($r in @($reviewers)) {
                $score = Get-SafeValue $r 'ReputationScore'
                if ($null -ne $score) { $total += [double]$score; $count++ }
            }
            if ($count -eq 0) { return $null }
            return [Math]::Round($total / $count, 1)
        }

        $avgScoreComp = New-MetricComparison -ValA (Get-AvgReputationScore $rrA) `
            -ValB (Get-AvgReputationScore $rrB) -PositiveDirection 'higher'
        Update-DirectionCounts $avgScoreComp['Direction']

        # New At Risk reviewers in B not in A
        $newAtRisk = @()
        $tierImprovements = @()
        $reviewersA = Get-SafeValue $rrA 'Reviewers'
        $reviewersB = Get-SafeValue $rrB 'Reviewers'
        if ($null -ne $reviewersA -and $null -ne $reviewersB) {
            $tierMapA = @{}
            foreach ($r in @($reviewersA)) {
                $rName = Get-SafeValue $r 'ReviewerName'
                $rTier = Get-SafeValue $r 'ReputationTier'
                if (-not [string]::IsNullOrWhiteSpace($rName)) { $tierMapA[$rName] = $rTier }
            }
            foreach ($r in @($reviewersB)) {
                $rName = Get-SafeValue $r 'ReviewerName'
                $rTierB = Get-SafeValue $r 'ReputationTier'
                if ([string]::IsNullOrWhiteSpace($rName)) { continue }
                $rTierA = if ($tierMapA.ContainsKey($rName)) { $tierMapA[$rName] } else { $null }

                if ($rTierB -eq 'At Risk' -and $rTierA -ne 'At Risk') {
                    $newAtRisk += $rName
                }
                # Detect tier improvements
                if ($null -ne $rTierA -and $rTierA -ne $rTierB) {
                    $tierOrder = @{ 'At Risk' = 1; 'Needs Attention' = 2; 'Good' = 3; 'Excellent' = 4 }
                    $ordA = if ($tierOrder.ContainsKey($rTierA)) { $tierOrder[$rTierA] } else { 0 }
                    $ordB = if ($tierOrder.ContainsKey($rTierB)) { $tierOrder[$rTierB] } else { 0 }
                    if ($ordB -gt $ordA) {
                        $tierImprovements += "${rName}: ${rTierA} -> ${rTierB}"
                    }
                }
            }
        }

        $reviewerReputationDim = @{
            AvgScore         = $avgScoreComp
            NewAtRisk        = $newAtRisk
            TierImprovements = $tierImprovements
        }
    }

    # ========================================
    # 5. Stale Access Delta
    # ========================================
    $staleAccessDim = $null
    $saA = Get-SafeValue $PeriodA 'StaleAccess'
    $saB = Get-SafeValue $PeriodB 'StaleAccess'

    if ($null -ne $saA -or $null -ne $saB) {
        $saSumA = Get-SafeValue $saA 'Summary'
        $saSumB = Get-SafeValue $saB 'Summary'

        $totalStaleComp = New-MetricComparison -ValA (Get-SafeValue $saSumA 'TotalStaleItems') `
            -ValB (Get-SafeValue $saSumB 'TotalStaleItems') -PositiveDirection 'lower' -Threshold 0
        Update-DirectionCounts $totalStaleComp['Direction']

        $neverReviewedComp = New-MetricComparison -ValA (Get-SafeValue $saSumA 'NeverReviewed') `
            -ValB (Get-SafeValue $saSumB 'NeverReviewed') -PositiveDirection 'lower' -Threshold 0
        Update-DirectionCounts $neverReviewedComp['Direction']

        $staleAccessDim = @{
            TotalStale    = $totalStaleComp
            NeverReviewed = $neverReviewedComp
        }
    }

    # ========================================
    # 6. Remediation Delta
    # ========================================
    $remediationDim = $null
    $remA = Get-SafeValue $PeriodA 'RemediationStatus'
    $remB = Get-SafeValue $PeriodB 'RemediationStatus'

    if ($null -ne $remA -or $null -ne $remB) {
        # RemediationStatus output: @{ Success; Data = @{ Items; Summary } }
        function Get-RemediationSummary {
            param([object]$RemOutput)
            if ($null -eq $RemOutput) { return $null }
            if ($RemOutput -is [hashtable] -and $RemOutput.ContainsKey('Data') -and $null -ne $RemOutput['Data']) {
                $data = $RemOutput['Data']
                if ($data -is [hashtable] -and $data.ContainsKey('Summary')) { return $data['Summary'] }
            }
            if ($RemOutput -is [hashtable] -and $RemOutput.ContainsKey('Summary')) { return $RemOutput['Summary'] }
            return $null
        }

        $remSumA = Get-RemediationSummary $remA
        $remSumB = Get-RemediationSummary $remB

        # SLA compliance = (Provisioned / Total) * 100
        function Get-SlaComplianceRate {
            param([object]$Summary)
            if ($null -eq $Summary) { return $null }
            $total = Get-SafeValue $Summary 'Total'
            $provisioned = Get-SafeValue $Summary 'Provisioned'
            if ($null -eq $total -or [int]$total -eq 0) { return $null }
            return [Math]::Round(([double]$provisioned / [double]$total) * 100, 1)
        }

        $slaComp = New-MetricComparison -ValA (Get-SlaComplianceRate $remSumA) `
            -ValB (Get-SlaComplianceRate $remSumB) -PositiveDirection 'higher'
        Update-DirectionCounts $slaComp['Direction']

        $avgDaysComp = New-MetricComparison -ValA (Get-SafeValue $remSumA 'AvgDaysToRemediate') `
            -ValB (Get-SafeValue $remSumB 'AvgDaysToRemediate') -PositiveDirection 'lower'
        Update-DirectionCounts $avgDaysComp['Direction']

        $remediationDim = @{
            SlaCompliance      = $slaComp
            AvgDaysToRemediate = $avgDaysComp
        }
    }

    # ========================================
    # Overall Direction (majority vote)
    # ========================================
    $overallDirection = 'Stable'
    if ($improvedCount -gt $degradedCount -and $improvedCount -gt $stableCount) {
        $overallDirection = 'Improved'
    } elseif ($degradedCount -gt $improvedCount -and $degradedCount -gt $stableCount) {
        $overallDirection = 'Degraded'
    }

    # Handle all-N/A case
    $totalDirectional = $improvedCount + $degradedCount + $stableCount
    if ($totalDirectional -eq 0) {
        $overallDirection = 'N/A'
    }

    $dimensions = @{}
    if ($null -ne $campaignMetricsDim)   { $dimensions['CampaignMetrics']    = $campaignMetricsDim }
    if ($null -ne $identityRiskDim)      { $dimensions['IdentityRisk']       = $identityRiskDim }
    if ($null -ne $sourceGovernanceDim)  { $dimensions['SourceGovernance']   = $sourceGovernanceDim }
    if ($null -ne $reviewerReputationDim){ $dimensions['ReviewerReputation'] = $reviewerReputationDim }
    if ($null -ne $staleAccessDim)       { $dimensions['StaleAccess']        = $staleAccessDim }
    if ($null -ne $remediationDim)       { $dimensions['Remediation']        = $remediationDim }

    Write-SPLog -Message "Compare-SPAuditPeriods: completed -- Improved=$improvedCount, Degraded=$degradedCount, Stable=$stableCount, Overall=$overallDirection" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Compare-SPAuditPeriods' `
        -CorrelationID $CorrelationID

    return @{
        PeriodA          = @{
            Label     = Get-SafeValue $PeriodA 'Label'
            DateRange = Get-SafeValue $PeriodA 'DateRange'
        }
        PeriodB          = @{
            Label     = Get-SafeValue $PeriodB 'Label'
            DateRange = Get-SafeValue $PeriodB 'DateRange'
        }
        Dimensions       = $dimensions
        OverallDirection = $overallDirection
        Summary          = @{
            Improved = $improvedCount
            Degraded = $degradedCount
            Stable   = $stableCount
        }
    }
}

#endregion

#region P14-02: Remediation Priority Queue

function Get-SPRemediationPriority {
    <#
    .SYNOPSIS
        Produces a ranked queue of actionable remediation items across all governance dimensions.
    .DESCRIPTION
        Synthesizes identity risk, stale access, policy violations, remediation status,
        and reviewer reputation into a single ranked list of specific, actionable
        remediation items. Each item has a priority score, severity, and rationale.

        Action types:
        - RevokeAccess: Identity with high risk + stale/privileged entitlement
        - CompletePendingRemediation: Revocation decided but not yet provisioned
        - ReviewStaleEntitlement: Entitlement never reviewed or review expired
        - AddressReviewerPerformance: Reviewer at At Risk tier
        - RemediatePolicyViolation: Policy in FAIL state

        Items are deduplicated by identity+entitlement pair (highest priority kept)
        and sorted by priority descending.
    .PARAMETER IdentityRisk
        Hashtable output from Measure-SPIdentityRisk.
    .PARAMETER StaleAccess
        Hashtable output from Get-SPStaleAccess.
    .PARAMETER PolicyCompliance
        Hashtable output from Test-SPGovernancePolicy.
    .PARAMETER RemediationStatus
        Hashtable output from Get-SPRemediationStatus.
    .PARAMETER ReviewerReputation
        Hashtable output from Measure-SPReviewerReputation.
    .PARAMETER MaxItems
        Maximum number of items to return. Default 50.
    .PARAMETER CorrelationID
        Correlation ID for logging.
    .OUTPUTS
        [hashtable] @{ Items = @(...); Summary = @{...} }
    .EXAMPLE
        $queue = Get-SPRemediationPriority -IdentityRisk $risk -StaleAccess $stale -MaxItems 20
        $queue.Items | Where-Object { $_.Severity -eq 'Critical' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [hashtable]$IdentityRisk,

        [Parameter()]
        [hashtable]$StaleAccess,

        [Parameter()]
        [hashtable]$PolicyCompliance,

        [Parameter()]
        [hashtable]$RemediationStatus,

        [Parameter()]
        [hashtable]$ReviewerReputation,

        [Parameter()]
        [int]$MaxItems = 50,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    Write-SPLog -Message "Get-SPRemediationPriority: starting priority queue generation, MaxItems=$MaxItems" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPRemediationPriority' `
        -CorrelationID $CorrelationID

    $candidates = [System.Collections.Generic.List[hashtable]]::new()
    $dedupMap = @{}

    function _SafeVal ($obj, [string]$key, $default = $null) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [hashtable]) {
            if ($obj.ContainsKey($key) -and $null -ne $obj[$key]) { return $obj[$key] }
            return $default
        }
        if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties[$key]) {
            $v = $obj.PSObject.Properties[$key].Value
            if ($null -ne $v) { return $v }
        }
        return $default
    }

    function _Severity ([int]$priority) {
        if ($priority -ge 80) { return 'Critical' }
        if ($priority -ge 60) { return 'High' }
        if ($priority -ge 40) { return 'Medium' }
        return 'Low'
    }

    # Action Type 1: RevokeAccess (from IdentityRisk + StaleAccess)
    if ($null -ne $IdentityRisk -and $IdentityRisk.ContainsKey('Identities')) {
        foreach ($identity in @($IdentityRisk['Identities'])) {
            if ($null -eq $identity) { continue }
            $riskScore    = [int](_SafeVal $identity 'RiskScore' 0)
            $riskTier     = [string](_SafeVal $identity 'RiskTier' 'Low')
            $identityId   = [string](_SafeVal $identity 'IdentityId' '')
            $identityName = [string](_SafeVal $identity 'IdentityName' '')
            if ($riskTier -eq 'Low') { continue }
            $privCount  = [int](_SafeVal $identity 'PrivilegedAccessCount' 0)
            $staleCount = [int](_SafeVal $identity 'StaleAccessCount' 0)
            if ($privCount -gt 0 -or $staleCount -gt 0) {
                $isPrivileged = ($privCount -gt 0)
                $isStale = ($staleCount -gt 0)
                $priority = $riskScore + $(if ($isPrivileged) { 20 } else { 0 }) + $(if ($isStale) { 15 } else { 0 })
                $priority = [Math]::Min(100, $priority)
                $rationale = [System.Collections.Generic.List[string]]::new()
                $rationale.Add("Identity risk score $riskScore ($riskTier tier)")
                if ($isPrivileged) { $rationale.Add('Privileged entitlement') }
                if ($isStale) { $rationale.Add('Stale access detected') }
                $candidates.Add(@{
                    ActionType      = 'RevokeAccess'
                    Priority        = $priority
                    Severity        = (_Severity $priority)
                    Summary         = "Revoke access for $identityName (risk $riskScore)"
                    IdentityName    = $identityName
                    IdentityId      = $identityId
                    SourceName      = ''
                    EntitlementName = 'Privileged/Stale Access'
                    Rationale       = @($rationale)
                    EstimatedEffort = $(if ($isPrivileged) { 'Medium' } else { 'Low' })
                })
            }
        }
    }

    # Action Type 2: CompletePendingRemediation (from RemediationStatus)
    if ($null -ne $RemediationStatus) {
        $remData = $null
        if ($RemediationStatus.ContainsKey('Data') -and $null -ne $RemediationStatus['Data']) {
            $remData = $RemediationStatus['Data']
        } elseif ($RemediationStatus.ContainsKey('Items')) {
            $remData = $RemediationStatus
        }
        if ($null -ne $remData -and $remData.ContainsKey('Items')) {
            foreach ($remItem in @($remData['Items'])) {
                if ($null -eq $remItem) { continue }
                $status = [string](_SafeVal $remItem 'Status' '')
                if ($status -ne 'Pending' -and $status -ne 'Overdue') { continue }
                $isOverdue = ($status -eq 'Overdue')
                $daysOverdue = 0
                $decisionDateStr = [string](_SafeVal $remItem 'DecisionDate' '')
                if ($isOverdue -and -not [string]::IsNullOrWhiteSpace($decisionDateStr)) {
                    try {
                        $decDt = [datetime]::Parse($decisionDateStr,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                        $daysOverdue = [int]((Get-Date) - $decDt).TotalDays
                    } catch { }
                }
                $priority = 80 + $(if ($isOverdue) { 20 } else { 0 }) + [Math]::Min($daysOverdue * 2, 20)
                $priority = [Math]::Min(100, $priority)
                $identityName    = [string](_SafeVal $remItem 'IdentityName' 'Unknown')
                $identityId      = [string](_SafeVal $remItem 'IdentityId' '')
                $entitlementName = [string](_SafeVal $remItem 'EntitlementName' '')
                $sourceName      = [string](_SafeVal $remItem 'SourceName' '')
                $rationale = [System.Collections.Generic.List[string]]::new()
                $rationale.Add("Revocation decided but not provisioned ($status)")
                if ($isOverdue) { $rationale.Add("$daysOverdue days overdue") }
                $candidates.Add(@{
                    ActionType      = 'CompletePendingRemediation'
                    Priority        = $priority
                    Severity        = (_Severity $priority)
                    Summary         = "Complete pending remediation: $entitlementName for $identityName"
                    IdentityName    = $identityName
                    IdentityId      = $identityId
                    SourceName      = $sourceName
                    EntitlementName = $entitlementName
                    Rationale       = @($rationale)
                    EstimatedEffort = 'Low'
                })
            }
        }
    }

    # Action Type 3: ReviewStaleEntitlement (from StaleAccess)
    if ($null -ne $StaleAccess -and $StaleAccess.ContainsKey('StaleItems')) {
        foreach ($staleItem in @($StaleAccess['StaleItems'])) {
            if ($null -eq $staleItem) { continue }
            $isPrivileged    = [bool](_SafeVal $staleItem 'Privileged' $false)
            $classification  = [string](_SafeVal $staleItem 'Classification' '')
            $isNeverReviewed = ($classification -eq 'NeverReviewed')
            $priority = 50 + $(if ($isPrivileged) { 25 } else { 0 }) + $(if ($isNeverReviewed) { 15 } else { 0 })
            $priority = [Math]::Min(100, $priority)
            $entitlementName = [string](_SafeVal $staleItem 'EntitlementName' '')
            $sourceName      = [string](_SafeVal $staleItem 'SourceName' '')
            $daysSince       = _SafeVal $staleItem 'DaysSinceReview' $null
            $rationale = [System.Collections.Generic.List[string]]::new()
            if ($isNeverReviewed) {
                $rationale.Add('Entitlement has never been reviewed')
            } else {
                $rationale.Add($(if ($null -ne $daysSince) { "$daysSince days since last review" } else { 'Review expired' }))
            }
            if ($isPrivileged) { $rationale.Add('Privileged entitlement') }
            $candidates.Add(@{
                ActionType      = 'ReviewStaleEntitlement'
                Priority        = $priority
                Severity        = (_Severity $priority)
                Summary         = "Review stale entitlement: $entitlementName on $sourceName"
                IdentityName    = ''
                IdentityId      = ''
                SourceName      = $sourceName
                EntitlementName = $entitlementName
                Rationale       = @($rationale)
                EstimatedEffort = $(if ($isPrivileged) { 'Medium' } else { 'Low' })
            })
        }
    }

    # Action Type 4: AddressReviewerPerformance (from ReviewerReputation)
    if ($null -ne $ReviewerReputation -and $ReviewerReputation.ContainsKey('Reviewers')) {
        foreach ($reviewer in @($ReviewerReputation['Reviewers'])) {
            if ($null -eq $reviewer) { continue }
            $repTier = [string](_SafeVal $reviewer 'ReputationTier' '')
            if ($repTier -ne 'At Risk') { continue }
            $repScore = [int](_SafeVal $reviewer 'ReputationScore' 50)
            $priority = 60 + $(if ($repScore -lt 20) { 20 } else { 0 })
            $priority = [Math]::Min(100, $priority)
            $reviewerName = [string](_SafeVal $reviewer 'ReviewerName' 'Unknown')
            $rationale = [System.Collections.Generic.List[string]]::new()
            $rationale.Add("Reviewer reputation score $repScore (At Risk tier)")
            $rationale.Add('Reviewer needs coaching or reassignment')
            $candidates.Add(@{
                ActionType      = 'AddressReviewerPerformance'
                Priority        = $priority
                Severity        = (_Severity $priority)
                Summary         = "Address reviewer performance: $reviewerName"
                IdentityName    = $reviewerName
                IdentityId      = [string](_SafeVal $reviewer 'ReviewerIdentityId' '')
                SourceName      = ''
                EntitlementName = ''
                Rationale       = @($rationale)
                EstimatedEffort = 'Medium'
            })
        }
    }

    # Action Type 5: RemediatePolicyViolation (from PolicyCompliance)
    if ($null -ne $PolicyCompliance -and $PolicyCompliance.ContainsKey('Policies')) {
        foreach ($policy in @($PolicyCompliance['Policies'])) {
            if ($null -eq $policy) { continue }
            $result = [string](_SafeVal $policy 'Result' '')
            if ($result -ne 'FAIL') { continue }
            $severity    = [string](_SafeVal $policy 'Severity' 'Warning')
            $isCritical  = ($severity -eq 'Critical')
            $violations  = @(_SafeVal $policy 'Violations' @())
            $violationCount = $violations.Count
            $priority = $(if ($isCritical) { 90 } else { 60 }) + [Math]::Min($violationCount, 10)
            $priority = [Math]::Min(100, $priority)
            $policyName = [string](_SafeVal $policy 'Name' 'Unknown Policy')
            $policyId   = [string](_SafeVal $policy 'Id' '')
            $details    = [string](_SafeVal $policy 'Details' '')
            $rationale = [System.Collections.Generic.List[string]]::new()
            $rationale.Add("Policy $policyId ($policyName) in FAIL state")
            if (-not [string]::IsNullOrWhiteSpace($details)) { $rationale.Add($details) }
            $rationale.Add("Severity: $severity")
            $candidates.Add(@{
                ActionType      = 'RemediatePolicyViolation'
                Priority        = $priority
                Severity        = (_Severity $priority)
                Summary         = "Remediate policy violation: $policyName"
                IdentityName    = ''
                IdentityId      = ''
                SourceName      = ''
                EntitlementName = $policyId
                Rationale       = @($rationale)
                EstimatedEffort = $(if ($isCritical) { 'High' } else { 'Medium' })
            })
        }
    }

    # Deduplication: same identity + entitlement pair keeps highest priority
    $deduped = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in $candidates) {
        $idVal  = $item['IdentityId']
        $entVal = $item['EntitlementName']
        if ([string]::IsNullOrWhiteSpace($idVal) -or [string]::IsNullOrWhiteSpace($entVal)) {
            $deduped.Add($item)
            continue
        }
        $dedupKey = "$idVal|$entVal"
        if ($dedupMap.ContainsKey($dedupKey)) {
            $existingIdx = $dedupMap[$dedupKey]
            if ($item['Priority'] -gt $deduped[$existingIdx]['Priority']) {
                $deduped[$existingIdx] = $item
            }
        } else {
            $dedupMap[$dedupKey] = $deduped.Count
            $deduped.Add($item)
        }
    }

    # Sort by priority descending and apply MaxItems
    $sorted = @($deduped | Sort-Object { $_['Priority'] } -Descending)
    if ($sorted.Count -gt $MaxItems) {
        $sorted = @($sorted[0..($MaxItems - 1)])
    }

    # Assign ranks and build summary
    $rank = 0
    $criticalCount = 0; $highCount = 0; $mediumCount = 0; $lowCount = 0
    $actionBreakdown = @{
        RevokeAccess               = 0
        CompletePendingRemediation = 0
        ReviewStaleEntitlement     = 0
        AddressReviewerPerformance = 0
        RemediatePolicyViolation   = 0
    }
    foreach ($item in $sorted) {
        $rank++
        $item['Rank'] = $rank
        switch ($item['Severity']) {
            'Critical' { $criticalCount++ }
            'High'     { $highCount++ }
            'Medium'   { $mediumCount++ }
            'Low'      { $lowCount++ }
        }
        $at = $item['ActionType']
        if ($actionBreakdown.ContainsKey($at)) { $actionBreakdown[$at]++ }
    }

    Write-SPLog -Message "Get-SPRemediationPriority: generated $($sorted.Count) items (Critical=$criticalCount, High=$highCount, Medium=$mediumCount, Low=$lowCount)" `
        -Severity INFO -Component 'SP.AuditReport' -Action 'Get-SPRemediationPriority' `
        -CorrelationID $CorrelationID

    return @{
        Items   = $sorted
        Summary = @{
            TotalItems          = $sorted.Count
            CriticalItems       = $criticalCount
            HighItems           = $highCount
            MediumItems         = $mediumCount
            LowItems            = $lowCount
            ActionTypeBreakdown = $actionBreakdown
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Compare-SPCampaigns',
    'Get-SPAuditTrail',
    'Measure-SPCampaignTrends',
    'Measure-SPReviewerReputation',
    'Measure-SPIdentityRisk',
    'Measure-SPSourceGovernance',
    'Measure-SPGovernanceMaturity',
    'Get-SPRemediationPriority',
    'Get-SPIdentityAccessSpread',
    'Compare-SPAuditPeriods'
)
