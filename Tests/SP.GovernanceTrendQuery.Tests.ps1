<#
.SYNOPSIS
    Unit tests for SP.GovernanceTrendQuery -- the unified trend query layer.
    TQ-01: Get-SPGovernanceDashboardData returns KPIs with Direction field
    TQ-02: Get-SPGovernanceDashboardData returns empty structure when no data
    TQ-03: Compare-SPGovernancePeriods returns Delta for each metric
    TQ-04: Get-SPGovernanceAlerts flags declining metrics
    TQ-05: Get-SPGovernanceAlerts returns empty when all healthy
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # Helper: write a governance-metrics.jsonl file with known data
    function New-TQGovernanceMetricsFile {
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

    # Helper: write a campaign trend JSONL file with known data
    function New-TQCampaignTrendFile {
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

    # Helper: apply the Get-SPConfig mock to all consuming modules
    function Set-TQConfigMock {
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
}

Describe "TQ-01: Get-SPGovernanceDashboardData returns KPIs with Direction" {
    It "Returns KPIs with Direction field when trend data exists" {
        $metricsDir = Join-Path $TestDrive 'tq01-metrics'
        $trendDir   = Join-Path $TestDrive 'tq01-trend'

        # Create governance metrics with improving maturity and growing stale access
        $records = @(
            [ordered]@{
                timestamp = (Get-Date).AddDays(-20).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')   # relative: fixed dates rot out of the Last30Days window
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'      = 2.8
                    'campaigns.activeCount'      = 5
                    'reviewers.avgCompletionPct'  = 60.0
                    'staleAccess.totalItems'     = 100
                    'campaigns.overdueCount'     = 0
                    'campaigns.completedCount'   = 2
                    'campaigns.avgDaysToComplete' = 10.0
                }
            },
            [ordered]@{
                timestamp = (Get-Date).AddDays(-5).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'      = 3.2
                    'campaigns.activeCount'      = 5
                    'reviewers.avgCompletionPct'  = 78.5
                    'staleAccess.totalItems'     = 90
                    'campaigns.overdueCount'     = 1
                    'campaigns.completedCount'   = 3
                    'campaigns.avgDaysToComplete' = 12.5
                }
            }
        )

        New-TQGovernanceMetricsFile -Dir $metricsDir -Records $records

        # Create a campaign trend file with priv approval data
        $campRecords = @(
            [ordered]@{
                timestamp    = (Get-Date).AddDays(-20).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                campaignId   = 'camp-tq01'
                campaignName = 'TQ01 Test'
                status       = 'ACTIVE'
                environment  = 'TEST'
                dueDate      = ''
                metrics      = [ordered]@{
                    'rates.privApprovalRate' = 0.15
                    'counts.total'           = 100
                }
            },
            [ordered]@{
                timestamp    = (Get-Date).AddDays(-5).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                campaignId   = 'camp-tq01'
                campaignName = 'TQ01 Test'
                status       = 'ACTIVE'
                environment  = 'TEST'
                dueDate      = ''
                metrics      = [ordered]@{
                    'rates.privApprovalRate' = 0.12
                    'counts.total'           = 100
                }
            }
        )
        New-TQCampaignTrendFile -Dir $trendDir -CampaignId 'camp-tq01' -Records $campRecords

        Set-TQConfigMock -MetricsDir $metricsDir -TrendDir $trendDir

        $result = Get-SPGovernanceDashboardData -Period 'Last30Days'

        $result | Should -Not -BeNullOrEmpty
        $result.KPIs | Should -Not -BeNullOrEmpty
        $result.KPIs.MaturityScore | Should -Not -BeNullOrEmpty
        $result.KPIs.MaturityScore.Direction | Should -BeIn @('Up','Down','Flat')
        $result.KPIs.MaturityScore.Value | Should -Not -BeNullOrEmpty
        $result.KPIs.ActiveCampaigns.Direction | Should -BeIn @('Up','Down','Flat')
        $result.KPIs.StaleAccessCount.Direction | Should -BeIn @('Up','Down','Flat')
        $result.KPIs.PrivApprovalRate.Direction | Should -BeIn @('Up','Down','Flat')
        $result.KPIs.ReviewerCompletion.Direction | Should -BeIn @('Up','Down','Flat')

        # Sparklines should contain data points
        $result.Sparklines | Should -Not -BeNullOrEmpty
        @($result.Sparklines.MaturityScore).Count | Should -BeGreaterThan 0

        # Campaign data should be populated from latest gov record
        $result.Campaigns.Active.Overdue | Should -Be 1
        $result.Campaigns.Completed.Count | Should -Be 3
    }
}

Describe "TQ-02: Get-SPGovernanceDashboardData returns empty structure when no data" {
    It "Returns a valid structure with null values when no trend data exists" {
        $emptyDir = Join-Path $TestDrive 'tq02-empty'
        if (-not (Test-Path $emptyDir)) { New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null }
        $emptyTrendDir = Join-Path $TestDrive 'tq02-empty-trend'

        Set-TQConfigMock -MetricsDir $emptyDir -TrendDir $emptyTrendDir

        $result = Get-SPGovernanceDashboardData -Period 'Last30Days'

        $result | Should -Not -BeNullOrEmpty
        $result.Period | Should -Be 'Last30Days'
        $result.KPIs | Should -Not -BeNullOrEmpty
        $result.KPIs.MaturityScore.Value | Should -BeNullOrEmpty
        $result.KPIs.MaturityScore.Direction | Should -Be 'Flat'
        @($result.Sparklines.MaturityScore).Count | Should -Be 0
        @($result.Alerts).Count | Should -Be 0
        $result.Campaigns.Active.Count | Should -Be 0
    }
}

Describe "TQ-03: Compare-SPGovernancePeriods returns Delta for each metric" {
    It "Returns Before/After/Delta/Direction for metrics across two months" {
        $metricsDir = Join-Path $TestDrive 'tq03-metrics'

        $records = @(
            [ordered]@{
                timestamp = (Get-Date '2026-05-15T08:00:00').ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 2.9
                    'campaigns.activeCount'    = 4
                    'staleAccess.totalItems'   = 120
                }
            },
            [ordered]@{
                # FIXED date on purpose: this test compares the explicit months
                # '2026-05' vs '2026-06', so this record must stay in June.
                timestamp = (Get-Date '2026-06-10T08:00:00').ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 3.2
                    'campaigns.activeCount'    = 5
                    'staleAccess.totalItems'   = 142
                }
            }
        )

        New-TQGovernanceMetricsFile -Dir $metricsDir -Records $records

        Set-TQConfigMock -MetricsDir $metricsDir -TrendDir (Join-Path $TestDrive 'tq03-no-campaigns')

        $result = Compare-SPGovernancePeriods -Period1 '2026-05' -Period2 '2026-06' -Granularity Month

        $result | Should -Not -BeNullOrEmpty
        $result.Period1 | Should -Be '2026-05'
        $result.Period2 | Should -Be '2026-06'
        $result.Metrics | Should -Not -BeNullOrEmpty

        # maturity.overallScore should show improvement (uses 'latest' aggregation)
        $result.Metrics.ContainsKey('maturity.overallScore') | Should -Be $true
        $mat = $result.Metrics['maturity.overallScore']
        $mat.Before | Should -Be 2.9
        $mat.After | Should -Be 3.2
        $mat.Delta | Should -BeGreaterThan 0
        $mat.Direction | Should -BeIn @('Up','Down','Flat')

        # campaigns.activeCount should have a delta
        $result.Metrics.ContainsKey('campaigns.activeCount') | Should -Be $true
        $camp = $result.Metrics['campaigns.activeCount']
        $camp.Delta | Should -Not -BeNullOrEmpty
    }
}

Describe "TQ-04: Get-SPGovernanceAlerts flags declining metrics" {
    It "Generates an alert for declining maturity and growing stale access" {
        $metricsDir = Join-Path $TestDrive 'tq04-metrics'

        # Maturity declining, stale access growing
        $records = @(
            [ordered]@{
                timestamp = (Get-Date).AddDays(-25).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')   # relative: fixed dates rot out of the lookback window
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 3.5
                    'staleAccess.totalItems'   = 100
                    'campaigns.overdueCount'   = 2
                }
            },
            [ordered]@{
                timestamp = (Get-Date).AddDays(-12).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 3.2
                    'staleAccess.totalItems'   = 130
                    'campaigns.overdueCount'   = 3
                }
            },
            [ordered]@{
                timestamp = (Get-Date).AddDays(-2).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 2.9
                    'staleAccess.totalItems'   = 160
                    'campaigns.overdueCount'   = 3
                }
            }
        )

        New-TQGovernanceMetricsFile -Dir $metricsDir -Records $records

        Set-TQConfigMock -MetricsDir $metricsDir -TrendDir (Join-Path $TestDrive 'tq04-no-campaigns')

        $alerts = @(Get-SPGovernanceAlerts -LookbackDays 30)

        $alerts.Count | Should -BeGreaterThan 0

        # Should have at least an alert for maturity decline
        $maturityAlert = $alerts | Where-Object { $_.Metric -eq 'maturity.overallScore' }
        $maturityAlert | Should -Not -BeNullOrEmpty
        @($maturityAlert)[0].Severity | Should -BeIn @('Amber','Red')
        @($maturityAlert)[0].Message | Should -Match 'Maturity score dropped'

        # Should have an alert for stale access growing
        $staleAlert = $alerts | Where-Object { $_.Metric -eq 'staleAccess.totalItems' }
        $staleAlert | Should -Not -BeNullOrEmpty
        @($staleAlert)[0].Message | Should -Match 'Stale access items rose'

        # Should have an alert for overdue campaigns
        $overdueAlert = $alerts | Where-Object { $_.Metric -eq 'campaigns.overdueCount' }
        $overdueAlert | Should -Not -BeNullOrEmpty
        @($overdueAlert)[0].Message | Should -Match 'campaign'
    }
}

Describe "TQ-05: Get-SPGovernanceAlerts returns empty when all healthy" {
    It "Returns no alerts when all metrics are stable or improving" {
        $metricsDir = Join-Path $TestDrive 'tq05-metrics'

        # All metrics stable/improving
        $records = @(
            [ordered]@{
                timestamp = (Get-Date).AddDays(-15).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')   # relative: previously outside the window, passing vacuously
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 3.0
                    'staleAccess.totalItems'   = 100
                    'campaigns.overdueCount'   = 0
                    'reviewers.atRiskCount'    = 0
                }
            },
            [ordered]@{
                timestamp = (Get-Date).AddDays(-2).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                label     = $null
                metrics   = [ordered]@{
                    'maturity.overallScore'    = 3.2
                    'staleAccess.totalItems'   = 95
                    'campaigns.overdueCount'   = 0
                    'reviewers.atRiskCount'    = 0
                }
            }
        )

        New-TQGovernanceMetricsFile -Dir $metricsDir -Records $records

        Set-TQConfigMock -MetricsDir $metricsDir -TrendDir (Join-Path $TestDrive 'tq05-no-campaigns')

        $alerts = @(Get-SPGovernanceAlerts -LookbackDays 30)
        $alerts.Count | Should -Be 0
    }
}
