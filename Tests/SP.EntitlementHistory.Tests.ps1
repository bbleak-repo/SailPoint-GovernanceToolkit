<#
.SYNOPSIS
    Unit tests for the per-entitlement decision history (Get-SPEntitlementHistory,
    Export-SPEntitlementHistory*Html/Csv, Get-SPCampaignSnapshotSet).
    HIST-01: timeline classification (flip / first-seen / unchanged exclusion)
    HIST-02: filters (by entitlement)
    HIST-03: HTML + CSV exporters round-trip to disk
    HIST-04: Get-SPCampaignSnapshotSet cross-campaign ordering + -WithinCampaign
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    function script:New-HistSnap([object]$Campaign, [hashtable]$Decisions, [string]$CapturedAt) {
        $s = Build-SPCampaignSnapshotData -Campaign $Campaign -Certifications @() -Decisions $Decisions
        if ($CapturedAt) { $s.Meta.CapturedAt = $CapturedAt }
        return $s
    }
    function script:Appr($id, $name, $acc, $accId, $dec, $date) {
        [PSCustomObject]@{ IdentityId = $id; IdentityName = $name; AccessName = $acc; AccessId = $accId; AccessType = 'ENTITLEMENT'; SourceName = 'Corporate AD'; SourceId = 'src-ad'; Decision = $dec; DecisionDate = $date }
    }

    $c8  = [PSCustomObject]@{ id = 'camp-0608'; name = 'Daily Attestation 2026-06-08'; status = 'ACTIVE'; created = '2026-06-08T00:00:00Z' }
    $c9  = [PSCustomObject]@{ id = 'camp-0609'; name = 'Daily Attestation 2026-06-09'; status = 'ACTIVE'; created = '2026-06-09T00:00:00Z' }
    $c11 = [PSCustomObject]@{ id = 'camp-0611'; name = 'Daily Attestation 2026-06-11'; status = 'ACTIVE'; created = '2026-06-11T00:00:00Z' }

    # admin_xyz: John APPROVE 6/8 -> APPROVE 6/9 -> REVOKE 6/11 ; vpn: John APPROVE all 3 (unchanged) ;
    # Alice gets admin_xyz for the FIRST time on 6/11.
    $script:s8 = New-HistSnap $c8 @{ Approved = @( (Appr 'john' 'John Doe' 'admin_xyz' 'ent-axyz' 'APPROVE' '2026-06-08T14:00:00Z'), (Appr 'john' 'John Doe' 'vpn' 'ent-vpn' 'APPROVE' '2026-06-08T14:01:00Z') ); Revoked = @(); Pending = @() } '2026-06-08T08:00:00Z'
    $script:s9 = New-HistSnap $c9 @{ Approved = @( (Appr 'john' 'John Doe' 'admin_xyz' 'ent-axyz' 'APPROVE' '2026-06-09T14:00:00Z'), (Appr 'john' 'John Doe' 'vpn' 'ent-vpn' 'APPROVE' '2026-06-09T14:01:00Z') ); Revoked = @(); Pending = @() } '2026-06-09T08:00:00Z'
    $script:s11 = New-HistSnap $c11 @{ Approved = @( (Appr 'alice' 'Alice Noname' 'admin_xyz' 'ent-axyz' 'APPROVE' '2026-06-11T10:00:00Z'), (Appr 'john' 'John Doe' 'vpn' 'ent-vpn' 'APPROVE' '2026-06-11T14:01:00Z') ); Revoked = @( (Appr 'john' 'John Doe' 'admin_xyz' 'ent-axyz' 'REVOKE' '2026-06-11T11:00:00Z') ); Pending = @() } '2026-06-11T08:00:00Z'

    # Pass deliberately out of order to prove the function sorts by date.
    $script:hist = (Get-SPEntitlementHistory -Snapshots @($script:s11, $script:s8, $script:s9)).Data
}

Describe "HIST-01: timeline classification" {
    It "records John's admin_xyz flip APPROVE -> REVOKE across 3 campaigns" {
        $t = @($script:hist.Timelines | Where-Object { $_.IdentityId -eq 'john' -and $_.AccessName -eq 'admin_xyz' })
        $t.Count               | Should -Be 1
        $t[0].ObservationCount | Should -Be 3
        $t[0].ChangeCount      | Should -Be 1
        $t[0].FirstDecision    | Should -Be 'APPROVE'
        $t[0].LastDecision     | Should -Be 'REVOKE'
        @($t[0].Observations)[-1].ChangeFromPrev | Should -Be 'APPROVE->REVOKE'
    }
    It "flags Alice's admin_xyz as a first-time grant (appeared after the first snapshot)" {
        $t = @($script:hist.Timelines | Where-Object { $_.IdentityId -eq 'alice' -and $_.AccessName -eq 'admin_xyz' })
        $t.Count                  | Should -Be 1
        $t[0].AppearedAfterFirst  | Should -Be $true
        $t[0].FirstDecision       | Should -Be 'APPROVE'
    }
    It "excludes the unchanged vpn timeline by default but includes it with -IncludeUnchanged" {
        @($script:hist.Timelines | Where-Object { $_.AccessName -eq 'vpn' }).Count | Should -Be 0
        $all = (Get-SPEntitlementHistory -Snapshots @($script:s8, $script:s9, $script:s11) -IncludeUnchanged).Data
        @($all.Timelines | Where-Object { $_.AccessName -eq 'vpn' }).Count | Should -Be 1
    }
}

Describe "HIST-02: filters" {
    It "restricts to a single entitlement by name" {
        $h = (Get-SPEntitlementHistory -Snapshots @($script:s8, $script:s9, $script:s11) -AccessName 'admin_xyz').Data
        @($h.Timelines).Count | Should -Be 2   # John (flip) + Alice (first-time)
        @($h.Timelines | Where-Object { $_.AccessName -ne 'admin_xyz' }).Count | Should -Be 0
    }
}

Describe "HIST-03: exporters round-trip" {
    BeforeAll {
        $script:od = Join-Path ([System.IO.Path]::GetTempPath()) ("hist-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:od -Force | Out-Null
    }
    AfterAll { if ($script:od -and (Test-Path $script:od)) { Remove-Item -Recurse -Force $script:od -ErrorAction SilentlyContinue } }
    It "writes an HTML report containing the entitlement and the flip" {
        $f = Join-Path $script:od 'h.html'
        $r = Export-SPEntitlementHistoryHtml -History $script:hist -OutputPath $f -GroupBy Both
        $r.Success | Should -Be $true
        Test-Path $r.Data | Should -Be $true
        $c = Get-Content $r.Data -Raw
        $c | Should -Match 'admin_xyz'
        $c | Should -Match 'REVOKE'
        $c | Should -Match 'By entitlement'
        $c | Should -Match 'By identity'
    }
    It "writes a CSV with one row per observation and the change label" {
        $f = Join-Path $script:od 'h.csv'
        $r = Export-SPEntitlementHistoryCsv -History $script:hist -OutputPath $f
        $r.Success | Should -Be $true
        $rows = Import-Csv $r.Data
        @($rows | Where-Object { $_.IdentityId -eq 'john' -and $_.AccessName -eq 'admin_xyz' }).Count | Should -Be 3
        @($rows | Where-Object { $_.ChangeFromPrev -eq 'APPROVE->REVOKE' }).Count | Should -Be 1
    }
}

Describe "HIST-04: Get-SPCampaignSnapshotSet" {
    BeforeAll {
        $script:sd = Join-Path ([System.IO.Path]::GetTempPath()) ("hsnap-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:sd -Force | Out-Null
        Save-SPCampaignSnapshot -Snapshot $script:s8  -SnapshotDir $script:sd | Out-Null
        Save-SPCampaignSnapshot -Snapshot $script:s9  -SnapshotDir $script:sd | Out-Null
        Save-SPCampaignSnapshot -Snapshot $script:s11 -SnapshotDir $script:sd | Out-Null

        # A standing (single, long-lived) campaign with TWO captures: APPROVE then REVOKE.
        $cw = [PSCustomObject]@{ id = 'camp-standing'; name = 'Standing Review'; status = 'ACTIVE'; created = '2026-06-01T00:00:00Z' }
        $w1 = New-HistSnap $cw @{ Approved = @( (Appr 'john' 'John Doe' 'admin_xyz' 'ent-axyz' 'APPROVE' '2026-06-11T08:30:00Z') ); Revoked = @(); Pending = @() } '2026-06-11T08:00:00Z'
        $w2 = New-HistSnap $cw @{ Approved = @(); Revoked = @( (Appr 'john' 'John Doe' 'admin_xyz' 'ent-axyz' 'REVOKE' '2026-06-11T12:30:00Z') ); Pending = @() } '2026-06-11T12:00:00Z'
        Save-SPCampaignSnapshot -Snapshot $w1 -SnapshotDir $script:sd | Out-Null
        Save-SPCampaignSnapshot -Snapshot $w2 -SnapshotDir $script:sd | Out-Null
    }
    AfterAll { if ($script:sd -and (Test-Path $script:sd)) { Remove-Item -Recurse -Force $script:sd -ErrorAction SilentlyContinue } }

    It "cross-campaign: one snapshot per matching campaign, oldest start first" {
        $r = Get-SPCampaignSnapshotSet -SnapshotDir $script:sd -CampaignNameContains 'Daily Attestation'
        $r.Success | Should -Be $true
        @($r.Data).Count | Should -Be 3
        [string]@($r.Data)[0].Meta.CampaignId | Should -Be 'camp-0608'
        [string]@($r.Data)[2].Meta.CampaignId | Should -Be 'camp-0611'
    }
    It "-WithinCampaign: every capture of one campaign, oldest first" {
        $r = Get-SPCampaignSnapshotSet -SnapshotDir $script:sd -CampaignId 'camp-standing' -WithinCampaign
        $r.Success | Should -Be $true
        @($r.Data).Count | Should -Be 2
        # walked end-to-end -> the single campaign's own APPROVE -> REVOKE flip
        $h = (Get-SPEntitlementHistory -Snapshots @($r.Data)).Data
        $t = @($h.Timelines | Where-Object { $_.AccessName -eq 'admin_xyz' })
        $t.Count          | Should -Be 1
        $t[0].FirstDecision | Should -Be 'APPROVE'
        $t[0].LastDecision  | Should -Be 'REVOKE'
    }
    It "-WithinCampaign errors when the filter matches more than one campaign" {
        $r = Get-SPCampaignSnapshotSet -SnapshotDir $script:sd -CampaignNameContains 'Daily Attestation' -WithinCampaign
        $r.Success | Should -Be $false
        $r.Error   | Should -Match 'narrow'
    }
}
