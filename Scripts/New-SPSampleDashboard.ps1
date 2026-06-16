#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a governance trend dashboard with synthetic data for demonstration
    and end-to-end pipeline validation.
.DESCRIPTION
    Creates realistic governance metrics and campaign trend JSONL data, then runs
    the full dashboard pipeline: Get-SPGovernanceDashboardData -> Compare-SPGovernancePeriods
    -> Export-SPGovernanceDashboardHtml. Produces a self-contained HTML file that
    shows exactly what leadership would see.

    No ISC tenant or mock server required. All data is synthetic but realistic:
    - 30 days of governance metrics (maturity trending up, stale access declining)
    - 3 campaigns with per-reviewer decision data, scope changes, timing
    - A rubber-stamp spike in week 3 to trigger an alert
    - Period-over-period comparison (current month vs prior month)

    Use this to:
    - Validate the dashboard pipeline end-to-end
    - Demo the governance dashboard to stakeholders
    - Visually inspect KPI cards, sparklines, alerts, and comparison table
.PARAMETER OutputPath
    Directory for the generated HTML dashboard. Default: .\Reports\sample-dashboard
.PARAMETER OpenInBrowser
    Open the generated HTML file in the default browser after creation.
.PARAMETER Help
    Show this help text.
.EXAMPLE
    .\Scripts\New-SPSampleDashboard.ps1 -OpenInBrowser
    # Generates sample dashboard and opens it in the default browser.
.EXAMPLE
    .\Scripts\New-SPSampleDashboard.ps1 -OutputPath C:\demo\dashboard
    # Generates sample dashboard in the specified directory.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$OutputPath,
    [Parameter()] [switch]$OpenInBrowser,
    [Parameter()] [switch]$Help
)

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $false }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    elseif ($mod.Required) {
        Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
        exit 4
    }
}

#endregion

#region Resolve Output Path

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $toolkitRoot 'Reports\sample-dashboard'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

#endregion

#region Generate Synthetic Governance Metrics JSONL

Write-Host ''
Write-Host '  Governance Trend Dashboard -- Sample Data Generator' -ForegroundColor Cyan
Write-Host '  ====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Step 1: Generating synthetic governance metrics...' -ForegroundColor Gray

$metricsDir = Join-Path $OutputPath '.metrics'
if (-not (Test-Path $metricsDir)) { New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null }

$metricsFile = Join-Path $metricsDir 'governance-metrics.jsonl'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$now = (Get-Date).ToUniversalTime()
$sb = New-Object System.Text.StringBuilder

# Generate 45 days of data (daily captures) so we have prior month + current month
for ($day = 44; $day -ge 0; $day--) {
    $ts = $now.AddDays(-$day)
    $dayFraction = ($day / 44.0)

    # Maturity score: trending up from 2.6 to 3.4 with small noise
    $maturity = [math]::Round(2.6 + (0.8 * (1 - $dayFraction)) + (Get-Random -Minimum -10 -Maximum 10) / 100.0, 2)

    # Active campaigns: varies 3-7
    $activeCampaigns = Get-Random -Minimum 3 -Maximum 8

    # Completed campaigns: 0-2 per day
    $completedCampaigns = Get-Random -Minimum 0 -Maximum 3

    # Overdue: 0-2
    $overdue = Get-Random -Minimum 0 -Maximum 3

    # Avg days to complete: 8-18
    $avgDays = [math]::Round(8 + (Get-Random -Minimum 0 -Maximum 100) / 10.0, 1)

    # Reviewer completion: trending up from 62% to 82%
    $reviewerComp = [math]::Round(62 + (20 * (1 - $dayFraction)) + (Get-Random -Minimum -30 -Maximum 30) / 10.0, 1)

    # Reviewers
    $totalReviewers = Get-Random -Minimum 12 -Maximum 25
    $completedReviewers = [math]::Floor($totalReviewers * $reviewerComp / 100)
    $notStarted = Get-Random -Minimum 0 -Maximum ([math]::Max(1, $totalReviewers - $completedReviewers))

    # Stale access: trending down from 180 to 120
    $staleAccess = [int][math]::Round(180 - (60 * (1 - $dayFraction)) + (Get-Random -Minimum -8 -Maximum 8))

    # At-risk reviewers: 0-3 with spike in week 3
    $atRisk = Get-Random -Minimum 0 -Maximum 3
    if ($day -ge 14 -and $day -le 20) { $atRisk = Get-Random -Minimum 3 -Maximum 7 }

    # Approval rate
    $approvalRate = [math]::Round(0.78 + (Get-Random -Minimum -50 -Maximum 50) / 1000.0, 3)

    # Source governance coverage
    $coverage = [math]::Round(85 + (Get-Random -Minimum -50 -Maximum 50) / 10.0, 1)

    # Identity risk
    $highRisk = Get-Random -Minimum 2 -Maximum 12
    $avgRiskScore = [math]::Round(2.1 + (Get-Random -Minimum 0 -Maximum 20) / 10.0, 2)

    # Orchestrator success
    $orchSuccess = [math]::Round(95 + (Get-Random -Minimum 0 -Maximum 50) / 10.0, 1)
    if ($orchSuccess -gt 100) { $orchSuccess = 100.0 }

    $record = [ordered]@{
        timestamp = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
        label     = "sample-day-$($ts.ToString('yyyy-MM-dd'))"
        metrics   = [ordered]@{
            'identityRisk.highCount'       = $highRisk
            'identityRisk.avgScore'        = $avgRiskScore
            'sourceGovernance.coveragePct'  = $coverage
            'sourceGovernance.avgScore'     = [math]::Round($coverage / 25, 2)
            'campaigns.total'              = $activeCampaigns + $completedCampaigns
            'campaigns.avgApprovalRate'     = $approvalRate
            'campaigns.avgResponseHours'    = [math]::Round(18 + (Get-Random -Minimum 0 -Maximum 240) / 10.0, 1)
            'reviewers.avgScore'           = [math]::Round(3.2 + (Get-Random -Minimum -10 -Maximum 10) / 10.0, 2)
            'reviewers.atRiskCount'        = $atRisk
            'staleAccess.totalItems'       = $staleAccess
            'staleAccess.neverReviewed'    = [int][math]::Round($staleAccess * 0.3)
            'maturity.overallScore'        = $maturity
            'maturity.overallLevel'        = if ($maturity -ge 3.0) { 'Defined' } elseif ($maturity -ge 2.0) { 'Developing' } else { 'Initial' }
            'orchestrator.successRate'     = $orchSuccess
            'campaigns.activeCount'        = $activeCampaigns
            'campaigns.completedCount'     = $completedCampaigns
            'campaigns.overdueCount'       = $overdue
            'campaigns.avgDaysToComplete'  = $avgDays
            'reviewers.totalActive'        = $totalReviewers
            'reviewers.completedCount'     = $completedReviewers
            'reviewers.notStartedCount'    = $notStarted
            'reviewers.avgCompletionPct'   = $reviewerComp
        }
    }

    [void]$sb.AppendLine(($record | ConvertTo-Json -Depth 5 -Compress))
}

[System.IO.File]::WriteAllText($metricsFile, $sb.ToString(), $utf8)
Write-Host "    Created $metricsFile (45 daily records)" -ForegroundColor DarkGray

#endregion

#region Generate Synthetic Campaign Trend JSONL

Write-Host '  Step 2: Generating synthetic campaign trend data...' -ForegroundColor Gray

$trendDir = Join-Path $metricsDir 'campaign-trend'
if (-not (Test-Path $trendDir)) { New-Item -ItemType Directory -Path $trendDir -Force | Out-Null }

$campaigns = @(
    @{ Id = 'camp-q2-entitlement-review'; Name = 'Q2 Entitlement Review'; Status = 'ACTIVE'; DueDate = $now.AddDays(8).ToString('yyyy-MM-ddTHH:mm:ssZ'); Created = $now.AddDays(-22).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    @{ Id = 'camp-ad-manager-cert';       Name = 'AD Manager Certification'; Status = 'ACTIVE'; DueDate = $now.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ssZ'); Created = $now.AddDays(-18).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    @{ Id = 'camp-q1-cleanup';            Name = 'Q1 Cleanup Review'; Status = 'COMPLETED'; DueDate = $now.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ'); Created = $now.AddDays(-35).ToString('yyyy-MM-ddTHH:mm:ssZ') }
)

$reviewerNames = @('Alice Chen', 'Bob Martinez', 'Carol Davis', 'Dave Wilson', 'Eve Thompson')

foreach ($camp in $campaigns) {
    $safeId = $camp.Id -replace '[^A-Za-z0-9_\-]', '_'
    $file = Join-Path $trendDir "$safeId.jsonl"
    $csb = New-Object System.Text.StringBuilder

    # Generate 20 daily captures for this campaign
    $startDay = if ($camp.Status -eq 'COMPLETED') { 30 } else { 20 }
    for ($day = $startDay; $day -ge 0; $day--) {
        $ts = $now.AddDays(-$day)
        $progress = 1 - ($day / [math]::Max(1, $startDay))

        $total = Get-Random -Minimum 80 -Maximum 150
        $approved = [int][math]::Round($total * $progress * 0.65)
        $revoked  = [int][math]::Round($total * $progress * 0.12)
        $pending  = $total - $approved - $revoked
        if ($pending -lt 0) { $pending = 0 }

        $privTotal = [int][math]::Round($total * 0.15)
        $privApproved = [int][math]::Round($privTotal * $progress * 0.7)
        $privRevoked  = [int][math]::Round($privTotal * $progress * 0.2)

        $reviewersTotal = 5
        $reviewersSigned = [int][math]::Round(5 * $progress)
        $completionPct = [math]::Round(($approved + $revoked) / [math]::Max(1, $total) * 100, 1)

        # Scope changes (from "diff")
        $scopeAdded   = if ($day -gt 2) { Get-Random -Minimum 0 -Maximum 8 } else { 0 }
        $scopeRemoved = if ($day -gt 5) { Get-Random -Minimum 0 -Maximum 3 } else { 0 }
        $scopeChanged = if ($day -gt 3) { Get-Random -Minimum 0 -Maximum 5 } else { 0 }

        # Timing
        $daysSinceStart = $startDay - $day
        $dueTs = [datetime]::Parse($camp.DueDate)
        $daysUntilDeadline = [int][math]::Round(($dueTs - $ts).TotalDays)

        # Per-reviewer summaries
        $reviewers = @()
        $remainingApproved = $approved
        $remainingRevoked  = $revoked
        $remainingPending  = $pending
        for ($ri = 0; $ri -lt 5; $ri++) {
            $rTotal = [int][math]::Round($total / 5)
            $rApproved = [int][math]::Min($remainingApproved, [math]::Round($rTotal * 0.65))
            $remainingApproved -= $rApproved
            $rRevoked = [int][math]::Min($remainingRevoked, [math]::Round($rTotal * 0.12))
            $remainingRevoked -= $rRevoked
            $rPending = $rTotal - $rApproved - $rRevoked
            if ($rPending -lt 0) { $rPending = 0 }
            $rComp = [math]::Round(($rApproved + $rRevoked) / [math]::Max(1, $rTotal) * 100, 1)

            $reviewers += [ordered]@{
                reviewer   = $reviewerNames[$ri]
                total      = $rTotal
                approved   = $rApproved
                revoked    = $rRevoked
                pending    = $rPending
                completion = $rComp
            }
        }

        $record = [ordered]@{
            timestamp    = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
            campaignId   = $camp.Id
            campaignName = $camp.Name
            status       = $camp.Status
            environment  = 'SAMPLE'
            dueDate      = $camp.DueDate
            metrics      = [ordered]@{
                'counts.total'              = $total
                'counts.approved'           = $approved
                'counts.revoked'            = $revoked
                'counts.pending'            = $pending
                'counts.privTotal'          = $privTotal
                'counts.privApproved'       = $privApproved
                'counts.privRevoked'        = $privRevoked
                'counts.privPending'        = $privTotal - $privApproved - $privRevoked
                'counts.reviewersTotal'     = $reviewersTotal
                'counts.reviewersSigned'    = $reviewersSigned
                'counts.reviewersNotStarted'= [math]::Max(0, $reviewersTotal - $reviewersSigned - 1)
                'rates.privApprovalRate'    = if ($privTotal -gt 0) { [math]::Round($privApproved / $privTotal, 3) } else { $null }
                'rates.approvalRate'        = if ($total -gt 0) { [math]::Round($approved / $total, 3) } else { $null }
                'rates.revokeRate'          = if ($total -gt 0) { [math]::Round($revoked / $total, 3) } else { $null }
                'completion.byDecisionPct'  = $completionPct
                'velocity.decisionsPerHour' = [math]::Round((Get-Random -Minimum 5 -Maximum 25) + (Get-Random -Minimum 0 -Maximum 100) / 100.0, 2)
                'scope.added'              = $scopeAdded
                'scope.removed'            = $scopeRemoved
                'scope.changed'            = $scopeChanged
                'scope.revokedItems'       = $revoked
                'scope.totalSources'       = Get-Random -Minimum 3 -Maximum 8
                'timing.daysSinceStart'    = $daysSinceStart
                'timing.daysUntilDeadline' = $daysUntilDeadline
                'risk.privilegedApproved'  = $privApproved
                'risk.privilegedTotal'     = $privTotal
            }
            reviewers = $reviewers
        }

        [void]$csb.AppendLine(($record | ConvertTo-Json -Depth 6 -Compress))
    }

    [System.IO.File]::WriteAllText($file, $csb.ToString(), $utf8)
    Write-Host "    Created $file ($($camp.Name))" -ForegroundColor DarkGray
}

#endregion

#region Run Dashboard Pipeline

Write-Host '  Step 3: Running dashboard pipeline...' -ForegroundColor Gray

# Override config to point at our synthetic data
# We mock Get-SPConfig by temporarily setting the metrics path
$originalGetConfig = $null
try {
    # Build a minimal config object that the trend query functions will use
    $mockConfig = [PSCustomObject]@{
        Metrics = [PSCustomObject]@{
            Path              = $metricsDir
            CampaignTrendPath = $trendDir
            RetentionDays     = 365
        }
        Audit = [PSCustomObject]@{
            OutputPath = $OutputPath
        }
    }

    # Replace Get-SPConfig in the current session
    $originalGetConfig = Get-Command Get-SPConfig -ErrorAction SilentlyContinue
    function global:Get-SPConfig { return $mockConfig }

    Write-Host '    Building dashboard data (Last30Days)...' -ForegroundColor DarkGray
    $dashData = Get-SPGovernanceDashboardData -Period Last30Days

    Write-Host '    Computing period comparison...' -ForegroundColor DarkGray
    $comparison = $null
    try {
        $prevMonth = $now.AddMonths(-1).ToString('yyyy-MM')
        $currMonth = $now.ToString('yyyy-MM')
        $comparison = Compare-SPGovernancePeriods -Period1 $prevMonth -Period2 $currMonth
    }
    catch {
        Write-Host "    WARN: Period comparison skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host '    Checking governance alerts...' -ForegroundColor DarkGray
    $alerts = @()
    try { $alerts = @(Get-SPGovernanceAlerts -LookbackDays 30) } catch { }
    if ($alerts.Count -gt 0) {
        Write-Host "    Found $($alerts.Count) alert(s)" -ForegroundColor Yellow
    }
    else {
        Write-Host '    No alerts (all metrics healthy)' -ForegroundColor Green
    }

    Write-Host '    Rendering HTML dashboard...' -ForegroundColor DarkGray

    $timestamp = $now.ToString('yyyyMMdd-HHmmss')
    $htmlFile = Join-Path $OutputPath "governance-dashboard-sample-${timestamp}.html"

    $exportParams = @{
        DashboardData = $dashData
        OutputPath    = $htmlFile
        Title         = 'Governance Trend Dashboard -- Sample Data'
    }
    if ($null -ne $comparison) {
        $exportParams['PeriodComparison'] = $comparison
    }

    $result = Export-SPGovernanceDashboardHtml @exportParams

    if ($result -is [hashtable] -and $result.Success) {
        $htmlFile = $result.Data
    }
    elseif ($result -is [string] -and (Test-Path $result)) {
        $htmlFile = $result
    }
}
finally {
    # Restore original Get-SPConfig
    if ($null -ne $originalGetConfig) {
        Remove-Item Function:\Get-SPConfig -ErrorAction SilentlyContinue
    }
}

#endregion

#region Output

Write-Host ''
Write-Host '  Dashboard generated successfully!' -ForegroundColor Green
Write-Host ''
Write-Host "  HTML:    $htmlFile" -ForegroundColor White
Write-Host "  Data:    $metricsDir" -ForegroundColor DarkGray
Write-Host "  Trends:  $trendDir" -ForegroundColor DarkGray
Write-Host ''

# Summary stats
Write-Host '  Pipeline Summary:' -ForegroundColor Cyan
if ($null -ne $dashData -and $null -ne $dashData.KPIs) {
    foreach ($kpiName in @('MaturityScore', 'ActiveCampaigns', 'PrivApprovalRate', 'ReviewerCompletion', 'StaleAccessCount')) {
        $kpi = $dashData.KPIs[$kpiName]
        if ($null -ne $kpi -and $null -ne $kpi.Value) {
            $arrow = switch ($kpi.Direction) { 'Up' { '^' } 'Down' { 'v' } default { '-' } }
            Write-Host "    $kpiName : $($kpi.Value)  $arrow $($kpi.Delta)  ($($kpi.Periods) periods)" -ForegroundColor White
        }
    }
}
Write-Host ''

if ($OpenInBrowser -and (Test-Path $htmlFile)) {
    Write-Host '  Opening in default browser...' -ForegroundColor Gray
    if ($IsMacOS -or $env:OS -notmatch 'Windows') {
        & open $htmlFile
    }
    else {
        Start-Process $htmlFile
    }
}

#endregion
