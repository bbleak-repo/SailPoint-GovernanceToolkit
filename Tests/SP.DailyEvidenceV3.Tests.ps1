<#
.SYNOPSIS
    Tests for the v3 daily-evidence DELTA report. v3's body is rendered inline, so these tests
    cover (a) the script parses, and (b) the day-over-day classifications v3 consumes from the
    cross-campaign diff + the cross-campaign persistently-pending overlay it computes from a
    snapshot set. The engine PersistedRevokes split is covered by SP.CampaignDiff CDF-13.

    DV3-01: the v3 script parses with no errors
    DV3-02: cross-campaign diff yields the buckets v3 renders (net-new / silently-removed / changed)
    DV3-03: persistently-pending across >= 2 DISTINCT campaigns (not captures)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    $script:V3Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV3.ps1'

    function New-DV3Snap {
        param([string]$Id, [string]$Name, [string]$Created, [hashtable]$Dec)
        Build-SPCampaignSnapshotData -Campaign ([PSCustomObject]@{ id = $Id; name = $Name; status = 'ACTIVE'; created = $Created }) -Certifications @() -Decisions $Dec
    }
    # v3's own overlay: count keys that are PENDING in >= 2 distinct campaign snapshots.
    function Measure-DV3CrossPending {
        param([object[]]$Snapshots)
        $cnt = @{}
        foreach ($snap in $Snapshots) {
            $seen = @{}
            foreach ($it in @($snap.Items)) {
                if ([string]$it.Decision -ne 'PENDING') { continue }
                $k = [string]$it.Key
                if (-not $k -or $seen.ContainsKey($k)) { continue }
                $seen[$k] = $true
                if (-not $cnt.ContainsKey($k)) { $cnt[$k] = 0 }
                $cnt[$k]++
            }
        }
        return $cnt
    }
}

Describe "DV3-01: v3 script parses" {
    It "has no parse errors" {
        Test-Path $script:V3Path | Should -Be $true
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:V3Path, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe "DV3-02: cross-campaign diff yields the buckets v3 renders" {
    BeforeAll {
        $prevDec = @{ Approved = @(
                [PSCustomObject]@{ IdentityId='i1'; IdentityName='A'; AccessName='admin'; AccessId='a1'; SourceName='AD'; SourceId='s1'; SourceType='Active Directory - Direct'; Decision='APPROVE'; DecisionDate='2026-06-10T09:00:00Z' }
                [PSCustomObject]@{ IdentityId='i3'; IdentityName='C'; AccessName='vpn'; AccessId='a3'; SourceName='AD'; SourceId='s1'; SourceType='Active Directory - Direct'; Decision='APPROVE'; DecisionDate='2026-06-10T09:00:00Z' }
            ); Pending=@(); Revoked=@() }
        $curDec = @{ Approved = @(
                [PSCustomObject]@{ IdentityId='i9'; IdentityName='New'; AccessName='dba'; AccessId='a9'; SourceName='AD'; SourceId='s1'; SourceType='Active Directory - Direct'; Decision='APPROVE'; DecisionDate='2026-06-11T09:00:00Z' }
            ); Pending=@(); Revoked=@(
                [PSCustomObject]@{ IdentityId='i1'; IdentityName='A'; AccessName='admin'; AccessId='a1'; SourceName='AD'; SourceId='s1'; SourceType='Active Directory - Direct'; Decision='REVOKE'; DecisionDate='2026-06-11T11:00:00Z' }
            ) }
        $prev = New-DV3Snap 'cMon' 'Daily Monday' '2026-06-10T08:00:00Z' $prevDec
        $cur  = New-DV3Snap 'cTue' 'Daily Tuesday' '2026-06-11T08:00:00Z' $curDec
        $script:dv2 = (Compare-SPCampaignSnapshots -Current $cur -Previous $prev -CrossCampaign).Data
    }
    It "net-new = Added (i9 dba, absent in the prior campaign)" {
        @($script:dv2.Scope.Added | Where-Object { $_.AccessName -eq 'dba' }).Count | Should -Be 1
    }
    It "silently-removed = Removed whose prior decision was NOT a revoke (i3 vpn)" {
        $silent = @($script:dv2.Scope.Removed | Where-Object { $_.Decision -ne 'REVOKE' })
        @($silent | Where-Object { $_.AccessName -eq 'vpn' }).Count | Should -Be 1
    }
    It "changed = APPROVE->REVOKE flip on existing access (i1 admin)" {
        $ch = @($script:dv2.Scope.Changed | Where-Object { $_.AccessName -eq 'admin' })[0]
        $ch.Transition | Should -Be 'APPROVE->REVOKE'
    }
}

Describe "DV3-03: persistently pending across >= 2 distinct campaigns" {
    It "counts a key PENDING in two separate campaigns, ignores a one-campaign pending" {
        $pend = { param($iid, $acc) [PSCustomObject]@{ IdentityId=$iid; IdentityName=$iid; AccessName=$acc; AccessId=$acc; SourceName='AD'; SourceId='s1'; SourceType='Active Directory - Direct'; Decision='PENDING'; DecisionDate='' } }
        $mon = New-DV3Snap 'cMon' 'Daily Monday'  '2026-06-09T08:00:00Z' @{ Approved=@(); Revoked=@(); Pending=@((& $pend 'u1' 'eShared'), (& $pend 'u2' 'eMonOnly')) }
        $tue = New-DV3Snap 'cTue' 'Daily Tuesday' '2026-06-10T08:00:00Z' @{ Approved=@(); Revoked=@(); Pending=@((& $pend 'u1' 'eShared')) }
        $wed = New-DV3Snap 'cWed' 'Daily Wednesday' '2026-06-11T08:00:00Z' @{ Approved=@(); Revoked=@(); Pending=@((& $pend 'u1' 'eShared')) }
        $counts = Measure-DV3CrossPending -Snapshots @($mon, $tue, $wed)
        $sharedKey = 'u1|eShared|s1'
        $monOnlyKey = 'u2|eMonOnly|s1'
        $counts[$sharedKey]  | Should -Be 3
        $counts[$monOnlyKey] | Should -Be 1
        @($counts.Keys | Where-Object { $counts[$_] -ge 2 }).Count | Should -Be 1
    }
}
