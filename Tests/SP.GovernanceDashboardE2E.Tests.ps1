<#
.SYNOPSIS
    End-to-end Pester tests for the governance dashboard pipeline.
    Synthetic JSONL -> Get-SPGovernanceDashboardData -> Compare-SPGovernancePeriods
      -> Get-SPGovernanceAlerts -> Export-SPGovernanceDashboardHtml

    DE-01: Dashboard data has KPI values
    DE-02: Sparkline arrays have weekly buckets
    DE-03: Direction computed correctly
    DE-04: Compare-SPGovernancePeriods returns deltas
    DE-05: Get-SPGovernanceAlerts detects issues
    DE-06: Dashboard HTML has KPI cards
    DE-07: Full round-trip produces valid file
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    # -----------------------------------------------------------
    # Helper: write a governance-metrics.jsonl file
    # -----------------------------------------------------------
    function New-DEGovernanceMetricsFile {
        param(
            [string]$Dir,
            [hashtable[]]$Records
        )
        if (-not (Test-Path $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
        $filePath = Join-Path $Dir 'governance-metrics.jsonl'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($rec in $Records) {
            $lines.Add(($rec | ConvertTo-Json -Depth 5 -Compress))
        }
        $content = ($lines -join "`n")
        if ($lines.Count -gt 0) { $content += "`n" }
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        return $filePath
    }

    # -----------------------------------------------------------
    # Helper: write a campaign trend JSONL file
    # -----------------------------------------------------------
    function New-DECampaignTrendFile {
        param(
            [string]$Dir,
            [string]$CampaignId,
            [hashtable[]]$Records
        )
        if (-not (Test-Path $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
        $safeId = $CampaignId -replace '[^A-Za-z0-9_\-]', '_'
        $filePath = Join-Path $Dir "$safeId.jsonl"
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($rec in $Records) {
            $lines.Add(($rec | ConvertTo-Json -Depth 5 -Compress))
        }
        $content = ($lines -join "`n")
        if ($lines.Count -gt 0) { $content += "`n" }
        [System.IO.File]::WriteAllText($filePath, $content, $utf8)
        return $filePath
    }

    # -----------------------------------------------------------
    # Helper: mock Get-SPConfig across consuming modules
    # -----------------------------------------------------------
    function Set-DEConfigMock {
        param([string]$MetricsDir, [string]$TrendDir)
        $mockBlock = {
            return [PSCustomObject]@{
                Metrics = [PSCustomObject]@{
                    Path              = $MetricsDir
                    CampaignTrendPath = $TrendDir
                    RetentionDays     = 365
                }
            }
        }.GetNewClosure()
        Mock Get-SPConfig -ModuleName SP.AuditOperations $mockBlock
        Mock Get-SPConfig -ModuleName SP.GovernanceTrendQuery $mockBlock
    }

    # -----------------------------------------------------------
    # Generate 30 days of synthetic governance-metrics.jsonl
    # with a clear upward maturity trend and growing stale access.
    # One record per day from 2026-05-14 through 2026-06-12.
    # -----------------------------------------------------------
    $script:e2eMetricsDir = Join-Path $TestDrive 'de-e2e-metrics'
    $script:e2eTrendDir   = Join-Path $TestDrive 'de-e2e-trend'

    $govRecords = [System.Collections.Generic.List[hashtable]]::new()
    $baseDate   = Get-Date '2026-05-14T08:00:00'
    for ($d = 0; $d -lt 30; $d++) {
        $ts = $baseDate.AddDays($d).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        # Maturity: rises from 2.5 to 3.5 over 30 days (clear Up direction)
        $maturity = [math]::Round(2.5 + ($d / 29.0) * 1.0, 2)
        # Stale access: rises from 80 to 160 (triggers alert)
        $stale    = [int](80 + ($d / 29.0) * 80)
        # Reviewer completion: stable around 72-78
        $reviewer = [math]::Round(72 + ($d % 7), 1)
        # Active campaigns: constant at 4
        $active   = 4
        # Overdue campaigns: 0 for the first half, 2 for the second half
        $overdue  = if ($d -ge 15) { 2 } else { 0 }

        $govRecords.Add([ordered]@{
            timestamp = $ts
            label     = $null
            metrics   = [ordered]@{
                'maturity.overallScore'       = $maturity
                'campaigns.activeCount'       = $active
                'reviewers.avgCompletionPct'  = $reviewer
                'staleAccess.totalItems'      = $stale
                'campaigns.overdueCount'      = $overdue
                'campaigns.completedCount'    = 1
                'campaigns.avgDaysToComplete' = 14.0
            }
        })
    }
    New-DEGovernanceMetricsFile -Dir $script:e2eMetricsDir -Records @($govRecords)

    # -----------------------------------------------------------
    # Generate 2 campaign trend JSONL files with priv approval data
    # -----------------------------------------------------------
    $campAlpha = [System.Collections.Generic.List[hashtable]]::new()
    for ($d = 0; $d -lt 30; $d += 5) {
        $ts = $baseDate.AddDays($d).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $campAlpha.Add([ordered]@{
            timestamp    = $ts
            campaignId   = 'camp-alpha'
            campaignName = 'Alpha Campaign'
            status       = 'ACTIVE'
            environment  = 'TEST'
            dueDate      = ''
            metrics      = [ordered]@{
                'rates.privApprovalRate' = [math]::Round(0.10 + ($d / 290.0), 4)
                'counts.total'           = 200
            }
        })
    }
    New-DECampaignTrendFile -Dir $script:e2eTrendDir -CampaignId 'camp-alpha' -Records @($campAlpha)

    $campBeta = [System.Collections.Generic.List[hashtable]]::new()
    for ($d = 0; $d -lt 30; $d += 7) {
        $ts = $baseDate.AddDays($d).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $campBeta.Add([ordered]@{
            timestamp    = $ts
            campaignId   = 'camp-beta'
            campaignName = 'Beta Campaign'
            status       = 'COMPLETED'
            environment  = 'TEST'
            dueDate      = ''
            metrics      = [ordered]@{
                'rates.privApprovalRate' = [math]::Round(0.08 + ($d / 350.0), 4)
                'counts.total'           = 150
            }
        })
    }
    New-DECampaignTrendFile -Dir $script:e2eTrendDir -CampaignId 'camp-beta' -Records @($campBeta)
}

# ===================================================================
# DE-01: Dashboard data has KPI values
# ===================================================================
Describe "DE-01: Dashboard data has KPI values" {
    It "KPIs.MaturityScore.Value is not null when 30 days of data exist" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        $dashboard = Get-SPGovernanceDashboardData -Period Last30Days

        $dashboard            | Should -Not -BeNullOrEmpty
        $dashboard.KPIs       | Should -Not -BeNullOrEmpty
        $dashboard.KPIs.MaturityScore          | Should -Not -BeNullOrEmpty
        $dashboard.KPIs.MaturityScore.Value    | Should -Not -BeNullOrEmpty
        $dashboard.KPIs.ActiveCampaigns.Value  | Should -Not -BeNullOrEmpty
        $dashboard.KPIs.StaleAccessCount.Value | Should -Not -BeNullOrEmpty
        $dashboard.KPIs.ReviewerCompletion.Value | Should -Not -BeNullOrEmpty
    }
}

# ===================================================================
# DE-02: Sparkline arrays have weekly buckets
# ===================================================================
Describe "DE-02: Sparkline arrays have weekly buckets" {
    It "Sparklines.MaturityScore has 4-5 entries for 30 days of daily data" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        $dashboard = Get-SPGovernanceDashboardData -Period Last30Days

        $dashboard.Sparklines | Should -Not -BeNullOrEmpty
        $sparkCount = @($dashboard.Sparklines.MaturityScore).Count
        # 30 days / 7 = ~4.3 weeks; expect 4 or 5 weekly buckets
        $sparkCount | Should -BeGreaterOrEqual 4
        $sparkCount | Should -BeLessOrEqual 5
    }
}

# ===================================================================
# DE-03: Direction computed correctly
# ===================================================================
Describe "DE-03: Direction computed correctly" {
    It "Direction is Up when maturity is trending upward in the data" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        $dashboard = Get-SPGovernanceDashboardData -Period Last30Days

        # Maturity rises from 2.5 to 3.5, which is >5% change, so direction should be Up
        $dashboard.KPIs.MaturityScore.Direction | Should -Be 'Up'
    }
}

# ===================================================================
# DE-04: Compare-SPGovernancePeriods returns deltas
# ===================================================================
Describe "DE-04: Compare-SPGovernancePeriods returns deltas" {
    It "Returns Metrics hashtable with Before/After/Delta for each metric" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        # Data spans 2026-05-14 through 2026-06-12 so both months have records
        $result = Compare-SPGovernancePeriods -Period1 '2026-05' -Period2 '2026-06' -Granularity Month

        $result          | Should -Not -BeNullOrEmpty
        $result.Period1  | Should -Be '2026-05'
        $result.Period2  | Should -Be '2026-06'
        $result.Metrics  | Should -Not -BeNullOrEmpty
        $result.Metrics.Count | Should -BeGreaterThan 0

        # maturity.overallScore should be present with Before/After/Delta
        $result.Metrics.ContainsKey('maturity.overallScore') | Should -Be $true
        $mat = $result.Metrics['maturity.overallScore']
        $mat.Before    | Should -Not -BeNullOrEmpty
        $mat.After     | Should -Not -BeNullOrEmpty
        $mat.Delta     | Should -Not -BeNullOrEmpty
        $mat.Direction | Should -BeIn @('Up','Down','Flat')

        # After should be greater than Before (maturity improved)
        $mat.After | Should -BeGreaterThan $mat.Before
    }
}

# ===================================================================
# DE-05: Get-SPGovernanceAlerts detects issues
# ===================================================================
Describe "DE-05: Get-SPGovernanceAlerts detects issues" {
    It "Produces alerts for declining/growing metrics planted in the data" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        $alerts = @(Get-SPGovernanceAlerts -LookbackDays 30)

        $alerts.Count | Should -BeGreaterThan 0

        # Stale access rose from 80 to 160 (100% increase) -- should trigger alert
        $staleAlert = $alerts | Where-Object { $_.Metric -eq 'staleAccess.totalItems' }
        $staleAlert | Should -Not -BeNullOrEmpty
        @($staleAlert)[0].Message | Should -Match 'Stale access items rose'

        # Overdue campaigns = 2 in latest records -- should trigger alert
        $overdueAlert = $alerts | Where-Object { $_.Metric -eq 'campaigns.overdueCount' }
        $overdueAlert | Should -Not -BeNullOrEmpty
        @($overdueAlert)[0].Message | Should -Match 'campaign'
    }
}

# ===================================================================
# DE-06: Dashboard HTML has KPI cards
# ===================================================================
Describe "DE-06: Dashboard HTML has KPI cards" {
    It "Exported HTML contains DOCTYPE and KPI metric labels" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        $dashboard = Get-SPGovernanceDashboardData -Period Last30Days
        $outDir    = Join-Path $TestDrive 'de06-html'
        $result    = Export-SPGovernanceDashboardHtml -DashboardData $dashboard -OutputPath $outDir

        $result.Success | Should -Be $true
        $content = [System.IO.File]::ReadAllText($result.Data)

        $content | Should -Match '<!DOCTYPE html>'
        # KPI label names rendered in the card row
        $content | Should -Match 'Maturity Score'
        $content | Should -Match 'Active Campaigns'
        $content | Should -Match 'Stale Access'
        $content | Should -Match 'Reviewer Completion'
    }
}

# ===================================================================
# DE-07: Full round-trip produces valid file
# ===================================================================
Describe "DE-07: Full round-trip produces valid file" {
    It "HTML file exists, is >1KB, and contains closing html tag" {
        Set-DEConfigMock -MetricsDir $script:e2eMetricsDir -TrendDir $script:e2eTrendDir

        # Full pipeline: data -> compare -> alerts -> HTML
        $dashboard  = Get-SPGovernanceDashboardData -Period Last30Days
        $comparison = Compare-SPGovernancePeriods -Period1 '2026-05' -Period2 '2026-06' -Granularity Month
        # Alerts are already embedded in dashboard, but we can also pass PeriodComparison
        $outDir     = Join-Path $TestDrive 'de07-html'
        $result     = Export-SPGovernanceDashboardHtml `
                        -DashboardData $dashboard `
                        -OutputPath $outDir `
                        -PeriodComparison $comparison

        $result.Success | Should -Be $true
        Test-Path $result.Data | Should -Be $true

        $fileInfo = Get-Item $result.Data
        $fileInfo.Length | Should -BeGreaterThan 1024

        $content = [System.IO.File]::ReadAllText($result.Data)
        $content | Should -Match '</html>'
    }
}
