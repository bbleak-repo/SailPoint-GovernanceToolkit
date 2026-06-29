#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    MacBook-validation fix: weekly trend period-key no longer collides across the
    calendar-year boundary.

.DESCRIPTION
    `_TQ_GetPeriodKey` (SP.GovernanceTrendQuery) and `_GetPeriodKey` (SP.AuditOperations)
    paired `$Dt.Year` with `GetWeekOfYear`, so a late-December date (ISO week 1 of the NEXT
    year) and an early-January date both keyed `YYYY-W01` -- merging data a year apart into
    one weekly bucket. The fix derives the ISO week-numbering year (Dec/Jan correction).

    Asserts the invariant that actually matters (no cross-year collision), not exact week
    numbers, so it is robust to .NET's GetWeekOfYear quirks.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.GovernanceTrendQuery.psm1') -Force -DisableNameChecking
    function script:D([string]$s) { [datetime]::ParseExact($s, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
}

Describe "WPK -- weekly period-key ISO year-boundary" {

    It "WPK-01 late-December and early-January of the same calendar year do NOT share a bucket" {
        InModuleScope SP.GovernanceTrendQuery -Parameters @{ LateDec = (D '2019-12-31'); EarlyJan = (D '2019-01-02') } {
            param($LateDec, $EarlyJan)
            $kDec = _TQ_GetPeriodKey -Dt $LateDec  -Gran 'Weekly'
            $kJan = _TQ_GetPeriodKey -Dt $EarlyJan -Gran 'Weekly'
            $kDec | Should -Match '^\d{4}-W\d{2}$'
            $kJan | Should -Match '^\d{4}-W\d{2}$'
            $kDec | Should -Not -Be $kJan -Because 'dates a year apart must never collide into one weekly bucket'
        }
    }

    It "WPK-02 dates in the same Mon-Sun ISO week across the year boundary DO share a bucket" {
        # 2020-12-31 (Thu) and 2021-01-01 (Fri) are in the same ISO week.
        InModuleScope SP.GovernanceTrendQuery -Parameters @{ A = (D '2020-12-31'); B = (D '2021-01-01') } {
            param($A, $B)
            (_TQ_GetPeriodKey -Dt $A -Gran 'Weekly') | Should -Be (_TQ_GetPeriodKey -Dt $B -Gran 'Weekly')
        }
    }

    It "WPK-03 Daily and Monthly granularities are unchanged" {
        InModuleScope SP.GovernanceTrendQuery -Parameters @{ Dt = (D '2026-03-15') } {
            param($Dt)
            (_TQ_GetPeriodKey -Dt $Dt -Gran 'Daily')   | Should -Be '2026-03-15'
            (_TQ_GetPeriodKey -Dt $Dt -Gran 'Monthly') | Should -Be '2026-03'
        }
    }
}
