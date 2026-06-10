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
    It "Flags persistently-pending (pending in both captures)" {
        # Bob/VPN-Standard and Dave/Legacy-App were pending yesterday and still pending today
        $keys = @($script:diff.Compliance.PersistentlyPending | ForEach-Object { $_.Key })
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

Describe "CDF-07: diff enrichment (2b)" {
    It "Flags a reassigned cert and rolls up per reviewer" {
        $camp = [PSCustomObject]@{ id='cr1'; name='R'; status='ACTIVE' }
        $prev = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @([PSCustomObject]@{ id='cx'; reviewer=[PSCustomObject]@{id='r-old';name='Old'}; decisionsTotal=4; decisionsMade=1 }) -Decisions @{Approved=@();Revoked=@();Pending=@()}
        $cur  = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @([PSCustomObject]@{ id='cx'; reviewer=[PSCustomObject]@{id='r-new';name='New'}; decisionsTotal=4; decisionsMade=2 }) -Decisions @{Approved=@();Revoked=@();Pending=@()}
        $d = (Compare-SPCampaignSnapshots -Current $cur -Previous $prev).Data
        $d.Completion.ReassignedCount | Should -Be 1
        @($d.Completion.Reviewers | Where-Object { $_.Reassigned }).Count | Should -Be 1
        @($d.Completion.ByReviewer).Count | Should -Be 1
        $d.Completion.ByReviewer[0].Certs | Should -Be 1
    }
    It "Reports true overdue against the campaign due date" {
        $campPast = [PSCustomObject]@{ id='cov'; name='O'; status='ACTIVE'; deadline='2020-01-01T00:00:00Z' }
        $prev = Build-SPCampaignSnapshotData -Campaign $campPast -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@([PSCustomObject]@{IdentityId='i1';AccessName='X';SourceName='AD';Decision='PENDING'})}
        $cur  = Build-SPCampaignSnapshotData -Campaign $campPast -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@([PSCustomObject]@{IdentityId='i1';AccessName='X';SourceName='AD';Decision='PENDING'})}
        $d = (Compare-SPCampaignSnapshots -Current $cur -Previous $prev).Data
        @($d.Compliance.Overdue).Count | Should -BeGreaterThan 0
    }
    It "Classifies a newly-onboarded source vs a new grant" {
        $camp = [PSCustomObject]@{ id='cso'; name='S'; status='ACTIVE' }
        $prev = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{Approved=@([PSCustomObject]@{IdentityId='i1';AccessName='E1';AccessId='e1';SourceName='AD';SourceId='src-ad';Decision='APPROVE'});Revoked=@();Pending=@()}
        $cur  = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{Approved=@(
            [PSCustomObject]@{IdentityId='i1';AccessName='E1';AccessId='e1';SourceName='AD';SourceId='src-ad';Decision='APPROVE'}
            [PSCustomObject]@{IdentityId='i2';AccessName='E2';AccessId='e2';SourceName='Disconnected CSV';SourceId='src-csv';Decision='APPROVE'}
        );Revoked=@();Pending=@()}
        $d = (Compare-SPCampaignSnapshots -Current $cur -Previous $prev).Data
        $d.Scope.NewSourceCount | Should -Be 1
        @($d.Scope.NewSources) | Should -Contain 'Disconnected CSV'
        ($d.Scope.Added | Where-Object { $_.SourceId -eq 'src-csv' }).ChangeClass | Should -Be 'NewSource'
    }
    It "Suppresses delta advisories on the baseline run" {
        $camp = [PSCustomObject]@{ id='cbl'; name='B'; status='ACTIVE' }
        $cur = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{Approved=@([PSCustomObject]@{IdentityId='i1';AccessName='Domain Admins';SourceName='AD';Decision='APPROVE'});Revoked=@();Pending=@()}
        $d = (Compare-SPCampaignSnapshots -Current $cur).Data
        @($d.Compliance.NewlyAddedPrivileged).Count | Should -Be 0
        @($d.Compliance.PrivilegedApproved).Count   | Should -Be 0
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

Describe "CDF-08: per-director diff split + HTML export" {
    BeforeAll {
        # Org tree (.Data shape from Build-SPOrgTree): reviewers rev-1/rev-2 report to dir-A,
        # rev-3 to dir-B, rev-4 has no manager (-> Unassigned bucket).
        $script:pdOrg = @{
            Nodes = @{
                'rev-1' = @{ Identity = @{ Id='rev-1'; Name='Alice'; ManagerId='dir-A'; ManagerName='Dir Alpha'; Found=$true }; ManagerId='dir-A'; Level=0; Children=@() }
                'rev-2' = @{ Identity = @{ Id='rev-2'; Name='Bob';   ManagerId='dir-A'; ManagerName='Dir Alpha'; Found=$true }; ManagerId='dir-A'; Level=0; Children=@() }
                'rev-3' = @{ Identity = @{ Id='rev-3'; Name='Carol'; ManagerId='dir-B'; ManagerName='Dir Beta';  Found=$true }; ManagerId='dir-B'; Level=0; Children=@() }
                'rev-4' = @{ Identity = @{ Id='rev-4'; Name='Dave';  ManagerId='';      ManagerName='';          Found=$true }; ManagerId='';      Level=0; Children=@() }
                'dir-A' = @{ Identity = @{ Id='dir-A'; Name='Dir Alpha'; ManagerId='vp-1'; ManagerName='VP One'; Found=$true }; ManagerId='vp-1'; Level=1; Children=@('rev-1','rev-2') }
                'dir-B' = @{ Identity = @{ Id='dir-B'; Name='Dir Beta';  ManagerId='vp-1'; ManagerName='VP One'; Found=$true }; ManagerId='vp-1'; Level=1; Children=@('rev-3') }
            }
            Directors = @('dir-A','dir-B'); Managers = @(); TopLeaders = @('vp-1')
        }
        $script:pdDiff = @{
            Meta = @{ CampaignId='c1'; CampaignName='Test Daily'; Status='ACTIVE'; HasPrevious=$true; Cadence='Adjacent'; CurrentCapturedAt='2026-06-10T10:00:00'; PreviousCapturedAt='2026-06-09T10:00:00' }
            Completion = @{ Reviewers = @(
                @{ ReviewerId='rev-1'; ReviewerName='Alice'; CurrMade=4; MadeDelta=3; Total=4; CompletionPct=100; Completed=$true;  Signed=$true;  NewlyCompleted=$true;  Stalled=$false; NotStarted=$false }
                @{ ReviewerId='rev-2'; ReviewerName='Bob';   CurrMade=0; MadeDelta=0; Total=4; CompletionPct=0;   Completed=$false; Signed=$false; NewlyCompleted=$false; Stalled=$true;  NotStarted=$false }
                @{ ReviewerId='rev-3'; ReviewerName='Carol'; CurrMade=0; MadeDelta=0; Total=2; CompletionPct=0;   Completed=$false; Signed=$false; NewlyCompleted=$false; Stalled=$false; NotStarted=$true }
                @{ ReviewerId='rev-4'; ReviewerName='Dave';  CurrMade=1; MadeDelta=1; Total=3; CompletionPct=33;  Completed=$false; Signed=$false; NewlyCompleted=$false; Stalled=$false; NotStarted=$false }
            ) }
            Scope = @{
                Added = @(
                    @{ ReviewerId='rev-1'; IdentityName='u1'; AccessName='Finance-Reader'; SourceName='AD';   Privileged=$false; Decision='APPROVE' }
                    @{ ReviewerId='rev-3'; IdentityName='u3'; AccessName='Domain Admins';  SourceName='AD';   Privileged=$true;  Decision='APPROVE' }
                    @{ ReviewerId='rev-4'; IdentityName='u4'; AccessName='VPN';            SourceName='Okta'; Privileged=$false; Decision='PENDING' }
                )
                Removed = @( @{ ReviewerId='rev-2'; IdentityName='u2'; AccessName='Legacy-App'; SourceName='AD'; Privileged=$false; Decision='REVOKE' } )
                Changed = @( @{ ReviewerId='rev-1'; IdentityName='u1'; AccessName='App-X'; SourceName='AD'; Privileged=$false; PrevDecision='PENDING'; CurrDecision='APPROVE' } )
            }
            Compliance = @{ NewlyAddedPrivileged = @( @{ ReviewerId='rev-3'; IdentityName='u3'; AccessName='Domain Admins'; SourceName='AD'; Privileged=$true; Decision='APPROVE' } ) }
        }
        $script:pdSplit = Split-SPCampaignDiffByDirector -Diff $script:pdDiff -OrgTree $script:pdOrg
        $script:pdAlpha = @($script:pdSplit.Directors | Where-Object { $_.DirectorName -eq 'Dir Alpha' })[0]
        $script:pdBeta  = @($script:pdSplit.Directors | Where-Object { $_.DirectorName -eq 'Dir Beta' })[0]
    }

    It "groups reviewers under their manager (director) and lists the Unassigned bucket last" {
        @($script:pdSplit.Directors).Count | Should -Be 3
        $script:pdSplit.Directors[0].DirectorName | Should -Be 'Dir Alpha'
        $script:pdSplit.Directors[-1].DirectorId  | Should -Be '__unassigned__'
    }
    It "slices completion + scope to each director" {
        $script:pdAlpha.Counts.Reviewers     | Should -Be 2
        $script:pdAlpha.Counts.NewlyCompleted | Should -Be 1
        $script:pdAlpha.Counts.Stalled        | Should -Be 1
        $script:pdAlpha.Counts.Added          | Should -Be 1
        $script:pdAlpha.Counts.Removed        | Should -Be 1
        $script:pdAlpha.Counts.Changed        | Should -Be 1
    }
    It "attributes privileged additions to the right director" {
        $script:pdBeta.Counts.Reviewers       | Should -Be 1
        $script:pdBeta.Counts.Added           | Should -Be 1
        $script:pdBeta.Counts.AddedPrivileged | Should -Be 1
        $script:pdBeta.Counts.NotStarted      | Should -Be 1
    }
    It "writes one HTML file per director + an index (no BOM)" {
        $dir = Join-Path $TestDrive 'pd'
        $res = Export-SPCampaignDiffByDirectorHtml -Diff $script:pdDiff -OrgTree $script:pdOrg -OutputPath $dir
        $res.Success | Should -Be $true
        $res.Data.DirectorCount | Should -Be 3
        @($res.Data.Files).Count | Should -Be 3
        Test-Path $res.Data.Index | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes(@($res.Data.Files)[0])
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
        # The Dir Beta file should name the director and the privileged grant.
        $betaFile = @($res.Data.Files | Where-Object { $_ -like '*Dir_Beta*' })[0]
        $betaFile | Should -Not -BeNullOrEmpty
        (Get-Content $betaFile -Raw) | Should -Match 'Domain Admins'
    }
}
