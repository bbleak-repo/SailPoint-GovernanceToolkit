<#
.SYNOPSIS
    Unit tests for SP.ReviewerAccountability -- stalled reviewer detection.
    RA-01: single-campaign stall detected
    RA-02: multi-campaign stall detected (severity Red)
    RA-03: progressing reviewers NOT flagged
    RA-04: respects ConsecutiveDays threshold
    RA-05: empty when no trend data exists
    RA-06: empty when all reviewers progressing
    RA-07: HTML report renders RED section for multi-campaign
    RA-08: HTML report renders Amber section for single-campaign
    RA-09: HTML healthy message when no stalls
    RA-10: severity Red for multi, Amber for single
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Audit

    function New-TestTrendFile {
        <#
        .SYNOPSIS
            Creates a synthetic campaign trend JSONL file for testing.
        .PARAMETER Dir
            Directory to write the file into.
        .PARAMETER CampaignId
            Unique campaign identifier.
        .PARAMETER CampaignName
            Human-readable campaign name.
        .PARAMETER DailyCaptures
            Array of hashtables: @{ Day=<int days ago>; Reviewers=@( @{Reviewer; Completion} ) }
        #>
        param(
            [string]$Dir,
            [string]$CampaignId,
            [string]$CampaignName,
            [object[]]$DailyCaptures
        )

        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($cap in $DailyCaptures) {
            $ts = (Get-Date).AddDays(-$cap.Day).ToUniversalTime().ToString('o')
            $reviewerArr = @()
            foreach ($rv in $cap.Reviewers) {
                $reviewerArr += @{
                    reviewer   = $rv.Reviewer
                    completion = $rv.Completion
                }
            }
            $rec = @{
                timestamp    = $ts
                campaignId   = $CampaignId
                campaignName = $CampaignName
                status       = 'ACTIVE'
                reviewers    = $reviewerArr
            }
            $lines.Add(($rec | ConvertTo-Json -Compress -Depth 5))
        }

        $filePath = Join-Path $Dir "$CampaignId.jsonl"
        [System.IO.File]::WriteAllLines($filePath, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        return $filePath
    }
}

Describe "RA-01: Detects single-campaign stall" {
    It "Flags ReviewerA when completion is flat for ConsecutiveDays" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra01-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # 5 daily captures, ReviewerA stuck at 30%
            $captures = @()
            for ($d = 5; $d -ge 1; $d--) {
                $captures += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-01' -CampaignName 'Campaign One' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $stalled = @($result.Data.StalledReviewers)
            $stalled.Count | Should -BeGreaterOrEqual 1
            $match = $stalled | Where-Object { $_.Reviewer -eq 'ReviewerA' }
            $match | Should -Not -BeNullOrEmpty
            $match.CampaignCount | Should -Be 1
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-02: Detects multi-campaign stall" {
    It "Flags ReviewerA stalled in 2 campaigns with severity Red" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra02-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $captures = @()
            for ($d = 5; $d -ge 1; $d--) {
                $captures += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-01' -CampaignName 'Campaign One' -DailyCaptures $captures
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-02' -CampaignName 'Campaign Two' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $match = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerA' }
            $match | Should -Not -BeNullOrEmpty
            $match.CampaignCount | Should -Be 2
            $match.Severity | Should -Be 'Red'
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-03: Does NOT flag progressing reviewers" {
    It "ReviewerB with increasing completion is not in the stalled list" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra03-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $captures = @()
            for ($d = 5; $d -ge 1; $d--) {
                $pct = 20 + ((5 - $d) * 15)   # 20, 35, 50, 65, 80
                $captures += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerB'; Completion = $pct } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-03' -CampaignName 'Campaign Three' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $match = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerB' }
            $match | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-04: Respects ConsecutiveDays threshold" {
    It "Does not flag when stall days < threshold" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra04-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # Only 2 days of data, threshold=3
            $captures = @(
                @{ Day = 2; Reviewers = @( @{ Reviewer = 'ReviewerC'; Completion = 50 } ) }
                @{ Day = 1; Reviewers = @( @{ Reviewer = 'ReviewerC'; Completion = 50 } ) }
            )
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-04' -CampaignName 'Campaign Four' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $match = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerC' }
            $match | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-05: Returns empty when no trend data exists" {
    It "Returns empty stalled list for an empty directory" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra05-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $result.Data.StalledReviewers.Count | Should -Be 0
            $result.Data.Summary.Total | Should -Be 0
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-06: Returns empty when all reviewers progressing" {
    It "No stalls when all reviewers increase completion each day" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra06-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $captures = @()
            for ($d = 5; $d -ge 1; $d--) {
                $pctA = 10 + ((5 - $d) * 10)
                $pctB = 5  + ((5 - $d) * 20)
                $captures += @{
                    Day = $d
                    Reviewers = @(
                        @{ Reviewer = 'ReviewerX'; Completion = $pctA }
                        @{ Reviewer = 'ReviewerY'; Completion = $pctB }
                    )
                }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-06' -CampaignName 'Campaign Six' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $result.Data.StalledReviewers.Count | Should -Be 0
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-07: HTML report renders RED section for multi-campaign" {
    It "HTML contains Multi-Campaign heading and the reviewer name" {
        $stalledData = @{
            Summary = @{ Total = 1; MultiCampaign = 1; SingleCampaign = 0; MaxConsecutiveDays = 5 }
            StalledReviewers = @(
                @{
                    Reviewer      = 'ReviewerA'
                    CampaignCount = 2
                    StalledDays   = 5
                    Severity      = 'Red'
                    Campaigns     = @(
                        @{ CampaignName = 'Campaign One'; CampaignId = 'c1'; StalledDays = 5; Completion = 30; LastCapture = '2026-06-10'; StallStartDate = '2026-06-05' }
                        @{ CampaignName = 'Campaign Two'; CampaignId = 'c2'; StalledDays = 5; Completion = 20; LastCapture = '2026-06-10'; StallStartDate = '2026-06-05' }
                    )
                    Recommendation = 'Reviewer stalled in 2 campaigns for 5+ days -- likely OOO/departed. Consider reassignment.'
                }
            )
        }

        $tmpHtml = Join-Path ([System.IO.Path]::GetTempPath()) "ra07-$([guid]::NewGuid().ToString('N')).html"
        try {
            $result = Export-SPStalledReviewerHtml -StalledData $stalledData -OutputPath $tmpHtml
            $result.Success | Should -Be $true
            $html = [System.IO.File]::ReadAllText($result.Data)
            $html | Should -Match 'Multi-Campaign'
            $html | Should -Match 'ReviewerA'
        }
        finally {
            Remove-Item -Path $tmpHtml -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-08: HTML report renders Amber section for single-campaign" {
    It "HTML contains Single-Campaign heading and the reviewer name" {
        $stalledData = @{
            Summary = @{ Total = 1; MultiCampaign = 0; SingleCampaign = 1; MaxConsecutiveDays = 4 }
            StalledReviewers = @(
                @{
                    Reviewer      = 'ReviewerD'
                    CampaignCount = 1
                    StalledDays   = 4
                    Severity      = 'Amber'
                    Campaigns     = @(
                        @{ CampaignName = 'Campaign Only'; CampaignId = 'co'; StalledDays = 4; Completion = 45; LastCapture = '2026-06-10'; StallStartDate = '2026-06-06' }
                    )
                    Recommendation = 'Reviewer stalled in Campaign Only for 4+ days. Follow up or reassign.'
                }
            )
        }

        $tmpHtml = Join-Path ([System.IO.Path]::GetTempPath()) "ra08-$([guid]::NewGuid().ToString('N')).html"
        try {
            $result = Export-SPStalledReviewerHtml -StalledData $stalledData -OutputPath $tmpHtml
            $result.Success | Should -Be $true
            $html = [System.IO.File]::ReadAllText($result.Data)
            $html | Should -Match 'Single-Campaign'
            $html | Should -Match 'ReviewerD'
        }
        finally {
            Remove-Item -Path $tmpHtml -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-09: HTML report shows healthy message when no stalls" {
    It "HTML contains the all-clear message" {
        $stalledData = @{
            Summary = @{ Total = 0; MultiCampaign = 0; SingleCampaign = 0; MaxConsecutiveDays = 0 }
            StalledReviewers = @()
        }

        $tmpHtml = Join-Path ([System.IO.Path]::GetTempPath()) "ra09-$([guid]::NewGuid().ToString('N')).html"
        try {
            $result = Export-SPStalledReviewerHtml -StalledData $stalledData -OutputPath $tmpHtml
            $result.Success | Should -Be $true
            $html = [System.IO.File]::ReadAllText($result.Data)
            $html | Should -Match 'All reviewers are making progress'
        }
        finally {
            Remove-Item -Path $tmpHtml -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-10: Severity is Red for multi, Amber for single" {
    It "Multi-campaign stall is Red, single-campaign stall is Amber" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra10-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # ReviewerA stalled in 2 campaigns (Red)
            $capsA = @()
            for ($d = 5; $d -ge 1; $d--) {
                $capsA += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-r1' -CampaignName 'Camp R1' -DailyCaptures $capsA
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-r2' -CampaignName 'Camp R2' -DailyCaptures $capsA

            # ReviewerE stalled in 1 campaign (Amber)
            $capsE = @()
            for ($d = 5; $d -ge 1; $d--) {
                $capsE += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerE'; Completion = 50 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-e1' -CampaignName 'Camp E1' -DailyCaptures $capsE

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true

            $matchA = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerA' }
            $matchA.Severity | Should -Be 'Red'

            $matchE = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerE' }
            $matchE.Severity | Should -Be 'Amber'
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-11: Window looks at the LAST N captures (recent progress not flagged)" {
    It "Does NOT flag a reviewer who stalled in the distant past but is progressing recently" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra11-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # 8 daily captures: stalled (30) days 8..4, then progressing 40/50/60 days 3..1.
            # Window = last Min(ConsecutiveDays+2, count) = Min(5,8) = 5 captures (days 5,4,3,2,1)
            # = 30,30,40,50,60 -> shows progress -> NOT stalled.
            $captures = @(
                @{ Day = 8; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
                @{ Day = 7; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
                @{ Day = 6; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
                @{ Day = 5; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
                @{ Day = 4; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 30 } ) }
                @{ Day = 3; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 40 } ) }
                @{ Day = 2; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 50 } ) }
                @{ Day = 1; Reviewers = @( @{ Reviewer = 'ReviewerA'; Completion = 60 } ) }
            )
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-11' -CampaignName 'Campaign Eleven' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $match = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerA' }
            $match | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-12: Finished-but-unsigned reviewer is NOT flagged stalled" {
    It "Does NOT flag a reviewer flat at 100% completion" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra12-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # 5 daily captures all at 100% (decisions done, just not signed off) -> flat, but finished.
            $captures = @()
            for ($d = 5; $d -ge 1; $d--) {
                $captures += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerF'; Completion = 100 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-12' -CampaignName 'Campaign Twelve' -DailyCaptures $captures

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $match = $result.Data.StalledReviewers | Where-Object { $_.Reviewer -eq 'ReviewerF' }
            $match | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "RA-13: Multi-campaign reviewer sorts before single-campaign with more stalled days" {
    It "ReviewerP (CampaignCount 2) sorts ahead of ReviewerQ (more StalledDays, 1 campaign)" {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "ra13-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            # ReviewerP: 2 campaigns, flat 30% over 5 days -> CampaignCount 2, StalledDays ~4
            $capsP = @()
            for ($d = 5; $d -ge 1; $d--) {
                $capsP += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerP'; Completion = 30 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-p1' -CampaignName 'Camp P1' -DailyCaptures $capsP
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-p2' -CampaignName 'Camp P2' -DailyCaptures $capsP

            # ReviewerQ: 1 campaign, flat 50% over 8 days -> CampaignCount 1, StalledDays ~7 (more)
            $capsQ = @()
            for ($d = 8; $d -ge 1; $d--) {
                $capsQ += @{ Day = $d; Reviewers = @( @{ Reviewer = 'ReviewerQ'; Completion = 50 } ) }
            }
            New-TestTrendFile -Dir $tmpDir -CampaignId 'camp-q1' -CampaignName 'Camp Q1' -DailyCaptures $capsQ

            $result = Get-SPStalledReviewers -TrendDir $tmpDir -ConsecutiveDays 3 -DaysBack 14
            $result.Success | Should -Be $true
            $result.Data.StalledReviewers[0].Reviewer | Should -Be 'ReviewerP'
        }
        finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
