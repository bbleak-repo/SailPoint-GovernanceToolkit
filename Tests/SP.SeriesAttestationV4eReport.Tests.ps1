#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the V4e series-attestation report -- Invoke-SPDailyEvidenceReportV4e.ps1.
.DESCRIPTION
    Proves the read-only V4e CLI + V4b-chrome HTML render (NOT the engine internals, which are
    covered by SP.SeriesAttestationDelta / SP.CachedCampaignSeries). V4e wears the V4/V4b visual
    chrome (gradient header, .section h2 blocks, .execbox, table.report, Decision Summary details)
    rebound to series-attestation fields; the per-campaign KPI/SLA/risk/domino machinery is dropped.

      V4E-01  the script parses with no errors (Parser::ParseFile).
      V4E-02  read-only -- source carries NO SupportsShouldProcess (CLI-005) and exposes no -WhatIf.
      V4E-03  runs against the repo fixture cache (Tests/TestData/SeriesAttestation/cache) with
              -IncludeUnverified, exit 0, and writes a daily-evidence-v4e-*.html.
      V4E-04  chrome grep: the HTML carries the V4b-EXACT section chrome (footer, v4e footer text,
              Decision Summary h2 + Decision Changes / Newly In Scope details) plus the already-
              shipped Certification Scope / execbox / Section A / Section B chrome (regression guard).
      V4E-05  DATA correctness: read the sibling daily-evidence-v4e-*.json FILE (NOT piped stdout --
              the console banner leaks into child stdout, see round-05 journal), Version -eq 'V4e',
              per-series Counts.DecisionChanged / Counts.NewlyInScope are non-negative ints, and the
              JSON Counts.NewlyInScope equals the number of 'Newly In Scope' detail <tr> rows the
              HTML renders for that series (HTML detail == JSON Counts reconciliation).

    The fixture cache is the checked-in repo cache; the script-invoking Its are gated behind
    -Skip:(-not $script:PwshAvailable), mirroring SP.SeriesAttestationCli.Tests.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    $script:PwshAvailable = [bool](Get-Command pwsh -ErrorAction SilentlyContinue)
    $script:V4ePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV4e.ps1'

    # The V4e test input is the checked-in rich cache fixture (>=2 same-series instances).
    $script:cliCache = Join-Path $PSScriptRoot 'TestData\SeriesAttestation\cache'

    function Invoke-V4e {
        param([string]$ExtraArgs = '')
        $cmd = "& '$($script:V4ePath)' $ExtraArgs 2>&1"
        return (& pwsh -NoProfile -Command $cmd)
    }

    # Run ONCE for the run-dependent describes: render Both to a scratch dir under TestDrive.
    $script:v4eOut = Join-Path $TestDrive 'v4e-out'
    New-Item -ItemType Directory -Path $script:v4eOut -Force | Out-Null
    if ($script:PwshAvailable) {
        $script:v4eStdout = Invoke-V4e "-CachePath '$($script:cliCache)' -IncludeUnverified -OutputPath '$($script:v4eOut)' -OutputMode Both"
        $script:v4eExit = $LASTEXITCODE
        $script:v4eHtml = (Get-ChildItem -Path $script:v4eOut -Filter 'daily-evidence-v4e-*.html' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $script:v4eJson = (Get-ChildItem -Path $script:v4eOut -Filter 'daily-evidence-v4e-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }
}

Describe "V4E-01: script parses" {
    It "exists and has no parse errors" {
        Test-Path $script:V4ePath | Should -Be $true
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:V4ePath, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe "V4E-02: read-only -- no SupportsShouldProcess (CLI-005)" {
    It "source carries no SupportsShouldProcess attribute" {
        $src = Get-Content $script:V4ePath -Raw
        $src | Should -Not -Match 'SupportsShouldProcess'
    }
    It "exposes no -WhatIf / -Confirm parameter" {
        $cmd = Get-Command $script:V4ePath
        $cmd.Parameters.Keys | Should -Not -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Not -Contain 'Confirm'
    }
}

Describe "V4E-03: runs against the fixture cache and writes HTML" {
    It "exits 0" {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'pwsh (PowerShell 7) not available'; return }
        $script:v4eExit | Should -Be 0
    }
    It "produces a daily-evidence-v4e-*.html file" {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'pwsh (PowerShell 7) not available'; return }
        $script:v4eHtml | Should -Not -BeNullOrEmpty
        $script:v4eHtml.Length | Should -BeGreaterThan 500
    }
    It "produces a sibling daily-evidence-v4e-*.json file" {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'pwsh (PowerShell 7) not available'; return }
        $script:v4eJson | Should -Not -BeNullOrEmpty
    }
}

Describe "V4E-04: V4b-EXACT section chrome (Decision Summary + footer + regression guard)" {
    It "carries the Decision Summary / footer / already-shipped section chrome" {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'pwsh (PowerShell 7) not available'; return }
        $content = Get-Content $script:v4eHtml.FullName -Raw
        # New in this item: Decision Summary detail + V4b-exact rebranded footer.
        $content | Should -Match 'class="footer"'
        $content | Should -Match 'Daily Evidence Report v4e'
        $content | Should -Match '<h2>Decision Summary</h2>'
        $content | Should -Match 'Decision Changes'
        $content | Should -Match 'Newly In Scope'
        $content | Should -Match 'CorrelationID:'
        # Regression guard: the already-shipped V4b chrome must still be present.
        $content | Should -Match '<h2>Certification Scope</h2>'
        $content | Should -Match 'class="execbox"'
        $content | Should -Match '<h2>A\. Series Attestation Summary</h2>'
        $content | Should -Match '<h2>B\. Reviewer Accountability</h2>'
    }
}

Describe "V4E-05: DATA correctness -- JSON Version + Counts reconcile with HTML detail rows" {
    It "Version is V4e and per-series Newly In Scope Counts equal the HTML detail rows" {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'pwsh (PowerShell 7) not available'; return }

        # Read the JSON FILE (never piped stdout -- the console banner leaks into child stdout).
        $json = Get-Content $script:v4eJson.FullName -Raw | ConvertFrom-Json
        $json.Version | Should -Be 'V4e'

        $html = Get-Content $script:v4eHtml.FullName -Raw

        # Isolate the Decision Summary section (from its h2 to the footer) and split into per-series
        # chunks on <div class="subhead"> -- chunks are in seriesDataList order == JSON Series order.
        $dsStart = $html.IndexOf('<h2>Decision Summary</h2>')
        $dsStart | Should -BeGreaterThan -1
        $footStart = $html.IndexOf('<div class="footer"', $dsStart)
        $footStart | Should -BeGreaterThan $dsStart
        $dsSection = $html.Substring($dsStart, $footStart - $dsStart)
        $chunks = @($dsSection -split '<div class="subhead">')
        # element [0] is the pre-subhead preamble; series chunks start at index 1.

        $series = @($json.Series)
        for ($i = 0; $i -lt $series.Count; $i++) {
            $s = $series[$i]
            [int]$s.Counts.DecisionChanged | Should -BeGreaterOrEqual 0
            [int]$s.Counts.NewlyInScope | Should -BeGreaterOrEqual 0

            $chunk = $chunks[$i + 1]
            $chunk | Should -Not -BeNullOrEmpty
            # Within the chunk, the 'Newly In Scope' details block runs from its summary to the end.
            $nisIdx = $chunk.IndexOf('Newly In Scope (')
            $nisIdx | Should -BeGreaterThan -1
            $nisBlock = $chunk.Substring($nisIdx)
            # Data rows are '<tr><td>...' (the None. row is '<tr><td colspan=' so it does NOT match).
            $rows = ([regex]::Matches($nisBlock, '<tr><td>')).Count
            $rows | Should -Be ([int]$s.Counts.NewlyInScope)
        }
    }
}
