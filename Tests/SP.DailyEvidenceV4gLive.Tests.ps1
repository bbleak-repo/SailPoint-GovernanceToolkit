#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    LIVE end-to-end tests for Invoke-SPDailyEvidenceReportV4g.ps1 against the committed
    node mock ISC (Tests/Tools/mock-isc-v4g.js): real auth flow, campaign/cert/item
    fetch, cache write, snapshot save, state tracking, and HTML render.

.DESCRIPTION
    The mock serves two phases via a phase file (V4G_PHASE_FILE env var):
      phase 1 -- one ACTIVE campaign (2026-09-05): Alice PENDING, Bob REVOKED,
                 Cara APPROVED (first seen)
      phase 2 -- adds the next day's campaign (2026-09-06): Alice APPROVED (newly
                 decided), Bob APPROVED (re-approved after revoke), Cara APPROVED

    V4GL-01: phase-1 baseline seeds the state DB with ZERO newly-decided/re-approved
    V4GL-02: phase-2 detects exactly 1 newly decided + 1 re-approved
    V4GL-03: phase-2 HTML renders the Newly Decided row, the Re-Approved After Revoke
             register with both dates, and excludes the first-seen-approved item

    Config handling mirrors SP.DailyEvidenceV7Reconcile.Tests: Config/settings.local.json
    is backed up, replaced with mock settings (all output paths sandboxed in $TestDrive),
    and restored in AfterAll. V4g runs out-of-process via the engine executable so its
    exit codes and preferences stay isolated. Skips when node is unavailable.
#>

BeforeAll {
    $script:glNode = $null
    try { $script:glNode = (Get-Command node -ErrorAction Ignore).Source } catch { }
    $script:glSkip = [string]::IsNullOrWhiteSpace($script:glNode)

    $script:ToolkitRoot = Split-Path $PSScriptRoot -Parent
    $script:V4gPath = Join-Path $script:ToolkitRoot 'Scripts\Invoke-SPDailyEvidenceReportV4g.ps1'
    $script:LocalCfg = Join-Path (Join-Path $script:ToolkitRoot 'Config') 'settings.local.json'
    $script:CfgBackup = $null
    if (Test-Path $script:LocalCfg) { $script:CfgBackup = Get-Content $script:LocalCfg -Raw }

    $script:Sandbox = Join-Path $TestDrive 'v4gl'
    foreach ($d in @('audit', 'metrics', 'cache', 'snapshots', 'out')) {
        New-Item -ItemType Directory -Path (Join-Path $script:Sandbox $d) -Force | Out-Null
    }
    $script:PhaseFile = Join-Path $TestDrive 'v4g-phase.txt'
    Set-Content -Path $script:PhaseFile -Value '1' -Encoding ascii

    if (-not $script:glSkip) {
        # Start the mock on a test-only port with the sandbox phase file.
        $env:V4G_PHASE_FILE = $script:PhaseFile
        $env:V4G_MOCK_PORT = '8768'
        $mockJs = Join-Path $PSScriptRoot 'Tools\mock-isc-v4g.js'
        $script:MockProc = Start-Process -FilePath $script:glNode -ArgumentList $mockJs -PassThru
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 8768); $c.Close(); break }
            catch { Start-Sleep -Milliseconds 250 }
        }
    }

    # Mock-targeting config with every output path sandboxed.
    $sbx = $script:Sandbox -replace '\\', '/'
    @{
        Api = @{ BaseUrl = 'http://127.0.0.1:8768/v3'; RetryCount = 1; RetryDelaySeconds = 1; TimeoutSeconds = 30
                 RateLimitRequestsPerWindow = 1000; RateLimitWindowSeconds = 1 }
        Authentication = @{ Mode = 'ConfigFile'; ConfigFile = @{
            TenantUrl = 'http://127.0.0.1:8768'; OAuthTokenUrl = 'http://127.0.0.1:8768/oauth/token'
            ClientId = 'mock'; ClientSecret = 'mock' } }
        Audit = @{ OutputPath = "$sbx/audit"; CachePath = "$sbx/cache"; SnapshotPath = "$sbx/snapshots" }
        Metrics = @{ Path = "$sbx/metrics" }
    } | ConvertTo-Json -Depth 5 | Set-Content $script:LocalCfg -Encoding UTF8

    $script:Engine = if (Get-Command powershell -ErrorAction Ignore) { 'powershell' } else { 'pwsh' }

    function Invoke-V4gLive {
        param([string]$Phase)
        Set-Content -Path $script:PhaseFile -Value $Phase -Encoding ascii
        # -DaysBack 3650, NOT a small window: the mock campaigns carry FIXED created
        # dates (2026-09-05/06), and V4g's lookback filters on them client-side. A
        # 3-day window made every assertion fail the moment the calendar moved on
        # ("Found 0 campaigns") -- a date bomb caught by the 2026-09-19 audit gate.
        & $script:Engine -NoProfile -ExecutionPolicy Bypass -File $script:V4gPath `
            -CampaignNameStartsWith 'Daily Attestation' -DaysBack 3650 `
            -OutputPath (Join-Path $script:Sandbox 'out') -OutputMode HTML 2>&1 | Out-String
    }

    # BOTH phases run HERE, in the file-level BeforeAll: Pester's TestDrive cleanup
    # removes files created INSIDE a Describe when that block exits, so a phase-1 run
    # inside Describe 1 lost its state DB before Describe 2's phase-2 run -- which then
    # seeded fresh (+3 new) instead of detecting the transitions. File-level artifacts
    # persist for the whole container.
    $script:p1 = ''
    $script:p2 = ''
    $script:h2 = ''
    if (-not $script:glSkip) {
        $script:p1 = Invoke-V4gLive -Phase '1'
        $script:StateSeeded = Test-Path (Join-Path $script:Sandbox 'metrics/entitlement-state.jsonl')
        $script:p2 = Invoke-V4gLive -Phase '2'
        $hf = Get-ChildItem (Join-Path $script:Sandbox 'out') -Filter 'daily-evidence-v4g-*.html' |
            Sort-Object Name | Select-Object -Last 1
        $script:h2 = if ($hf) { Get-Content $hf.FullName -Raw } else { '' }
    }
}

AfterAll {
    if ($null -ne $script:MockProc -and -not $script:MockProc.HasExited) {
        Stop-Process -Id $script:MockProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:V4G_PHASE_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:V4G_MOCK_PORT -ErrorAction SilentlyContinue
    if ($null -ne $script:CfgBackup) { Set-Content $script:LocalCfg -Value $script:CfgBackup -Encoding UTF8 }
    else { Remove-Item $script:LocalCfg -Force -ErrorAction SilentlyContinue }
}

Describe 'V4GL-01: phase-1 baseline seeds cleanly' {
    It 'fetches the day-1 campaign from the mock' -Skip:$script:glSkip {
        $script:p1 | Should -Match 'Daily Attestation - 2026-09-05'
    }
    It 'state tracking seeds 3 records with ZERO newly-decided and ZERO re-approved' -Skip:$script:glSkip {
        $script:p1 | Should -Match 'ent=3\(\+3 new, 0 changed, 0 decided, 0 re-approved\)'
    }
    It 'writes the entitlement state DB into the sandbox' -Skip:$script:glSkip {
        $script:StateSeeded | Should -BeTrue
    }
}

Describe 'V4GL-02/03: phase-2 decided day' {
    It 'V4GL-02 detects exactly 1 newly decided and 1 re-approved' -Skip:$script:glSkip {
        $script:p2 | Should -Match 'ent=3\(\+0 new, 2 changed, 1 decided, 1 re-approved\)'
    }
    It 'V4GL-03 renders the Newly Decided PENDING->APPROVE row' -Skip:$script:glSkip {
        $script:h2 | Should -Match 'Alice Alpha'
        $script:h2 | Should -Match '>PENDING<'
    }
    It 'V4GL-03 renders the Re-Approved After Revoke register with both dates' -Skip:$script:glSkip {
        $script:h2 | Should -Match 'Re-Approved After Revoke \(1 items\)'
        $script:h2 | Should -Match 'Bob Bravo'
        $script:h2 | Should -Match '2026-09-05'
        $script:h2 | Should -Match '2026-09-06'
    }
    It 'V4GL-03 excludes the first-seen-approved item from both registers' -Skip:$script:glSkip {
        # Cara appears in the campaign data but must not appear in Newly Decided or
        # Re-Approved (first-seen-already-decided is not an observed transition).
        $ndBlock = [regex]::Match($script:h2, 'Newly Decided.*?</details>', 'Singleline').Value
        $raBlock = [regex]::Match($script:h2, 'Re-Approved After Revoke.*?</details>', 'Singleline').Value
        $ndBlock | Should -Not -Match 'Cara Charlie'
        $raBlock | Should -Not -Match 'Cara Charlie'
    }
}
