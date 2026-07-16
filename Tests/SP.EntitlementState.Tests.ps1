#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for SP.EntitlementState -- persistent per-entitlement state tracking
    across campaign instances.

.DESCRIPTION
    Validates the state machine, JSONL round-trip, stateLog format (yyyyMMdd day keys),
    derived consecutiveUndecided, the scope sweep (orchestrator-owned), corrupt-file
    accounting, re-processing convergence (ACTIVE instances), and the
    UNDECIDED->PENDING regression guard.

    ES-001: Read empty/missing file returns empty StateMap, Exists=false
    ES-002: Create records from resolved items (decision mapping, instance-dated)
    ES-003: PENDING->APPROVE transition detected as NewlyDecided
    ES-004: UNDECIDED->APPROVE transition detected as NewlyDecided
    ES-005: UNDECIDED->PENDING regression guard (skip, keep UNDECIDED)
    ES-006: Same state = no stateLog duplication, only metadata update
    ES-007: Scope sweep drops items absent from their series' newest instance
    ES-008: Scope sweep is idempotent -- reruns drop nothing new
    ES-009: StateSummary counts correct
    ES-010: stateLog format (P:20260624|A:20260625) incl. year-boundary ordering
    ES-011: Write/Read JSONL round-trip with _meta line
    ES-012: Update does NOT mark ProcessedInstances (orchestrator owns it)
    ES-013: ProcessedInstances in _meta survives round-trip
    ES-014: consecutiveUndecided derives from the trailing P/U run
    ES-015: Multiple instances processed chronologically
    ES-016: Re-processing the same instance converges (ACTIVE campaign day upgrade)
    ES-017: Out-of-order backfill never regresses current state
    ES-018: Corrupt lines are counted in SkippedLines, valid lines still load
    ES-019: Retention prune removes only long-out-of-scope records
    ES-020: First-seen-already-decided is NOT NewlyDecided (no observed transition)
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.EntitlementState.psm1') -Force -DisableNameChecking

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
# ES-001: Read empty/missing file
# ---------------------------------------------------------------------------
Describe 'ES-001: Read empty/missing file returns empty StateMap' {
    It 'returns Exists=false and empty StateMap for a non-existent path' {
        $fakePath = Join-Path $TestDrive 'nonexistent-entitlement-state.jsonl'
        $result = Read-SPEntitlementState -Path $fakePath

        $result.Exists     | Should -BeFalse
        $result.StateMap   | Should -BeOfType [hashtable]
        $result.StateMap.Count | Should -Be 0
        $result.RecordCount    | Should -Be 0
        $result.ProcessedInstances | Should -BeOfType [hashtable]
        $result.ProcessedInstances.Count | Should -Be 0
        $result.SkippedLines | Should -Be 0
    }

    It 'returns Exists=true and empty StateMap for an empty file' {
        $emptyFile = Join-Path $TestDrive 'empty-state.jsonl'
        '' | Set-Content -Path $emptyFile -NoNewline
        $result = Read-SPEntitlementState -Path $emptyFile

        $result.Exists     | Should -BeTrue
        $result.StateMap.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-002: Create records from resolved items (decision mapping)
# ---------------------------------------------------------------------------
Describe 'ES-002: Create records from resolved items' {
    BeforeAll {
        $script:stateMap = @{}
        $approved  = New-TestResolvedItem -ItemKey 'id-a|ent-a|src-a' -HonestDecision 'Approved'
        $revoked   = New-TestResolvedItem -ItemKey 'id-b|ent-b|src-b' -HonestDecision 'Revoked'
        $autoUndec = New-TestResolvedItem -ItemKey 'id-c|ent-c|src-c' -HonestDecision 'Undecided' `
            -IsAutoApproved $true -IsGenuineDecision $false
        $pending   = New-TestResolvedItem -ItemKey 'id-d|ent-d|src-d' -HonestDecision 'Undecided' `
            -IsAutoApproved $false -IsGenuineDecision $false

        $items = @($approved, $revoked, $autoUndec, $pending)
        # TodayLabel deliberately differs from InstanceDate: every record date must
        # come from the campaign's own day, never the processing day.
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items -InstanceId 'camp-002' -InstanceDate '2026-06-24' `
            -SeriesName 'daily attestation' -TodayLabel '2026-07-15'
    }

    It 'maps Approved -> APPROVE' {
        $script:stateMap['id-a|ent-a|src-a']['currentDecision'] | Should -Be 'APPROVE'
    }

    It 'maps Revoked -> REVOKE' {
        $script:stateMap['id-b|ent-b|src-b']['currentDecision'] | Should -Be 'REVOKE'
    }

    It 'maps Undecided + auto-approved -> UNDECIDED' {
        $script:stateMap['id-c|ent-c|src-c']['currentDecision'] | Should -Be 'UNDECIDED'
    }

    It 'maps Undecided + not auto-approved -> PENDING' {
        $script:stateMap['id-d|ent-d|src-d']['currentDecision'] | Should -Be 'PENDING'
    }

    It 'reports StateNew = 4' {
        $script:result.StateNew | Should -Be 4
    }

    It 'stamps record dates from the INSTANCE date, not the processing date' {
        $script:stateMap['id-a|ent-a|src-a']['firstSeenDate'] | Should -Be '2026-06-24'
        $script:stateMap['id-a|ent-a|src-a']['lastSeenDate']  | Should -Be '2026-06-24'
        $script:stateMap['id-a|ent-a|src-a']['lastStateChangeDate'] | Should -Be '2026-06-24'
    }

    It 'stamps the series name on records (scope sweep depends on it)' {
        $script:stateMap['id-a|ent-a|src-a']['seriesName'] | Should -Be 'daily attestation'
    }
}

# ---------------------------------------------------------------------------
# ES-003: PENDING->APPROVE detected as NewlyDecided
# ---------------------------------------------------------------------------
Describe 'ES-003: PENDING->APPROVE transition detected as NewlyDecided' {
    BeforeAll {
        $script:stateMap = @{}
        $pending = New-TestResolvedItem -ItemKey 'id-pd|ent-pd|src-pd' `
            -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($pending) -InstanceId 'camp-003a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # Confirm PENDING state was set
        $script:priorState = $script:stateMap['id-pd|ent-pd|src-pd']['currentDecision']

        # Now approve it (processing happens later than the campaign day)
        $approved = New-TestResolvedItem -ItemKey 'id-pd|ent-pd|src-pd' `
            -HonestDecision 'Approved'
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($approved) -InstanceId 'camp-003b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-07-15'
    }

    It 'prior state was PENDING' {
        $script:priorState | Should -Be 'PENDING'
    }

    It 'detects the transition as NewlyDecided' {
        $script:result.NewlyDecided.Count | Should -Be 1
        $script:result.NewlyDecided[0].PriorState | Should -Be 'PENDING'
        $script:result.NewlyDecided[0].NewState   | Should -Be 'APPROVE'
    }

    It 'stamps DecisionDate with the campaign day, never the processing day' {
        $script:result.NewlyDecided[0].DecisionDate | Should -Be '2026-06-25'
    }

    It 'updates currentDecision to APPROVE' {
        $script:stateMap['id-pd|ent-pd|src-pd']['currentDecision'] | Should -Be 'APPROVE'
    }

    It 'records priorDecision = PENDING' {
        $script:stateMap['id-pd|ent-pd|src-pd']['priorDecision'] | Should -Be 'PENDING'
    }
}

# ---------------------------------------------------------------------------
# ES-004: UNDECIDED->APPROVE detected as NewlyDecided
# ---------------------------------------------------------------------------
Describe 'ES-004: UNDECIDED->APPROVE transition detected as NewlyDecided' {
    BeforeAll {
        $script:stateMap = @{}
        $undecided = New-TestResolvedItem -ItemKey 'id-ud|ent-ud|src-ud' `
            -HonestDecision 'Undecided' -IsAutoApproved $true -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($undecided) -InstanceId 'camp-004a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $script:priorState = $script:stateMap['id-ud|ent-ud|src-ud']['currentDecision']

        $approved = New-TestResolvedItem -ItemKey 'id-ud|ent-ud|src-ud' `
            -HonestDecision 'Approved'
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($approved) -InstanceId 'camp-004b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'prior state was UNDECIDED' {
        $script:priorState | Should -Be 'UNDECIDED'
    }

    It 'detects the UNDECIDED->APPROVE transition as NewlyDecided' {
        $script:result.NewlyDecided.Count | Should -Be 1
        $script:result.NewlyDecided[0].PriorState | Should -Be 'UNDECIDED'
        $script:result.NewlyDecided[0].NewState   | Should -Be 'APPROVE'
    }

    It 'reports StateChanged = 1' {
        $script:result.StateChanged | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# ES-005: UNDECIDED->PENDING regression guard
# ---------------------------------------------------------------------------
Describe 'ES-005: UNDECIDED->PENDING regression guard' {
    BeforeAll {
        $script:stateMap = @{}
        # First: set item to UNDECIDED (auto-approved in closed campaign)
        $undecided = New-TestResolvedItem -ItemKey 'id-rg|ent-rg|src-rg' `
            -HonestDecision 'Undecided' -IsAutoApproved $true -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($undecided) -InstanceId 'camp-005a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # Second: new active campaign has same item as Undecided + NOT auto (= PENDING)
        $pending = New-TestResolvedItem -ItemKey 'id-rg|ent-rg|src-rg' `
            -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false `
            -ReviewerName 'New Reviewer'
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($pending) -InstanceId 'camp-005b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'keeps state as UNDECIDED (does not regress to PENDING)' {
        $script:stateMap['id-rg|ent-rg|src-rg']['currentDecision'] | Should -Be 'UNDECIDED'
    }

    It 'still updates metadata (lastSeenDate, inCurrentScope)' {
        $script:stateMap['id-rg|ent-rg|src-rg']['inCurrentScope'] | Should -BeTrue
        $script:stateMap['id-rg|ent-rg|src-rg']['lastSeenDate'] | Should -Be '2026-06-25'
    }

    It 'reports zero state changes' {
        $script:result.StateChanged | Should -Be 0
    }

    It 'reports zero NewlyDecided' {
        $script:result.NewlyDecided.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-006: Same state = no stateLog duplication, only metadata update
# ---------------------------------------------------------------------------
Describe 'ES-006: Same state does not duplicate the stateLog entry' {
    BeforeAll {
        $script:stateMap = @{}
        $item = New-TestResolvedItem -ItemKey 'id-ss|ent-ss|src-ss' -HonestDecision 'Approved'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($item) -InstanceId 'camp-006a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $script:logAfterFirst = $script:stateMap['id-ss|ent-ss|src-ss']['stateLog']

        # Process same item again with same decision on same day
        $item2 = New-TestResolvedItem -ItemKey 'id-ss|ent-ss|src-ss' -HonestDecision 'Approved' `
            -ReviewerName 'Updated Reviewer'
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($item2) -InstanceId 'camp-006b' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'
    }

    It 'does not duplicate the stateLog entry' {
        $script:stateMap['id-ss|ent-ss|src-ss']['stateLog'] | Should -Be $script:logAfterFirst
    }

    It 'updates reviewer metadata' {
        $script:stateMap['id-ss|ent-ss|src-ss']['reviewerName'] | Should -Be 'Updated Reviewer'
    }

    It 'reports zero state changes' {
        $script:result.StateChanged | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-007: Scope sweep (orchestrator-owned) drops items absent from their
# series' newest instance
# ---------------------------------------------------------------------------
Describe 'ES-007: Scope sweep drops items absent from their series newest instance' {
    BeforeAll {
        $script:stateMap = @{}
        $itemA = New-TestResolvedItem -ItemKey 'id-keep|ent-keep|src-keep' -HonestDecision 'Approved'
        $itemB = New-TestResolvedItem -ItemKey 'id-drop|ent-drop|src-drop' -HonestDecision 'Approved' `
            -IdentityName 'Drop User' -AccessName 'Drop Access' -SourceName 'Drop Source'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA, $itemB) -InstanceId 'camp-007a' `
            -InstanceDate '2026-06-24' -SeriesName 'daily' -TodayLabel '2026-06-24'

        # Newest instance (06-25) only contains itemA
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA) -InstanceId 'camp-007b' `
            -InstanceDate '2026-06-25' -SeriesName 'daily' -TodayLabel '2026-06-25'

        $script:sweep = Invoke-SPEntitlementScopeSweep -StateMap $script:stateMap `
            -SeriesNewestDates @{ 'daily' = '2026-06-25' } -TodayLabel '2026-06-25'
    }

    It 'marks the missing item as inCurrentScope=false' {
        $script:stateMap['id-drop|ent-drop|src-drop']['inCurrentScope'] | Should -BeFalse
    }

    It 'reports the dropped item in DroppedFromScope' {
        $script:sweep.DroppedFromScope.Count | Should -Be 1
        $script:sweep.DroppedFromScope[0].ItemKey | Should -Be 'id-drop|ent-drop|src-drop'
    }

    It 'keeps the still-present item as inCurrentScope=true' {
        $script:stateMap['id-keep|ent-keep|src-keep']['inCurrentScope'] | Should -BeTrue
    }

    It 'leaves records of series with no known newest date untouched' {
        $foreign = @{ itemKey = 'x'; seriesName = 'quarterly'; lastSeenDate = '2026-01-01'
                      inCurrentScope = $true; identityName = ''; accessName = ''; sourceName = ''
                      currentDecision = 'PENDING' }
        $map2 = @{ 'x' = $foreign }
        $s2 = Invoke-SPEntitlementScopeSweep -StateMap $map2 `
            -SeriesNewestDates @{ 'daily' = '2026-06-25' } -TodayLabel '2026-06-25'
        $map2['x']['inCurrentScope'] | Should -BeTrue
        $s2.DroppedFromScope.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-008: Scope sweep is idempotent -- a same-day rerun drops nothing new
# ---------------------------------------------------------------------------
Describe 'ES-008: Scope sweep is idempotent across reruns' {
    BeforeAll {
        $script:stateMap = @{}
        $itemA = New-TestResolvedItem -ItemKey 'id-keep2|ent-keep2|src-keep2' -HonestDecision 'Approved'
        $itemB = New-TestResolvedItem -ItemKey 'id-drop2|ent-drop2|src-drop2' -HonestDecision 'Approved' `
            -IdentityName 'Drop User 2' -AccessName 'Drop Access 2'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA, $itemB) -InstanceId 'camp-008a' `
            -InstanceDate '2026-06-24' -SeriesName 'daily' -TodayLabel '2026-06-24'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA) -InstanceId 'camp-008b' `
            -InstanceDate '2026-06-25' -SeriesName 'daily' -TodayLabel '2026-06-25'

        $newest = @{ 'daily' = '2026-06-25' }
        $script:sweep1 = Invoke-SPEntitlementScopeSweep -StateMap $script:stateMap `
            -SeriesNewestDates $newest -TodayLabel '2026-06-25'
        # Same-day rerun: NOTHING new processed -- the sweep must not drop or flip anything.
        $script:sweep2 = Invoke-SPEntitlementScopeSweep -StateMap $script:stateMap `
            -SeriesNewestDates $newest -TodayLabel '2026-06-25'
    }

    It 'first sweep reports the drop' {
        $script:sweep1.DroppedFromScope.Count | Should -Be 1
    }

    It 'rerun does not re-report the already-dropped item' {
        $script:sweep2.DroppedFromScope.Count | Should -Be 0
    }

    It 'rerun keeps the in-scope item in scope (no mass drop on rerun)' {
        $script:stateMap['id-keep2|ent-keep2|src-keep2']['inCurrentScope'] | Should -BeTrue
    }

    It 'item remains inCurrentScope=false' {
        $script:stateMap['id-drop2|ent-drop2|src-drop2']['inCurrentScope'] | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# ES-009: StateSummary counts correct
# ---------------------------------------------------------------------------
Describe 'ES-009: StateSummary counts in-scope items by state' {
    BeforeAll {
        $script:stateMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-s1|ent-s1|src-s1' -HonestDecision 'Approved'),
            (New-TestResolvedItem -ItemKey 'id-s2|ent-s2|src-s2' -HonestDecision 'Approved'),
            (New-TestResolvedItem -ItemKey 'id-s3|ent-s3|src-s3' -HonestDecision 'Revoked'),
            (New-TestResolvedItem -ItemKey 'id-s4|ent-s4|src-s4' -HonestDecision 'Undecided' `
                -IsAutoApproved $true -IsGenuineDecision $false),
            (New-TestResolvedItem -ItemKey 'id-s5|ent-s5|src-s5' -HonestDecision 'Undecided' `
                -IsAutoApproved $false -IsGenuineDecision $false)
        )
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items -InstanceId 'camp-009' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'
    }

    It 'counts 2 APPROVE' {
        $script:result.StateSummary.APPROVE | Should -Be 2
    }

    It 'counts 1 REVOKE' {
        $script:result.StateSummary.REVOKE | Should -Be 1
    }

    It 'counts 1 UNDECIDED' {
        $script:result.StateSummary.UNDECIDED | Should -Be 1
    }

    It 'counts 1 PENDING' {
        $script:result.StateSummary.PENDING | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# ES-010: stateLog format (year-full day keys)
# ---------------------------------------------------------------------------
Describe 'ES-010: stateLog format uses abbreviation:yyyyMMdd pipe-separated' {
    BeforeAll {
        $script:stateMap = @{}
        $pending = New-TestResolvedItem -ItemKey 'id-log|ent-log|src-log' `
            -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($pending) -InstanceId 'camp-010a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $approved = New-TestResolvedItem -ItemKey 'id-log|ent-log|src-log' `
            -HonestDecision 'Approved'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($approved) -InstanceId 'camp-010b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'stateLog shows P:20260624|A:20260625' {
        $script:stateMap['id-log|ent-log|src-log']['stateLog'] | Should -Be 'P:20260624|A:20260625'
    }

    It 'entries are chronologically ordered by day key' {
        $log = $script:stateMap['id-log|ent-log|src-log']['stateLog']
        $parts = $log.Split('|')
        $dates = @($parts | ForEach-Object { $_.Substring(2) })
        $sorted = @($dates | Sort-Object)
        ($dates -join ',') | Should -Be ($sorted -join ',')
    }

    It 'keeps December-to-January transitions in true chronological order' {
        # The old MMdd format sorted 0105 BEFORE 1231 of the PRIOR year, rendering
        # the approval before the pending state in the audit trail.
        $r1 = Update-StateLogEntry -StateLog '' -DayKey '20251231' -StateCode 'PENDING'
        $r2 = Update-StateLogEntry -StateLog $r1.StateLog -DayKey '20260105' -StateCode 'APPROVE'
        $r2.StateLog | Should -Be 'P:20251231|A:20260105'
    }

    It 'does not collide the same calendar day across two years' {
        $r1 = Update-StateLogEntry -StateLog '' -DayKey '20250707' -StateCode 'PENDING'
        $r2 = Update-StateLogEntry -StateLog $r1.StateLog -DayKey '20260707' -StateCode 'APPROVE'
        $r2.StateLog | Should -Be 'P:20250707|A:20260707'
        $r2.Changed  | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# ES-011: Write/Read JSONL round-trip with _meta line
# ---------------------------------------------------------------------------
Describe 'ES-011: Write/Read JSONL round-trip' {
    BeforeAll {
        $script:stateMap = @{}
        $items = @(
            (New-TestResolvedItem -ItemKey 'id-rt1|ent-rt1|src-rt1' -HonestDecision 'Approved' `
                -IdentityName 'Alice' -AccessName 'Finance-RW'),
            (New-TestResolvedItem -ItemKey 'id-rt2|ent-rt2|src-rt2' -HonestDecision 'Revoked' `
                -IdentityName 'Bob' -AccessName 'Admin-Access')
        )
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items -InstanceId 'camp-011' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $script:filePath = Join-Path $TestDrive 'entitlement-state.jsonl'
        $script:procInst = @{ 'camp-011' = @{ processedDate = '2026-06-24'; instanceDate = '2026-06-24' } }
        $script:writeResult = Write-SPEntitlementState -StateMap $script:stateMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-24'

        $script:readBack = Read-SPEntitlementState -Path $script:filePath
    }

    It 'write reports Success' {
        $script:writeResult.Success | Should -BeTrue
    }

    It 'file exists after write' {
        Test-Path $script:filePath | Should -BeTrue
    }

    It 'no temp file is left behind' {
        @(Get-ChildItem $TestDrive -Filter 'entitlement-state.jsonl.*.tmp').Count | Should -Be 0
    }

    It 'round-trip preserves record count' {
        $script:readBack.RecordCount | Should -Be 2
    }

    It 'round-trip preserves item keys' {
        $script:readBack.StateMap.ContainsKey('id-rt1|ent-rt1|src-rt1') | Should -BeTrue
        $script:readBack.StateMap.ContainsKey('id-rt2|ent-rt2|src-rt2') | Should -BeTrue
    }

    It 'round-trip preserves decision state' {
        $script:readBack.StateMap['id-rt1|ent-rt1|src-rt1']['currentDecision'] | Should -Be 'APPROVE'
        $script:readBack.StateMap['id-rt2|ent-rt2|src-rt2']['currentDecision'] | Should -Be 'REVOKE'
    }

    It 'round-trip preserves LastRunDate' {
        $script:readBack.LastRunDate | Should -Be '2026-06-24'
    }

    It 'overwrite of an existing file also succeeds (File.Replace path)' {
        $second = Write-SPEntitlementState -StateMap $script:stateMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-25'
        $second.Success | Should -BeTrue
        (Read-SPEntitlementState -Path $script:filePath).LastRunDate | Should -Be '2026-06-25'
    }
}

# ---------------------------------------------------------------------------
# ES-012: Update does NOT mark ProcessedInstances (orchestrator owns it)
# ---------------------------------------------------------------------------
Describe 'ES-012: Update-SPEntitlementState does not mark ProcessedInstances' {
    It 'leaves the caller-supplied ProcessedInstances untouched' {
        # v1.1 contract: the earlier in-function marking is what skipped
        # Update-SPReviewerState for every instance (reviewer state never populated)
        # and froze ACTIVE campaigns at their first snapshot.
        $stateMap = @{}
        $procInst = @{}
        $item = New-TestResolvedItem -ItemKey 'id-pi|ent-pi|src-pi' -HonestDecision 'Approved'
        [void](Update-SPEntitlementState -StateMap $stateMap `
            -ResolvedItems @($item) -ProcessedInstances $procInst `
            -InstanceId 'camp-012' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24')

        $procInst.ContainsKey('camp-012') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# ES-013: ProcessedInstances in _meta survives round-trip
# ---------------------------------------------------------------------------
Describe 'ES-013: ProcessedInstances in _meta survives Write/Read round-trip' {
    BeforeAll {
        $script:stateMap = @{}
        $item = New-TestResolvedItem -ItemKey 'id-pi2|ent-pi2|src-pi2' -HonestDecision 'Approved'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($item) -InstanceId 'camp-013' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $script:filePath = Join-Path $TestDrive 'pi-roundtrip.jsonl'
        $procInst = @{
            'camp-013a' = @{ processedDate = '2026-06-23'; instanceDate = '2026-06-23' }
            'camp-013b' = @{ processedDate = '2026-06-24'; instanceDate = '2026-06-24' }
        }
        Write-SPEntitlementState -StateMap $script:stateMap -Path $script:filePath `
            -ProcessedInstances $procInst -LastRunDate '2026-06-24'

        $script:readBack = Read-SPEntitlementState -Path $script:filePath
    }

    It 'ProcessedInstances round-trips with correct keys' {
        $script:readBack.ProcessedInstances.ContainsKey('camp-013a') | Should -BeTrue
        $script:readBack.ProcessedInstances.ContainsKey('camp-013b') | Should -BeTrue
    }

    It 'ProcessedInstances values survive the round-trip' {
        $script:readBack.ProcessedInstances['camp-013a']['processedDate'] | Should -Be '2026-06-23'
        $script:readBack.ProcessedInstances['camp-013b']['instanceDate']  | Should -Be '2026-06-24'
    }
}

# ---------------------------------------------------------------------------
# ES-014: consecutiveUndecided derives from the trailing P/U run
# ---------------------------------------------------------------------------
Describe 'ES-014: consecutiveUndecided counter' {
    BeforeAll {
        $script:stateMap = @{}
        # First: UNDECIDED (auto-approved) -- counter starts at 1
        $undecided = New-TestResolvedItem -ItemKey 'id-cu|ent-cu|src-cu' `
            -HonestDecision 'Undecided' -IsAutoApproved $true -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($undecided) -InstanceId 'camp-014a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $script:countAfterFirst = $script:stateMap['id-cu|ent-cu|src-cu']['consecutiveUndecided']

        # Second: still UNDECIDED on the next campaign day -- counter reaches 2
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($undecided) -InstanceId 'camp-014b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'

        $script:countAfterSecond = $script:stateMap['id-cu|ent-cu|src-cu']['consecutiveUndecided']

        # Third: APPROVE -- counter resets to 0
        $approved = New-TestResolvedItem -ItemKey 'id-cu|ent-cu|src-cu' -HonestDecision 'Approved'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($approved) -InstanceId 'camp-014c' `
            -InstanceDate '2026-06-26' -TodayLabel '2026-06-26'

        $script:countAfterReset = $script:stateMap['id-cu|ent-cu|src-cu']['consecutiveUndecided']
    }

    It 'starts at 1 for first UNDECIDED' {
        $script:countAfterFirst | Should -Be 1
    }

    It 'increments to 2 when UNDECIDED repeats on a new campaign day' {
        $script:countAfterSecond | Should -Be 2
    }

    It 'resets to 0 when decision changes to APPROVE' {
        $script:countAfterReset | Should -Be 0
    }

    It 'does NOT double-count when the SAME instance day is re-processed' {
        # ACTIVE campaigns are re-captured every run until they complete; the counter
        # is derived from the day-keyed log, so a replay converges.
        $map = @{}
        $u = New-TestResolvedItem -ItemKey 'k|e|s' -HonestDecision 'Undecided' `
            -IsAutoApproved $true -IsGenuineDecision $false
        1..3 | ForEach-Object {
            Update-SPEntitlementState -StateMap $map -ResolvedItems @($u) `
                -InstanceId 'camp-x' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24' | Out-Null
        }
        $map['k|e|s']['consecutiveUndecided'] | Should -Be 1
    }

    It 'Get-SPTrailingUnreviewedCount counts the trailing P/U run only' {
        Get-SPTrailingUnreviewedCount -StateLog 'A:20260601|P:20260602|U:20260603' | Should -Be 2
        Get-SPTrailingUnreviewedCount -StateLog 'P:20260601|A:20260602' | Should -Be 0
        Get-SPTrailingUnreviewedCount -StateLog '' | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-015: Multiple instances processed chronologically
# ---------------------------------------------------------------------------
Describe 'ES-015: Multiple instances processed chronologically' {
    BeforeAll {
        $script:stateMap = @{}

        # Instance 1: items A and B as PENDING
        $items1 = @(
            (New-TestResolvedItem -ItemKey 'id-mi-a|ent-mi-a|src-mi' `
                -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false `
                -IdentityName 'Alpha'),
            (New-TestResolvedItem -ItemKey 'id-mi-b|ent-mi-b|src-mi' `
                -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false `
                -IdentityName 'Bravo')
        )
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items1 `
            -InstanceId 'camp-015a' -InstanceDate '2026-06-23' -TodayLabel '2026-06-23'

        # Instance 2: A is approved, B still pending
        $items2 = @(
            (New-TestResolvedItem -ItemKey 'id-mi-a|ent-mi-a|src-mi' `
                -HonestDecision 'Approved' -IdentityName 'Alpha'),
            (New-TestResolvedItem -ItemKey 'id-mi-b|ent-mi-b|src-mi' `
                -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false `
                -IdentityName 'Bravo')
        )
        $script:result2 = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items2 `
            -InstanceId 'camp-015b' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # Instance 3: B is approved too
        $items3 = @(
            (New-TestResolvedItem -ItemKey 'id-mi-a|ent-mi-a|src-mi' `
                -HonestDecision 'Approved' -IdentityName 'Alpha'),
            (New-TestResolvedItem -ItemKey 'id-mi-b|ent-mi-b|src-mi' `
                -HonestDecision 'Approved' -IdentityName 'Bravo')
        )
        $script:result3 = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items3 `
            -InstanceId 'camp-015c' -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'instance 2 detects A as NewlyDecided (PENDING->APPROVE)' {
        $script:result2.NewlyDecided.Count | Should -Be 1
        $script:result2.NewlyDecided[0].ItemKey | Should -Be 'id-mi-a|ent-mi-a|src-mi'
    }

    It 'instance 3 detects B as NewlyDecided (PENDING->APPROVE)' {
        $script:result3.NewlyDecided.Count | Should -Be 1
        $script:result3.NewlyDecided[0].ItemKey | Should -Be 'id-mi-b|ent-mi-b|src-mi'
    }

    It 'stateLog shows chronological progression for item A' {
        $log = $script:stateMap['id-mi-a|ent-mi-a|src-mi']['stateLog']
        $log | Should -Be 'P:20260623|A:20260624|A:20260625'
    }

    It 'stateLog shows chronological progression for item B' {
        $log = $script:stateMap['id-mi-b|ent-mi-b|src-mi']['stateLog']
        $log | Should -Be 'P:20260623|P:20260624|A:20260625'
    }

    It 'final StateSummary shows 2 APPROVE, 0 PENDING' {
        $script:result3.StateSummary.APPROVE | Should -Be 2
        $script:result3.StateSummary.PENDING | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-016: Re-processing the same instance converges (ACTIVE campaign upgrade)
# ---------------------------------------------------------------------------
Describe 'ES-016: ACTIVE-instance re-processing converges' {
    It 'a mid-day PENDING snapshot upgraded to APPROVE at close settles at APPROVE with one day entry' {
        $map = @{}
        $pending = New-TestResolvedItem -ItemKey 'act|e|s' `
            -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false
        # 09:00 capture of the ACTIVE campaign
        Update-SPEntitlementState -StateMap $map -ResolvedItems @($pending) `
            -InstanceId 'camp-act' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24' | Out-Null
        # 18:00 re-capture after the reviewer finished
        $approved = New-TestResolvedItem -ItemKey 'act|e|s' -HonestDecision 'Approved'
        $r = Update-SPEntitlementState -StateMap $map -ResolvedItems @($approved) `
            -InstanceId 'camp-act' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        $map['act|e|s']['currentDecision'] | Should -Be 'APPROVE'
        $map['act|e|s']['stateLog'] | Should -Be 'A:20260624'   # day entry UPGRADED, not duplicated
        $r.NewlyDecided.Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# ES-017: Out-of-order backfill never regresses current state
# ---------------------------------------------------------------------------
Describe 'ES-017: Out-of-order backfill never regresses current state' {
    It 'an older instance processed after a newer one only adds its history entry' {
        $map = @{}
        $approved = New-TestResolvedItem -ItemKey 'oo|e|s' -HonestDecision 'Approved'
        Update-SPEntitlementState -StateMap $map -ResolvedItems @($approved) `
            -InstanceId 'camp-new' -InstanceDate '2026-06-25' -TodayLabel '2026-06-25' | Out-Null

        $pendingOld = New-TestResolvedItem -ItemKey 'oo|e|s' `
            -HonestDecision 'Undecided' -IsAutoApproved $false -IsGenuineDecision $false
        Update-SPEntitlementState -StateMap $map -ResolvedItems @($pendingOld) `
            -InstanceId 'camp-old' -InstanceDate '2026-06-23' -TodayLabel '2026-06-25' | Out-Null

        $map['oo|e|s']['currentDecision'] | Should -Be 'APPROVE'
        $map['oo|e|s']['lastSeenDate']    | Should -Be '2026-06-25'
        $map['oo|e|s']['stateLog']        | Should -Be 'P:20260623|A:20260625'
    }
}

# ---------------------------------------------------------------------------
# ES-018: Corrupt lines are counted, valid lines still load
# ---------------------------------------------------------------------------
Describe 'ES-018: Corrupt lines are counted in SkippedLines' {
    It 'reports skipped lines and loads the valid records' {
        $path = Join-Path $TestDrive 'corrupt-state.jsonl'
        $valid = '{"itemKey":"ok|e|s","currentDecision":"APPROVE","inCurrentScope":true,"lastSeenDate":"2026-06-24"}'
        @('{"_meta":true,"lastRunDate":"2026-06-24"}', $valid, '{ this is not json', '{"noItemKey":1}') |
            Set-Content -Path $path -Encoding UTF8
        $r = Read-SPEntitlementState -Path $path -WarningAction SilentlyContinue
        $r.RecordCount  | Should -Be 1
        $r.SkippedLines | Should -Be 2
        $r.StateMap.ContainsKey('ok|e|s') | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# ES-019: Retention prune removes only long-out-of-scope records
# ---------------------------------------------------------------------------
Describe 'ES-019: Retention prune removes only long-out-of-scope records' {
    It 'prunes a record out of scope past RetentionDays, keeps fresher ones' {
        $stale = @{ itemKey = 'stale'; seriesName = 'daily'; lastSeenDate = '2026-01-01'
                    inCurrentScope = $false; identityName = ''; accessName = ''; sourceName = ''
                    currentDecision = 'PENDING' }
        $fresh = @{ itemKey = 'fresh'; seriesName = 'daily'; lastSeenDate = '2026-06-20'
                    inCurrentScope = $false; identityName = ''; accessName = ''; sourceName = ''
                    currentDecision = 'PENDING' }
        $map = @{ 'stale' = $stale; 'fresh' = $fresh }
        $s = Invoke-SPEntitlementScopeSweep -StateMap $map `
            -SeriesNewestDates @{ 'daily' = '2026-06-25' } -TodayLabel '2026-06-25' -RetentionDays 90

        $s.PrunedCount | Should -Be 1
        $map.ContainsKey('stale') | Should -BeFalse
        $map.ContainsKey('fresh') | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# ES-020: First-seen-already-decided is NOT NewlyDecided
# ---------------------------------------------------------------------------
Describe 'ES-020: First sighting of an already-decided item is not a new decision' {
    It 'reports zero NewlyDecided when the first-ever record is APPROVE' {
        # Bootstrap over historical cache: the decision may be months old -- listing it
        # as newly decided would fabricate decision-activity evidence.
        $map = @{}
        $approved = New-TestResolvedItem -ItemKey 'fs|e|s' -HonestDecision 'Approved'
        $r = Update-SPEntitlementState -StateMap $map -ResolvedItems @($approved) `
            -InstanceId 'camp-fs' -InstanceDate '2026-06-24' -TodayLabel '2026-07-15'
        $r.NewlyDecided.Count | Should -Be 0
        $r.StateNew | Should -Be 1
    }
}
