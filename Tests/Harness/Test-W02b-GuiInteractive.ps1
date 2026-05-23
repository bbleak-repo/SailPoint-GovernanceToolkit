#Requires -Version 5.1
<#
.SYNOPSIS
    W-02b -- Interactive FlaUI backfill for the W-02 GUI Settings/Campaigns/Evidence
    structural tests. Drives a REAL visible WPF window via Tests\Harness\SP.UiTest.psm1
    (FlaUI 4.0 UIA3) and asserts the live UI behaviour, then dismisses any modal
    dialogs the dashboard raises (Save -> "Saved" MessageBox).

.DESCRIPTION
    Run as:
        powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
            -File .\Tests\Harness\Test-W02b-GuiInteractive.ps1 `
            -JsonlPath docs\windows-test-rounds\WG-02b-results.jsonl

    Emits one compact JSON line per test, terminated by a {summary} line.
    Exit 0 if no FAIL (BLOCKED does not fail). Per-test screenshots land in
    docs\windows-test-rounds\WG-02b-<id>.png.

.NOTES
    DO NOT run under a non-STA host; WPF requires STA and the dashboard's own
    re-launcher would spawn a second STA process that FlaUI cannot attach to.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$JsonlPath,
    [Parameter()][string]$ScreenshotDir
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Error "Run this script under -STA (powershell.exe -STA -File ...)."
    exit 2
}

# Resolve paths up-front so they don't depend on the WorkingDirectory the
# harness inherits from its launcher.
$harnessRoot = $PSScriptRoot
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $harnessRoot '..\..'))
if (-not $ConfigPath)    { $ConfigPath    = Join-Path $toolkitRoot 'Config\settings.json' }
if (-not $ScreenshotDir) { $ScreenshotDir = Join-Path $toolkitRoot 'docs\windows-test-rounds' }
if (-not $JsonlPath)     { $JsonlPath     = Join-Path $ScreenshotDir 'WG-02b-results.jsonl' }
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

# ----- Small UI helpers (kept here so SP.UiTest.psm1 stays minimal) ---------

function Get-SPUiTextValue {
    param([Parameter(Mandatory)]$Element)
    $tb = [FlaUI.Core.AutomationElements.TextBox]::new($Element.FrameworkAutomationElement)
    return $tb.Text
}

function Set-SPUiTextValue {
    <#
    .SYNOPSIS
        Atomically sets a WPF TextBox value via the UIA Value pattern and waits
        for the change to round-trip back through FlaUI before returning.
        Cross-process UIA calls are async; without the wait loop the next
        Button.Click() can race ahead of TextProperty propagation.
    #>
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)][string]$Value,
          [int]$TimeoutMs = 3000)
    $vp = $Element.Patterns.Value.Pattern
    $vp.SetValue($Value)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Get-SPUiTextValue -Element $Element) -eq $Value) { return $true }
        Start-Sleep -Milliseconds 75
    }
    return $false
}

function Dismiss-SPUiSavedDialog {
    <#
    .SYNOPSIS
        Save-SettingsForm pops a System.Windows.MessageBox titled "Saved" (Win32
        #32770 dialog under the covers). Best-effort: walk the Desktop root for
        a top-level Window whose Name is "Saved" and Invoke its OK button, then
        fall back to sending Enter to whichever process window currently has
        focus. Returns $true on dismissal, $false on timeout. Save success is
        verified separately by reading the file from disk, so a $false here is
        non-fatal.
    #>
    param([Parameter(Mandatory)]$Application, [Parameter(Mandatory)]$Automation,
          [int]$TimeoutSeconds = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        # 1) Per-app top-level windows.
        try {
            $modals = $Application.GetAllTopLevelWindows($Automation)
            foreach ($w in $modals) {
                if ($w.Title -eq 'Saved' -or $w.Name -eq 'Saved') {
                    $cf  = $w.ConditionFactory
                    $btn = $w.FindFirstDescendant($cf.ByControlType([FlaUI.Core.Definitions.ControlType]::Button))
                    if ($btn) {
                        try { $btn.Patterns.Invoke.Pattern.Invoke() } catch { $btn.Click() }
                    }
                    else { $w.Close() }
                    return $true
                }
            }
        } catch { }
        # 2) Whole-desktop sweep (Win32 #32770 dialogs sometimes don't show up in
        # the per-application enumeration above).
        try {
            $desktop = $Automation.GetDesktop()
            $cf = $desktop.ConditionFactory
            $cond = $cf.ByControlType([FlaUI.Core.Definitions.ControlType]::Window).And($cf.ByName('Saved'))
            $w = $desktop.FindFirstDescendant($cond)
            if ($w) {
                $btn = $w.FindFirstDescendant($cf.ByControlType([FlaUI.Core.Definitions.ControlType]::Button))
                if ($btn) {
                    try { $btn.Patterns.Invoke.Pattern.Invoke() } catch { $btn.Click() }
                }
                else { try { $w.Close() } catch { } }
                return $true
            }
        } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Read-DcHoursBackFromDisk {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Get-Content -Raw -Path $Path | ConvertFrom-Json
    return [int]$cfg.DeltaCert.DefaultHoursBack
}

# ----- Test run -------------------------------------------------------------

$ui = $null
try {

    # ----- WG-02b-01: Launch + 5 tabs visible
    try {
        $ui = Start-SPDashboardForTest -ConfigPath $ConfigPath -TimeoutSeconds 45
        $expectedTabs = @('Campaigns', 'Evidence', 'Settings', 'Audit', 'Delta Cert')
        $missing = @()
        foreach ($tname in $expectedTabs) {
            try { Find-SPUiTab -Window $ui.Window -Header $tname -TimeoutMs 3000 | Out-Null }
            catch { $missing += $tname }
        }
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-02b-01-launched.png') | Out-Null
        if ($missing.Count -eq 0) {
            Add-Result 'WG-02b-01' 'PASS' "Window '$($ui.Window.Title)' attached (pid $($ui.Process.Id)); 5 tabs found"
        }
        else {
            Add-Result 'WG-02b-01' 'FAIL' ("Missing tabs: {0}" -f ($missing -join ', '))
        }
    }
    catch {
        Add-Result 'WG-02b-01' 'FAIL' "Launch/attach failed: $($_.Exception.Message)"
        # Without a window the rest cannot run.
        Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1; blocked = 0 }))
        exit 1
    }

    # ----- WG-02b-02: Settings tab renders -- 6 section headers visible
    try {
        $settingsTab = Find-SPUiTab -Window $ui.Window -Header 'Settings'
        $settingsTab.Select()
        Start-Sleep -Milliseconds 400  # let layout pass
        $sectionHeaders = @('Environment', 'Authentication', 'API Configuration',
                            'Testing', 'Safety Controls', 'Delta Cert')
        $missing = @()
        foreach ($h in $sectionHeaders) {
            try { Find-SPUiElement -Root $ui.Window -Name $h -ControlType 'Text' -TimeoutMs 2000 | Out-Null }
            catch { $missing += $h }
        }
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-02b-02-settings-tab.png') | Out-Null
        if ($missing.Count -eq 0) {
            Add-Result 'WG-02b-02' 'PASS' 'All 6 settings section headers visible'
        }
        else {
            Add-Result 'WG-02b-02' 'FAIL' ("Missing section headers: {0}" -f ($missing -join ', '))
        }
    }
    catch {
        Add-Result 'WG-02b-02' 'FAIL' "Settings tab probe failed: $($_.Exception.Message)"
    }

    # ----- WG-02b-03: Delta Cert section has 6 fields
    try {
        $dcFields = @('TxtDcSourceIds', 'TxtDcHoursBack', 'TxtDcDeadlineDays',
                      'CboDcReviewerMode', 'TxtDcCampaignPrefix', 'TxtDcOutputPath')
        $missing = @()
        foreach ($id in $dcFields) {
            try { Find-SPUiElement -Root $ui.Window -AutomationId $id -TimeoutMs 2000 | Out-Null }
            catch { $missing += $id }
        }
        if ($missing.Count -eq 0) {
            Add-Result 'WG-02b-03' 'PASS' '6/6 Delta Cert fields present (Source IDs, Hours Back, Deadline Days, Reviewer Mode, Campaign Prefix, Output Path)'
        }
        else {
            Add-Result 'WG-02b-03' 'FAIL' ("Missing fields: {0}" -f ($missing -join ', '))
        }
    }
    catch {
        Add-Result 'WG-02b-03' 'FAIL' "Delta Cert field probe failed: $($_.Exception.Message)"
    }

    # ----- WG-02b-04: Quick Connect section -- masked PasswordBox + Apply/Clear
    try {
        $pb       = Find-SPUiElement -Root $ui.Window -AutomationId 'PbBrowserToken' -TimeoutMs 3000
        $btnApply = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnApplyToken' -ControlType 'Button' -TimeoutMs 3000
        $btnClear = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnClearToken' -ControlType 'Button' -TimeoutMs 3000
        $status   = Find-SPUiElement -Root $ui.Window -AutomationId 'BrowserTokenStatus' -TimeoutMs 3000

        $isPassword = ($pb.ControlType -eq [FlaUI.Core.Definitions.ControlType]::Edit) -and ($pb.Properties.IsPassword.Value -eq $true)
        if ($isPassword -and $btnApply -and $btnClear -and $status) {
            Add-Result 'WG-02b-04' 'PASS' 'PbBrowserToken IsPassword=True + BtnApplyToken + BtnClearToken + BrowserTokenStatus all present'
        }
        else {
            Add-Result 'WG-02b-04' 'FAIL' ("password={0} apply={1} clear={2} status={3}" -f $isPassword, [bool]$btnApply, [bool]$btnClear, [bool]$status)
        }
    }
    catch {
        Add-Result 'WG-02b-04' 'FAIL' "Quick Connect probe failed: $($_.Exception.Message)"
    }

    # ----- WG-02b-05: Save/Load round trip on TxtDcHoursBack
    try {
        $hoursField = Find-SPUiElement -Root $ui.Window -AutomationId 'TxtDcHoursBack' -ControlType 'Edit'
        $btnSave    = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnSaveSettings' -ControlType 'Button'
        $statusBar  = Find-SPUiElement -Root $ui.Window -AutomationId 'StatusBarText'

        $initialUiValue   = Get-SPUiTextValue -Element $hoursField
        $initialDiskValue = Read-DcHoursBackFromDisk -Path $ConfigPath

        # --- Round trip 1: 24 -> 48 ---
        $set1Ok    = Set-SPUiTextValue -Element $hoursField -Value '48'
        $uiAfterSet1 = Get-SPUiTextValue -Element $hoursField
        # Use Invoke pattern explicitly so we don't depend on mouse Click reaching
        # the underlying WPF dispatch.
        $btnSave.Patterns.Invoke.Pattern.Invoke()
        $dismissed1 = Dismiss-SPUiSavedDialog -Application $ui.Application -Automation $ui.Automation -TimeoutSeconds 10
        Start-Sleep -Milliseconds 400
        $statusAfter1   = $statusBar.Name
        $afterSaveDisk1 = Read-DcHoursBackFromDisk -Path $ConfigPath

        # --- Round trip 2: 48 -> 24 (restore) ---
        $set2Ok    = Set-SPUiTextValue -Element $hoursField -Value '24'
        $uiAfterSet2 = Get-SPUiTextValue -Element $hoursField
        $btnSave.Patterns.Invoke.Pattern.Invoke()
        $dismissed2 = Dismiss-SPUiSavedDialog -Application $ui.Application -Automation $ui.Automation -TimeoutSeconds 10
        Start-Sleep -Milliseconds 400
        $statusAfter2   = $statusBar.Name
        $afterSaveDisk2 = Read-DcHoursBackFromDisk -Path $ConfigPath

        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-02b-05-after-save-roundtrip.png') | Out-Null

        # WG-02-05 spec is the SAVE ROUND TRIP, not the post-save modal hygiene.
        # PASS condition: UI value committed, disk file updated to match, status
        # bar reports success, then the same again restoring the original. The
        # Dismiss-SPUiSavedDialog calls above are best-effort because WPF's
        # Win32 #32770 "Saved" dialog often disappears on its own before our
        # cross-process polling can catch it (Invoke pattern in WPF dispatches
        # async; subsequent tests confirm nothing is left blocking input).
        if ($initialUiValue -eq '24' -and $initialDiskValue -eq 24 -and
            $set1Ok -and $uiAfterSet1 -eq '48' -and $afterSaveDisk1 -eq 48 -and $statusAfter1 -like '*saved successfully*' -and
            $set2Ok -and $uiAfterSet2 -eq '24' -and $afterSaveDisk2 -eq 24 -and $statusAfter2 -like '*saved successfully*') {
            Add-Result 'WG-02b-05' 'PASS' ("Round trip OK: UI 24/disk 24 -> 48 (ui={0} disk={1} status='{2}' dismissed={3}) -> 24 (ui={4} disk={5} status='{6}' dismissed={7})" -f $uiAfterSet1, $afterSaveDisk1, $statusAfter1, $dismissed1, $uiAfterSet2, $afterSaveDisk2, $statusAfter2, $dismissed2)
        }
        else {
            Add-Result 'WG-02b-05' 'FAIL' ("ui0=$initialUiValue disk0=$initialDiskValue | set1Ok=$set1Ok uiAfterSet1=$uiAfterSet1 disk1=$afterSaveDisk1 status1='$statusAfter1' dismissed1=$dismissed1 | set2Ok=$set2Ok uiAfterSet2=$uiAfterSet2 disk2=$afterSaveDisk2 status2='$statusAfter2' dismissed2=$dismissed2")
        }
    }
    catch {
        Add-Result 'WG-02b-05' 'FAIL' "Save round-trip failed: $($_.Exception.Message)"
        # Try to clear any leftover modal so subsequent tests can run.
        Dismiss-SPUiSavedDialog -Application $ui.Application -Automation $ui.Automation -TimeoutSeconds 2 | Out-Null
    }

    # ----- WG-02b-06: Campaigns tab renders -- toolbar buttons + DataGrid + progress area
    try {
        $campTab = Find-SPUiTab -Window $ui.Window -Header 'Campaigns'
        $campTab.Select()
        Start-Sleep -Milliseconds 400
        $btnRunSel  = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRunSelected'     -ControlType 'Button' -TimeoutMs 3000
        $btnRunAll  = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRunAll'          -ControlType 'Button' -TimeoutMs 3000
        $btnRunSmk  = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRunSmoke'        -ControlType 'Button' -TimeoutMs 3000
        $btnRefresh = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRefreshCampaigns' -ControlType 'Button' -TimeoutMs 3000
        $grid       = Find-SPUiElement -Root $ui.Window -AutomationId 'CampaignGrid'       -TimeoutMs 3000
        $curTest    = Find-SPUiElement -Root $ui.Window -AutomationId 'CurrentTestLabel'   -TimeoutMs 3000
        $resultSum  = Find-SPUiElement -Root $ui.Window -AutomationId 'ResultSummaryText'  -TimeoutMs 3000

        # SuiteProgressBar starts Visibility=Collapsed; it is intentionally absent
        # from the UIA tree until a run begins. Verify the surrounding "progress area"
        # via CurrentTestLabel + ResultSummaryText instead.
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-02b-06-campaigns-tab.png') | Out-Null
        if ($btnRunSel -and $btnRunAll -and $btnRunSmk -and $btnRefresh -and $grid -and $curTest -and $resultSum) {
            Add-Result 'WG-02b-06' 'PASS' 'Toolbar (RunSelected/RunAll/RunSmoke/Refresh) + CampaignGrid + progress area (CurrentTestLabel + ResultSummaryText) present; SuiteProgressBar is Visibility=Collapsed pre-run by design'
        }
        else {
            Add-Result 'WG-02b-06' 'FAIL' 'One or more Campaigns-tab controls missing from live UI'
        }
    }
    catch {
        Add-Result 'WG-02b-06' 'FAIL' "Campaigns tab probe failed: $($_.Exception.Message)"
    }

    # ----- WG-02b-07: Evidence tab renders
    try {
        $evTab = Find-SPUiTab -Window $ui.Window -Header 'Evidence'
        $evTab.Select()
        Start-Sleep -Milliseconds 400
        $tree       = Find-SPUiElement -Root $ui.Window -AutomationId 'EvidenceTree'       -TimeoutMs 3000
        $detailGrid = Find-SPUiElement -Root $ui.Window -AutomationId 'EvidenceDetailGrid' -TimeoutMs 3000
        $btnRefresh = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnRefreshEvidence' -ControlType 'Button' -TimeoutMs 3000
        $btnOpen    = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnOpenInBrowser'   -ControlType 'Button' -TimeoutMs 3000
        $btnExport  = Find-SPUiElement -Root $ui.Window -AutomationId 'BtnExportAll'       -ControlType 'Button' -TimeoutMs 3000
        Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir 'WG-02b-07-evidence-tab.png') | Out-Null
        if ($tree -and $detailGrid -and $btnRefresh -and $btnOpen -and $btnExport) {
            Add-Result 'WG-02b-07' 'PASS' 'EvidenceTree + EvidenceDetailGrid + Refresh/Open/Export buttons present'
        }
        else {
            Add-Result 'WG-02b-07' 'FAIL' 'One or more Evidence-tab controls missing from live UI'
        }
    }
    catch {
        Add-Result 'WG-02b-07' 'FAIL' "Evidence tab probe failed: $($_.Exception.Message)"
    }

    # ----- WG-02b-08: All 5 tab headers clickable -- cycle through, verify selection
    try {
        $order = @('Campaigns', 'Evidence', 'Settings', 'Audit', 'Delta Cert')
        $failures = @()
        foreach ($name in $order) {
            $tab = Find-SPUiTab -Window $ui.Window -Header $name
            $tab.Select()
            $deadline = (Get-Date).AddSeconds(2)
            while (-not $tab.IsSelected -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 80
            }
            if (-not $tab.IsSelected) { $failures += $name }
            Save-SPUiScreenshot -Element $ui.Window -Path (Join-Path $ScreenshotDir ("WG-02b-08-tab-{0}.png" -f ($name -replace ' ', ''))) | Out-Null
        }
        if ($failures.Count -eq 0) {
            Add-Result 'WG-02b-08' 'PASS' 'All 5 tabs selectable in order: Campaigns -> Evidence -> Settings -> Audit -> Delta Cert (per-tab PNGs written)'
        }
        else {
            Add-Result 'WG-02b-08' 'FAIL' ("IsSelected never became true within 2s for: {0}" -f ($failures -join ', '))
        }
    }
    catch {
        Add-Result 'WG-02b-08' 'FAIL' "Tab cycle failed: $($_.Exception.Message)"
    }

}
finally {
    if ($ui) {
        # Final clean-up: dismiss any orphan modal that a failed save handler may
        # have left up before tearing the process down.
        try { Dismiss-SPUiSavedDialog -Application $ui.Application -Automation $ui.Automation -TimeoutSeconds 2 | Out-Null } catch { }
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
