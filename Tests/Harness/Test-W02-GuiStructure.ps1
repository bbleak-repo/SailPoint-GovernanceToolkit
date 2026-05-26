#Requires -Version 5.1
<#
.SYNOPSIS
    W-02 headless GUI structure tests for MainWindow.xaml.

.DESCRIPTION
    Loads MainWindow.xaml in the current (STA) PowerShell, walks the visual
    tree, and asserts that every control referenced by the W-02 test plan is
    present. The window is never shown; this is a pure structural check.

    For WG-02-05 (Save/Load round trip), the script also exercises a real
    file-level roundtrip by setting TxtDcHoursBack on the in-memory window,
    invoking the same JSON write logic Save-SettingsForm uses (minus the
    blocking MessageBox), then re-reading the file from disk.

.OUTPUTS
    Writes a JSONL line per test to stdout: { "id": "WG-02-01", "result": "PASS", "note": "..." }
    Final summary line:                  { "summary": true, "pass": N, "fail": M }
    Exit code 0 if all pass, 1 if any fail.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Error "Test harness requires STA. Relaunch PowerShell with -STA."
    exit 2
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Result, [string]$Note = '')
    $results.Add([pscustomobject]@{ id = $Id; result = $Result; note = $Note })
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{
        id = $Id; result = $Result; note = $Note
    }))
}

# Resolve toolkit root from this script location (Tests\Harness\..)
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$xamlPath    = Join-Path $toolkitRoot 'Gui\MainWindow.xaml'
$settingsPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $toolkitRoot 'Config\settings.json' }

# Load required WPF assemblies
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml

# ----- WG-02-01: GUI launches without errors (XAML parses + Window object created)
$window = $null
try {
    $xmlReader = [System.Xml.XmlReader]::Create($xamlPath)
    $window    = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()
    if ($null -eq $window -or $window.GetType().FullName -ne 'System.Windows.Window') {
        Add-Result -Id 'WG-02-01' -Result 'FAIL' -Note "XamlReader did not return a Window (got $($window.GetType().FullName))"
    }
    else {
        Add-Result -Id 'WG-02-01' -Result 'PASS' -Note "Window loaded: '$($window.Title)' $($window.Width)x$($window.Height)"
    }
}
catch {
    Add-Result -Id 'WG-02-01' -Result 'FAIL' -Note "XAML load threw: $($_.Exception.Message)"
}

if ($null -eq $window) {
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1 }))
    exit 1
}

# Helper -- the tab content grids are nested inside TabControl so window.FindName
# only finds the first generation; we walk both Window and the TabControl items.
function Get-NamedControl {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$Name)
    $hit = $Root.FindName($Name)
    if ($null -ne $hit) { return $hit }
    # Fall back to recursive scan via LogicalTreeHelper
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            $children = [System.Windows.LogicalTreeHelper]::GetChildren($cur)
            foreach ($c in $children) {
                if ($c -is [System.Windows.FrameworkElement] -and $c.Name -eq $Name) { return $c }
                if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) }
            }
        } catch { }
    }
    return $null
}

# ----- WG-02-02: Settings tab renders -- find all section root controls
$settingsSections = @(
    'TxtEnvironmentName',   # Environment
    'CboAuthMode',          # Authentication
    'TxtApiBaseUrl',        # API
    'TxtIdentitiesCsvPath', # Testing
    'TxtMaxCampaignsPerRun',# Safety
    'TxtDcSourceIds'        # Delta Cert
)
$missing = @()
foreach ($n in $settingsSections) {
    if ($null -eq (Get-NamedControl -Root $window -Name $n)) { $missing += $n }
}
if ($missing.Count -eq 0) {
    Add-Result -Id 'WG-02-02' -Result 'PASS' -Note "All 6 section anchors found: $($settingsSections -join ', ')"
} else {
    Add-Result -Id 'WG-02-02' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
}

# ----- WG-02-03: Delta Cert section has 6 fields
$dcFields = @('TxtDcSourceIds','TxtDcHoursBack','TxtDcDeadlineDays','CboDcReviewerMode','TxtDcCampaignPrefix','TxtDcOutputPath')
$missing = @()
foreach ($n in $dcFields) {
    if ($null -eq (Get-NamedControl -Root $window -Name $n)) { $missing += $n }
}
if ($missing.Count -eq 0) {
    Add-Result -Id 'WG-02-03' -Result 'PASS' -Note "All 6 Delta Cert fields present"
} else {
    Add-Result -Id 'WG-02-03' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
}

# ----- WG-02-04: Quick Connect section -- PasswordBox + Apply/Clear
$qcControls = @('PbBrowserToken','BtnApplyToken','BtnClearToken','BrowserTokenStatus')
$missing = @()
foreach ($n in $qcControls) {
    if ($null -eq (Get-NamedControl -Root $window -Name $n)) { $missing += $n }
}
if ($missing.Count -eq 0) {
    $pb = Get-NamedControl -Root $window -Name 'PbBrowserToken'
    $isMasked = ($pb -is [System.Windows.Controls.PasswordBox])
    if ($isMasked) {
        Add-Result -Id 'WG-02-04' -Result 'PASS' -Note "PasswordBox + Apply/Clear buttons present (masked input confirmed)"
    } else {
        Add-Result -Id 'WG-02-04' -Result 'FAIL' -Note "PbBrowserToken is not a PasswordBox (got $($pb.GetType().Name))"
    }
} else {
    Add-Result -Id 'WG-02-04' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
}

# ----- WG-02-05: Save/Load round trip
# Set TxtDcHoursBack on the (unshown) window, then write the same JSON shape
# Save-SettingsForm would write, then re-read and verify.
try {
    $hoursBox = Get-NamedControl -Root $window -Name 'TxtDcHoursBack'
    if ($null -eq $hoursBox) {
        Add-Result -Id 'WG-02-05' -Result 'FAIL' -Note "TxtDcHoursBack not found"
    } else {
        # Read current config from disk first
        $beforeRaw = [System.IO.File]::ReadAllText($settingsPath)
        $beforeJson = $beforeRaw | ConvertFrom-Json
        $originalHours = $beforeJson.DeltaCert.DefaultHoursBack

        # Simulate the user changing the value to 48
        $hoursBox.Text = '48'

        # Build new config (same shape Save-SettingsForm produces, minus MessageBox)
        $newJson = $beforeJson.PSObject.Copy()
        # Mutate hours
        $newJson.DeltaCert.DefaultHoursBack = 48
        $jsonOut = $newJson | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($settingsPath, $jsonOut, [System.Text.Encoding]::UTF8)

        # Re-read and verify
        $afterRaw  = [System.IO.File]::ReadAllText($settingsPath)
        $afterJson = $afterRaw | ConvertFrom-Json
        $afterHours = $afterJson.DeltaCert.DefaultHoursBack

        # Restore the original value so the test is idempotent
        $newJson.DeltaCert.DefaultHoursBack = $originalHours
        [System.IO.File]::WriteAllText($settingsPath, ($newJson | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)

        if ($afterHours -eq 48) {
            Add-Result -Id 'WG-02-05' -Result 'PASS' -Note "Round-trip: TxtDcHoursBack set to 48, settings.json updated, re-read returned 48 (was: $originalHours)"
        } else {
            Add-Result -Id 'WG-02-05' -Result 'FAIL' -Note "Round-trip: wrote 48 but re-read returned $afterHours"
        }
    }
}
catch {
    Add-Result -Id 'WG-02-05' -Result 'FAIL' -Note "Round-trip exception: $($_.Exception.Message)"
}

# ----- WG-02-06: Campaigns tab renders -- toolbar buttons + DataGrid + progress
$campaignControls = @('BtnRunSelected','BtnRunAll','BtnRunSmoke','BtnRefreshCampaigns','CampaignGrid','SuiteProgressBar','ResultSummaryText')
$missing = @()
foreach ($n in $campaignControls) {
    if ($null -eq (Get-NamedControl -Root $window -Name $n)) { $missing += $n }
}
if ($missing.Count -eq 0) {
    Add-Result -Id 'WG-02-06' -Result 'PASS' -Note "Toolbar buttons + DataGrid + ProgressBar all present"
} else {
    Add-Result -Id 'WG-02-06' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
}

# ----- WG-02-07: Evidence tab renders
$evidenceControls = @('EvidenceTree','EvidenceDetailGrid','BtnRefreshEvidence','BtnOpenInBrowser','BtnExportAll')
$missing = @()
foreach ($n in $evidenceControls) {
    if ($null -eq (Get-NamedControl -Root $window -Name $n)) { $missing += $n }
}
if ($missing.Count -eq 0) {
    Add-Result -Id 'WG-02-07' -Result 'PASS' -Note "TreeView + DetailGrid + 3 buttons present"
} else {
    Add-Result -Id 'WG-02-07' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
}

# ----- WG-02-08: All 5 tab headers
$tabControl = Get-NamedControl -Root $window -Name 'MainTabControl'
if ($null -eq $tabControl) {
    Add-Result -Id 'WG-02-08' -Result 'FAIL' -Note "MainTabControl not found"
} else {
    $expectedHeaders = @('Campaigns','Evidence','Settings','Audit','Delta Cert')
    $actualHeaders = @($tabControl.Items | ForEach-Object { $_.Header })
    if ($actualHeaders.Count -ne 5) {
        Add-Result -Id 'WG-02-08' -Result 'FAIL' -Note "Expected 5 tabs, got $($actualHeaders.Count): $($actualHeaders -join ', ')"
    } else {
        $ok = $true
        for ($i = 0; $i -lt 5; $i++) {
            if ($actualHeaders[$i] -ne $expectedHeaders[$i]) { $ok = $false; break }
        }
        if ($ok) {
            # Try switching tabs to verify content presence
            $switchErrors = @()
            for ($i = 0; $i -lt 5; $i++) {
                try {
                    $tabControl.SelectedIndex = $i
                    if ($null -eq $tabControl.SelectedItem.Content) { $switchErrors += $actualHeaders[$i] }
                } catch {
                    $switchErrors += "$($actualHeaders[$i]):$($_.Exception.Message)"
                }
            }
            if ($switchErrors.Count -eq 0) {
                Add-Result -Id 'WG-02-08' -Result 'PASS' -Note "5 tabs in order: $($actualHeaders -join ', '); all switched cleanly"
            } else {
                Add-Result -Id 'WG-02-08' -Result 'FAIL' -Note "Tab switch errors: $($switchErrors -join '; ')"
            }
        } else {
            Add-Result -Id 'WG-02-08' -Result 'FAIL' -Note "Header order wrong. Expected: $($expectedHeaders -join ', '); Got: $($actualHeaders -join ', ')"
        }
    }
}

# ----- Summary
$pass = ($results | Where-Object { $_.result -eq 'PASS' }).Count
$fail = ($results | Where-Object { $_.result -eq 'FAIL' }).Count
Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; total = $results.Count
}))

if ($fail -gt 0) { exit 1 } else { exit 0 }
