<#
.SYNOPSIS
    Tests for SP.CampaignSeries -- the V4c recurring-series derivation layer.

    Covers Get-SPCampaignSeriesKey (temporal-token stripping + spacing/separator/case
    robust normalization) and Group-SPCampaignSeries (deterministic clustering, opt-in
    near-match consolidation, override guards).

    CSK-01: module imports + both commands exist
    CSK-02: the 4 spacing/separator variants of 'Campaign - 2026-06-30' share a NormalizedStem
    CSK-03: ISO datetime -> Daily, token fully stripped
    CSK-04: quarter variants -> Quarterly, same stem
    CSK-05: numeric year-month -> Monthly
    CSK-06: 'Jun 2026' / 'June 2026' -> Monthly, same stem
    CSK-07: W23 / 'Week 23' -> Weekly
    CSK-08: bare trailing year -> Annual
    CSK-09: no-temporal name -> Unknown, stem = normalized whole name
    CSK-10: case-insensitive grouping
    CSK-11: Group-SPCampaignSeries clusters a mixed list deterministically
    CSK-12: override -SeriesStem / -SeriesPattern
    CSK-13: -SimilarityThreshold default OFF vs ON (typo merge)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Audit
}

Describe 'CSK-01 module + commands' {
    It 'exports Get-SPCampaignSeriesKey and Group-SPCampaignSeries' {
        (Get-Command Get-SPCampaignSeriesKey -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        (Get-Command Group-SPCampaignSeries  -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
    }
}

Describe 'CSK-02 spacing/separator robustness' {
    It 'collapses 4 hand-spacing variants to the same NormalizedStem' {
        $variants = @(
            'Campaign - 2026-06-30',
            'Campaign -2026-06-30',
            'Campaign-  2026-06-30',
            'Campaign  -  2026-06-30'
        )
        $norms = foreach ($v in $variants) {
            $r = Get-SPCampaignSeriesKey -Name $v
            $r.Success | Should -BeTrue
            $r.Data.NormalizedStem
        }
        $uniq = @($norms | Select-Object -Unique)
        $uniq.Count | Should -Be 1
        $uniq[0] | Should -Be 'campaign'
    }
}

Describe 'CSK-03 ISO datetime' {
    It 'classifies a full ISO datetime as Daily and strips the token' {
        $r = Get-SPCampaignSeriesKey -Name 'Daily Cert 2026-06-30T23:29:02Z'
        $r.Success | Should -BeTrue
        $r.Data.PeriodType | Should -Be 'Daily'
        $r.Data.PeriodToken | Should -Be '2026-06-30T23:29:02Z'
        $r.Data.NormalizedStem | Should -Be 'daily cert'
        $r.Data.SeriesStem | Should -Not -Match '\d'
    }
}

Describe 'CSK-04 quarter variants' {
    It 'classifies every quarter variant as Quarterly with the same base stem' {
        $variants = @(
            'Access Review - 1Q2026',
            'Access Review - Q1 2026',
            'Access Review - 2026 Q1',
            'Access Review - Q1-2026'
        )
        $norms = foreach ($v in $variants) {
            $r = Get-SPCampaignSeriesKey -Name $v
            $r.Data.PeriodType | Should -Be 'Quarterly'
            $r.Data.NormalizedStem
        }
        $uniq = @($norms | Select-Object -Unique)
        $uniq.Count | Should -Be 1
        $uniq[0] | Should -Be 'access review'
    }
}

Describe 'CSK-05 numeric year-month' {
    It 'classifies 2026-06 as Monthly' {
        $r = Get-SPCampaignSeriesKey -Name 'Monthly Access - 2026-06'
        $r.Data.PeriodType | Should -Be 'Monthly'
        $r.Data.NormalizedStem | Should -Be 'monthly access'
    }
}

Describe 'CSK-06 month-name + year' {
    It 'treats Jun 2026 and June 2026 as the same Monthly series' {
        $a = Get-SPCampaignSeriesKey -Name 'Access - Jun 2026'
        $b = Get-SPCampaignSeriesKey -Name 'Access - June 2026'
        $a.Data.PeriodType | Should -Be 'Monthly'
        $b.Data.PeriodType | Should -Be 'Monthly'
        $a.Data.NormalizedStem | Should -Be $b.Data.NormalizedStem
        $a.Data.NormalizedStem | Should -Be 'access'
    }
}

Describe 'CSK-07 week' {
    It 'treats W23 and Week 23 as the same Weekly series' {
        $a = Get-SPCampaignSeriesKey -Name 'Sprint W23'
        $b = Get-SPCampaignSeriesKey -Name 'Sprint Week 23'
        $a.Data.PeriodType | Should -Be 'Weekly'
        $b.Data.PeriodType | Should -Be 'Weekly'
        $a.Data.NormalizedStem | Should -Be $b.Data.NormalizedStem
        $a.Data.NormalizedStem | Should -Be 'sprint'
    }
}

Describe 'CSK-08 trailing year' {
    It 'classifies a bare trailing year as Annual' {
        $r = Get-SPCampaignSeriesKey -Name 'Annual Review 2026'
        $r.Data.PeriodType | Should -Be 'Annual'
        $r.Data.PeriodToken | Should -Be '2026'
        $r.Data.NormalizedStem | Should -Be 'annual review'
    }
}

Describe 'CSK-09 no temporal token' {
    It 'returns Unknown and uses the normalized whole name as stem' {
        $r = Get-SPCampaignSeriesKey -Name 'Disconnected App Review'
        $r.Data.PeriodType | Should -Be 'Unknown'
        $r.Data.Confidence | Should -Be 'None'
        $r.Data.PeriodToken | Should -Be ''
        $r.Data.NormalizedStem | Should -Be 'disconnected app review'
    }
}

Describe 'CSK-10 case-insensitive grouping' {
    It 'groups an upper-cased variant with the lower-cased one' {
        $a = Get-SPCampaignSeriesKey -Name 'CAMPAIGN - 2026-06-30'
        $b = Get-SPCampaignSeriesKey -Name 'campaign - 2026-06-29'
        $a.Data.NormalizedStem | Should -Be $b.Data.NormalizedStem
        $a.Data.SeriesStem | Should -Be 'CAMPAIGN'
    }
}

Describe 'CSK-11 Group-SPCampaignSeries clustering' {
    It 'clusters a mixed list with correct Members/Count and is deterministic' {
        $camps = @(
            [PSCustomObject]@{ id = 'c1'; Name = 'Access Review - 2026-06-28' },
            [PSCustomObject]@{ id = 'c2'; Name = 'Access Review - 2026-06-29' },
            [PSCustomObject]@{ id = 'c3'; Name = 'Finance Cert - Q1 2026' },
            [PSCustomObject]@{ id = 'c4'; Name = 'Finance Cert - Q2 2026' },
            [PSCustomObject]@{ id = 'c5'; Name = 'Disconnected App Review' }
        )
        $r1 = Group-SPCampaignSeries -Campaigns $camps
        $r1.Success | Should -BeTrue
        $r1.Data.Count | Should -Be 3

        $access = $r1.Data | Where-Object { $_.NormalizedStem -eq 'access review' }
        $access.Count | Should -Be 2
        $access.PeriodType | Should -Be 'Daily'
        @($access.Members | ForEach-Object { $_.id }) | Should -Be @('c1', 'c2')

        $finance = $r1.Data | Where-Object { $_.NormalizedStem -eq 'finance cert' }
        $finance.Count | Should -Be 2
        $finance.PeriodType | Should -Be 'Quarterly'

        # deterministic: same input -> identical cluster stems + counts on a second run
        $r2 = Group-SPCampaignSeries -Campaigns $camps
        @($r2.Data | ForEach-Object { "$($_.NormalizedStem):$($_.Count)" }) |
            Should -Be @($r1.Data | ForEach-Object { "$($_.NormalizedStem):$($_.Count)" })
    }

    It 'accepts an empty collection' {
        $r = Group-SPCampaignSeries -Campaigns @()
        $r.Success | Should -BeTrue
        @($r.Data).Count | Should -Be 0
    }
}

Describe 'CSK-12 override guards' {
    It 'honors an explicit -SeriesStem' {
        $r = Get-SPCampaignSeriesKey -Name 'Weird Name 2026-06-30' -SeriesStem 'Custom Family'
        $r.Success | Should -BeTrue
        $r.Data.SeriesStem | Should -Be 'Custom Family'
        $r.Data.NormalizedStem | Should -Be 'custom family'
        $r.Data.Confidence | Should -Be 'High'
    }
    It 'honors an explicit -SeriesPattern' {
        $r = Get-SPCampaignSeriesKey -Name 'Build 4471 Review' -SeriesPattern '\d{4}'
        $r.Success | Should -BeTrue
        $r.Data.PeriodToken | Should -Be '4471'
        $r.Data.NormalizedStem | Should -Be 'build review'
        $r.Data.Confidence | Should -Be 'High'
    }
    It 'returns an Error envelope on a bad -SeriesPattern regex' {
        $r = Get-SPCampaignSeriesKey -Name 'Anything' -SeriesPattern '([unterminated'
        $r.Success | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }
}

Describe 'CSK-13 opt-in similarity threshold' {
    It 'keeps a typo separate when threshold is OFF (default 0)' {
        $camps = @(
            [PSCustomObject]@{ id = 'a'; Name = 'Campaign' },
            [PSCustomObject]@{ id = 'b'; Name = 'Campagin' }
        )
        $r = Group-SPCampaignSeries -Campaigns $camps
        $r.Success | Should -BeTrue
        $r.Data.Count | Should -Be 2
    }
    It 'merges a typo when threshold is ON' {
        $camps = @(
            [PSCustomObject]@{ id = 'a'; Name = 'Campaign' },
            [PSCustomObject]@{ id = 'b'; Name = 'Campagin' }
        )
        $r = Group-SPCampaignSeries -Campaigns $camps -SimilarityThreshold 0.3
        $r.Success | Should -BeTrue
        $r.Data.Count | Should -Be 1
        $r.Data[0].Count | Should -Be 2
    }
}
