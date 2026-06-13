<#
.SYNOPSIS
    Unit tests for SP.CampaignTrend -- the per-campaign KPI rate time-series.
    CT-01: Save appends a rate row; Get reads it back
    CT-02: Daily/Weekly/Monthly rollup + direction-neutral arrow
    CT-03: Null rates (zero denominator) are skipped, not charted as 0
    CT-04: Data completeness (captures per period) is reported
    CT-05: HTML export round-trips to disk
    CT-06: Velocity derived from the diff (decisions/hour)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    function New-CTSnapshot {
        param([string]$Id = 'camp-ct', [int]$PrivApproved = 2, [int]$PrivRevoked = 1, [int]$Approved = 5, [int]$Revoked = 2, [string]$CapturedAt)
        $approvedItems = @()
        for ($i = 0; $i -lt $PrivApproved; $i++) { $approvedItems += [PSCustomObject]@{ IdentityId="i$i"; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE' } }
        for ($i = 0; $i -lt ($Approved - $PrivApproved); $i++) { $approvedItems += [PSCustomObject]@{ IdentityId="n$i"; AccessName='Finance-Reader'; SourceName='AD'; Decision='APPROVE' } }
        $revokedItems = @()
        for ($i = 0; $i -lt $PrivRevoked; $i++) { $revokedItems += [PSCustomObject]@{ IdentityId="r$i"; AccessName='DBA-Master'; SourceName='Oracle'; Decision='REVOKE' } }
        for ($i = 0; $i -lt ($Revoked - $PrivRevoked); $i++) { $revokedItems += [PSCustomObject]@{ IdentityId="x$i"; AccessName='VPN'; SourceName='Okta'; Decision='REVOKE' } }
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id=$Id; name='CT'; status='ACTIVE' }) -Certifications @() -Decisions @{ Approved=$approvedItems; Revoked=$revokedItems; Pending=@() } -Provenance @{ Environment='TEST' }
        if ($CapturedAt) { $s.Meta.CapturedAt = $CapturedAt }
        return $s
    }
}

Describe "CT-01: Save + Get round-trip" {
    It "Appends a rate row and reads it back" {
        $dir = Join-Path $TestDrive 't1'
        $s = New-CTSnapshot -CapturedAt (Get-Date '2026-06-09T08:00:00').ToString('o')
        $r = Save-SPCampaignTrendPoint -Snapshot $s -TrendDir $dir
        $r.Success | Should -Be $true
        Test-Path $r.Data.FilePath | Should -Be $true
        $t = Get-SPCampaignTrend -CampaignId 'camp-ct' -TrendDir $dir -Granularity Daily
        $t.Success | Should -Be $true
        $t.Data.PointCount | Should -Be 1
        $t.Data.Trends.ContainsKey('rates.privApprovalRate') | Should -Be $true
    }
}

Describe "CT-02: rollup + direction" {
    It "Rolls up multiple captures and flags rising privileged approval as 'Up'" {
        $dir = Join-Path $TestDrive 't2'
        # week 1: priv approval rate low (1 approved / (1+2 revoked) = 0.333)
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -PrivApproved 1 -PrivRevoked 2 -CapturedAt (Get-Date '2026-05-01T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        # later: priv approval rate high (4 approved / (4+0) -> but need revoked>0; use 4 appr / (4+1)=0.8)
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -PrivApproved 4 -PrivRevoked 1 -Approved 6 -Revoked 2 -CapturedAt (Get-Date '2026-06-01T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        $t = (Get-SPCampaignTrend -CampaignId 'camp-ct' -TrendDir $dir -Granularity Monthly).Data
        $t.PointCount | Should -Be 2
        @($t.Trends['rates.privApprovalRate'].Periods).Count | Should -Be 2
        $t.Trends['rates.privApprovalRate'].Direction | Should -Be 'Up'
    }
}

Describe "CT-03: null rates skipped" {
    It "Skips a rate whose denominator was zero (no privileged reviewed)" {
        $dir = Join-Path $TestDrive 't3'
        # no privileged at all -> PrivApprovalRate null
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id='camp-z'; name='Z'; status='ACTIVE' }) -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='Finance-Reader'; SourceName='AD'; Decision='APPROVE' }); Revoked=@(); Pending=@() } -Provenance @{ Environment='TEST' }
        $s.Meta.CapturedAt = (Get-Date '2026-06-09T08:00:00').ToString('o')
        Save-SPCampaignTrendPoint -Snapshot $s -TrendDir $dir | Out-Null
        $t = (Get-SPCampaignTrend -CampaignId 'camp-z' -TrendDir $dir -Granularity Daily).Data
        # privApprovalRate had a null value -> the metric should have no period buckets / absent
        $hasPriv = $t.Trends.ContainsKey('rates.privApprovalRate')
        $hasPriv | Should -Be $false
        # but a non-null rate (approvalRate) is present
        $t.Trends.ContainsKey('rates.approvalRate') | Should -Be $true
    }
}

Describe "CT-04: data completeness" {
    It "Reports captures per period" {
        $dir = Join-Path $TestDrive 't4'
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -CapturedAt (Get-Date '2026-06-09T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -CapturedAt (Get-Date '2026-06-09T14:00:00').ToString('o')) -TrendDir $dir | Out-Null
        $t = (Get-SPCampaignTrend -CampaignId 'camp-ct' -TrendDir $dir -Granularity Daily).Data
        $day = @($t.Periods | Where-Object { $_.Period -eq '2026-06-09' })[0]
        $day.Captures | Should -Be 2
    }
}

Describe "CT-05: HTML export" {
    It "Writes a trend HTML file" {
        $dir = Join-Path $TestDrive 't5'
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -PrivApproved 1 -PrivRevoked 2 -CapturedAt (Get-Date '2026-05-01T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -PrivApproved 4 -PrivRevoked 1 -CapturedAt (Get-Date '2026-06-01T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        $t = (Get-SPCampaignTrend -CampaignId 'camp-ct' -TrendDir $dir -Granularity Monthly).Data
        $out = Join-Path $TestDrive 'html'
        $e = Export-SPCampaignTrendHtml -Trend $t -OutputPath $out
        $e.Success | Should -Be $true
        Test-Path $e.Data | Should -Be $true
        (Get-Content $e.Data -Raw) | Should -Match 'Privileged approval rate'
    }
}

Describe "CT-07: program (cross-campaign) trend" {
    It "Aggregates across campaigns and counts closures per period" {
        $dir = Join-Path $TestDrive 'prog'
        # campaign A: active rows in two months
        $a1 = New-CTSnapshot -Id 'camp-A' -PrivApproved 1 -PrivRevoked 2 -CapturedAt (Get-Date '2026-05-10T08:00:00').ToString('o')
        Save-SPCampaignTrendPoint -Snapshot $a1 -TrendDir $dir | Out-Null
        $a2 = New-CTSnapshot -Id 'camp-A' -PrivApproved 3 -PrivRevoked 1 -CapturedAt (Get-Date '2026-06-10T08:00:00').ToString('o')
        Save-SPCampaignTrendPoint -Snapshot $a2 -TrendDir $dir | Out-Null
        # campaign B: closes in June (status COMPLETED)
        $b = New-CTSnapshot -Id 'camp-B' -PrivApproved 4 -PrivRevoked 1 -CapturedAt (Get-Date '2026-06-15T08:00:00').ToString('o')
        $b.Meta.Status = 'COMPLETED'
        Save-SPCampaignTrendPoint -Snapshot $b -TrendDir $dir | Out-Null

        $p = (Get-SPProgramTrend -TrendDir $dir -Granularity Monthly).Data
        $p.CampaignCount | Should -Be 2
        $jun = @($p.Periods | Where-Object { $_.Period -eq '2026-06' })[0]
        $jun.Campaigns | Should -Be 2
        $jun.Closed | Should -Be 1
    }
    It "Exports the program trend HTML" {
        $dir = Join-Path $TestDrive 'prog2'
        Save-SPCampaignTrendPoint -Snapshot (New-CTSnapshot -Id 'camp-X' -CapturedAt (Get-Date '2026-06-01T08:00:00').ToString('o')) -TrendDir $dir | Out-Null
        $p = (Get-SPProgramTrend -TrendDir $dir -Granularity Monthly).Data
        $e = Export-SPProgramTrendHtml -Trend $p -OutputPath (Join-Path $TestDrive 'phtml')
        $e.Success | Should -Be $true
        (Get-Content $e.Data -Raw) | Should -Match 'Program Governance Trend'
    }
}

Describe "CT-08: per-reviewer decision summaries" {
    It "Includes reviewer summaries in the trend JSONL row" {
        $dir = Join-Path $TestDrive 't8'
        $camp = [PSCustomObject]@{ id='camp-rev'; name='REV'; status='ACTIVE' }
        $certs = @(
            [PSCustomObject]@{ id='c1'; reviewer=[PSCustomObject]@{id='r1';name='Alice'}; decisionsTotal=4; decisionsMade=3 },
            [PSCustomObject]@{ id='c2'; reviewer=[PSCustomObject]@{id='r2';name='Bob'};   decisionsTotal=3; decisionsMade=3 }
        )
        $decisions = @{
            Approved = @(
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i1'; AccessName='AppA'; SourceName='AD'; Decision='APPROVE' },
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i2'; AccessName='AppB'; SourceName='AD'; Decision='APPROVE' },
                [PSCustomObject]@{ CertificationId='c2'; IdentityId='i3'; AccessName='AppC'; SourceName='AD'; Decision='APPROVE' },
                [PSCustomObject]@{ CertificationId='c2'; IdentityId='i4'; AccessName='AppD'; SourceName='AD'; Decision='APPROVE' }
            )
            Revoked = @(
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i5'; AccessName='AppE'; SourceName='AD'; Decision='REVOKE' },
                [PSCustomObject]@{ CertificationId='c2'; IdentityId='i6'; AccessName='AppF'; SourceName='AD'; Decision='REVOKE' }
            )
            Pending = @(
                [PSCustomObject]@{ CertificationId='c1'; IdentityId='i7'; AccessName='AppG'; SourceName='AD'; Decision='' }
            )
        }
        $s = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certs -Decisions $decisions -Provenance @{ Environment='TEST' }
        $s.Meta.CapturedAt = (Get-Date '2026-06-10T08:00:00').ToString('o')
        $r = Save-SPCampaignTrendPoint -Snapshot $s -TrendDir $dir
        $r.Success | Should -Be $true
        # Read back the JSONL row and parse it
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = @([System.IO.File]::ReadAllLines($r.Data.FilePath, $utf8) | Where-Object { $_ -match '\S' })
        $row = $lines[0] | ConvertFrom-Json
        $row.reviewers | Should -Not -BeNullOrEmpty
        @($row.reviewers).Count | Should -Be 2
        $alice = @($row.reviewers | Where-Object { $_.reviewer -eq 'Alice' })[0]
        $alice.total | Should -Be 4
        $alice.approved | Should -Be 2
        $alice.revoked | Should -Be 1
        $alice.pending | Should -Be 1
        $alice.completion | Should -Be 75.0
        $bob = @($row.reviewers | Where-Object { $_.reviewer -eq 'Bob' })[0]
        $bob.total | Should -Be 3
        $bob.approved | Should -Be 2
        $bob.revoked | Should -Be 1
        $bob.pending | Should -Be 0
        $bob.completion | Should -Be 100.0
    }
    It "Sets reviewers to empty array when no certs data" {
        $dir = Join-Path $TestDrive 't8b'
        $camp = [PSCustomObject]@{ id='camp-empty'; name='EMPTY'; status='ACTIVE' }
        $s = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions @{ Approved=@([PSCustomObject]@{ IdentityId='i1'; AccessName='AppA'; SourceName='AD'; Decision='APPROVE' }); Revoked=@(); Pending=@() } -Provenance @{ Environment='TEST' }
        $s.Meta.CapturedAt = (Get-Date '2026-06-10T08:00:00').ToString('o')
        $r = Save-SPCampaignTrendPoint -Snapshot $s -TrendDir $dir
        $r.Success | Should -Be $true
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = @([System.IO.File]::ReadAllLines($r.Data.FilePath, $utf8) | Where-Object { $_ -match '\S' })
        $row = $lines[0] | ConvertFrom-Json
        @($row.reviewers).Count | Should -Be 0
    }
    It "Skips reviewers with zero decisions total" {
        $dir = Join-Path $TestDrive 't8c'
        $camp = [PSCustomObject]@{ id='camp-skip'; name='SKIP'; status='ACTIVE' }
        $certs = @(
            [PSCustomObject]@{ id='c1'; reviewer=[PSCustomObject]@{id='r1';name='Active'}; decisionsTotal=2; decisionsMade=1 },
            [PSCustomObject]@{ id='c2'; reviewer=[PSCustomObject]@{id='r2';name='Empty'};  decisionsTotal=0; decisionsMade=0 }
        )
        $decisions = @{
            Approved = @([PSCustomObject]@{ CertificationId='c1'; IdentityId='i1'; AccessName='AppA'; SourceName='AD'; Decision='APPROVE' })
            Revoked = @()
            Pending = @([PSCustomObject]@{ CertificationId='c1'; IdentityId='i2'; AccessName='AppB'; SourceName='AD'; Decision='' })
        }
        $s = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certs -Decisions $decisions -Provenance @{ Environment='TEST' }
        $s.Meta.CapturedAt = (Get-Date '2026-06-10T08:00:00').ToString('o')
        $r = Save-SPCampaignTrendPoint -Snapshot $s -TrendDir $dir
        $r.Success | Should -Be $true
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $lines = @([System.IO.File]::ReadAllLines($r.Data.FilePath, $utf8) | Where-Object { $_ -match '\S' })
        $row = $lines[0] | ConvertFrom-Json
        @($row.reviewers).Count | Should -Be 1
        $row.reviewers[0].reviewer | Should -Be 'Active'
    }
}

Describe "CT-06: velocity from diff" {
    It "Derives decisions-per-hour from the diff interval + made-delta" {
        $dir = Join-Path $TestDrive 't6'
        $camp = [PSCustomObject]@{ id='camp-v'; name='V'; status='ACTIVE' }
        $prev = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @([PSCustomObject]@{ id='c'; reviewer=[PSCustomObject]@{id='r';name='R'}; decisionsTotal=10; decisionsMade=2 }) -Decisions @{Approved=@();Revoked=@();Pending=@()} -Provenance @{Environment='TEST'}
        $prev.Meta.CapturedAt = (Get-Date '2026-06-09T08:00:00').ToString('o')
        $cur  = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @([PSCustomObject]@{ id='c'; reviewer=[PSCustomObject]@{id='r';name='R'}; decisionsTotal=10; decisionsMade=12 }) -Decisions @{Approved=@();Revoked=@();Pending=@()} -Provenance @{Environment='TEST'}
        $cur.Meta.CapturedAt = (Get-Date '2026-06-09T10:00:00').ToString('o')   # +2h, +10 decisions => 5/hr
        $diff = (Compare-SPCampaignSnapshots -Current $cur -Previous $prev).Data
        Save-SPCampaignTrendPoint -Snapshot $cur -Diff $diff -TrendDir $dir | Out-Null
        $t = (Get-SPCampaignTrend -CampaignId 'camp-v' -TrendDir $dir -Granularity Daily).Data
        $t.Trends['velocity.decisionsPerHour'].Periods[0].Latest | Should -Be 5
    }
}
