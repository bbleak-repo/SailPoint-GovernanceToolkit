#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SERIES-READER -- Get-SPCachedCampaignSeries (V4c cache-IO layer).
.DESCRIPTION
    Covers CS-001..CS-007:
      CS-001  reads BOM'd meta files, derives series, groups name variances together.
      CS-002  orders instances chronologically by PeriodToken; stamps OrderIndex.
      CS-003  carries provenance (CapturedWhileActive / Unverified / SealReason / Status).
      CS-004  NO-API loaders return items (.jsonl) + sealed roster (.json) from disk.
      CS-005  MinInstances filter (default 2) drops one-off campaigns; override honored.
      CS-006  absent cache dir -> Success with empty Series (does not throw).
      CS-007  -SeriesStem / -SeriesPattern overrides + Quarterly chrono ordering.
    Cache fixtures are hand-authored into a TestDrive subdir; metas are written with
    -Encoding UTF8 (UTF-8 BOM) ON PURPOSE to prove the BOM-safe read.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    function New-CSCacheInstance {
        param(
            [string]$Dir,
            [string]$CampId,
            [string]$CampName,
            [string]$Status = 'COMPLETED',
            [string]$CachedAt = '2026-06-30T08:00:00.0000000+00:00',
            [bool]$IsPermanent = $true,
            [bool]$CapturedWhileActive = $true,
            [bool]$Unverified = $false,
            [string]$SealReason = $null,
            [object[]]$Items = @(),
            [object[]]$RosterEntries = @()
        )
        $safe = $CampId -replace '[^A-Za-z0-9_\-]', '_'
        $meta = [ordered]@{
            CampaignId          = $CampId
            CampaignName        = $CampName
            Status              = $Status
            CachedAt            = $CachedAt
            IsPermanent         = $IsPermanent
            CapturedWhileActive = $CapturedWhileActive
            Unverified          = $Unverified
            ItemCount           = @($Items).Count
            CertCount           = @($RosterEntries).Count
        }
        if ($null -ne $SealReason) { $meta['SealReason'] = $SealReason }
        # -Encoding UTF8 writes the UTF-8 BOM on purpose (proves BOM-safe read).
        $meta | ConvertTo-Json | Set-Content (Join-Path $Dir "items-$safe.meta.json") -Encoding UTF8

        $itemsPath = Join-Path $Dir "items-$safe.jsonl"
        if (@($Items).Count -gt 0) {
            $lines = foreach ($it in @($Items)) {
                @{ Item = $it; CertificationId = "$CampId-cert"; CertificationName = "$CampName Cert"; CampaignName = $CampName } | ConvertTo-Json -Compress -Depth 8
            }
            Set-Content -Path $itemsPath -Value $lines -Encoding UTF8
        }

        if (@($RosterEntries).Count -gt 0) {
            $roster = [ordered]@{ CampaignId = $CampId; CapturedWhileActive = $CapturedWhileActive; Entries = @($RosterEntries) }
            $roster | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Dir "roster-$safe.json") -Encoding UTF8
        }
    }
}

Describe "CS-001: derives series, collapses name spacing/separator variances" {
    BeforeAll {
        $script:dir1 = Join-Path $TestDrive 'cs001'
        New-Item -ItemType Directory -Path $script:dir1 -Force | Out-Null
        # Two daily instances with DIFFERENT human spacing around the dash -- must group.
        New-CSCacheInstance -Dir $script:dir1 -CampId 'd-1' -CampName 'Access Review - 2026-06-29' -CachedAt '2026-06-29T08:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir1 -CampId 'd-2' -CampName 'Access Review -2026-06-30'  -CachedAt '2026-06-30T08:00:00.0000000+00:00'
        $script:r1 = Get-SPCachedCampaignSeries -CachePath $script:dir1
    }
    It "succeeds" { $script:r1.Success | Should -BeTrue }
    It "finds exactly one series" { $script:r1.Data.SeriesCount | Should -Be 1 }
    It "groups both spacing-variant instances together" {
        $script:r1.Data.Series[0].InstanceCount | Should -Be 2
    }
    It "reports a Daily period type" { $script:r1.Data.Series[0].PeriodType | Should -Be 'Daily' }
    It "counts kept instances" { $script:r1.Data.InstanceCount | Should -Be 2 }
}

Describe "CS-002: orders instances chronologically by PeriodToken + stamps OrderIndex" {
    BeforeAll {
        $script:dir2 = Join-Path $TestDrive 'cs002'
        New-Item -ItemType Directory -Path $script:dir2 -Force | Out-Null
        # Inserted out of order; CachedAt deliberately REVERSED vs the date token so we
        # prove ordering follows the PeriodToken, not CachedAt.
        New-CSCacheInstance -Dir $script:dir2 -CampId 'o-b' -CampName 'Quarterly Cert - 2026-06-30' -CachedAt '2026-01-01T00:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir2 -CampId 'o-a' -CampName 'Quarterly Cert - 2026-06-28' -CachedAt '2026-12-31T00:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir2 -CampId 'o-c' -CampName 'Quarterly Cert - 2026-06-29' -CachedAt '2026-06-15T00:00:00.0000000+00:00'
        $script:r2 = Get-SPCachedCampaignSeries -CachePath $script:dir2
        $script:inst2 = $script:r2.Data.Series[0].Instances
    }
    It "orders ascending by date token" {
        $script:inst2[0].CampaignId | Should -Be 'o-a'
        $script:inst2[1].CampaignId | Should -Be 'o-c'
        $script:inst2[2].CampaignId | Should -Be 'o-b'
    }
    It "stamps 0-based OrderIndex" {
        $script:inst2[0].OrderIndex | Should -Be 0
        $script:inst2[2].OrderIndex | Should -Be 2
    }
    It "records ChronoSource = PeriodToken" {
        $script:inst2[0].ChronoSource | Should -Be 'PeriodToken'
    }
}

Describe "CS-003: carries capture provenance from meta.json" {
    BeforeAll {
        $script:dir3 = Join-Path $TestDrive 'cs003'
        New-Item -ItemType Directory -Path $script:dir3 -Force | Out-Null
        New-CSCacheInstance -Dir $script:dir3 -CampId 'p-1' -CampName 'Prov Review - 2026-06-29' `
            -CachedAt '2026-06-29T08:00:00.0000000+00:00' -CapturedWhileActive $true -Unverified $false `
            -SealReason 'Campaign transitioned from ACTIVE to COMPLETED'
        New-CSCacheInstance -Dir $script:dir3 -CampId 'p-2' -CampName 'Prov Review - 2026-06-30' `
            -CachedAt '2026-06-30T08:00:00.0000000+00:00' -CapturedWhileActive $false -Unverified $true -Status 'COMPLETED'
        $script:r3 = Get-SPCachedCampaignSeries -CachePath $script:dir3
        $script:inst3 = $script:r3.Data.Series[0].Instances
    }
    It "carries CapturedWhileActive + SealReason on the verified instance" {
        $script:inst3[0].CapturedWhileActive | Should -BeTrue
        $script:inst3[0].SealReason | Should -Match 'transitioned'
    }
    It "carries Unverified provenance on the first-seen-COMPLETED instance" {
        $script:inst3[1].Unverified | Should -BeTrue
        $script:inst3[1].CapturedWhileActive | Should -BeFalse
    }
    It "carries Status" { $script:inst3[1].Status | Should -Be 'COMPLETED' }
}

Describe "CS-004: NO-API loaders return items + sealed roster from disk" {
    BeforeAll {
        $script:dir4 = Join-Path $TestDrive 'cs004'
        New-Item -ItemType Directory -Path $script:dir4 -Force | Out-Null
        $items = @(
            [PSCustomObject]@{ id = 'it-1'; decision = 'APPROVE' },
            [PSCustomObject]@{ id = 'it-2'; decision = 'APPROVE' }
        )
        $roster = @(
            [PSCustomObject]@{ CertificationId = 'l-1-cert'; ReviewerName = 'Alice'; ReviewerId = 'rv-1' }
        )
        New-CSCacheInstance -Dir $script:dir4 -CampId 'l-1' -CampName 'Loader Review - 2026-06-29' -CachedAt '2026-06-29T08:00:00.0000000+00:00' -Items $items -RosterEntries $roster
        New-CSCacheInstance -Dir $script:dir4 -CampId 'l-2' -CampName 'Loader Review - 2026-06-30' -CachedAt '2026-06-30T08:00:00.0000000+00:00' -Items $items -RosterEntries $roster
        $script:r4 = Get-SPCachedCampaignSeries -CachePath $script:dir4
        $script:inst4 = $script:r4.Data.Series[0].Instances
    }
    It "LoadItems returns the wrapped items" {
        $loaded = & $script:inst4[0].LoadItems
        @($loaded).Count | Should -Be 2
        @($loaded)[0].Item.id | Should -Be 'it-1'
    }
    It "LoadItems wraps with CampaignName" {
        $loaded = & $script:inst4[0].LoadItems
        @($loaded)[0].CampaignName | Should -Be 'Loader Review - 2026-06-29'
    }
    It "LoadRoster returns the sealed Entries" {
        $entries = & $script:inst4[0].LoadRoster
        @($entries).Count | Should -Be 1
        @($entries)[0].ReviewerName | Should -Be 'Alice'
    }
    It "loaders return empty when sibling files absent" {
        # A series whose instances have no items/roster files on disk.
        $dirX = Join-Path $TestDrive 'cs004x'
        New-Item -ItemType Directory -Path $dirX -Force | Out-Null
        New-CSCacheInstance -Dir $dirX -CampId 'x-1' -CampName 'Empty Review - 2026-06-29' -CachedAt '2026-06-29T08:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $dirX -CampId 'x-2' -CampName 'Empty Review - 2026-06-30' -CachedAt '2026-06-30T08:00:00.0000000+00:00'
        $rx = Get-SPCachedCampaignSeries -CachePath $dirX
        @(& $rx.Data.Series[0].Instances[0].LoadItems).Count | Should -Be 0
        @(& $rx.Data.Series[0].Instances[0].LoadRoster).Count | Should -Be 0
    }
}

Describe "CS-005: MinInstances filter" {
    BeforeAll {
        $script:dir5 = Join-Path $TestDrive 'cs005'
        New-Item -ItemType Directory -Path $script:dir5 -Force | Out-Null
        # Series A: two instances. Series B (one-off): single instance.
        New-CSCacheInstance -Dir $script:dir5 -CampId 'a-1' -CampName 'Recurring - 2026-06-29' -CachedAt '2026-06-29T08:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir5 -CampId 'a-2' -CampName 'Recurring - 2026-06-30' -CachedAt '2026-06-30T08:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir5 -CampId 'b-1' -CampName 'One Off - 2026-06-30' -CachedAt '2026-06-30T08:00:00.0000000+00:00'
    }
    It "default (2) drops the one-off campaign" {
        $r = Get-SPCachedCampaignSeries -CachePath $script:dir5
        $r.Data.SeriesCount | Should -Be 1
        $r.Data.Series[0].SeriesStem | Should -Match 'Recurring'
    }
    It "MinInstances=1 keeps both" {
        $r = Get-SPCachedCampaignSeries -CachePath $script:dir5 -MinInstances 1
        $r.Data.SeriesCount | Should -Be 2
    }
}

Describe "CS-006: absent cache dir -> Success with empty Series" {
    It "does not throw and returns empty" {
        $missing = Join-Path $TestDrive 'does-not-exist'
        $r = Get-SPCachedCampaignSeries -CachePath $missing
        $r.Success | Should -BeTrue
        $r.Data.SeriesCount | Should -Be 0
        @($r.Data.Series).Count | Should -Be 0
        $r.Data.CacheDir | Should -Be $missing
    }
}

Describe "CS-007: overrides + Quarterly chronological ordering" {
    BeforeAll {
        $script:dir7 = Join-Path $TestDrive 'cs007'
        New-Item -ItemType Directory -Path $script:dir7 -Force | Out-Null
        # Quarterly variants in different coworker spellings; must group + order Q1->Q3.
        New-CSCacheInstance -Dir $script:dir7 -CampId 'q-3' -CampName 'Finance Cert - Q3 2026' -CachedAt '2026-01-01T00:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir7 -CampId 'q-1' -CampName 'Finance Cert - 1Q2026'  -CachedAt '2026-12-01T00:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $script:dir7 -CampId 'q-2' -CampName 'Finance Cert - Q2-2026' -CachedAt '2026-06-01T00:00:00.0000000+00:00'
    }
    It "groups quarterly variants and orders Q1->Q2->Q3 by token" {
        $r = Get-SPCachedCampaignSeries -CachePath $script:dir7
        $r.Data.SeriesCount | Should -Be 1
        $inst = $r.Data.Series[0].Instances
        $inst[0].CampaignId | Should -Be 'q-1'
        $inst[1].CampaignId | Should -Be 'q-2'
        $inst[2].CampaignId | Should -Be 'q-3'
        $inst[0].PeriodType | Should -Be 'Quarterly'
    }
    It "SeriesStem override forces a single series for unrelated names" {
        $dirO = Join-Path $TestDrive 'cs007o'
        New-Item -ItemType Directory -Path $dirO -Force | Out-Null
        New-CSCacheInstance -Dir $dirO -CampId 's-1' -CampName 'Totally Different Alpha 2026-06-29' -CachedAt '2026-06-29T08:00:00.0000000+00:00'
        New-CSCacheInstance -Dir $dirO -CampId 's-2' -CampName 'Unrelated Beta 2026-06-30' -CachedAt '2026-06-30T08:00:00.0000000+00:00'
        $r = Get-SPCachedCampaignSeries -CachePath $dirO -SeriesStem 'Forced Series'
        $r.Data.SeriesCount | Should -Be 1
        $r.Data.Series[0].InstanceCount | Should -Be 2
    }
}
