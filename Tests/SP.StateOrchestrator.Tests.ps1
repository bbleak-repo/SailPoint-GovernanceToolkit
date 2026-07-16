#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Integration tests for SP.StateOrchestrator -- the state-tracking pipeline contract.

.DESCRIPTION
    Drives Invoke-SPStateTracking end-to-end against a stubbed cache reader
    (global Get-SPCachedCampaignSeries) and the REAL SP.CampaignSeries honest
    classifier, verifying the ownership contract the original implementation broke:

    OT-01: bootstrap populates BOTH state files (reviewer state was never populated
           before v2.1: the entitlement update marked instances processed, so the
           reviewer update skipped every instance)
    OT-02: a same-day rerun is a no-op (previously it flipped EVERY record out of
           scope and zeroed the state summary)
    OT-03: ACTIVE instances re-process until COMPLETED, then lock (previously a
           mid-day snapshot froze reviewers as missed forever)
    OT-04: a corrupt state file aborts the run instead of silently rebuilding
    OT-05: Resolve-SPReportDateRange flags invalid explicit dates (exit-2 contract)
    OT-06: -Force rebuilds from scratch without double-counting
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Shared\SP.Shared.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.CampaignSeries.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.EntitlementState.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.ReviewerState.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.StateOrchestrator.psm1') -Force -DisableNameChecking

    # Raw ISC-shaped item wrapper (what the cache reader's LoadItems returns).
    function New-OTRawItem {
        param([string]$Id, [string]$User, [string]$Access, [string]$Decision, [string]$CertId = 'cert-1')
        [pscustomobject]@{
            Item = [pscustomobject]@{
                id              = $Id
                identitySummary = [pscustomobject]@{ identityId = "iid-$User"; name = $User }
                access          = [pscustomobject]@{ id = "ent-$Access"; name = $Access; type = 'ENTITLEMENT' }
                account         = [pscustomobject]@{ nativeIdentity = "CN=$User"; sourceId = 'src-1' }
                decision        = $Decision
                comments        = ''
                decisionDate    = ''
                reviewedBy      = $null
            }
            CertificationId = $CertId; CertificationName = "Cert $CertId"; CampaignName = 'OT'
        }
    }

    function New-OTRoster {
        param([string]$CertId = 'cert-1', [string]$Reviewer = 'Rita Reviewer', [string]$ReviewerId = 'rv-rita')
        @([pscustomobject]@{ CertificationId = $CertId; ReviewerName = $Reviewer; ReviewerId = $ReviewerId; ReviewerEmail = "$Reviewer@x.com"; SignedById = '' })
    }

    # Global stub the orchestrator resolves instead of the real cache reader.
    # Set $script:OTSeries before each Invoke-SPStateTracking call.
    $script:OTSeries = @()
    function global:Get-SPCachedCampaignSeries {
        param([int]$MinInstances = 1, [string]$CachePath, [string]$CorrelationID)
        return @{ Success = $true; Error = $null; Data = @{ Series = $script:OTSeries } }
    }

    function New-OTInstance {
        param([string]$CampId, [string]$Date, [string]$Status, [object[]]$Items, [object[]]$Roster)
        [pscustomobject]@{
            CampaignId   = $CampId
            CampaignName = "OT Daily - $Date"
            Status       = $Status
            Unverified   = $false
            PeriodToken  = $Date
            CachedAt     = "${Date}T18:00:00Z"
            LoadItems    = { , $Items }.GetNewClosure()
            LoadRoster   = { , $Roster }.GetNewClosure()
        }
    }

    function New-OTSeriesDef {
        param([string]$Stem = 'ot daily', [object[]]$Instances)
        [pscustomobject]@{ SeriesStem = $Stem; NormalizedStem = $Stem; Instances = $Instances }
    }
}

AfterAll {
    Remove-Item function:\Get-SPCachedCampaignSeries -ErrorAction SilentlyContinue
}

Describe 'OT-01: bootstrap populates BOTH state files' {
    It 'writes entitlement AND reviewer records from one run' {
        $mdir = Join-Path $TestDrive 'ot01'
        New-Item -ItemType Directory -Force $mdir | Out-Null
        $roster = New-OTRoster
        $items = @(
            (New-OTRawItem -Id 'i1' -User 'alice' -Access 'Finance-RW' -Decision 'APPROVE'),
            (New-OTRawItem -Id 'i2' -User 'bob' -Access 'HR-RO' -Decision $null)
        )
        $script:OTSeries = @((New-OTSeriesDef -Instances @((New-OTInstance -CampId 'c1' -Date '2026-06-24' -Status 'COMPLETED' -Items $items -Roster $roster))))

        $r = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25'

        $r.Success | Should -BeTrue
        $r.Entitlement.Total | Should -Be 2
        $r.Reviewer.Total | Should -Be 1        # the roster reviewer -- previously ALWAYS 0
        $r.Reviewer.ReviewersNew | Should -Be 1

        (Read-SPReviewerState -Path (Join-Path $mdir 'reviewer-state.jsonl')).RecordCount | Should -Be 1
        (Read-SPEntitlementState -Path (Join-Path $mdir 'entitlement-state.jsonl')).RecordCount | Should -Be 2
    }
}

Describe 'OT-02: same-day rerun is a no-op' {
    It 'does not drop records or zero the summary on an immediate rerun' {
        $mdir = Join-Path $TestDrive 'ot02'
        New-Item -ItemType Directory -Force $mdir | Out-Null
        $roster = New-OTRoster
        $items = @((New-OTRawItem -Id 'i1' -User 'alice' -Access 'Finance-RW' -Decision 'APPROVE'))
        $script:OTSeries = @((New-OTSeriesDef -Instances @((New-OTInstance -CampId 'c1' -Date '2026-06-24' -Status 'COMPLETED' -Items $items -Roster $roster))))

        $r1 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25'
        $r1.Entitlement.StateSummary.APPROVE | Should -Be 1

        # Rerun the same day: the COMPLETED instance is already processed, so nothing
        # new happens -- previously this flipped every record out of scope.
        $r2 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25'
        $r2.Success | Should -BeTrue
        $r2.InstancesProcessed | Should -Be 0
        $r2.Entitlement.DroppedFromScope.Count | Should -Be 0
        $r2.Entitlement.StateSummary.APPROVE | Should -Be 1
        $r2.Entitlement.StateMap['iid-alice|finance-rw|src-1']['inCurrentScope'] | Should -BeTrue
    }
}

Describe 'OT-03: ACTIVE instances re-process until COMPLETED' {
    It 'upgrades a mid-day missed snapshot once the reviewer finishes' {
        $mdir = Join-Path $TestDrive 'ot03'
        New-Item -ItemType Directory -Force $mdir | Out-Null
        $roster = New-OTRoster

        # 09:00 -- campaign ACTIVE, nothing decided
        $morning = @((New-OTRawItem -Id 'i1' -User 'alice' -Access 'Finance-RW' -Decision $null))
        $script:OTSeries = @((New-OTSeriesDef -Instances @((New-OTInstance -CampId 'c1' -Date '2026-06-24' -Status 'ACTIVE' -Items $morning -Roster $roster))))
        $r1 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-24'
        $r1.InstancesProcessed | Should -Be 1

        $rv1 = (Read-SPReviewerState -Path (Join-Path $mdir 'reviewer-state.jsonl')).ReviewerMap['id:rv-rita']
        $rv1['series']['ot daily']['dayLog'] | Should -Be 'M:20260624'

        # 18:00 -- same instance, now COMPLETED, reviewer decided everything
        $evening = @((New-OTRawItem -Id 'i1' -User 'alice' -Access 'Finance-RW' -Decision 'APPROVE'))
        $script:OTSeries = @((New-OTSeriesDef -Instances @((New-OTInstance -CampId 'c1' -Date '2026-06-24' -Status 'COMPLETED' -Items $evening -Roster $roster))))
        $r2 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-24'
        $r2.InstancesProcessed | Should -Be 1   # ACTIVE run did NOT lock it

        $rv2 = (Read-SPReviewerState -Path (Join-Path $mdir 'reviewer-state.jsonl')).ReviewerMap['id:rv-rita']
        $rv2['series']['ot daily']['dayLog'] | Should -Be 'C:20260624'   # day UPGRADED, not frozen at M
        [int]$rv2['global']['engagementScore'] | Should -Be 100

        # Third run: the COMPLETED instance is now locked
        $r3 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-24'
        $r3.InstancesProcessed | Should -Be 0
    }
}

Describe 'OT-04: corrupt state file aborts instead of silently rebuilding' {
    It 'returns Success=false and leaves the corrupt file untouched' {
        $mdir = Join-Path $TestDrive 'ot04'
        New-Item -ItemType Directory -Force $mdir | Out-Null
        $entPath = Join-Path $mdir 'entitlement-state.jsonl'
        'this is { not json at all' | Set-Content -Path $entPath -Encoding UTF8
        $before = Get-Content $entPath -Raw

        $script:OTSeries = @()
        $r = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25' -WarningAction SilentlyContinue

        $r.Success | Should -BeFalse
        $r.Error | Should -Match 'Refusing to overwrite'
        (Get-Content $entPath -Raw) | Should -Be $before   # months of history NOT clobbered
    }
}

Describe 'OT-05: Resolve-SPReportDateRange flags invalid explicit dates' {
    It 'sets Valid=false for an unparseable StartDate' {
        $r = Resolve-SPReportDateRange -StartDate '2026-13-45' -EndDate '2026-07-01'
        $r.Valid | Should -BeFalse
        $r.Error | Should -Match 'Invalid StartDate'
    }

    It 'stays Valid for good dates and blank optionals' {
        $r = Resolve-SPReportDateRange -DaysBack 7
        $r.Valid | Should -BeTrue
        $r.StartDate | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }
}

Describe 'OT-06: -Force rebuilds from scratch without double-counting' {
    It 'yields identical counters after two -Force runs over the same cache' {
        $mdir = Join-Path $TestDrive 'ot06'
        New-Item -ItemType Directory -Force $mdir | Out-Null
        $roster = New-OTRoster
        $items = @(
            (New-OTRawItem -Id 'i1' -User 'alice' -Access 'Finance-RW' -Decision 'APPROVE'),
            (New-OTRawItem -Id 'i2' -User 'bob' -Access 'HR-RO' -Decision $null)
        )
        $script:OTSeries = @((New-OTSeriesDef -Instances @((New-OTInstance -CampId 'c1' -Date '2026-06-24' -Status 'COMPLETED' -Items $items -Roster $roster))))

        $r1 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25' -Force
        $r2 = Invoke-SPStateTracking -MetricsPath $mdir -TodayLabel '2026-06-25' -Force

        $r2.Entitlement.Total | Should -Be $r1.Entitlement.Total
        $r2.Reviewer.Total    | Should -Be $r1.Reviewer.Total
        # consecutiveUndecided must not inflate across -Force rebuilds (derived, not incremented)
        $r2.Entitlement.StateMap['iid-bob|hr-ro|src-1']['consecutiveUndecided'] | Should -Be 1
        # Reviewer counters identical too
        $rv = $r2.Reviewer.ReviewerMap['id:rv-rita']
        [int]$rv['series']['ot daily']['campaignsObserved'] | Should -Be 1
    }
}
