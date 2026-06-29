#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    WI-12 (plan G7) -- Time-axis semantics for the daily-evidence captureDate key.

.DESCRIPTION
    Self-contained unit tests for the pure function Resolve-SPCaptureDateKey, which decides
    the captureDate axis used by the daily-evidence JSONL store and V7's per-day resolution.

    DEFAULT keying = the campaign's own created date (campaign-to-campaign axis), correct for
    recurring daily campaigns. -PerRunDay = the run date (per-day progression of a single
    long-running campaign), opt-in and never the default.

    No mock server / fixtures needed -- the function is pure date math.

    Assertions:
      TAK-01 Resolve-SPCaptureDateKey is exported from SP.Audit.
      TAK-02 default keying derives from the campaign Created date.
      TAK-03 default keying falls back to RunDate when Created is blank or unparseable.
      TAK-04 -PerRunDay returns the RunDate regardless of Created.
      TAK-05 (G7 demonstration) a single long-running campaign (constant Created) collapses
             to ONE key under the default axis but yields THREE distinct keys under -PerRunDay.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

Describe 'Resolve-SPCaptureDateKey (WI-12 / G7 time-axis semantics)' {

    It 'TAK-01 Resolve-SPCaptureDateKey is exported' {
        Get-Command Resolve-SPCaptureDateKey -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'TAK-02 default keying derives from the campaign Created date' {
        Resolve-SPCaptureDateKey -CampaignCreated '2026-06-01T08:00:00Z' -RunDate ([datetime]'2026-06-27') |
            Should -Be '2026-06-01'
    }

    It 'TAK-03 default keying falls back to RunDate when Created is blank' {
        Resolve-SPCaptureDateKey -CampaignCreated '' -RunDate ([datetime]'2026-06-27') |
            Should -Be '2026-06-27'
    }

    It 'TAK-03 default keying falls back to RunDate when Created is unparseable' {
        Resolve-SPCaptureDateKey -CampaignCreated 'not-a-date' -RunDate ([datetime]'2026-06-27') |
            Should -Be '2026-06-27'
    }

    It 'TAK-04 -PerRunDay returns the RunDate regardless of Created' {
        Resolve-SPCaptureDateKey -CampaignCreated '2026-06-01T08:00:00Z' -RunDate ([datetime]'2026-06-27') -PerRunDay |
            Should -Be '2026-06-27'
    }

    It 'TAK-05 single long-running campaign: default collapses to 1 key, -PerRunDay yields 3 distinct keys' {
        $created  = '2026-06-01T08:00:00Z'
        $runDays  = @([datetime]'2026-06-25', [datetime]'2026-06-26', [datetime]'2026-06-27')

        $defaultKeys = foreach ($rd in $runDays) {
            Resolve-SPCaptureDateKey -CampaignCreated $created -RunDate $rd
        }
        $perRunDayKeys = foreach ($rd in $runDays) {
            Resolve-SPCaptureDateKey -CampaignCreated $created -RunDate $rd -PerRunDay
        }

        # Default (campaign-created axis): every capture of one campaign collapses to one slot.
        @($defaultKeys | Select-Object -Unique).Count | Should -Be 1
        @($defaultKeys | Select-Object -Unique)[0]    | Should -Be '2026-06-01'

        # -PerRunDay (per-run-day axis): one distinct key per capture day -> true progression.
        @($perRunDayKeys | Select-Object -Unique).Count | Should -Be 3
    }
}
