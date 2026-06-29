#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for decision-date provenance (DATE-PROVENANCE-GUARD).
.DESCRIPTION
    Proves Resolve-SPDecisionDateDisplay distinguishes a GENUINE decision time from
    a created/placeholder substitute so the daily-evidence render never presents the
    campaign Created timestamp as a real decision date.

    Contract (IsGenuine = the date is a real decision time):
      - blank/whitespace RawDate                                  -> not genuine, Display = Placeholder
      - Provenance in campaign-created/created/placeholder/
        fallback-created (case-insensitive)                       -> not genuine
      - CampaignCreated non-blank AND RawDate value-equals it     -> not genuine
        (same instant even when differently formatted)
      - otherwise                                                 -> genuine, Display = RawDate verbatim
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

Describe "DDP-001: Resolve-SPDecisionDateDisplay provenance guard" {

    It "treats a blank RawDate as NOT genuine and shows the placeholder" {
        $r = Resolve-SPDecisionDateDisplay -RawDate '   '
        $r.IsGenuine | Should -BeFalse
        $r.Display   | Should -Be '-'
    }

    It "treats Provenance 'campaign-created' as NOT genuine regardless of the date value" {
        $r = Resolve-SPDecisionDateDisplay -RawDate '2026-06-01T09:00:00Z' -Provenance 'campaign-created'
        $r.IsGenuine | Should -BeFalse
        $r.Display   | Should -Be '-'
    }

    It "treats provenance markers case-insensitively (CREATED)" {
        $r = Resolve-SPDecisionDateDisplay -RawDate '2026-06-01T09:00:00Z' -Provenance 'CREATED'
        $r.IsGenuine | Should -BeFalse
    }

    It "treats a RawDate value-equal to CampaignCreated as NOT genuine (same instant, different format)" {
        $r = Resolve-SPDecisionDateDisplay -RawDate '2026-06-01T09:00:00Z' -CampaignCreated '2026-06-01 09:00:00Z'
        $r.IsGenuine | Should -BeFalse
        $r.Display   | Should -Be '-'
    }

    It "treats a genuine distinct decision date with empty provenance as genuine and echoes it verbatim" {
        $raw = '2026-06-15T14:32:00Z'
        $r = Resolve-SPDecisionDateDisplay -RawDate $raw -Provenance '' -CampaignCreated '2026-06-01T09:00:00Z'
        $r.IsGenuine | Should -BeTrue
        $r.Display   | Should -Be $raw
    }

    It "respects a custom -Placeholder when the date is not genuine" {
        $r = Resolve-SPDecisionDateDisplay -RawDate '' -Placeholder 'unknown'
        $r.IsGenuine | Should -BeFalse
        $r.Display   | Should -Be 'unknown'
    }

    It "does NOT suppress a genuine date that merely shares no value with a blank CampaignCreated" {
        $raw = '2026-06-15T14:32:00Z'
        $r = Resolve-SPDecisionDateDisplay -RawDate $raw -CampaignCreated ''
        $r.IsGenuine | Should -BeTrue
        $r.Display   | Should -Be $raw
    }
}
