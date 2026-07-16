#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for SP.ReviewerState -- persistent per-reviewer engagement tracking
    across campaign series and instances.

.DESCRIPTION
    Validates engagement classification (C/P/M/U), dayLog format, weeklyStats,
    streak tracking, engagement score, JSONL round-trip, ProcessedInstances tracking,
    reviewer identity extraction, and multi-instance chronological processing.

    RS-001: Campaign series name extraction (day-of-week+date, ISO date, year-only, no date)
    RS-002: Completed (C) -- all items IsGenuineDecision=true for a reviewer
    RS-003: Partial (P) -- some items decided, some not
    RS-004: Missed (M) -- zero genuine decisions, NOT all auto-approved
    RS-005: Undecided (U) -- zero genuine decisions, ALL auto-approved
    RS-006: dayLog format and chronological ordering
    RS-007: dayLog idempotency (same MMDD + same state = no update)
    RS-008: weeklyStats per ISO week
    RS-009: Streak tracking (C increments, M/U increments miss streak, P breaks both)
    RS-010: engagementScore = completed/observed * 100
    RS-011: Multiple series per reviewer tracked independently
    RS-012: Write/Read JSONL round-trip with _meta line
    RS-013: ProcessedInstances tracking
    RS-014: Reviewer email/id extracted from resolved items
    RS-015: Multiple instances with different dates
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

    It 'creates the reviewer record' {
        $script:rvMap.ContainsKey('Alice Manager') | Should -BeTrue
    }

    It 'dayLog shows C for 0624' {
        $script:rvMap['Alice Manager']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0624'
    }

    It 'campaignsCompleted = 1' {
        $script:rvMap['Alice Manager']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 1
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

    It 'dayLog shows P for 0624' {
        $script:rvMap['Bob Partial']['series']['Daily Attestation']['dayLog'] | Should -Be 'P:0624'
    }

    It 'campaignsCompleted remains 0' {
        $script:rvMap['Bob Partial']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 0
    }

    It 'campaignsMissed remains 0 (partial is not missed)' {
        $script:rvMap['Bob Partial']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 0
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

    It 'dayLog shows M for 0624' {
        $script:rvMap['Carol Missed']['series']['Daily Attestation']['dayLog'] | Should -Be 'M:0624'
    }

    It 'campaignsMissed = 1' {
        $script:rvMap['Carol Missed']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
    }

    It 'campaignsCompleted = 0' {
        $script:rvMap['Carol Missed']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 0
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

    It 'dayLog shows U for 0624' {
        $script:rvMap['Dave Undecided']['series']['Daily Attestation']['dayLog'] | Should -Be 'U:0624'
    }

    It 'campaignsMissed = 1 (U counts as missed)' {
        $script:rvMap['Dave Undecided']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
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

    It 'dayLog shows C:0623|M:0624|C:0625 in chronological order' {
        $script:rvMap['Eve DayLog']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0623|M:0624|C:0625'
    }

    It 'each entry uses the format {State}:{MMDD}' {
        $log = $script:rvMap['Eve DayLog']['series']['Daily Attestation']['dayLog']
        foreach ($part in $log.Split('|')) {
            $part | Should -Match '^[CPMU]:\d{4}$'
        }
    }
}

# ---------------------------------------------------------------------------
# RS-007: dayLog idempotency
# ---------------------------------------------------------------------------
Describe 'RS-007: dayLog idempotency -- same MMDD + same state = no update' {
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

        $script:observedAfterFirst = [int]$script:rvMap['Frank Idem']['series']['Daily Attestation']['campaignsObserved']

        # Same day, same state
        $script:result = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -InstanceId 'camp-007b' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'

        $script:observedAfterSecond = [int]$script:rvMap['Frank Idem']['series']['Daily Attestation']['campaignsObserved']
    }

    It 'dayLog does not duplicate the entry' {
        $script:rvMap['Frank Idem']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0624'
    }

    It 'campaignsObserved does not increment on idempotent replay' {
        $script:observedAfterSecond | Should -Be $script:observedAfterFirst
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

        $script:sd = $script:rvMap['Grace Weekly']['series']['Daily Attestation']
    }

    It 'weeklyStats has an entry for the ISO week' {
        $script:sd['weeklyStats'].Count | Should -BeGreaterOrEqual 1
    }

    It 'expected count matches the number of days processed in that week' {
        # Both days are in the same ISO week
        $weekKey = @($script:sd['weeklyStats'].Keys)[0]
        [int]$script:sd['weeklyStats'][$weekKey]['expected'] | Should -Be 2
    }

    It 'completed = 1 for the week (Monday only)' {
        $weekKey = @($script:sd['weeklyStats'].Keys)[0]
        [int]$script:sd['weeklyStats'][$weekKey]['completed'] | Should -Be 1
    }

    It 'missed = 1 for the week (Tuesday only)' {
        $weekKey = @($script:sd['weeklyStats'].Keys)[0]
        [int]$script:sd['weeklyStats'][$weekKey]['missed'] | Should -Be 1
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
        $s = $script:rvMap['Hank Streaker']['series']['Daily Attestation']['streaks']
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
        $s2 = $script:rvMap['Hank Streaker']['series']['Daily Attestation']['streaks']
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
        $s3 = $script:rvMap['Hank Streaker']['series']['Daily Attestation']['streaks']
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
        $s4 = $script:rvMap['Hank Streaker']['series']['Daily Attestation']['streaks']
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
        [int]$script:rvMap['Ivy Score']['global']['totalCampaignsCompleted'] | Should -Be 2
    }

    It 'totalCampaignsObserved = 3' {
        [int]$script:rvMap['Ivy Score']['global']['totalCampaignsObserved'] | Should -Be 3
    }

    It 'engagementScore = 67 (rounded from 66.67)' {
        [int]$script:rvMap['Ivy Score']['global']['engagementScore'] | Should -Be 67
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
        $script:rvMap['Jack Multi']['series'].Count | Should -Be 2
    }

    It 'Daily Attestation series shows C' {
        $script:rvMap['Jack Multi']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0624'
    }

    It 'SOX Review series shows M' {
        $script:rvMap['Jack Multi']['series']['SOX Review']['dayLog'] | Should -Be 'M:0624'
    }

    It 'global totalCampaignsObserved = 2 (across both series)' {
        [int]$script:rvMap['Jack Multi']['global']['totalCampaignsObserved'] | Should -Be 2
    }

    It 'global totalCampaignsCompleted = 1 (only Daily Attestation)' {
        [int]$script:rvMap['Jack Multi']['global']['totalCampaignsCompleted'] | Should -Be 1
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
        $script:procInst = @{ 'camp-012' = @{ date = '2026-06-24'; series = 'Daily Attestation'; status = 'COMPLETED' } }
        Write-SPReviewerState -ReviewerMap $script:rvMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-24'

        $script:readBack = Read-SPReviewerState -Path $script:filePath
    }

    It 'file exists after write' {
        Test-Path $script:filePath | Should -BeTrue
    }

    It 'round-trip preserves reviewer count' {
        $script:readBack.RecordCount | Should -Be 1
    }

    It 'round-trip preserves reviewer name key' {
        $script:readBack.ReviewerMap.ContainsKey('Kim RoundTrip') | Should -BeTrue
    }

    It 'round-trip preserves series data' {
        $script:readBack.ReviewerMap['Kim RoundTrip']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0624'
    }

    It 'round-trip preserves LastRunDate' {
        $script:readBack.LastRunDate | Should -Be '2026-06-24'
    }

    It 'round-trip preserves Exists=true' {
        $script:readBack.Exists | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# RS-013: ProcessedInstances tracking
# ---------------------------------------------------------------------------
Describe 'RS-013: ProcessedInstances tracking' {
    BeforeAll {
        $script:rvMap = @{}
        $script:procInst = @{}

        $items = @(
            (New-TestResolvedItem -ItemKey 'id-pi1|ent-pi1|src-pi1' -ReviewerName 'Leo Proc' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        $script:result = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items -ProcessedInstances $script:procInst `
            -InstanceId 'camp-013' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'adds InstanceId to ProcessedInstances' {
        $script:result.ProcessedInstances.ContainsKey('camp-013') | Should -BeTrue
    }

    It 'records date and series in ProcessedInstances entry' {
        $script:result.ProcessedInstances['camp-013'].date   | Should -Be '2026-06-24'
        $script:result.ProcessedInstances['camp-013'].series | Should -Be 'Daily Attestation'
    }

    It 'ProcessedInstances round-trips through Write/Read' {
        $path = Join-Path $TestDrive 'pi-reviewer.jsonl'
        Write-SPReviewerState -ReviewerMap $script:rvMap -Path $path `
            -ProcessedInstances $script:result.ProcessedInstances -LastRunDate '2026-06-24'

        $readBack = Read-SPReviewerState -Path $path
        $readBack.ProcessedInstances.ContainsKey('camp-013') | Should -BeTrue
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

    It 'stores reviewerEmail from resolved items' {
        $script:rvMap['Mia Identity']['reviewerEmail'] | Should -Be 'mia@corp.com'
    }

    It 'stores reviewerId from resolved items' {
        $script:rvMap['Mia Identity']['reviewerId'] | Should -Be 'rv-mia-001'
    }
}

# ---------------------------------------------------------------------------
# RS-015: Multiple instances with different dates
# ---------------------------------------------------------------------------
Describe 'RS-015: Multiple instances with different dates processed correctly' {
    BeforeAll {
        $script:rvMap = @{}
        $script:procInst = @{}

        # Instance 1: 2026-06-22 (Mon) -- Completed
        $items1 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items1 -ProcessedInstances $script:procInst `
            -InstanceId 'camp-015a' -InstanceDate '2026-06-22' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-22'

        # Instance 2: 2026-06-23 (Tue) -- Missed
        $items2 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Undecided' -IsGenuineDecision $false -IsAutoApproved $false)
        )
        Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items2 -ProcessedInstances $script:procInst `
            -InstanceId 'camp-015b' -InstanceDate '2026-06-23' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-23'

        # Instance 3: 2026-06-24 (Wed) -- Completed
        $items3 = @(
            (New-TestResolvedItem -ItemKey 'id-mi1|ent-mi1|src-mi1' -ReviewerName 'Nate MultiDay' `
                -HonestDecision 'Approved' -IsGenuineDecision $true)
        )
        $script:result3 = Update-SPReviewerState -ReviewerMap $script:rvMap `
            -ResolvedItems $items3 -ProcessedInstances $script:procInst `
            -InstanceId 'camp-015c' -InstanceDate '2026-06-24' `
            -SeriesName 'Daily Attestation' -TodayLabel '2026-06-24'
    }

    It 'dayLog shows all three days in order' {
        $script:rvMap['Nate MultiDay']['series']['Daily Attestation']['dayLog'] | Should -Be 'C:0622|M:0623|C:0624'
    }

    It 'campaignsObserved = 3' {
        [int]$script:rvMap['Nate MultiDay']['series']['Daily Attestation']['campaignsObserved'] | Should -Be 3
    }

    It 'campaignsCompleted = 2' {
        [int]$script:rvMap['Nate MultiDay']['series']['Daily Attestation']['campaignsCompleted'] | Should -Be 2
    }

    It 'campaignsMissed = 1' {
        [int]$script:rvMap['Nate MultiDay']['series']['Daily Attestation']['campaignsMissed'] | Should -Be 1
    }

    It 'all three instances tracked in ProcessedInstances' {
        $script:procInst.ContainsKey('camp-015a') | Should -BeTrue
        $script:procInst.ContainsKey('camp-015b') | Should -BeTrue
        $script:procInst.ContainsKey('camp-015c') | Should -BeTrue
    }

    It 'global engagementScore = 67 (2 completed / 3 observed)' {
        [int]$script:rvMap['Nate MultiDay']['global']['engagementScore'] | Should -Be 67
    }

    It 'ReviewersUpdated increments on existing reviewer' {
        $script:result3.ReviewersUpdated | Should -Be 1
    }
}
