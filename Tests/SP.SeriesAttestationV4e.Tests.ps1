#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    E2E proof that Invoke-SPDailyEvidenceReportV4e.ps1 renders BYTE-FAITHFUL V4b chrome AND
    correct series-attestation data off the committed rich-cache fixture.
.DESCRIPTION
    This is a targeted sibling of SP.SeriesAttestationV4eReport.Tests.ps1 (which reconciles the
    JSON/HTML detail rows via pwsh). Here we run the read-only V4e CLI ONCE via powershell.exe
    (Windows PowerShell 5.1 -- the repo target, always present on this box) against the checked-in
    fixture cache (Tests/TestData/SeriesAttestation/cache) with -IncludeUnverified and assert BOTH:

      (a) V4b chrome is byte-faithful -- the literal section chrome copied from V4b renders verbatim:
          the gradient header, class='container', class="scope-inline", class="execbox", the donut
          stroke-dasharray attribute, table class="report", the B reviewer accountability section,
          and class="footer".
      (b) Series DATA is correct -- the fixture's 11 instances collapse to ONE series
          'daily attestation manager campaign'; Alice + Carol => NewlyAttested (2), Dave =>
          PersistentlyUndecided (1), Bob is AlreadyAttestedEarlier (excluded). Under -IncludeUnverified
          the JSON projection Counts equal the engine counts.

    QUOTE-STYLE GOTCHA (load-bearing): the container div and the donut attribute render with SINGLE
    quotes, everything else with DOUBLE quotes -- the chrome assertions below match accordingly.

    Every run-dependent It is gated on $script:PsAvailable (Skipped only if powershell.exe is truly
    absent -- it is not on this Windows box).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    # powershell.exe (Windows PowerShell 5.1) is the repo target and is always present on this box.
    $script:PsAvailable = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
    $script:V4ePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV4e.ps1'

    # Resolve the COMMITTED cache fixture; self-heal by regenerating into $TestDrive when the
    # committed copy is missing/stale (so the suite never depends on a stale on-disk copy).
    # PS 5.1: nested 2-arg Join-Path (no 3-arg form).
    $committedCache = Join-Path (Join-Path (Join-Path $PSScriptRoot 'TestData') 'SeriesAttestation') 'cache'
    $hasFixture = $false
    if (Test-Path $committedCache) {
        $hasFixture = @(Get-ChildItem -Path $committedCache -Filter 'items-*.meta.json' -File -ErrorAction SilentlyContinue).Count -gt 0
    }
    if ($hasFixture) {
        $script:CacheDir = $committedCache
    }
    else {
        $gen = Join-Path (Join-Path (Join-Path $PSScriptRoot 'TestData') 'SeriesAttestation') 'Build-SeriesAttestationFixture.ps1'
        $script:CacheDir = Join-Path $TestDrive 'sa-cache'
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        & $gen -OutputDir $script:CacheDir | Out-Null
    }

    # Run the read-only V4e CLI ONCE -- render Both so BOTH the .html and the .json sidecar are written.
    if ($script:PsAvailable) {
        $script:outDir = Join-Path $TestDrive 'v4e-out'
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
        & powershell.exe -NoProfile -File $script:V4ePath -CachePath $script:CacheDir -IncludeUnverified -OutputPath $script:outDir -OutputMode Both | Out-Null
        $script:exit = $LASTEXITCODE
        $script:htmlFile = (Get-ChildItem -Path $script:outDir -Filter 'daily-evidence-v4e-*.html' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $script:jsonFile = (Get-ChildItem -Path $script:outDir -Filter 'daily-evidence-v4e-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }
}

Describe 'V4E-E2E-01: parses / exits 0 / writes files' {
    It 'has no parse errors (Parser::ParseFile)' {
        Test-Path $script:V4ePath | Should -Be $true
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:V4ePath, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
    It 'exits 0' {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:exit | Should -Be 0
    }
    It 'writes a daily-evidence-v4e-*.html and a .json sidecar' {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:htmlFile | Should -Not -BeNullOrEmpty
        $script:jsonFile | Should -Not -BeNullOrEmpty
    }
}

Describe 'V4E-E2E-02: V4b chrome is byte-faithful' {
    It 'renders every V4b section-chrome token verbatim' {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $html = Get-Content $script:htmlFile.FullName -Raw

        # Header gradient (CSS .header{background:linear-gradient(135deg,...)}).
        $html | Should -Match 'linear-gradient'
        # Container div renders SINGLE-quoted: <div class='container'>. Quote-tolerant match.
        $html | Should -Match 'class=[''"]container[''"]'
        # Certification Scope inline block (double-quoted).
        $html | Should -Match 'class="scope-inline"'
        # Executive Summary box (double-quoted).
        $html | Should -Match 'class="execbox"'
        # Donut ring -- attribute name only (renders single-quoted stroke-dasharray='$pct $rest').
        $html | Should -Match 'stroke-dasharray'
        # table.report (Section A / B / detail; double-quoted).
        $html | Should -Match 'class="report"'
        # Section B reviewer accountability heading ('.' escaped).
        $html | Should -Match '<h2>B\. Reviewer Accountability</h2>'
        # Footer (double-quoted).
        $html | Should -Match 'class="footer"'
    }
}

Describe 'V4E-E2E-03: series data is correct' {
    It 'yields one series with NewlyAttested=2 and PersistentlyUndecided=1' {
        if (-not $script:PsAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }

        # Read the JSON FILE (never child stdout -- the console banner leaks into stdout).
        $json = Get-Content $script:jsonFile.FullName -Raw | ConvertFrom-Json
        $json.Version     | Should -Be 'V4e'
        $json.SeriesCount | Should -Be 1

        $series = @($json.Series)
        $series.Count | Should -Be 1
        $series[0].NormalizedStem | Should -Be 'daily attestation manager campaign'
        [int]$series[0].Counts.NewlyAttested         | Should -Be 2
        [int]$series[0].Counts.PersistentlyUndecided | Should -Be 1
    }
}
