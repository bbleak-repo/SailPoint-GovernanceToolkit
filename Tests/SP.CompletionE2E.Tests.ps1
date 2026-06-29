#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    WI-11 -- End-to-end completion-tracking proof (cache-honesty).

.DESCRIPTION
    The demonstration that completion tracking "actually works" in BOTH the ACTIVE and
    COMPLETED states. Drives the REAL daily-evidence cache + roster + provenance engine
    end-to-end against the WI-0 cache-honesty fixtures and asserts that the RENDERED
    who-completed / who-did-not output matches the WI-0 expected-truth tables:

      * undecided items attribute to the cert-ASSIGNED reviewer (item.CertificationId ->
        sealed roster), never to item.reviewedBy (null for pending items),
      * NO (Unassigned) collapse,
      * verified-vs-unverified provenance is honored (the WI-4 banner appears iff the
        completion was NOT captured while ACTIVE).

    The ONLY external dependency is the single HTTP seam Get-SPAuditCertificationItems,
    mocked in SP.AuditQueries module scope (exactly as Tests/SP.CacheProvenance.Tests.ps1
    does) -- so the whole proof is fully headless; no live mock server is required. The
    fixture access-review items are served by the mock body from the file-scope
    $script:E2EItemsByCert map: a Pester `Mock -ModuleName ...` body is a CLOSURE over the
    scope where Mock was defined (this test file), so it reads the test's $script: var
    directly (a module-scope injection via & (Get-Module){ $script:x=... } would NOT be
    visible to the mock body -- verified empirically).

    Every expected count / reviewer is read from expected-truth.json so the proof stays
    in lockstep with WI-0 (no hard-coded numbers).

    Scenarios (each routed through the real cache+roster+provenance engine):
      E2E-1 ACTIVE          (camp-ch-active-001)     : seal while ACTIVE -> CapturedWhileActive
                                                        true -> banner ABSENT (verified).
      E2E-2 COMPLETED       (camp-ch-completed-001)  : first-seen while COMPLETED -> roster
                                                        CapturedWhileActive false -> banner
                                                        PRESENT (unverified honored).
      E2E-3 TRANSITION      (camp-ch-transition-001) : seal ACTIVE -> clear mem -> re-read
                                                        COMPLETED (disk seal-on-transition) ->
                                                        provenance stays verified, banner ABSENT.
      E2E-4 REASSIGNMENT    (camp-ch-reassign-001)   : undecided items attribute to cert.reviewer
                                                        (Iris), reassigned-from (Hank) excluded.
      E2E-5 LIVE cross-check                          : Skipped-by-default unless the live mock
                                                        seed-data.json is present (human-run path).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    $script:ChDir    = Join-Path (Join-Path $PSScriptRoot 'TestData') 'CacheHonesty'
    $script:Fixtures = Get-Content (Join-Path $ChDir 'mock-fixtures.json') -Raw | ConvertFrom-Json
    $script:Truth    = Get-Content (Join-Path $ChDir 'expected-truth.json') -Raw | ConvertFrom-Json
    $script:SeedPath = 'C:/temp/Coding/API-MockServer/Profiles/SailPoint-ISC/seed-data.json'

    # --- Fixture helpers (mirrored from SP.ReviewerCompletionAttribution / SP.MockFixtures) ---
    function Get-FxItems {
        param($CertId)
        $prop = $Fixtures.accessReviewItems.PSObject.Properties[$CertId]
        if ($null -eq $prop) { return @() }
        return @($prop.Value)
    }

    # Truth campaign entries carry either 'reviewers' (normal) or 'expectedActive' (transition).
    function Get-TruthReviewers {
        param($campEntry)
        if ($campEntry.PSObject.Properties['reviewers'])      { return @($campEntry.reviewers) }
        if ($campEntry.PSObject.Properties['expectedActive']) { return @($campEntry.expectedActive) }
        return @()
    }

    function Get-E2ECerts {
        param($CampaignId)
        @($Fixtures.certifications | Where-Object { $_.campaign.id -eq $CampaignId })
    }

    function New-E2ECampaign {
        param([string]$CampaignId, [string]$Status)
        $c = $Fixtures.campaigns | Where-Object { $_.id -eq $CampaignId }
        [PSCustomObject]@{ id = $c.id; name = $c.name; status = $Status }
    }

    # --- Per-cert fixture item map for the mocked HTTP seam --------------------------------
    # A Pester `Mock -ModuleName ...` body is a closure over the scope where Mock was DEFINED
    # (this test file), NOT the module's SessionState -- so a module-scope injection via
    # & (Get-Module){ $script:x = ... } is NOT visible to the mock, but this file-scope
    # $script: var IS. The mock body reads $script:E2EItemsByCert[$CertificationId] to serve
    # the fixture's access-review items for the requested cert -- fully headless, no server.
    $script:E2EItemsByCert = @{}
    foreach ($cert in $Fixtures.certifications) {
        $script:E2EItemsByCert[$cert.id] = @(Get-FxItems $cert.id)
    }

    # --- The COMPLETED-path attribution engine wiring (mirrors V4 :1956-1963) --------------
    function Get-E2EPendingByReviewer {
        param($ItemsData, $RosterData)
        $dec = Group-SPAuditDecisions -Items @($ItemsData)
        # Build the reassigned-away ID exclusion set from the sealed/live roster (V4 :1945-1951).
        $reassignedAwayIds = @{}
        foreach ($re in $RosterData) {
            if ($null -eq $re) { continue }
            $rfId = ''
            if ($null -ne $re.PSObject.Properties['ReassignedFromId']) { $rfId = [string]$re.ReassignedFromId }
            if (-not [string]::IsNullOrWhiteSpace($rfId)) { $reassignedAwayIds[$rfId] = $true }
        }
        return Group-SPCompletedPendingByReviewer `
            -PendingItems @($dec.Pending) `
            -DecidedItems (@($dec.Approved) + @($dec.Revoked)) `
            -Roster @($RosterData) `
            -PrimaryReviewers @() `
            -ReassignedAwayNames @{} `
            -KeyByReviewerId `
            -ReassignedAwayIds $reassignedAwayIds
    }

    # ConvertTo-SafeHtml is module-internal to SP.AuditReportHtml (not exported), so invoke it
    # inside the module scope -- the same real encoder V4 uses, so the rendered proof matches.
    function Get-E2ESafeHtml {
        param($Text)
        & (Get-Module SP.AuditReportHtml) { param($t) ConvertTo-SafeHtml $t } $Text
    }

    # --- Render the V4 COMPLETED accountability fragment (markup copied from V4 :1967-1982) --
    # Reproduces the rendered "Undecided Items by Reviewer" fragment + the WI-4 provenance
    # banner so the proof asserts against rendered HTML, not just the OrderedDictionary.
    function Format-E2EAccountability {
        param($PendingByReviewer, [bool]$CapturedWhileActive, [string]$CampaignName)
        $pendingR = @($PendingByReviewer.Values | Sort-Object { $_.Name })
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<div class="subhead">' + (Get-E2ESafeHtml $CampaignName) + '</div>')
        if (-not $CapturedWhileActive) {
            [void]$sb.AppendLine('<div class="s-red" style="border:1px solid #c0392b;background:#fdecea;padding:6px 8px;margin:4px 0;font-size:12px;font-weight:600">&#9888; No active-state capture -- completion unverified. ISC post-completion data is being trusted without a sealed ACTIVE-state snapshot.</div>')
        }
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:12px;margin-bottom:4px'>Reviewers who did not complete ($($pendingR.Count))</summary>")
        [void]$sb.AppendLine("<div style='font-size:11px;color:#777;margin-bottom:4px'>Includes reviewers with undecided items AND reviewers who decided everything but never signed off (force-closed).</div>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th style="text-align:right">Undecided Items</th><th style="text-align:right">Total Items</th><th>Note</th></tr></thead><tbody>')
        if ($pendingR.Count -eq 0) {
            [void]$sb.AppendLine('<tr><td colspan="5" style="color:#777;font-style:italic">No undecided items found (all items were decided before close).</td></tr>')
        }
        else {
            foreach ($rr in $pendingR) {
                $pCnt = $rr.PendingCount; $tCnt = $rr.TotalCount
                # COMP-REVIEWER-COMPLETENESS: CompletionReason-driven note (mirrors V4/V4b render).
                if ($pCnt -eq 0) { $phCls = 's-amber'; $note = 'all decided - not signed off (auto-closed)' }
                elseif ($pCnt -eq $tCnt) { $phCls = 's-red'; $note = 'No decisions made' }
                else { $phCls = 's-amber'; $note = "$($tCnt - $pCnt) of $tCnt decided" }
                [void]$sb.AppendLine("<tr><td style='font-weight:600'>" + (Get-E2ESafeHtml $rr.Name) + "</td><td>" + (Get-E2ESafeHtml $rr.Email) + "</td><td style='text-align:right;font-weight:600' class='$phCls'>$pCnt</td><td style='text-align:right'>$tCnt</td><td>$note</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></details>')
        return $sb.ToString()
    }

    # Fetch the value row (the engine keys by 'id:<reviewerId>' when -KeyByReviewerId is on,
    # so look the row up by its display Name -- the user-visible attribution).
    function Get-E2ERow {
        param($PendingByReviewer, [string]$Name)
        @($PendingByReviewer.Values | Where-Object { [string]$_.Name -eq $Name })
    }
}

Describe "E2E -- completion-tracking proof (ACTIVE + COMPLETED + transition)" {

    BeforeAll {
        # Single HTTP seam, mocked in module scope (mirrors SP.CacheProvenance). The body
        # returns the injected fixture items for the requested cert -- no live server.
        Mock Write-SPLog -ModuleName SP.AuditQueries { }
        Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
            return @{
                Success = $true
                Data    = @($script:E2EItemsByCert[$CertificationId])
                Error   = $null
            }
        }
    }

    It "E2E-1 ACTIVE (camp-ch-active-001): seal-while-ACTIVE attributes undecided items to the assigned reviewers, banner ABSENT (verified)" {
        $cache = Join-Path (Join-Path $TestDrive 'e2e') 'active'
        Clear-SPAuditItemCache -CampaignId 'camp-ch-active-001' -MemoryOnly
        $certs = Get-E2ECerts 'camp-ch-active-001'
        $camp  = New-E2ECampaign 'camp-ch-active-001' 'ACTIVE'

        # Seal items + roster while ACTIVE through the REAL cache engine (one mocked seam).
        $items = Get-SPCachedCampaignItems -Campaign $camp -CachePath $cache -Certifications $certs -TtlMinutes 180
        $items.Success | Should -BeTrue -Because "items must seal through the cache engine"

        $roster = Get-SPCachedCampaignRoster -Campaign $camp -CachePath $cache -Certifications $certs
        $roster.Success             | Should -BeTrue
        $roster.Sealed              | Should -BeTrue  -Because "the ACTIVE seal must be read back from disk"
        $roster.CapturedWhileActive | Should -BeTrue  -Because "captured while ACTIVE => verified provenance"

        $pbr  = Get-E2EPendingByReviewer -ItemsData $items.Data -RosterData $roster.Data
        $html = Format-E2EAccountability -PendingByReviewer $pbr -CapturedWhileActive $roster.CapturedWhileActive -CampaignName $camp.name

        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-active-001' }
        $expectedIncomplete = 0
        foreach ($r in (Get-TruthReviewers $truthCamp)) {
            if ($r.reassignedAway) { continue }
            $expectedPending = [int]$r.undecidedCount + [int]$r.autoApprovedCount
            if ($expectedPending -gt 0) {
                $expectedIncomplete++
                $html | Should -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) has undecided work and MUST be rendered as incomplete"
                $row = @(Get-E2ERow $pbr $r.reviewerName)
                @($row).Count                | Should -Be 1 -Because "exactly one attributed row for $($r.reviewerName)"
                $row[0].PendingCount         | Should -Be $expectedPending -Because "PendingCount for $($r.reviewerName)"
            }
            else {
                $html | Should -Not -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) is complete and must be ABSENT"
            }
        }

        # Rendered proof: no collapse, provenance verified (no banner).
        $html | Should -Not -Match '\(Unassigned\)'      -Because "every undecided item maps to a real assigned reviewer"
        $html | Should -Not -Match 'No active-state capture' -Because "ACTIVE seal => verified => no unverified banner"
        @($pbr.Values | Where-Object { [string]$_.Name -eq '(Unassigned)' }).Count | Should -Be 0
        @($pbr.Keys).Count | Should -Be $expectedIncomplete -Because "one row per incomplete assigned reviewer (Alan + Carl), not a single collapsed row"
        $expectedIncomplete | Should -BeGreaterOrEqual 2
    }

    It "E2E-2 COMPLETED first-seen (camp-ch-completed-001): no (Unassigned) collapse, banner PRESENT (unverified honored), totals consistent" {
        $cache = Join-Path (Join-Path $TestDrive 'e2e') 'completed'
        Clear-SPAuditItemCache -CampaignId 'camp-ch-completed-001' -MemoryOnly
        $certs = Get-E2ECerts 'camp-ch-completed-001'
        $camp  = New-E2ECampaign 'camp-ch-completed-001' 'COMPLETED'

        # First-seen WHILE COMPLETED (never observed ACTIVE) -> roster sealed but UNVERIFIED.
        $items = Get-SPCachedCampaignItems -Campaign $camp -CachePath $cache -Certifications $certs -TtlMinutes 180
        $items.Success | Should -BeTrue

        $roster = Get-SPCachedCampaignRoster -Campaign $camp -CachePath $cache -Certifications $certs
        $roster.Sealed              | Should -BeTrue
        $roster.CapturedWhileActive | Should -BeFalse -Because "first-seen-COMPLETED has no honest ACTIVE snapshot => unverified"

        $pbr  = Get-E2EPendingByReviewer -ItemsData $items.Data -RosterData $roster.Data
        $html = Format-E2EAccountability -PendingByReviewer $pbr -CapturedWhileActive $roster.CapturedWhileActive -CampaignName $camp.name

        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-completed-001' }
        $expectedIncomplete = 0
        foreach ($r in (Get-TruthReviewers $truthCamp)) {
            if ($r.reassignedAway) { continue }
            $expectedPending = [int]$r.undecidedCount + [int]$r.autoApprovedCount
            if ($expectedPending -gt 0) {
                $expectedIncomplete++
                $html | Should -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) has undecided/auto-approved work"
                $row = @(Get-E2ERow $pbr $r.reviewerName)
                @($row).Count        | Should -Be 1
                $row[0].PendingCount | Should -Be $expectedPending -Because "PendingCount for $($r.reviewerName) (Evan counts 3 idNowAutoApproved as pending)"
                # TotalCount internally consistent: decided + undecided + auto.
                $expectedTotal = [int]$r.decidedCount + [int]$r.undecidedCount + [int]$r.autoApprovedCount
                $row[0].TotalCount   | Should -Be $expectedTotal -Because "TotalCount for $($r.reviewerName)"
            }
            else {
                $html | Should -Not -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) is complete and must be ABSENT"
            }
        }

        # Exactly N rows proves the (Unassigned) collapse is gone (old code => 1 row).
        @($pbr.Keys).Count  | Should -Be $expectedIncomplete -Because "Dana + Evan, not one collapsed (Unassigned) row"
        $expectedIncomplete | Should -BeGreaterOrEqual 2
        $html | Should -Not -Match '\(Unassigned\)'
        $html | Should -Match 'No active-state capture' -Because "unverified provenance MUST surface the warning banner"
    }

    It "E2E-3 TRANSITION (camp-ch-transition-001): seal ACTIVE -> flip COMPLETED keeps verified provenance and identical attribution" {
        $cache = Join-Path (Join-Path $TestDrive 'e2e') 'transition'
        Clear-SPAuditItemCache -CampaignId 'camp-ch-transition-001' -MemoryOnly
        $certs   = Get-E2ECerts 'camp-ch-transition-001'
        $campAct = New-E2ECampaign 'camp-ch-transition-001' 'ACTIVE'
        $campCmp = New-E2ECampaign 'camp-ch-transition-001' 'COMPLETED'

        # 1) Seal while ACTIVE (writes the honest roster + items to disk).
        $null = Get-SPCachedCampaignItems -Campaign $campAct -CachePath $cache -Certifications $certs -TtlMinutes 180
        # 2) Drop ONLY the in-memory layer so the disk seal-on-transition path runs (the
        #    Layer-1 mem cache would otherwise early-return and bypass the seal). MANDATORY.
        Clear-SPAuditItemCache -CampaignId 'camp-ch-transition-001' -MemoryOnly
        # 3) Re-read the SAME campaign now COMPLETED -> disk HIT triggers seal-on-transition.
        $items = Get-SPCachedCampaignItems -Campaign $campCmp -CachePath $cache -Certifications $certs -TtlMinutes 180
        $items.Success   | Should -BeTrue
        $items.FromCache | Should -BeTrue -Because "the COMPLETED re-read must hit the sealed ACTIVE disk cache"

        # Roster file was written only on the ACTIVE miss (NOT rewritten on the transition HIT),
        # so provenance stays VERIFIED across the flip.
        $roster = Get-SPCachedCampaignRoster -Campaign $campCmp -CachePath $cache -Certifications $certs
        $roster.Sealed              | Should -BeTrue
        $roster.CapturedWhileActive | Should -BeTrue -Because "the seal predates the flip => still verified"

        $pbr  = Get-E2EPendingByReviewer -ItemsData $items.Data -RosterData $roster.Data
        $html = Format-E2EAccountability -PendingByReviewer $pbr -CapturedWhileActive $roster.CapturedWhileActive -CampaignName $campCmp.name

        # Use Get-TruthReviewers -> expectedActive (== expectedCompleted by design).
        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-transition-001' }
        $expectedIncomplete = 0
        foreach ($r in (Get-TruthReviewers $truthCamp)) {
            if ($r.reassignedAway) { continue }
            $expectedPending = [int]$r.undecidedCount + [int]$r.autoApprovedCount
            if ($expectedPending -gt 0) {
                $expectedIncomplete++
                $html | Should -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) (Greg) incomplete across the flip"
                $row = @(Get-E2ERow $pbr $r.reviewerName)
                @($row).Count        | Should -Be 1
                $row[0].PendingCount | Should -Be $expectedPending
            }
            else {
                $html | Should -Not -Match ([regex]::Escape($r.reviewerName)) -Because "$($r.reviewerName) (Helen) complete => absent"
            }
        }

        @($pbr.Keys).Count | Should -Be $expectedIncomplete
        $html | Should -Not -Match '\(Unassigned\)'
        $html | Should -Not -Match 'No active-state capture' -Because "transition preserves the verified ACTIVE seal => no banner"
    }

    It "E2E-4 REASSIGNMENT (camp-ch-reassign-001): undecided items attribute to cert.reviewer (Iris); reassigned-from (Hank) excluded" {
        $cache = Join-Path (Join-Path $TestDrive 'e2e') 'reassign'
        Clear-SPAuditItemCache -CampaignId 'camp-ch-reassign-001' -MemoryOnly
        $certs = Get-E2ECerts 'camp-ch-reassign-001'
        $camp  = New-E2ECampaign 'camp-ch-reassign-001' 'ACTIVE'

        $items  = Get-SPCachedCampaignItems -Campaign $camp -CachePath $cache -Certifications $certs -TtlMinutes 180
        $roster = Get-SPCachedCampaignRoster -Campaign $camp -CachePath $cache -Certifications $certs
        $roster.Sealed | Should -BeTrue
        $pbr  = Get-E2EPendingByReviewer -ItemsData $items.Data -RosterData $roster.Data
        $html = Format-E2EAccountability -PendingByReviewer $pbr -CapturedWhileActive $roster.CapturedWhileActive -CampaignName $camp.name

        $truthCamp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-reassign-001' }
        $iris = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-010' }
        $hank = Get-TruthReviewers $truthCamp | Where-Object { $_.reviewerId -eq 'id-ch-rv-009' }
        $expectedPending = [int]$iris.undecidedCount + [int]$iris.autoApprovedCount

        $irisRow = @(Get-E2ERow $pbr $iris.reviewerName)
        @($irisRow).Count        | Should -Be 1 -Because "the active (reassigned-TO) reviewer owns the undecided items"
        $irisRow[0].PendingCount | Should -Be $expectedPending
        $html | Should -Match ([regex]::Escape($iris.reviewerName))

        @(Get-E2ERow $pbr $hank.reviewerName).Count | Should -Be 0 -Because "the reassigned-FROM reviewer holds no items"
        $html | Should -Not -Match ([regex]::Escape($hank.reviewerName))
        $html | Should -Not -Match '\(Unassigned\)'
    }

    It "E2E-5 LIVE cross-check: end-to-end against the live mock seed-data.json (Skipped when absent)" {
        if (-not (Test-Path $SeedPath)) {
            Set-ItResult -Skipped -Because "mock seed-data.json not present at $SeedPath (human-run live path)"
            return
        }
        $seed    = Get-Content $SeedPath -Raw | ConvertFrom-Json
        $seedIds = @($seed.campaigns | ForEach-Object { $_.id })
        foreach ($id in @('camp-ch-active-001', 'camp-ch-completed-001', 'camp-ch-transition-001', 'camp-ch-reassign-001')) {
            $seedIds | Should -Contain $id
        }
    }
}
