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

    # Resolve the shipped-script paths in the run phase so the DDP-002 static/wiring
    # guards can read the ACTUAL files. $PSScriptRoot is Tests/, scripts live in
    # ../Scripts/ (PS 5.1: no 3-arg Join-Path -> nest two 2-arg calls).
    $script:DDPRepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:DDPScriptsV4  = Join-Path (Join-Path $script:DDPRepoRoot 'Scripts') 'Invoke-SPDailyEvidenceReportV4.ps1'
    $script:DDPScriptsV4b = Join-Path (Join-Path $script:DDPRepoRoot 'Scripts') 'Invoke-SPDailyEvidenceReportV4b.ps1'
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

Describe "DDP-002: script injection idiom (5.1 runtime guard)" {
    # Closes the honesty test-gap: no test previously exercised the SCRIPT injection
    # path. ParseFile reports 0 errors on the buggy form, and the pure-helper tests
    # above never load the scripts, so the runtime CommandNotFoundException that left
    # DecisionDateProvenance unset slipped through. These guards read the ACTUAL
    # shipped script text and prove the corrected idiom at runtime.

    Context "static guard: forbidden inline-if-as-argument is absent from the shipped scripts" {
        It "Invoke-SPDailyEvidenceReportV4.ps1 has no '-NotePropertyValue (if' occurrence" {
            (Test-Path $script:DDPScriptsV4) | Should -BeTrue
            $raw = Get-Content -Raw -Path $script:DDPScriptsV4
            $raw | Should -Not -Match '-NotePropertyValue\s*\(\s*if\b'
        }
        It "Invoke-SPDailyEvidenceReportV4b.ps1 has no '-NotePropertyValue (if' occurrence" {
            (Test-Path $script:DDPScriptsV4b) | Should -BeTrue
            $raw = Get-Content -Raw -Path $script:DDPScriptsV4b
            $raw | Should -Not -Match '-NotePropertyValue\s*\(\s*if\b'
        }
    }

    Context "positive wiring guard: the precomputed tag is defined and used at both injection sites" {
        It "Invoke-SPDailyEvidenceReportV4.ps1 precomputes \$fallbackProv and wires it twice" {
            $raw = Get-Content -Raw -Path $script:DDPScriptsV4
            $raw | Should -Match '\$fallbackProv\s*=\s*if\s*\('
            $usages = [regex]::Matches($raw, '-NotePropertyValue\s+\$fallbackProv\b')
            $usages.Count | Should -BeGreaterOrEqual 2
        }
        It "Invoke-SPDailyEvidenceReportV4b.ps1 precomputes \$fallbackProv and wires it twice" {
            $raw = Get-Content -Raw -Path $script:DDPScriptsV4b
            $raw | Should -Match '\$fallbackProv\s*=\s*if\s*\('
            $usages = [regex]::Matches($raw, '-NotePropertyValue\s+\$fallbackProv\b')
            $usages.Count | Should -BeGreaterOrEqual 2
        }
    }

    Context "runtime idiom proof: the corrected statement-assignment actually stamps the property" {
        It "stamps 'campaign-created' when the fallback IS the created timestamp" {
            $o = [pscustomobject]@{ Key = 'k1' }
            $fallbackIsCreated = $true
            $fallbackProv = if ($fallbackIsCreated) { 'campaign-created' } else { 'signoff' }
            $o | Add-Member -NotePropertyName 'DecisionDateProvenance' -NotePropertyValue $fallbackProv -Force
            ($o.PSObject.Properties.Name -contains 'DecisionDateProvenance') | Should -BeTrue
            $o.DecisionDateProvenance | Should -Be 'campaign-created'
        }
        It "stamps 'signoff' when the fallback is a genuine sign-off date" {
            $o = [pscustomobject]@{ Key = 'k2' }
            $fallbackIsCreated = $false
            $fallbackProv = if ($fallbackIsCreated) { 'campaign-created' } else { 'signoff' }
            $o | Add-Member -NotePropertyName 'DecisionDateProvenance' -NotePropertyValue $fallbackProv -Force
            ($o.PSObject.Properties.Name -contains 'DecisionDateProvenance') | Should -BeTrue
            $o.DecisionDateProvenance | Should -Be 'signoff'
        }
    }
}
