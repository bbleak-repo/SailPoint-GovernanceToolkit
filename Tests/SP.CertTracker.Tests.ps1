<#
.SYNOPSIS
    Unit tests for SP.CertTracker -- the executive certification progress tracker engine.
    CTK-01: stage derivation across the lifecycle (Launched..Closed)
    CTK-02: velocity + projected-close vs deadline (OnTrack / AtRisk / Behind)
    CTK-03: momentum + days-in phase (Ramp / Pace / LongTail), active-is-normal
    CTK-04: RAG + program rollup (pipeline board)
    CTK-05: graceful degradation (no previous, no dates, zero velocity)
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # Build a snapshot with controllable decided/total/signed + dates.
    function New-TkSnapshot {
        param(
            [string]$Id = 'camp-tk', [string]$Status = 'ACTIVE',
            [int]$Approved = 0, [int]$Revoked = 0, [int]$Pending = 0,
            [int]$RevTotal = 0, [int]$RevSigned = 0, [int]$RemPending = 0,
            [string]$Start, [string]$Due, [string]$Captured
        )
        # NOTE: guard ranges -- PowerShell 1..0 = (1,0), so an unguarded range fabricates a phantom item at 0.
        $appr = @(); if ($Approved -gt 0) { $appr = @(1..$Approved | ForEach-Object { [PSCustomObject]@{ IdentityId="a$_"; AccessName='E'; SourceName='AD'; Decision='APPROVE' } }) }
        $rev  = @(); if ($Revoked  -gt 0) { $rev  = @(1..$Revoked  | ForEach-Object { [PSCustomObject]@{ IdentityId="r$_"; AccessName='E'; SourceName='AD'; Decision='REVOKE'; RemediationStatus = $(if ($_ -le $RemPending) { 'Pending' } else { 'Provisioned' }) } }) }
        $pend = @(); if ($Pending  -gt 0) { $pend = @(1..$Pending  | ForEach-Object { [PSCustomObject]@{ IdentityId="p$_"; AccessName='E'; SourceName='AD'; Decision='PENDING' } }) }
        $certs = @()
        for ($i = 0; $i -lt $RevTotal; $i++) {
            $signed = ($i -lt $RevSigned)
            # made/total so the cert looks done when signed; partial otherwise
            $certs += [PSCustomObject]@{ id="c$i"; reviewer=[PSCustomObject]@{id="rv$i";name="Rv$i"}; decisionsTotal=4; decisionsMade=$(if ($signed) { 4 } else { 0 }); signed=$signed }
        }
        $camp = [PSCustomObject]@{ id=$Id; name='Tracker'; status=$Status }
        if ($Start) { $camp | Add-Member created $Start -Force }
        if ($Due)   { $camp | Add-Member deadline $Due -Force }
        $s = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certs -Decisions @{ Approved=$appr; Revoked=$rev; Pending=$pend }
        if ($Captured) { $s.Meta.CapturedAt = $Captured }
        return $s
    }
}

Describe "CTK-01: stage derivation" {
    It "Launched when no decisions yet" {
        $cur = New-TkSnapshot -Approved 0 -Revoked 0 -Pending 10 -RevTotal 3 -RevSigned 0
        $d = (Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })).Data.Campaigns[0]
        $d.Stage | Should -Be 'Launched'
    }
    It "In Review when partially decided" {
        $cur = New-TkSnapshot -Approved 4 -Revoked 1 -Pending 5 -RevTotal 3 -RevSigned 1
        ((Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })).Data.Campaigns[0]).Stage | Should -Be 'In Review'
    }
    It "Decisions Done when all decided but not all signed" {
        $cur = New-TkSnapshot -Approved 8 -Revoked 2 -Pending 0 -RevTotal 3 -RevSigned 1
        ((Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })).Data.Campaigns[0]).Stage | Should -Be 'Decisions Done'
    }
    It "Remediation when all signed but revocations pending de-provisioning" {
        $cur = New-TkSnapshot -Approved 6 -Revoked 4 -Pending 0 -RevTotal 3 -RevSigned 3 -RemPending 2
        ((Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })).Data.Campaigns[0]).Stage | Should -Be 'Remediation'
    }
    It "Closed when campaign status COMPLETED" {
        $cur = New-TkSnapshot -Status 'COMPLETED' -Approved 8 -Revoked 2 -Pending 0 -RevTotal 3 -RevSigned 3
        ((Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })).Data.Campaigns[0]).Stage | Should -Be 'Closed'
    }
}

Describe "CTK-02: velocity + projection" {
    It "Projects close from velocity and flags OnTrack before the deadline" {
        # prev: 10 decided at T0; cur: 50 decided at T0+1day => 40/day; 50 remaining => ~1.25d => well before a 5-day deadline
        $prev = New-TkSnapshot -Approved 10 -Revoked 0 -Pending 90 -RevTotal 5 -RevSigned 0 -Start '2026-06-09T08:00:00Z' -Captured '2026-06-09T08:00:00Z'
        $cur  = New-TkSnapshot -Approved 50 -Revoked 0 -Pending 50 -RevTotal 5 -RevSigned 0 -Start '2026-06-09T08:00:00Z' -Due '2026-06-14T08:00:00Z' -Captured '2026-06-10T08:00:00Z'
        $d = (Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $prev })).Data.Campaigns[0]
        $d.VelocityPerDay | Should -Be 40
        $d.ProjectedVsDeadline | Should -Be 'OnTrack'
    }
    It "Flags Behind when velocity can't make the deadline" {
        # 5/day, 50 remaining => 10 days, deadline in 2 days => Behind
        $prev = New-TkSnapshot -Approved 0 -Revoked 0 -Pending 100 -RevTotal 5 -RevSigned 0 -Start '2026-06-09T08:00:00Z' -Captured '2026-06-09T08:00:00Z'
        $cur  = New-TkSnapshot -Approved 5 -Revoked 0 -Pending 50 -RevTotal 5 -RevSigned 0 -Start '2026-06-09T08:00:00Z' -Due '2026-06-12T08:00:00Z' -Captured '2026-06-10T08:00:00Z'
        $d = (Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $prev })).Data.Campaigns[0]
        $d.ProjectedVsDeadline | Should -Be 'Behind'
        $d.Rag | Should -Be 'Red'
    }
}

Describe "CTK-03: momentum + days-in phase" {
    It "Ramp early (under a day in), with movement vs prior" {
        $prev = New-TkSnapshot -Approved 0 -Revoked 0 -Pending 20 -RevTotal 2 -RevSigned 0 -Start '2026-06-10T08:00:00Z' -Captured '2026-06-10T10:00:00Z'
        $cur  = New-TkSnapshot -Approved 5 -Revoked 0 -Pending 15 -RevTotal 2 -RevSigned 0 -Start '2026-06-10T08:00:00Z' -Captured '2026-06-10T14:00:00Z'
        $d = (Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $prev })).Data.Campaigns[0]
        $d.Phase | Should -Be 'Ramp'
        $d.Momentum | Should -BeIn @('Advanced','Moving')   # Launched -> In Review = forward movement
    }
    It "LongTail when many days in and still active; stalled momentum flagged" {
        $prev = New-TkSnapshot -Approved 30 -Revoked 0 -Pending 10 -RevTotal 3 -RevSigned 0 -Start '2026-06-01T08:00:00Z' -Captured '2026-06-10T08:00:00Z'
        $cur  = New-TkSnapshot -Approved 30 -Revoked 0 -Pending 10 -RevTotal 3 -RevSigned 0 -Start '2026-06-01T08:00:00Z' -Captured '2026-06-11T08:00:00Z'
        $d = (Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $prev })).Data.Campaigns[0]
        $d.Phase | Should -Be 'LongTail'
        $d.Momentum | Should -Be 'Stalled'
    }
}

Describe "CTK-04: RAG + program rollup" {
    It "Rolls up a pipeline board across campaigns" {
        $c1 = New-TkSnapshot -Id 'c1' -Approved 0 -Revoked 0 -Pending 10 -RevTotal 2 -RevSigned 0
        $c2 = New-TkSnapshot -Id 'c2' -Approved 5 -Revoked 1 -Pending 4 -RevTotal 2 -RevSigned 1
        $c3 = New-TkSnapshot -Id 'c3' -Status 'COMPLETED' -Approved 8 -Revoked 2 -Pending 0 -RevTotal 2 -RevSigned 2
        $r = (Build-SPCertTrackerData -Campaigns @(
            @{ Current = $c1; Previous = $null }, @{ Current = $c2; Previous = $null }, @{ Current = $c3; Previous = $null }
        )).Data
        $r.Program.TotalCampaigns | Should -Be 3
        $r.Program.ActiveCampaigns | Should -Be 2
        $r.Program.ByStage['Launched'] | Should -Be 1
        $r.Program.ByStage['Closed'] | Should -Be 1
    }
}

Describe "CTK-06: HTML board" {
    It "Renders a tracker board (stage rail + pace cards + both completion framings)" {
        $c1 = New-TkSnapshot -Id 'c1' -Approved 0 -Revoked 0 -Pending 10 -RevTotal 2 -RevSigned 0 -Start '2026-06-09T08:00:00Z' -Due '2026-06-13T08:00:00Z' -Captured '2026-06-09T16:00:00Z'
        $c2 = New-TkSnapshot -Id 'c2' -Approved 30 -Revoked 5 -Pending 5 -RevTotal 2 -RevSigned 1 -Start '2026-06-05T08:00:00Z' -Due '2026-06-10T08:00:00Z' -Captured '2026-06-09T16:00:00Z'
        $data = (Build-SPCertTrackerData -Campaigns @(@{ Current = $c1; Previous = $null }, @{ Current = $c2; Previous = $null })).Data
        $out = Join-Path $TestDrive 'board'
        $e = Export-SPCertTrackerHtml -TrackerData $data -OutputPath $out
        $e.Success | Should -Be $true
        Test-Path $e.Data | Should -Be $true
        $html = Get-Content $e.Data -Raw
        $html | Should -Match 'Certification Progress Tracker'
        $html | Should -Match 'Reviewers complete'
        $html | Should -Match 'Decisions complete'
    }
}

Describe "CTK-07: attestation evidence pack" {
    It "Renders actual decisions/reviewer/date/justification + revocation closure" {
        $decisions = @{
            Approved = @(
                [PSCustomObject]@{ IdentityName='Alice'; AccessName='Finance-Reader'; SourceName='AD'; Privileged=$false; ReviewerName='Mgr One'; ReviewerEmail='m1@x'; DecisionDate='2026-06-09T09:00:00Z'; Justification='Role-appropriate'; RemediationStatus='N/A' }
                [PSCustomObject]@{ IdentityName='Eve'; AccessName='Domain Admins'; SourceName='AD'; Privileged=$true; ReviewerName='Mgr One'; DecisionDate='2026-06-09T09:05:00Z'; Justification='Approved with note' }
            )
            Revoked = @(
                [PSCustomObject]@{ IdentityName='Bob'; AccessName='VPN'; SourceName='Okta'; Privileged=$false; ReviewerName='Mgr Two'; DecisionDate='2026-06-09T09:10:00Z'; Justification='No longer needed'; RemediationStatus='Pending' }
            )
            Pending = @(
                [PSCustomObject]@{ IdentityName='Carol'; AccessName='App-Reader'; SourceName='AD'; Privileged=$false; ReviewerName='Mgr Two' }
            )
        }
        $meta = @{ Name='Daily Attestation - Tue'; Id='camp-ev'; Status='ACTIVE'; StartDate='2026-06-06T08:00:00Z'; DueDate='2026-06-11T08:00:00Z'; CapturedAt='2026-06-09T16:00:00Z'; ReviewersSigned=1; ReviewersTotal=2 }
        $out = Join-Path $TestDrive 'ev'
        $e = Export-SPAttestationEvidenceHtml -CampaignMeta $meta -Decisions $decisions -OutputPath $out
        $e.Success | Should -Be $true
        Test-Path $e.Data | Should -Be $true
        $html = Get-Content $e.Data -Raw
        $html | Should -Match 'Attestation Evidence Pack'
        $html | Should -Match 'Mgr One'           # real reviewer rendered
        $html | Should -Match 'No longer needed'   # real justification rendered
        $html | Should -Match 'Revocation closure' # closure section
        $html | Should -Match 'Pending removal'    # revoked-not-remediated surfaced
    }
}

Describe "CTK-05: graceful degradation" {
    It "Handles no previous, no dates, zero velocity without error" {
        $cur = New-TkSnapshot -Approved 0 -Revoked 0 -Pending 10 -RevTotal 2 -RevSigned 0
        $r = Build-SPCertTrackerData -Campaigns @(@{ Current = $cur; Previous = $null })
        $r.Success | Should -Be $true
        $d = $r.Data.Campaigns[0]
        $d.HasPrevious | Should -Be $false
        $d.Momentum | Should -Be 'NoData'
        $d.ProjectedVsDeadline | Should -BeIn @('Stalled','NoDeadline','NoData')
    }
}
