<#
.SYNOPSIS
    Unit tests for Export-SPGovernanceDashboardHtml (Phase 5).
    DH-01: Output file is created
    DH-02: HTML contains DOCTYPE and charset
    DH-03: KPI cards render with direction indicators
    DH-04: Sparkline SVG elements present in output
    DH-05: Alert callouts render
    DH-06: All dynamic content is HTML-encoded
    DH-07: Returns Success=$true with file path
    DH-08: Handles null KPIs gracefully (no throw)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # Standard dashboard data for most tests
    function New-DHTestDashboardData {
        return @{
            CapturedAt = (Get-Date '2026-06-12T14:00:00')
            Period     = 'Last30Days'
            KPIs = @{
                MaturityScore      = @{ Value = 3.2;     Direction = 'Up';   Delta = '+0.3';   Period = '30d' }
                ActiveCampaigns    = @{ Value = 5;       Direction = 'Flat'; Delta = '0';      Period = '30d' }
                PrivApprovalRate   = @{ Value = '12.4%'; Direction = 'Down'; Delta = '-2.1%';  Period = '30d' }
                ReviewerCompletion = @{ Value = '78.5%'; Direction = 'Up';   Delta = '+5.2%';  Period = '30d' }
                StaleAccessCount   = @{ Value = 142;     Direction = 'Down'; Delta = '-18';    Period = '30d' }
            }
            Sparklines = @{
                MaturityScore    = @(2.8, 2.9, 3.0, 3.0, 3.1, 3.2)
                PrivApprovalRate = @(14.5, 13.8, 13.0, 12.4)
            }
            Alerts = @(
                @{ Severity = 'Amber'; Metric = 'staleAccess'; Message = 'Stale access items rose from 120 to 142 (+18%) over 30 days' }
                @{ Severity = 'Red';   Metric = 'rubberStamp'; Message = 'Rubber-stamp rate above 25% threshold' }
            )
            Campaigns = @{
                Completed = @{ Count = 3; AvgDays = 12.5; Trend = 'Improving' }
                Active    = @{ Count = 5; Overdue = 1 }
            }
        }
    }

    function New-DHTestPeriodComparison {
        return @{
            'maturity.overallScore' = @{ Before = 2.9; After = 3.2; Delta = '+0.3'; Direction = 'Up' }
            'staleAccess.count'     = @{ Before = 120; After = 142; Delta = '+22';  Direction = 'Down' }
        }
    }
}

Describe "DH-01: Output file is created" {
    It "Creates an HTML file in the specified output directory" {
        $outDir = Join-Path $TestDrive 'dh01'
        $data   = New-DHTestDashboardData

        $result = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir

        $result.Success | Should -Be $true
        $result.Data    | Should -Not -BeNullOrEmpty
        Test-Path $result.Data | Should -Be $true
        $result.Data | Should -BeLike '*.html'
    }
}

Describe "DH-02: HTML contains DOCTYPE and charset" {
    It "Output starts with DOCTYPE and includes charset meta tag" {
        $outDir = Join-Path $TestDrive 'dh02'
        $data   = New-DHTestDashboardData

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir
        $content = [System.IO.File]::ReadAllText($result.Data)

        $content | Should -Match '<!DOCTYPE html>'
        $content | Should -Match "charset='utf-8'"
    }
}

Describe "DH-03: KPI cards render with direction indicators" {
    It "Renders KPI cards with CSS triangle direction indicators" {
        $outDir = Join-Path $TestDrive 'dh03'
        $data   = New-DHTestDashboardData

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir
        $content = [System.IO.File]::ReadAllText($result.Data)

        # Up arrow: border-bottom (CSS triangle)
        $content | Should -Match 'border-bottom:8px solid'
        # Down arrow: border-top (CSS triangle)
        $content | Should -Match 'border-top:8px solid'
        # Flat indicator: width:12px;height:3px
        $content | Should -Match 'width:12px;height:3px'

        # KPI values present
        $content | Should -Match '3\.2'
        $content | Should -Match '12\.4%'
        $content | Should -Match '78\.5%'
        $content | Should -Match '142'
    }
}

Describe "DH-04: Sparkline SVG elements present in output" {
    It "Renders SVG sparkline bar charts for each metric with sparkline data" {
        $outDir = Join-Path $TestDrive 'dh04'
        $data   = New-DHTestDashboardData

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir
        $content = [System.IO.File]::ReadAllText($result.Data)

        # SVG elements present
        $content | Should -Match '<svg'
        $content | Should -Match '<rect'
        $content | Should -Match '</svg>'

        # Metric labels present
        $content | Should -Match 'MaturityScore'
        $content | Should -Match 'PrivApprovalRate'
    }
}

Describe "DH-05: Alert callouts render" {
    It "Renders amber and red alert callout boxes" {
        $outDir = Join-Path $TestDrive 'dh05'
        $data   = New-DHTestDashboardData

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir
        $content = [System.IO.File]::ReadAllText($result.Data)

        # Amber alert styling
        $content | Should -Match '#fff7e6'
        $content | Should -Match '#ffd97a'

        # Red alert styling
        $content | Should -Match '#fdecec'
        $content | Should -Match '#f5c6cb'

        # Alert messages
        $content | Should -Match 'Stale access items'
        $content | Should -Match 'Rubber-stamp rate'
    }

    It "Renders healthy message when no alerts" {
        $outDir = Join-Path $TestDrive 'dh05-healthy'
        $data   = New-DHTestDashboardData
        $data.Alerts = @()

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir
        $content = [System.IO.File]::ReadAllText($result.Data)

        $content | Should -Match 'All metrics within normal range'
    }
}

Describe "DH-06: All dynamic content is HTML-encoded" {
    It "HTML-encodes user-controlled values to prevent XSS" {
        $outDir = Join-Path $TestDrive 'dh06'
        $data   = New-DHTestDashboardData
        # Inject XSS payload into a KPI value
        $data.KPIs.MaturityScore.Value = '<script>alert(1)</script>'
        $data.Alerts = @(
            @{ Severity = 'Amber'; Metric = 'test'; Message = '<img onerror=alert(1) src=x>' }
        )

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir -Title '<b>evil</b>'
        $content = [System.IO.File]::ReadAllText($result.Data)

        # Raw script tags must NOT appear as executable HTML elements
        $content | Should -Not -Match '<script>'
        # The img tag should be encoded so it is not a real HTML tag
        $content | Should -Not -Match '<img '
        # Encoded versions should appear as safe text content
        $content | Should -Match '&lt;script&gt;'
        $content | Should -Match '&lt;img'
    }
}

Describe "DH-07: Returns Success=true with file path" {
    It "Returns hashtable with Success, Data (file path), and null Error" {
        $outDir = Join-Path $TestDrive 'dh07'
        $data   = New-DHTestDashboardData

        $result = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir

        $result              | Should -BeOfType [hashtable]
        $result.Success      | Should -Be $true
        $result.Data         | Should -Not -BeNullOrEmpty
        $result.Error        | Should -BeNullOrEmpty
        $result.Data         | Should -BeLike "*GovernanceDashboard-*.html"
    }
}

Describe "DH-08: Handles null KPIs gracefully (no throw)" {
    It "Does not throw when KPIs is null" {
        $outDir = Join-Path $TestDrive 'dh08-null'
        $data   = @{
            CapturedAt = (Get-Date)
            Period     = 'Last30Days'
            KPIs       = $null
            Sparklines = $null
            Alerts     = $null
            Campaigns  = $null
        }

        $result = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir

        $result.Success | Should -Be $true
        $result.Data    | Should -Not -BeNullOrEmpty
        Test-Path $result.Data | Should -Be $true

        $content = [System.IO.File]::ReadAllText($result.Data)
        $content | Should -Match 'No trend data available'
    }

    It "Does not throw when DashboardData has empty KPIs hashtable" {
        $outDir = Join-Path $TestDrive 'dh08-empty'
        $data   = @{
            CapturedAt = (Get-Date)
            Period     = 'Last30Days'
            KPIs       = @{}
            Sparklines = @{}
            Alerts     = @()
            Campaigns  = @{}
        }

        $result = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir

        $result.Success | Should -Be $true
        $result.Data    | Should -Not -BeNullOrEmpty

        $content = [System.IO.File]::ReadAllText($result.Data)
        $content | Should -Match 'No trend data available'
    }

    It "Renders period comparison table when provided" {
        $outDir     = Join-Path $TestDrive 'dh08-comp'
        $data       = New-DHTestDashboardData
        $comparison = New-DHTestPeriodComparison

        $result  = Export-SPGovernanceDashboardHtml -DashboardData $data -OutputPath $outDir -PeriodComparison $comparison
        $content = [System.IO.File]::ReadAllText($result.Data)

        $content | Should -Match 'Period Comparison'
        $content | Should -Match 'maturity\.overallScore'
        $content | Should -Match 'staleAccess\.count'
        # Direction indicators in comparison table
        $content | Should -Match 'border-bottom:8px solid'
    }
}
