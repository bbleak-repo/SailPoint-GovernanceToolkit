#Requires -Version 5.1
<#
    SP.BaselineGovernanceCorrectness.Tests.ps1  (BGC-B03 .. BGC-B10)

    T-02: GOVERNANCE CONTENT-CORRECTNESS for the membership baseline reports.

    Goes beyond the render-only Tests/SP.AdaptiveBaselineReports.Tests.ps1 (which
    only asserts well-formed HTML over adapter output) by feeding a KNOWN, HAND-BUILT
    GroupResults fixture whose governance truth is explicit, then asserting that each
    report's computed governance SIGNAL (the flagged identities and the KPI/badge
    numbers) matches that seeded truth -- ONLY the privileged group/members are
    flagged, EXACTLY the seeded SoD conflict appears (no false positive, no false
    negative), the disabled-account distinct KPI dedups an account in multiple groups,
    and the executive-summary aggregates equal the input.

    The fixture is built BY HAND (no Build-SPRCDataset) so the seeded truth is
    explicit and independent of the adapter. Additive only: this file does not modify
    or weaken the existing render-only suite.

    SEEDED FIXTURE (5 groups, 5 distinct identities):
      1. 'Domain Admins'          (priv)     -- alice (enabled) + bob (DISABLED)
      2. 'Administrators'         (priv)     -- bob (same disabled identity; 2nd priv group)
      3. 'Marketing Distribution' (non-priv) -- carol (enabled)
      4. 'AP Payments'            (B04 Finance-Payments)  -- dave + erin
      5. 'AP Payment Approval'    (B04 Finance-Approvals) -- dave
    dave holds BOTH SoD sides (the one true conflict; SOD-001 Critical).
    erin holds only the Finance-Payments side (single-side -> must NOT violate).
    bob is the disabled identity in TWO privileged groups (distinct-dedup + B10 SoD).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.AdaptiveReports\SP.AdaptiveReports.psd1') -Force -DisableNameChecking -ErrorAction Stop

    # ---- fixture builders: the documented GroupResults shape, by hand ----
    function script:M {
        param([string]$Sam, [string]$Disp, [string]$Email, [bool]$Enabled)
        [pscustomobject]@{ SamAccountName = $Sam; DisplayName = $Disp; Email = $Email; Enabled = $Enabled }
    }
    function script:GR {
        param([string]$Domain, [string]$GroupName, [object[]]$Members)
        [pscustomobject]@{
            Data = [pscustomobject]@{
                Domain      = $Domain
                GroupName   = $GroupName
                MemberCount = @($Members).Count
                IsNested    = $false
                Skipped     = $false
                Members     = $Members
            }
            Errors = @()
        }
    }

    $alice = script:M 'alice' 'Alice Admin'   'alice@example.com' $true
    $bob   = script:M 'bob'   'Bob Disabled'  'bob@example.com'   $false
    $carol = script:M 'carol' 'Carol Reader'  'carol@example.com' $true
    $dave  = script:M 'dave'  'Dave Both'     'dave@example.com'  $true
    $erin  = script:M 'erin'  'Erin OneSide'  'erin@example.com'  $true

    $script:Gr = @(
        script:GR 'corp' 'Domain Admins'          @($alice, $bob)
        script:GR 'corp' 'Administrators'         @($bob)
        script:GR 'corp' 'Marketing Distribution' @($carol)
        script:GR 'corp' 'AP Payments'            @($dave, $erin)
        script:GR 'corp' 'AP Payment Approval'    @($dave)
    )

    function script:Render-Report {
        param([string]$Fn, $GroupResults)
        $out = Join-Path $TestDrive ("{0}-{1}.html" -f $Fn, ([guid]::NewGuid().ToString('N')))
        & $Fn -GroupResults $GroupResults -OutputPath $out -Theme light | Out-Null
        return (Get-Content -Raw -Path $out)
    }
}

Describe 'SP.AdaptiveReports — baseline governance correctness (synthetic truth)' {

    It 'BGC-B03: privileged review flags ONLY the privileged groups/members and counts disabled-with-privilege correctly' {
        $html = script:Render-Report -Fn 'Export-PrivilegedGroupReviewReport' -GroupResults $script:Gr

        # Badge: privileged groups -- BOTH 'Domain Admins' and 'Administrators' match the heuristic -> 2.
        $mPriv = [regex]::Match($html, '<div class="badge[^"]*"><b>(\d+)</b>privileged groups</div>')
        $mPriv.Success | Should -BeTrue -Because 'the privileged-groups badge must be present'
        [int]$mPriv.Groups[1].Value | Should -Be 2

        # Badge: privileged members -- alice+bob (Domain Admins) + bob (Administrators) = 3 rows.
        $mMem = [regex]::Match($html, '<div class="badge[^"]*"><b>(\d+)</b>privileged members</div>')
        $mMem.Success | Should -BeTrue
        [int]$mMem.Groups[1].Value | Should -Be 3

        # Badge: disabled w/ privilege -- bob is disabled in BOTH priv groups = 2 disabled-priv rows.
        $mDis = [regex]::Match($html, '<div class="badge[^"]*"><b>(\d+)</b>disabled w/ privilege</div>')
        $mDis.Success | Should -BeTrue
        [int]$mDis.Groups[1].Value | Should -Be 2

        # Flagged identities/groups present.
        $html | Should -Match 'Bob Disabled'
        $html | Should -Match 'Domain Admins'
        $html | Should -Match 'Administrators'

        # Non-privileged group and its members are NOT flagged (no false positives).
        $html | Should -Not -Match 'Marketing Distribution'
        $html | Should -Not -Match 'Carol'
        $html | Should -Not -Match 'AP Payments'
    }

    It 'BGC-B04: SoD report flags EXACTLY the one seeded conflicting identity (no false pos/neg)' {
        $html = script:Render-Report -Fn 'Export-SodToxicComembershipReport' -GroupResults $script:Gr

        # Active Violations = 1 (only dave holds both Finance-Payments AND Finance-Approvals).
        $mViol = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Active Violations</div>')
        $mViol.Success | Should -BeTrue
        [int]$mViol.Groups[1].Value | Should -Be 1

        # Distinct Users = 1.
        $mUsers = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Distinct Users</div>')
        $mUsers.Success | Should -BeTrue
        [int]$mUsers.Groups[1].Value | Should -Be 1

        # The true conflicting identity is present...
        $html | Should -Match 'Dave Both'
        # ...and the single-side identity (erin, only AP Payments) is NOT a violation (no false positive).
        $html | Should -Not -Match 'Erin'
        # ...and a wholly unrelated non-priv member is absent.
        $html | Should -Not -Match 'Carol'
    }

    It 'BGC-B05: orphaned/disabled surfaces disabled accounts and dedups distinct count across groups' {
        $html = script:Render-Report -Fn 'Export-OrphanedDisabledMembersReport' -GroupResults $script:Gr

        # Distinct disabled accounts = 1 (bob, even though he sits in TWO groups) -- the round-10 dedup guard.
        $mDistinct = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Distinct disabled accounts</div>')
        $mDistinct.Success | Should -BeTrue
        [int]$mDistinct.Groups[1].Value | Should -Be 1

        # Disabled-member findings = 2 (one row per disabled-member->group pair; bob in 2 groups). By design.
        $mFind = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Disabled-member findings</div>')
        $mFind.Success | Should -BeTrue
        [int]$mFind.Groups[1].Value | Should -Be 2

        # In privileged groups = 2 (both of bob's disabled rows are in privileged groups).
        $mPriv = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">In privileged groups</div>')
        $mPriv.Success | Should -BeTrue
        [int]$mPriv.Groups[1].Value | Should -Be 2

        # The disabled identity is surfaced; enabled identities and non-priv members are absent.
        $html | Should -Match 'Bob Disabled'
        $html | Should -Not -Match 'Alice Admin'
        $html | Should -Not -Match 'Carol'
    }

    It 'BGC-B06: inventory catalog lists every seeded group exactly' {
        $html = script:Render-Report -Fn 'Export-GroupInventoryCatalogReport' -GroupResults $script:Gr

        $seededGroups = @('Domain Admins', 'Administrators', 'Marketing Distribution', 'AP Payments', 'AP Payment Approval')
        $present = @($seededGroups | Where-Object { $html -match [regex]::Escape($_) })
        $present.Count | Should -Be 5

        foreach ($g in $seededGroups) {
            $html | Should -Match ([regex]::Escape($g))
        }
    }

    It 'BGC-B10: executive summary KPIs + aggregate counts equal the seeded input' {
        $html = script:Render-Report -Fn 'Export-GovernanceExecutiveSummaryReport' -GroupResults $script:Gr

        # KPI: Distinct Members = 5 (alice, bob, carol, dave, erin).
        $mMembers = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Distinct Members</div>')
        $mMembers.Success | Should -BeTrue
        [int]$mMembers.Groups[1].Value | Should -Be 5

        # KPI: Groups in Scope = 5.
        $mGroups = [regex]::Match($html, '<div class="n">(\d+)</div><div class="l">Groups in Scope</div>')
        $mGroups.Success | Should -BeTrue
        [int]$mGroups.Groups[1].Value | Should -Be 5

        # Metric rows (Name -> tier -> value). Row counts by design (not distinct).
        $metricVal = {
            param([string]$Name)
            $m = [regex]::Match($html, ([regex]::Escape($Name) + '</td>\s*<td class="tier">[^<]*</td>\s*<td class="num">(\d+)</td>'))
            if (-not $m.Success) { return -1 }
            return [int]$m.Groups[1].Value
        }

        # Disabled members in groups = 2 (bob's row in each of his 2 groups -- ROW count by design).
        (& $metricVal 'Disabled members in groups') | Should -Be 2
        # SoD conflicts found = 1 (bob is a member of 2 distinct privileged groups).
        (& $metricVal 'SoD conflicts found') | Should -Be 1
        # Privileged-group members = 3 (alice+bob in Domain Admins, bob in Administrators = 3 rows).
        (& $metricVal 'Privileged-group members') | Should -Be 3
    }
}
