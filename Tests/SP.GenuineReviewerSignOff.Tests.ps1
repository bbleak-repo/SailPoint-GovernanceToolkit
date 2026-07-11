<#
.SYNOPSIS
    Tests for Get-SPGenuineReviewerSignOff -- the SET-based genuine sign-off computation
    (Phase=='SIGNED' minus force-sign evidence minus reviewers with undecided items).

    GSO-01: pending items veto a SIGNED phase (the production "100 of 100 signed" bug)
    GSO-02: force-sign evidence veto (signedBy != reviewer)
    GSO-03: a reviewer caught by BOTH signals is subtracted ONCE (set, not count, arithmetic)
    GSO-04: distinct-by-reviewer totals (per-cert reassigned entries collapse)
    GSO-05: qualifier caption carries the auto-closed count
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Audit

    function New-GSOReviewer {
        param([string]$Name, [string]$Id = '', [string]$Phase = 'SIGNED', [int]$DecisionsMade = 5)
        [pscustomobject]@{ Name = $Name; ReviewerId = $Id; Email = "$Name@x.com"; Phase = $Phase; DecisionsMade = $DecisionsMade }
    }
    function New-GSORosterEntry {
        param([string]$Name, [string]$Id, [string]$SignedById = '')
        [pscustomobject]@{ CertificationId = "cert-$Name"; ReviewerName = $Name; ReviewerId = $Id; ReviewerEmail = "$Name@x.com"; SignedById = $SignedById }
    }
}

Describe 'GSO-01: undecided items veto a SIGNED phase' {
    It 'excludes signed reviewers named in PendingReviewerNames (no signedBy provenance needed)' {
        # 4 reviewers, ISC force-close marked ALL of them SIGNED; 2 still had undecided items.
        $reviewers = @(
            (New-GSOReviewer -Name 'Alice' -Id 'r1'),
            (New-GSOReviewer -Name 'Bob' -Id 'r2'),
            (New-GSOReviewer -Name 'Carol' -Id 'r3'),
            (New-GSOReviewer -Name 'Dave' -Id 'r4')
        )
        $r = Get-SPGenuineReviewerSignOff -Reviewers $reviewers -Roster @() -PendingReviewerNames @('Bob', 'Dave')
        $r.Total | Should -Be 4
        $r.SignedRaw | Should -Be 4
        $r.Signed | Should -Be 2
        $r.AutoClosed | Should -Be 2
        @($r.GenuineSignedNames) | Sort-Object | Should -Be @('Alice', 'Carol')
    }

    It 'matches pending names case-insensitively and ignores blank / N/A / unknown names' {
        $reviewers = @((New-GSOReviewer -Name 'Alice' -Id 'r1'), (New-GSOReviewer -Name 'Bob' -Id 'r2'))
        $r = Get-SPGenuineReviewerSignOff -Reviewers $reviewers -PendingReviewerNames @('ALICE', '', 'N/A', 'Nobody Real')
        $r.Signed | Should -Be 1
        @($r.GenuineSignedNames) | Should -Be @('Bob')
    }
}

Describe 'GSO-02: admin force-sign evidence veto' {
    It 'excludes reviewers whose cert was signed by someone else' {
        $reviewers = @((New-GSOReviewer -Name 'Alice' -Id 'r1'), (New-GSOReviewer -Name 'Bob' -Id 'r2'))
        $roster = @(
            (New-GSORosterEntry -Name 'Alice' -Id 'r1' -SignedById 'admin-9'),
            (New-GSORosterEntry -Name 'Bob' -Id 'r2' -SignedById 'r2')       # self-signed: genuine
        )
        $r = Get-SPGenuineReviewerSignOff -Reviewers $reviewers -Roster $roster
        $r.Signed | Should -Be 1
        $r.AutoClosed | Should -Be 1
        @($r.GenuineSignedNames) | Should -Be @('Bob')
    }

    It 'treats empty SignedById as indeterminate (never force evidence)' {
        $reviewers = @((New-GSOReviewer -Name 'Alice' -Id 'r1'))
        $roster = @((New-GSORosterEntry -Name 'Alice' -Id 'r1' -SignedById ''))
        (Get-SPGenuineReviewerSignOff -Reviewers $reviewers -Roster $roster).Signed | Should -Be 1
    }
}

Describe 'GSO-03: overlap subtracts once (set semantics)' {
    It 'a reviewer with BOTH pending items AND force-sign evidence reduces Signed by exactly 1' {
        # Count arithmetic would compute 3 signed - 1 forced - 1 pending = 1; the honest answer is 2.
        $reviewers = @(
            (New-GSOReviewer -Name 'Alice' -Id 'r1'),
            (New-GSOReviewer -Name 'Bob' -Id 'r2'),
            (New-GSOReviewer -Name 'Carol' -Id 'r3')
        )
        $roster = @((New-GSORosterEntry -Name 'Alice' -Id 'r1' -SignedById 'admin-9'))
        $r = Get-SPGenuineReviewerSignOff -Reviewers $reviewers -Roster $roster -PendingReviewerNames @('Alice')
        $r.Signed | Should -Be 2
        $r.AutoClosed | Should -Be 1
    }
}

Describe 'GSO-04: distinct-by-reviewer totals' {
    It 'collapses per-cert reassigned entries for the same person and counts new delegates once' {
        # 3 primary + delegate Dana holding 2 reassigned certs (also NOT a primary) + primary Bob
        # holding 1 reassigned cert => 4 distinct reviewers from 6 entries.
        $reviewers = @(
            (New-GSOReviewer -Name 'Alice' -Id 'r1'),
            (New-GSOReviewer -Name 'Bob' -Id 'r2'),
            (New-GSOReviewer -Name 'Carol' -Id 'r3' -Phase 'ACTIVE'),
            (New-GSOReviewer -Name 'Dana' -Id 'r4'),
            (New-GSOReviewer -Name 'Dana' -Id 'r4'),
            (New-GSOReviewer -Name 'Bob' -Id 'r2')
        )
        $r = Get-SPGenuineReviewerSignOff -Reviewers $reviewers
        $r.Total | Should -Be 4
        $r.SignedRaw | Should -Be 3      # Alice, Bob, Dana (Carol not signed)
    }

    It 'NotStarted counts distinct reviewers whose every entry is idle' {
        $reviewers = @(
            (New-GSOReviewer -Name 'Alice' -Id 'r1' -Phase 'NOT_STARTED' -DecisionsMade 0),
            (New-GSOReviewer -Name 'Bob' -Id 'r2' -Phase 'ACTIVE' -DecisionsMade 0),
            (New-GSOReviewer -Name 'Carol' -Id 'r3' -Phase 'ACTIVE' -DecisionsMade 3)
        )
        (Get-SPGenuineReviewerSignOff -Reviewers $reviewers).NotStarted | Should -Be 2
    }

    It 'returns all zeros for null/empty input' {
        $r = Get-SPGenuineReviewerSignOff -Reviewers @()
        $r.Total | Should -Be 0
        $r.Signed | Should -Be 0
        $r.AutoClosed | Should -Be 0
    }
}

Describe 'GSO-05: closed-incomplete caption carries the auto-closed count' {
    It 'appends the auto-closed suffix only when the count is positive' {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 83 -ReviewersTotal 100 -UndecidedCount 42 -AutoClosedCount 17
        $q.IsClosedIncomplete | Should -BeTrue
        $q.Caption | Should -Be 'Closed with incomplete work - 83 of 100 reviewers signed off, 42 items never manually decided (17 reviewer(s) auto-closed at force-close)'
    }

    It 'keeps the legacy caption byte-identical when AutoClosedCount is 0/omitted' {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 2 -ReviewersTotal 3 -UndecidedCount 4
        $q.Caption | Should -Be 'Closed with incomplete work - 2 of 3 reviewers signed off, 4 items never manually decided'
    }
}
