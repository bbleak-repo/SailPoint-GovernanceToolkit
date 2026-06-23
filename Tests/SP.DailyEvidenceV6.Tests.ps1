<#
.SYNOPSIS
    Tests for v6 daily-evidence metrics visualization report.

    DV6-01: v6 script parses with no errors
    DV6-02: v6 produces HTML from synthetic daily-metrics.jsonl (7 days)
    DV6-03: v6 handles single-day data (insufficient data banner)
    DV6-04: v6 deduplicates records by captureDate (latest timestamp wins)
    DV6-05: v6 sorts reviewers alphabetically
    DV6-06: v6 HTML contains no ISC API or rubber-stamp references
    DV6-07: v6 CampaignNameContains filter works correctly
    DV6-08: v6 cross-campaign risk matrix sorted by date descending
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core

    $script:V6Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV6.ps1'
    $script:ToolkitRoot = Split-Path $PSScriptRoot -Parent
    $script:MetricsDir = Join-Path $script:ToolkitRoot (Join-Path 'Audit' 'metrics')
    $script:JsonlPath = Join-Path $script:MetricsDir 'daily-metrics.jsonl'
    $script:OutputDir = Join-Path $script:ToolkitRoot (Join-Path 'Audit' 'daily-evidence')

    # Backup existing JSONL if present
    $script:OriginalJsonl = $null
    if (Test-Path $script:JsonlPath) {
        $script:OriginalJsonl = Get-Content $script:JsonlPath -Raw
    }

    # Ensure directories exist
    if (-not (Test-Path $script:MetricsDir)) {
        New-Item -ItemType Directory -Path $script:MetricsDir -Force | Out-Null
    }

    function New-V6TestRecord {
        param(
            [string]$CaptureDate,
            [string]$CaptureTimestamp,
            [string]$CampaignId = "camp-$CaptureDate",
            [string]$CampaignName = "Daily Test $CaptureDate",
            [double]$CompletionPct = 50.0,
            [int]$Total = 100,
            [int]$Approved = 45,
            [int]$Revoked = 5,
            [int]$Pending = 50,
            [string[]]$ReviewerNames = @('Alice','Bob','Carol')
        )
        if ([string]::IsNullOrWhiteSpace($CaptureTimestamp)) {
            $CaptureTimestamp = "${CaptureDate}T12:00:00-04:00"
        }
        $reviewers = @()
        $rvCount = $ReviewerNames.Count
        foreach ($rn in $ReviewerNames) {
            $reviewers += [ordered]@{
                name          = $rn
                identityId    = "id-$($rn.ToLower())"
                email         = "$($rn.ToLower())@test.com"
                classification = 'Primary'
                total         = [int]($Total / $rvCount)
                approved      = [int]($Approved / $rvCount)
                revoked       = [int]($Revoked / $rvCount)
                pending       = [int]($Pending / $rvCount)
                completionPct = $CompletionPct
                signed        = ($CompletionPct -ge 100)
                phase         = if ($CompletionPct -ge 100) { 'SIGNED' } else { 'ACTIVE' }
            }
        }
        return [ordered]@{
            captureDate      = $CaptureDate
            captureTimestamp  = $CaptureTimestamp
            correlationId    = [guid]::NewGuid().ToString()
            campaign         = [ordered]@{
                id        = $CampaignId
                name      = $CampaignName
                status    = 'ACTIVE'
                created   = "${CaptureDate}T00:00:00Z"
                deadline  = "${CaptureDate}T23:59:59Z"
                completed = $null
            }
            summary          = [ordered]@{
                totalItems              = $Total
                approved                = $Approved
                revoked                 = $Revoked
                pending                 = $Pending
                completionPct           = $CompletionPct
                completionPctByReviewer = [math]::Round($CompletionPct * 0.9, 1)
                reviewersTotal          = $rvCount
                reviewersSigned         = if ($CompletionPct -ge 100) { $rvCount } else { 0 }
                reviewersNotStarted     = 0
                reviewersInProgress     = if ($CompletionPct -lt 100) { $rvCount } else { 0 }
                privilegedTotal         = 20
                privilegedApproved      = [int](20 * $CompletionPct / 100 * 0.9)
                privilegedRevoked       = [int](20 * $CompletionPct / 100 * 0.1)
                privilegedPending       = [int](20 * (100 - $CompletionPct) / 100)
                distinctIdentities      = 50
                distinctSources         = 2
                revokedWithRemediation  = $Revoked
                revokedPendingRemediation = 0
            }
            reviewers        = $reviewers
            sources          = @(
                [ordered]@{ name='TestAD'; id='src-1'; total=[int]($Total*0.7); approved=[int]($Approved*0.7); revoked=[int]($Revoked*0.7); pending=[int]($Pending*0.7) }
                [ordered]@{ name='TestSAP'; id='src-2'; total=[int]($Total*0.3); approved=[int]($Approved*0.3); revoked=[int]($Revoked*0.3); pending=[int]($Pending*0.3) }
            )
            diff             = [ordered]@{
                hasPrior          = $false
                priorCampaignName = ''
                scopeAdded        = 0
                scopeRemoved      = 0
                scopeChanged      = 0
                newlyApprovedCount = 0
                revokedCount      = 0
            }
        }
    }

    function Write-V6TestJsonl {
        param([object[]]$Records)
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = @()
        foreach ($rec in $Records) {
            $lines += ($rec | ConvertTo-Json -Depth 10 -Compress)
        }
        [System.IO.File]::WriteAllLines($script:JsonlPath, $lines, $utf8)
    }

    function Invoke-V6 {
        param([string]$ExtraArgs = '')
        $cmd = "& '$($script:V6Path)' $ExtraArgs 2>&1"
        return (& pwsh -NoProfile -Command $cmd)
    }

    function Get-LatestV6Html {
        return (Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }
}

AfterAll {
    # Restore original JSONL or remove test data
    if ($null -ne $script:OriginalJsonl) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:JsonlPath, $script:OriginalJsonl, $utf8)
    }
    elseif (Test-Path $script:JsonlPath) {
        Remove-Item $script:JsonlPath -Force -ErrorAction SilentlyContinue
    }

    # Clean up V6 HTML output files
    Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Describe "DV6-01: v6 script parses" {
    It "has no parse errors" {
        Test-Path $script:V6Path | Should -Be $true
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:V6Path, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe "DV6-02: v6 produces HTML from 7-day synthetic data" {
    BeforeAll {
        # Clean any prior V6 HTML
        Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $records = @()
        $baseDate = (Get-Date).AddDays(-6)
        for ($i = 0; $i -lt 7; $i++) {
            $dt = $baseDate.AddDays($i)
            $pct = 40 + ($i * 9)
            $approved = [int](100 * $pct / 100 * 0.9)
            $revoked = [int](100 * $pct / 100 * 0.1)
            $pending = 100 - $approved - $revoked
            $records += New-V6TestRecord -CaptureDate $dt.ToString('yyyy-MM-dd') `
                -CompletionPct $pct -Total 100 -Approved $approved -Revoked $revoked -Pending $pending
        }
        Write-V6TestJsonl -Records $records

        $script:V6Output02 = Invoke-V6 '-DaysBack 7 -OutputMode HTML'
        $script:V6Html02 = Get-LatestV6Html
    }

    It "produces an HTML file" {
        $script:V6Html02 | Should -Not -BeNullOrEmpty
        $script:V6Html02.Length | Should -BeGreaterThan 1000
    }

    It "HTML contains KPI banner" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Completion'
        $content | Should -Match 'Approved'
        $content | Should -Match 'Pending'
    }

    It "HTML contains Metric Trends section" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Metric Trends'
    }

    It "HTML contains Per-Reviewer Accountability" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Per-Reviewer Accountability'
    }

    It "HTML contains Risk Matrix" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Cross-Campaign Risk Matrix'
    }

    It "HTML contains Completion Projection" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Completion Projection'
    }

    It "HTML contains Heatmap" {
        $content = Get-Content $script:V6Html02.FullName -Raw
        $content | Should -Match 'Reviewer Activity Heatmap'
    }
}

Describe "DV6-03: v6 handles single-day data" {
    BeforeAll {
        Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $records = @(New-V6TestRecord -CaptureDate (Get-Date).ToString('yyyy-MM-dd') -CompletionPct 65)
        Write-V6TestJsonl -Records $records

        $script:V6Output03 = Invoke-V6 '-DaysBack 1 -OutputMode Both'
        $script:V6Html03 = Get-LatestV6Html
    }

    It "produces HTML even with 1 data point" {
        $script:V6Html03 | Should -Not -BeNullOrEmpty
    }

    It "HTML contains insufficient data banner" {
        $content = Get-Content $script:V6Html03.FullName -Raw
        $content | Should -Match 'Insufficient Trend Data'
    }

    It "console output shows single-point note" {
        $script:V6Output03 -join "`n" | Should -Match 'single-point'
    }
}

Describe "DV6-04: v6 deduplicates by captureDate" {
    BeforeAll {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $rec1 = New-V6TestRecord -CaptureDate $today -CaptureTimestamp "${today}T10:00:00-04:00" -CompletionPct 40
        $rec2 = New-V6TestRecord -CaptureDate $today -CaptureTimestamp "${today}T16:00:00-04:00" -CompletionPct 75
        Write-V6TestJsonl -Records @($rec1, $rec2)

        $script:V6Output04 = Invoke-V6 '-DaysBack 1 -OutputMode Both'
    }

    It "keeps only 1 data point after dedup" {
        $script:V6Output04 -join "`n" | Should -Match 'Built 1 daily data point'
    }

    It "kept the later timestamp record (75% completion)" {
        $script:V6Output04 -join "`n" | Should -Match '75%'
    }
}

Describe "DV6-05: v6 sorts reviewers alphabetically" {
    BeforeAll {
        Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $rec = New-V6TestRecord -CaptureDate (Get-Date).ToString('yyyy-MM-dd') `
            -ReviewerNames @('Zara','Michelle','Alice') -CompletionPct 60
        Write-V6TestJsonl -Records @($rec)

        Invoke-V6 '-DaysBack 1 -OutputMode HTML' | Out-Null
        $script:V6Html05 = Get-LatestV6Html
        $script:V6Html05Content = Get-Content $script:V6Html05.FullName -Raw
    }

    It "Alice appears before Michelle before Zara in the HTML" {
        $alicePos = $script:V6Html05Content.IndexOf('Alice')
        $michellePos = $script:V6Html05Content.IndexOf('Michelle')
        $zaraPos = $script:V6Html05Content.IndexOf('Zara')
        $alicePos | Should -BeLessThan $michellePos
        $michellePos | Should -BeLessThan $zaraPos
    }
}

Describe "DV6-06: v6 has no ISC API or rubber-stamp references" {
    It "script source has no API token handling" {
        $src = Get-Content $script:V6Path -Raw
        $src | Should -Not -Match '\-Token'
        $src | Should -Not -Match 'Invoke-RestMethod'
        $src | Should -Not -Match 'Invoke-WebRequest'
        $src | Should -Not -Match '/v3/campaigns'
        $src | Should -Not -Match '/beta/'
    }

    It "script source has no rubber-stamp references" {
        $src = Get-Content $script:V6Path -Raw
        $src | Should -Not -Match 'rubber.stamp'
        $src | Should -Not -Match 'rubberStamp'
        $src | Should -Not -Match 'RUBBER.STAMP'
    }
}

Describe "DV6-07: CampaignNameContains filter" {
    BeforeAll {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
        $rec1 = New-V6TestRecord -CaptureDate $today -CampaignName 'Q2 Privileged Review' -CompletionPct 70
        $rec2 = New-V6TestRecord -CaptureDate $yesterday -CampaignName 'Monthly SOX Audit' -CompletionPct 55
        Write-V6TestJsonl -Records @($rec1, $rec2)

        $script:V6Output07 = Invoke-V6 "-DaysBack 7 -CampaignNameContains 'Q2' -OutputMode Console"
    }

    It "loads only 1 record matching Q2" {
        $script:V6Output07 -join "`n" | Should -Match 'Loaded 1 record'
    }

    It "shows Q2 campaign name" {
        $script:V6Output07 -join "`n" | Should -Match 'Q2 Privileged Review'
    }
}

Describe "DV6-08: Cross-campaign risk matrix sorted by date descending" {
    BeforeAll {
        Get-ChildItem -Path $script:OutputDir -Filter 'daily-evidence-v6-*.html' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $records = @()
        $baseDate = (Get-Date).AddDays(-3)
        for ($i = 0; $i -lt 4; $i++) {
            $dt = $baseDate.AddDays($i)
            $records += New-V6TestRecord -CaptureDate $dt.ToString('yyyy-MM-dd') `
                -CampaignName "Daily Test $($dt.ToString('MMdd'))" -CompletionPct (50 + $i * 12)
        }
        Write-V6TestJsonl -Records $records

        Invoke-V6 '-DaysBack 7 -OutputMode HTML' | Out-Null
        $script:V6Html08 = Get-LatestV6Html
        $script:V6Html08Content = Get-Content $script:V6Html08.FullName -Raw
    }

    It "latest date appears first in risk matrix" {
        $latestLabel = (Get-Date).ToString('MM/dd')
        $earliestLabel = (Get-Date).AddDays(-3).ToString('MM/dd')
        # Find the Risk Matrix section, then check order within it
        $riskIdx = $script:V6Html08Content.IndexOf('Cross-Campaign Risk Matrix')
        $latestPos = $script:V6Html08Content.IndexOf($latestLabel, $riskIdx)
        $earliestPos = $script:V6Html08Content.IndexOf($earliestLabel, $riskIdx)
        $latestPos | Should -BeLessThan $earliestPos
    }
}
