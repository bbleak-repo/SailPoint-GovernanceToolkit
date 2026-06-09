<#
.SYNOPSIS
    Unit tests for SP.CampaignDelta -- the campaign snapshot foundation (Phase 0).
    CD-01: Build-SPCampaignSnapshotData shape + privileged/source tagging + KPI rollup
    CD-02: Save/Get round-trip
    CD-03: Get-SPCampaignPreviousSnapshot picks the most recent before a cutoff
    CD-04: Remove-SPCampaignOldSnapshots honors retention
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    $script:campaign = [PSCustomObject]@{ id = 'camp-cd-001'; name = 'Daily Attestation - Tue'; status = 'ACTIVE' }
    $script:certs = @(
        [PSCustomObject]@{ id = 'cert-1'; reviewer = [PSCustomObject]@{ id = 'mgr-1'; name = 'Mgr One' }; decisionsTotal = 4; decisionsMade = 2 }
    )
    $script:decisions = @{
        Approved = @(
            [PSCustomObject]@{ CertificationId = 'cert-1'; IdentityId = 'id-1'; IdentityName = 'Alice'; AccessName = 'Finance-Reader'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'APPROVE'; DecisionDate = '2026-06-09T09:00:00Z' }
            [PSCustomObject]@{ CertificationId = 'cert-1'; IdentityId = 'id-1'; IdentityName = 'Alice'; AccessName = 'Domain Admins'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'APPROVE'; DecisionDate = '2026-06-09T09:01:00Z' }
        )
        Revoked = @(
            [PSCustomObject]@{ CertificationId = 'cert-1'; IdentityId = 'id-2'; IdentityName = 'Bob'; AccessName = 'VPN-Standard'; AccessType = 'ENTITLEMENT'; SourceName = 'Okta'; Decision = 'REVOKE'; DecisionDate = '2026-06-09T09:02:00Z' }
        )
        Pending = @(
            [PSCustomObject]@{ CertificationId = 'cert-1'; IdentityId = 'id-3'; IdentityName = 'Carol'; AccessName = 'App-Reader'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'PENDING'; DecisionDate = '' }
        )
    }
}

Describe "CD-01: Build-SPCampaignSnapshotData" {
    BeforeAll {
        $script:snap = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
    }
    It "Captures campaign meta + counts" {
        $script:snap.Meta.CampaignId | Should -Be 'camp-cd-001'
        $script:snap.Meta.ItemCount  | Should -Be 4
        $script:snap.Meta.CertCount  | Should -Be 1
    }
    It "Records per-cert completion (made/total, not completed)" {
        $script:snap.Certs[0].DecisionsMade  | Should -Be 2
        $script:snap.Certs[0].DecisionsTotal | Should -Be 4
        $script:snap.Certs[0].Completed      | Should -Be $false
    }
    It "Tags 'Domain Admins' as privileged and the others as not" {
        $priv = @($script:snap.Items | Where-Object { $_.Privileged })
        $priv.Count | Should -Be 1
        $priv[0].AccessName | Should -Be 'Domain Admins'
    }
    It "Rolls up KPIs incl. privileged and completion %" {
        $script:snap.Kpi.Approved      | Should -Be 2
        $script:snap.Kpi.Revoked       | Should -Be 1
        $script:snap.Kpi.Pending       | Should -Be 1
        $script:snap.Kpi.PrivilegedTotal | Should -Be 1
        $script:snap.Kpi.CompletionPct | Should -Be 50
    }
    It "Breaks KPIs down by source" {
        $script:snap.Kpi.BySource['AD'].Total   | Should -Be 3
        $script:snap.Kpi.BySource['Okta'].Total | Should -Be 1
    }
    It "Builds a stable scope key (identity|access|source)" {
        ($script:snap.Items | Where-Object { $_.AccessName -eq 'Domain Admins' }).Key | Should -Be 'id-1|Domain Admins|AD'
    }
}

Describe "CD-02: Save / Get round-trip" {
    It "Saves a datetime-stamped file and reads it back" {
        $snap = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $dir = Join-Path $TestDrive 'snaps'
        $saved = Save-SPCampaignSnapshot -Snapshot $snap -SnapshotDir $dir
        $saved.Success | Should -Be $true
        Test-Path $saved.Data | Should -Be $true
        $loaded = Get-SPCampaignSnapshot -Path $saved.Data
        $loaded.Success | Should -Be $true
        [int]$loaded.Data.Meta.ItemCount | Should -Be 4
    }
}

Describe "CD-03: Get-SPCampaignPreviousSnapshot" {
    It "Returns the most recent snapshot strictly before the cutoff" {
        $dir = Join-Path $TestDrive 'prev'
        # two snapshots with explicit, distinct capture times
        $s1 = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $s1.Meta.CapturedAt = (Get-Date '2026-06-08T09:00:00').ToString('o')
        Save-SPCampaignSnapshot -Snapshot $s1 -SnapshotDir $dir | Out-Null
        $s2 = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $s2.Meta.CapturedAt = (Get-Date '2026-06-09T09:00:00').ToString('o')
        Save-SPCampaignSnapshot -Snapshot $s2 -SnapshotDir $dir | Out-Null

        $prev = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cd-001' -SnapshotDir $dir -Before (Get-Date '2026-06-09T09:00:00')
        $prev.Success | Should -Be $true
        $prev.Data | Should -Not -BeNullOrEmpty
        $prev.Data.CapturedAt.ToString('yyyy-MM-dd') | Should -Be '2026-06-08'
    }
    It "Returns null Data (not an error) when no prior snapshot exists" {
        $dir = Join-Path $TestDrive 'empty'
        $prev = Get-SPCampaignPreviousSnapshot -CampaignId 'nope' -SnapshotDir $dir
        $prev.Success | Should -Be $true
        $prev.Data | Should -BeNullOrEmpty
    }
}

Describe "CD-04: Remove-SPCampaignOldSnapshots" {
    It "Deletes snapshots older than the retention window" {
        $dir = Join-Path $TestDrive 'retain'
        $old = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $old.Meta.CapturedAt = (Get-Date).AddDays(-120).ToString('o')
        Save-SPCampaignSnapshot -Snapshot $old -SnapshotDir $dir | Out-Null
        $new = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        Save-SPCampaignSnapshot -Snapshot $new -SnapshotDir $dir | Out-Null

        $r = Remove-SPCampaignOldSnapshots -SnapshotDir $dir -RetentionDays 90
        $r.Success | Should -Be $true
        $r.Data.Removed | Should -Be 1
        (Get-SPCampaignSnapshotList -CampaignId 'camp-cd-001' -SnapshotDir $dir).Data.Count | Should -Be 1
    }
}
