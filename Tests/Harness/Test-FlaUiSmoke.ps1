#Requires -Version 5.1
<#
.SYNOPSIS
    Sanity check for the FlaUI harness (SP.UiTest.psm1).

.DESCRIPTION
    Launches the dashboard as a real visible WPF window, verifies the
    main window has the expected title and that the five expected tabs
    are present, captures a screenshot, then closes the window.

    This is *not* part of the W-* test plan -- it's the foundation smoke
    test we run once after standing up the FlaUI scaffolding to prove the
    helper module works end-to-end.

.OUTPUTS
    JSONL one line per check; final summary line:
        { "summary": true, "pass": N, "fail": M }
    Exit 0 if all pass, 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$ScreenshotPath,
    [Parameter()][string]$JsonlPath
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Error "Run this script under -STA (powershell.exe -STA -File ...)."
    exit 2
}

Import-Module (Join-Path $PSScriptRoot 'SP.UiTest.psm1') -Force

$results = New-Object System.Collections.Generic.List[object]
if ($JsonlPath) {
    $jsonlDir = Split-Path -Parent $JsonlPath
    if ($jsonlDir -and -not (Test-Path $jsonlDir)) {
        New-Item -ItemType Directory -Path $jsonlDir -Force | Out-Null
    }
    Set-Content -Path $JsonlPath -Value '' -Encoding utf8
}
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    $line = ConvertTo-Json -Compress -InputObject ([ordered]@{
        id = $Id; result = $Result; note = $Note
    })
    Write-Host $line
    if ($JsonlPath) { Add-Content -Path $JsonlPath -Value $line -Encoding utf8 }
}

$ui = $null
try {
    # ----- SMOKE-01: Dashboard launches and FlaUI attaches
    try {
        $launchParams = @{ TimeoutSeconds = 45 }
        if ($ConfigPath) { $launchParams['ConfigPath'] = $ConfigPath }
        $ui = Start-SPDashboardForTest @launchParams
        Add-Result -Id 'SMOKE-01' -Result 'PASS' -Note "Window '$($ui.Window.Title)' attached (pid $($ui.Process.Id))"
    }
    catch {
        Add-Result -Id 'SMOKE-01' -Result 'FAIL' -Note "Launch/attach failed: $($_.Exception.Message)"
        Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1 }))
        exit 1
    }

    # ----- SMOKE-02: Title matches
    $expectedTitle = 'SailPoint ISC Governance Toolkit'
    if ($ui.Window.Title -eq $expectedTitle) {
        Add-Result -Id 'SMOKE-02' -Result 'PASS' -Note "Title = '$expectedTitle'"
    }
    else {
        Add-Result -Id 'SMOKE-02' -Result 'FAIL' -Note "Expected '$expectedTitle' got '$($ui.Window.Title)'"
    }

    # ----- SMOKE-03..07: Each tab is discoverable
    $expectedTabs = @('Campaigns', 'Evidence', 'Settings', 'Audit', 'Delta Cert')
    $i = 2
    foreach ($tabName in $expectedTabs) {
        $i++
        $id = "SMOKE-{0:D2}" -f $i
        try {
            $tab = Find-SPUiTab -Window $ui.Window -Header $tabName -TimeoutMs 3000
            Add-Result -Id $id -Result 'PASS' -Note "Tab '$tabName' found (AutomationId='$($tab.AutomationId)')"
        }
        catch {
            Add-Result -Id $id -Result 'FAIL' -Note "Tab '$tabName' not discoverable: $($_.Exception.Message)"
        }
    }

    # ----- SMOKE-08: Click Settings tab and wait for selection (proves we can drive controls)
    try {
        $settings = Find-SPUiTab -Window $ui.Window -Header 'Settings'
        $settings.Select()
        $deadline = (Get-Date).AddSeconds(3)
        $selected = $false
        while ((Get-Date) -lt $deadline) {
            if ($settings.IsSelected) { $selected = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if ($selected) {
            Add-Result -Id 'SMOKE-08' -Result 'PASS' -Note "Settings tab selected"
        }
        else {
            Add-Result -Id 'SMOKE-08' -Result 'FAIL' -Note "Settings.IsSelected never became true within 3s"
        }
    }
    catch {
        Add-Result -Id 'SMOKE-08' -Result 'FAIL' -Note "Select failed: $($_.Exception.Message)"
    }

    # ----- SMOKE-09: Screenshot (optional)
    if ($ScreenshotPath) {
        try {
            $path = Save-SPUiScreenshot -Element $ui.Window -Path $ScreenshotPath
            Add-Result -Id 'SMOKE-09' -Result 'PASS' -Note "Screenshot saved: $path"
        }
        catch {
            Add-Result -Id 'SMOKE-09' -Result 'FAIL' -Note "Screenshot failed: $($_.Exception.Message)"
        }
    }
}
finally {
    if ($ui) { Stop-SPDashboardForTest -UiContext $ui }
}

$pass = @($results | Where-Object result -eq 'PASS').Count
$fail = @($results | Where-Object result -eq 'FAIL').Count
$summary = ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = $pass; fail = $fail })
Write-Host $summary
if ($JsonlPath) { Add-Content -Path $JsonlPath -Value $summary -Encoding utf8 }
exit $(if ($fail -eq 0) { 0 } else { 1 })
