#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Evidence Trail and Report Generation
.DESCRIPTION
    Provides JSONL audit trail writing and HTML report generation for
    campaign test runs. All reports use embedded CSS with no external
    dependencies for portability.
.NOTES
    Module: SP.Testing / SP.Evidence
    Version: 1.0.0
    Component: Test Orchestration
    Color taxonomy:
        Green  #339933 - PASS / success
        Red    #CC3333 - FAIL / error
        Orange #FF8800 - WARN
        Blue   #336699 - INFO / neutral
        Gray   #777777 - SKIP / footer
#>

$script:ToolkitVersion = '1.0.0'

#region Path Management

function New-SPCampaignEvidencePath {
    <#
    .SYNOPSIS
        Create and return the evidence directory for a given test ID.
    .DESCRIPTION
        Creates {BasePath}/Evidence/{TestId}/ if it does not already exist,
        then returns the full path.
    .PARAMETER TestId
        The test case identifier (e.g., TC-001).
    .PARAMETER BasePath
        Base directory under which the Evidence folder lives.
    .OUTPUTS
        [string] Full path to the evidence directory.
    .EXAMPLE
        $ePath = New-SPCampaignEvidencePath -TestId "TC-001" -BasePath "C:\toolkit"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TestId,

        [Parameter(Mandatory)]
        [string]$BasePath
    )

    try {
        # Sanitise TestId for use as a directory name
        $safeName = $TestId -replace '[\\/:*?"<>|]', '_'
        $evidencePath = Join-Path -Path $BasePath -ChildPath "Evidence" | Join-Path -ChildPath $safeName

        if (-not (Test-Path -Path $evidencePath -PathType Container)) {
            New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null
        }

        return $evidencePath
    }
    catch {
        # Return a best-effort path even on failure
        return Join-Path -Path $BasePath -ChildPath "Evidence\$TestId"
    }
}

#endregion

#region JSONL Evidence Writing

function Write-SPEvidenceEvent {
    <#
    .SYNOPSIS
        Append a single JSONL event line to the audit trail.
    .DESCRIPTION
        Serialises the event to a JSON object on a single line and appends it
        to {EvidencePath}/audit.jsonl. Thread-unsafe for concurrent writes
        (single-threaded orchestrator assumption).
    .PARAMETER EvidencePath
        Directory returned by New-SPCampaignEvidencePath.
    .PARAMETER TestId
        Test case identifier.
    .PARAMETER Step
        Integer step number within the test (1-based).
    .PARAMETER Action
        Short action name (e.g., CreateCampaign, ActivateCampaign).
    .PARAMETER Status
        One of: PASS, FAIL, INFO, SKIP, WARN.
    .PARAMETER Data
        Optional hashtable or PSCustomObject of additional data to embed.
    .PARAMETER Message
        Human-readable description of the event.
    .PARAMETER CorrelationID
        Correlation ID propagated from the suite runner.
    .EXAMPLE
        Write-SPEvidenceEvent -EvidencePath $ep -TestId "TC-001" -Step 1 `
            -Action "CreateCampaign" -Status "PASS" -Message "Campaign created" `
            -CorrelationID $cid
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$TestId,

        [Parameter(Mandatory)]
        [int]$Step,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'INFO', 'SKIP', 'WARN')]
        [string]$Status,

        [Parameter()]
        $Data = $null,

        [Parameter()]
        [string]$Message = '',

        [Parameter()]
        [string]$CorrelationID = ''
    )

    try {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

        # Extract CampaignId from Data if present for top-level field convenience
        $campaignId = ''
        if ($null -ne $Data) {
            if ($Data -is [hashtable] -and $Data.ContainsKey('CampaignId')) {
                $campaignId = $Data.CampaignId
            }
            elseif ($Data.PSObject.Properties.Name -contains 'CampaignId') {
                $campaignId = $Data.CampaignId
            }
        }

        # Build the event object using ordered hashtable for deterministic JSON field order
        $event = [ordered]@{
            Timestamp     = $timestamp
            TestId        = $TestId
            Step          = $Step
            Action        = $Action
            Status        = $Status
            CampaignId    = $campaignId
            Message       = $Message
            CorrelationID = $CorrelationID
            Data          = $Data
        }

        # Serialize to JSON (single line) - PS5.1 ConvertTo-Json default depth 2 is fine for flat data
        $jsonLine = $event | ConvertTo-Json -Depth 5 -Compress

        $auditFile = Join-Path -Path $EvidencePath -ChildPath 'audit.jsonl'

        # Ensure directory exists
        if (-not (Test-Path -Path $EvidencePath -PathType Container)) {
            New-Item -Path $EvidencePath -ItemType Directory -Force | Out-Null
        }

        # Append the JSON line using .NET API for consistent encoding across PS 5.1 and PS 7
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
    }
    catch {
        # Evidence writing must not break the test run
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Failed to write evidence event: $($_.Exception.Message)" `
                -Severity WARN -Component "SP.Evidence" -Action "WriteEvidenceEvent"
        }
    }
}

#endregion

#region HTML Report Generation

function Export-SPCampaignReport {
    <#
    .SYNOPSIS
        Generate an HTML summary report for a single campaign test run.
    .DESCRIPTION
        Reads the audit.jsonl file from EvidencePath, parses each event,
        and generates a professional summary.html with step table, decision
        summary, and embedded CSS.
    .PARAMETER EvidencePath
        Directory containing audit.jsonl (from New-SPCampaignEvidencePath).
    .PARAMETER TestId
        Test case identifier.
    .PARAMETER TestName
        Human-readable test name.
    .PARAMETER TestResult
        Hashtable with keys: Pass ($true/$false), Error (string or null),
        Steps (array), DurationSeconds (number).
    .EXAMPLE
        Export-SPCampaignReport -EvidencePath $ep -TestId "TC-001" `
            -TestName "Source Owner Approve All" -TestResult $result
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$TestId,

        [Parameter(Mandatory)]
        [string]$TestName,

        [Parameter(Mandatory)]
        [hashtable]$TestResult
    )

    try {
        # Read and parse JSONL events
        $events = @()
        $auditFile = Join-Path -Path $EvidencePath -ChildPath 'audit.jsonl'
        if (Test-Path -Path $auditFile -PathType Leaf) {
            $lines = Get-Content -Path $auditFile -Encoding UTF8 -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                $line = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $ev = $line | ConvertFrom-Json -ErrorAction Stop
                    $events += $ev
                }
                catch {
                    # Skip malformed lines
                }
            }
        }

        # Determine overall pass/fail
        $overallPass = $false
        if ($TestResult.ContainsKey('Pass')) {
            $overallPass = [bool]$TestResult.Pass
        }

        $badgeText    = if ($overallPass) { 'PASS' } else { 'FAIL' }
        $badgeColor   = if ($overallPass) { '#339933' } else { '#CC3333' }
        $durationSecs = if ($TestResult.ContainsKey('DurationSeconds')) { [math]::Round([double]$TestResult.DurationSeconds, 1) } else { 0 }
        $errorText    = if ($TestResult.ContainsKey('Error') -and -not [string]::IsNullOrWhiteSpace($TestResult.Error)) { $TestResult.Error } else { '' }
        $correlationId = ''
        if ($events.Count -gt 0 -and $null -ne $events[0].CorrelationID) {
            $correlationId = $events[0].CorrelationID
        }

        # Build step rows from events
        $stepRowsHtml = ''
        $prevTimestamp = $null
        $stepNum = 0
        $approveCount = 0
        $revokeCount  = 0
        $totalDecided = 0

        foreach ($ev in $events) {
            $stepNum++
            $statusColor = switch ($ev.Status) {
                'PASS' { '#339933' }
                'FAIL' { '#CC3333' }
                'WARN' { '#FF8800' }
                'SKIP' { '#777777' }
                default { '#336699' }  # INFO
            }

            # Calculate duration between steps
            $durationCell = ''
            if ($null -ne $prevTimestamp -and $null -ne $ev.Timestamp) {
                try {
                    $curr = [datetime]::Parse($ev.Timestamp)
                    $prev = [datetime]::Parse($prevTimestamp)
                    $diffMs = [math]::Round(($curr - $prev).TotalMilliseconds)
                    $durationCell = "${diffMs}ms"
                }
                catch { $durationCell = '' }
            }
            $prevTimestamp = $ev.Timestamp

            $actionLabel = if ($null -ne $ev.Action) { [System.Net.WebUtility]::HtmlEncode($ev.Action) } else { '' }
            $msgLabel    = if ($null -ne $ev.Message) { [System.Net.WebUtility]::HtmlEncode($ev.Message) } else { '' }

            $stepRowsHtml += @"
            <tr>
                <td style="text-align:center;">$($ev.Step)</td>
                <td>$actionLabel</td>
                <td style="color:$statusColor; font-weight:bold;">$($ev.Status)</td>
                <td>$msgLabel</td>
                <td style="text-align:right; color:#555;">$durationCell</td>
            </tr>
"@

            # Tally decision events for summary
            if ($ev.Action -eq 'BulkDecide' -and $ev.Status -eq 'PASS') {
                if ($null -ne $ev.Data) {
                    try {
                        $dataObj = $ev.Data
                        if ($dataObj.PSObject.Properties.Name -contains 'TotalDecided') {
                            $totalDecided = [int]$dataObj.TotalDecided
                        }
                        if ($dataObj.PSObject.Properties.Name -contains 'ApproveCount') {
                            $approveCount = [int]$dataObj.ApproveCount
                        }
                        if ($dataObj.PSObject.Properties.Name -contains 'RevokeCount') {
                            $revokeCount = [int]$dataObj.RevokeCount
                        }
                    }
                    catch { }
                }
            }
        }

        # Decision summary section (only if decisions were made)
        $decisionSummaryHtml = ''
        if ($totalDecided -gt 0 -or $approveCount -gt 0 -or $revokeCount -gt 0) {
            $decisionSummaryHtml = @"
        <h2 style="color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px;">Decision Summary</h2>
        <table style="width:100%; border-collapse:collapse; margin-bottom:24px;">
            <thead>
                <tr style="background:#34495e; color:#fff;">
                    <th style="padding:10px; text-align:left;">Metric</th>
                    <th style="padding:10px; text-align:right;">Count</th>
                </tr>
            </thead>
            <tbody>
                <tr style="border-bottom:1px solid #ddd;">
                    <td style="padding:10px;">Total Decisions</td>
                    <td style="padding:10px; text-align:right; font-weight:bold;">$totalDecided</td>
                </tr>
                <tr style="background:#f9f9f9; border-bottom:1px solid #ddd;">
                    <td style="padding:10px;">Approved</td>
                    <td style="padding:10px; text-align:right; color:#339933; font-weight:bold;">$approveCount</td>
                </tr>
                <tr style="border-bottom:1px solid #ddd;">
                    <td style="padding:10px;">Revoked</td>
                    <td style="padding:10px; text-align:right; color:#CC3333; font-weight:bold;">$revokeCount</td>
                </tr>
            </tbody>
        </table>
"@
        }

        $errorSectionHtml = ''
        if (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $errorSectionHtml = @"
        <div style="background:#fff0f0; border-left:4px solid #CC3333; padding:12px 16px; margin-bottom:24px; border-radius:4px;">
            <strong style="color:#CC3333;">Test Error:</strong>
            <span style="color:#333;">$([System.Net.WebUtility]::HtmlEncode($errorText))</span>
        </div>
"@
        }

        $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Campaign Test Report: $([System.Net.WebUtility]::HtmlEncode($TestId))</title>
    <style>
        body {
            font-family: -apple-system, 'Segoe UI', system-ui, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f0f2f5;
            color: #333;
        }
        .container {
            max-width: 960px;
            margin: 0 auto;
            background: #fff;
            padding: 30px 36px;
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.12);
        }
        h1 { color: #2c3e50; margin-bottom: 4px; }
        .subtitle { color: #666; font-size: 14px; margin-bottom: 24px; }
        .badge {
            display: inline-block;
            padding: 6px 20px;
            border-radius: 20px;
            color: #fff;
            font-size: 18px;
            font-weight: bold;
            letter-spacing: 1px;
            margin-bottom: 24px;
        }
        .meta-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
            gap: 12px;
            margin-bottom: 28px;
        }
        .meta-card {
            background: #f8f9fa;
            border: 1px solid #dee2e6;
            border-radius: 6px;
            padding: 12px 16px;
        }
        .meta-label { font-size: 11px; text-transform: uppercase; color: #888; margin-bottom: 4px; }
        .meta-value { font-size: 16px; font-weight: 600; color: #333; word-break: break-all; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 24px; }
        th { background: #34495e; color: #fff; padding: 10px 12px; text-align: left; font-size: 13px; }
        td { padding: 9px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
        tr:nth-child(even) td { background: #f9f9f9; }
        tr:hover td { background: #f0f4f8; }
        .footer {
            margin-top: 28px;
            padding-top: 16px;
            border-top: 1px solid #dee2e6;
            color: #888;
            font-size: 11px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Campaign Test Report</h1>
        <div class="subtitle">$([System.Net.WebUtility]::HtmlEncode($TestName))</div>
        <div class="badge" style="background-color:$badgeColor;">$badgeText</div>

        <div class="meta-grid">
            <div class="meta-card">
                <div class="meta-label">Test ID</div>
                <div class="meta-value">$([System.Net.WebUtility]::HtmlEncode($TestId))</div>
            </div>
            <div class="meta-card">
                <div class="meta-label">Duration</div>
                <div class="meta-value">${durationSecs}s</div>
            </div>
            <div class="meta-card">
                <div class="meta-label">Steps Recorded</div>
                <div class="meta-value">$($events.Count)</div>
            </div>
            <div class="meta-card">
                <div class="meta-label">Correlation ID</div>
                <div class="meta-value" style="font-size:11px; word-break:break-all;">$([System.Net.WebUtility]::HtmlEncode($correlationId))</div>
            </div>
        </div>

        $errorSectionHtml

        <h2 style="color:#2c3e50; border-bottom:2px solid #336699; padding-bottom:6px;">Test Steps</h2>
        <table>
            <thead>
                <tr>
                    <th style="width:50px; text-align:center;">#</th>
                    <th>Action</th>
                    <th style="width:80px;">Status</th>
                    <th>Message</th>
                    <th style="width:90px; text-align:right;">Duration</th>
                </tr>
            </thead>
            <tbody>
$stepRowsHtml
            </tbody>
        </table>

        $decisionSummaryHtml

        <div class="footer">
            SailPoint ISC Governance Toolkit v$($script:ToolkitVersion) &nbsp;|&nbsp;
            Generated: $generatedAt
        </div>
    </div>
</body>
</html>
"@

        $reportFile = Join-Path -Path $EvidencePath -ChildPath 'summary.html'
        $html | Set-Content -Path $reportFile -Encoding UTF8

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Campaign report written: $reportFile" `
                -Severity INFO -Component "SP.Evidence" -Action "ExportCampaignReport"
        }
    }
    catch {
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Failed to export campaign report for $TestId : $($_.Exception.Message)" `
                -Severity ERROR -Component "SP.Evidence" -Action "ExportCampaignReport"
        }
    }
}

function Export-SPSuiteReport {
    <#
    .SYNOPSIS
        Generate an HTML executive summary report for a full test suite run.
    .DESCRIPTION
        Creates Reports/GovernanceRun_{timestamp}.html with executive summary
        counts, per-test result rows with links to individual campaign reports,
        and a failed-tests detail section. Uses embedded CSS only.
    .PARAMETER SuiteResult
        Hashtable from Invoke-SPTestSuite: {Results; PassCount; FailCount;
        SkipCount; DurationSeconds; TenantUrl; Environment; CorrelationID}.
    .PARAMETER OutputPath
        Directory in which to write the suite report HTML file.
    .PARAMETER RunTimestamp
        String timestamp used in the filename (e.g., "20260218-143022").
    .EXAMPLE
        Export-SPSuiteReport -SuiteResult $suite -OutputPath "C:\toolkit\Reports" -RunTimestamp "20260218-143022"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$SuiteResult,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$RunTimestamp
    )

    try {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        $results = if ($SuiteResult.ContainsKey('Results') -and $null -ne $SuiteResult.Results) { @($SuiteResult.Results) } else { @() }
        $passCount = if ($SuiteResult.ContainsKey('PassCount')) { [int]$SuiteResult.PassCount } else { 0 }
        $failCount = if ($SuiteResult.ContainsKey('FailCount')) { [int]$SuiteResult.FailCount } else { 0 }
        $skipCount = if ($SuiteResult.ContainsKey('SkipCount')) { [int]$SuiteResult.SkipCount } else { 0 }
        $totalDuration = if ($SuiteResult.ContainsKey('DurationSeconds')) { [math]::Round([double]$SuiteResult.DurationSeconds, 1) } else { 0 }
        $tenantUrl     = if ($SuiteResult.ContainsKey('TenantUrl'))    { $SuiteResult.TenantUrl }    else { 'N/A' }
        $environment   = if ($SuiteResult.ContainsKey('Environment'))  { $SuiteResult.Environment }  else { 'N/A' }
        $correlationId = if ($SuiteResult.ContainsKey('CorrelationID')) { $SuiteResult.CorrelationID } else { 'N/A' }

        $totalTests  = $passCount + $failCount + $skipCount
        $passRate    = if ($totalTests -gt 0) { [math]::Round(($passCount / $totalTests) * 100, 1) } else { 0 }
        $overallPass = ($failCount -eq 0)
        $suiteBadge  = if ($overallPass) { 'PASS' } else { 'FAIL' }
        $suiteColor  = if ($overallPass) { '#339933' } else { '#CC3333' }

        # Per-test rows
        $testRowsHtml = ''
        $failDetailHtml = ''

        foreach ($r in $results) {
            $testId    = if ($r.ContainsKey('TestId'))   { $r.TestId }   else { 'N/A' }
            $testName  = if ($r.ContainsKey('TestName')) { $r.TestName } else { 'N/A' }
            $testType  = if ($r.ContainsKey('CampaignType')) { $r.CampaignType } else { '' }
            $testDur   = if ($r.ContainsKey('DurationSeconds')) { [math]::Round([double]$r.DurationSeconds, 1) } else { 0 }
            $testPass  = if ($r.ContainsKey('Pass'))     { [bool]$r.Pass } else { $false }
            $testSkip  = if ($r.ContainsKey('Skipped'))  { [bool]$r.Skipped } else { $false }
            $testError = if ($r.ContainsKey('Error') -and -not [string]::IsNullOrWhiteSpace($r.Error)) { $r.Error } else { '' }

            $statusText  = if ($testSkip) { 'SKIP' } elseif ($testPass) { 'PASS' } else { 'FAIL' }
            $statusColor = switch ($statusText) {
                'PASS' { '#339933' }
                'FAIL' { '#CC3333' }
                default { '#777777' }
            }

            # Relative link to per-campaign summary.html
            $summaryLink = "..\\Evidence\\$([System.Net.WebUtility]::HtmlEncode($testId))\\summary.html"

            $testRowsHtml += @"
            <tr>
                <td style="font-weight:600;">$([System.Net.WebUtility]::HtmlEncode($testId))</td>
                <td><a href="$summaryLink" style="color:#336699;">$([System.Net.WebUtility]::HtmlEncode($testName))</a></td>
                <td style="color:#666;">$([System.Net.WebUtility]::HtmlEncode($testType))</td>
                <td style="text-align:right;">${testDur}s</td>
                <td style="text-align:center;">
                    <span style="display:inline-block; padding:3px 12px; border-radius:12px; background:$statusColor; color:#fff; font-weight:bold; font-size:12px;">$statusText</span>
                </td>
            </tr>
"@

            if (-not $testPass -and -not $testSkip) {
                # Find the first failed step
                $failedStep = ''
                if ($r.ContainsKey('Steps') -and $null -ne $r.Steps) {
                    foreach ($step in $r.Steps) {
                        if ($step.ContainsKey('Status') -and $step.Status -eq 'FAIL') {
                            $failedStep = "Step $($step.Step): $($step.Action) - $($step.Message)"
                            break
                        }
                    }
                }
                if ([string]::IsNullOrWhiteSpace($failedStep) -and -not [string]::IsNullOrWhiteSpace($testError)) {
                    $failedStep = $testError
                }

                $failDetailHtml += @"
                <tr>
                    <td style="font-weight:600; color:#CC3333;">$([System.Net.WebUtility]::HtmlEncode($testId))</td>
                    <td>$([System.Net.WebUtility]::HtmlEncode($testName))</td>
                    <td>$([System.Net.WebUtility]::HtmlEncode($failedStep))</td>
                </tr>
"@
            }
        }

        $failedDetailSection = ''
        if (-not [string]::IsNullOrWhiteSpace($failDetailHtml)) {
            $failedDetailSection = @"
        <h2 style="color:#CC3333; border-bottom:2px solid #CC3333; padding-bottom:6px;">Failed Tests Detail</h2>
        <table>
            <thead>
                <tr>
                    <th>Test ID</th>
                    <th>Test Name</th>
                    <th>Failure Reason</th>
                </tr>
            </thead>
            <tbody>
$failDetailHtml
            </tbody>
        </table>
"@
        }

        $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SailPoint Governance Suite Report - $([System.Net.WebUtility]::HtmlEncode($RunTimestamp))</title>
    <style>
        body {
            font-family: -apple-system, 'Segoe UI', system-ui, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f0f2f5;
            color: #333;
        }
        .container {
            max-width: 1100px;
            margin: 0 auto;
            background: #fff;
            padding: 32px 40px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.12);
        }
        h1 { color: #2c3e50; margin-bottom: 4px; font-size: 26px; }
        h2 { color: #2c3e50; border-bottom: 2px solid #336699; padding-bottom: 6px; margin-top: 32px; }
        .subtitle { color: #666; font-size: 13px; margin-bottom: 28px; }
        .badge {
            display: inline-block;
            padding: 8px 28px;
            border-radius: 24px;
            color: #fff;
            font-size: 20px;
            font-weight: bold;
            letter-spacing: 2px;
            margin-bottom: 28px;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
            gap: 14px;
            margin-bottom: 32px;
        }
        .summary-card {
            border-radius: 8px;
            padding: 16px 12px;
            text-align: center;
            color: #fff;
        }
        .card-total   { background: #336699; }
        .card-pass    { background: #339933; }
        .card-fail    { background: #CC3333; }
        .card-skip    { background: #777777; }
        .card-rate    { background: #FF8800; }
        .card-dur     { background: #663399; }
        .card-number  { font-size: 32px; font-weight: 700; line-height: 1; }
        .card-label   { font-size: 12px; margin-top: 6px; opacity: 0.9; }
        .env-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 12px;
            margin-bottom: 28px;
        }
        .env-card {
            background: #f8f9fa;
            border: 1px solid #dee2e6;
            border-radius: 6px;
            padding: 10px 14px;
        }
        .env-label { font-size: 11px; text-transform: uppercase; color: #888; margin-bottom: 3px; }
        .env-value { font-size: 13px; font-weight: 600; word-break: break-all; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 24px; font-size: 13px; }
        th { background: #34495e; color: #fff; padding: 10px 12px; text-align: left; }
        td { padding: 9px 12px; border-bottom: 1px solid #eee; }
        tr:nth-child(even) td { background: #f9f9f9; }
        tr:hover td { background: #f0f4f8; }
        a { text-decoration: none; }
        a:hover { text-decoration: underline; }
        .footer {
            margin-top: 32px;
            padding-top: 16px;
            border-top: 1px solid #dee2e6;
            color: #888;
            font-size: 11px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>SailPoint ISC Governance Suite Report</h1>
        <div class="subtitle">Run: $([System.Net.WebUtility]::HtmlEncode($RunTimestamp)) &nbsp;|&nbsp; Generated: $generatedAt</div>
        <div class="badge" style="background-color:$suiteColor;">$suiteBadge</div>

        <div class="summary-grid">
            <div class="summary-card card-total">
                <div class="card-number">$totalTests</div>
                <div class="card-label">Total Tests</div>
            </div>
            <div class="summary-card card-pass">
                <div class="card-number">$passCount</div>
                <div class="card-label">Passed</div>
            </div>
            <div class="summary-card card-fail">
                <div class="card-number">$failCount</div>
                <div class="card-label">Failed</div>
            </div>
            <div class="summary-card card-skip">
                <div class="card-number">$skipCount</div>
                <div class="card-label">Skipped</div>
            </div>
            <div class="summary-card card-rate">
                <div class="card-number">$passRate%</div>
                <div class="card-label">Pass Rate</div>
            </div>
            <div class="summary-card card-dur">
                <div class="card-number">${totalDuration}s</div>
                <div class="card-label">Duration</div>
            </div>
        </div>

        <h2>Environment</h2>
        <div class="env-grid">
            <div class="env-card">
                <div class="env-label">Tenant URL</div>
                <div class="env-value">$([System.Net.WebUtility]::HtmlEncode($tenantUrl))</div>
            </div>
            <div class="env-card">
                <div class="env-label">Environment</div>
                <div class="env-value">$([System.Net.WebUtility]::HtmlEncode($environment))</div>
            </div>
            <div class="env-card">
                <div class="env-label">Correlation ID</div>
                <div class="env-value" style="font-size:11px;">$([System.Net.WebUtility]::HtmlEncode($correlationId))</div>
            </div>
            <div class="env-card">
                <div class="env-label">Toolkit Version</div>
                <div class="env-value">$($script:ToolkitVersion)</div>
            </div>
        </div>

        <h2>Test Results</h2>
        <table>
            <thead>
                <tr>
                    <th style="width:90px;">Test ID</th>
                    <th>Test Name</th>
                    <th style="width:150px;">Type</th>
                    <th style="width:80px; text-align:right;">Duration</th>
                    <th style="width:80px; text-align:center;">Status</th>
                </tr>
            </thead>
            <tbody>
$testRowsHtml
            </tbody>
        </table>

        $failedDetailSection

        <div class="footer">
            SailPoint ISC Governance Toolkit v$($script:ToolkitVersion) &nbsp;|&nbsp;
            Correlation ID: $([System.Net.WebUtility]::HtmlEncode($correlationId))
        </div>
    </div>
</body>
</html>
"@

        $reportFileName = "GovernanceRun_${RunTimestamp}.html"
        $reportFile = Join-Path -Path $OutputPath -ChildPath $reportFileName
        $html | Set-Content -Path $reportFile -Encoding UTF8

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Suite report written: $reportFile" `
                -Severity INFO -Component "SP.Evidence" -Action "ExportSuiteReport"
        }
    }
    catch {
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Failed to export suite report: $($_.Exception.Message)" `
                -Severity ERROR -Component "SP.Evidence" -Action "ExportSuiteReport"
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-SPCampaignEvidencePath',
    'Write-SPEvidenceEvent',
    'Export-SPCampaignReport',
    'Export-SPSuiteReport'
)
