<#
.SYNOPSIS
    WI-0 -- Cache-honesty mock fixtures: parser + expected-truth consistency tests.

    Self-contained (no module import). Parses the two committed TestData JSON files
    (mock-fixtures.json + expected-truth.json) and asserts the truth table is
    internally consistent with the fixture payload using the SAME classifier rules
    as Group-SPAuditDecisions (SP.AuditReportCore.psm1). Optionally cross-checks the
    live mock seed-data.json if present.

    Assertions:
      MF-01 (a) fixtures parse; all 4 camp-ch-* campaigns present with expected status.
      MF-02 (b) each truth reviewer: cert exists; cert.reviewer.id/name match.
      MF-03 (c) recomputed decided/undecided/autoApproved == truth counts.
      MF-04 (d) shouldShowComplete == (undecided==0 AND autoApproved==0).
      MF-05 (e) faithfulness: decided items have reviewedBy.name; undecided/auto have none.
      MF-06 (f) completed certs are SIGNED w/ inflated decisionsMade AND still have undecided work.
      MF-07 (g) >=2 distinct incomplete reviewers in camp-ch-completed-001 (merge-risk demo).
      MF-08 (h) each campaign's certs have DISTINCT reviewer ids.
      MF-09 (i) reassign: from.id==Hank; Hank reassignedAway & excluded; Iris incomplete.
      MF-10 (j) transition: expectedActive deep-equals expectedCompleted.
      MF-11 (k) optional cross-check against live mock seed-data.json.
#>
#Requires -Modules Pester

BeforeAll {
    $script:ChDir    = Join-Path (Join-Path $PSScriptRoot 'TestData') 'CacheHonesty'
    $script:Fixtures = Get-Content (Join-Path $ChDir 'mock-fixtures.json') -Raw | ConvertFrom-Json
    $script:Truth    = Get-Content (Join-Path $ChDir 'expected-truth.json') -Raw | ConvertFrom-Json
    $script:SeedPath = 'C:/temp/Coding/API-MockServer/Profiles/SailPoint-ISC/seed-data.json'

    $script:CertById = @{}
    foreach ($c in $Fixtures.certifications) { $script:CertById[$c.id] = $c }

    function Get-FxItems {
        param($CertId)
        $prop = $Fixtures.accessReviewItems.PSObject.Properties[$CertId]
        if ($null -eq $prop) { return @() }
        return @($prop.Value)
    }

    # Mirror of the Group-SPAuditDecisions classifier (SP.AuditReportCore.psm1 ~line 404).
    function Get-FxItemCategory {
        param($item)
        $dec = ''
        if ($item.PSObject.Properties['decision']) { $dec = [string]$item.decision }
        if ([string]::IsNullOrWhiteSpace($dec)) { return 'undecided' }
        $comment = ''
        if ($item.PSObject.Properties['comment']) { $comment = [string]$item.comment }
        $u = $dec.ToUpperInvariant()
        if ($u -in @('APPROVE', 'APPROVED', 'CERTIFY')) {
            if ($comment.Contains('idNowAutoApproved')) { return 'autoApproved' }
            return 'decided'
        }
        if ($u -in @('REVOKE', 'REVOKED', 'DENY', 'REJECT', 'EXCEPTION')) { return 'decided' }
        return 'undecided'
    }

    function Measure-FxCert {
        param($CertId)
        $d = 0; $u = 0; $a = 0
        foreach ($it in (Get-FxItems $CertId)) {
            switch (Get-FxItemCategory $it) {
                'decided'      { $d++ }
                'autoApproved' { $a++ }
                default        { $u++ }
            }
        }
        [pscustomobject]@{ Decided = $d; Undecided = $u; Auto = $a }
    }

    # Truth campaign entries carry either 'reviewers' (normal) or 'expectedActive' (transition).
    function Get-TruthReviewers {
        param($campEntry)
        if ($campEntry.PSObject.Properties['reviewers'])      { return @($campEntry.reviewers) }
        if ($campEntry.PSObject.Properties['expectedActive']) { return @($campEntry.expectedActive) }
        return @()
    }
}

Describe "MF -- Cache-honesty mock fixtures" {

    It "MF-01 (a) fixtures parse and all 4 camp-ch-* campaigns are present with the expected status" {
        @($Fixtures.campaigns | Where-Object { $_.id -like 'camp-ch-*' }).Count | Should -Be 4
        $ids = @($Fixtures.campaigns | ForEach-Object { $_.id })
        foreach ($tc in $Truth.campaigns) {
            $ids | Should -Contain $tc.campaignId
            $camp = $Fixtures.campaigns | Where-Object { $_.id -eq $tc.campaignId }
            $camp | Should -Not -BeNullOrEmpty
            $camp.status | Should -Be $tc.status
        }
    }

    It "MF-02 (b) every truth reviewer maps to a cert whose assigned reviewer id and name match" {
        foreach ($tc in $Truth.campaigns) {
            foreach ($r in (Get-TruthReviewers $tc)) {
                if ($r.reassignedAway) { continue }   # FROM reviewer is not the cert.reviewer
                $cert = $CertById[$r.certId]
                $cert | Should -Not -BeNullOrEmpty -Because "cert $($r.certId) must exist in fixtures"
                $cert.reviewer.id   | Should -Be $r.reviewerId   -Because "cert $($r.certId) reviewer id"
                $cert.reviewer.name | Should -Be $r.reviewerName -Because "cert $($r.certId) reviewer name"
            }
        }
    }

    It "MF-03 (c) recomputed decided/undecided/autoApproved counts equal the truth counts" {
        foreach ($tc in $Truth.campaigns) {
            foreach ($r in (Get-TruthReviewers $tc)) {
                if ($r.reassignedAway) { continue }
                $m = Measure-FxCert $r.certId
                $m.Decided   | Should -Be $r.decidedCount      -Because "decided for $($r.certId)"
                $m.Undecided | Should -Be $r.undecidedCount    -Because "undecided for $($r.certId)"
                $m.Auto      | Should -Be $r.autoApprovedCount -Because "autoApproved for $($r.certId)"
            }
        }
    }

    It "MF-04 (d) shouldShowComplete equals (undecidedCount==0 AND autoApprovedCount==0)" {
        foreach ($tc in $Truth.campaigns) {
            foreach ($r in (Get-TruthReviewers $tc)) {
                if ($r.reassignedAway) { continue }
                $expected = (($r.undecidedCount -eq 0) -and ($r.autoApprovedCount -eq 0))
                [bool]$r.shouldShowComplete | Should -Be $expected -Because "complete flag for $($r.certId)"
                [bool]$r.shouldAppearInIncompleteList | Should -Be (-not $expected) -Because "incomplete-list flag for $($r.certId)"
            }
        }
    }

    It "MF-05 (e) faithfulness: decided items carry reviewedBy.name; undecided/auto items carry none" {
        foreach ($cert in $Fixtures.certifications) {
            foreach ($it in (Get-FxItems $cert.id)) {
                $cat = Get-FxItemCategory $it
                $hasReviewedBy = ($it.PSObject.Properties['reviewedBy'] -and $null -ne $it.reviewedBy)
                switch ($cat) {
                    'decided' {
                        $hasReviewedBy | Should -BeTrue -Because "decided item $($it.id) must have reviewedBy"
                        [string]$it.reviewedBy.name | Should -Not -BeNullOrEmpty -Because "decided item $($it.id) reviewedBy.name"
                    }
                    'autoApproved' {
                        $hasReviewedBy | Should -BeFalse -Because "auto-approved item $($it.id) must NOT have reviewedBy"
                        [string]$it.comment | Should -Match 'idNowAutoApproved'
                    }
                    default {
                        # undecided
                        $hasReviewedBy | Should -BeFalse -Because "undecided item $($it.id) must NOT have reviewedBy"
                        $hasDecision = ($it.PSObject.Properties['decision'] -and -not [string]::IsNullOrWhiteSpace([string]$it.decision))
                        $hasDecision | Should -BeFalse -Because "undecided item $($it.id) must NOT have an APPROVE/REVOKE decision"
                    }
                }
            }
        }
    }

    It "MF-06 (f) completed campaign certs are SIGNED with inflated decisionsMade yet still hold undecided work" {
        $completed = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-completed-001' }
        $completed | Should -Not -BeNullOrEmpty
        $anyUndecided = $false
        foreach ($r in (Get-TruthReviewers $completed)) {
            if ($r.reassignedAway) { continue }
            $cert = $CertById[$r.certId]
            $cert.phase | Should -Be 'SIGNED' -Because "force-signed cert $($r.certId)"
            $cert.decisionsMade | Should -Be $cert.decisionsTotal -Because "inflated decisionsMade lie on $($r.certId)"
            if ($r.undecidedCount -gt 0) { $anyUndecided = $true }
        }
        $anyUndecided | Should -BeTrue -Because "the force-sign lie: at least one reviewer still has genuinely undecided items"
    }

    It "MF-07 (g) camp-ch-completed-001 has >=2 distinct INCOMPLETE reviewers (the (Unassigned)-merge demonstrator)" {
        $completed = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-completed-001' }
        $incomplete = @(Get-TruthReviewers $completed | Where-Object { -not $_.reassignedAway -and -not $_.shouldShowComplete })
        $distinct = @($incomplete | ForEach-Object { $_.reviewerId } | Sort-Object -Unique)
        $distinct.Count | Should -BeGreaterOrEqual 2
    }

    It "MF-08 (h) each campaign's certs have DISTINCT reviewer ids" {
        foreach ($camp in @($Fixtures.campaigns | Where-Object { $_.id -like 'camp-ch-*' })) {
            $certs = @($Fixtures.certifications | Where-Object { $_.campaign.id -eq $camp.id })
            $ids = @($certs | ForEach-Object { $_.reviewer.id })
            $unique = @($ids | Sort-Object -Unique)
            $unique.Count | Should -Be $ids.Count -Because "campaign $($camp.id) must have distinct cert reviewers"
        }
    }

    It "MF-09 (i) reassignment: from.id is Hank; Hank is excluded; Iris (cert.reviewer) is incomplete" {
        $cert = $CertById['cert-ch-reassign-001']
        $cert | Should -Not -BeNullOrEmpty
        $cert.reassignment | Should -Not -BeNullOrEmpty
        $cert.reassignment.from.id | Should -Be 'id-ch-rv-009'
        $cert.reviewer.id          | Should -Be 'id-ch-rv-010'

        $camp = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-reassign-001' }
        $hank = Get-TruthReviewers $camp | Where-Object { $_.reviewerId -eq 'id-ch-rv-009' }
        $hank | Should -Not -BeNullOrEmpty
        [bool]$hank.reassignedAway               | Should -BeTrue
        [bool]$hank.shouldAppearInIncompleteList | Should -BeFalse

        $iris = Get-TruthReviewers $camp | Where-Object { $_.reviewerId -eq 'id-ch-rv-010' }
        $iris | Should -Not -BeNullOrEmpty
        [bool]$iris.shouldShowComplete | Should -BeFalse
    }

    It "MF-10 (j) transition: expectedActive deep-equals expectedCompleted" {
        $tr = $Truth.campaigns | Where-Object { $_.campaignId -eq 'camp-ch-transition-001' }
        $tr | Should -Not -BeNullOrEmpty
        $tr.PSObject.Properties['expectedActive']    | Should -Not -BeNullOrEmpty
        $tr.PSObject.Properties['expectedCompleted'] | Should -Not -BeNullOrEmpty
        $a = ($tr.expectedActive    | ConvertTo-Json -Depth 20)
        $b = ($tr.expectedCompleted | ConvertTo-Json -Depth 20)
        $a | Should -Be $b
    }

    It "MF-11 (k) cross-check: live mock seed-data.json (if present) serves all 4 camp-ch-* campaigns" {
        if (-not (Test-Path $SeedPath)) {
            Set-ItResult -Skipped -Because "mock seed-data.json not present at $SeedPath"
            return
        }
        $seed = Get-Content $SeedPath -Raw | ConvertFrom-Json
        $seedIds = @($seed.campaigns | ForEach-Object { $_.id })
        foreach ($id in @('camp-ch-active-001', 'camp-ch-completed-001', 'camp-ch-transition-001', 'camp-ch-reassign-001')) {
            $seedIds | Should -Contain $id
        }
    }
}
