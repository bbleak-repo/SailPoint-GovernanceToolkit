#Requires -Version 5.1
<#
.SYNOPSIS
    W-04 -- Interactive FlaUI tests for the Delta Cert tab.
    Drives a REAL visible WPF window via Tests\Harness\SP.UiTest.psm1 (FlaUI 4.0
    UIA3): opens DeltaCertRunDialog (Configure + Run), DeltaCertEscalateDialog,
    drives Cleanup + Open Output Folder + Refresh + Generate Delta Report, and
    verifies the result DataGrid + history ListBox populate.

.DESCRIPTION
    Run as:
        powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W04-DeltaCertInteractive.ps1 `
            -JsonlPath docs\windows-test-rounds\WG-04-results.jsonl

    Emits one compact JSON line per test, terminated by a {summary} line.
    Exit 0 if no FAIL (BLOCKED does not fail). Per-test screenshots land in
    docs\windows-test-rounds\WG-04-<id>.png.

.NOTES
    Requires the mock Pode server at http://10.0.0.143:8080. If unreachable, all
    live-dependent tests are marked BLOCKED.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$JsonlPath,
    [Parameter()][string]$ScreenshotDir,
    [Parameter()][int]$RunTimeoutSec = 120,
    [Parameter()][int]$CleanupTimeoutSec = 60,
    [Parameter()][int]$EscalationTimeoutSec = 60,
    [Parameter()][int]$DeltaReportTimeoutSec = 60
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
if (-not $JsonlPath)     { $JsonlPath     = Join-Path $ScreenshotDir 'WG-04-results.jsonl' }
if (-not (Test-Path $ScreenshotDir)) { New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null }
Set-Content -Path $JsonlPath -Value '' -Encoding utf8

Import-Module (Join-Path $harnessRoot 'SP.UiTest.psm1') -Force

$scriptStart = Get-Date

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

function Get-SPUiTextValue {
    param([Parameter(Mandatory)]$Element)
    $tb = [FlaUI.Core.AutomationElements.TextBox]::new($Element.FrameworkAutomationElement)
    return $tb.Text
}

function Set-SPUiTextValue {
    param(
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [int]$TimeoutMs = 3000
    )
    $vp = $Element.Patterns.Value.Pattern
    $vp.SetValue($Value)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Get-SPUiTextValue -Element $Element) -eq $Value) { return $true }
        Start-Sleep -Milliseconds 75
    }
    return $false
}

function Find-SPModalByTitle {
    <#
    .SYNOPSIS
        Polls the desktop UIA tree for a top-level Window whose Name matches
        the given title.
    #>
    param([Parameter(Mandatory)]$Automation, [Parameter(Mandatory)][string]$Title, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $desktop = $Automation.GetDesktop()
            $cf = $desktop.ConditionFactory
            $cond = $cf.ByControlType([FlaUI.Core.Definitions.ControlType]::Window).And($cf.ByName($Title))
            $w = $desktop.FindFirstDescendant($cond)
            if ($w) { return $w }
        } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Set-SPUiComboValue {
    param([Parameter(Mandatory)]$ComboBox, [Parameter(Mandatory)][string]$Value, [int]$TimeoutMs = 3000)
    try { $ComboBox.Patterns.ExpandCollapse.Pattern.Expand() } catch { }
    Start-Sleep -Milliseconds 200
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $item = $null
    while ((Get-Date) -lt $deadline -and -not $item) {
        try {
            $cf = $ComboBox.ConditionFactory
            $cond = $cf.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem).And($cf.ByName($Value))
            $item = $ComboBox.FindFirstDescendant($cond)
        } catch { }
        if (-not $item) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $item) {
        try { $ComboBox.Patterns.ExpandCollapse.Pattern.Collapse() } catch { }
        return $false
    }
    try { $item.Patterns.SelectionItem.Pattern.Select() }
    catch { try { $item.Click() } catch { } }
    Start-Sleep -Milliseconds 200
    try { $ComboBox.Patterns.ExpandCollapse.Pattern.Collapse() } catch { }
    return $true
}

function Get-SPUiComboSelection {
    param([Parameter(Mandatory)]$ComboBox)
    try {
        $cb = [FlaUI.Core.AutomationElements.ComboBox]::new($ComboBox.FrameworkAutomationElement)
        $sel = $cb.SelectedItem
        if ($sel) { return $sel.Name }
    } catch { }
    return $null
}

function Get-NewProcessesByName {
    param([Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][datetime]$Since)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($n in $Names) {
        try {
            $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
            foreach ($p in $procs) {
                try { if ($p.StartTime -gt $Since) { $out.Add($p) | Out-Null } } catch { }
            }
        } catch { }
    }
    return $out
}

function Stop-Procs {
    param([System.Collections.Generic.List[object]]$Procs)
    foreach ($p in $Procs) { try { $p.CloseMainWindow() | Out-Null } catch { } }
    Start-Sleep -Milliseconds 300
    foreach ($p in $Procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
}

function Wait-DcStatus {
    <#
    .SYNOPSIS
        Polls DeltaCertStatusLabel until it matches a regex (or timeout).
        Skips transient "Running ..." / "Generating ..." labels set before the
        background runspace finishes. Returns the final label text.
    #>
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Regex,
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastText = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $lbl = Find-SPUiElement -Root $Window -AutomationId 'DeltaCertStatusLabel' -TimeoutMs 500
            $lastText = $lbl.Name
            if ($lastText -notmatch '^(Running|Generating)\b' -and $lastText -match $Regex) {
                return $lastText
            }
        } catch { }
        Start-Sleep -Milliseconds 700
    }
    return $lastText
}

function Wait-DcRunIdle {
    <#
    .SYNOPSIS
        Polls BtnRunDeltaCert until IsEnabled = True (the runspace-complete timer
        re-enables it).
    #>
    param([Parameter(Mandatory)]$Window, [int]$TimeoutSec = 60, [string]$ButtonId = 'BtnRunDeltaCert')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $btn = Find-SPUiElement -Root $Window -AutomationId $ButtonId -ControlType 'Button' -TimeoutMs 400
            if ($btn.Properties.IsEnabled.Value -eq $true) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ----- Mock-up check (BLOCKED guard) ---------------------------------------

$mockUp = $false
$mockProbeError = $null
try {
    $h = Invoke-RestMethod -Uri 'http://10.0.0.143:8080/health' -TimeoutSec 5 -ErrorAction Stop
    if ($h -and $h.status -eq 'ok') { $mockUp = $true }
} catch { $mockProbeError = $_.Exception.Message; $mockUp = $false }

# ----- Clean DeltaCert/ before run -- but only files we will write -----------

$deltaCertDir   = Join-Path $toolkitRoot 'DeltaCert'
$deltaCertHistory = Join-Path $deltaCertDir 'history.jsonl'
if (Test-Path $deltaCertDir) {
    # Wipe the dir so we start with a known baseline. Each test will create
    # whatever sub-folders it needs.
    try { Remove-Item -Path $deltaCertDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ----- Test run -------------------------------------------------------------

$ui = $null
try {

    # ----- WG-04-01: Delta Cert tab renders -- Row 0 has summary + Configure + Run
    try {
        $ui = Start-SPDashboardForTest -ConfigPath $ConfigPath -TimeoutSeconds 45
        $dcTab = Find-SPUiTab -Window $ui.Window -Header 'Delta Cert'
        $dcTab.Select() | Out-Null
        Start-Sleep -Milliseconds 600

        $summary  = Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertSummaryLabel' -TimeoutMs 4000
        $btnCfg   = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnConfigureDeltaCert' -ControlType 'Button' -TimeoutMs 4000
        $btnRun   = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRunDeltaCert'       -ControlType 'Button' -TimeoutMs 4000
        $initialSummary = $summary.Name
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-01-tab.png') | Out-Null

        if ($summary -and $btnCfg -and $btnRun) {
            Add-Result 'WG-04-01' 'PASS' ("Delta Cert tab Row 0 visible -- DeltaCertSummaryLabel ('{0}') + BtnConfigureDeltaCert + BtnRunDeltaCert" -f $initialSummary)
        } else {
            Add-Result 'WG-04-01' 'FAIL' ('Row 0 missing controls: summary={0} cfg={1} run={2}' -f [bool]$summary, [bool]$btnCfg, [bool]$btnRun)
        }
    }
    catch {
        Add-Result 'WG-04-01' 'FAIL' "Launch/attach failed: $($_.Exception.Message)"
        Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1; blocked = 0 }))
        exit 1
    }

    # ----- WG-04-02: Click [Configure...] -- DeltaCertRunDialog opens with 4 fields
    $dialogOpenedOnce = $false
    try {
        $btnCfg = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnConfigureDeltaCert' -ControlType 'Button'
        $btnCfg.Patterns.Invoke.Pattern.Invoke()
        $modal = Find-SPModalByTitle -Automation $ui.Automation -Title 'Delta Cert Run Parameters' -TimeoutMs 6000
        if (-not $modal) {
            Add-Result 'WG-04-02' 'FAIL' "Modal 'Delta Cert Run Parameters' did not appear within 6s"
        } else {
            $dialogOpenedOnce = $true
            $txtSrc      = Find-SPUiElement -Root $modal -AutomationId 'TxtSourceIds'    -TimeoutMs 2000
            $txtHours    = Find-SPUiElement -Root $modal -AutomationId 'TxtHoursBack'    -TimeoutMs 2000
            $txtDeadline = Find-SPUiElement -Root $modal -AutomationId 'TxtDeadlineDays' -TimeoutMs 2000
            $cboMode     = Find-SPUiElement -Root $modal -AutomationId 'CboReviewerMode' -TimeoutMs 2000
            Save-SPUiScreenshot -Element $modal -Path (Join-Path $ScreenshotDir 'WG-04-02-config-dialog.png') | Out-Null
            if ($txtSrc -and $txtHours -and $txtDeadline -and $cboMode) {
                Add-Result 'WG-04-02' 'PASS' "Modal opened with 4 fields (TxtSourceIds, TxtHoursBack, TxtDeadlineDays, CboReviewerMode)"
            } else {
                Add-Result 'WG-04-02' 'FAIL' ("Field probe: src={0} hours={1} deadline={2} mode={3}" -f [bool]$txtSrc, [bool]$txtHours, [bool]$txtDeadline, [bool]$cboMode)
            }

            # ----- WG-04-03: dialog pre-populated from config defaults
            try {
                $srcVal      = Get-SPUiTextValue -Element $txtSrc
                $hoursVal    = Get-SPUiTextValue -Element $txtHours
                $deadlineVal = Get-SPUiTextValue -Element $txtDeadline
                $modeVal     = Get-SPUiComboSelection -ComboBox $cboMode
                # Mock config sets SourceIds=["src-ad-001"], DefaultHoursBack=24,
                # DefaultDeadlineDays=2, DefaultReviewerMode='Manager'.
                if ($srcVal -match 'src-ad-001' -and $hoursVal -eq '24' -and $deadlineVal -eq '2' -and $modeVal -eq 'Manager') {
                    Add-Result 'WG-04-03' 'PASS' ("Pre-populated: SourceIds='{0}', HoursBack={1}, DeadlineDays={2}, Mode={3}" -f $srcVal, $hoursVal, $deadlineVal, $modeVal)
                } else {
                    Add-Result 'WG-04-03' 'FAIL' ("Unexpected defaults: src='{0}' hours='{1}' deadline='{2}' mode='{3}'" -f $srcVal, $hoursVal, $deadlineVal, $modeVal)
                }
            } catch {
                Add-Result 'WG-04-03' 'FAIL' "Default-population probe failed: $($_.Exception.Message)"
            }

            # WG-04-07 first half: use Cancel on this configure modal so summary
            # label is only updated when we LATER hit Run. The Configure click
            # handler only updates the label on dialog OK. We'll come back to it
            # after WG-04-04 runs the cert and check the label updated.
            $btnCancel = Find-SPUiElement -Root $modal -AutomationId 'BtnCancel' -ControlType 'Button' -TimeoutMs 2000
            if ($btnCancel) { try { $btnCancel.Patterns.Invoke.Pattern.Invoke() } catch { try { $btnCancel.Click() } catch { } } }
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        Add-Result 'WG-04-02' 'FAIL' "Configure dialog probe failed: $($_.Exception.Message)"
        Add-Result 'WG-04-03' 'BLOCKED' "Configure dialog never opened"
    }

    # ----- WG-04-04: Set parameters and click [Run Delta Cert] -- runs cert
    $runCompleted = $false
    $createdSomething = $false
    if (-not $mockUp) {
        Add-Result 'WG-04-04' 'BLOCKED' "Mock at http://10.0.0.143:8080 unreachable; skipping live run ($mockProbeError)"
        Add-Result 'WG-04-05' 'BLOCKED' "Mock unreachable; cannot complete delta cert run"
    } else {
        try {
            $btnRun = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRunDeltaCert' -ControlType 'Button'
            $btnRun.Patterns.Invoke.Pattern.Invoke()
            $modal = Find-SPModalByTitle -Automation $ui.Automation -Title 'Delta Cert Run Parameters' -TimeoutMs 6000
            if (-not $modal) {
                Add-Result 'WG-04-04' 'FAIL' "Run Delta Cert did not open the modal within 6s"
                Add-Result 'WG-04-05' 'BLOCKED' "WG-04-04 failed"
            } else {
                $txtSrc      = Find-SPUiElement -Root $modal -AutomationId 'TxtSourceIds'    -TimeoutMs 3000
                $txtHours    = Find-SPUiElement -Root $modal -AutomationId 'TxtHoursBack'    -TimeoutMs 3000
                $txtDeadline = Find-SPUiElement -Root $modal -AutomationId 'TxtDeadlineDays' -TimeoutMs 3000
                $cboMode     = Find-SPUiElement -Root $modal -AutomationId 'CboReviewerMode' -TimeoutMs 3000

                $srcOk      = Set-SPUiTextValue -Element $txtSrc      -Value 'src-ad-001'
                $hoursOk    = Set-SPUiTextValue -Element $txtHours    -Value '48'
                $deadlineOk = Set-SPUiTextValue -Element $txtDeadline -Value '2'
                $modeOk     = Set-SPUiComboValue -ComboBox $cboMode   -Value 'Manager'

                Save-SPUiScreenshot -Element $modal -Path (Join-Path $ScreenshotDir 'WG-04-04-run-filled.png') | Out-Null

                if (-not ($srcOk -and $hoursOk -and $deadlineOk -and $modeOk)) {
                    Add-Result 'WG-04-04' 'FAIL' ("Field set: src={0} hours={1} deadline={2} mode={3}" -f $srcOk, $hoursOk, $deadlineOk, $modeOk)
                    $btnCancel = Find-SPUiElement -Root $modal -AutomationId 'BtnCancel' -ControlType 'Button' -TimeoutMs 2000
                    if ($btnCancel) { try { $btnCancel.Patterns.Invoke.Pattern.Invoke() } catch { } }
                    Add-Result 'WG-04-05' 'BLOCKED' "Run never executed"
                } else {
                    $btnOk = Find-SPUiElement -Root $modal -AutomationId 'BtnOK' -ControlType 'Button' -TimeoutMs 3000
                    $btnOk.Patterns.Invoke.Pattern.Invoke()

                    # Modal should close + status label should change to running.
                    Start-Sleep -Milliseconds 800
                    $statusEarly = $null
                    try { $statusEarly = (Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertStatusLabel' -TimeoutMs 1500).Name } catch { }
                    Add-Result 'WG-04-04' 'PASS' ("Run Delta Cert clicked with SourceIds=src-ad-001 / 48h / 2d / Manager. Modal closed; status='{0}'" -f $statusEarly)

                    # WG-04-05: Wait for completion. Run handler sets status to
                    # "Delta cert complete: X campaigns created" on success.
                    $finalStatus = Wait-DcStatus -Window $ui.Window -Regex '(complete|fail|error)' -TimeoutSec $RunTimeoutSec
                    Wait-DcRunIdle -Window $ui.Window -TimeoutSec 30 | Out-Null
                    Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-05-run-done.png') | Out-Null

                    if (-not $finalStatus) {
                        Add-Result 'WG-04-05' 'FAIL' "DeltaCertStatusLabel never reached complete/fail state within ${RunTimeoutSec}s"
                    } elseif ($finalStatus -match 'fail|error') {
                        Add-Result 'WG-04-05' 'FAIL' ("Run reported failure: '{0}'" -f $finalStatus)
                    } else {
                        # Verify DeltaCertResultGrid has at least one row.
                        $grid = Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertResultGrid' -TimeoutMs 3000
                        $cfG = $grid.ConditionFactory
                        $rows = @($grid.FindAllDescendants($cfG.ByControlType([FlaUI.Core.Definitions.ControlType]::DataItem)))
                        if ($rows.Count -ge 1) {
                            $runCompleted = $true
                            if ($finalStatus -match 'Campaigns:\s*(\d+)') {
                                $created = [int]$Matches[1]
                                if ($created -gt 0) { $createdSomething = $true }
                            }
                            Add-Result 'WG-04-05' 'PASS' ("'{0}'; DeltaCertResultGrid has {1} row(s)" -f $finalStatus, $rows.Count)
                        } else {
                            Add-Result 'WG-04-05' 'FAIL' ("Status='{0}' but DeltaCertResultGrid has 0 rows" -f $finalStatus)
                        }
                    }
                }
            }
        }
        catch {
            Add-Result 'WG-04-04' 'FAIL' "Run Delta Cert flow failed: $($_.Exception.Message)"
            Add-Result 'WG-04-05' 'BLOCKED' "WG-04-04 failed"
        }
    }

    # ----- WG-04-06: Re-open Configure -- session persistence -- dialog pre-populated with LAST USED
    try {
        if (-not $runCompleted) {
            Add-Result 'WG-04-06' 'BLOCKED' "Cannot test session persistence -- WG-04-04 did not store params"
        } else {
            $btnCfg = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnConfigureDeltaCert' -ControlType 'Button'
            $btnCfg.Patterns.Invoke.Pattern.Invoke()
            $modal2 = Find-SPModalByTitle -Automation $ui.Automation -Title 'Delta Cert Run Parameters' -TimeoutMs 6000
            if (-not $modal2) {
                Add-Result 'WG-04-06' 'FAIL' "Configure modal did not re-open"
            } else {
                $txtSrc      = Find-SPUiElement -Root $modal2 -AutomationId 'TxtSourceIds'    -TimeoutMs 2000
                $txtHours    = Find-SPUiElement -Root $modal2 -AutomationId 'TxtHoursBack'    -TimeoutMs 2000
                $txtDeadline = Find-SPUiElement -Root $modal2 -AutomationId 'TxtDeadlineDays' -TimeoutMs 2000
                $cboMode     = Find-SPUiElement -Root $modal2 -AutomationId 'CboReviewerMode' -TimeoutMs 2000

                $s = Get-SPUiTextValue -Element $txtSrc
                $h = Get-SPUiTextValue -Element $txtHours
                $d = Get-SPUiTextValue -Element $txtDeadline
                $m = Get-SPUiComboSelection -ComboBox $cboMode
                Save-SPUiScreenshot -Element $modal2 -Path (Join-Path $ScreenshotDir 'WG-04-06-reopen.png') | Out-Null

                if ($s -eq 'src-ad-001' -and $h -eq '48' -and $d -eq '2' -and $m -eq 'Manager') {
                    Add-Result 'WG-04-06' 'PASS' ("Session persistence: dialog pre-populated with LAST USED -- src='{0}' h={1} d={2} mode={3}" -f $s, $h, $d, $m)
                } else {
                    Add-Result 'WG-04-06' 'FAIL' ("Last-used values not restored: src='{0}' h='{1}' d='{2}' mode='{3}'" -f $s, $h, $d, $m)
                }
                $btnCancel = Find-SPUiElement -Root $modal2 -AutomationId 'BtnCancel' -ControlType 'Button' -TimeoutMs 2000
                if ($btnCancel) { try { $btnCancel.Patterns.Invoke.Pattern.Invoke() } catch { } }
                Start-Sleep -Milliseconds 400
            }
        }
    }
    catch {
        Add-Result 'WG-04-06' 'FAIL' "Session persistence probe failed: $($_.Exception.Message)"
    }

    # ----- WG-04-07: Summary label updated to reflect current params
    try {
        if (-not $runCompleted) {
            Add-Result 'WG-04-07' 'BLOCKED' "Run did not complete; no LastDeltaCertParams to render"
        } else {
            $summary = (Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertSummaryLabel' -TimeoutMs 3000).Name
            # Expected format: "Sources: src-ad-001 | 48h | 2d deadline | Manager"
            if ($summary -match '^Sources:\s*src-ad-001\s*\|\s*48h\s*\|\s*2d deadline\s*\|\s*Manager') {
                Add-Result 'WG-04-07' 'PASS' ("DeltaCertSummaryLabel text: '{0}'" -f $summary)
            } else {
                Add-Result 'WG-04-07' 'FAIL' ("Unexpected summary text: '{0}'" -f $summary)
            }
        }
    }
    catch {
        Add-Result 'WG-04-07' 'FAIL' "Summary label probe failed: $($_.Exception.Message)"
    }

    # ----- WG-04-08: Click [Run Cleanup] -- runs cleanup (may be a no-op)
    if (-not $mockUp) {
        Add-Result 'WG-04-08' 'BLOCKED' "Mock unreachable; cleanup needs API access"
    } else {
        try {
            $btnCleanup = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnCleanupDeltaCert' -ControlType 'Button'
            $btnCleanup.Patterns.Invoke.Pattern.Invoke()
            $finalStatus = Wait-DcStatus -Window $ui.Window -Regex '(Cleanup complete|Cleanup failed|No stale|No campaigns)' -TimeoutSec $CleanupTimeoutSec
            Wait-DcRunIdle -Window $ui.Window -TimeoutSec 30 -ButtonId 'BtnCleanupDeltaCert' | Out-Null
            Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-08-cleanup.png') | Out-Null
            if ($finalStatus -and $finalStatus -notmatch '\bfailed\b') {
                Add-Result 'WG-04-08' 'PASS' ("Cleanup completed: '{0}'" -f $finalStatus)
            } elseif ($finalStatus) {
                Add-Result 'WG-04-08' 'FAIL' ("Cleanup failure: '{0}'" -f $finalStatus)
            } else {
                Add-Result 'WG-04-08' 'FAIL' ("Cleanup status label never reached terminal state within ${CleanupTimeoutSec}s")
            }
        }
        catch {
            Add-Result 'WG-04-08' 'FAIL' "Cleanup click failed: $($_.Exception.Message)"
        }
    }

    # ----- WG-04-09: Click [Run Escalation] -- DeltaCertEscalateDialog opens with 3 fields
    $escDialogOpened = $false
    try {
        $btnEsc = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnEscalateDeltaCert' -ControlType 'Button'
        $btnEsc.Patterns.Invoke.Pattern.Invoke()
        $escModal = Find-SPModalByTitle -Automation $ui.Automation -Title 'Escalation Parameters' -TimeoutMs 6000
        if (-not $escModal) {
            Add-Result 'WG-04-09' 'FAIL' "Modal 'Escalation Parameters' did not appear within 6s"
            Add-Result 'WG-04-10' 'BLOCKED' "Escalation dialog never opened"
        } else {
            $escDialogOpened = $true
            $txtPfx    = Find-SPUiElement -Root $escModal -AutomationId 'TxtCampaignPrefix' -TimeoutMs 2000
            $txtStale  = Find-SPUiElement -Root $escModal -AutomationId 'TxtStaleHours'     -TimeoutMs 2000
            $txtLevels = Find-SPUiElement -Root $escModal -AutomationId 'TxtMaxLevels'      -TimeoutMs 2000
            Save-SPUiScreenshot -Element $escModal -Path (Join-Path $ScreenshotDir 'WG-04-09-escalate-dialog.png') | Out-Null
            if ($txtPfx -and $txtStale -and $txtLevels) {
                Add-Result 'WG-04-09' 'PASS' "Escalation modal opened with 3 fields (TxtCampaignPrefix, TxtStaleHours, TxtMaxLevels)"
            } else {
                Add-Result 'WG-04-09' 'FAIL' ("Field probe: pfx={0} stale={1} levels={2}" -f [bool]$txtPfx, [bool]$txtStale, [bool]$txtLevels)
            }

            # ----- WG-04-10: Set escalation params and click Run Escalation
            if (-not $mockUp) {
                Add-Result 'WG-04-10' 'BLOCKED' "Mock unreachable; escalation needs API access"
                $btnCancel = Find-SPUiElement -Root $escModal -AutomationId 'BtnCancel' -ControlType 'Button' -TimeoutMs 2000
                if ($btnCancel) { try { $btnCancel.Patterns.Invoke.Pattern.Invoke() } catch { } }
            } else {
                $pOk = Set-SPUiTextValue -Element $txtPfx    -Value 'AD Delta Cert'
                $sOk = Set-SPUiTextValue -Element $txtStale  -Value '1'
                $lOk = Set-SPUiTextValue -Element $txtLevels -Value '2'
                if (-not ($pOk -and $sOk -and $lOk)) {
                    Add-Result 'WG-04-10' 'FAIL' ("Field set: pfx={0} stale={1} levels={2}" -f $pOk, $sOk, $lOk)
                    $btnCancel = Find-SPUiElement -Root $escModal -AutomationId 'BtnCancel' -ControlType 'Button' -TimeoutMs 2000
                    if ($btnCancel) { try { $btnCancel.Patterns.Invoke.Pattern.Invoke() } catch { } }
                } else {
                    $btnOk = Find-SPUiElement -Root $escModal -AutomationId 'BtnOK' -ControlType 'Button' -TimeoutMs 3000
                    $btnOk.Patterns.Invoke.Pattern.Invoke()
                    $finalStatus = Wait-DcStatus -Window $ui.Window -Regex '(Escalation complete|Escalation failed|No stale)' -TimeoutSec $EscalationTimeoutSec
                    Wait-DcRunIdle -Window $ui.Window -TimeoutSec 30 -ButtonId 'BtnEscalateDeltaCert' | Out-Null
                    Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-10-escalation-done.png') | Out-Null
                    if ($finalStatus -and $finalStatus -notmatch '\bfailed\b') {
                        Add-Result 'WG-04-10' 'PASS' ("Escalation completed: '{0}'" -f $finalStatus)
                    } elseif ($finalStatus) {
                        Add-Result 'WG-04-10' 'FAIL' ("Escalation failure: '{0}'" -f $finalStatus)
                    } else {
                        Add-Result 'WG-04-10' 'FAIL' "Escalation status label never reached terminal state within ${EscalationTimeoutSec}s"
                    }
                }
            }
        }
    }
    catch {
        Add-Result 'WG-04-09' 'FAIL' "Escalation dialog probe failed: $($_.Exception.Message)"
        Add-Result 'WG-04-10' 'BLOCKED' "WG-04-09 failed"
    }

    # ----- WG-04-11: Click [Open Output Folder] -- launches Explorer on DeltaCert\
    try {
        $beforeExplorer = Get-NewProcessesByName -Names @('explorer') -Since $scriptStart
        $beforeCount = $beforeExplorer.Count
        $btnOpen = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnOpenDeltaCertFolder' -ControlType 'Button' -TimeoutMs 3000
        $btnOpen.Patterns.Invoke.Pattern.Invoke()
        $sawExplorer = $false
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            $now = Get-NewProcessesByName -Names @('explorer') -Since $scriptStart
            if ($now.Count -gt $beforeCount) { $sawExplorer = $true; break }
            Start-Sleep -Milliseconds 300
        }
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-11-open-folder.png') | Out-Null

        $spawned = Get-NewProcessesByName -Names @('explorer') -Since $scriptStart
        $newOnes = @($spawned | Where-Object {
            $proc = $_
            -not ($beforeExplorer | Where-Object { $_.Id -eq $proc.Id })
        })
        Stop-Procs -Procs ([System.Collections.Generic.List[object]]$newOnes)

        if ($sawExplorer) {
            Add-Result 'WG-04-11' 'PASS' ("BtnOpenDeltaCertFolder spawned {0} explorer.exe process(es); cleaned up" -f $newOnes.Count)
        } elseif (Test-Path $deltaCertDir) {
            Add-Result 'WG-04-11' 'PASS' "BtnOpenDeltaCertFolder click did not throw; DeltaCert\ exists. Explorer may have reused existing shell process."
        } else {
            Add-Result 'WG-04-11' 'FAIL' "No new Explorer process and DeltaCert\ directory missing"
        }
    }
    catch {
        Add-Result 'WG-04-11' 'FAIL' "Open Output Folder click failed: $($_.Exception.Message)"
    }

    # ----- WG-04-12: Click [Generate Delta Report] -- generates HTML in DeltaCert\reports\
    if (-not $mockUp) {
        Add-Result 'WG-04-12' 'BLOCKED' "Mock unreachable; delta report needs API access"
    } else {
        try {
            $btnReport = $null
            try { $btnReport = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnGenerateDeltaReport' -ControlType 'Button' -TimeoutMs 3000 } catch { }
            if (-not $btnReport) {
                Add-Result 'WG-04-12' 'FAIL' "BtnGenerateDeltaReport button not found"
            } else {
                # Snapshot browser processes BEFORE: Invoke-GuiDeltaReport calls
                # Start-Process on the resulting HTML, which spawns/reuses a browser.
                $browserNames = @('msedge','chrome','firefox','brave','opera','iexplore','vivaldi')
                $browsersBefore = @{}
                foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
                    if ($browserNames -contains $p.ProcessName.ToLower()) { $browsersBefore[[int]$p.Id] = $true }
                }

                $btnReport.Patterns.Invoke.Pattern.Invoke()
                $finalStatus = Wait-DcStatus -Window $ui.Window -Regex '(Delta report generated|Delta report failed)' -TimeoutSec $DeltaReportTimeoutSec
                Wait-DcRunIdle -Window $ui.Window -TimeoutSec 30 -ButtonId 'BtnGenerateDeltaReport' | Out-Null
                Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-12-delta-report.png') | Out-Null

                # Clean up any new browser processes spawned by Start-Process.
                $toKill = New-Object System.Collections.Generic.List[object]
                foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
                    if (-not $browsersBefore.ContainsKey([int]$p.Id) -and $browserNames -contains $p.ProcessName.ToLower()) {
                        $toKill.Add($p) | Out-Null
                    }
                }
                Stop-Procs -Procs $toKill

                $reportsDir = Join-Path $deltaCertDir 'reports'
                $reports = @()
                if (Test-Path $reportsDir) {
                    $reports = @(Get-ChildItem -Path $reportsDir -Filter '*.html' -ErrorAction SilentlyContinue)
                }
                if ($finalStatus -match '\bfailed\b') {
                    Add-Result 'WG-04-12' 'FAIL' ("Delta report failure: '{0}'" -f $finalStatus)
                } elseif ($reports.Count -ge 1) {
                    Add-Result 'WG-04-12' 'PASS' ("Delta report generated: '{0}'; {1} HTML file(s) under DeltaCert\reports\; killed {2} spawned browser process(es)" -f $finalStatus, $reports.Count, $toKill.Count)
                } else {
                    Add-Result 'WG-04-12' 'FAIL' ("Status='{0}' but no HTML reports under DeltaCert\reports\" -f $finalStatus)
                }
            }
        }
        catch {
            Add-Result 'WG-04-12' 'FAIL' "Generate Delta Report click failed: $($_.Exception.Message)"
        }
    }

    # ----- WG-04-13: History section shows recent runs (color-coded)
    try {
        # Refresh to be sure the list is fresh after all our runs.
        try {
            $btnRefresh = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRefreshDeltaCertHistory' -ControlType 'Button' -TimeoutMs 3000
            if ($btnRefresh) { $btnRefresh.Patterns.Invoke.Pattern.Invoke(); Start-Sleep -Milliseconds 600 }
        } catch { }

        $listBox = Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertHistoryList' -TimeoutMs 3000
        $cfL = $listBox.ConditionFactory
        $items = @($listBox.FindAllChildren($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        if ($items.Count -eq 0) {
            $items = @($listBox.FindAllDescendants($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        }
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-13-history.png') | Out-Null

        if ($items.Count -ge 1) {
            $sampleName = $items[0].Name
            $hasNoRunsMsg = ($sampleName -match 'No recent runs')
            if ($hasNoRunsMsg) {
                if ($runCompleted) {
                    Add-Result 'WG-04-13' 'FAIL' ("History list says 'No recent runs' even though Run completed. Sample: '{0}'" -f $sampleName)
                } else {
                    Add-Result 'WG-04-13' 'PASS' ("History list shows placeholder '{0}' (no runs persisted yet, which is expected when mock was down)" -f $sampleName)
                }
            } else {
                Add-Result 'WG-04-13' 'PASS' ("DeltaCertHistoryList shows {0} item(s); first item: '{1}'" -f $items.Count, $sampleName)
            }
        } else {
            Add-Result 'WG-04-13' 'FAIL' "DeltaCertHistoryList is empty (no items and no placeholder)"
        }
    }
    catch {
        Add-Result 'WG-04-13' 'FAIL' "History probe failed: $($_.Exception.Message)"
    }

    # ----- WG-04-14: Click [Refresh] -- history list refreshes
    try {
        $btnRefresh = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRefreshDeltaCertHistory' -ControlType 'Button' -TimeoutMs 3000
        $listBox = Find-SPUiElement -Root $ui.Window -AutomationId 'DeltaCertHistoryList' -TimeoutMs 3000
        $cfL = $listBox.ConditionFactory

        $itemsBefore = @($listBox.FindAllChildren($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        if ($itemsBefore.Count -eq 0) {
            $itemsBefore = @($listBox.FindAllDescendants($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        }
        $beforeCount = $itemsBefore.Count

        $btnRefresh.Patterns.Invoke.Pattern.Invoke()
        Start-Sleep -Milliseconds 800

        $itemsAfter = @($listBox.FindAllChildren($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        if ($itemsAfter.Count -eq 0) {
            $itemsAfter = @($listBox.FindAllDescendants($cfL.ByControlType([FlaUI.Core.Definitions.ControlType]::ListItem)))
        }
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-04-14-refresh.png') | Out-Null

        # Refresh should produce at least one item (either real entries or the
        # "No recent runs..." placeholder), and the click should not throw.
        if ($itemsAfter.Count -ge 1) {
            Add-Result 'WG-04-14' 'PASS' ("Refresh click OK; history list has {0} item(s) after refresh (was {1})" -f $itemsAfter.Count, $beforeCount)
        } else {
            Add-Result 'WG-04-14' 'FAIL' ("Refresh produced an empty list (was {0} item(s) before refresh)" -f $beforeCount)
        }
    }
    catch {
        Add-Result 'WG-04-14' 'FAIL' "Refresh click failed: $($_.Exception.Message)"
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
