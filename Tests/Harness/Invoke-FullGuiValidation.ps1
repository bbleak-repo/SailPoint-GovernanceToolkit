#Requires -Version 5.1
<#
.SYNOPSIS
    Full-stack GUI + CLI validation against the local Pode API MockServer.

.DESCRIPTION
    End-to-end orchestrator that brings up the API MockServer, plugs it into
    a throwaway test config, runs the FlaUI-driven GUI harnesses against a
    real visible WPF dashboard, the CLI scripts, the Playwright visual pass
    and the HTML content validation, then tears the mock back down.

    The user's Config\settings.local.json (and the committed Config\settings.json
    template) are never modified -- the orchestrator writes a temp
    Config\settings.testrun.json and passes its path to each harness via
    -ConfigPath, deleting it on exit.

    Phases (run in order):
        smoke   Tests\Harness\Test-FlaUiSmoke.ps1
        W-02b   Tests\Harness\Test-W02b-GuiInteractive.ps1       (Settings + Campaigns + Evidence tabs)
        W-03b   Tests\Harness\Test-W03b-AuditTabInteractive.ps1  (Audit tab, queries mock)
        W-04    Tests\Harness\Test-W04-DeltaCertInteractive.ps1  (Delta Cert tab, queries mock)
        W-05    Tests\Harness\Test-W05-CliScripts.ps1            (Scripts/* against mock)
        W-06    Tests\Harness\Test-W06-Playwright.ps1            (visual capture; requires Python)
        W-07    Tests\Harness\Test-W07-ReportContent.ps1         (HTML content; consumes W-03b output)

.PARAMETER MockServerPath
    Directory containing Start-MockServer.ps1. Defaults to
    C:\temp\Coding\API-mockserver.

.PARAMETER MockBaseUrl
    URL the mock will be reachable at. Defaults to http://localhost:8080.

.PARAMETER SkipMockStart
    Do not start the mock. Assume it is already running and just validate
    /health. Use when you have started the mock manually in another window.

.PARAMETER SkipMockStop
    Do not stop the mock after tests. Use to leave it running for follow-up
    manual exploration.

.PARAMETER HarnessFilter
    Subset of phases to run, by short name (smoke, W-02b, W-03b, W-04, W-05,
    W-06, W-07). If omitted, all 7 phases run.

.PARAMETER ResultsDir
    Directory to write per-phase results into. Defaults to
    docs\windows-test-rounds\full-gui-validation-<yyyyMMdd-HHmmss>.

.PARAMETER MockReadyTimeoutSec
    How long to wait for the mock's /health endpoint to respond after starting
    the mock process. Default 60s.

.EXAMPLE
    .\Invoke-FullGuiValidation.ps1
    Full end-to-end run with auto-managed mock.

.EXAMPLE
    .\Invoke-FullGuiValidation.ps1 -HarnessFilter smoke,W-02b -SkipMockStop
    Just the smoke and W-02b phases; leave the mock running afterwards.

.EXAMPLE
    .\Invoke-FullGuiValidation.ps1 -SkipMockStart
    Use a mock you started yourself in another terminal.

.OUTPUTS
    Console: per-phase PASS/FAIL summary and overall totals.
    Filesystem: one subdirectory per phase under -ResultsDir, each containing
    the harness's JSONL output, stdout/stderr capture, and screenshots.
    Plus a top-level summary.md.
    Exit code: 0 if every run phase PASSed, non-zero if any phase FAILed or
    crashed.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$MockServerPath = 'C:\temp\Coding\API-mockserver',
    [Parameter()][string]$MockBaseUrl    = 'http://localhost:8080',
    [Parameter()][switch]$SkipMockStart,
    [Parameter()][switch]$SkipMockStop,
    [Parameter()][string[]]$HarnessFilter,
    [Parameter()][string]$ResultsDir,
    [Parameter()][int]$MockReadyTimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
$script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

# ---------- Output dir + helpers ----------

if (-not $ResultsDir) {
    $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ResultsDir = Join-Path $script:ToolkitRoot "docs\windows-test-rounds\full-gui-validation-$stamp"
}
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

$logFile = Join-Path $ResultsDir 'orchestrator.log'
function Log {
    param([string]$Message, [ConsoleColor]$Color = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Log "Toolkit root:    $script:ToolkitRoot" 'White'
Log "Results dir:     $ResultsDir" 'White'
Log "Mock server:     $MockServerPath" 'White'
Log "Mock base URL:   $MockBaseUrl" 'White'

# ---------- Phase registry ----------

$allPhases = [ordered]@{
    'smoke' = @{
        Script    = 'Test-FlaUiSmoke.ps1'
        NeedsMock = $false  # smoke just opens dashboard; doesn't need API
        NeedsSta  = $true
        NeedsConfigPath = $true
        Description = 'FlaUI smoke (window appears, tabs discoverable)'
    }
    'W-02b' = @{
        Script    = 'Test-W02b-GuiInteractive.ps1'
        NeedsMock = $false
        NeedsSta  = $true
        NeedsConfigPath = $true
        Description = 'Settings + Campaigns + Evidence tabs (interactive)'
    }
    'W-03b' = @{
        Script    = 'Test-W03b-AuditTabInteractive.ps1'
        NeedsMock = $true
        NeedsSta  = $true
        NeedsConfigPath = $true
        Description = 'Audit tab end-to-end against mock (interactive)'
    }
    'W-04' = @{
        Script    = 'Test-W04-DeltaCertInteractive.ps1'
        NeedsMock = $true
        NeedsSta  = $true
        NeedsConfigPath = $true
        Description = 'Delta Cert tab buttons + dialogs (interactive)'
    }
    'W-05' = @{
        Script    = 'Test-W05-CliScripts.ps1'
        NeedsMock = $true
        NeedsSta  = $false
        NeedsConfigPath = $false  # W-05 uses default config; not parameterised
        Description = 'CLI scripts against mock'
    }
    'W-06' = @{
        Script    = 'Test-W06-Playwright.ps1'
        NeedsMock = $false  # renders existing HTML
        NeedsSta  = $false
        NeedsConfigPath = $false
        Description = 'Playwright visual capture (needs Python)'
    }
    'W-07' = @{
        Script    = 'Test-W07-ReportContent.ps1'
        NeedsMock = $false  # consumes W-03b output
        NeedsSta  = $false
        NeedsConfigPath = $false
        Description = 'HTML report deep content validation'
    }
}

if ($HarnessFilter) {
    $unknown = $HarnessFilter | Where-Object { -not $allPhases.Contains($_) }
    if ($unknown) {
        throw "Unknown harness name(s): $($unknown -join ', '). Valid: $($allPhases.Keys -join ', ')"
    }
    $phasesToRun = [ordered]@{}
    foreach ($k in $allPhases.Keys) {
        if ($HarnessFilter -contains $k) { $phasesToRun[$k] = $allPhases[$k] }
    }
}
else {
    $phasesToRun = $allPhases
}
Log "Phases to run:   $($phasesToRun.Keys -join ', ')" 'White'

# ---------- Mock lifecycle ----------

$mockProcess = $null
$mockStartedByUs = $false

function Test-MockHealthy {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $r = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($r.status -eq 'ok')
    }
    catch { return $false }
}

function Start-MockIfNeeded {
    if ($SkipMockStart) {
        Log "Skipping mock start (-SkipMockStart). Validating already-running mock at $MockBaseUrl..." 'Yellow'
        if (Test-MockHealthy -Url $MockBaseUrl) {
            Log "  -> mock responsive." 'Green'
            return
        }
        throw "Mock at $MockBaseUrl is not responding to /health and -SkipMockStart was specified."
    }

    if (Test-MockHealthy -Url $MockBaseUrl) {
        Log "Mock already running at $MockBaseUrl -- using as-is (will NOT stop on exit)." 'Yellow'
        $script:SkipMockStop = $true
        return
    }

    $starter = Join-Path $MockServerPath 'Start-MockServer.ps1'
    if (-not (Test-Path $starter)) {
        throw "Start-MockServer.ps1 not found at: $starter (override with -MockServerPath)"
    }

    Log "Starting mock from $starter..." 'Cyan'
    $stdoutLog = Join-Path $ResultsDir 'mock-stdout.log'
    $stderrLog = Join-Path $ResultsDir 'mock-stderr.log'

    $script:mockProcess = Start-Process powershell.exe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$starter`"") `
        -WorkingDirectory $MockServerPath `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError  $stderrLog
    $script:mockStartedByUs = $true
    Log "  mock PID = $($script:mockProcess.Id)" 'Gray'

    # Poll /health until ready
    $deadline = (Get-Date).AddSeconds($MockReadyTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($script:mockProcess.HasExited) {
            $errTail = if (Test-Path $stderrLog) { (Get-Content $stderrLog -Tail 20) -join "`n" } else { '(no stderr)' }
            throw "Mock process exited prematurely with code $($script:mockProcess.ExitCode). Last stderr:`n$errTail"
        }
        if (Test-MockHealthy -Url $MockBaseUrl -TimeoutSec 1) {
            Log "  mock is healthy after $([int]((Get-Date) - $script:mockProcess.StartTime).TotalSeconds)s." 'Green'
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Mock did not become healthy within ${MockReadyTimeoutSec}s. See $stdoutLog / $stderrLog for details."
}

function Stop-MockIfStarted {
    if (-not $script:mockStartedByUs) {
        Log "Leaving mock running (we did not start it, or -SkipMockStop set)." 'Yellow'
        return
    }
    if ($null -eq $script:mockProcess) { return }
    if ($script:mockProcess.HasExited)  { return }

    Log "Stopping mock (PID $($script:mockProcess.Id))..." 'Cyan'
    try {
        # Pode catches Ctrl+C cleanly; try graceful first
        $script:mockProcess.CloseMainWindow() | Out-Null
        $script:mockProcess.WaitForExit(5000) | Out-Null
        if (-not $script:mockProcess.HasExited) { $script:mockProcess.Kill() }
        Log "  stopped. Exit code: $($script:mockProcess.ExitCode)" 'Gray'
    }
    catch {
        Log "  stop error: $($_.Exception.Message)" 'Red'
    }
}

function Test-MockOAuth {
    param([string]$Url)
    $body = "grant_type=client_credentials&client_id=test&client_secret=test"
    try {
        $r = Invoke-RestMethod -Uri "$Url/oauth/token" -Method POST -Body $body `
             -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 5 -ErrorAction Stop
        if ($r.access_token) { return $true }
        return $false
    }
    catch { return $false }
}

# ---------- Test config ----------

$testConfigPath = Join-Path $script:ToolkitRoot 'Config\settings.testrun.json'

function Write-TestConfig {
    # Take the committed Config\settings.json as a base (it has every section
    # populated) and overlay the mock URLs + permissive Safety so the tests
    # can run CompleteCampaign / WhatIf=false flows against the mock.
    $base = Get-Content (Join-Path $script:ToolkitRoot 'Config\settings.json') -Raw | ConvertFrom-Json

    $base.Global.EnvironmentName              = 'MOCK-TESTRUN'
    $base.Authentication.ConfigFile.TenantUrl       = $MockBaseUrl
    $base.Authentication.ConfigFile.OAuthTokenUrl   = "$MockBaseUrl/oauth/token"
    $base.Authentication.ConfigFile.ClientId        = 'mock-test-client'
    $base.Authentication.ConfigFile.ClientSecret    = 'mock-test-secret'
    $base.Api.BaseUrl                                = "$MockBaseUrl/v3"
    $base.Safety.RequireWhatIfOnProd                 = $false
    $base.Safety.AllowCompleteCampaign               = $true
    if (-not ($base.PSObject.Properties.Name -contains 'DeltaCert')) {
        $base | Add-Member NoteProperty DeltaCert ([PSCustomObject]@{})
    }
    $base.DeltaCert.SourceIds                       = @('src-ad-001')
    $base.DeltaCert.FallbackReviewerIdentityId      = 'id-orphan-1'

    ($base | ConvertTo-Json -Depth 20) | Set-Content -Path $testConfigPath -Encoding utf8
    Log "Test config written: $testConfigPath" 'Green'
}

function Remove-TestConfig {
    if (Test-Path $testConfigPath) {
        Remove-Item $testConfigPath -Force -ErrorAction SilentlyContinue
        Log "Test config removed." 'Gray'
    }
}

# ---------- Harness runner ----------

function Invoke-Harness {
    param([string]$Name, [hashtable]$Spec)

    $phaseDir = Join-Path $ResultsDir $Name
    New-Item -ItemType Directory -Path $phaseDir -Force | Out-Null
    $jsonl  = Join-Path $phaseDir 'results.jsonl'
    $stdout = Join-Path $phaseDir 'stdout.log'
    $stderr = Join-Path $phaseDir 'stderr.log'
    $shots  = Join-Path $phaseDir 'screenshots'

    $scriptPath = Join-Path $script:ToolkitRoot "Tests\Harness\$($Spec.Script)"
    if (-not (Test-Path $scriptPath)) {
        Log "  $Name : SKIP (script not found: $scriptPath)" 'Yellow'
        return [pscustomobject]@{ Name=$Name; Result='SKIP'; Pass=0; Fail=0; Total=0; DurationSec=0; Note='Script missing' }
    }

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($Spec.NeedsSta) { $psArgs = @('-STA') + $psArgs }
    $psArgs += @('-File', $scriptPath)

    # Per-script parameter mapping. Each harness's param block has been
    # surveyed; the orchestrator passes what each script actually accepts.
    switch ($Name) {
        'smoke'  { $psArgs += @('-JsonlPath', $jsonl, '-ScreenshotPath', (Join-Path $shots 'smoke.png')) }
        'W-02b'  { $psArgs += @('-ConfigPath', $testConfigPath, '-JsonlPath', $jsonl, '-ScreenshotDir', $shots) }
        'W-03b'  { $psArgs += @('-ConfigPath', $testConfigPath, '-JsonlPath', $jsonl, '-ScreenshotDir', $shots) }
        'W-04'   { $psArgs += @('-ConfigPath', $testConfigPath, '-JsonlPath', $jsonl, '-ScreenshotDir', $shots) }
        'W-05'   { $psArgs += @('-JsonlPath', $jsonl, '-LogDir', $phaseDir) }
        'W-06'   { $psArgs += @('-JsonlPath', $jsonl, '-ScreenshotDir', $shots) }
        'W-07'   { $psArgs += @('-JsonlPath', $jsonl) }
    }

    Log "  $Name : starting ($($Spec.Description))" 'Cyan'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Use [Process]::Start directly with ProcessStartInfo so $proc.ExitCode is
    # reliably populated. Start-Process -PassThru + -RedirectStandard* has a
    # long-standing PowerShell bug where ExitCode can come back as $null.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = (Get-Command powershell.exe).Source
    $psi.Arguments              = ($psArgs | ForEach-Object {
        if ($_ -match '\s' -and -not $_.StartsWith('"')) { "`"$_`"" } else { $_ }
    }) -join ' '
    $psi.WorkingDirectory       = $script:ToolkitRoot
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    # Read both streams async to avoid buffer-fill deadlock for chatty harnesses.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $sw.Stop()
    [System.IO.File]::WriteAllText($stdout, $outTask.Result)
    [System.IO.File]::WriteAllText($stderr, $errTask.Result)
    $exit = $proc.ExitCode

    # Parse JSONL for pass/fail summary
    $pass = 0; $fail = 0; $total = 0
    if (Test-Path $jsonl) {
        foreach ($line in (Get-Content $jsonl)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json -ErrorAction Stop
                if ($obj.summary -eq $true) {
                    if ($null -ne $obj.pass) { $pass = [int]$obj.pass }
                    if ($null -ne $obj.fail) { $fail = [int]$obj.fail }
                }
                elseif ($null -ne $obj.result) {
                    $total++
                    if ($obj.result -eq 'PASS') { $pass++ }
                    elseif ($obj.result -eq 'FAIL') { $fail++ }
                }
            } catch { }
        }
    }
    if ($total -eq 0) { $total = $pass + $fail }

    $result = if ($exit -ne 0 -or $fail -gt 0) { 'FAIL' } else { 'PASS' }
    Log ("  {0} : {1}  ({2} pass, {3} fail, exit {4}, {5:N1}s)" -f
        $Name, $result, $pass, $fail, $exit, $sw.Elapsed.TotalSeconds) `
        $(if ($result -eq 'PASS') { 'Green' } else { 'Red' })

    return [pscustomobject]@{
        Name        = $Name
        Result      = $result
        Pass        = $pass
        Fail        = $fail
        Total       = $total
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ExitCode    = $exit
        Note        = ''
    }
}

# ---------- Main flow ----------

$results = New-Object System.Collections.Generic.List[object]
$overallStartedAt = Get-Date

try {
    Log '=== Mock prerequisite ===' 'White'
    Start-MockIfNeeded

    Log '=== Validating mock ===' 'White'
    if (-not (Test-MockHealthy -Url $MockBaseUrl))      { throw "/health is not OK at $MockBaseUrl" }
    if (-not (Test-MockOAuth   -Url $MockBaseUrl))      { throw "/oauth/token did not return access_token at $MockBaseUrl" }
    Log "  /health  : OK" 'Green'
    Log "  /oauth/token : OK (access_token returned)" 'Green'

    Log '=== Writing test config ===' 'White'
    Write-TestConfig

    Log '=== Running harnesses ===' 'White'
    foreach ($name in $phasesToRun.Keys) {
        $r = Invoke-Harness -Name $name -Spec $phasesToRun[$name]
        $results.Add($r)
    }
}
finally {
    Log '=== Cleanup ===' 'White'
    Remove-TestConfig
    Stop-MockIfStarted
}

# ---------- Summary ----------

$totalDuration = (Get-Date) - $overallStartedAt
$passCount = @($results | Where-Object Result -eq 'PASS').Count
$failCount = @($results | Where-Object Result -eq 'FAIL').Count
$skipCount = @($results | Where-Object Result -eq 'SKIP').Count
$testPassTotal = ($results | Measure-Object -Property Pass -Sum).Sum
$testFailTotal = ($results | Measure-Object -Property Fail -Sum).Sum

$summary = @()
$summary += '# Full GUI Validation Summary'
$summary += ''
$summary += ('**Started:**  ' + $overallStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))
$summary += ('**Duration:** ' + ('{0:N1} min' -f $totalDuration.TotalMinutes))
$summary += ('**Mock URL:** ' + $MockBaseUrl)
$summary += ('**Results:**  ' + $ResultsDir)
$summary += ''
$summary += '| Phase | Result | Tests Pass | Tests Fail | Duration | Exit |'
$summary += '|-------|--------|-----------:|-----------:|---------:|-----:|'
foreach ($r in $results) {
    $summary += ('| {0} | {1} | {2} | {3} | {4}s | {5} |' -f $r.Name, $r.Result, $r.Pass, $r.Fail, $r.DurationSec, $r.ExitCode)
}
$summary += ''
$summary += ('**Phase totals:** {0} PASS / {1} FAIL / {2} SKIP' -f $passCount, $failCount, $skipCount)
$summary += ('**Test totals:**  {0} pass / {1} fail across all phases' -f $testPassTotal, $testFailTotal)

$summaryPath = Join-Path $ResultsDir 'summary.md'
$summary -join "`r`n" | Set-Content -Path $summaryPath -Encoding utf8

Write-Host ''
Write-Host '================ FULL GUI VALIDATION ================' -ForegroundColor White
$summary | ForEach-Object { Write-Host $_ }
Write-Host '=====================================================' -ForegroundColor White
Write-Host "Summary written: $summaryPath"

exit $(if ($failCount -gt 0) { 1 } else { 0 })
