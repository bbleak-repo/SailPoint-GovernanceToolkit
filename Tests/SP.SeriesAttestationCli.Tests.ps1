#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the V4c series-attestation CLI -- Invoke-SPDailyEvidenceReportV4c.ps1.
.DESCRIPTION
    Proves the read-only CLI glue + HTML render, NOT the engine internals (those are
    covered by SP.SeriesAttestationDelta / SP.CachedCampaignSeries / SP.CampaignSeriesKey).

      CLI-01  the script parses with no errors (Parser::ParseFile).
      CLI-02  has CmdletBinding but NO SupportsShouldProcess (CLI-005 -- read-only).
      CLI-03  -OutputMode is a ValidateSet Console/JSON/HTML/Both (CLI-004).
      CLI-04  against a TestDrive fixture cache (>=2 same-series instances; one prior
              Undecided, newest genuine APPROVE) produces a daily-evidence-v4c-*.html
              whose content names "Newly Attested" and "Daily Evidence Report v4c".
      CLI-05  empty cache dir -> exit 0 + still emits valid HTML (no throw).

    The cache fixtures are hand-authored into a TestDrive subdir; metas are written with
    -Encoding UTF8 (UTF-8 BOM) ON PURPOSE to prove the BOM-safe read path. The
    script-invoking Its are gated behind $script:PsAvailable (powershell.exe -- Windows
    PowerShell 5.1, the repo target, always present on this box), mirroring the sibling
    SP.SeriesAttestationV4e.Tests.ps1. (Earlier revisions invoked pwsh / PowerShell 7, which
    is NOT installed here, so every run-dependent It silently skipped.)
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    # powershell.exe (Windows PowerShell 5.1) is the repo target and is always present on this box.
    $script:PsAvailable = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
    $script:V4cPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV4c.ps1'

    # Reuse the cache-fixture builder shape from SP.CachedCampaignSeries.Tests.ps1: meta
    # is written -Encoding UTF8 (UTF-8 BOM) on purpose; items wrapped one-per-line; roster
    # carries the sealed Entries (cert-assigned reviewer attribution).
    function New-CliCacheInstance {
        param(
            [string]$Dir,
            [string]$CampId,
            [string]$CampName,
            [string]$Status = 'COMPLETED',
            [string]$CachedAt = '2026-06-30T08:00:00.0000000+00:00',
            [bool]$CapturedWhileActive = $true,
            [bool]$Unverified = $false,
            [object[]]$Items = @(),
            [object[]]$RosterEntries = @()
        )
        $safe = $CampId -replace '[^A-Za-z0-9_\-]', '_'
        $meta = [ordered]@{
            CampaignId          = $CampId
            CampaignName        = $CampName
            Status              = $Status
            CachedAt            = $CachedAt
            IsPermanent         = $true
            CapturedWhileActive = $CapturedWhileActive
            Unverified          = $Unverified
            ItemCount           = @($Items).Count
            CertCount           = @($RosterEntries).Count
        }
        $meta | ConvertTo-Json | Set-Content (Join-Path $Dir "items-$safe.meta.json") -Encoding UTF8

        $itemsPath = Join-Path $Dir "items-$safe.jsonl"
        if (@($Items).Count -gt 0) {
            $lines = foreach ($it in @($Items)) {
                @{ Item = $it; CertificationId = "$CampId-cert"; CertificationName = "$CampName Cert"; CampaignName = $CampName } | ConvertTo-Json -Compress -Depth 8
            }
            Set-Content -Path $itemsPath -Value $lines -Encoding UTF8
        }

        if (@($RosterEntries).Count -gt 0) {
            $roster = [ordered]@{ CampaignId = $CampId; CapturedWhileActive = $CapturedWhileActive; Entries = @($RosterEntries) }
            $roster | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Dir "roster-$safe.json") -Encoding UTF8
        }
    }

    # Build a recurring series: identity 'alice' + entitlement 'Finance-RW' is Undecided
    # (pending) in the prior instance and a GENUINE reviewer APPROVE in the newest.
    function New-CliFixtureItem {
        param([string]$Decision, [string]$Justification = '')
        return [PSCustomObject]@{
            identitySummary = [PSCustomObject]@{ identityId = 'id-alice'; name = 'Alice Anders' }
            access          = [PSCustomObject]@{ id = 'ent-fin-rw'; type = 'ENTITLEMENT'; name = 'Finance-RW' }
            accessSummary   = [PSCustomObject]@{ entitlement = [PSCustomObject]@{ sourceId = 'src-ad'; sourceName = 'CorpAD' } }
            decision        = $Decision
            decisionDate    = '2026-06-30T10:00:00Z'
            comment         = $Justification
        }
    }

    function Invoke-V4c {
        param([string]$ExtraArgs = '')
        $cmd = "& '$($script:V4cPath)' $ExtraArgs 2>&1"
        return (& powershell.exe -NoProfile -Command $cmd)
    }
}

Describe "CLI-01: V4c script parses" {
    It "exists and has no parse errors" {
        Test-Path $script:V4cPath | Should -Be $true
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:V4cPath, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe "CLI-02: read-only -- no SupportsShouldProcess (CLI-005)" {
    It "has CmdletBinding but exposes no -WhatIf parameter" {
        $cmd = Get-Command $script:V4cPath
        $cmd.Parameters.Keys | Should -Not -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Not -Contain 'Confirm'
    }
    It "source carries no SupportsShouldProcess attribute" {
        $src = Get-Content $script:V4cPath -Raw
        $src | Should -Not -Match 'SupportsShouldProcess'
    }
}

Describe "CLI-03: -OutputMode is a ValidateSet (CLI-004)" {
    It "validates Console/JSON/HTML/Both" {
        $cmd = Get-Command $script:V4cPath
        $p = $cmd.Parameters['OutputMode']
        $p | Should -Not -BeNullOrEmpty
        $vs = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $vs | Should -Not -BeNullOrEmpty
        $set = @($vs.ValidValues)
        $set | Should -Contain 'Console'
        $set | Should -Contain 'JSON'
        $set | Should -Contain 'HTML'
        $set | Should -Contain 'Both'
    }
}

Describe "CLI-04: renders HTML from a 2-instance recurring fixture cache" {
    BeforeAll {
        $script:cliCache = Join-Path $TestDrive 'cli04-cache'
        $script:cliOut = Join-Path $TestDrive 'cli04-out'
        New-Item -ItemType Directory -Path $script:cliCache -Force | Out-Null
        New-Item -ItemType Directory -Path $script:cliOut -Force | Out-Null

        # Roster is keyed by the per-item CERTIFICATION id. New-CliCacheInstance wraps each item
        # with CertificationId "<CampId>-cert" (see line ~64), and post-44c0edf the engine derives
        # the per-item cert id from that wrapper -- so the sealed roster entry's CertificationId
        # must equal "<CampId>-cert" for the cert-assigned reviewer to win (mirrors the passing E2E
        # roster-dam-*.json which keys on 'dam-01-cert').
        $roster = @([PSCustomObject]@{ CertificationId = 'cli-d1-cert'; ReviewerName = 'Rita Reviewer'; ReviewerId = 'rv-rita'; ReviewerEmail = 'rita@test.com' })
        $rosterB = @([PSCustomObject]@{ CertificationId = 'cli-d2-cert'; ReviewerName = 'Rita Reviewer'; ReviewerId = 'rv-rita'; ReviewerEmail = 'rita@test.com' })

        # Prior instance: pending (Undecided). Newest: genuine APPROVE.
        New-CliCacheInstance -Dir $script:cliCache -CampId 'cli-d1' -CampName 'Access Review - 2026-06-29' `
            -CachedAt '2026-06-29T08:00:00.0000000+00:00' `
            -Items @((New-CliFixtureItem -Decision 'PENDING')) -RosterEntries $roster
        New-CliCacheInstance -Dir $script:cliCache -CampId 'cli-d2' -CampName 'Access Review -2026-06-30' `
            -CachedAt '2026-06-30T08:00:00.0000000+00:00' `
            -Items @((New-CliFixtureItem -Decision 'APPROVE')) -RosterEntries $rosterB

        if ($script:PsAvailable) {
            $script:cli04Out = Invoke-V4c "-CachePath '$($script:cliCache)' -OutputPath '$($script:cliOut)' -OutputMode HTML"
            $script:cli04Html = (Get-ChildItem -Path $script:cliOut -Filter 'daily-evidence-v4c-*.html' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }
    }

    It "produces a daily-evidence-v4c-*.html file" {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cli04Html | Should -Not -BeNullOrEmpty
        $script:cli04Html.Length | Should -BeGreaterThan 500
    }

    It "names the report and the Newly Attested headline" {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $content = Get-Content $script:cli04Html.FullName -Raw
        $content | Should -Match 'Daily Evidence Report v4c'
        $content | Should -Match 'Newly Attested'
    }

    It "attributes the genuine approval to the cert-assigned reviewer" {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $content = Get-Content $script:cli04Html.FullName -Raw
        $content | Should -Match 'Rita Reviewer'
        $content | Should -Match 'Finance-RW'
    }
}

Describe "CLI-05: empty cache dir -> exit 0 + valid HTML (no throw)" {
    BeforeAll {
        $script:emptyCache = Join-Path $TestDrive 'cli05-empty'
        $script:emptyOut = Join-Path $TestDrive 'cli05-out'
        New-Item -ItemType Directory -Path $script:emptyCache -Force | Out-Null
        New-Item -ItemType Directory -Path $script:emptyOut -Force | Out-Null

        if ($script:PsAvailable) {
            $script:cli05Out = Invoke-V4c "-CachePath '$($script:emptyCache)' -OutputPath '$($script:emptyOut)' -OutputMode HTML"
            $script:cli05Exit = $LASTEXITCODE
            $script:cli05Html = (Get-ChildItem -Path $script:emptyOut -Filter 'daily-evidence-v4c-*.html' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }
    }

    It "exits 0" {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cli05Exit | Should -Be 0
    }

    It "still emits a valid no-series HTML" {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cli05Html | Should -Not -BeNullOrEmpty
        $content = Get-Content $script:cli05Html.FullName -Raw
        $content | Should -Match 'Daily Evidence Report v4c'
        $content | Should -Match 'No recurring series found'
    }
}
