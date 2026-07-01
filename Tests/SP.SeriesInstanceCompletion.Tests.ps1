<#
.SYNOPSIS
    Tests for SP.CampaignSeries helper Get-SPSeriesInstanceCompletion -- the PURE per-campaign
    HONEST completion + source-aware removal-status summary for ONE materialized series instance
    (the newest-instance panel V4e renders). It REUSES the existing engines (no reinvention):
    Resolve-SPSeriesItemState / ConvertTo-SPCanonicalDecision for the honest per-item decision,
    Group-SPCompletedPendingByReviewer for the genuine reviewer sign-off (admin force-close is NOT
    a sign-off), and Get-SPRevocationDisposition for the removal status.

    The instance fixtures are the COMMITTED rich cache (Tests/TestData/SeriesAttestation/cache):
    a "Daily Attestation Manager Campaign - <date>" series whose newest instance (dam-11) is
    COMPLETED with 3 genuine APPROVE + 1 PENDING, and whose dam-02 instance carries a lone
    idNowAutoApproved APPROVE that the honest classifier demotes.

    SIC-01: command exported.
    SIC-02: newest instance (dam-11) exact honest numbers.
    SIC-03: dam-02 auto-approve honesty guard (idNowAutoApproved -> Undecided).
    SIC-04: removal mapping (Deprovisioned / Queued / Pending) via a synthetic REVOKE instance.
    SIC-05: empty Items -> Success with all-zero counts, no throw.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    # Resolve the COMMITTED cache fixture (mirrors SP.SeriesAttestationE2E.Tests.ps1).
    $script:CacheDir = Join-Path (Join-Path (Join-Path $PSScriptRoot 'TestData') 'SeriesAttestation') 'cache'

    $r = Get-SPCachedCampaignSeries -CachePath $script:CacheDir
    $script:series = @($r.Data.Series)[0]
    $script:instances = @($script:series.Instances)

    # Newest instance = max OrderIndex (the reader assigns 0..N-1 ascending by chrono key).
    $script:newest = $script:instances | Sort-Object -Property OrderIndex -Descending | Select-Object -First 1
    $script:newestItems  = @(& $script:newest.LoadItems)
    $script:newestRoster = @(& $script:newest.LoadRoster)

    # The dam-02 instance (lone idNowAutoApproved APPROVE).
    $script:dam02 = $script:instances | Where-Object { $_.CampaignId -eq 'dam-02' } | Select-Object -First 1

    # Synthetic REVOKE-item factory (raw ISC item shape) to exercise Get-SPRevocationDisposition.
    function New-SICRevokeWrapper {
        param([string]$IdentityId, [string]$AccessId, [bool]$Completed, [string]$SourceType, [string]$SourceName)
        $raw = [PSCustomObject]@{
            identitySummary = [PSCustomObject]@{ identityId = $IdentityId; name = $IdentityId }
            access          = [PSCustomObject]@{ id = $AccessId; type = 'ENTITLEMENT'; name = $AccessId; source = [PSCustomObject]@{ id = 'src-x'; name = $SourceName } }
            account         = [PSCustomObject]@{ nativeIdentity = "CN=$IdentityId"; sourceId = 'src-x' }
            decision        = 'REVOKE'
            comment         = ''
            decisionDate    = '2026-06-30T10:00:00Z'
            completed       = $Completed
            sourceType      = $SourceType
        }
        [PSCustomObject]@{ CertificationId = 'syn-cert'; CampaignName = 'Synthetic Revoke Campaign'; Item = $raw }
    }
}

Describe 'SIC-01 command exported' {
    It 'exports Get-SPSeriesInstanceCompletion' {
        (Get-Command Get-SPSeriesInstanceCompletion -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
    }
}

Describe 'SIC-02 newest instance (dam-11) exact honest completion numbers' {
    BeforeAll {
        $script:res = Get-SPSeriesInstanceCompletion -Items $script:newestItems -Roster $script:newestRoster `
            -Status $script:newest.Status -Unverified ([bool]$script:newest.Unverified)
        $script:d = $script:res.Data
    }
    It 'succeeds' { $script:res.Success | Should -BeTrue }
    It 'picks dam-11 as the newest instance' { $script:newest.CampaignId | Should -Be 'dam-11' }
    It 'Total is 4' { $script:d.Total | Should -Be 4 }
    It 'Approved is 3 (three genuine APPROVE)' { $script:d.Approved | Should -Be 3 }
    It 'Revoked is 0' { $script:d.Revoked | Should -Be 0 }
    It 'Undecided is 1 (the lone PENDING)' { $script:d.Undecided | Should -Be 1 }
    It 'ItemsDecided is 3' { $script:d.ItemsDecided | Should -Be 3 }
    It 'ItemsDecidedPct is 75 (V4b formula)' { $script:d.ItemsDecidedPct | Should -Be 75 }
    It 'ReviewersTotal is 1 (rv-mona)' { $script:d.ReviewersTotal | Should -Be 1 }
    It 'ReviewersSigned is 0 (Mona left the PENDING item undecided)' { $script:d.ReviewersSigned | Should -Be 0 }
    It 'Removal is 0/0/0 (no revokes)' {
        $script:d.Removal.Deprovisioned | Should -Be 0
        $script:d.Removal.Queued        | Should -Be 0
        $script:d.Removal.Pending       | Should -Be 0
    }
    It 'Status is echoed back' { $script:d.Status | Should -Be $script:newest.Status }
}

Describe 'SIC-03 dam-02 auto-approve honesty guard' {
    BeforeAll {
        $items  = @(& $script:dam02.LoadItems)
        $roster = @(& $script:dam02.LoadRoster)
        $script:res2 = Get-SPSeriesInstanceCompletion -Items $items -Roster $roster -Status $script:dam02.Status
        $script:d2 = $script:res2.Data
    }
    It 'succeeds' { $script:res2.Success | Should -BeTrue }
    It 'demotes the lone idNowAutoApproved APPROVE -> Approved 0' { $script:d2.Approved | Should -Be 0 }
    It 'counts all four as Undecided' { $script:d2.Undecided | Should -Be 4 }
    It 'ItemsDecided is 0' { $script:d2.ItemsDecided | Should -Be 0 }
    It 'ItemsDecidedPct is 0' { $script:d2.ItemsDecidedPct | Should -Be 0 }
}

Describe 'SIC-04 removal mapping via synthetic REVOKE instance' {
    BeforeAll {
        $wrapped = @(
            (New-SICRevokeWrapper -IdentityId 'id-r1' -AccessId 'ent-r1' -Completed $true  -SourceType 'Active Directory - Direct' -SourceName 'Active Directory')
            (New-SICRevokeWrapper -IdentityId 'id-r2' -AccessId 'ent-r2' -Completed $true  -SourceType 'Workday'                   -SourceName 'Workday HR')
            (New-SICRevokeWrapper -IdentityId 'id-r3' -AccessId 'ent-r3' -Completed $false -SourceType 'Active Directory - Direct' -SourceName 'Active Directory')
        )
        $script:res3 = Get-SPSeriesInstanceCompletion -Items $wrapped -Roster @() -Status 'COMPLETED'
        $script:d3 = $script:res3.Data
    }
    It 'succeeds' { $script:res3.Success | Should -BeTrue }
    It 'counts all three as Revoked' { $script:d3.Revoked | Should -Be 3 }
    It 'Total is 3' { $script:d3.Total | Should -Be 3 }
    It 'completed REVOKE on connected AD -> Deprovisioned 1' { $script:d3.Removal.Deprovisioned | Should -Be 1 }
    It 'completed REVOKE on a non-AD source -> Queued 1' { $script:d3.Removal.Queued | Should -Be 1 }
    It 'not-completed REVOKE -> Pending 1' { $script:d3.Removal.Pending | Should -Be 1 }
}

Describe 'SIC-05 empty Items -> Success all-zeros, no throw' {
    BeforeAll {
        $script:res4 = Get-SPSeriesInstanceCompletion -Items @() -Roster @() -Status 'ACTIVE'
        $script:d4 = $script:res4.Data
    }
    It 'succeeds' { $script:res4.Success | Should -BeTrue }
    It 'Total 0' { $script:d4.Total | Should -Be 0 }
    It 'Approved/Revoked/Undecided all 0' {
        $script:d4.Approved  | Should -Be 0
        $script:d4.Revoked   | Should -Be 0
        $script:d4.Undecided | Should -Be 0
    }
    It 'ItemsDecidedPct 0' { $script:d4.ItemsDecidedPct | Should -Be 0 }
    It 'ReviewersSigned/Total 0' {
        $script:d4.ReviewersSigned | Should -Be 0
        $script:d4.ReviewersTotal  | Should -Be 0
    }
    It 'Removal 0/0/0' {
        $script:d4.Removal.Deprovisioned | Should -Be 0
        $script:d4.Removal.Queued        | Should -Be 0
        $script:d4.Removal.Pending       | Should -Be 0
    }
}
