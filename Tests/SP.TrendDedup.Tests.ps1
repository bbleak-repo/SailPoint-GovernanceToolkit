<#
.SYNOPSIS
    Unit tests for WI-9 (G6) -- long-term-store dedup + ACTIVE-record protection.
    Ports the daily-evidence ACTIVE-protection + same-day dedup to the two long-term
    stores (SP.CampaignTrend + governance-metrics.jsonl) and the trend per-reviewer read path.

    TD-01: trend -ProtectActive skips a same-day COMPLETED capture when an ACTIVE row exists
    TD-02: default (no switch) appends both same-day rows (back-compat with CT-04)
    TD-03: -ProtectActive does NOT skip when prior same-day row is COMPLETED or on a different day
    TD-04: Save-SPGovernanceMetrics -DedupSameDay skips a 2nd same-Label same-day run; default appends
    TD-05: Get-SPCampaignReviewerTrend round-trips per-reviewer Alice/Bob series + Latest.completion
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    function New-TDSnapshot {
        param([string]$Id = 'camp-td', [string]$Status = 'ACTIVE', [int]$PrivApproved = 2, [int]$PrivRevoked = 1, [int]$Approved = 5, [int]$Revoked = 2, [string]$CapturedAt)
        $approvedItems = @()
        for ($i = 0; $i -lt $PrivApproved; $i++) { $approvedItems += [PSCustomObject]@{ IdentityId="i$i"; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE' } }
        for ($i = 0; $i -lt ($Approved - $PrivApproved); $i++) { $approvedItems += [PSCustomObject]@{ IdentityId="n$i"; AccessName='Finance-Reader'; SourceName='AD'; Decision='APPROVE' } }
        $revokedItems = @()
        for ($i = 0; $i -lt $PrivRevoked; $i++) { $revokedItems += [PSCustomObject]@{ IdentityId="r$i"; AccessName='DBA-Master'; SourceName='Oracle'; Decision='REVOKE' } }
        for ($i = 0; $i -lt ($Revoked - $PrivRevoked); $i++) { $revokedItems += [PSCustomObject]@{ IdentityId="x$i"; AccessName='VPN'; SourceName='Okta'; Decision='REVOKE' } }
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id=$Id; name='TD'; status=$Status }) -Certifications @() -Decisions @{ Approved=$approvedItems; Revoked=$revokedItems; Pending=@() } -Provenance @{ Environment='TEST' }
        $s.Meta.Status = $Status
        if ($CapturedAt) { $s.Meta.CapturedAt = $CapturedAt }
        return $s
    }

    function Get-TDLineCount {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return 0 }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        return @([System.IO.File]::ReadAllLines($Path, $utf8) | Where-Object { $_ -match '\S' }).Count
    }
}

Describe "TD-01: trend -ProtectActive skips same-day COMPLETED when ACTIVE row exists" {
    It "Keeps only the honest ACTIVE row for the day" {
        $dir = Join-Path $TestDrive 'td1'
        $active = New-TDSnapshot -Id 'camp-td1' -Status 'ACTIVE' -CapturedAt '2026-06-10T08:00:00Z'
        $r1 = Save-SPCampaignTrendPoint -Snapshot $active -TrendDir $dir -ProtectActive
        $r1.Success | Should -Be $true
        $completed = New-TDSnapshot -Id 'camp-td1' -Status 'COMPLETED' -CapturedAt '2026-06-10T14:00:00Z'
        $r2 = Save-SPCampaignTrendPoint -Snapshot $completed -TrendDir $dir -ProtectActive
        $r2.Success | Should -Be $true
        $r2.Data.Skipped | Should -Be $true
        $r2.Data.SkipReason | Should -Match 'ACTIVE record exists'
        # File has exactly 1 line, and it is the ACTIVE row
        Get-TDLineCount -Path $r1.Data.FilePath | Should -Be 1
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $row = (@([System.IO.File]::ReadAllLines($r1.Data.FilePath, $utf8) | Where-Object { $_ -match '\S' }))[0] | ConvertFrom-Json
        $row.status | Should -Be 'ACTIVE'
        $t = (Get-SPCampaignTrend -CampaignId 'camp-td1' -TrendDir $dir -Granularity Daily).Data
        $t.PointCount | Should -Be 1
    }
}

Describe "TD-02: default (no switch) appends both same-day rows" {
    It "Back-compat: 2 same-day captures are both written" {
        $dir = Join-Path $TestDrive 'td2'
        $active = New-TDSnapshot -Id 'camp-td2' -Status 'ACTIVE' -CapturedAt '2026-06-10T08:00:00Z'
        Save-SPCampaignTrendPoint -Snapshot $active -TrendDir $dir | Out-Null
        $completed = New-TDSnapshot -Id 'camp-td2' -Status 'COMPLETED' -CapturedAt '2026-06-10T14:00:00Z'
        $r2 = Save-SPCampaignTrendPoint -Snapshot $completed -TrendDir $dir
        $r2.Success | Should -Be $true
        Get-TDLineCount -Path $r2.Data.FilePath | Should -Be 2
        $t = (Get-SPCampaignTrend -CampaignId 'camp-td2' -TrendDir $dir -Granularity Daily).Data
        $t.PointCount | Should -Be 2
    }
}

Describe "TD-03: -ProtectActive does not over-skip" {
    It "Appends when the prior same-day row is COMPLETED (not ACTIVE)" {
        $dir = Join-Path $TestDrive 'td3a'
        $c1 = New-TDSnapshot -Id 'camp-td3a' -Status 'COMPLETED' -CapturedAt '2026-06-10T08:00:00Z'
        Save-SPCampaignTrendPoint -Snapshot $c1 -TrendDir $dir -ProtectActive | Out-Null
        $c2 = New-TDSnapshot -Id 'camp-td3a' -Status 'COMPLETED' -CapturedAt '2026-06-10T14:00:00Z'
        $r2 = Save-SPCampaignTrendPoint -Snapshot $c2 -TrendDir $dir -ProtectActive
        $r2.Data.Skipped | Should -Not -Be $true
        Get-TDLineCount -Path $r2.Data.FilePath | Should -Be 2
    }
    It "Appends when the prior ACTIVE row is on a different day" {
        $dir = Join-Path $TestDrive 'td3b'
        $a1 = New-TDSnapshot -Id 'camp-td3b' -Status 'ACTIVE' -CapturedAt '2026-06-09T08:00:00Z'
        Save-SPCampaignTrendPoint -Snapshot $a1 -TrendDir $dir -ProtectActive | Out-Null
        $c2 = New-TDSnapshot -Id 'camp-td3b' -Status 'COMPLETED' -CapturedAt '2026-06-10T08:00:00Z'
        $r2 = Save-SPCampaignTrendPoint -Snapshot $c2 -TrendDir $dir -ProtectActive
        $r2.Data.Skipped | Should -Not -Be $true
        Get-TDLineCount -Path $r2.Data.FilePath | Should -Be 2
    }
}

Describe "TD-04: Save-SPGovernanceMetrics -DedupSameDay" {
    It "Skips a 2nd same-Label same-day run while default appends" {
        $dirDedup = Join-Path $TestDrive 'gm-dedup'
        New-Item -Path $dirDedup -ItemType Directory -Force | Out-Null
        $first  = Save-SPGovernanceMetrics -Label 'daily-x' -MetricsDir $dirDedup -DedupSameDay
        $first.Success | Should -Be $true
        $second = Save-SPGovernanceMetrics -Label 'daily-x' -MetricsDir $dirDedup -DedupSameDay
        $second.Success | Should -Be $true
        $second.Data.Skipped | Should -Be $true
        Get-TDLineCount -Path $first.Data.FilePath | Should -Be 1

        # Default (no switch) appends a 2nd line
        $dirAppend = Join-Path $TestDrive 'gm-append'
        New-Item -Path $dirAppend -ItemType Directory -Force | Out-Null
        $a1 = Save-SPGovernanceMetrics -Label 'daily-y' -MetricsDir $dirAppend
        $a2 = Save-SPGovernanceMetrics -Label 'daily-y' -MetricsDir $dirAppend
        $a1.Success | Should -Be $true
        $a2.Success | Should -Be $true
        Get-TDLineCount -Path $a2.Data.FilePath | Should -Be 2
    }
}

Describe "TD-05: Get-SPCampaignReviewerTrend per-reviewer read path" {
    It "Round-trips per-reviewer Alice/Bob series + Latest.completion across two captures" {
        $dir = Join-Path $TestDrive 'td5'
        $camp = [PSCustomObject]@{ id='camp-rt'; name='RT'; status='ACTIVE' }
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
        $s1 = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certs -Decisions $decisions -Provenance @{ Environment='TEST' }
        $s1.Meta.CapturedAt = '2026-06-09T08:00:00Z'
        Save-SPCampaignTrendPoint -Snapshot $s1 -TrendDir $dir | Out-Null
        $s2 = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certs -Decisions $decisions -Provenance @{ Environment='TEST' }
        $s2.Meta.CapturedAt = '2026-06-10T08:00:00Z'
        Save-SPCampaignTrendPoint -Snapshot $s2 -TrendDir $dir | Out-Null

        $rt = Get-SPCampaignReviewerTrend -CampaignId 'camp-rt' -TrendDir $dir
        $rt.Success | Should -Be $true
        $rt.Data.PointCount | Should -Be 2
        @($rt.Data.Reviewers).Count | Should -Be 2
        $alice = @($rt.Data.Reviewers | Where-Object { $_.Reviewer -eq 'Alice' })[0]
        $alice | Should -Not -BeNullOrEmpty
        @($alice.Points).Count | Should -Be 2
        $alice.Latest.total | Should -Be 4
        $alice.Latest.completion | Should -Be 75.0
        $bob = @($rt.Data.Reviewers | Where-Object { $_.Reviewer -eq 'Bob' })[0]
        @($bob.Points).Count | Should -Be 2
        $bob.Latest.completion | Should -Be 100.0
    }
    It "Returns empty Reviewers for an unknown campaign" {
        $dir = Join-Path $TestDrive 'td5b'
        $rt = Get-SPCampaignReviewerTrend -CampaignId 'nope' -TrendDir $dir
        $rt.Success | Should -Be $true
        @($rt.Data.Reviewers).Count | Should -Be 0
        $rt.Data.PointCount | Should -Be 0
    }
}
