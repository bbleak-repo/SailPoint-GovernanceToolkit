#Requires -Version 5.1
<#
.SYNOPSIS
    W-09c headless GUI structure tests for the Enriched Reports section of the
    Adaptive Reports tab.

.DESCRIPTION
    Loads Gui\MainWindow.xaml in the current (STA) PowerShell via XamlReader,
    locates the "Adaptive Reports" TabItem's content (the AdaptiveReportsTabContent
    Grid), and asserts structural facts about the NEW Enriched Reports surface
    (T-05): the four ChkArEnriched* checkboxes that feed the existing Generate
    handler chain, that each carries a non-empty ToolTip, and that the reused
    BtnArGenerate action button is still present.

    W-09 (Test-W09-AdaptiveTabStructure.ps1) already covers the legacy controls;
    this harness asserts ONLY the new enriched surface plus a couple of regression
    anchors so the additive nature of the change is provable headlessly.

    This item is PURELY structural and headless. It does NOT import the GUI
    modules, does NOT call Initialize-SPAdaptiveTab, does NOT touch any mock, and
    never .Show()s the window.

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

# ----- Load MainWindow + locate Adaptive Reports tab content
$window = $null
try { $window = Load-Xaml -Path $mainXaml } catch { }
if ($null -eq $window) {
    Add-Result -Id 'WG-09c-pre' -Result 'FAIL' -Note "Could not load MainWindow.xaml at '$mainXaml'"
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1; blocked = 0; total = 1 }))
    exit 1
}

$tabControl       = Get-NamedControl -Root $window -Name 'MainTabControl'
$adaptiveTabItem  = $null
$adaptiveIdx      = -1
if ($tabControl) {
    for ($i = 0; $i -lt $tabControl.Items.Count; $i++) {
        $hdr = $tabControl.Items[$i].Header
        if ($hdr -eq 'Adaptive Reports') { $adaptiveTabItem = $tabControl.Items[$i]; $adaptiveIdx = $i }
    }
}
$adaptiveTabContent = if ($adaptiveTabItem) { $adaptiveTabItem.Content } else { $null }

$enrichedNames = @(
    'ChkArEnrichedPrivilegedAttestation',
    'ChkArEnrichedAccountability',
    'ChkArEnrichedTrend',
    'ChkArEnrichedDisconnected'
)

# ----- WG-09c-01: container Grid named AdaptiveReportsTabContent present
try {
    if (-not $adaptiveTabContent) {
        Add-Result -Id 'WG-09c-01' -Result 'FAIL' -Note "Adaptive Reports tab has no Content"
    } else {
        $grid = $null
        if ($adaptiveTabContent -is [System.Windows.FrameworkElement] -and $adaptiveTabContent.Name -eq 'AdaptiveReportsTabContent') {
            $grid = $adaptiveTabContent
        } else {
            $grid = Get-NamedControl -Root $adaptiveTabContent -Name 'AdaptiveReportsTabContent'
        }
        if (-not $grid) {
            Add-Result -Id 'WG-09c-01' -Result 'FAIL' -Note "Container 'AdaptiveReportsTabContent' not found"
        } else {
            Add-Result -Id 'WG-09c-01' -Result 'PASS' -Note "Container Grid 'AdaptiveReportsTabContent' present ($($grid.GetType().Name))"
        }
    }
} catch {
    Add-Result -Id 'WG-09c-01' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-09c-02: all four ChkArEnriched checkboxes present
try {
    if (-not $adaptiveTabContent) {
        Add-Result -Id 'WG-09c-02' -Result 'FAIL' -Note "Adaptive Reports tab content not available"
    } else {
        $missing = Test-ControlsPresent -Root $adaptiveTabContent -Names $enrichedNames
        if (@($missing).Count -eq 0) {
            Add-Result -Id 'WG-09c-02' -Result 'PASS' -Note "Enriched checkboxes: all $(@($enrichedNames).Count) controls present"
        } else {
            Add-Result -Id 'WG-09c-02' -Result 'FAIL' -Note "Enriched checkboxes: Missing: $($missing -join ', ')"
        }
    }
} catch {
    Add-Result -Id 'WG-09c-02' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-09c-03: every ChkArEnriched control has a non-empty ToolTip
try {
    if (-not $adaptiveTabContent) {
        Add-Result -Id 'WG-09c-03' -Result 'FAIL' -Note "Adaptive Reports tab content not available"
    } else {
        $elements = Get-FrameworkElements -Root $adaptiveTabContent
        $targets = @($elements | Where-Object {
            -not [string]::IsNullOrEmpty($_.Name) -and $_.Name.StartsWith('ChkArEnriched')
        })
        $missing = @()
        foreach ($el in $targets) {
            $tt = $el.ToolTip
            $ttText = if ($tt -is [string]) { $tt } elseif ($null -ne $tt) { [string]$tt } else { $null }
            if ([string]::IsNullOrWhiteSpace($ttText)) { $missing += $el.Name }
        }
        if ($targets.Count -eq 0) {
            Add-Result -Id 'WG-09c-03' -Result 'FAIL' -Note "No ChkArEnriched* controls found in Adaptive Reports subtree"
        } elseif (@($missing).Count -eq 0) {
            Add-Result -Id 'WG-09c-03' -Result 'PASS' -Note "All $($targets.Count) ChkArEnriched* controls have a non-empty ToolTip"
        } else {
            Add-Result -Id 'WG-09c-03' -Result 'FAIL' -Note "$(@($missing).Count) of $($targets.Count) ChkArEnriched* controls missing ToolTip: $($missing -join ', ')"
        }
    }
} catch {
    Add-Result -Id 'WG-09c-03' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-09c-04: BtnArGenerate still present (proves Generate button reused, not broken)
try {
    if (-not $adaptiveTabContent) {
        Add-Result -Id 'WG-09c-04' -Result 'FAIL' -Note "Adaptive Reports tab content not available"
    } else {
        $btn = Get-NamedControl -Root $adaptiveTabContent -Name 'BtnArGenerate'
        if (-not $btn) {
            Add-Result -Id 'WG-09c-04' -Result 'FAIL' -Note "BtnArGenerate not found -- the reused Generate button is missing"
        } else {
            Add-Result -Id 'WG-09c-04' -Result 'PASS' -Note "BtnArGenerate present ($($btn.GetType().Name)) -- Generate button reused for enriched reports"
        }
    }
} catch {
    Add-Result -Id 'WG-09c-04' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- Summary
$pass    = ($results | Where-Object { $_.result -eq 'PASS' }).Count
$fail    = ($results | Where-Object { $_.result -eq 'FAIL' }).Count
$blocked = ($results | Where-Object { $_.result -eq 'BLOCKED' }).Count

Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = $results.Count
}))

if ($fail -gt 0) { exit 1 } else { exit 0 }
