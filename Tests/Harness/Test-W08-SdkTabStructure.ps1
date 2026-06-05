#Requires -Version 5.1
<#
.SYNOPSIS
    W-08 headless GUI structure tests for the SDK Features tab.

.DESCRIPTION
    Loads Gui\MainWindow.xaml in the current (STA) PowerShell via XamlReader,
    locates the "SDK Features" TabItem's content (the SdkTabContent Grid), and
    walks the visual/logical tree to assert structural facts about the SDK tab:
    the nested TabControl, the six sub-tab headers, each sub-tab's required
    controls, and that every Btn*/Chk* control carries a non-empty ToolTip.

    This item is PURELY structural and headless. It does NOT import the GUI
    modules, does NOT call Initialize-SdkTab, does NOT touch any mock, and never
    .Show()s the window. The only WPF conventions exercised are note 5
    (XamlReader::Load) and note 1 (STA apartment for the harness process).

    NOTE: assertions are made against MainWindow.xaml (the runtime), NOT against
    the Gui\SdkTab.xaml design reference, which diverges from the live content
    (camelCase grid bindings; no static SdkCertBadge*/SdkApprovalBadge* count
    TextBlocks -- the summary panels are empty StackPanels filled dynamically).

.OUTPUTS
    JSONL per test to stdout, terminated by a {summary} line.
    Exit 0 if no FAILs; exit 1 if any FAIL.
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

# ----- Paths
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mainXaml    = Join-Path $toolkitRoot 'Gui\MainWindow.xaml'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml

# ----- Helpers
function Load-Xaml {
    param([string]$Path)
    $r = [System.Xml.XmlReader]::Create($Path)
    try { return [System.Windows.Markup.XamlReader]::Load($r) }
    finally { $r.Close() }
}

function Get-NamedControl {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$Name)
    if ($Root -is [System.Windows.FrameworkElement]) {
        $hit = $Root.FindName($Name)
        if ($null -ne $hit) { return $hit }
    }
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

function Test-ControlsPresent {
    # Returns the array of names that are NOT found under $Root.
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string[]]$Names)
    $missing = @()
    foreach ($n in $Names) {
        if (-not (Get-NamedControl -Root $Root -Name $n)) { $missing += $n }
    }
    return $missing
}

function Get-FrameworkElements {
    # Depth-first walk of the logical tree returning every FrameworkElement.
    param([Parameter(Mandatory)]$Root)
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($cur -is [System.Windows.FrameworkElement]) { $found.Add($cur) }
        try {
            $children = [System.Windows.LogicalTreeHelper]::GetChildren($cur)
            foreach ($c in $children) {
                if ($c -is [System.Windows.DependencyObject]) { $stack.Push($c) }
            }
        } catch { }
    }
    return $found
}

# ----- Load MainWindow + locate SDK Features tab content
$window = $null
try { $window = Load-Xaml -Path $mainXaml } catch { }
if ($null -eq $window) {
    Add-Result -Id 'WG-08-pre' -Result 'FAIL' -Note "Could not load MainWindow.xaml at '$mainXaml'"
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1; blocked = 0; total = 1 }))
    exit 1
}

$tabControl   = Get-NamedControl -Root $window -Name 'MainTabControl'
$sdkTabItem   = $null
$settingsIdx  = -1
$sdkIdx       = -1
if ($tabControl) {
    for ($i = 0; $i -lt $tabControl.Items.Count; $i++) {
        $hdr = $tabControl.Items[$i].Header
        if ($hdr -eq 'SDK Features') { $sdkTabItem = $tabControl.Items[$i]; $sdkIdx = $i }
        if ($hdr -eq 'Settings')     { $settingsIdx = $i }
    }
}
$sdkTabContent = if ($sdkTabItem) { $sdkTabItem.Content } else { $null }

# ----- WG-08-01: SDK Features tab exists (and precedes the Settings tab)
try {
    if (-not $tabControl) {
        Add-Result -Id 'WG-08-01' -Result 'FAIL' -Note "MainTabControl not found in MainWindow.xaml"
    } elseif (-not $sdkTabItem) {
        Add-Result -Id 'WG-08-01' -Result 'FAIL' -Note "No TabItem with Header 'SDK Features' found"
    } elseif ($settingsIdx -ge 0 -and $sdkIdx -ge $settingsIdx) {
        Add-Result -Id 'WG-08-01' -Result 'FAIL' -Note "SDK Features (index $sdkIdx) does not precede Settings (index $settingsIdx)"
    } else {
        Add-Result -Id 'WG-08-01' -Result 'PASS' -Note "SDK Features tab found at index $sdkIdx (precedes Settings at index $settingsIdx of $($tabControl.Items.Count) tabs)"
    }
} catch {
    Add-Result -Id 'WG-08-01' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-08-02: nested TabControl named SdkSubTabControl
$subTab = $null
try {
    $subTab = if ($sdkTabContent) { Get-NamedControl -Root $sdkTabContent -Name 'SdkSubTabControl' } else { $null }
    if (-not $sdkTabContent) {
        Add-Result -Id 'WG-08-02' -Result 'FAIL' -Note "SDK Features tab has no Content"
    } elseif (-not $subTab) {
        Add-Result -Id 'WG-08-02' -Result 'FAIL' -Note "Nested TabControl 'SdkSubTabControl' not found"
    } elseif ($subTab -isnot [System.Windows.Controls.TabControl]) {
        Add-Result -Id 'WG-08-02' -Result 'FAIL' -Note "SdkSubTabControl is a $($subTab.GetType().Name), expected TabControl"
    } else {
        Add-Result -Id 'WG-08-02' -Result 'PASS' -Note "Nested TabControl 'SdkSubTabControl' present"
    }
} catch {
    Add-Result -Id 'WG-08-02' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-08-03: exactly 6 sub-tabs, headers in order
try {
    if (-not $subTab) {
        Add-Result -Id 'WG-08-03' -Result 'FAIL' -Note "SdkSubTabControl not available"
    } else {
        $expected = @('Templates', 'Cert Summaries', 'Approvals', 'Work Items', 'Workflows', 'Filters')
        $actual = @($subTab.Items | ForEach-Object { [string]$_.Header })
        $ok = ($actual.Count -eq $expected.Count)
        for ($i = 0; $ok -and $i -lt $expected.Count; $i++) {
            if ($actual[$i] -ne $expected[$i]) { $ok = $false }
        }
        if ($ok) {
            Add-Result -Id 'WG-08-03' -Result 'PASS' -Note "6 sub-tabs in order: '$($actual -join "', '")'"
        } else {
            Add-Result -Id 'WG-08-03' -Result 'FAIL' -Note "Sub-tab mismatch. Expected '$($expected -join ', ')' got '$($actual -join ', ')'"
        }
    }
} catch {
    Add-Result -Id 'WG-08-03' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-08-04..09: required controls per sub-tab
$controlSets = [ordered]@{
    'WG-08-04' = @{ Label = 'Templates';      Names = @('SdkTemplateGrid', 'BtnSdkRefreshTemplates', 'BtnSdkNewTemplate', 'BtnSdkEditSchedule', 'BtnSdkRemoveSchedule', 'BtnSdkDeleteTemplate') }
    'WG-08-05' = @{ Label = 'Cert Summaries'; Names = @('CboSdkCertCampaign', 'CboSdkCertification', 'CboSdkAccessType', 'SdkCertSummaryGrid') }
    'WG-08-06' = @{ Label = 'Approvals';      Names = @('SdkApprovalGrid', 'RbSdkPending', 'RbSdkCompleted', 'BtnSdkApprove', 'BtnSdkDeny', 'BtnSdkForward') }
    'WG-08-07' = @{ Label = 'Work Items';     Names = @('SdkWorkItemGrid', 'BtnSdkRefreshWorkItems', 'BtnSdkCompleteWorkItem', 'BtnSdkForwardWorkItem', 'SdkWiBadgeOpen') }
    'WG-08-08' = @{ Label = 'Workflows';      Names = @('SdkWorkflowGrid', 'SdkExecutionGrid', 'BtnSdkTestWorkflow', 'BtnSdkCreateOOO') }
    'WG-08-09' = @{ Label = 'Filters';        Names = @('SdkFilterGrid', 'BtnSdkRefreshFilters', 'BtnSdkNewFilter', 'BtnSdkDeleteFilter', 'ChkSdkIncludeSystem') }
}
foreach ($id in $controlSets.Keys) {
    $set = $controlSets[$id]
    try {
        if (-not $sdkTabContent) {
            Add-Result -Id $id -Result 'FAIL' -Note "SDK tab content not available"
            continue
        }
        $missing = Test-ControlsPresent -Root $sdkTabContent -Names $set.Names
        if (@($missing).Count -eq 0) {
            Add-Result -Id $id -Result 'PASS' -Note "$($set.Label): all $(@($set.Names).Count) controls present"
        } else {
            Add-Result -Id $id -Result 'FAIL' -Note "$($set.Label): Missing: $($missing -join ', ')"
        }
    } catch {
        Add-Result -Id $id -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
    }
}

# ----- WG-08-10: every Btn*/Chk* in the SDK subtree has a non-empty ToolTip
try {
    if (-not $sdkTabContent) {
        Add-Result -Id 'WG-08-10' -Result 'FAIL' -Note "SDK tab content not available"
    } else {
        $elements = Get-FrameworkElements -Root $sdkTabContent
        $targets = @($elements | Where-Object {
            -not [string]::IsNullOrEmpty($_.Name) -and ($_.Name.StartsWith('Btn') -or $_.Name.StartsWith('Chk'))
        })
        $missing = @()
        foreach ($el in $targets) {
            $tt = $el.ToolTip
            $ttText = if ($tt -is [string]) { $tt } elseif ($null -ne $tt) { [string]$tt } else { $null }
            if ([string]::IsNullOrWhiteSpace($ttText)) { $missing += $el.Name }
        }
        if ($targets.Count -eq 0) {
            Add-Result -Id 'WG-08-10' -Result 'FAIL' -Note "No Btn*/Chk* controls found in SDK subtree"
        } elseif (@($missing).Count -eq 0) {
            Add-Result -Id 'WG-08-10' -Result 'PASS' -Note "All $($targets.Count) Btn*/Chk* controls have a non-empty ToolTip"
        } else {
            Add-Result -Id 'WG-08-10' -Result 'FAIL' -Note "$(@($missing).Count) of $($targets.Count) Btn*/Chk* controls missing ToolTip: $($missing -join ', ')"
        }
    }
} catch {
    Add-Result -Id 'WG-08-10' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- Summary
$pass    = ($results | Where-Object { $_.result -eq 'PASS' }).Count
$fail    = ($results | Where-Object { $_.result -eq 'FAIL' }).Count
$blocked = ($results | Where-Object { $_.result -eq 'BLOCKED' }).Count

Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = $results.Count
}))

if ($fail -gt 0) { exit 1 } else { exit 0 }
