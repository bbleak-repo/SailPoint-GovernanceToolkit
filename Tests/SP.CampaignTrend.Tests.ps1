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
