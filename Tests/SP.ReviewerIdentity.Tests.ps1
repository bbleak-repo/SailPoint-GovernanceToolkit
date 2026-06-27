#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    WI-5 (plan G3) -- reviewer identity keyed on ISC identity ID, not display name.

.DESCRIPTION
    Group-SPCompletedPendingByReviewer (the COMPLETED-path attribution from WI-3) used to
    key its output OrderedDictionary on the reviewer DISPLAY NAME, so:
      * two distinct reviewers sharing a display name MERGE into one row (collision), and
      * one reviewer renamed across captures SPLITS into two rows.
    WI-5 adds an OPT-IN -KeyByReviewerId switch that keys on the ISC identity ID
    ('id:'+ReviewerId), with display name kept for presentation only, plus a -ReassignedAwayIds
    companion exclusion so a reassigned-away reviewer is excluded by ID (not by a name that
    might collide with an innocent same-named reviewer).

    These are SELF-CONTAINED unit tests (no mock server). Inputs are crafted directly as
    PSCustomObjects:
      * roster entries shaped like ConvertTo-SPCertRosterEntry output
        (CertificationId / ReviewerName / ReviewerId / ReviewerEmail / Classification /
        ReassignedFromName / ReassignedFromId),
      * pending items shaped like Group-SPAuditDecisions undecided output -- a pending item
        has no reviewedBy so its ReviewerName is 'N/A', forcing roster attribution.

    Assertions:
      RI-01 NO MERGE   -- two reviewers, same name, distinct IDs are NOT merged (with switch),
                          and the contrast (without switch) reproduces the old 1-row collapse.
      RI-02 NO SPLIT   -- one reviewer (one ID) renamed across certs stays ONE row (with switch),
                          and the contrast (without switch) splits into two rows.
      RI-03 REASSIGN   -- reassigned-away exclusion by ID drops only the matching reviewer,
                          whereas the name-based exclusion would wrongly drop BOTH same-named.
      RI-04 ADDITIVE   -- default (no switch) call is still name-keyed exactly as today.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    # Build a roster entry mirroring ConvertTo-SPCertRosterEntry output.
    function New-RosterEntry {
        param(
            [string]$CertId,
            [string]$ReviewerName,
            [string]$ReviewerId,
            [string]$ReviewerEmail = '',
            [string]$Classification = 'Primary',
            [string]$ReassignedFromName = $null,
            [string]$ReassignedFromId = $null
        )
        [PSCustomObject]@{
            CertificationId    = $CertId
            CertificationName  = $CertId
            ReviewerName       = $ReviewerName
            ReviewerId         = $ReviewerId
            ReviewerEmail      = $ReviewerEmail
            Classification     = $Classification
            ReassignedFromName = $ReassignedFromName
            ReassignedFromId   = $ReassignedFromId
        }
    }

    # Pending item: no reviewedBy -> ReviewerName 'N/A' (matches Group-SPAuditDecisions :179),
    # forcing the function to attribute by the cert's roster reviewer.
    function New-PendingItems {
        param([string]$CertId, [int]$Count)
        1..$Count | ForEach-Object { [PSCustomObject]@{ CertificationId = $CertId; ReviewerName = 'N/A' } }
    }
}

Describe "RI -- reviewer identity by ID, not display name (WI-5 / G3)" {

    It "RI-01 NO MERGE: two reviewers with the same display name but distinct IDs are not merged" {
        $roster = @(
            (New-RosterEntry -CertId 'cert-A' -ReviewerName 'Pat Smith' -ReviewerId 'id-rv-A'),
            (New-RosterEntry -CertId 'cert-B' -ReviewerName 'Pat Smith' -ReviewerId 'id-rv-B')
        )
        $pending = @((New-PendingItems -CertId 'cert-A' -Count 2) + (New-PendingItems -CertId 'cert-B' -Count 3))

        # With the switch: two distinct rows, one per identity ID.
        $byId = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster -KeyByReviewerId
        @($byId.Values).Count | Should -Be 2 -Because "two distinct identity IDs must stay two rows"
        $ids = @($byId.Values | ForEach-Object { $_.ReviewerId } | Sort-Object)
        $ids | Should -Be @('id-rv-A', 'id-rv-B') -Because "each row carries its own ISC identity ID"
        $counts = @($byId.Values | ForEach-Object { $_.PendingCount } | Sort-Object)
        $counts | Should -Be @(2, 3) -Because "the per-reviewer pending counts are not summed together"

        # Contrast (old name-keying bug): without the switch, the two collapse into one row.
        $byName = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster
        @($byName.Values).Count | Should -Be 1 -Because "name-keying merges the same-named reviewers (the bug WI-5 fixes)"
        $byName['Pat Smith'].PendingCount | Should -Be 5 -Because "name-keying sums both reviewers' pending items"
    }

    It "RI-02 NO SPLIT: one reviewer (one ID) renamed across captures stays a single row" {
        $roster = @(
            (New-RosterEntry -CertId 'cert-C' -ReviewerName 'Pat Smith'      -ReviewerId 'id-rv-C'),
            (New-RosterEntry -CertId 'cert-D' -ReviewerName 'Patricia Smith' -ReviewerId 'id-rv-C')
        )
        $pending = @((New-PendingItems -CertId 'cert-C' -Count 2) + (New-PendingItems -CertId 'cert-D' -Count 3))

        # With the switch: same ID -> exactly one row, one display name, summed count.
        $byId = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster -KeyByReviewerId
        @($byId.Values).Count | Should -Be 1 -Because "one identity ID is one reviewer regardless of rename"
        $row = @($byId.Values)[0]
        $row.ReviewerId | Should -Be 'id-rv-C'
        $row.PendingCount | Should -Be 5 -Because "the renamed reviewer's items are not split across two rows"
        $row.Name | Should -Be 'Pat Smith' -Because "Name is the first non-empty display name seen for the key"

        # Contrast: without the switch, the rename splits into two name-keyed rows.
        $byName = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster
        @($byName.Values).Count | Should -Be 2 -Because "name-keying splits a renamed reviewer (the bug WI-5 fixes)"
    }

    It "RI-03 REASSIGNMENT MATCH BY ID: ID exclusion drops only the reassigned-away reviewer" {
        # Two reviewers share the display name 'Pat Smith': id-rv-A reassigned away, id-rv-B active.
        $roster = @(
            (New-RosterEntry -CertId 'cert-A' -ReviewerName 'Pat Smith' -ReviewerId 'id-rv-A'),
            (New-RosterEntry -CertId 'cert-B' -ReviewerName 'Pat Smith' -ReviewerId 'id-rv-B')
        )
        $pending = @((New-PendingItems -CertId 'cert-A' -Count 2) + (New-PendingItems -CertId 'cert-B' -Count 3))

        # ID-based exclusion: id-rv-A excluded, id-rv-B's row remains.
        $byId = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster `
            -KeyByReviewerId -ReassignedAwayIds @{ 'id-rv-A' = $true }
        @($byId.Values).Count | Should -Be 1 -Because "only the reassigned-away identity is dropped"
        $row = @($byId.Values)[0]
        $row.ReviewerId | Should -Be 'id-rv-B' -Because "the active same-named reviewer is preserved"
        $row.PendingCount | Should -Be 3

        # Contrast: name-based exclusion of 'Pat Smith' wrongly drops BOTH same-named reviewers.
        $byName = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster `
            -KeyByReviewerId -ReassignedAwayNames @{ 'Pat Smith' = $true }
        @($byName.Values).Count | Should -Be 0 -Because "name-based exclusion cannot tell the two apart (why ID match is correct)"
    }

    It "RI-04 ADDITIVE: default call (no switch) still produces the name-keyed dictionary unchanged" {
        $roster = @(
            (New-RosterEntry -CertId 'cert-E' -ReviewerName 'Dana Lee'  -ReviewerId 'id-rv-D' -ReviewerEmail 'dana@example.com'),
            (New-RosterEntry -CertId 'cert-F' -ReviewerName 'Evan Park' -ReviewerId 'id-rv-E' -ReviewerEmail 'evan@example.com')
        )
        $pending = @(@(New-PendingItems -CertId 'cert-E' -Count 1) + @(New-PendingItems -CertId 'cert-F' -Count 2))

        $byName = Group-SPCompletedPendingByReviewer -PendingItems $pending -DecidedItems @() -Roster $roster
        @($byName.Values).Count | Should -Be 2 -Because "distinct names => distinct rows in the legacy path"
        $byName.Contains('Dana Lee')  | Should -BeTrue -Because "the dictionary is still keyed by display name by default"
        $byName.Contains('Evan Park') | Should -BeTrue
        $byName['Dana Lee'].PendingCount  | Should -Be 1
        $byName['Evan Park'].PendingCount | Should -Be 2
    }
}
