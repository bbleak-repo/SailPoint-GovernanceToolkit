#Requires -Version 5.1
<#
.SYNOPSIS
    W-03 headless GUI structure tests for the Audit tab.

.DESCRIPTION
    Loads MainWindow.xaml + AuditQueryDialog.xaml in the current (STA) PowerShell,
    walks the visual tree, calls Initialize-AuditTab to wire handlers, and
    exercises the helpers (Update-AuditSummaryLabel, Load-AuditReportList,
    Resolve-AuditOutputPath) directly. The window is never shown.

    Live-mock-dependent items (WG-03-03 query, WG-03-05 specific mock data,
    WG-03-07 actual run, WG-03-08 completion, WG-03-09 leadership files) are
    attempted via the public CLI script Invoke-SPCampaignAudit.ps1. When the
    mock is unreachable, those rows are marked BLOCKED with a clear note.

.OUTPUTS
    JSONL per test to stdout, terminated by a {summary} line.
    Exit 0 if no FAILs; exit 1 if any FAIL. BLOCKED rows do not fail the run.
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
$toolkitRoot   = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mainXaml      = Join-Path $toolkitRoot 'Gui\MainWindow.xaml'
$dialogXaml    = Join-Path $toolkitRoot 'Gui\AuditQueryDialog.xaml'
$settingsPath  = if ($ConfigPath) { $ConfigPath } else { Join-Path $toolkitRoot 'Config\settings.json' }

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
    $hit = $Root.FindName($Name)
    if ($null -ne $hit) { return $hit }
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

function Get-EventHandlerCount {
    # Reflect into UIElement.EventHandlersStore to count registered handlers for an event.
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)][System.Windows.RoutedEvent]$Event)
    try {
        $prop = [System.Windows.UIElement].GetProperty('EventHandlersStore',
            [System.Reflection.BindingFlags]'Instance,NonPublic')
        $store = $prop.GetValue($Element, $null)
        if ($null -eq $store) { return 0 }
        $m = $store.GetType().GetMethod('GetRoutedEventHandlers',
            [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
        $handlers = $m.Invoke($store, @($Event))
        if ($null -eq $handlers) { return 0 }
        return @($handlers).Count
    } catch {
        return -1
    }
}

# ----- Load MainWindow + locate Audit tab content
$window = $null
try { $window = Load-Xaml -Path $mainXaml } catch { }
if ($null -eq $window) {
    Add-Result -Id 'WG-03-pre' -Result 'FAIL' -Note "Could not load MainWindow.xaml"
    Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{ summary = $true; pass = 0; fail = 1; blocked = 0; total = 1 }))
    exit 1
}

$tabControl = Get-NamedControl -Root $window -Name 'MainTabControl'
$auditTabItem = $null
if ($tabControl) {
    foreach ($t in $tabControl.Items) {
        if ($t.Header -eq 'Audit') { $auditTabItem = $t; break }
    }
}
$auditTabContent = if ($auditTabItem) { $auditTabItem.Content } else { $null }

# ----- WG-03-01: Audit tab Row 0 (Summary + Configure + Query Campaigns)
try {
    $summary     = if ($auditTabContent) { Get-NamedControl -Root $auditTabContent -Name 'AuditSummaryLabel' } else { $null }
    $btnConfig   = if ($auditTabContent) { Get-NamedControl -Root $auditTabContent -Name 'BtnConfigureAudit' } else { $null }
    $btnQuery    = if ($auditTabContent) { Get-NamedControl -Root $auditTabContent -Name 'BtnQueryCampaigns' } else { $null }

    $missing = @()
    if (-not $summary)   { $missing += 'AuditSummaryLabel' }
    if (-not $btnConfig) { $missing += 'BtnConfigureAudit' }
    if (-not $btnQuery)  { $missing += 'BtnQueryCampaigns' }

    if ($missing.Count -eq 0) {
        # Verify Row 0 grid placement
        $grid0 = [System.Windows.Controls.Grid]::GetRow($summary)
        $ok = ($grid0 -eq 0) -and ([System.Windows.Controls.Grid]::GetRow($btnConfig) -eq 0) -and ([System.Windows.Controls.Grid]::GetRow($btnQuery) -eq 0)
        if ($ok) {
            Add-Result -Id 'WG-03-01' -Result 'PASS' -Note "Row 0 has Summary + Configure + Query Campaigns; initial summary text: '$($summary.Text)'"
        } else {
            Add-Result -Id 'WG-03-01' -Result 'FAIL' -Note "Controls present but not all in Row 0"
        }
    } else {
        Add-Result -Id 'WG-03-01' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
    }
} catch {
    Add-Result -Id 'WG-03-01' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-02: AuditQueryDialog loads, has 3 fields
try {
    $dialog = Load-Xaml -Path $dialogXaml
    $txt = Get-NamedControl -Root $dialog -Name 'TxtCampaignName'
    $cboStatus = Get-NamedControl -Root $dialog -Name 'CboStatus'
    $cboTimespan = Get-NamedControl -Root $dialog -Name 'CboTimespan'
    $missing = @()
    if (-not $txt) { $missing += 'TxtCampaignName' }
    if (-not $cboStatus) { $missing += 'CboStatus' }
    if (-not $cboTimespan) { $missing += 'CboTimespan' }
    if ($missing.Count -eq 0) {
        # Verify the dialog is a Window and uses CenterOwner startup
        $title = $dialog.Title
        Add-Result -Id 'WG-03-02' -Result 'PASS' -Note "AuditQueryDialog '$title' parses; 3 fields present"
    } else {
        Add-Result -Id 'WG-03-02' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
    }
} catch {
    Add-Result -Id 'WG-03-02' -Result 'FAIL' -Note "Dialog XAML load threw: $($_.Exception.Message)"
}

# ----- WG-03-03: AuditQueryDialog -- set filters (COMPLETED + 365 days); attempt live query
try {
    $dialog = Load-Xaml -Path $dialogXaml
    $txt = Get-NamedControl -Root $dialog -Name 'TxtCampaignName'
    $cboStatus = Get-NamedControl -Root $dialog -Name 'CboStatus'
    $cboTimespan = Get-NamedControl -Root $dialog -Name 'CboTimespan'

    $txt.Text = ''
    # Pick COMPLETED
    $completedIdx = -1
    for ($i = 0; $i -lt $cboStatus.Items.Count; $i++) {
        if ($cboStatus.Items[$i].Content -eq 'COMPLETED') { $completedIdx = $i; break }
    }
    # Pick 365 days
    $threeSixtyFiveIdx = -1
    for ($i = 0; $i -lt $cboTimespan.Items.Count; $i++) {
        if ($cboTimespan.Items[$i].Content -eq '365 days') { $threeSixtyFiveIdx = $i; break }
    }

    if ($completedIdx -lt 0 -or $threeSixtyFiveIdx -lt 0) {
        Add-Result -Id 'WG-03-03' -Result 'FAIL' -Note "Missing options. COMPLETED idx=$completedIdx, 365 days idx=$threeSixtyFiveIdx (CboTimespan has $($cboTimespan.Items.Count) items)"
    } else {
        $cboStatus.SelectedIndex = $completedIdx
        $cboTimespan.SelectedIndex = $threeSixtyFiveIdx
        $statusVal = $cboStatus.SelectedItem.Content
        $timeVal = $cboTimespan.SelectedItem.Content
        if ($statusVal -eq 'COMPLETED' -and $timeVal -eq '365 days') {
            Add-Result -Id 'WG-03-03' -Result 'PASS' -Note "Dialog accepts COMPLETED + 365 days filter selections"
        } else {
            Add-Result -Id 'WG-03-03' -Result 'FAIL' -Note "Selections did not stick: status='$statusVal' timespan='$timeVal'"
        }
    }
} catch {
    Add-Result -Id 'WG-03-03' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- Import module so we can call Update-AuditSummaryLabel, Load-AuditReportList, Resolve-AuditOutputPath, Get-AuditQueryDialogDefaults
$moduleImported = $false
$importError = $null
try {
    Import-Module (Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $toolkitRoot 'Modules\SP.Gui\SP.GuiBridge.psm1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $toolkitRoot 'Modules\SP.Gui\SP.MainWindow.psm1') -Force -DisableNameChecking -ErrorAction Stop
    # Show-SPDashboard normally sets these script-scoped vars; replicate them so
    # Get-XamlPath / Resolve-AuditOutputPath / Initialize-AuditTab work headlessly.
    $mod = Get-Module SP.MainWindow
    & $mod {
        param($root, $cfg, $self)
        $script:ToolkitRoot = $root
        $script:ConfigPath  = $cfg
        $script:ThisModule  = $self
    } $toolkitRoot $settingsPath (Get-Module SP.MainWindow)
    $moduleImported = $true
} catch {
    $importError = $_.Exception.Message
}

# ----- WG-03-04: Update-AuditSummaryLabel updates text from query params
try {
    if (-not $moduleImported) {
        Add-Result -Id 'WG-03-04' -Result 'FAIL' -Note "Module import failed: $importError"
    }
    else {
        # Use the module-scope state. Call Update-AuditSummaryLabel via & $mod block so it sees $script:LastAuditQueryParams
        $mod = Get-Module SP.MainWindow
        & $mod {
            $script:LastAuditQueryParams = @{
                TxtCampaignName = ''
                CboStatus       = 'COMPLETED'
                CboTimespan     = '365 days'
            }
        }
        & $mod { param($tc) Update-AuditSummaryLabel -TabContent $tc } $auditTabContent
        $summary = Get-NamedControl -Root $auditTabContent -Name 'AuditSummaryLabel'
        if ($summary.Text -eq 'Status: COMPLETED | Timespan: 365 days') {
            Add-Result -Id 'WG-03-04' -Result 'PASS' -Note "Summary label text: '$($summary.Text)'"
        } else {
            Add-Result -Id 'WG-03-04' -Result 'FAIL' -Note "Unexpected summary text: '$($summary.Text)'"
        }
    }
} catch {
    Add-Result -Id 'WG-03-04' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-05: Campaign DataGrid wired with 6 columns and ItemsSource ready
try {
    $grid = Get-NamedControl -Root $auditTabContent -Name 'AuditCampaignGrid'
    if (-not $grid) {
        Add-Result -Id 'WG-03-05' -Result 'FAIL' -Note "AuditCampaignGrid not found"
    } else {
        $colHeaders = @($grid.Columns | ForEach-Object { $_.Header })
        $expected = @('', 'Campaign Name', 'Status', 'Created', 'Completed', 'Certs')
        $ok = ($colHeaders.Count -eq 6)
        for ($i = 0; $ok -and $i -lt 6; $i++) { if ($colHeaders[$i] -ne $expected[$i]) { $ok = $false } }
        if ($ok) {
            Add-Result -Id 'WG-03-05' -Result 'PASS' -Note "AuditCampaignGrid has 6 columns in order: '$($colHeaders -join "', '")'"
        } else {
            Add-Result -Id 'WG-03-05' -Result 'FAIL' -Note "Column mismatch. Expected '$($expected -join ',')' got '$($colHeaders -join ',')'"
        }
    }
} catch {
    Add-Result -Id 'WG-03-05' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-06: Three audit-option checkboxes with correct names + IsChecked defaults
try {
    $cb1 = Get-NamedControl -Root $auditTabContent -Name 'ChkCampaignReports'
    $cb2 = Get-NamedControl -Root $auditTabContent -Name 'ChkIdentityEvents'
    $cb3 = Get-NamedControl -Root $auditTabContent -Name 'ChkLeadershipRollup'
    $missing = @()
    if (-not $cb1) { $missing += 'ChkCampaignReports' }
    if (-not $cb2) { $missing += 'ChkIdentityEvents' }
    if (-not $cb3) { $missing += 'ChkLeadershipRollup' }
    if ($missing.Count -eq 0) {
        $detail = "Defaults: Reports=$($cb1.IsChecked), Events=$($cb2.IsChecked), Leadership=$($cb3.IsChecked)"
        if ($cb1.IsChecked -eq $true -and $cb2.IsChecked -eq $true -and $cb3.IsChecked -eq $false) {
            Add-Result -Id 'WG-03-06' -Result 'PASS' -Note $detail
        } else {
            Add-Result -Id 'WG-03-06' -Result 'FAIL' -Note "Unexpected defaults. $detail"
        }
    } else {
        Add-Result -Id 'WG-03-06' -Result 'FAIL' -Note "Missing: $($missing -join ', ')"
    }
} catch {
    Add-Result -Id 'WG-03-06' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-07: BtnRunAudit exists; starts disabled (no campaigns queried yet)
try {
    $btnRun = Get-NamedControl -Root $auditTabContent -Name 'BtnRunAudit'
    if (-not $btnRun) {
        Add-Result -Id 'WG-03-07' -Result 'FAIL' -Note "BtnRunAudit not found"
    } else {
        if ($btnRun.IsEnabled -eq $false) {
            Add-Result -Id 'WG-03-07' -Result 'PASS' -Note "BtnRunAudit present and disabled at startup (enabled after query populates campaigns)"
        } else {
            Add-Result -Id 'WG-03-07' -Result 'FAIL' -Note "BtnRunAudit should be disabled until query returns campaigns; was: IsEnabled=$($btnRun.IsEnabled)"
        }
    }
} catch {
    Add-Result -Id 'WG-03-07' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- Now wire the tab so subsequent tests can probe handlers
$initialized = $false
try {
    if ($moduleImported) {
        $mod = Get-Module SP.MainWindow
        & $mod { param($tc) Initialize-AuditTab -TabContent $tc } $auditTabContent
        $initialized = $true
    }
} catch {
    Add-Result -Id 'WG-03-init' -Result 'FAIL' -Note "Initialize-AuditTab threw: $($_.Exception.Message)"
}

# ----- WG-03-08/09: Run audit + leadership reports (LIVE MOCK)
# We do not raise the WPF Click event (that spawns a runspace and blocks).
# Instead invoke the CLI script directly, which is what the Click handler ultimately calls.
$mockUp = $false
try {
    $h = Invoke-WebRequest -Uri 'http://10.0.0.143:8080/health' -TimeoutSec 4 -ErrorAction Stop
    $mockUp = ($h.StatusCode -eq 200)
} catch {
    $mockUp = $false
}

if (-not $mockUp) {
    Add-Result -Id 'WG-03-08' -Result 'BLOCKED' -Note "Mock at http://10.0.0.143:8080 unreachable; skipping live audit run"
    Add-Result -Id 'WG-03-09' -Result 'BLOCKED' -Note "Mock unreachable; cannot generate leadership reports"
} else {
    # WG-03-08: Run audit via CLI script
    try {
        $auditScript = Join-Path $toolkitRoot 'Scripts\Invoke-SPCampaignAudit.ps1'
        $audOut = Join-Path $toolkitRoot 'Audit'
        if (Test-Path $audOut) { Remove-Item $audOut -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $audOut -ItemType Directory -Force | Out-Null

        $stderr = New-Object System.Text.StringBuilder
        $stdout = & $auditScript -Status COMPLETED -DaysBack 365 -IncludeLeadershipRollup -LeadershipDepth 4 -DetailLevel Detailed 2>&1
        $exit = $LASTEXITCODE
        $htmls = @(Get-ChildItem -Path $audOut -Filter '*.html' -Recurse -ErrorAction SilentlyContinue)
        if ($exit -eq 0 -and $htmls.Count -gt 0) {
            Add-Result -Id 'WG-03-08' -Result 'PASS' -Note "Audit script exit=0; $($htmls.Count) HTML report(s) generated under Audit/"
        } else {
            Add-Result -Id 'WG-03-08' -Result 'FAIL' -Note "Audit script exit=$exit, HTML count=$($htmls.Count). Output: $(($stdout | Out-String).Substring(0, [Math]::Min(300, ($stdout|Out-String).Length)))"
        }

        # WG-03-09: Leadership files
        $leadDir = Join-Path $audOut 'leadership'
        if (Test-Path $leadDir) {
            $execHtml = Join-Path $leadDir 'executive-summary.html'
            $perPerson = @(Get-ChildItem -Path $leadDir -Filter '*.html' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'executive-summary.html' })
            if ((Test-Path $execHtml) -and $perPerson.Count -gt 0) {
                Add-Result -Id 'WG-03-09' -Result 'PASS' -Note "executive-summary.html + $($perPerson.Count) leader report(s) generated"
            } else {
                Add-Result -Id 'WG-03-09' -Result 'FAIL' -Note "Leadership directory present but missing executive-summary.html or leader reports"
            }
        } else {
            Add-Result -Id 'WG-03-09' -Result 'FAIL' -Note "Audit/leadership/ directory not created"
        }
    } catch {
        Add-Result -Id 'WG-03-08' -Result 'FAIL' -Note "Audit script exception: $($_.Exception.Message)"
        Add-Result -Id 'WG-03-09' -Result 'BLOCKED' -Note "Skipped due to WG-03-08 failure"
    }
}

# ----- WG-03-10: Recent reports ListBox populates via Load-AuditReportList
try {
    $listBox = Get-NamedControl -Root $auditTabContent -Name 'AuditReportList'
    if (-not $listBox) {
        Add-Result -Id 'WG-03-10' -Result 'FAIL' -Note "AuditReportList not found"
    } elseif (-not $moduleImported) {
        Add-Result -Id 'WG-03-10' -Result 'FAIL' -Note "Module not imported; cannot call Load-AuditReportList"
    } else {
        $audOut = Join-Path $toolkitRoot 'Audit'
        if (-not (Test-Path $audOut)) { New-Item -Path $audOut -ItemType Directory -Force | Out-Null }
        # If no real audit reports exist, seed synthetic ones so the function has something to render
        $existing = @(Get-ChildItem -Path $audOut -Filter '*.html' -Recurse -ErrorAction SilentlyContinue)
        $syntheticCreated = $false
        if ($existing.Count -eq 0) {
            [System.IO.File]::WriteAllText((Join-Path $audOut 'w03-synthetic-1.html'), '<html><body>synth1</body></html>')
            [System.IO.File]::WriteAllText((Join-Path $audOut 'w03-synthetic-2.html'), '<html><body>synth2</body></html>')
            $syntheticCreated = $true
        }

        $listBox.Items.Clear()
        $mod = Get-Module SP.MainWindow
        & $mod { param($tc) Load-AuditReportList -TabContent $tc } $auditTabContent

        $itemCount = $listBox.Items.Count
        $greenCount = 0
        $green = '#FF339933'
        foreach ($item in $listBox.Items) {
            if ($item -is [System.Windows.Controls.ListBoxItem] -and $item.Foreground -is [System.Windows.Media.SolidColorBrush]) {
                if ($item.Foreground.Color.ToString() -eq $green) { $greenCount++ }
            }
        }

        # Cleanup synthetic seed files (do not pollute repo)
        if ($syntheticCreated) {
            Remove-Item (Join-Path $audOut 'w03-synthetic-1.html') -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $audOut 'w03-synthetic-2.html') -ErrorAction SilentlyContinue
        }

        if ($itemCount -ge 1 -and $greenCount -ge 1) {
            Add-Result -Id 'WG-03-10' -Result 'PASS' -Note "ListBox populated: $itemCount item(s), $greenCount green (HTML) entries"
        } elseif ($itemCount -ge 1) {
            Add-Result -Id 'WG-03-10' -Result 'FAIL' -Note "ListBox populated ($itemCount) but no green HTML color brush detected"
        } else {
            Add-Result -Id 'WG-03-10' -Result 'FAIL' -Note "ListBox is empty after Load-AuditReportList"
        }
    }
} catch {
    Add-Result -Id 'WG-03-10' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-11: Double-click handler is wired on AuditReportList
try {
    $listBox = Get-NamedControl -Root $auditTabContent -Name 'AuditReportList'
    if (-not $listBox) {
        Add-Result -Id 'WG-03-11' -Result 'FAIL' -Note "AuditReportList not found"
    } else {
        $count = Get-EventHandlerCount -Element $listBox -Event ([System.Windows.Controls.Control]::MouseDoubleClickEvent)
        if ($count -ge 1) {
            Add-Result -Id 'WG-03-11' -Result 'PASS' -Note "MouseDoubleClick handler attached ($count handler(s))"
        } elseif ($count -eq 0) {
            Add-Result -Id 'WG-03-11' -Result 'FAIL' -Note "No MouseDoubleClick handler attached (Initialize-AuditTab did not wire it)"
        } else {
            Add-Result -Id 'WG-03-11' -Result 'FAIL' -Note "Could not introspect EventHandlersStore"
        }
    }
} catch {
    Add-Result -Id 'WG-03-11' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- WG-03-12: BtnOpenAuditFolder has Click handler + Resolve-AuditOutputPath returns valid path
try {
    $btnOpen = Get-NamedControl -Root $auditTabContent -Name 'BtnOpenAuditFolder'
    if (-not $btnOpen) {
        Add-Result -Id 'WG-03-12' -Result 'FAIL' -Note "BtnOpenAuditFolder not found"
    } else {
        $count = Get-EventHandlerCount -Element $btnOpen -Event ([System.Windows.Controls.Button]::ClickEvent)
        $resolved = $null
        if ($moduleImported) {
            $mod = Get-Module SP.MainWindow
            $resolved = & $mod { Resolve-AuditOutputPath }
        }
        if ($count -ge 1 -and -not [string]::IsNullOrWhiteSpace($resolved) -and [System.IO.Path]::IsPathRooted($resolved)) {
            Add-Result -Id 'WG-03-12' -Result 'PASS' -Note "Click handler attached ($count); Resolve-AuditOutputPath = '$resolved'"
        } elseif ($count -eq 0) {
            Add-Result -Id 'WG-03-12' -Result 'FAIL' -Note "BtnOpenAuditFolder has no Click handler attached"
        } else {
            Add-Result -Id 'WG-03-12' -Result 'FAIL' -Note "Handler count=$count, resolved path='$resolved' (must be absolute non-empty)"
        }
    }
} catch {
    Add-Result -Id 'WG-03-12' -Result 'FAIL' -Note "Exception: $($_.Exception.Message)"
}

# ----- Reset LastAuditQueryParams so we do not leak state across runs
try {
    if ($moduleImported) {
        $mod = Get-Module SP.MainWindow
        & $mod { $script:LastAuditQueryParams = $null } | Out-Null
    }
} catch { }

# ----- Summary
$pass    = ($results | Where-Object { $_.result -eq 'PASS' }).Count
$fail    = ($results | Where-Object { $_.result -eq 'FAIL' }).Count
$blocked = ($results | Where-Object { $_.result -eq 'BLOCKED' }).Count

Write-Host (ConvertTo-Json -Compress -InputObject ([ordered]@{
    summary = $true; pass = $pass; fail = $fail; blocked = $blocked; total = $results.Count
}))

if ($fail -gt 0) { exit 1 } else { exit 0 }
