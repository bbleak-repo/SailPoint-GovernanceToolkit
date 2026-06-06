#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x unit suite for Export-SPRollingTrendHtml (T-06).
.DESCRIPTION
    Headlessly verifies the additive rolling 7-day / 30-day manager-cert trend HTML
    view against the FROZEN fixture Tests/TestData/ManagerCert30DaySim.State.json
    (the same fixture T-05 uses). No live mock server is required; the suite is fully
    deterministic (anchor date derived from the fixture, not Get-Date).

    Asserts the @{Success;Data;Error} envelope, a non-empty self-contained HTML file
    with distinct 7-day and 30-day rolling sections + per-calendar-day buckets, the
    privileged-role membership change Added/Removed series (priv-scoped, 41 removes in
    30d), and the manager-accountability attested/overdue/missed series.

    Imports only -Core -Audit (SP.ReportComponents is intentionally ABSENT, proving the
    function works without optional RC reuse).
.NOTES
    Mirrors the import + fixture idiom of SP.ManagerCert30DaySim.Tests.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Audit

    $fixturePath = Join-Path $PSScriptRoot 'TestData\ManagerCert30DaySim.State.json'
    $script:State     = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
    $script:Daily     = @($script:State.campaigns | Where-Object { $_.id -like 'camp-daily-priv-*' })
    $script:Changelog = @($script:State.membershipChangelog)
    $script:Tracked   = @($script:State.trackedPrivilegedRoles)

    # Deterministic anchor = max changelog date (matches the function's default rule).
    $script:Anchor = ($script:Changelog |
        ForEach-Object { [datetime]::Parse($_.date, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } |
        Measure-Object -Maximum).Maximum

    $script:OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rolltrend-" + [guid]::NewGuid().ToString('N'))

    # Single canonical run reused across most It-blocks.
    $script:Result = Export-SPRollingTrendHtml -DailyCampaigns $script:Daily `
        -Changelog $script:Changelog -TrackedRoles $script:Tracked `
        -OutputPath $script:OutDir
}

AfterAll {
    if ($script:OutDir -and (Test-Path $script:OutDir)) {
        Remove-Item $script:OutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Export-SPRollingTrendHtml' {

    It 'is exported and available as a command' {
        Get-Command Export-SPRollingTrendHtml -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'returns a Success=$true envelope with a null Error' {
        $script:Result | Should -Not -BeNullOrEmpty
        $script:Result.Success | Should -BeTrue
        $script:Result.Error | Should -BeNullOrEmpty
    }

    It 'writes an HTML file that exists on disk' {
        $script:Result.Data.Path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:Result.Data.Path | Should -BeTrue
    }

    It 'produces a non-empty, well-formed HTML document' {
        $html = Get-Content -LiteralPath $script:Result.Data.Path -Raw
        $html.Length | Should -BeGreaterThan 0
        $html | Should -Match '<!DOCTYPE html'
        $html | Should -Match '</html>'
    }

    It 'renders BOTH a 7-day and a 30-day rolling section in the HTML' {
        $html = Get-Content -LiteralPath $script:Result.Data.Path -Raw
        $html | Should -Match '(?i)7-day'
        $html | Should -Match '(?i)30-day'
    }

    It 'exposes both windows in the returned Data.Windows structure' {
        $script:Result.Data.Windows.Contains('7') | Should -BeTrue
        $script:Result.Data.Windows.Contains('30') | Should -BeTrue
    }

    It 'has multiple distinct day buckets in the 30-day window' {
        $days30 = @($script:Result.Data.Windows['30'].Days)
        $days30.Count | Should -BeGreaterThan 1
        $distinct = @($days30 | ForEach-Object { $_.Date } | Select-Object -Unique)
        $distinct.Count | Should -Be $days30.Count
    }

    It 'has a monotone 7-day day-count not exceeding the 30-day day-count' {
        $c7  = @($script:Result.Data.Windows['7'].Days).Count
        $c30 = @($script:Result.Data.Windows['30'].Days).Count
        $c7 | Should -BeLessOrEqual $c30
    }

    It 'detects privileged-role REMOVE events in the 30-day window (>0) and >= the 7-day window' {
        $rem30 = $script:Result.Data.Windows['30'].Removed
        $rem7  = $script:Result.Data.Windows['7'].Removed
        $rem30 | Should -BeGreaterThan 0
        $rem30 | Should -BeGreaterOrEqual $rem7
    }

    It 'priv-scoped 30-day Removed matches the fixture-derived expected count' {
        $trIds = @($script:Tracked | ForEach-Object { $_.id })
        $cutoff = $script:Anchor.Date.AddDays(-30)
        $expected = @($script:Changelog | Where-Object {
            $_.operation -eq 'REMOVE' -and ($trIds -contains $_.groupId) -and
            ([datetime]::Parse($_.date, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Date -ge $cutoff) -and
            ([datetime]::Parse($_.date, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Date -le $script:Anchor.Date)
        }).Count
        $script:Result.Data.Windows['30'].Removed | Should -Be $expected
    }

    It 'renders an Added / Removed indicator in the HTML' {
        $html = Get-Content -LiteralPath $script:Result.Data.Path -Raw
        $html | Should -Match '(?i)Removed'
        $html | Should -Match '(?i)Added'
    }

    It 'reports manager accountability with Missed > 0 in the 30-day window' {
        $script:Result.Data.Windows['30'].Missed | Should -BeGreaterThan 0
    }

    It 'sums attested+overdue+missed > 0 across the 30-day window' {
        $w = $script:Result.Data.Windows['30']
        ($w.Attested + $w.Overdue + $w.Missed) | Should -BeGreaterThan 0
    }

    It 'renders attested / overdue / missed accountability tokens in the HTML' {
        $html = Get-Content -LiteralPath $script:Result.Data.Path -Raw
        $html | Should -Match '(?i)Attested'
        $html | Should -Match '(?i)Overdue'
        $html | Should -Match '(?i)Missed'
    }

    It 'handles empty input gracefully (Success + valid HTML still written)' {
        $r = Export-SPRollingTrendHtml -DailyCampaigns @() -Changelog @() -OutputPath $script:OutDir
        $r.Success | Should -BeTrue
        $r.Data.Path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $r.Data.Path | Should -BeTrue
        (Get-Content -LiteralPath $r.Data.Path -Raw).Length | Should -BeGreaterThan 0
    }

    It 'is deterministic for a fixed -AnchorDate (identical 30-day buckets on repeat runs)' {
        $a = Export-SPRollingTrendHtml -DailyCampaigns $script:Daily -Changelog $script:Changelog `
            -TrackedRoles $script:Tracked -OutputPath $script:OutDir -AnchorDate $script:Anchor
        $b = Export-SPRollingTrendHtml -DailyCampaigns $script:Daily -Changelog $script:Changelog `
            -TrackedRoles $script:Tracked -OutputPath $script:OutDir -AnchorDate $script:Anchor

        $aDays = @($a.Data.Windows['30'].Days)
        $bDays = @($b.Data.Windows['30'].Days)
        $aDays.Count | Should -Be $bDays.Count
        for ($i = 0; $i -lt $aDays.Count; $i++) {
            $aDays[$i].Date     | Should -Be $bDays[$i].Date
            $aDays[$i].Attested | Should -Be $bDays[$i].Attested
            $aDays[$i].Removed  | Should -Be $bDays[$i].Removed
            $aDays[$i].Added    | Should -Be $bDays[$i].Added
            $aDays[$i].Missed   | Should -Be $bDays[$i].Missed
        }
    }
}
