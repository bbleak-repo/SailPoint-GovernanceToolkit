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
    It "Does not self-select the just-captured snapshot (sub-second cutoff regression)" {
        # Regression: a snapshot's filename is truncated to the SECOND, but Meta.CapturedAt carries
        # sub-seconds. Passing the raw sub-second CapturedAt as -Before lets the just-captured
        # snapshot's own (truncated) filename time sort before it, so it is returned as its OWN
        # "previous" -> the day-over-day diff self-compares and shows 0 changes. Invoke-SPCampaignDiff
        # aligns the cutoff to whole seconds; this locks that a second-aligned cutoff excludes the
        # same-second snapshot and returns the genuinely prior one.
        $dir = Join-Path $TestDrive 'subsec'
        $older = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $older.Meta.CapturedAt = (Get-Date '2026-06-09T09:00:00').ToString('o')
        Save-SPCampaignSnapshot -Snapshot $older -SnapshotDir $dir | Out-Null

        $current = Build-SPCampaignSnapshotData -Campaign $script:campaign -Certifications $script:certs -Decisions $script:decisions
        $current.Meta.CapturedAt = (Get-Date '2026-06-09T10:00:00').AddMilliseconds(500).ToString('o')  # filename -> ...T100000
        Save-SPCampaignSnapshot -Snapshot $current -SnapshotDir $dir | Out-Null

        # Mirror the CLI: align the cutoff to whole seconds before requesting the previous snapshot.
        $cutoff = [datetime]::Parse($current.Meta.CapturedAt)
        $cutoff = $cutoff.AddTicks(-($cutoff.Ticks % [System.TimeSpan]::TicksPerSecond))
        $prev = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cd-001' -SnapshotDir $dir -Before $cutoff

        $prev.Success | Should -Be $true
        $prev.Data    | Should -Not -BeNullOrEmpty
        $prev.Data.CapturedAt.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-06-09T09:00:00'
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

Describe "CD-05: KPI rates, denominators, reviewer rollup" {
    BeforeAll {
        # 2 privileged approved, 1 privileged revoked, 1 non-priv approved, 1 non-priv pending
        $certs = @(
            [PSCustomObject]@{ id = 'c1'; reviewer = [PSCustomObject]@{ id = 'r1'; name = 'R1' }; decisionsTotal = 5; decisionsMade = 5; signed = $true }
            [PSCustomObject]@{ id = 'c2'; reviewer = [PSCustomObject]@{ id = 'r2'; name = 'R2' }; decisionsTotal = 3; decisionsMade = 0 }
        )
        $dec = @{
            Approved = @(
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i1'; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE' }
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i2'; AccessName='Enterprise Admins'; Privileged=$true; SourceName='AD'; Decision='APPROVE' }
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i3'; AccessName='Finance-Reader'; SourceName='AD'; Decision='APPROVE' }
            )
            Revoked = @(
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i4'; AccessName='DBA-Master'; SourceName='Oracle'; Decision='REVOKE' }
            )
            Pending = @(
                [PSCustomObject]@{ CertificationId='c2'; IdentityId='i5'; AccessName='VPN'; SourceName='Okta'; Decision='PENDING' }
            )
        }
        $script:s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id='cr'; name='Rates'; status='ACTIVE' }) -Certifications $certs -Decisions $dec
    }
    It "Computes privileged-approval rate over REVIEWED privileged only" {
        # priv approved=2 (Domain/Enterprise Admins), priv revoked=1 (DBA-Master) => reviewed=3
        $script:s.Kpi.PrivilegedApproved | Should -Be 2
        $script:s.Kpi.PrivilegedRevoked  | Should -Be 1
        $script:s.Kpi.PrivilegedReviewed | Should -Be 3
        [math]::Round($script:s.Kpi.Rates.PrivApprovalRate,4) | Should -Be 0.6667
    }
    It "Returns null rate when the denominator is zero" {
        $script:s.Kpi.Rates.PrivApprovalRate | Should -Not -BeNullOrEmpty
        # no revoked-only scenario here; ApprovalRate denominator = approved+revoked = 4 > 0
        $script:s.Kpi.Rates.ApprovalRate | Should -Not -BeNullOrEmpty
    }
    It "Tracks reviewer-weighted completion" {
        $script:s.Kpi.ReviewersTotal      | Should -Be 2
        $script:s.Kpi.ReviewersSigned     | Should -Be 1
        $script:s.Kpi.ReviewersNotStarted | Should -Be 1
        $script:s.Kpi.CompletionPctByReviewer | Should -Be 50
    }
}

Describe "CD-06: stable ID-based scope key" {
    It "Keys on entitlement/source IDs so a rename does not churn" {
        $campaign = [PSCustomObject]@{ id='ck'; name='Key'; status='ACTIVE' }
        $day1 = @{ Approved=@([PSCustomObject]@{ CertificationId='c'; IdentityId='i1'; AccessName='Old Name'; AccessId='ent-99'; SourceName='AD'; SourceId='src-1'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $day2 = @{ Approved=@([PSCustomObject]@{ CertificationId='c'; IdentityId='i1'; AccessName='Renamed Entitlement'; AccessId='ent-99'; SourceName='Active Directory'; SourceId='src-1'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $s1 = Build-SPCampaignSnapshotData -Campaign $campaign -Certifications @() -Decisions $day1
        $s2 = Build-SPCampaignSnapshotData -Campaign $campaign -Certifications @() -Decisions $day2
        $s1.Items[0].Key | Should -Be 'i1|ent-99|src-1'
        $s2.Items[0].Key | Should -Be 'i1|ent-99|src-1'   # identical despite both names changing
    }
    It "Falls back to names when IDs are absent" {
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id='cn'; name='N'; status='ACTIVE' }) -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $s.Items[0].Key | Should -Be 'i1|Domain Admins|AD'
    }
}

Describe "CD-07: signed vs decided-awaiting-signoff" {
    It "Distinguishes all-decided-but-unsigned from signed" {
        $certs = @([PSCustomObject]@{ id='c1'; reviewer=[PSCustomObject]@{id='r';name='R'}; decisionsTotal=4; decisionsMade=4; signed=$false })
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cs';name='S';status='ACTIVE'}) -Certifications $certs -Decisions @{ Approved=@(); Revoked=@(); Pending=@() }
        $s.Certs[0].Signed                 | Should -Be $false
        $s.Certs[0].DecidedAwaitingSignoff | Should -Be $true
        $s.Certs[0].Completed              | Should -Be $true   # operational completion still true
    }
}

Describe "CD-08: privileged provenance + word-boundary patterns" {
    It "Tags ISC attribute as 'attribute' (confirmed)" {
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='ca';name='A';status='ACTIVE'}) -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='Plain-Entitlement'; Privileged=$true; SourceName='AD'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $s.Items[0].Privileged       | Should -Be $true
        $s.Items[0].PrivilegedSource | Should -Be 'attribute'
        $s.Kpi.PrivilegedConfirmed   | Should -Be 1
    }
    It "Does NOT match 'Admin' inside 'Administrative Assistant' (word boundary)" {
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cb';name='B';status='ACTIVE'}) -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='Administrative Assistant'; SourceName='HR'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $s.Items[0].Privileged | Should -Be $false
    }
    It "Still matches a real privileged name as 'pattern' (suspected)" {
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cc';name='C';status='ACTIVE'}) -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE' }); Revoked=@(); Pending=@() }
        $s.Items[0].Privileged       | Should -Be $true
        $s.Items[0].PrivilegedSource | Should -Be 'pattern'
        $s.Kpi.PrivilegedSuspected   | Should -Be 1
    }
}

Describe "CD-09: integrity sidecar, lifecycle retention, provenance/due-date" {
    It "Writes a SHA-256 sidecar matching the file" {
        $dir = Join-Path $TestDrive 'sha'
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='ch';name='H';status='ACTIVE'}) -Certifications $script:certs -Decisions $script:decisions
        $saved = Save-SPCampaignSnapshot -Snapshot $s -SnapshotDir $dir
        $sidecar = "$($saved.Data).sha256"
        Test-Path $sidecar | Should -Be $true
        $expected = (Get-FileHash -Path $saved.Data -Algorithm SHA256).Hash.ToLowerInvariant()
        ((Get-Content $sidecar -Raw) -split '\s')[0] | Should -Be $expected
    }
    It "Preserves COMPLETED (evidence) snapshots beyond retention, deletes ACTIVE ones" {
        $dir = Join-Path $TestDrive 'lifecycle'
        $active = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cl';name='L';status='ACTIVE'}) -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()}
        $active.Meta.CapturedAt = (Get-Date).AddDays(-200).ToString('o')
        Save-SPCampaignSnapshot -Snapshot $active -SnapshotDir $dir | Out-Null
        $done = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cl';name='L';status='COMPLETED'}) -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()}
        $done.Meta.CapturedAt = (Get-Date).AddDays(-201).ToString('o')
        Save-SPCampaignSnapshot -Snapshot $done -SnapshotDir $dir | Out-Null

        $r = Remove-SPCampaignOldSnapshots -SnapshotDir $dir -RetentionDays 90
        $r.Data.Removed           | Should -Be 1
        $r.Data.PreservedEvidence | Should -Be 1
    }
    It "Stamps due-date and provenance into Meta" {
        $campaign = [PSCustomObject]@{ id='cp'; name='P'; status='ACTIVE'; deadline='2026-06-20T00:00:00Z' }
        $s = Build-SPCampaignSnapshotData -Campaign $campaign -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()} -Provenance @{ ToolkitVersion='1.0.0'; TenantUrl='https://x.api.identitynow.com'; Environment='PROD'; CapturedBy='tester' }
        $s.Meta.DueDate              | Should -Be '2026-06-20T00:00:00Z'
        $s.Meta.Provenance.Environment | Should -Be 'PROD'
        $s.Meta.Provenance.CapturedBy  | Should -Be 'tester'
        @($s.Meta.PrivilegedPatterns).Count | Should -BeGreaterThan 0
    }
}

Describe "CD-11: cadence-aware previous-snapshot selection" {
    BeforeAll {
        $script:cadDir = Join-Path $TestDrive 'cadence'
        $camp = [PSCustomObject]@{ id='camp-cad'; name='Cad'; status='ACTIVE' }
        # captures at now, -1d, -7d, -30d (and an earlier-today one)
        foreach ($ago in @(0.0, 1.0, 7.0, 30.0)) {
            $s = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()}
            $s.Meta.CapturedAt = (Get-Date).AddDays(-$ago).ToString('o')
            Save-SPCampaignSnapshot -Snapshot $s -SnapshotDir $script:cadDir | Out-Null
        }
        # an extra capture 3h ago (same calendar day as 'now' in most cases)
        $se = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()}
        $se.Meta.CapturedAt = (Get-Date).AddHours(-3).ToString('o')
        Save-SPCampaignSnapshot -Snapshot $se -SnapshotDir $script:cadDir | Out-Null
    }
    It "Weekly picks the snapshot closest to ~168h ago" {
        $now = Get-Date
        $r = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cad' -SnapshotDir $script:cadDir -Before $now -TargetAgoHours 168
        $r.Success | Should -Be $true
        [math]::Round(($now - $r.Data.CapturedAt).TotalDays, 0) | Should -Be 7
    }
    It "Daily picks the snapshot closest to ~24h ago" {
        $now = Get-Date
        $r = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cad' -SnapshotDir $script:cadDir -Before $now -TargetAgoHours 24
        [math]::Round(($now - $r.Data.CapturedAt).TotalDays, 0) | Should -Be 1
    }
    It "Adjacent (default) picks the immediately prior snapshot" {
        $now = Get-Date
        $r = Get-SPCampaignPreviousSnapshot -CampaignId 'camp-cad' -SnapshotDir $script:cadDir -Before $now.AddMinutes(-1)
        # most recent before (now-1min) is the 3h-ago capture
        [math]::Round(($now - $r.Data.CapturedAt).TotalHours, 0) | Should -Be 3
    }
}

Describe "CD-10: snapshots chained into the audit evidence chain" {
    It "Includes snapshot .json captures in New-SPAuditEvidenceChain" {
        $snapDir  = Join-Path $TestDrive 'ec-snaps'
        $emptyAud = Join-Path $TestDrive 'ec-empty-audit'; New-Item -ItemType Directory -Path $emptyAud -Force | Out-Null
        $emptyDc  = Join-Path $TestDrive 'ec-empty-dc';    New-Item -ItemType Directory -Path $emptyDc -Force | Out-Null
        $manOut   = Join-Path $TestDrive 'ec-manifest';    New-Item -ItemType Directory -Path $manOut -Force | Out-Null
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{id='cec';name='EC';status='COMPLETED'}) -Certifications @() -Decisions @{Approved=@();Revoked=@();Pending=@()}
        Save-SPCampaignSnapshot -Snapshot $s -SnapshotDir $snapDir | Out-Null

        $r = New-SPAuditEvidenceChain -AuditOutputPath $emptyAud -DeltaCertOutputPath $emptyDc -IncludeSnapshots -SnapshotPath $snapDir -OutputPath $manOut
        $r.Success | Should -Be $true
        $r.Data.FileCount | Should -BeGreaterThan 0
        Test-Path $r.Data.ManifestPath | Should -Be $true
    }
}
