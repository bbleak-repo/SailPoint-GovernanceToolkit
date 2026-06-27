#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    WI-7 (plan G2) -- reassigned-away exclusion DIRECTION in the COMPLETED
    daily-evidence "who did not complete" path.

.DESCRIPTION
    The COMPLETED branch of Invoke-SPDailyEvidenceReportV4(.b).ps1 builds a set of
    "reassigned away" reviewer names and skips any pending item whose cert-ASSIGNED
    reviewer is in that set (so a reviewer who legitimately handed their cert off is
    not blamed for the reassignee's still-undecided work). G2 flagged this exclusion
    as POSSIBLY INVERTED -- if the set were keyed on the CURRENT reviewer (the
    reassignee) instead of the ORIGINAL handoff-er, it would WRONGLY drop the
    accountable reviewer and leave the incomplete list empty.

    Reading the live code (cache-honesty data contract):
      - Group-SPReviewerActions (SP.AuditReportCore.psm1:501-519) builds each Reassigned
        entry with Name = the CURRENT reviewer (reassignment.to = Iris) and
        ReassignedFrom = the ORIGINAL handoff-er (reassignment.from = Hank).
      - V4/V4b (Invoke-SPDailyEvidenceReportV4.ps1:1917-1922) build $reassignedAwayNames
        from $rr.ReassignedFrom (= Hank, the ORIGINAL). CORRECT direction.
      - Group-SPCompletedPendingByReviewer resolves each pending item to its cert-assigned
        reviewer (reassignment.to = Iris) and skips it only if THAT name is in the set.
        Excluding Hank therefore never drops Iris.

    This suite PINS that correct direction so a future "simplification" cannot invert it.
    It is ADDITIVE TEST ONLY -- no production change is expected; the V4/V4b exclusion is
    confirmed correct, not inverted.

    Pipeline mirrors the sibling Tests/SP.ReviewerCompletionAttribution.Tests.ps1:
      wrap each cert's access-review items with CertificationId
        -> Group-SPAuditDecisions
        -> Get-SPCachedCampaignRoster (empty TestDrive => Live fallback from the supplied
           certs, fully self-contained -- no live mock server needed)
        -> Group-SPCompletedPendingByReviewer (under test, varying the exclusion set).
    Every expected count is read from expected-truth.json so the test stays in lockstep
    with the WI-0 truth table (camp-ch-reassign-001).

    Assertions:
      RA-01 Direction/outcome with the CORRECTLY-built exclusion set (keyed on the
            ORIGINAL handoff-er Hank): reassignee Iris IS accountable (present,
            PendingCount=3), original Hank is NOT blamed (absent), and the V4-built set
            does NOT contain the reassignee name -- the explicit not-inverted check.
      RA-02 Inversion guard: an INVERTED set (keyed on the reassignee Iris) WRONGLY drops
            the accountable reviewer -> zero incomplete rows. The regression a future
            change must not introduce.
      RA-03 Empty-set baseline: roster attribution alone is already correct (Iris present
            /PendingCount=3, Hank absent, no (Unassigned) key); the exclusion is a
            redundant safety net.
      RA-04 Production-build fidelity: Group-SPReviewerActions keys the set on the ORIGINAL
            (ReassignedFrom=Hank), with Name=the reassignee (Iris), never the reverse.
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

    # Drive the COMPLETED daily-evidence attribution path for one fixture campaign, exactly
    # as the V4/V4b COMPLETED branch does, but with a caller-supplied exclusion set so the
    # tests can vary the DIRECTION under test (correct / inverted / empty).
    function Invoke-CompletedAttribution {
        param($CampaignId, $CachePath, [hashtable]$ReassignedAwayNames = @{})
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
        return Group-SPCompletedPendingByReviewer `
            -PendingItems @($dec.Pending) `
            -DecidedItems (@($dec.Approved) + @($dec.Revoked)) `
            -Roster @($roster.Data) `
            -PrimaryReviewers @() `
            -ReassignedAwayNames $ReassignedAwayNames
    }

    # A reassigned cert shaped exactly as Get-SPAuditCertifications produces it for a
    # Hank->Iris handoff: ReviewerClassification='Reassigned', reviewer=the CURRENT
    # reviewer (reassignment.to = Iris), plus a reassignedFrom member naming the ORIGINAL
    # handoff-er (Hank). Group-SPReviewerActions reads $cert.reassignedFrom.name and
    # $cert.reviewer.name from this shape.
    function New-ShapedReassignCert {
        return [PSCustomObject]@{
            id                     = 'cert-ch-reassign-001'
            name                   = 'Cert cert-ch-reassign-001'
            ReviewerClassification = 'Reassigned'
            reviewer               = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-ch-rv-010'; name = 'Iris ReassignTo'; email = 'iris.reassignto@corp.test' }
            reassignedFrom         = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-ch-rv-009'; name = 'Hank ReassignFrom' }
            decisionsMade          = 1
            decisionsTotal         = 4
            phase                  = 'ACTIVE'
            signed                 = $null
        }
    }

    # Build the reassigned-away exclusion set EXACTLY as the V4/V4b COMPLETED branch does
    # (Invoke-SPDailyEvidenceReportV4.ps1:1917-1922): from Group-SPReviewerActions Reassigned
    # entries, keyed on $_.ReassignedFrom (the ORIGINAL handoff-er), never the current Name.
    function Get-V4ExclusionSet {
        param($Certs)
        $ra = Group-SPReviewerActions -Certifications @($Certs)
        $reassigned = if ($null -ne $ra['Reassigned']) { @($ra['Reassigned']) } else { @() }
        $excl = @{}
        foreach ($rr in $reassigned) {
            $rfName = ''
            if ($null -ne $rr.PSObject.Properties['ReassignedFrom']) { $rfName = [string]$rr.ReassignedFrom }
            if (-not [string]::IsNullOrWhiteSpace($rfName)) { $excl[$rfName] = $true }
        }
        return $excl
    }
}

Describe "RA -- reassigned-away exclusion direction (G2 / WI-7)" {

    It "RA-01 correctly-built exclusion set keeps the accountable reassignee and clears the original handoff-er" {
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-reassign-001' }
        $iris = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-010' }
        $hank = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-009' }
        $expectedPending = [int]$iris.undecidedCount + [int]$iris.autoApprovedCount   # 3

        # The V4-built exclusion set is keyed on the ORIGINAL handoff-er, never the reassignee.
        $excl = Get-V4ExclusionSet (New-ShapedReassignCert)
        $excl.ContainsKey($hank.reviewerName) | Should -BeTrue  -Because "the exclusion set must hold the ORIGINAL handoff-er (Hank)"
        $excl.ContainsKey($iris.reviewerName) | Should -BeFalse -Because "the set must NOT be keyed on the reassignee (Iris) -- the not-inverted check"

        $result = Invoke-CompletedAttribution -CampaignId 'camp-ch-reassign-001' -CachePath $TestDrive -ReassignedAwayNames $excl
        $result.Contains($iris.reviewerName) | Should -BeTrue -Because "the reassignee owns the still-undecided items and IS accountable"
        $result[$iris.reviewerName].PendingCount | Should -Be $expectedPending
        $result.Contains($hank.reviewerName) | Should -BeFalse -Because "the original handoff-er holds no items and must NOT be blamed"
    }

    It "RA-02 inversion guard: an inverted set (keyed on the reassignee) wrongly drops the accountable reviewer" {
        # If the exclusion were inverted (keyed on the CURRENT reviewer Iris), the accountable
        # reviewer's pending items would all be skipped -> zero incomplete rows. This is the
        # regression a future 'simplification' of the exclusion direction must NOT introduce.
        $inverted = @{ 'Iris ReassignTo' = $true }
        $result = Invoke-CompletedAttribution -CampaignId 'camp-ch-reassign-001' -CachePath $TestDrive -ReassignedAwayNames $inverted
        $result.Contains('Iris ReassignTo') | Should -BeFalse -Because "an inverted exclusion wrongly drops the accountable reassignee"
        @($result.Keys).Count | Should -Be 0 -Because "inverting the exclusion leaves NO incomplete rows -- the bug WI-7 guards against"
    }

    It "RA-03 empty-set baseline: roster attribution alone already gives the correct outcome" {
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-reassign-001' }
        $iris = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-010' }
        $expectedPending = [int]$iris.undecidedCount + [int]$iris.autoApprovedCount   # 3

        $result = Invoke-CompletedAttribution -CampaignId 'camp-ch-reassign-001' -CachePath $TestDrive -ReassignedAwayNames @{}
        $result.Contains('Iris ReassignTo') | Should -BeTrue -Because "roster attribution maps the items to the cert-assigned reviewer (Iris)"
        $result['Iris ReassignTo'].PendingCount | Should -Be $expectedPending
        $result.Contains('Hank ReassignFrom') | Should -BeFalse -Because "the original handoff-er holds no items"
        @($result.Keys) | Should -Not -Contain '(Unassigned)' -Because "no undecided item collapses to (Unassigned)"
    }

    It "RA-04 production build keys the exclusion set on the ORIGINAL handoff-er, never the reassignee" {
        $ra = Group-SPReviewerActions -Certifications @(New-ShapedReassignCert)
        $reassigned = @($ra['Reassigned'])
        $reassigned.Count | Should -Be 1
        $reassigned[0].Name           | Should -Be 'Iris ReassignTo'   -Because "Name is the CURRENT reviewer (reassignment.to)"
        $reassigned[0].ReassignedFrom | Should -Be 'Hank ReassignFrom' -Because "ReassignedFrom is the ORIGINAL handoff-er (reassignment.from) -- the set is keyed on THIS, not Name"
    }
}
