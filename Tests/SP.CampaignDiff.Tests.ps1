<#
.SYNOPSIS
    Unit tests for SP.CampaignDiff -- the snapshot comparison + diff reporting layer.
    CDF-01: Compare completion view (newly completed / stalled / not started / progress)
    CDF-02: Compare scope view (added / removed / changed, privileged tagging)
    CDF-03: Compliance summary (newly-added privileged, stalled, overdue, priv-approved)
    CDF-04: First-run (no previous) is graceful -- everything treated as baseline-added
    CDF-05: HTML + CSV exporters round-trip to disk
    CDF-06: Compare works on JSON-round-tripped snapshots (PSCustomObject shape)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    $script:campaign = [PSCustomObject]@{ id = 'camp-cdf-001'; name = 'Daily Attestation - Wed'; status = 'ACTIVE' }

    # ---- PREVIOUS capture (yesterday) ----
    $prevCerts = @(
        [PSCustomObject]@{ id = 'cert-A'; reviewer = [PSCustomObject]@{ id = 'mgr-A'; name = 'Mgr A' }; decisionsTotal = 4; decisionsMade = 1 }
        [PSCustomObject]@{ id = 'cert-B'; reviewer = [PSCustomObject]@{ id = 'mgr-B'; name = 'Mgr B' }; decisionsTotal = 2; decisionsMade = 0 }
    )
    $prevDecisions = @{
        Approved = @(
            [PSCustomObject]@{ CertificationId = 'cert-A'; IdentityId = 'id-1'; IdentityName = 'Alice'; AccessName = 'Finance-Reader'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'APPROVE'; DecisionDate = '2026-06-08T09:00:00Z' }
        )
        Revoked = @()
        Pending = @(
            [PSCustomObject]@{ CertificationId = 'cert-A'; IdentityId = 'id-2'; IdentityName = 'Bob'; AccessName = 'VPN-Standard'; AccessType = 'ENTITLEMENT'; SourceName = 'Okta'; Decision = 'PENDING'; DecisionDate = '' }
            [PSCustomObject]@{ CertificationId = 'cert-B'; IdentityId = 'id-3'; IdentityName = 'Carol'; AccessName = 'App-Reader'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'PENDING'; DecisionDate = '' }
            [PSCustomObject]@{ CertificationId = 'cert-B'; IdentityId = 'id-4'; IdentityName = 'Dave'; AccessName = 'Legacy-App'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'PENDING'; DecisionDate = '' }
        )
    }
    $script:prevSnap = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $prevCerts -Decisions $prevDecisions
    $script:prevSnap.Meta.CapturedAt = (Get-Date '2026-06-08T09:00:00').ToString('o')

    # ---- CURRENT capture (today) ----
    #  - cert-A made progress (1 -> 3); cert-B still 0 (stalled/not-started)
    #  - Bob's VPN still pending (overdue undecided); Carol's App-Reader -> removed from scope
    #  - NEW privileged grant 'Domain Admins' added for Eve (newly-added privileged)
    #  - Bob's VPN-Standard unchanged pending; Finance-Reader stays approved
    $curCerts = @(
        [PSCustomObject]@{ id = 'cert-A'; reviewer = [PSCustomObject]@{ id = 'mgr-A'; name = 'Mgr A' }; decisionsTotal = 4; decisionsMade = 3 }
        [PSCustomObject]@{ id = 'cert-B'; reviewer = [PSCustomObject]@{ id = 'mgr-B'; name = 'Mgr B' }; decisionsTotal = 2; decisionsMade = 0 }
    )
    $curDecisions = @{
        Approved = @(
            [PSCustomObject]@{ CertificationId = 'cert-A'; IdentityId = 'id-1'; IdentityName = 'Alice'; AccessName = 'Finance-Reader'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'APPROVE'; DecisionDate = '2026-06-08T09:00:00Z' }
            [PSCustomObject]@{ CertificationId = 'cert-A'; IdentityId = 'id-5'; IdentityName = 'Eve'; AccessName = 'Domain Admins'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'APPROVE'; DecisionDate = '2026-06-09T09:05:00Z' }
        )
        Revoked = @()
        Pending = @(
            [PSCustomObject]@{ CertificationId = 'cert-A'; IdentityId = 'id-2'; IdentityName = 'Bob'; AccessName = 'VPN-Standard'; AccessType = 'ENTITLEMENT'; SourceName = 'Okta'; Decision = 'PENDING'; DecisionDate = '' }
            [PSCustomObject]@{ CertificationId = 'cert-B'; IdentityId = 'id-4'; IdentityName = 'Dave'; AccessName = 'Legacy-App'; AccessType = 'ENTITLEMENT'; SourceName = 'AD'; Decision = 'PENDING'; DecisionDate = '' }
        )
    }
    $script:curSnap = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $curCerts -Decisions $curDecisions
    $script:curSnap.Meta.CapturedAt = (Get-Date '2026-06-09T09:00:00').ToString('o')

    $script:diff = (Compare-SPCampaignSnapshots -Current $script:curSnap -Previous $script:prevSnap).Data
}

Describe "CDF-01: Completion view" {
    It "Counts progress, stalled, and not-started reviewers" {
        $certA = @($script:diff.Completion.Reviewers | Where-Object { $_.CertId -eq 'cert-A' })[0]
        $certA.MadeDelta | Should -Be 2          # 1 -> 3
        $certA.CompletionPct | Should -Be 75
        $certB = @($script:diff.Completion.Reviewers | Where-Object { $_.CertId -eq 'cert-B' })[0]
        $certB.NotStarted | Should -Be $true     # 0 made
        $script:diff.Completion.NotStartedCount | Should -Be 1
    }
    It "Tracks completion % movement" {
        $script:diff.Completion.PrevCompletionPct | Should -BeLessThan $script:diff.Completion.CurrCompletionPct
    }
}

Describe "CDF-02: Scope view" {
    It "Detects added grants (Eve/Domain Admins is new)" {
        $addedKeys = @($script:diff.Scope.Added | ForEach-Object { $_.Key })
        $addedKeys | Should -Contain 'id-5|Domain Admins|AD'
        $script:diff.Scope.AddedPrivilegedCount | Should -Be 1
    }
    It "Detects removed grants (Carol/App-Reader is gone)" {
        $removedKeys = @($script:diff.Scope.Removed | ForEach-Object { $_.Key })
        $removedKeys | Should -Contain 'id-3|App-Reader|AD'
    }
}

Describe "CDF-03: Compliance summary" {
    It "Flags newly-added privileged access" {
        @($script:diff.Compliance.NewlyAddedPrivileged).Count | Should -Be 1
        $script:diff.Compliance.NewlyAddedPrivileged[0].AccessName | Should -Be 'Domain Admins'
    }
    It "Flags overdue undecided (pending in both captures)" {
        # Bob/VPN-Standard and Dave/Legacy-App were pending yesterday and still pending today
        $keys = @($script:diff.Compliance.OverdueUndecided | ForEach-Object { $_.Key })
        $keys | Should -Contain 'id-2|VPN-Standard|Okta'
        $keys | Should -Contain 'id-4|Legacy-App|AD'
    }
    It "Flags privileged approved as advisory (Domain Admins newly approved)" {
        @($script:diff.Compliance.PrivilegedApproved).Count | Should -Be 1
        $script:diff.Compliance.PrivilegedApproved[0].AccessName | Should -Be 'Domain Admins'
    }
    It "Flags stalled/not-started reviewers" {
        @($script:diff.Compliance.StalledReviewers).Count | Should -BeGreaterOrEqual 1
    }
}

Describe "CDF-04: First-run (no previous)" {
    It "Treats everything as baseline-added without error" {
        $r = Compare-SPCampaignSnapshots -Current $script:curSnap
        $r.Success | Should -Be $true
        $r.Data.Meta.HasPrevious | Should -Be $false
        $r.Data.Scope.AddedCount | Should -Be $script:curSnap.Meta.ItemCount
        $r.Data.Scope.RemovedCount | Should -Be 0
    }
}

Describe "CDF-05: Exporters" {
    It "Writes both HTML diff reports" {
        $dir = Join-Path $TestDrive 'html'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $c = Export-SPCampaignCompletionDiffHtml -Diff $script:diff -OutputPath $dir
        $s = Export-SPCampaignScopeDiffHtml -Diff $script:diff -OutputPath $dir
        $c.Success | Should -Be $true; Test-Path $c.Data | Should -Be $true
        $s.Success | Should -Be $true; Test-Path $s.Data | Should -Be $true
        (Get-Content $s.Data -Raw) | Should -Match 'Domain Admins'
    }
    It "Writes completion + scope CSVs" {
        $dir = Join-Path $TestDrive 'csv'
        $r = Export-SPCampaignDiffCsv -Diff $script:diff -OutputDir $dir
        $r.Success | Should -Be $true
        Test-Path $r.Data.CompletionCsv | Should -Be $true
        Test-Path $r.Data.ScopeCsv | Should -Be $true
        $rows = Import-Csv $r.Data.ScopeCsv
        @($rows | Where-Object { $_.Change -eq 'Added' -and $_.AccessName -eq 'Domain Admins' }).Count | Should -Be 1
    }
}

Describe "CDF-06: JSON round-trip shape" {
    It "Compares snapshots that have been saved + reloaded from disk" {
        $dir = Join-Path $TestDrive 'snaps'
        Save-SPCampaignSnapshot -Snapshot $script:prevSnap -SnapshotDir $dir | Out-Null
        $savedCur = Save-SPCampaignSnapshot -Snapshot $script:curSnap -SnapshotDir $dir
        $loadedCur = (Get-SPCampaignSnapshot -Path $savedCur.Data).Data
        $prevRef = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cdf-001' -SnapshotDir $dir -Before (Get-Date '2026-06-09T09:00:00')
        $loadedPrev = (Get-SPCampaignSnapshot -Path $prevRef.Data.Path).Data
        $r = Compare-SPCampaignSnapshots -Current $loadedCur -Previous $loadedPrev
        $r.Success | Should -Be $true
        @($r.Data.Compliance.NewlyAddedPrivileged).Count | Should -Be 1
    }
}
