#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for SP.EntitlementState -- persistent per-entitlement state tracking
    across campaign instances.

.DESCRIPTION
    Validates the state machine, JSONL round-trip, ProcessedInstances tracking,
    stateLog format, consecutiveUndecided counters, scope detection, and the
    UNDECIDED->PENDING regression guard.

    ES-001: Read empty/missing file returns empty StateMap, Exists=false
    ES-002: Create records from resolved items (decision mapping)
    ES-003: PENDING->APPROVE transition detected as NewlyDecided
    ES-004: UNDECIDED->APPROVE transition detected as NewlyDecided
    ES-005: UNDECIDED->PENDING regression guard (skip, keep UNDECIDED)
    ES-006: Same state = no stateLog append, only metadata update
    ES-007: Dropped from scope (item not in resolved items -> inCurrentScope=false)
    ES-008: Already-dropped items not re-reported
    ES-009: StateSummary counts correct
    ES-010: stateLog format (P:0624|A:0625)
    ES-011: Write/Read JSONL round-trip with _meta line
    ES-012: ProcessedInstances tracking (InstanceId added to set)
    ES-013: ProcessedInstances in _meta survives round-trip
    ES-014: consecutiveUndecided counter increments/resets
    ES-015: Multiple instances processed chronologically
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
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items -InstanceId 'camp-002' -InstanceDate '2026-06-24' `
            -TodayLabel '2026-06-24'
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

        # Now approve it
        $approved = New-TestResolvedItem -ItemKey 'id-pd|ent-pd|src-pd' `
            -HonestDecision 'Approved'
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($approved) -InstanceId 'camp-003b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'prior state was PENDING' {
        $script:priorState | Should -Be 'PENDING'
    }

    It 'detects the transition as NewlyDecided' {
        $script:result.NewlyDecided.Count | Should -Be 1
        $script:result.NewlyDecided[0].PriorState | Should -Be 'PENDING'
        $script:result.NewlyDecided[0].NewState   | Should -Be 'APPROVE'
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
    }

    It 'reports zero state changes' {
        $script:result.StateChanged | Should -Be 0
    }

    It 'reports zero NewlyDecided' {
        $script:result.NewlyDecided.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-006: Same state = no stateLog append, only metadata update
# ---------------------------------------------------------------------------
Describe 'ES-006: Same state does not append to stateLog' {
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
# ES-007: Dropped from scope
# ---------------------------------------------------------------------------
Describe 'ES-007: Items not in resolved items are marked dropped from scope' {
    BeforeAll {
        $script:stateMap = @{}
        $itemA = New-TestResolvedItem -ItemKey 'id-keep|ent-keep|src-keep' -HonestDecision 'Approved'
        $itemB = New-TestResolvedItem -ItemKey 'id-drop|ent-drop|src-drop' -HonestDecision 'Approved' `
            -IdentityName 'Drop User' -AccessName 'Drop Access' -SourceName 'Drop Source'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA, $itemB) -InstanceId 'camp-007a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # Second pass: only itemA is present
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA) -InstanceId 'camp-007b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'
    }

    It 'marks the missing item as inCurrentScope=false' {
        $script:stateMap['id-drop|ent-drop|src-drop']['inCurrentScope'] | Should -BeFalse
    }

    It 'reports the dropped item in DroppedFromScope' {
        $script:result.DroppedFromScope.Count | Should -Be 1
        $script:result.DroppedFromScope[0].ItemKey | Should -Be 'id-drop|ent-drop|src-drop'
    }

    It 'keeps the still-present item as inCurrentScope=true' {
        $script:stateMap['id-keep|ent-keep|src-keep']['inCurrentScope'] | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# ES-008: Already-dropped items not re-reported
# ---------------------------------------------------------------------------
Describe 'ES-008: Already-dropped items are not re-reported' {
    BeforeAll {
        $script:stateMap = @{}
        $itemA = New-TestResolvedItem -ItemKey 'id-keep2|ent-keep2|src-keep2' -HonestDecision 'Approved'
        $itemB = New-TestResolvedItem -ItemKey 'id-drop2|ent-drop2|src-drop2' -HonestDecision 'Approved' `
            -IdentityName 'Drop User 2' -AccessName 'Drop Access 2'
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA, $itemB) -InstanceId 'camp-008a' `
            -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # First drop
        Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA) -InstanceId 'camp-008b' `
            -InstanceDate '2026-06-25' -TodayLabel '2026-06-25'

        # Second pass with same item still absent
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($itemA) -InstanceId 'camp-008c' `
            -InstanceDate '2026-06-26' -TodayLabel '2026-06-26'
    }

    It 'does not re-report the already-dropped item' {
        $script:result.DroppedFromScope.Count | Should -Be 0
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
# ES-010: stateLog format
# ---------------------------------------------------------------------------
Describe 'ES-010: stateLog format uses abbreviation:MMDD pipe-separated' {
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

    It 'stateLog shows P:0624|A:0625' {
        $script:stateMap['id-log|ent-log|src-log']['stateLog'] | Should -Be 'P:0624|A:0625'
    }

    It 'entries are chronologically ordered by MMDD' {
        $log = $script:stateMap['id-log|ent-log|src-log']['stateLog']
        $parts = $log.Split('|')
        $dates = @($parts | ForEach-Object { $_.Substring(2) })
        $sorted = @($dates | Sort-Object)
        ($dates -join ',') | Should -Be ($sorted -join ',')
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
        Write-SPEntitlementState -StateMap $script:stateMap -Path $script:filePath `
            -ProcessedInstances $script:procInst -LastRunDate '2026-06-24'

        $script:readBack = Read-SPEntitlementState -Path $script:filePath
    }

    It 'file exists after write' {
        Test-Path $script:filePath | Should -BeTrue
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

    It 'round-trip preserves Exists=true' {
        $script:readBack.Exists | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# ES-012: ProcessedInstances tracking
# ---------------------------------------------------------------------------
Describe 'ES-012: ProcessedInstances tracking' {
    BeforeAll {
        $script:stateMap = @{}
        $item = New-TestResolvedItem -ItemKey 'id-pi|ent-pi|src-pi' -HonestDecision 'Approved'
        $script:procInst = @{}
        $script:result = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems @($item) -ProcessedInstances $script:procInst `
            -InstanceId 'camp-012' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'
    }

    It 'adds InstanceId to ProcessedInstances' {
        $script:result.ProcessedInstances.ContainsKey('camp-012') | Should -BeTrue
    }

    It 'records instanceDate in ProcessedInstances entry' {
        $script:result.ProcessedInstances['camp-012'].instanceDate | Should -Be '2026-06-24'
    }

    It 'records processedDate in ProcessedInstances entry' {
        $script:result.ProcessedInstances['camp-012'].processedDate | Should -Be '2026-06-24'
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
# ES-014: consecutiveUndecided counter increments/resets
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

        # Second: still UNDECIDED (same state) -- counter increments to 2
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

    It 'increments to 2 when UNDECIDED repeats' {
        $script:countAfterSecond | Should -Be 2
    }

    It 'resets to 0 when decision changes to APPROVE' {
        $script:countAfterReset | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# ES-015: Multiple instances processed chronologically
# ---------------------------------------------------------------------------
Describe 'ES-015: Multiple instances processed chronologically' {
    BeforeAll {
        $script:stateMap = @{}
        $script:procInst = @{}

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
            -ResolvedItems $items1 -ProcessedInstances $script:procInst `
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
            -ResolvedItems $items2 -ProcessedInstances $script:procInst `
            -InstanceId 'camp-015b' -InstanceDate '2026-06-24' -TodayLabel '2026-06-24'

        # Instance 3: B is approved too
        $items3 = @(
            (New-TestResolvedItem -ItemKey 'id-mi-a|ent-mi-a|src-mi' `
                -HonestDecision 'Approved' -IdentityName 'Alpha'),
            (New-TestResolvedItem -ItemKey 'id-mi-b|ent-mi-b|src-mi' `
                -HonestDecision 'Approved' -IdentityName 'Bravo')
        )
        $script:result3 = Update-SPEntitlementState -StateMap $script:stateMap `
            -ResolvedItems $items3 -ProcessedInstances $script:procInst `
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

    It 'all three instances tracked in ProcessedInstances' {
        $script:procInst.ContainsKey('camp-015a') | Should -BeTrue
        $script:procInst.ContainsKey('camp-015b') | Should -BeTrue
        $script:procInst.ContainsKey('camp-015c') | Should -BeTrue
    }

    It 'stateLog shows chronological progression for item A' {
        $log = $script:stateMap['id-mi-a|ent-mi-a|src-mi']['stateLog']
        $log | Should -Be 'P:0623|A:0624'
    }

    It 'stateLog shows chronological progression for item B' {
        $log = $script:stateMap['id-mi-b|ent-mi-b|src-mi']['stateLog']
        $log | Should -Be 'P:0623|A:0625'
    }

    It 'final StateSummary shows 2 APPROVE, 0 PENDING' {
        $script:result3.StateSummary.APPROVE | Should -Be 2
        $script:result3.StateSummary.PENDING | Should -Be 0
    }
}
