#Requires -Version 5.1
<#
.SYNOPSIS
    W-09b -- Interactive FlaUI backfill for the W-09 Adaptive-Reports structural
    tests. Drives a REAL visible WPF window via Tests\Harness\SP.UiTest.psm1
    (FlaUI 4.0 UIA3): navigates the flat Adaptive Reports tab, asserts the report
    options/components/baselines resolve, clicks Generate against the mock, waits
    for the status label to report success, asserts a new HTML report file appears
    in the output directory, exercises the Open Report / Open Folder round-trip,
    and captures a screenshot for every step.

.DESCRIPTION
    Run as:
        powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W09b-AdaptiveTabInteractive.ps1 `
            -JsonlPath docs\windows-test-rounds\WG-09b-results.jsonl

    Emits one compact JSON line per test, terminated by a {summary} line.
    Exit 0 if no FAIL (BLOCKED does not fail). Per-test screenshots land in
    docs\windows-test-rounds\WG-09b-<id>.png.

.NOTES
    AUTHOR-ONLY / DEFERRED RUN (AR-19): authored by the headless loop but NOT
    executed there. A human runs it in a live Windows STA GUI session with the
    mock Pode server at http://localhost:8080 as the final acceptance gate.

    Requires the mock Pode server at $MockBaseUrl. If unreachable, all
    live-dependent tests (WG-09-11 through WG-09-14) are marked BLOCKED and
    Generate will not produce a report.

    DO NOT run under a non-STA host; WPF + FlaUI UIA3 require STA, and the
    dashboard's own re-launcher would spawn a second STA process that FlaUI
    cannot attach to (the harness passes -NoIsolation via Start-SPDashboardForTest).

    Asserts against the RUNTIME Gui\MainWindow.xaml Adaptive Reports tab -- a FLAT
    Grid (AdaptiveReportsTabContent) with NO nested TabControl and NO sub-tabs
    (unlike the SDK Features tab). Every -AutomationId below resolves because WPF
    surfaces each x:Name as the UIA AutomationId (exactly as W-08b does for the
    SDK controls); the W-09 structure test green-lights the same control set.
    This test walks the READ/generate happy path only (configure -> Generate ->
    file appears -> Open Report); it does NOT exercise destructive paths (the
    Adaptive Reports tab has none), so no Safety/What-If confirmation MessageBox
    can block the run.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$JsonlPath,
    [Parameter()][string]$ScreenshotDir,
    # URL where the mock Pode server is reachable. AR-19 defaults to the
    # locally-running mock per the backlog/plan; overridable for a remote mock.
    [Parameter()][string]$MockBaseUrl = 'http://localhost:8080',
    # Budget for any step that triggers a bridge/runspace call. 2000ms was
    # demonstrated flaky for runspace-backed actions in W-03b; 5000ms de-flakes
    # them. Always paired with a polling finder, never a fixed Start-Sleep as
    # the wait mechanism.
    [Parameter()][int]$RefreshTimeoutMs = 5000
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Error "Run this script under -STA (powershell.exe -STA -File ...)."
    exit 2
}

$harnessRoot = $PSScriptRoot
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $harnessRoot '..\..'))
if (-not $ConfigPath)    { $ConfigPath    = Join-Path $toolkitRoot 'Config\settings.json' }
if (-not $ScreenshotDir) { $ScreenshotDir = Join-Path $toolkitRoot 'docs\windows-test-rounds' }
if (-not $JsonlPath)     { $JsonlPath     = Join-Path $ScreenshotDir 'WG-09b-results.jsonl' }
if (-not (Test-Path $ScreenshotDir)) { New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null }
Set-Content -Path $JsonlPath -Value '' -Encoding utf8

Import-Module (Join-Path $harnessRoot 'SP.UiTest.psm1') -Force

# ----- Result sink ----------------------------------------------------------

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $Id; result = $Result; note = $Note })
    Write-Host $line
    Add-Content -Path $JsonlPath -Value $line -Encoding utf8
}

# ----- Small UI helpers -----------------------------------------------------

function Invoke-SPUiButton {
    <#
    .SYNOPSIS
        Invokes a Button via the Invoke pattern, falling back to Click().
    #>
    param([Parameter(Mandatory)]$Button)
    try { $Button.Patterns.Invoke.Pattern.Invoke() }
    catch { $Button.Click() }
}

function Set-SPUiCheckTo {
    <#
    .SYNOPSIS
        Toggles a CheckBox/CheckBox-cell to the desired ON/OFF state and polls
        until the ToggleState matches or the deadline elapses.
    #>
    param([Parameter(Mandatory)]$CheckBox, [Parameter(Mandatory)][bool]$Desired, [int]$TimeoutMs = 3000)
    $want = if ($Desired) { 'On' } else { 'Off' }
    $getState = {
        param($el)
        try { return [string]$el.Patterns.Toggle.Pattern.ToggleState.Value } catch { return $null }
    }
    $cur = & $getState $CheckBox
    if ($cur -ne $want) {
        try { $CheckBox.Patterns.Toggle.Pattern.Toggle() }
        catch { try { $CheckBox.Click() } catch { } }
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((& $getState $CheckBox) -eq $want) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return ((& $getState $CheckBox) -eq $want)
}

function Get-SPUiToggleState {
    <#
    .SYNOPSIS
        Returns 'On'/'Off'/'Indeterminate' for an element exposing the Toggle
        pattern, or $null if unavailable.
    #>
    param([Parameter(Mandatory)]$Element)
    try { return [string]$Element.Patterns.Toggle.Pattern.ToggleState.Value } catch { return $null }
}

# ----- Mock-up check (BLOCKED guard) ---------------------------------------

$mockUp = $false
$mockProbeError = $null
try {
    # Invoke-RestMethod, not Invoke-WebRequest: the latter prompts for proxy creds
    # under -NonInteractive STA hosts even when no proxy auth is actually needed.
    $h = Invoke-RestMethod -Uri "$MockBaseUrl/health" -TimeoutSec 5 -ErrorAction Stop
    if ($h -and $h.status -eq 'ok') { $mockUp = $true }
} catch { $mockProbeError = $_.Exception.Message; $mockUp = $false }

# All the live-dependent step IDs, for the BLOCKED-everything fast path.
$liveStepIds = @('WG-09-11','WG-09-12','WG-09-13','WG-09-14')

# ----- Derive the output dir the production code writes to ------------------
# Resolve-AdaptiveOutputPath (SP.MainWindow.psm1) is private to the GUI module,
# so the harness re-derives the SAME path the production code does: read the
# config's .Audit.OutputPath (fallback '.\Audit'), resolve relative against the
# toolkit root, Join 'adaptive', GetFullPath.
$outDir = $null
try {
    $auditOut = '.\Audit'
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg -and $cfg.PSObject.Properties.Name -contains 'Audit' -and
            $null -ne $cfg.Audit -and
            $cfg.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
            $auditOut = $cfg.Audit.OutputPath
        }
    }
    if (-not [System.IO.Path]::IsPathRooted($auditOut)) {
        $auditOut = Join-Path $toolkitRoot $auditOut
    }
    $outDir = [System.IO.Path]::GetFullPath((Join-Path $auditOut 'adaptive'))
} catch {
    $outDir = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot 'Audit\adaptive'))
}

# ----- Test run -------------------------------------------------------------

$ui = $null
try {

    if (-not $mockUp) {
        $blockNote = "Mock at $MockBaseUrl unreachable ($mockProbeError); Generate will not produce a report."
        foreach ($id in $liveStepIds) { Add-Result $id 'BLOCKED' $blockNote }
    }
    else {
        # Launch the dashboard once; all steps share the window. Stop in finally.
        try {
            $ui = Start-SPDashboardForTest -ConfigPath $ConfigPath -TimeoutSeconds 45
        }
        catch {
            $blockNote = "Dashboard launch/attach failed: $($_.Exception.Message)"
            foreach ($id in $liveStepIds) { Add-Result $id 'BLOCKED' $blockNote }
            throw
        }

        # ----- WG-09-11: Navigate to Adaptive Reports tab; anchor combo renders
        $tabReady = $false
        try {
            $tab = Find-SPUiTab -Window $ui.Window -Header 'Adaptive Reports'
            $tab.Select() | Out-Null
            # Prove the tab content actually rendered by resolving an anchor
            # control (AdaptiveReportsAnchorCombo, x:Name'd at MainWindow.xaml).
            $anchorCombo = Find-SPUiElement -Root $ui.Window -AutomationId 'AdaptiveReportsAnchorCombo' -TimeoutMs $RefreshTimeoutMs
            Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-09b-11-adaptive-tab.png') | Out-Null
            if ($anchorCombo) {
                $tabReady = $true
                Add-Result 'WG-09-11' 'PASS' "Adaptive Reports tab selected; AdaptiveReportsAnchorCombo present"
            } else {
                Add-Result 'WG-09-11' 'FAIL' "AdaptiveReportsAnchorCombo not found after selecting Adaptive Reports tab"
            }
        }
        catch {
            Add-Result 'WG-09-11' 'FAIL' "Navigation failed: $($_.Exception.Message)"
        }

        # ----- WG-09-12: Configure selections (anchor/theme/days-back + >=1 component)
        $configOk = $false
        try {
            if (-not $tabReady) {
                Add-Result 'WG-09-12' 'BLOCKED' "Adaptive tab not ready (WG-09-11)"
            } else {
                # Anchor combo defaults to SelectedIndex=0=Entitlement (XAML); we
                # leave the default and just assert it resolves.
                $anchorCombo = Find-SPUiElement -Root $ui.Window -AutomationId 'AdaptiveReportsAnchorCombo' -TimeoutMs $RefreshTimeoutMs
                # Theme combo defaults to light (idx0); assert it resolves.
                $themeCombo  = Find-SPUiElement -Root $ui.Window -AutomationId 'AdaptiveReportsThemeCombo'  -TimeoutMs $RefreshTimeoutMs
                # Days-back box defaults Text='90'; assert it resolves (leave default).
                $daysBox     = Find-SPUiElement -Root $ui.Window -AutomationId 'AdaptiveReportsDaysBackBox' -TimeoutMs $RefreshTimeoutMs

                # Ensure at least one component is checked. The defaults
                # (ChkArCompKpiCards/ChkArCompTopN/ChkArCompGroupTable) are
                # IsChecked=True so the 'select at least one' guard in
                # Invoke-GuiAdaptiveReport is already satisfied; make it explicit
                # and idempotent via Set-SPUiCheckTo.
                $chkKpi = Find-SPUiElement -Root $ui.Window -AutomationId 'ChkArCompKpiCards' -ControlType 'CheckBox' -TimeoutMs $RefreshTimeoutMs
                Set-SPUiCheckTo -CheckBox $chkKpi -Desired $true -TimeoutMs $RefreshTimeoutMs | Out-Null
                # Optionally also pick one baseline (Inventory) for a richer run.
                try {
                    $chkBase = Find-SPUiElement -Root $ui.Window -AutomationId 'ChkArBaseInventory' -ControlType 'CheckBox' -TimeoutMs 2000
                    if ($chkBase) { Set-SPUiCheckTo -CheckBox $chkBase -Desired $true -TimeoutMs $RefreshTimeoutMs | Out-Null }
                } catch { }

                Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-09b-12-config.png') | Out-Null

                $kpiState   = Get-SPUiToggleState -Element $chkKpi
                $resolved   = ($anchorCombo -and $themeCombo -and $daysBox)
                if ($resolved -and $kpiState -eq 'On') {
                    $configOk = $true
                    Add-Result 'WG-09-12' 'PASS' "Anchor/Theme/DaysBack resolved; ChkArCompKpiCards ToggleState=On (>=1 component selected)"
                } else {
                    Add-Result 'WG-09-12' 'FAIL' ("Configure failed: anchor={0} theme={1} daysBack={2} kpiState={3}" -f [bool]$anchorCombo, [bool]$themeCombo, [bool]$daysBox, $kpiState)
                }
            }
        }
        catch {
            Add-Result 'WG-09-12' 'FAIL' "Configure selections failed: $($_.Exception.Message)"
        }

        # ----- WG-09-13: Generate + report file appears + opens (core assertion)
        $generateOk = $false
        try {
            if (-not $configOk) {
                Add-Result 'WG-09-13' 'BLOCKED' "Selections not configured (WG-09-12)"
            } else {
                # Snapshot the output dir BEFORE clicking so the new file is
                # unambiguous. Output dir = the SAME path Resolve-AdaptiveOutputPath
                # returns ({Audit.OutputPath}\adaptive resolved against toolkit root).
                $before = @()
                if (Test-Path $outDir) {
                    $before = @(Get-ChildItem -Path $outDir -Filter *.html -ErrorAction SilentlyContinue)
                }
                $beforeNames = @($before | ForEach-Object { $_.Name })

                $btn = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnArGenerate' -ControlType 'Button' -TimeoutMs $RefreshTimeoutMs
                Invoke-SPUiButton -Button $btn

                # Wait for completion via the status label, NOT a fixed sleep.
                # The runspace dispatcher sets AdaptiveReportsStatusLabel.Text to
                # 'Generated N report(s).' on success (SP.MainWindow.psm1) or
                # 'Adaptive report failed: ...' on failure. Report generation hits
                # the live mock + multiple API round-trips, so allow a generous
                # 90s deadline. This mirrors W-08b's status-label polling pattern.
                $statusText = ''
                $statusDeadline = (Get-Date).AddMilliseconds(90000)
                while ((Get-Date) -lt $statusDeadline) {
                    try {
                        $lbl = Find-SPUiElement -Root $ui.Window -AutomationId 'AdaptiveReportsStatusLabel' -TimeoutMs 800
                        $statusText = if ($null -ne $lbl) { $lbl.Name } else { '' }
                    } catch { }
                    if ($statusText -match '^Generated \d+ report' -or $statusText -match '(?i)failed') { break }
                    Start-Sleep -Milliseconds 500
                }

                $statusSuccess = ($statusText -match '^Generated \d+ report')

                # On success-text, poll the output dir for a NEW *.html (present
                # now but not in $before). The runspace flushes the file via
                # Wait-SPReportFileReady before Start-Process, so allow ~10s.
                $newFiles = @()
                if ($statusSuccess) {
                    $fileDeadline = (Get-Date).AddMilliseconds(10000)
                    while ((Get-Date) -lt $fileDeadline) {
                        if (Test-Path $outDir) {
                            $now = @(Get-ChildItem -Path $outDir -Filter *.html -ErrorAction SilentlyContinue)
                            $newFiles = @($now | Where-Object { $beforeNames -notcontains $_.Name })
                            if ($newFiles.Count -gt 0) { break }
                        }
                        Start-Sleep -Milliseconds 500
                    }
                }

                Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-09b-13-generate.png') | Out-Null

                # PASS requires (a) the status label shows 'Generated N report(s).'
                # AND (b) at least one new HTML file appeared in $outDir. The
                # primary file is adaptive-Entitlement-<stamp>.html; baseline files
                # are <key>-<stamp>.html -- any new *.html is acceptable. Production
                # auto-opens the report via Start-Process; the harness asserts the
                # FILE appears rather than a browser window (cross-process browser
                # detection is out of scope -- same soft-boundary reasoning as the
                # W-08b tooltip note).
                if ($statusSuccess -and $newFiles.Count -gt 0) {
                    $generateOk = $true
                    $newNames = ($newFiles | ForEach-Object { $_.Name }) -join ', '
                    Add-Result 'WG-09-13' 'PASS' ("Status '{0}'; {1} new HTML report(s) in '{2}': {3} (production auto-opens via Start-Process -- file-presence assertion, not browser-window)" -f $statusText, $newFiles.Count, $outDir, $newNames)
                } elseif ($statusSuccess) {
                    Add-Result 'WG-09-13' 'FAIL' ("Status reported success ('{0}') but no new *.html appeared in '{1}' within 10s" -f $statusText, $outDir)
                } else {
                    Add-Result 'WG-09-13' 'FAIL' ("Generate did not report success within 90s; last status='{0}'" -f $statusText)
                }
            }
        }
        catch {
            Add-Result 'WG-09-13' 'FAIL' "Generate failed: $($_.Exception.Message)"
        }

        # ----- WG-09-14: Open Report + Open Folder round-trip (soft-PASS)
        try {
            if (-not $generateOk) {
                Add-Result 'WG-09-14' 'BLOCKED' "Generate did not succeed (WG-09-13)"
            } else {
                # After a successful Generate, $script:LastAdaptiveReportPath is set
                # so BtnArOpenReport re-opens it. Invoke-GuiAdaptiveOpenReport sets
                # the GLOBAL StatusBarText to 'No report generated yet.' only when no
                # report exists -- assert (best-effort soft-PASS) that this failure
                # text does NOT appear after clicking Open Report.
                $btnOpenReport = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnArOpenReport' -ControlType 'Button' -TimeoutMs $RefreshTimeoutMs
                Invoke-SPUiButton -Button $btnOpenReport

                # Give the handler a beat, then read the global status bar text.
                $noReportErr = $false
                $statusBarText = ''
                $deadline = (Get-Date).AddMilliseconds(4000)
                while ((Get-Date) -lt $deadline) {
                    try {
                        $sb = Find-SPUiElement -Root $ui.Window -AutomationId 'StatusBarText' -TimeoutMs 600
                        $statusBarText = if ($null -ne $sb) { $sb.Name } else { '' }
                    } catch { }
                    if ($statusBarText -match 'No report generated yet') { $noReportErr = $true; break }
                    Start-Sleep -Milliseconds 300
                }

                # Also exercise BtnArOpenFolder (opens explorer to $outDir; no
                # assertable UIA state -- screenshot-only soft note).
                $folderInvoked = $false
                try {
                    $btnOpenFolder = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnArOpenFolder' -ControlType 'Button' -TimeoutMs 2000
                    if ($btnOpenFolder) { Invoke-SPUiButton -Button $btnOpenFolder; $folderInvoked = $true }
                } catch { }

                Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-09b-14-open-report.png') | Out-Null

                if (-not $noReportErr) {
                    Add-Result 'WG-09-14' 'PASS' ("Open Report invoked without the 'No report generated yet.' error (status='{0}'); Open Folder invoked={1} (explorer open is a soft note -- no UIA assertion)" -f $statusBarText, $folderInvoked)
                } else {
                    Add-Result 'WG-09-14' 'FAIL' "Open Report flipped status to 'No report generated yet.' despite a prior successful Generate (LastAdaptiveReportPath not set)"
                }
            }
        }
        catch {
            Add-Result 'WG-09-14' 'FAIL' "Open Report round-trip failed: $($_.Exception.Message)"
        }
    }

}
finally {
    if ($ui) {
        Stop-SPDashboardForTest -UiContext $ui
    }
}

$pass    = @($results | Where-Object result -eq 'PASS').Count
$fail    = @($results | Where-Object result -eq 'FAIL').Count
$blocked = @($results | Where-Object result -eq 'BLOCKED').Count
$summary = ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = ($pass + $fail + $blocked)
})
Write-Host $summary
Add-Content -Path $JsonlPath -Value $summary -Encoding utf8
exit $(if ($fail -eq 0) { 0 } else { 1 })
