#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for SP.ReviewerState -- persistent per-reviewer engagement tracking
    across campaign series and instances.

.DESCRIPTION
    Validates engagement classification (C/P/M/U), the yyyyMMdd dayLog, derived
    weeklyStats/streaks/engagement, stable identity keying, JSONL round-trip,
    re-processing convergence (ACTIVE instances), corrupt-file accounting, and
    multi-instance chronological processing.

    RS-001: Campaign series name extraction (day-of-week+date, ISO date, year-only, no date)
    RS-002: Completed (C) -- all items IsGenuineDecision=true for a reviewer
    RS-003: Partial (P) -- some items decided, some not
    RS-004: Missed (M) -- zero genuine decisions, NOT all auto-approved
    RS-005: Undecided (U) -- zero genuine decisions, ALL auto-approved
    RS-006: dayLog format (yyyyMMdd) and chronological ordering incl. year boundary
    RS-007: Same-day same-state replay is idempotent
    RS-008: weeklyStats per ISO week (derived from dayLog)
    RS-009: Streak tracking (C increments, M/U increments miss streak, P breaks both)
    RS-010: engagementScore = completed/observed * 100
    RS-011: Multiple series per reviewer tracked independently
    RS-012: Write/Read JSONL round-trip with _meta line
    RS-013: Update does NOT mark ProcessedInstances (orchestrator owns it)
    RS-014: Reviewer email/id extracted from resolved items
    RS-015: Multiple instances with different dates
    RS-016: Stable identity -- rename keeps history; same-name distinct ids never merge
    RS-017: ACTIVE re-processing converges (M day upgraded to C, no double-count)
    RS-018: Out-of-order backfill yields date-ordered streaks
    RS-019: Corrupt lines counted in SkippedLines, valid records still load
    RS-020: ISO week labels are correct across the year boundary
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.ReviewerState.psm1') -Force -DisableNameChecking

    function New-TestResolvedItem {
        param(
            [string]$ItemKey = 'id-001|ent-001|src-001',
            [string]$HonestDecision = 'Approved',
            [bool]$IsAutoApproved = $false,
            [bool]$IsGenuineDecision = $true,
            [string]$ReviewerName = 'Test Reviewer',
            [string]$ReviewerEmail = '',
            [string]$ReviewerId = '',
            [string]$IdentityId = 'id-001',
            [string]$IdentityName = 'Test User',
            [string]$AccessName = 'Test Access',
            [string]$AccessType = 'ENTITLEMENT',
            [string]$SourceId = 'src-001',
            [string]$SourceName = 'Test Source',
            [string]$DecisionDate = '2026-06-24T10:00:00Z'
        )
        return [PSCustomObject]@{
            ItemKey           = $ItemKey
            HonestDecision    = $HonestDecision
            IsAutoApproved    = $IsAutoApproved
            IsGenuineDecision = $IsGenuineDecision
            ReviewerName      = $ReviewerName
            ReviewerEmail     = $ReviewerEmail
            ReviewerId        = $ReviewerId
            IdentityId        = $IdentityId
            IdentityName      = $IdentityName
            AccessName        = $AccessName
            AccessType        = $AccessType
            SourceId          = $SourceId
            SourceName        = $SourceName
            DecisionDate      = $DecisionDate
        }
    }
}

# ---------------------------------------------------------------------------
# RS-001: Campaign series name extraction
# ---------------------------------------------------------------------------
Describe 'RS-001: Get-SPCampaignSeriesName strips date suffixes' {
    It 'strips day-of-week + full date (e.g. "Tuesday, June 24, 2026")' {
        $name = Get-SPCampaignSeriesName -CampaignName 'Daily Attestation Tuesday, June 24, 2026'
        $name | Should -Be 'Daily Attestation'
    }

    It 'strips ISO date suffix (e.g. "2026-06-24")' {
        $name = Get-SPCampaignSeriesName -CampaignName 'SOX Review 2026-06-24'
        $name | Should -Be 'SOX Review'
    }

    It 'strips year-only suffix (e.g. "2026")' {
        $name = Get-SPCampaignSeriesName -CampaignName 'Annual Recertification 2026'
        $name | Should -Be 'Annual Recertification'
    }

    It 'returns unchanged name when no date suffix is present' {
        $name = Get-SPCampaignSeriesName -CampaignName 'Standing Campaign'
        $name | Should -Be 'Standing Campaign'
    }

    It 'strips US-format date suffix (e.g. "6/24/2026")' {
        $name = Get-SPCampaignSeriesName -CampaignName 'Quarterly Review 6/24/2026'
        $name | Should -Be 'Quarterly Review'
    }

    It 'does NOT strip non-year trailing numbers (e.g. zone/site codes)' {
        $name = Get-SPCampaignSeriesName -CampaignName 'PCI Review Zone 1042'
        $name | Should -Be 'PCI Review Zone 1042'
    }
}

# ---------------------------------------------------------------------------
# RS-002: Completed (C) -- all items decided
# ---------------------------------------------------------------------------
Describe 'RS-002: Completed engagement (C) when all items genuinely decided' {
    BeforeAll {
        $script:rvMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-c1|ent-c1|src-c1' -ReviewerName 'Alice Manager' `
                -HonestDecision 'Approved' -IsGenuineDecision $true),
            (New-TestResolvedItem -ItemKey 'id-c2|ent-c2|src-c2' -ReviewerName 'Alice Manager' `
                -HonestDecision 'Revoked' -IsGenuineDecision $true)
        )
        $script:result = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-002' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'creates the reviewer record keyed by stable identity (nm: fallback)' {
        $script:rvMap.ContainsKey('nm:Alice Manager') | Should -BeTrue
        $script:rvMap['nm:Alice Manager']['reviewerName'] | Should -Be 'Alice Manager'
    }

    It 'dayLog shows C for 2026-06-24' {
        $script:rvMap['nm:Alice Manager']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260624'
    }

    It 'campaignsCompleted = 1' {
        $script:rvMap['nm:Alice Manager']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 1
    }

    It 'reports ReviewersNew = 1' {
        $script:result.ReviewersNew | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-003: Partial (P) -- some items decided, some not
# ---------------------------------------------------------------------------
Describe 'RS-003: Partial engagement (P) when some items decided' {
    BeforeAll {
        $script:rvMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-p1|ent-p1|src-p1' -ReviewerName 'Bob Partial' `
                -HonestDecision 'Approved' -IsGenuineDecision $true),
            (New-TestResolvedItem -ItemKey 'id-p2|ent-p2|src-p2' -ReviewerName 'Bob Partial' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-003' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'dayLog shows P for 2026-06-24' {
        $script:rvMap['nm:Bob Partial']['series']['Daily Attestation']['dayLog'] | Should -Be 'P:20260624'
    }

    It 'campaignsCompleted remains 0' {
        $script:rvMap['nm:Bob Partial']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 0
    }

    It 'campaignsMissed remains 0 (partial is not missed)' {
        $script:rvMap['nm:Bob Partial']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# RS-004: Missed (M) -- zero genuine decisions, NOT all auto-approved
# ---------------------------------------------------------------------------
Describe 'RS-004: Missed engagement (M) when zero decisions and not all auto-approved' {
    BeforeAll {
        $script:rvMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-m1|ent-m1|src-m1' -ReviewerName 'Carol Missed' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false),
            (New-TestResolvedItem -ItemKey 'id-m2|ent-m2|src-m2' -ReviewerName 'Carol Missed' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-004' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'dayLog shows M for 2026-06-24' {
        $script:rvMap['nm:Carol Missed']['series']['Daily Attestation']['dayLog'] | Should -Be 'M:20260624'
    }

    It 'campaignsMissed = 1' {
        $script:rvMap['nm:Carol Missed']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
    }

    It 'campaignsCompleted = 0' {
        $script:rvMap['nm:Carol Missed']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# RS-005: Undecided (U) -- zero genuine decisions, ALL auto-approved
# ---------------------------------------------------------------------------
Describe 'RS-005: Undecided engagement (U) when zero decisions and all auto-approved' {
    BeforeAll {
        $script:rvMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-u1|ent-u1|src-u1' -ReviewerName 'Dave Undecided' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $true),
            (New-TestResolvedItem -ItemKey 'id-u2|ent-u2|src-u2' -ReviewerName 'Dave Undecided' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-005' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'dayLog shows U for 2026-06-24' {
        $script:rvMap['nm:Dave Undecided']['series']['Daily Attestation']['dayLog'] | Should -Be 'U:20260624'
    }

    It 'campaignsMissed = 1 (U counts as missed)' {
        $script:rvMap['nm:Dave Undecided']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-006: dayLog format and chronological ordering
# ---------------------------------------------------------------------------
Describe 'RS-006: dayLog format and chronological ordering' {
    BeforeAll {
        $script:rvMap = @{}

        # Day 1: Completed
        $items1 = @(
            (New-TestResolvedItem -ItemKey 'id-dl1|ent-dl1|src-dl1' -ReviewerName 'Eve DayLog' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items1 -InstanceId 'camp-006a' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'

        # Day 2: Missed
        $items2 = @(
            (New-TestResolvedItem -ItemKey 'id-dl1|ent-dl1|src-dl1' -ReviewerName 'Eve DayLog' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items2 -InstanceId 'camp-006b' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        # Day 3: Completed
        $items3 = @(
            (New-TestResolvedItem -ItemKey 'id-dl1|ent-dl1|src-dl1' -ReviewerName 'Eve DayLog' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items3 -InstanceId 'camp-006c' -InstanceDate '2026-06-25' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-25'
    }

    It 'dayLog shows C:20260623|M:20260624|C:20260625 in chronological order' {
        $script:rvMap['nm:Eve DayLog']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260623|M:20260624|C:20260625'
    }

    It 'each entry uses the format {State}:{yyyyMMdd}' {
        $log = $script:rvMap['nm:Eve DayLog']['series']['Daily Attestation']['dayLog']
        foreach ($part in $log.Split('|')) {
            $part | Should -Match '^[CPMU]:\d{8}$'
        }
    }

    It 'keeps December-to-January transitions chronological (the MMdd format did not)' {
        $r1 = Update-DayLogEntry -DayLog '' -DayKey '20251231' -State 'C'
        $r2 = Update-DayLogEntry -DayLog $r1.DayLog -DayKey '20260102' -State 'M'
        $r2.DayLog | Should -Be 'C:20251231|M:20260102'
    }

    It 'does not collide the same calendar day across two years' {
        $r1 = Update-DayLogEntry -DayLog '' -DayKey '20250707' -State 'C'
        $r2 = Update-DayLogEntry -DayLog $r1.DayLog -DayKey '20260707' -State 'C'
        $r2.DayLog  | Should -Be 'C:20250707|C:20260707'
        $r2.Changed | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# RS-007: Same-day same-state replay is idempotent
# ---------------------------------------------------------------------------
Describe 'RS-007: same day + same state replay changes nothing' {
    BeforeAll {
        $script:rvMap = @{}

        # Initial state
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-id1|ent-id1|src-id1' -ReviewerName 'Frank Idem' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-007a' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $script:observedAfterFirst = [int]$script:rvMap['nm:Frank Idem']['series']['Daily Attestation']['campaignsObserved']

        # Same day, same state (e.g. the ACTIVE campaign re-captured, or a rerun)
        $script:result = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-007b' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $script:observedAfterSecond = [int]$script:rvMap['nm:Frank Idem']['series']['Daily Attestation']['campaignsObserved']
    }

    It 'dayLog does not duplicate the entry' {
        $script:rvMap['nm:Frank Idem']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260624'
    }

    It 'campaignsObserved does not increment on idempotent replay' {
        $script:observedAfterSecond | Should -Be $script:observedAfterFirst
        $script:observedAfterSecond | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-008: weeklyStats per ISO week
# ---------------------------------------------------------------------------
Describe 'RS-008: weeklyStats tracked per ISO week' {
    BeforeAll {
        $script:rvMap = @{}

        # Monday 2026-06-22 (ISO week 2026-W26)
        $items1 = @(
            (New-TestResolvedItem -ItemKey 'id-ws1|ent-ws1|src-ws1' -ReviewerName 'Grace Weekly' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items1 -InstanceId 'camp-008a' -InstanceDate '2026-06-22' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-22'

        # Tuesday 2026-06-23 (same ISO week)
        $items2 = @(
            (New-TestResolvedItem -ItemKey 'id-ws1|ent-ws1|src-ws1' -ReviewerName 'Grace Weekly' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items2 -InstanceId 'camp-008b' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'

        $script:sd = $script:rvMap['nm:Grace Weekly']['series']['Daily Attestation']
    }

    It 'weeklyStats has exactly one ISO-week entry' {
        $script:sd['weeklyStats'].Count | Should -Be 1
    }

    It 'the ISO week label is 2026-W26' {
        @($script:sd['weeklyStats'].Keys)[0] | Should -Be '2026-W26'
    }

    It 'expected count matches the number of days processed in that week' {
        [int]$script:sd['weeklyStats']['2026-W26']['expected'] | Should -Be 2
    }

    It 'completed = 1 for the week (Monday only)' {
        [int]$script:sd['weeklyStats']['2026-W26']['completed'] | Should -Be 1
    }

    It 'missed = 1 for the week (Tuesday only)' {
        [int]$script:sd['weeklyStats']['2026-W26']['missed'] | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-009: Streak tracking
# ---------------------------------------------------------------------------
Describe 'RS-009: Streak tracking (C increments, M/U increments miss, P breaks both)' {
    BeforeAll {
        $script:rvMap = @{}

        # Day 1: C (currentStreak=1, currentMissStreak=0)
        $itemsC = @(
            (New-TestResolvedItem -ItemKey 'id-sk1|ent-sk1|src-sk1' -ReviewerName 'Hank Streaker' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsC -InstanceId 'camp-009a' -InstanceDate '2026-06-22' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-22'

        # Day 2: C (currentStreak=2)
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsC -InstanceId 'camp-009b' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'

        $script:streaksAfter2C = @{}
        $s = $script:rvMap['nm:Hank Streaker']['series']['Daily Attestation']['streaks']
        foreach ($k in $s.Keys) { $script:streaksAfter2C[$k] = $s[$k] }

        # Day 3: M (currentStreak=0, currentMissStreak=1)
        $itemsM = @(
            (New-TestResolvedItem -ItemKey 'id-sk1|ent-sk1|src-sk1' -ReviewerName 'Hank Streaker' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsM -InstanceId 'camp-009c' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $script:streaksAfterM = @{}
        $s2 = $script:rvMap['nm:Hank Streaker']['series']['Daily Attestation']['streaks']
        foreach ($k in $s2.Keys) { $script:streaksAfterM[$k] = $s2[$k] }

        # Day 4: U (currentMissStreak=2)
        $itemsU = @(
            (New-TestResolvedItem -ItemKey 'id-sk1|ent-sk1|src-sk1' -ReviewerName 'Hank Streaker' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsU -InstanceId 'camp-009d' -InstanceDate '2026-06-25' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-25'

        $script:streaksAfterU = @{}
        $s3 = $script:rvMap['nm:Hank Streaker']['series']['Daily Attestation']['streaks']
        foreach ($k in $s3.Keys) { $script:streaksAfterU[$k] = $s3[$k] }

        # Day 5: P (breaks both streaks)
        $itemsP = @(
            (New-TestResolvedItem -ItemKey 'id-sk1|ent-sk1|src-sk1' -ReviewerName 'Hank Streaker' `
                -HonestDecision 'Approved' -IsGenuineDecision $true),
            (New-TestResolvedItem -ItemKey 'id-sk2|ent-sk2|src-sk2' -ReviewerName 'Hank Streaker' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsP -InstanceId 'camp-009e' -InstanceDate '2026-06-26' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-26'

        $script:streaksAfterP = @{}
        $s4 = $script:rvMap['nm:Hank Streaker']['series']['Daily Attestation']['streaks']
        foreach ($k in $s4.Keys) { $script:streaksAfterP[$k] = $s4[$k] }
    }

    It 'after 2 completions: currentStreak=2, longestStreak=2' {
        [int]$script:streaksAfter2C['currentStreak'] | Should -Be 2
        [int]$script:streaksAfter2C['longestStreak'] | Should -Be 2
    }

    It 'after miss (M): currentStreak=0, currentMissStreak=1' {
        [int]$script:streaksAfterM['currentStreak']     | Should -Be 0
        [int]$script:streaksAfterM['currentMissStreak'] | Should -Be 1
    }

    It 'after undecided (U): currentMissStreak=2' {
        [int]$script:streaksAfterU['currentMissStreak'] | Should -Be 2
    }

    It 'longestStreak preserved at 2 after misses' {
        [int]$script:streaksAfterU['longestStreak'] | Should -Be 2
    }

    It 'after partial (P): both streaks reset to 0' {
        [int]$script:streaksAfterP['currentStreak']     | Should -Be 0
        [int]$script:streaksAfterP['currentMissStreak'] | Should -Be 0
    }

    It 'longestMissStreak preserved at 2 after partial break' {
        [int]$script:streaksAfterP['longestMissStreak'] | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# RS-010: engagementScore = completed/observed * 100
# ---------------------------------------------------------------------------
Describe 'RS-010: engagementScore calculation' {
    BeforeAll {
        $script:rvMap = @{}

        # 3 campaigns: C, C, M -> score = 2/3 * 100 = 67
        $itemsC = @(
            (New-TestResolvedItem -ItemKey 'id-es1|ent-es1|src-es1' -ReviewerName 'Ivy Score' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        $itemsM = @(
            (New-TestResolvedItem -ItemKey 'id-es1|ent-es1|src-es1' -ReviewerName 'Ivy Score' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )

        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsC -InstanceId 'camp-010a' -InstanceDate '2026-06-22' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-22'
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsC -InstanceId 'camp-010b' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsM -InstanceId 'camp-010c' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'totalCampaignsCompleted = 2' {
        [int]$script:rvMap['nm:Ivy Score']['global']['totalCampaignsCompleted'] | Should -Be 2
    }

    It 'totalCampaignsObserved = 3' {
        [int]$script:rvMap['nm:Ivy Score']['global']['totalCampaignsObserved'] | Should -Be 3
    }

    It 'engagementScore = 67 (rounded from 66.67)' {
        [int]$script:rvMap['nm:Ivy Score']['global']['engagementScore'] | Should -Be 67
    }
}

# ---------------------------------------------------------------------------
# RS-011: Multiple series per reviewer tracked independently
# ---------------------------------------------------------------------------
Describe 'RS-011: Multiple series per reviewer tracked independently' {
    BeforeAll {
        $script:rvMap = @{}

        # Series A: Completed
        $itemsA = @(
            (New-TestResolvedItem -ItemKey 'id-ms1|ent-ms1|src-ms1' -ReviewerName 'Jack Multi' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsA -InstanceId 'camp-011a' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        # Series B: Missed
        $itemsB = @(
            (New-TestResolvedItem -ItemKey 'id-ms2|ent-ms2|src-ms2' -ReviewerName 'Jack Multi' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $itemsB -InstanceId 'camp-011b' -InstanceDate '2026-06-24' `
            -SeriesName 'SOX Review' -TodayLabel '2026-06-24'
    }

    It 'reviewer has two series entries' {
        $script:rvMap['nm:Jack Multi']['series'].Count | Should -Be 2
    }

    It 'Daily Attestation series shows C' {
        $script:rvMap['nm:Jack Multi']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260624'
    }

    It 'SOX Review series shows M' {
        $script:rvMap['nm:Jack Multi']['series']['SOX Review']['dayLog'] | Should -Be 'M:20260624'
    }

    It 'global totalCampaignsObserved = 2 (across both series)' {
        [int]$script:rvMap['nm:Jack Multi']['global']['totalCampaignsObserved'] | Should -Be 2
    }

    It 'global totalCampaignsCompleted = 1 (only Daily Attestation)' {
        [int]$script:rvMap['nm:Jack Multi']['global']['totalCampaignsCompleted'] | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-012: Write/Read JSONL round-trip with _meta line
# ---------------------------------------------------------------------------
Describe 'RS-012: Write/Read JSONL round-trip' {
    BeforeAll {
        $script:rvMap = @{}

        $items = @(
            (New-TestResolvedItem -ItemKey 'id-rt1|ent-rt1|src-rt1' -ReviewerName 'Kim RoundTrip' `
                -HonestDecision 'Approved' -IsGenuineDecision $true `
                -ReviewerEmail 'kim@example.com' -ReviewerId 'rv-kim')
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-012' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $script:filePath = Join-Path $TestDrive 'reviewer-state.jsonl'
        $script:procInst = @{ 'camp-012' = @{ instanceDate = '2026-06-24'; series = 'Daily Attestation'; status = 'COMPLETED' } }
        $script:writeResult = Write-SPReviewerState -ReviewerMap $script:rvMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-24'

        $script:readBack = Read-SPReviewerState -Path $script:filePath
    }

    It 'write reports Success' {
        $script:writeResult.Success | Should -BeTrue
    }

    It 'file exists after write' {
        Test-Path $script:filePath | Should -BeTrue
    }

    It 'round-trip preserves reviewer count' {
        $script:readBack.RecordCount | Should -Be 1
    }

    It 'round-trip preserves the stable reviewer key (id-based, since the item carried one)' {
        $script:readBack.ReviewerMap.ContainsKey('id:rv-kim') | Should -BeTrue
        $script:readBack.ReviewerMap['id:rv-kim']['reviewerName'] | Should -Be 'Kim RoundTrip'
    }

    It 'round-trip preserves series data' {
        $script:readBack.ReviewerMap['id:rv-kim']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260624'
    }

    It 'round-trip preserves LastRunDate' {
        $script:readBack.LastRunDate | Should -Be '2026-06-24'
    }

    It 'overwrite of an existing file also succeeds (File.Replace path)' {
        $second = Write-SPReviewerState -ReviewerMap $script:rvMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-25'
        $second.Success | Should -BeTrue
        (Read-SPReviewerState -Path $script:filePath).LastRunDate | Should -Be '2026-06-25'
    }
}

# ---------------------------------------------------------------------------
# RS-013: Update does NOT mark ProcessedInstances (orchestrator owns it)
# ---------------------------------------------------------------------------
Describe 'RS-013: Update-SPReviewerState does not guard on or mark ProcessedInstances' {
    It 'processes an instance even when its id is already in ProcessedInstances, and marks nothing' {
        # v2.1 contract: the earlier in-function guard is what made reviewer state
        # never populate (the entitlement update had already marked every instance),
        # and the marking froze ACTIVE campaigns at their first snapshot.
        $rvMap = @{}
        $procInst = @{ 'camp-013' = $true }
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-pi1|ent-pi1|src-pi1' -ReviewerName 'Leo Proc' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        $result = Update-SPReviewerState -ReviewerMap $rvMap `
            -ResolvedItems $items -ProcessedInstances $procInst `
            -InstanceId 'camp-013' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $result.ReviewersNew | Should -Be 1
        $rvMap.ContainsKey('nm:Leo Proc') | Should -BeTrue
        # Only the pre-existing key remains; the function added nothing.
        $procInst.Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-014: Reviewer email/id extracted from resolved items
# ---------------------------------------------------------------------------
Describe 'RS-014: Reviewer email and id extracted from resolved items' {
    BeforeAll {
        $script:rvMap = @{}

        $items = @(
            (New-TestResolvedItem -ItemKey 'id-ri1|ent-ri1|src-ri1' -ReviewerName 'Mia Identity' `
                -HonestDecision 'Approved' -IsGenuineDecision $true `
                -ReviewerEmail 'mia@corp.com' -ReviewerId 'rv-mia-001'),
            (New-TestResolvedItem -ItemKey 'id-ri2|ent-ri2|src-ri2' -ReviewerName 'Mia Identity' `
                -HonestDecision 'Revoked' -IsGenuineDecision $true `
                -ReviewerEmail 'mia@corp.com' -ReviewerId 'rv-mia-001')
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-014' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'keys the record by ReviewerId when present' {
        $script:rvMap.ContainsKey('id:rv-mia-001') | Should -BeTrue
    }

    It 'stores reviewerEmail from resolved items' {
        $script:rvMap['id:rv-mia-001']['reviewerEmail'] | Should -Be 'mia@corp.com'
    }

    It 'stores reviewerId from resolved items' {
        $script:rvMap['id:rv-mia-001']['reviewerId'] | Should -Be 'rv-mia-001'
    }
}

# ---------------------------------------------------------------------------
# RS-015: Multiple instances with different dates
# ---------------------------------------------------------------------------
Describe 'RS-015: Multiple instances with different dates processed correctly' {
    BeforeAll {
        $script:rvMap = @{}

        # Instance 1: 2026-06-22 (Mon) -- Completed
        $items1 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items1 `
            -InstanceId 'camp-015a' -InstanceDate '2026-06-22' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-22'

        # Instance 2: 2026-06-23 (Tue) -- Missed
        $items2 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items2 `
            -InstanceId 'camp-015b' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'

        # Instance 3: 2026-06-24 (Wed) -- Completed
        $items3 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        $script:result3 = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items3 `
            -InstanceId 'camp-015c' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'dayLog shows all three days in order' {
        $script:rvMap['nm:Nate MultiDay']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:20260622|M:20260623|C:20260624'
    }

    It 'campaignsObserved = 3' {
        [int]$script:rvMap['nm:Nate MultiDay']['series']['Daily Attestation']['campaignsObserved'] | Should -Be 3
    }

    It 'campaignsCompleted = 2' {
        [int]$script:rvMap['nm:Nate MultiDay']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 2
    }

    It 'campaignsMissed = 1' {
        [int]$script:rvMap['nm:Nate MultiDay']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
    }

    It 'global engagementScore = 67 (2 completed / 3 observed)' {
        [int]$script:rvMap['nm:Nate MultiDay']['global']['engagementScore'] | Should -Be 67
    }

    It 'ReviewersUpdated increments on existing reviewer' {
        $script:result3.ReviewersUpdated | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# RS-016: Stable identity keying
# ---------------------------------------------------------------------------
Describe 'RS-016: stable identity -- renames keep history, same names never merge' {
    It 'a display-name change keeps the same record and history (id-keyed)' {
        $rvMap = @{}
        $before = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Jane Smith' `
            -ReviewerId 'rv-jane' -HonestDecision 'Approved' -IsGenuineDecision $true
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($before) `
            -InstanceId 'c1' -InstanceDate '2026-06-22' -SeriesName 'Daily' -TodayLabel '2026-06-22' | Out-Null

        $after = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Jane Doe' `
            -ReviewerId 'rv-jane' -HonestDecision 'Approved' -IsGenuineDecision $true
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($after) `
            -InstanceId 'c2' -InstanceDate '2026-06-23' -SeriesName 'Daily' -TodayLabel '2026-06-23' | Out-Null

        $rvMap.Count | Should -Be 1
        $rvMap['id:rv-jane']['reviewerName'] | Should -Be 'Jane Doe'   # label refreshed
        [int]$rvMap['id:rv-jane']['series']['Daily']['campaignsObserved'] | Should -Be 2   # history intact
    }

    It 'two reviewers sharing a display name but different ids never merge' {
        $rvMap = @{}
        $smith1 = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'John Smith' `
            -ReviewerId 'rv-js-1' -HonestDecision 'Approved' -IsGenuineDecision $true
        $smith2 = New-TestResolvedItem -ItemKey 'd|e|f' -ReviewerName 'John Smith' `
            -ReviewerId 'rv-js-2' -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($smith1, $smith2) `
            -InstanceId 'c1' -InstanceDate '2026-06-24' -SeriesName 'Daily' -TodayLabel '2026-06-24' | Out-Null

        $rvMap.Count | Should -Be 2
        $rvMap['id:rv-js-1']['series']['Daily']['dayLog'] | Should -Be 'C:20260624'
        $rvMap['id:rv-js-2']['series']['Daily']['dayLog'] | Should -Be 'M:20260624'
    }

    It 'an item with an id but a blank display name still counts' {
        $rvMap = @{}
        $anon = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName '' `
            -ReviewerId 'rv-anon' -HonestDecision 'Approved' -IsGenuineDecision $true
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($anon) `
            -InstanceId 'c1' -InstanceDate '2026-06-24' -SeriesName 'Daily' -TodayLabel '2026-06-24' | Out-Null
        $rvMap.ContainsKey('id:rv-anon') | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# RS-017: ACTIVE re-processing converges (day upgrade)
# ---------------------------------------------------------------------------
Describe 'RS-017: re-processing an ACTIVE instance upgrades the day without double-counting' {
    It 'M at 09:00 upgraded to C at 18:00 settles at one completed day' {
        $rvMap = @{}
        # Morning capture: nothing decided yet
        $morning = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Olive Active' `
            -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($morning) `
            -InstanceId 'camp-act' -InstanceDate '2026-06-24' -SeriesName 'Daily' `
            -InstanceStatus 'ACTIVE' -TodayLabel '2026-06-24' | Out-Null

        $sd0 = $rvMap['nm:Olive Active']['series']['Daily']
        $sd0['dayLog'] | Should -Be 'M:20260624'
        [int]$sd0['campaignsMissed'] | Should -Be 1

        # Evening re-capture of the SAME instance: reviewer finished everything
        $evening = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Olive Active' `
            -HonestDecision 'Approved' -IsGenuineDecision $true
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($evening) `
            -InstanceId 'camp-act' -InstanceDate '2026-06-24' -SeriesName 'Daily' `
            -InstanceStatus 'COMPLETED' -TodayLabel '2026-06-24' | Out-Null

        $sd = $rvMap['nm:Olive Active']['series']['Daily']
        $sd['dayLog'] | Should -Be 'C:20260624'
        [int]$sd['campaignsObserved']  | Should -Be 1
        [int]$sd['campaignsCompleted'] | Should -Be 1
        [int]$sd['campaignsMissed']    | Should -Be 0
        [int]$rvMap['nm:Olive Active']['global']['engagementScore'] | Should -Be 100
    }
}

# ---------------------------------------------------------------------------
# RS-018: Out-of-order backfill yields date-ordered streaks
# ---------------------------------------------------------------------------
Describe 'RS-018: streaks derive from date order, not processing order' {
    It 'processing 06-25(C) then backfilling 06-23(M) still ends on a completion streak' {
        $rvMap = @{}
        $c = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Pat Backfill' `
            -HonestDecision 'Approved' -IsGenuineDecision $true
        $m = New-TestResolvedItem -ItemKey 'a|b|c' -ReviewerName 'Pat Backfill' `
            -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false

        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($c) `
            -InstanceId 'c-new' -InstanceDate '2026-06-25' -SeriesName 'Daily' -TodayLabel '2026-06-25' | Out-Null
        Update-SPReviewerState -ReviewerMap $rvMap -ResolvedItems @($m) `
            -InstanceId 'c-old' -InstanceDate '2026-06-23' -SeriesName 'Daily' -TodayLabel '2026-06-25' | Out-Null

        $streaks = $rvMap['nm:Pat Backfill']['series']['Daily']['streaks']
        # Date order is M(06-23) -> C(06-25): the reviewer's most recent day is a completion.
        [int]$streaks['currentStreak']     | Should -Be 1
        [int]$streaks['currentMissStreak'] | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# RS-019: Corrupt lines counted, valid records still load
# ---------------------------------------------------------------------------
Describe 'RS-019: corrupt lines are counted in SkippedLines' {
    It 'reports skipped lines and loads the valid records' {
        $path = Join-Path $TestDrive 'corrupt-reviewer.jsonl'
        $valid = '{"reviewerKey":"nm:Ok Reviewer","reviewerName":"Ok Reviewer","series":{},"global":{}}'
        @('{"_meta":{"lastRunDate":"2026-06-24"}}', $valid, 'not json at all {{{') |
            Set-Content -Path $path -Encoding UTF8
        $r = Read-SPReviewerState -Path $path -WarningAction SilentlyContinue
        $r.RecordCount  | Should -Be 1
        $r.SkippedLines | Should -Be 1
        $r.ReviewerMap.ContainsKey('nm:Ok Reviewer') | Should -BeTrue
    }

    It 'legacy records without reviewerKey fall back to the name key' {
        $path = Join-Path $TestDrive 'legacy-reviewer.jsonl'
        @('{"reviewerName":"Legacy Reviewer","series":{},"global":{}}') |
            Set-Content -Path $path -Encoding UTF8
        $r = Read-SPReviewerState -Path $path
        $r.ReviewerMap.ContainsKey('nm:Legacy Reviewer') | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# RS-020: ISO week labels across the year boundary
# ---------------------------------------------------------------------------
Describe 'RS-020: ISO week labels are correct across the year boundary' {
    It 'labels Mon 2029-12-31 as 2030-W01 (Thursday rule)' {
        Get-SPIsoWeekString -Date ([datetime]'2029-12-31') | Should -Be '2030-W01'
    }

    It 'labels Fri 2027-01-01 as 2026-W53' {
        Get-SPIsoWeekString -Date ([datetime]'2027-01-01') | Should -Be '2026-W53'
    }

    It 'labels a mid-year date normally' {
        Get-SPIsoWeekString -Date ([datetime]'2026-06-22') | Should -Be '2026-W26'
    }
}
