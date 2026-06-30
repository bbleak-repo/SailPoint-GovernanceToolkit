#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    WI-R0 (plan WI-1 + WI-3) -- COMPLETED-campaign reviewer completion attribution.

.DESCRIPTION
    Drives the daily-evidence COMPLETED "who did not complete" path against the WI-0
    cache-honesty mock fixtures and asserts that undecided items are attributed to their
    certification's ASSIGNED reviewer (item.CertificationId -> sealed/live roster), NOT
    collapsed into a single (Unassigned) row -- the root-cause R0 bug.

    Pipeline (mirrors Tests/SP.MockFixtures.Tests.ps1 fixture handling):
      wrap each cert's access-review items with CertificationId
        -> Group-SPAuditDecisions (classify decided/undecided/auto-approved)
        -> Get-SPCachedCampaignRoster (empty TestDrive => Live fallback from the supplied
           certs, so this is fully self-contained -- no live mock server needed)
        -> Group-SPCompletedPendingByReviewer (the fix under test).

    RED before Group-SPCompletedPendingByReviewer exists; GREEN after the fix.
    Every expected count is read from expected-truth.json so the test stays in lockstep
    with the WI-0 truth table.

    Assertions:
      RCA-01 Group-SPCompletedPendingByReviewer is exported.
      RCA-02 camp-ch-completed-001: undecided items attribute to the correct ASSIGNED
             reviewers (Dana/Evan), Fiona (complete) absent, NO (Unassigned) collapse,
             >=2 distinct incomplete reviewers -- per truth counts.
      RCA-03 reassignment: attributed to the cert.reviewer (Iris=reassignment.to), the
             reassigned-from reviewer (Hank) is NOT a key.
      RCA-04 no (Unassigned) leakage: every produced row Name is non-empty and is a real
             roster reviewer for that campaign.
      RCA-05 TotalCount is internally consistent (decided + undecided + auto per reviewer).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    $script:ChDir    = Join-Path (Join-Path $PSScriptRoot 'TestData') 'CacheHonesty'
    $script:Fixtures = Get-Content (Join-Path $ChDir 'mock-fixtures.json') -Raw | ConvertFrom-Json
    $script:Truth    = Get-Content (Join-Path $ChDir 'expected-truth.json') -Raw | ConvertFrom-Json

    function Get-FxItems {
        param($CertId)
        $prop = $Fixtures.accessReviewItems.PSObject.Properties[$CertId]
        if ($null -eq $prop) { return @() }
        return @($prop.Value)
    }

    # Truth campaign entries carry either 'reviewers' (normal) or 'expectedActive'.
    function Get-TruthReviewers {
        param($campEntry)
        if ($campEntry.PSObject.Properties['reviewers'])      { return @($campEntry.reviewers) }
        if ($campEntry.PSObject.Properties['expectedActive']) { return @($campEntry.expectedActive) }
        return @()
    }

    # Drive the COMPLETED daily-evidence attribution path for one fixture campaign exactly
    # as the V4/V4b COMPLETED branch does: wrap items with CertificationId, classify, resolve
    # the cert roster (empty CachePath => Live fallback built from the supplied certs), then
    # attribute pending items to the cert-assigned reviewer.
    function Invoke-CompletedAttribution {
        param($CampaignId, $CachePath, [switch]$IncludeUnsignedComplete)
        $camp  = $Fixtures.campaigns | Where-Object { $_.id -eq $CampaignId }
        $certs = @($Fixtures.certifications | Where-Object { $_.campaign.id -eq $CampaignId })
        $wrapped = @()
        foreach ($cert in $certs) {
            foreach ($it in (Get-FxItems $cert.id)) {
                $wrapped += @{ Item = $it; CertificationId = $cert.id; CertificationName = $cert.name; CampaignName = $camp.name }
            }
        }
        $dec    = Group-SPAuditDecisions -Items $wrapped
        $roster = Get-SPCachedCampaignRoster -Campaign $camp -Certifications $certs -CachePath $CachePath
        $roster.Success | Should -BeTrue -Because "roster live fallback must succeed for $CampaignId"
        # COMP-REVIEWER-COMPLETENESS: forward the opt-in switch so RCA-06 can exercise the
        # finished-but-unsigned surfacing while RCA-02..05/07 keep the default (off) path.
        return Group-SPCompletedPendingByReviewer `
            -PendingItems @($dec.Pending) `
            -DecidedItems (@($dec.Approved) + @($dec.Revoked)) `
            -Roster @($roster.Data) `
            -PrimaryReviewers @() `
            -ReassignedAwayNames @{} `
            -IncludeUnsignedComplete:$IncludeUnsignedComplete
    }
}

Describe "RCA -- COMPLETED reviewer completion attribution (R0)" {

    It "RCA-01 Group-SPCompletedPendingByReviewer is exported" {
        Get-Command Group-SPCompletedPendingByReviewer -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "RCA-02 camp-ch-completed-001 attributes undecided items to the correct ASSIGNED reviewers (no (Unassigned) collapse)" {
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-completed-001' }
        $result    = Invoke-CompletedAttribution -CampaignId 'camp-ch-completed-001' -CachePath $TestDrive

        foreach ($r in (Get-TruthReviewers $truthCamp)) {
            if ($r.reassignedAway) { continue }
            $expectedPending = [int]$r.undecidedCount + [int]$r.autoApprovedCount
            if ($expectedPending -gt 0) {
                $result.Contains($r.reviewerName) | Should -BeTrue -Because "$($r.reviewerName) has $expectedPending undecided/auto item(s) and MUST appear"
                $result[$r.reviewerName].PendingCount | Should -Be $expectedPending -Because "PendingCount for $($r.reviewerName)"
            }
            else {
                $result.Contains($r.reviewerName) | Should -BeFalse -Because "$($r.reviewerName) is complete -> not in the incomplete list"
            }
        }

        $keys = @($result.Keys)
        $keys | Should -Not -Contain '(Unassigned)' -Because "every undecided item maps to a real assigned reviewer"

        # >=2 distinct incomplete reviewers proves the collapse is gone (old code => 1 row).
        $expectedIncomplete = @(Get-TruthReviewers $truthCamp | Where-Object {
            -not $_.reassignedAway -and (([int]$_.undecidedCount + [int]$_.autoApprovedCount) -gt 0)
        }).Count
        $expectedIncomplete | Should -BeGreaterOrEqual 2
        $keys.Count | Should -Be $expectedIncomplete -Because "one row per incomplete assigned reviewer, not one collapsed row"
    }

    It "RCA-03 reassignment: undecided items attribute to the cert.reviewer (reassignment.to), not the reassigned-from reviewer" {
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-reassign-001' }
        $result    = Invoke-CompletedAttribution -CampaignId 'camp-ch-reassign-001' -CachePath $TestDrive

        $iris = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-010' }
        $hank = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-009' }
        $expectedPending = [int]$iris.undecidedCount + [int]$iris.autoApprovedCount

        $result.Contains($iris.reviewerName) | Should -BeTrue -Because "the active (reassigned-to) reviewer owns the undecided items"
        $result[$iris.reviewerName].PendingCount | Should -Be $expectedPending
        $result.Contains($hank.reviewerName) | Should -BeFalse -Because "the reassigned-FROM reviewer holds no items"
    }

    It "RCA-04 no (Unassigned) leakage: every produced row is a real roster reviewer with a non-empty name" {
        foreach ($cid in @('camp-ch-completed-001', 'camp-ch-reassign-001')) {
            $certs       = @($Fixtures.certifications | Where-Object { $_.campaign.id -eq $cid })
            $rosterNames = @($certs | ForEach-Object { [string]$_.reviewer.name })
            $result      = Invoke-CompletedAttribution -CampaignId $cid -CachePath $TestDrive
            foreach ($k in @($result.Keys)) {
                [string]$k | Should -Not -BeNullOrEmpty
                $rosterNames | Should -Contain $k -Because "row '$k' must be an assigned reviewer for $cid"
            }
        }
    }

    It "RCA-05 TotalCount is internally consistent (decided + undecided + auto per reviewer)" {
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-completed-001' }
        $result    = Invoke-CompletedAttribution -CampaignId 'camp-ch-completed-001' -CachePath $TestDrive
        foreach ($r in (Get-TruthReviewers $truthCamp)) {
            if ($r.reassignedAway) { continue }
            if (-not $result.Contains($r.reviewerName)) { continue }
            $expectedTotal = [int]$r.decidedCount + [int]$r.undecidedCount + [int]$r.autoApprovedCount
            $result[$r.reviewerName].TotalCount | Should -Be $expectedTotal -Because "TotalCount for $($r.reviewerName)"
        }
    }

    It "RCA-06 force-close (camp-ch-forceclose-001) WITH -IncludeUnsignedComplete: finished-but-unsigned (Quinn) AND undecided (Rita) both surface as non-completion" {
        # The force-close entry uses a distinct 'forceCloseReviewers' property (NOT 'reviewers'),
        # so read it directly -- Get-TruthReviewers returns @() for it by design.
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-forceclose-001' }
        $fc = @($truthCamp.forceCloseReviewers)
        $quinnTruth = $fc | Where-Object { $_.reviewerId -eq 'id-ch-rv-011' }
        $ritaTruth  = $fc | Where-Object { $_.reviewerId -eq 'id-ch-rv-012' }

        $result = Invoke-CompletedAttribution -CampaignId 'camp-ch-forceclose-001' -CachePath $TestDrive -IncludeUnsignedComplete

        # Quinn decided all 4 items but was force-signed -> finished-but-unsigned, PendingCount 0.
        $result.Contains($quinnTruth.reviewerName) | Should -BeTrue -Because "Quinn was force-signed (signedBy.id != reviewer.id) so she did not complete"
        $result[$quinnTruth.reviewerName].PendingCount | Should -Be 0 -Because "Quinn decided every item"
        $result[$quinnTruth.reviewerName].CompletionReason | Should -Be 'finished-but-unsigned'
        $result[$quinnTruth.reviewerName].TotalCount | Should -Be ([int]$quinnTruth.decidedCount) -Because "TotalCount is her decided count"

        # Rita left undecided/auto-approved work -> still attributed via the pending loop.
        $expectedRitaPending = [int]$ritaTruth.undecidedCount + [int]$ritaTruth.autoApprovedCount
        $result.Contains($ritaTruth.reviewerName) | Should -BeTrue -Because "Rita has $expectedRitaPending undecided/auto item(s)"
        $result[$ritaTruth.reviewerName].PendingCount | Should -Be $expectedRitaPending
        $result[$ritaTruth.reviewerName].CompletionReason | Should -Be 'undecided-auto-approved'
    }

    It "RCA-07 force-close WITHOUT the switch: Quinn (finished-but-unsigned) is ABSENT -- default behaviour unchanged (opt-in contract)" {
        $truthCamp  = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-forceclose-001' }
        $quinnTruth = @($truthCamp.forceCloseReviewers) | Where-Object { $_.reviewerId -eq 'id-ch-rv-011' }

        $result = Invoke-CompletedAttribution -CampaignId 'camp-ch-forceclose-001' -CachePath $TestDrive

        $result.Contains($quinnTruth.reviewerName) | Should -BeFalse -Because "without -IncludeUnsignedComplete the finished-but-unsigned reviewer is NOT surfaced (default path identical)"
    }
}
