<#
.SYNOPSIS
    Unit tests for SP.CampaignVelocity -- the opt-in review-velocity advisory.
    CV-01: per-reviewer velocity metrics (span, rate, approval ratio, time-to-start)
    CV-02: a fast all-approve burst is flagged 'fast-pace'; a paced reviewer is 'normal-pace'
    CV-03: missing decision timestamps degrade to 'insufficient' / coverage reported
    CV-04: HTML export carries the mandatory caveats and writes to disk
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    function New-VelSnapshot {
        param([object[]]$Approved = @(), [object[]]$Revoked = @(), [string]$Start = '2026-06-09T08:00:00Z', [object[]]$Certs = @())
        $s = Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id='camp-vel'; name='Vel'; status='COMPLETED'; created=$Start }) -Certifications $Certs -Decisions @{ Approved=$Approved; Revoked=$Revoked; Pending=@() }
        return $s
    }
    # helper to make N approve items for a reviewer's cert, spread over a span
    function New-Decisions {
        param([string]$CertId, [int]$Count, [datetime]$First, [double]$IntervalSeconds, [string]$Access = 'Domain Admins', [string]$Decision = 'APPROVE')
        $list = @()
        for ($i = 0; $i -lt $Count; $i++) {
            $when = $First.AddSeconds($i * $IntervalSeconds)
            $list += [PSCustomObject]@{ CertificationId=$CertId; IdentityId="id-$CertId-$i"; AccessName=$Access; SourceName='AD'; Decision=$Decision; DecisionDate=$when.ToString('o') }
        }
        return $list
    }
}

Describe "CV-01: per-reviewer metrics" {
    It "Computes span, rate, approval ratio and time-to-start" {
        $certs = @([PSCustomObject]@{ id='c1'; reviewer=[PSCustomObject]@{id='r1';name='Reviewer One'}; decisionsTotal=12; decisionsMade=12; signed=$true })
        # 12 approvals, one every 60s, starting 1h after campaign start
        $appr = New-Decisions -CertId 'c1' -Count 12 -First ([datetime]'2026-06-09T09:00:00Z') -IntervalSeconds 60
        $snap = New-VelSnapshot -Approved $appr -Certs $certs -Start '2026-06-09T08:00:00Z'
        $v = Measure-SPReviewerVelocity -Snapshot $snap
        $v.Success | Should -Be $true
        $r = @($v.Data.Reviewers | Where-Object { $_.ReviewerId -eq 'r1' })[0]
        $r.DecisionsTimed   | Should -Be 12
        $r.ApprovalRatio    | Should -Be 1
        $r.ActiveSpanMinutes | Should -Be 11          # first..last = 11 min
        [math]::Round($r.TimeToStartHours,0) | Should -Be 1   # started 1h after campaign start
    }
}

Describe "CV-02: fast vs normal pace" {
    It "Flags a fast all-approve burst as 'fast-pace'" {
        $certs = @([PSCustomObject]@{ id='cf'; reviewer=[PSCustomObject]@{id='rf';name='Fast'}; decisionsTotal=30; decisionsMade=30; signed=$true })
        # 30 approvals, one every 1 second => 60/min, all approve
        $appr = New-Decisions -CertId 'cf' -Count 30 -First ([datetime]'2026-06-09T09:00:00Z') -IntervalSeconds 1
        $v = Measure-SPReviewerVelocity -Snapshot (New-VelSnapshot -Approved $appr -Certs $certs)
        $r = @($v.Data.Reviewers | Where-Object { $_.ReviewerId -eq 'rf' })[0]
        $r.PaceNote | Should -Be 'fast-pace'
        $v.Data.Summary.FastPace | Should -Be 1
    }
    It "Leaves a paced reviewer (and revokes) as 'normal-pace'" {
        $certs = @([PSCustomObject]@{ id='cn'; reviewer=[PSCustomObject]@{id='rn';name='Normal'}; decisionsTotal=12; decisionsMade=12; signed=$true })
        $appr = New-Decisions -CertId 'cn' -Count 8 -First ([datetime]'2026-06-09T09:00:00Z') -IntervalSeconds 120
        $rev  = New-Decisions -CertId 'cn' -Count 4 -First ([datetime]'2026-06-09T09:20:00Z') -IntervalSeconds 120 -Access 'VPN' -Decision 'REVOKE'
        $v = Measure-SPReviewerVelocity -Snapshot (New-VelSnapshot -Approved $appr -Revoked $rev -Certs $certs)
        $r = @($v.Data.Reviewers | Where-Object { $_.ReviewerId -eq 'rn' })[0]
        $r.PaceNote | Should -Be 'normal-pace'
    }
}

Describe "CV-03: missing timestamps" {
    It "Degrades and reports timing coverage when decisions lack timestamps" {
        $certs = @([PSCustomObject]@{ id='cx'; reviewer=[PSCustomObject]@{id='rx';name='X'}; decisionsTotal=5; decisionsMade=5; signed=$true })
        $appr = @(1..5 | ForEach-Object { [PSCustomObject]@{ CertificationId='cx'; IdentityId="i$_"; AccessName='Domain Admins'; SourceName='AD'; Decision='APPROVE'; DecisionDate='' } })
        $v = Measure-SPReviewerVelocity -Snapshot (New-VelSnapshot -Approved $appr -Certs $certs)
        $v.Success | Should -Be $true
        $v.Data.Summary.ItemsDecided | Should -Be 5
        $v.Data.Summary.ItemsTimed   | Should -Be 0
        $v.Data.Summary.TimingCoveragePct | Should -Be 0
    }
}

Describe "CV-04: HTML caveats" {
    It "Writes an HTML advisory containing the mandatory caveats" {
        $certs = @([PSCustomObject]@{ id='ch'; reviewer=[PSCustomObject]@{id='rh';name='H'}; decisionsTotal=12; decisionsMade=12; signed=$true })
        $appr = New-Decisions -CertId 'ch' -Count 12 -First ([datetime]'2026-06-09T09:00:00Z') -IntervalSeconds 30
        $v = Measure-SPReviewerVelocity -Snapshot (New-VelSnapshot -Approved $appr -Certs $certs)
        $out = Join-Path $TestDrive 'vel'
        $e = Export-SPReviewerVelocityHtml -Velocity $v.Data -OutputPath $out
        $e.Success | Should -Be $true
        Test-Path $e.Data | Should -Be $true
        $html = Get-Content $e.Data -Raw
        $html | Should -Match 'advisory, not a determination'
        $html | Should -Match 'gameable'
    }
}
