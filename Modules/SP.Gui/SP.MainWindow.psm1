#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - WPF Main Window Host
.DESCRIPTION
    Hosts the WPF dashboard using XAML definitions loaded from the Gui/ directory.
    Manages window lifecycle, tab initialization, event wiring, and cross-thread
    UI updates via the WPF dispatcher pattern.

    Tab responsibilities:
      Campaigns - Load CSV data into DataGrid, run selected/all/smoke tests
      Evidence  - Browse Evidence/ folder tree, view JSONL events and HTML reports
      Settings  - Edit settings.json fields, test connectivity
.NOTES
    Module:  SP.MainWindow
    Version: 1.0.0
    Threading: WPF requires STA. The Show-SPDashboard.ps1 launcher handles
               STA relaunch if PowerShell is running MTA.
#>

Set-StrictMode -Version 1

#region Assembly Loading

Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
Add-Type -AssemblyName WindowsBase            -ErrorAction Stop
Add-Type -AssemblyName System.Xml             -ErrorAction Stop

#endregion

#region Module-scoped State

# Holds loaded data across tab interactions
$script:LoadedCampaigns    = @()
$script:LoadedIdentities   = @{}
$script:ConfigPath         = $null
$script:ToolkitRoot        = $null
$script:MainWindow         = $null
$script:CampaignDataSource      = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:IsRunning               = $false
$script:AuditCampaignDataSource     = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:IsAuditRunning              = $false
$script:DeltaCertResultDataSource   = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:IsDeltaCertRunning          = $false
$script:LastDeltaCertParams         = $null
$script:LastEscalationParams        = $null
$script:LastAuditQueryParams        = $null

# Module reference used to re-enter module scope from WPF event handlers.
# Populated by Show-SPDashboard / headless harness before handlers are wired.
# WPF stores click handlers as delegates and PowerShell 5.1 drops module
# SessionState during delegate conversion, so function-name lookup inside a
# fired handler resolves against the global scope instead of this module.
# Wrap handler bodies in & $script:ThisModule { ... } to re-enter module
# scope so private helpers (Set-StatusMessage, Invoke-GuiTestRun, Load-*,
# Save-*, etc.) resolve at fire-time.
$script:ThisModule = $null

#endregion

#region Internal XAML Helpers

function Get-XamlPath {
    <#
    .SYNOPSIS
        Resolves the absolute path to a XAML file in the Gui/ directory.
    .PARAMETER FileName
        XAML filename (e.g., MainWindow.xaml).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FileName)

    $guiDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Gui'))
    return Join-Path $guiDir $FileName
}

function Load-XamlWindow {
    <#
    .SYNOPSIS
        Loads a XAML file and returns the parsed WPF object.
    .PARAMETER XamlPath
        Absolute path to the .xaml file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XamlPath
    )

    if (-not (Test-Path $XamlPath)) {
        throw "XAML file not found: $XamlPath"
    }

    try {
        $xmlReader = [System.Xml.XmlReader]::Create($XamlPath)
        $result    = [System.Windows.Markup.XamlReader]::Load($xmlReader)
        $xmlReader.Close()
        return $result
    }
    catch {
        throw "Failed to load XAML from '$XamlPath': $($_.Exception.Message)"
    }
}

function Find-Control {
    <#
    .SYNOPSIS
        Finds a named WPF control within a parent element.
    .PARAMETER Parent
        The WPF FrameworkElement parent.
    .PARAMETER Name
        The x:Name of the control to find.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Parent,
        [Parameter(Mandatory)]
        [string]$Name
    )
    return $Parent.FindName($Name)
}

function Invoke-OnDispatcher {
    <#
    .SYNOPSIS
        Marshals an action to the WPF dispatcher (required for cross-thread UI updates).
    .PARAMETER Action
        ScriptBlock to invoke on the UI thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $dispatcher = [System.Windows.Application]::Current.Dispatcher
    if ($null -ne $dispatcher) {
        $dispatcher.Invoke([System.Action]$Action, [System.Windows.Threading.DispatcherPriority]::Normal)
    }
    else {
        & $Action
    }
}

function Show-SPGuiDialog {
    <#
    .SYNOPSIS
        Loads a XAML dialog, shows it as a modal, and returns control values.
    .DESCRIPTION
        Reusable modal dialog helper. Loads XAML from file, sets Owner to the
        main window, wires OK/Cancel buttons, optionally pre-populates controls,
        and returns a hashtable of named control values on OK or $null on Cancel.
    .PARAMETER XamlPath
        Absolute path to the dialog XAML file.
    .PARAMETER ControlNames
        Array of x:Name strings whose values to read on OK.
    .PARAMETER Defaults
        Optional hashtable of control-name -> default-value to pre-populate.
    .PARAMETER OkButtonName
        x:Name of the OK button (default: BtnOK).
    .PARAMETER CancelButtonName
        x:Name of the Cancel button (default: BtnCancel).
    .OUTPUTS
        Hashtable of control values on OK, or $null on Cancel/error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$XamlPath,
        [Parameter(Mandatory)][string[]]$ControlNames,
        [Parameter()][hashtable]$Defaults,
        [Parameter()][string]$OkButtonName = 'BtnOK',
        [Parameter()][string]$CancelButtonName = 'BtnCancel'
    )

    if (-not (Test-Path $XamlPath)) {
        try { Write-SPLog -Message "Dialog XAML not found: $XamlPath" -Severity ERROR -Component 'SP.Gui' -Action 'ShowDialog' } catch { }
        return $null
    }

    try {
        [xml]$xaml = [System.IO.File]::ReadAllText($XamlPath)
        $reader = [System.Xml.XmlNodeReader]::new($xaml)
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Set owner for centering
        if ($null -ne $script:MainWindow) {
            $dialog.Owner = $script:MainWindow
        }

        # Wire OK button
        $btnOK = $dialog.FindName($OkButtonName)
        if ($null -ne $btnOK) {
            $btnOK.Add_Click({ $dialog.DialogResult = $true }.GetNewClosure())
        }

        # Wire Cancel button
        $btnCancel = $dialog.FindName($CancelButtonName)
        if ($null -ne $btnCancel) {
            $btnCancel.Add_Click({ $dialog.Close() }.GetNewClosure())
        }

        # Apply defaults
        if ($null -ne $Defaults) {
            foreach ($key in $Defaults.Keys) {
                $ctrl = $dialog.FindName($key)
                if ($null -eq $ctrl) { continue }
                $value = $Defaults[$key]
                if ($ctrl -is [System.Windows.Controls.TextBox]) {
                    $ctrl.Text = if ($null -ne $value) { [string]$value } else { '' }
                }
                elseif ($ctrl -is [System.Windows.Controls.ComboBox]) {
                    # Match item by Content string
                    foreach ($item in $ctrl.Items) {
                        $itemContent = if ($item -is [System.Windows.Controls.ComboBoxItem]) {
                            $item.Content
                        } else { $item }
                        if ([string]$itemContent -eq [string]$value) {
                            $ctrl.SelectedItem = $item
                            break
                        }
                    }
                }
                elseif ($ctrl -is [System.Windows.Controls.CheckBox]) {
                    $ctrl.IsChecked = [bool]$value
                }
            }
        }

        # Show modal
        $result = $dialog.ShowDialog()

        if ($result -eq $true) {
            $values = @{}
            foreach ($name in $ControlNames) {
                $ctrl = $dialog.FindName($name)
                if ($null -eq $ctrl) {
                    $values[$name] = $null
                }
                elseif ($ctrl -is [System.Windows.Controls.TextBox]) {
                    $values[$name] = $ctrl.Text
                }
                elseif ($ctrl -is [System.Windows.Controls.ComboBox]) {
                    $selected = $ctrl.SelectedItem
                    $values[$name] = if ($selected -is [System.Windows.Controls.ComboBoxItem]) {
                        $selected.Content
                    } else { $selected }
                }
                elseif ($ctrl -is [System.Windows.Controls.CheckBox]) {
                    $values[$name] = $ctrl.IsChecked
                }
                else {
                    $values[$name] = $null
                }
            }
            return $values
        }
        else {
            return $null
        }
    }
    catch {
        try { Write-SPLog -Message "Dialog error ($XamlPath): $($_.Exception.Message)" -Severity ERROR -Component 'SP.Gui' -Action 'ShowDialog' } catch { }
        return $null
    }
}

#endregion

#region Status Bar Helpers

function Set-StatusMessage {
    <#
    .SYNOPSIS
        Updates the main window status bar text.
    .PARAMETER Message
        Text to display.
    .PARAMETER IsError
        If true, displays in error color. Otherwise uses info color.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$IsError
    )

    Invoke-OnDispatcher -Action {
        $statusLabel = Find-Control -Parent $script:MainWindow -Name 'StatusBarText'
        if ($null -ne $statusLabel) {
            $statusLabel.Text       = $Message
            $statusLabel.Foreground = if ($IsError) {
                [System.Windows.Media.Brushes]::Salmon
            } else {
                [System.Windows.Media.Brushes]::LightGray
            }
        }
    }
}

#endregion

#region Campaign Tab

function Initialize-CampaignTab {
    <#
    .SYNOPSIS
        Wires up the Campaign tab DataGrid and button event handlers.
    #>
    [CmdletBinding()]
    param($TabContent)

    # Local capture of module reference. .GetNewClosure() preserves locals
    # across the WPF delegate conversion; $script:* lookups don't survive it.
    $module = $script:ThisModule

    $campaignGrid   = Find-Control -Parent $TabContent -Name 'CampaignGrid'
    $btnRunSelected = Find-Control -Parent $TabContent -Name 'BtnRunSelected'
    $btnRunAll      = Find-Control -Parent $TabContent -Name 'BtnRunAll'
    $btnRunSmoke    = Find-Control -Parent $TabContent -Name 'BtnRunSmoke'
    $btnRefresh     = Find-Control -Parent $TabContent -Name 'BtnRefreshCampaigns'
    $tagFilter      = Find-Control -Parent $TabContent -Name 'TagFilterCombo'
    $progressBar     = Find-Control -Parent $TabContent -Name 'SuiteProgressBar'
    $progressPercent = Find-Control -Parent $TabContent -Name 'SuiteProgressPercent'
    $progressLabel   = Find-Control -Parent $TabContent -Name 'CurrentTestLabel'
    $resultSummary   = Find-Control -Parent $TabContent -Name 'ResultSummaryText'

    # Load initial data
    Load-CampaignData -Grid $campaignGrid -TagFilter $tagFilter -ProgressLabel $progressLabel

    # Refresh button
    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            & $module {
                param($grid, $tf, $pl)
                Load-CampaignData -Grid $grid -TagFilter $tf -ProgressLabel $pl
            } $campaignGrid $tagFilter $progressLabel
        }.GetNewClosure())
    }

    # Run Selected
    if ($btnRunSelected) {
        $btnRunSelected.Add_Click({
            & $module {
                param($pb, $pp, $pl, $rs)
                $selected = @($script:LoadedCampaigns | Where-Object { $_.IsSelected -eq $true })
                if ($selected.Count -eq 0) {
                    Set-StatusMessage -Message 'No campaigns selected. Use the checkbox column to select tests.' -IsError
                    return
                }
                Invoke-GuiTestRun -Campaigns $selected -ProgressBar $pb `
                    -ProgressPercent $pp -ProgressLabel $pl -ResultSummary $rs
            } $progressBar $progressPercent $progressLabel $resultSummary
        }.GetNewClosure())
    }

    # Run All
    if ($btnRunAll) {
        $btnRunAll.Add_Click({
            & $module {
                param($pb, $pp, $pl, $rs)
                $all = @($script:LoadedCampaigns | ForEach-Object { $_._Original })
                if ($all.Count -eq 0) {
                    Set-StatusMessage -Message 'No campaigns loaded.' -IsError
                    return
                }
                Invoke-GuiTestRun -Campaigns $all -ProgressBar $pb `
                    -ProgressPercent $pp -ProgressLabel $pl -ResultSummary $rs
            } $progressBar $progressPercent $progressLabel $resultSummary
        }.GetNewClosure())
    }

    # Run Smoke
    if ($btnRunSmoke) {
        $btnRunSmoke.Add_Click({
            & $module {
                param($pb, $pp, $pl, $rs)
                $smoke = @($script:LoadedCampaigns | Where-Object {
                    $tags = $_._Original.Tags -split ',' | ForEach-Object { $_.Trim().ToLower() }
                    $tags -contains 'smoke'
                } | ForEach-Object { $_._Original })

                if ($smoke.Count -eq 0) {
                    Set-StatusMessage -Message 'No smoke-tagged campaigns found. Add Tags=smoke to test cases.' -IsError
                    return
                }
                Invoke-GuiTestRun -Campaigns $smoke -ProgressBar $pb `
                    -ProgressPercent $pp -ProgressLabel $pl -ResultSummary $rs
            } $progressBar $progressPercent $progressLabel $resultSummary
        }.GetNewClosure())
    }
}

function Load-CampaignData {
    [CmdletBinding()]
    param($Grid, $TagFilter, $ProgressLabel)

    Set-StatusMessage -Message 'Loading campaign data...'

    $result = Get-SPGuiCampaignList -ConfigPath $script:ConfigPath
    if (-not $result.Success) {
        Set-StatusMessage -Message "Failed to load campaigns: $($result.Error)" -IsError
        return
    }

    $script:LoadedCampaigns  = $result.Data
    $script:LoadedIdentities = $result.Identities

    if ($null -ne $Grid) {
        $obsCollection = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
        foreach ($item in $result.Data) {
            $obsCollection.Add($item)
        }
        $Grid.ItemsSource = $obsCollection
    }

    # Populate tag filter dropdown
    if ($null -ne $TagFilter) {
        $allTags = $result.Data | ForEach-Object {
            $_.Tags -split ',' | ForEach-Object { $_.Trim() }
        } | Where-Object { $_ } | Sort-Object -Unique

        $TagFilter.Items.Clear()
        [void]$TagFilter.Items.Add('(All)')
        foreach ($tag in $allTags) {
            [void]$TagFilter.Items.Add($tag)
        }
        $TagFilter.SelectedIndex = 0
    }

    Set-StatusMessage -Message "Loaded $($result.Data.Count) campaign(s) and $($result.Identities.Count) identity(ies)."
}

function Invoke-GuiTestRun {
    [CmdletBinding()]
    param($Campaigns, $ProgressBar, $ProgressPercent, $ProgressLabel, $ResultSummary)

    if ($script:IsRunning) {
        Set-StatusMessage -Message 'A test run is already in progress.' -IsError
        return
    }

    # Safety guard: honor Safety.RequireWhatIfOnProd. The CLI (Invoke-GovernanceTest.ps1)
    # gates live execution behind ShouldProcess; the GUI previously bypassed this entirely
    # by hardcoding -WhatIf:$false in Invoke-SPGuiTest. If the flag is set in config, prompt
    # the user before spawning the live runspace. Defaults to safe (prompt) if config can't
    # be read for any reason.
    $requireConfirm = $true
    $envName        = 'Unknown'
    try {
        $cfg = Get-SPConfig -ConfigPath $script:ConfigPath
        if ($cfg -and $cfg.Safety -and ($cfg.Safety.PSObject.Properties.Name -contains 'RequireWhatIfOnProd')) {
            $requireConfirm = [bool]$cfg.Safety.RequireWhatIfOnProd
        }
        if ($cfg -and $cfg.Global -and ($cfg.Global.PSObject.Properties.Name -contains 'EnvironmentName')) {
            $envName = [string]$cfg.Global.EnvironmentName
        }
    } catch { }

    if ($requireConfirm) {
        $msg = "Safety.RequireWhatIfOnProd is enabled in settings.json.`n`n" +
               "About to run $($Campaigns.Count) live test campaign(s) against environment: $envName`n`n" +
               "Continue with live API execution?"
        $choice = [System.Windows.MessageBox]::Show(
            $msg,
            'Confirm Live Test Run',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-StatusMessage -Message 'Run cancelled by user (Safety.RequireWhatIfOnProd).'
            return
        }
    }

    $script:IsRunning = $true
    $correlationID    = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Starting test run. CorrelationID: $correlationID"

    if ($null -ne $ProgressBar) {
        $ProgressBar.Value   = 0
        $ProgressBar.Maximum = $Campaigns.Count
        $ProgressBar.Visibility = [System.Windows.Visibility]::Visible
    }

    if ($null -ne $ProgressPercent) {
        $ProgressPercent.Text = '0%'
    }

    # Run in a background runspace to avoid freezing the UI
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    # Share necessary state with the runspace
    $runspace.SessionStateProxy.SetVariable('Campaigns',        $Campaigns)
    $runspace.SessionStateProxy.SetVariable('Identities',       $script:LoadedIdentities)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',    $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',      $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',      $ProgressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',  $ProgressPercent)
    $runspace.SessionStateProxy.SetVariable('ProgressLabel',    $ProgressLabel)
    $runspace.SessionStateProxy.SetVariable('ResultSummary',    $ResultSummary)
    $runspace.SessionStateProxy.SetVariable('MainWindow',       $script:MainWindow)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # Load modules in runspace
        $coreModule    = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule     = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $testingModule = Join-Path $ToolkitRoot 'Modules\SP.Testing\SP.Testing.psd1'
        $guiModule     = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $testingModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $suiteResult = Invoke-SPGuiTest `
            -SelectedCampaigns $Campaigns `
            -Identities        $Identities `
            -CorrelationID     $CorrelationID

        # Marshal result back to UI thread
        $dispatcher = $MainWindow.Dispatcher
        $capturedResult   = $suiteResult
        $capturedProgress = $ProgressBar
        $capturedPercent  = $ProgressPercent
        $capturedLabel    = $ProgressLabel
        $capturedSummary  = $ResultSummary

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgress) {
                $capturedProgress.Value      = $capturedResult.PassCount + $capturedResult.FailCount + $capturedResult.SkipCount
                $capturedProgress.Visibility = [System.Windows.Visibility]::Visible
            }
            if ($null -ne $capturedPercent) {
                $capturedPercent.Text = '100%'
            }
            if ($null -ne $capturedLabel) {
                $capturedLabel.Content = 'Complete'
            }
            if ($null -ne $capturedSummary) {
                $p = $capturedResult.PassCount
                $f = $capturedResult.FailCount
                $s = $capturedResult.SkipCount
                $capturedSummary.Text = "PASS: $p  FAIL: $f  SKIP: $s  | $([math]::Round($capturedResult.DurationSeconds,1))s"
                $capturedSummary.Foreground = if ($capturedResult.Success) {
                    [System.Windows.Media.Brushes]::LightGreen
                } else {
                    [System.Windows.Media.Brushes]::Salmon
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $suiteResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null

    $asyncResult = $psInstance.BeginInvoke()

    # Register callback to clean up and update status when done.
    # Also enforces a max-wait ceiling so a deadlocked runspace can't leak forever.
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    # 30 min ceiling for any single GUI-launched suite. The CLI doesn't impose this
    # — it inherits user-controllable command-line behavior — but the GUI has no
    # cancel button, so an upper bound prevents permanent IsRunning lockout if the
    # runspace deadlocks (network hang, infinite retry, etc.).
    $maxWaitSeconds = 1800

    $capturedTimer       = $timer
    $capturedPs          = $psInstance
    $capturedRunspace    = $runspace
    $capturedAsync       = $asyncResult
    $capturedStartTime   = Get-Date
    $capturedMaxWaitSec  = $maxWaitSeconds
    $capturedModule      = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $start, $maxSec)

            $elapsed = ((Get-Date) - $start).TotalSeconds
            $done    = $ps.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')
            $timeout = (-not $done) -and ($elapsed -gt $maxSec)

            if (-not ($done -or $timeout)) { return }

            $t.Stop()
            try {
                if ($timeout) {
                    try { $ps.Stop() } catch { }
                    Set-StatusMessage -Message ("Test run aborted: exceeded {0}s ceiling." -f $maxSec) -IsError
                }
                elseif ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Test run failed: $errMsg" -IsError
                }
                else {
                    Set-StatusMessage -Message 'Test run complete.'
                }

                try {
                    if (-not $timeout) {
                        $ps.EndInvoke($async) | Out-Null
                    }
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedStartTime $capturedMaxWaitSec
    }.GetNewClosure())

    $timer.Start()
}

#endregion

#region Evidence Tab

function Initialize-EvidenceTab {
    <#
    .SYNOPSIS
        Wires up the Evidence tab TreeView and detail panel.
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    $evidenceTree   = Find-Control -Parent $TabContent -Name 'EvidenceTree'
    $btnRefresh     = Find-Control -Parent $TabContent -Name 'BtnRefreshEvidence'
    $btnOpenBrowser = Find-Control -Parent $TabContent -Name 'BtnOpenInBrowser'
    $btnExportAll   = Find-Control -Parent $TabContent -Name 'BtnExportAll'
    $detailGrid     = Find-Control -Parent $TabContent -Name 'EvidenceDetailGrid'

    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            & $module {
                param($tree)
                Load-EvidenceTree -Tree $tree
            } $evidenceTree
        }.GetNewClosure())
    }

    if ($evidenceTree) {
        $evidenceTree.Add_SelectedItemChanged({
            & $module {
                param($tree, $dg)
                $selectedNode = $tree.SelectedItem
                if ($null -ne $selectedNode -and $selectedNode.Tag -and (Test-Path $selectedNode.Tag)) {
                    Load-EvidenceDetail -FilePath $selectedNode.Tag -DetailGrid $dg
                }
            } $evidenceTree $detailGrid
        }.GetNewClosure())
    }

    if ($btnOpenBrowser) {
        $btnOpenBrowser.Add_Click({
            $selectedNode = $evidenceTree.SelectedItem
            if ($null -ne $selectedNode -and $selectedNode.Tag -and (Test-Path $selectedNode.Tag)) {
                Start-Process $selectedNode.Tag
            }
        }.GetNewClosure())
    }

    if ($btnExportAll) {
        $btnExportAll.Add_Click({
            & $module {
                $evidenceRoot = Join-Path $script:ToolkitRoot 'Evidence'
                if (-not (Test-Path $evidenceRoot)) {
                    Set-StatusMessage -Message 'Evidence directory not found.' -IsError
                    return
                }
                Start-Process 'explorer.exe' -ArgumentList "`"$evidenceRoot`""
                Set-StatusMessage -Message "Opened evidence folder: $evidenceRoot"
            }
        }.GetNewClosure())
    }

    Load-EvidenceTree -Tree $evidenceTree
}

function Load-EvidenceTree {
    [CmdletBinding()]
    param($Tree)

    if ($null -eq $Tree) { return }

    $Tree.Items.Clear()

    $evidenceRoot = Join-Path $script:ToolkitRoot 'Evidence'
    if (-not (Test-Path $evidenceRoot)) {
        $rootNode         = [System.Windows.Controls.TreeViewItem]::new()
        $rootNode.Header  = 'Evidence directory not found'
        [void]$Tree.Items.Add($rootNode)
        return
    }

    # Add root node
    $rootNode        = [System.Windows.Controls.TreeViewItem]::new()
    $rootNode.Header = 'Evidence'
    $rootNode.Tag    = $evidenceRoot

    # Add sub-folders (TestId directories)
    $subDirs = Get-ChildItem -Path $evidenceRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($dir in $subDirs) {
        $dirNode        = [System.Windows.Controls.TreeViewItem]::new()
        $dirNode.Header = $dir.Name
        $dirNode.Tag    = $dir.FullName

        # Add files inside the TestId folder
        $files = Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue | Sort-Object Name
        foreach ($file in $files) {
            $fileNode        = [System.Windows.Controls.TreeViewItem]::new()
            $fileNode.Header = $file.Name
            $fileNode.Tag    = $file.FullName
            [void]$dirNode.Items.Add($fileNode)
        }

        [void]$rootNode.Items.Add($dirNode)
    }

    $rootNode.IsExpanded = $true
    [void]$Tree.Items.Add($rootNode)
}

function Load-EvidenceDetail {
    [CmdletBinding()]
    param([string]$FilePath, $DetailGrid)

    if ($null -eq $DetailGrid) { return }

    try {
        $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
        if ($ext -eq '.jsonl') {
            $lines  = [System.IO.File]::ReadAllLines($FilePath)
            $events = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $obj = $line | ConvertFrom-Json
                    $events.Add($obj)
                }
                catch { }
            }
            $DetailGrid.ItemsSource = $events
        }
    }
    catch {
        Set-StatusMessage -Message "Failed to load evidence file: $($_.Exception.Message)" -IsError
    }
}

#endregion

#region Settings Tab

function Initialize-SettingsTab {
    <#
    .SYNOPSIS
        Wires up the Settings tab form and buttons.
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    $btnSave         = Find-Control -Parent $TabContent -Name 'BtnSaveSettings'
    $btnReset        = Find-Control -Parent $TabContent -Name 'BtnResetDefaults'
    $btnTestConn     = Find-Control -Parent $TabContent -Name 'BtnTestConnectivity'
    $connStatus      = Find-Control -Parent $TabContent -Name 'ConnectivityStatusText'
    $pbBrowserToken  = Find-Control -Parent $TabContent -Name 'PbBrowserToken'
    $btnApplyToken   = Find-Control -Parent $TabContent -Name 'BtnApplyToken'
    $btnClearToken   = Find-Control -Parent $TabContent -Name 'BtnClearToken'
    $tokenStatus     = Find-Control -Parent $TabContent -Name 'BrowserTokenStatus'
    $btnBrowseIds    = Find-Control -Parent $TabContent -Name 'BtnBrowseIdentities'
    $btnBrowseCamps  = Find-Control -Parent $TabContent -Name 'BtnBrowseCampaigns'
    $btnBrowseEvid   = Find-Control -Parent $TabContent -Name 'BtnBrowseEvidence'
    $btnBrowseReps   = Find-Control -Parent $TabContent -Name 'BtnBrowseReports'

    # Load current settings into form
    Load-SettingsForm -TabContent $TabContent

    # Save settings
    if ($btnSave) {
        $btnSave.Add_Click({
            & $module {
                param($tc)
                Save-SettingsForm -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Reset to defaults
    if ($btnReset) {
        $btnReset.Add_Click({
            $result = [System.Windows.MessageBox]::Show(
                'Reset all settings to defaults? This will overwrite your current settings.json.',
                'Confirm Reset',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                & $module {
                    param($tc)
                    Load-SettingsForm -TabContent $tc
                } $TabContent
            }
        }.GetNewClosure())
    }

    # Test connectivity
    if ($btnTestConn) {
        $btnTestConn.Add_Click({
            & $module {
                try {
                    $connStatusCtl = Find-Control -Parent $script:MainWindow -Name 'ConnectivityStatusText'
                    if ($null -ne $connStatusCtl) {
                        $connStatusCtl.Text = 'Testing connectivity...'
                        $connStatusCtl.Foreground = [System.Windows.Media.Brushes]::LightGray
                    }
                    Set-StatusMessage -Message 'Running connectivity test...'

                    $statusResult = Test-SPGuiConnectivity -ConfigPath $script:ConfigPath

                    if ($null -ne $connStatusCtl) {
                        $connStatusCtl.Text = $statusResult.OverallMessage
                        $connStatusCtl.Foreground = if ($statusResult.Success) {
                            [System.Windows.Media.Brushes]::LightGreen
                        } else {
                            [System.Windows.Media.Brushes]::Salmon
                        }
                    }
                    Set-StatusMessage -Message $statusResult.OverallMessage -IsError:(-not $statusResult.Success)
                }
                catch {
                    $errMsg = "Test Connectivity handler failed: $($_.Exception.Message)"
                    try { Write-SPLog -Message $errMsg -Severity ERROR -Component 'SP.Gui' -Action 'TestConnectivity' } catch { }
                    try { Set-StatusMessage -Message $errMsg -IsError } catch { }
                }
            }
        }.GetNewClosure())
    }

    # Apply browser token
    if ($btnApplyToken) {
        $btnApplyToken.Add_Click({
            & $module {
                param($pb, $ts)
                $tokenValue = ''
                if ($null -ne $pb) {
                    $tokenValue = $pb.Password
                }

                $result = Set-SPGuiBrowserToken -Token $tokenValue

                if ($null -ne $ts) {
                    $ts.Text = $result.Message
                    $ts.Foreground = if ($result.Success) {
                        [System.Windows.Media.Brushes]::LightGreen
                    } else {
                        [System.Windows.Media.Brushes]::Salmon
                    }
                }

                Set-StatusMessage -Message $result.Message -IsError:(-not $result.Success)
            } $pbBrowserToken $tokenStatus
        }.GetNewClosure())
    }

    # Clear browser token
    if ($btnClearToken) {
        $btnClearToken.Add_Click({
            & $module {
                param($pb, $ts)
                Clear-SPAuthToken

                if ($null -ne $pb) {
                    $pb.Clear()
                }

                if ($null -ne $ts) {
                    $ts.Text = 'Browser token cleared. Toolkit will use configured OAuth credentials.'
                    $ts.Foreground = [System.Windows.Media.Brushes]::LightGray
                }

                Set-StatusMessage -Message 'Browser token cleared.'
            } $pbBrowserToken $tokenStatus
        }.GetNewClosure())
    }

    # Browse buttons: wire file picker for CSVs, folder picker for directories
    if ($btnBrowseIds) {
        $btnBrowseIds.Add_Click({
            & $module {
                Invoke-GuiFilePicker -TargetName 'TxtIdentitiesCsvPath' -Title 'Select test-identities.csv' -Filter 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            }
        }.GetNewClosure())
    }
    if ($btnBrowseCamps) {
        $btnBrowseCamps.Add_Click({
            & $module {
                Invoke-GuiFilePicker -TargetName 'TxtCampaignsCsvPath' -Title 'Select test-campaigns.csv' -Filter 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            }
        }.GetNewClosure())
    }
    if ($btnBrowseEvid) {
        $btnBrowseEvid.Add_Click({
            & $module {
                Invoke-GuiFolderPicker -TargetName 'TxtEvidencePath' -Description 'Select Evidence output folder'
            }
        }.GetNewClosure())
    }
    if ($btnBrowseReps) {
        $btnBrowseReps.Add_Click({
            & $module {
                Invoke-GuiFolderPicker -TargetName 'TxtReportsPath' -Description 'Select Reports output folder'
            }
        }.GetNewClosure())
    }
}

function Invoke-GuiFilePicker {
    <#
    .SYNOPSIS
        Opens an OpenFileDialog and writes the chosen path into a named TextBox
        on the main window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter()]        [string]$Title   = 'Select file',
        [Parameter()]        [string]$Filter  = 'All files (*.*)|*.*'
    )
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title       = $Title
    $dlg.Filter      = $Filter
    $dlg.Multiselect = $false
    $existing = Find-Control -Parent $script:MainWindow -Name $TargetName
    if ($null -ne $existing -and $existing.Text) {
        $seed = $existing.Text
        try {
            $seedDir = if (Test-Path $seed -PathType Container) { $seed } else { Split-Path -Parent $seed }
            if ($seedDir -and (Test-Path $seedDir)) { $dlg.InitialDirectory = $seedDir }
        } catch { }
    }
    if ($dlg.ShowDialog() -eq $true) {
        if ($null -ne $existing) { $existing.Text = $dlg.FileName }
    }
}

function Invoke-GuiFolderPicker {
    <#
    .SYNOPSIS
        Opens a FolderBrowserDialog (from System.Windows.Forms) and writes the
        chosen directory into a named TextBox on the main window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter()]        [string]$Description = 'Select folder'
    )
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    $existing = Find-Control -Parent $script:MainWindow -Name $TargetName
    if ($null -ne $existing -and $existing.Text) {
        try {
            $seed = $existing.Text
            if (Test-Path $seed) { $dlg.SelectedPath = $seed }
        } catch { }
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if ($null -ne $existing) { $existing.Text = $dlg.SelectedPath }
    }
}

function Load-SettingsForm {
    [CmdletBinding()]
    param($TabContent)

    $config = $null
    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams -Force
    }
    catch {
        Set-StatusMessage -Message "Could not load settings for form: $($_.Exception.Message)" -IsError
        return
    }

    if (Test-SPConfigFirstRun -Config $config) { return }

    # Helper to set control text
    $setField = {
        param($Name, $Value)
        $ctrl = Find-Control -Parent $TabContent -Name $Name
        if ($null -ne $ctrl) {
            if ($ctrl -is [System.Windows.Controls.TextBox]) { $ctrl.Text = $Value }
            elseif ($ctrl -is [System.Windows.Controls.CheckBox]) { $ctrl.IsChecked = [bool]$Value }
            elseif ($ctrl -is [System.Windows.Controls.ComboBox]) { $ctrl.Text = $Value }
        }
    }

    & $setField 'TxtEnvironmentName'     $config.Global.EnvironmentName
    & $setField 'ChkDebugMode'           $config.Global.DebugMode
    & $setField 'CboAuthMode'            $config.Authentication.Mode
    & $setField 'TxtTenantUrl'           $config.Authentication.ConfigFile.TenantUrl
    & $setField 'TxtClientId'            $config.Authentication.ConfigFile.ClientId
    & $setField 'TxtApiBaseUrl'          $config.Api.BaseUrl
    & $setField 'TxtApiTimeout'          $config.Api.TimeoutSeconds
    & $setField 'TxtRetryCount'          $config.Api.RetryCount
    & $setField 'TxtIdentitiesCsvPath'   $config.Testing.IdentitiesCsvPath
    & $setField 'TxtCampaignsCsvPath'    $config.Testing.CampaignsCsvPath
    & $setField 'TxtEvidencePath'        $config.Testing.EvidencePath
    & $setField 'TxtReportsPath'         $config.Testing.ReportsPath
    & $setField 'TxtMaxCampaignsPerRun'  $config.Safety.MaxCampaignsPerRun
    & $setField 'ChkRequireWhatIf'       $config.Safety.RequireWhatIfOnProd
    & $setField 'ChkAllowComplete'       $config.Safety.AllowCompleteCampaign

    # DeltaCert settings
    if ($config.PSObject.Properties.Name -contains 'DeltaCert') {
        $dc = $config.DeltaCert
        $sourceIdText = ''
        if ($dc.PSObject.Properties.Name -contains 'SourceIds' -and $dc.SourceIds) {
            $sourceIdText = ($dc.SourceIds -join ', ')
        }
        & $setField 'TxtDcSourceIds'       $sourceIdText
        & $setField 'TxtDcHoursBack'       $dc.DefaultHoursBack
        & $setField 'TxtDcDeadlineDays'    $dc.DefaultDeadlineDays
        & $setField 'CboDcReviewerMode'    $dc.DefaultReviewerMode
        & $setField 'TxtDcCampaignPrefix'  $dc.CampaignNamePrefix
        & $setField 'TxtDcOutputPath'      $dc.OutputPath
    }
}

function Save-SettingsForm {
    [CmdletBinding()]
    param($TabContent)

    Set-StatusMessage -Message 'Saving settings...'

    $configPath = $script:ConfigPath
    if (-not $configPath) {
        $configPath = Resolve-SPConfigPath -ToolkitRoot $script:ToolkitRoot
    }

    $getField = {
        param($Name, $Default = '')
        $ctrl = Find-Control -Parent $TabContent -Name $Name
        if ($null -eq $ctrl) { return $Default }
        if ($ctrl -is [System.Windows.Controls.TextBox]) { return $ctrl.Text }
        if ($ctrl -is [System.Windows.Controls.CheckBox]) { return ($ctrl.IsChecked -eq $true) }
        if ($ctrl -is [System.Windows.Controls.ComboBox]) { return $ctrl.Text }
        return $Default
    }

    # Read current config to preserve fields we don't edit in the GUI (e.g. ClientSecret
    # when the password box was left blank — overwriting it unconditionally would
    # destroy a real credential already on disk).
    $existingConfig = $null
    try { $existingConfig = Get-SPConfig -ConfigPath $configPath -Force } catch { }

    # Resolve ClientSecret: prefer the password box if user typed something; otherwise
    # keep whatever is already in settings.json. Never write an empty string, and
    # never write a sentinel that would silently erase a real secret.
    $clientSecretToWrite = $null
    $pbSecret = Find-Control -Parent $TabContent -Name 'PbClientSecret'
    if ($null -ne $pbSecret -and $pbSecret.Password) {
        $clientSecretToWrite = $pbSecret.Password
    }
    elseif ($null -ne $existingConfig -and
            $existingConfig.PSObject.Properties.Name -contains 'Authentication' -and
            $existingConfig.Authentication.PSObject.Properties.Name -contains 'ConfigFile' -and
            $existingConfig.Authentication.ConfigFile.PSObject.Properties.Name -contains 'ClientSecret') {
        $clientSecretToWrite = $existingConfig.Authentication.ConfigFile.ClientSecret
    }
    else {
        $clientSecretToWrite = 'CHANGE_ME_DO_NOT_USE_IN_PRODUCTION'
    }

    $timeoutVal  = 60; [int]::TryParse((& $getField 'TxtApiTimeout'), [ref]$timeoutVal) | Out-Null
    $retryVal    = 3;  [int]::TryParse((& $getField 'TxtRetryCount'), [ref]$retryVal) | Out-Null
    $maxRunVal   = 10; [int]::TryParse((& $getField 'TxtMaxCampaignsPerRun'), [ref]$maxRunVal) | Out-Null

    $newConfig = [ordered]@{
        Global = [ordered]@{
            EnvironmentName = & $getField 'TxtEnvironmentName'
            DebugMode       = & $getField 'ChkDebugMode' $false
            ToolkitVersion  = '1.0.0'
        }
        Authentication = [ordered]@{
            Mode       = & $getField 'CboAuthMode' 'ConfigFile'
            ConfigFile = [ordered]@{
                TenantUrl     = & $getField 'TxtTenantUrl'
                OAuthTokenUrl = (& $getField 'TxtTenantUrl').TrimEnd('/') + '/oauth/token'
                ClientId      = & $getField 'TxtClientId'
                ClientSecret  = $clientSecretToWrite
            }
            Vault = [ordered]@{
                VaultPath        = '.\Data\sp-vault.enc'
                Pbkdf2Iterations = 600000
                CredentialKey    = 'sailpoint-isc'
            }
        }
        Logging = [ordered]@{
            Path            = '.\Logs'
            FilePrefix      = 'GovernanceToolkit'
            MinimumSeverity = 'INFO'
            RetentionDays   = 30
        }
        Api = [ordered]@{
            BaseUrl                    = & $getField 'TxtApiBaseUrl'
            TimeoutSeconds             = $timeoutVal
            RetryCount                 = $retryVal
            RetryDelaySeconds          = 5
            RateLimitRequestsPerWindow = 95
            RateLimitWindowSeconds     = 10
        }
        Testing = [ordered]@{
            IdentitiesCsvPath                = & $getField 'TxtIdentitiesCsvPath'
            CampaignsCsvPath                 = & $getField 'TxtCampaignsCsvPath'
            EvidencePath                     = & $getField 'TxtEvidencePath'
            ReportsPath                      = & $getField 'TxtReportsPath'
            DecisionBatchSize                = 250
            ReassignSyncMax                  = 50
            ReassignAsyncMax                 = 500
            CampaignActivationTimeoutSeconds = 300
            CampaignCompleteTimeoutSeconds   = 600
            DefaultDecision                  = 'APPROVE'
            WhatIfByDefault                  = $false
        }
        Safety = [ordered]@{
            MaxCampaignsPerRun    = $maxRunVal
            RequireWhatIfOnProd   = (& $getField 'ChkRequireWhatIf' $true)
            AllowCompleteCampaign = (& $getField 'ChkAllowComplete' $false)
        }
    }

    # Preserve Audit section from existing config
    if ($null -ne $existingConfig -and
        $existingConfig.PSObject.Properties.Name -contains 'Audit') {
        $newConfig['Audit'] = $existingConfig.Audit
    }

    # DeltaCert: overlay GUI fields onto existing config to preserve non-GUI keys
    $dcHoursBack    = 24;  [int]::TryParse((& $getField 'TxtDcHoursBack'),    [ref]$dcHoursBack)    | Out-Null
    $dcDeadlineDays = 2;   [int]::TryParse((& $getField 'TxtDcDeadlineDays'), [ref]$dcDeadlineDays) | Out-Null

    $sourceIdRaw = & $getField 'TxtDcSourceIds' ''
    $sourceIdArray = @()
    if ($sourceIdRaw -and $sourceIdRaw.Trim()) {
        $sourceIdArray = @($sourceIdRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($null -ne $existingConfig -and
        $existingConfig.PSObject.Properties.Name -contains 'DeltaCert') {
        # Start from existing, overlay GUI fields
        $dcExisting = $existingConfig.DeltaCert
        $dcConfig = [ordered]@{}
        foreach ($prop in $dcExisting.PSObject.Properties) {
            $dcConfig[$prop.Name] = $prop.Value
        }
        $dcConfig['SourceIds']            = $sourceIdArray
        $dcConfig['DefaultHoursBack']     = $dcHoursBack
        $dcConfig['DefaultDeadlineDays']  = $dcDeadlineDays
        $dcConfig['DefaultReviewerMode']  = & $getField 'CboDcReviewerMode' 'Manager'
        $dcConfig['CampaignNamePrefix']   = & $getField 'TxtDcCampaignPrefix' 'AD Delta Cert'
        $dcConfig['OutputPath']           = & $getField 'TxtDcOutputPath' '.\DeltaCert'
    }
    else {
        # No existing DeltaCert section -- create fresh with defaults for non-GUI fields
        $dcConfig = [ordered]@{
            SourceIds                  = $sourceIdArray
            DefaultHoursBack           = $dcHoursBack
            DefaultDeadlineDays        = $dcDeadlineDays
            FallbackReviewerIdentityId = ''
            CampaignNamePrefix         = & $getField 'TxtDcCampaignPrefix' 'AD Delta Cert'
            MaxCampaignsPerRun         = 50
            CleanupDaysStale           = 3
            OutputPath                 = & $getField 'TxtDcOutputPath' '.\DeltaCert'
            DefaultReviewerMode        = & $getField 'CboDcReviewerMode' 'Manager'
            ExcludeLifecycleStates     = @('terminated', 'inactive', 'leaver', 'prehire')
            ExcludeDisplayNamePatterns = @()
            ExcludeIdentityIds         = @()
            Escalation                 = [ordered]@{
                DefaultStaleHours     = 24
                MaxEscalationLevels   = 2
                CampaignNamePrefix    = 'AD Delta Cert'
            }
        }
    }
    $newConfig['DeltaCert'] = $dcConfig

    try {
        $json = $newConfig | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($configPath, $json, [System.Text.Encoding]::UTF8)
        # Invalidate config cache
        Get-SPConfig -ConfigPath $configPath -Force | Out-Null
        Set-StatusMessage -Message 'Settings saved successfully.'
        [System.Windows.MessageBox]::Show(
            "Settings saved to:`n$configPath",
            'Saved',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        Set-StatusMessage -Message "Failed to save settings: $($_.Exception.Message)" -IsError
        [System.Windows.MessageBox]::Show(
            "Failed to save settings:`n$($_.Exception.Message)",
            'Save Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
}

#endregion

#region Audit Tab

function Initialize-AuditTab {
    <#
    .SYNOPSIS
        Wires up the Audit tab controls and event handlers.
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    $btnConfigure         = Find-Control -Parent $TabContent -Name 'BtnConfigureAudit'
    $btnQuery             = Find-Control -Parent $TabContent -Name 'BtnQueryCampaigns'
    $btnRunAudit          = Find-Control -Parent $TabContent -Name 'BtnRunAudit'
    $btnOpenFolder        = Find-Control -Parent $TabContent -Name 'BtnOpenAuditFolder'
    $btnRefreshReports    = Find-Control -Parent $TabContent -Name 'BtnRefreshAuditReports'
    $auditReportList      = Find-Control -Parent $TabContent -Name 'AuditReportList'

    # Configure button -- opens dialog, stores params, updates summary (does NOT query)
    if ($btnConfigure) {
        $btnConfigure.Add_Click({
            & $module {
                param($tc)

                $dialogXaml = Get-XamlPath -FileName 'AuditQueryDialog.xaml'
                $defaults   = Get-AuditQueryDialogDefaults
                $dialogResult = Show-SPGuiDialog `
                    -XamlPath      $dialogXaml `
                    -ControlNames  @('TxtCampaignName', 'CboStatus', 'CboTimespan') `
                    -Defaults      $defaults

                if ($null -ne $dialogResult) {
                    $script:LastAuditQueryParams = $dialogResult
                    Update-AuditSummaryLabel -TabContent $tc
                }
            } $TabContent
        }.GetNewClosure())
    }

    # Query Campaigns button -- opens dialog then queries on OK
    if ($btnQuery) {
        $btnQuery.Add_Click({
            & $module {
                param($tc)
                Invoke-AuditCampaignQuery -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Run Audit button
    if ($btnRunAudit) {
        $btnRunAudit.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiAuditRun -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Open Reports Folder button
    if ($btnOpenFolder) {
        $btnOpenFolder.Add_Click({
            $outputPath = & $module { Resolve-AuditOutputPath }
            if (-not (Test-Path $outputPath)) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$outputPath`""
        }.GetNewClosure())
    }

    # Refresh audit reports button
    if ($btnRefreshReports) {
        $btnRefreshReports.Add_Click({
            & $module {
                param($tc)
                Load-AuditReportList -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Double-click on report list item opens file
    if ($auditReportList) {
        $auditReportList.Add_MouseDoubleClick({
            $selected = $auditReportList.SelectedItem
            if ($null -ne $selected -and $null -ne $selected.Tag -and (Test-Path $selected.Tag)) {
                Start-Process $selected.Tag
            }
        }.GetNewClosure())
    }

    # Populate summary label and recent reports on init
    Update-AuditSummaryLabel -TabContent $TabContent
    Load-AuditReportList -TabContent $TabContent
}

function Invoke-AuditCampaignQuery {
    <#
    .SYNOPSIS
        Shows query parameters dialog, then queries ISC for campaigns matching
        the filter values and populates the AuditCampaignGrid.
    #>
    [CmdletBinding()]
    param($TabContent)

    # Show parameters dialog
    $dialogXaml = Get-XamlPath -FileName 'AuditQueryDialog.xaml'
    $defaults   = Get-AuditQueryDialogDefaults
    $dialogResult = Show-SPGuiDialog `
        -XamlPath      $dialogXaml `
        -ControlNames  @('TxtCampaignName', 'CboStatus', 'CboTimespan') `
        -Defaults      $defaults

    if ($null -eq $dialogResult) { return }

    # Persist for next open and update summary label
    $script:LastAuditQueryParams = $dialogResult
    Update-AuditSummaryLabel -TabContent $TabContent

    $grid        = Find-Control -Parent $TabContent -Name 'AuditCampaignGrid'
    $statusLabel = Find-Control -Parent $TabContent -Name 'AuditStatusLabel'
    $btnRunAudit = Find-Control -Parent $TabContent -Name 'BtnRunAudit'

    Set-StatusMessage -Message 'Querying campaigns...'

    # Extract filter values from dialog result
    $campaignName = ''
    if ($dialogResult['TxtCampaignName']) {
        $campaignName = $dialogResult['TxtCampaignName'].Trim()
    }

    $statusFilter = $null
    if ($dialogResult['CboStatus'] -and $dialogResult['CboStatus'] -ne '(All)') {
        $statusFilter = $dialogResult['CboStatus']
    }

    $daysBack = 30
    if ($dialogResult['CboTimespan']) {
        $timespanText = $dialogResult['CboTimespan']
        $parsed = 30
        if ($timespanText -match '(\d+)') {
            [int]::TryParse($Matches[1], [ref]$parsed) | Out-Null
        }
        $daysBack = $parsed
    }

    # Build parameters
    $queryParams = @{ DaysBack = $daysBack }
    if ($campaignName)  { $queryParams['CampaignNameContains'] = $campaignName }
    if ($statusFilter)  { $queryParams['Status']       = $statusFilter }

    $result = Get-SPGuiAuditCampaigns @queryParams

    if (-not $result.Success) {
        Set-StatusMessage -Message "Query failed: $($result.Error)" -IsError
        if ($null -ne $statusLabel) {
            $statusLabel.Text = "Query failed: $($result.Error)"
        }
        return
    }

    # Populate ObservableCollection in-place (PS 5.1: use .Clear() + .Add())
    $script:AuditCampaignDataSource.Clear()
    foreach ($item in $result.Data) {
        $script:AuditCampaignDataSource.Add($item)
    }

    # Bind DataGrid
    if ($null -ne $grid) {
        $grid.ItemsSource = $script:AuditCampaignDataSource
    }

    # Enable Run Audit if we got results
    if ($null -ne $btnRunAudit) {
        $btnRunAudit.IsEnabled = ($result.Data.Count -gt 0)
    }

    # Update status label
    $count = $result.Data.Count
    if ($null -ne $statusLabel) {
        $statusLabel.Text = "$count campaign(s) found"
    }

    Set-StatusMessage -Message "Query complete. $count campaign(s) found."
}

function Get-AuditQueryDialogDefaults {
    <#
    .SYNOPSIS
        Returns audit query dialog defaults: last-used params if available, otherwise sensible defaults.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -ne $script:LastAuditQueryParams) {
        return $script:LastAuditQueryParams
    }

    return @{
        TxtCampaignName = ''
        CboStatus       = '(All)'
        CboTimespan     = '30 days'
    }
}

function Update-AuditSummaryLabel {
    <#
    .SYNOPSIS
        Updates the Audit summary label to reflect current query parameters.
    .DESCRIPTION
        Shows "Status: (All) | Timespan: 30 days" when no campaign name filter,
        or "Campaign: test | Status: COMPLETED | Timespan: 14 days" when set.
    #>
    [CmdletBinding()]
    param($TabContent)

    $label = Find-Control -Parent $TabContent -Name 'AuditSummaryLabel'
    if ($null -eq $label) { return }

    $params = $script:LastAuditQueryParams
    if ($null -eq $params) {
        $params = Get-AuditQueryDialogDefaults
    }

    $status   = if ($params['CboStatus'])   { $params['CboStatus'] }   else { '(All)' }
    $timespan = if ($params['CboTimespan']) { $params['CboTimespan'] } else { '30 days' }

    $campaignName = ''
    if ($params['TxtCampaignName']) {
        $campaignName = $params['TxtCampaignName'].Trim()
    }

    if ([string]::IsNullOrWhiteSpace($campaignName)) {
        $label.Text = "Status: $status | Timespan: $timespan"
    }
    else {
        $label.Text = "Campaign: $campaignName | Status: $status | Timespan: $timespan"
    }
}

function Invoke-GuiAuditRun {
    <#
    .SYNOPSIS
        Runs the audit against selected campaigns in a background runspace.
        Follows the same pattern as Invoke-GuiTestRun.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsAuditRunning) {
        Set-StatusMessage -Message 'An audit run is already in progress.' -IsError
        return
    }

    $progressBar     = Find-Control -Parent $TabContent -Name 'AuditProgressBar'
    $progressPercent = Find-Control -Parent $TabContent -Name 'AuditProgressPercent'
    $statusLabel     = Find-Control -Parent $TabContent -Name 'AuditStatusLabel'
    $btnRunAudit     = Find-Control -Parent $TabContent -Name 'BtnRunAudit'
    $chkCampReports  = Find-Control -Parent $TabContent -Name 'ChkCampaignReports'
    $chkIdentEvents  = Find-Control -Parent $TabContent -Name 'ChkIdentityEvents'
    $chkLeadership   = Find-Control -Parent $TabContent -Name 'ChkLeadershipRollup'
    $cboStartLevel   = Find-Control -Parent $TabContent -Name 'CboLeadershipStartLevel'
    $cboDetailLevel  = Find-Control -Parent $TabContent -Name 'CboDetailLevel'

    $selectedCampaigns = @($script:AuditCampaignDataSource | Where-Object { $_.IsSelected -eq $true })

    if ($selectedCampaigns.Count -eq 0) {
        Set-StatusMessage -Message 'No campaigns selected. Use the checkbox column to select campaigns to audit.' -IsError
        return
    }

    $script:IsAuditRunning = $true
    $correlationID         = [guid]::NewGuid().ToString()
    $outputPath            = Resolve-AuditOutputPath
    $includeCampaignReports = ($null -eq $chkCampReports -or $chkCampReports.IsChecked -ne $false)
    $includeIdentEvents    = ($null -eq $chkIdentEvents -or $chkIdentEvents.IsChecked -ne $false)
    $includeLeadership     = ($null -ne $chkLeadership -and $chkLeadership.IsChecked -eq $true)
    $leadershipStartLevel  = -1
    if ($null -ne $cboStartLevel -and $null -ne $cboStartLevel.SelectedItem) {
        $startLevelText = $cboStartLevel.SelectedItem.Content
        if ($startLevelText -ne 'Auto' -and $startLevelText -match '^\d+$') {
            $leadershipStartLevel = [int]$startLevelText
        }
    }

    $detailLevel = 'Verbose'
    if ($null -ne $cboDetailLevel -and $null -ne $cboDetailLevel.SelectedItem) {
        $detailLevelText = $cboDetailLevel.SelectedItem.Content
        if ($detailLevelText -in @('Summary', 'Detailed', 'Verbose')) {
            $detailLevel = $detailLevelText
        }
    }

    Set-StatusMessage -Message "Starting audit run. CorrelationID: $correlationID"

    if ($null -ne $statusLabel) {
        $statusLabel.Text = "Auditing $($selectedCampaigns.Count) campaign(s)..."
    }

    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }

    if ($null -ne $progressPercent) {
        $progressPercent.Text = '0%'
    }

    if ($null -ne $btnRunAudit) {
        $btnRunAudit.IsEnabled = $false
    }

    # Create background runspace (STA)
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    # Share variables explicitly (PS 5.1: no closures across runspace boundaries)
    $runspace.SessionStateProxy.SetVariable('SelectedCampaigns',    $selectedCampaigns)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('IncludeCampaignReports', $includeCampaignReports)
    $runspace.SessionStateProxy.SetVariable('IncludeIdentEvents',   $includeIdentEvents)
    $runspace.SessionStateProxy.SetVariable('IncludeLeadership',    $includeLeadership)
    $runspace.SessionStateProxy.SetVariable('LeadershipStartLevel', $leadershipStartLevel)
    $runspace.SessionStateProxy.SetVariable('DetailLevel',          $detailLevel)
    $runspace.SessionStateProxy.SetVariable('OutputPath',           $outputPath)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',          $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',      $progressPercent)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)
    $runspace.SessionStateProxy.SetVariable('TabContent',           $TabContent)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # Load modules in runspace
        $coreModule  = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule   = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $auditModule = Join-Path $ToolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'
        $guiModule   = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        $modulesToLoad = @($coreModule, $apiModule, $auditModule, $guiModule)

        # Load SP.DeltaCert when leadership rollup is requested (provides Build-SPOrgTree)
        if ($IncludeLeadership) {
            $deltaCertModule = Join-Path $ToolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
            $modulesToLoad = @($coreModule, $apiModule, $auditModule, $deltaCertModule, $guiModule)
        }

        foreach ($mod in $modulesToLoad) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $auditResult = Invoke-SPGuiAudit `
            -SelectedCampaigns      $SelectedCampaigns `
            -CorrelationID          $CorrelationID `
            -OutputPath             $OutputPath `
            -IncludeCampaignReports:$IncludeCampaignReports `
            -IncludeIdentityEvents:$IncludeIdentEvents `
            -IncludeLeadershipRollup:$IncludeLeadership `
            -LeadershipStartLevel   $LeadershipStartLevel `
            -DetailLevel            $DetailLevel

        # Marshal result back to UI thread
        $dispatcher       = $MainWindow.Dispatcher
        $capturedResult   = $auditResult
        $capturedProgress = $ProgressBar
        $capturedPercent  = $ProgressPercent
        $capturedLabel    = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgress) {
                $capturedProgress.Value = 100
            }
            if ($null -ne $capturedPercent) {
                $capturedPercent.Text = '100%'
            }
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $capturedLabel.Text = "Audit complete. $($capturedResult.CampaignsAudited) campaign(s), $($capturedResult.FilesWritten) file(s) written."
                } else {
                    $capturedLabel.Text = "Audit failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $auditResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null

    $asyncResult = $psInstance.BeginInvoke()

    # DispatcherTimer polls for completion (500ms interval)
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnRunAudit
    $capturedProg     = $progressBar
    $capturedPercent2 = $progressPercent
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Audit run failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Audit run complete.'
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) { $prog.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($null -ne $pct)  { $pct.Text = '' }

                Load-AuditReportList -TabContent $tab

                try {
                    $ps.EndInvoke($async) | Out-Null
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsAuditRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPercent2
    }.GetNewClosure())

    $timer.Start()
}

function Load-AuditReportList {
    <#
    .SYNOPSIS
        Populates the AuditReportList ListBox with color-coded audit report files.
        Green = HTML reports (full analysis), Gray = other file types.
    #>
    [CmdletBinding()]
    param($TabContent)

    $listBox = Find-Control -Parent $TabContent -Name 'AuditReportList'
    if ($null -eq $listBox) { return }

    $outputPath = Resolve-AuditOutputPath

    $result = Get-SPGuiAuditReports -AuditOutputPath $outputPath

    $listBox.Items.Clear()

    if (-not $result.Success) {
        $item        = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = "No reports found (path: $outputPath)"
        $item.Foreground = [System.Windows.Media.Brushes]::Gray
        $listBox.Items.Add($item) | Out-Null
        return
    }

    $converter  = [System.Windows.Media.BrushConverter]::new()
    $brushGreen = $converter.ConvertFromString('#339933')
    $brushGray  = $converter.ConvertFromString('#888899')

    foreach ($report in $result.Data) {
        $item         = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = $report.FileName
        $item.Tag     = $report.FullPath
        $item.ToolTip = "$($report.FullPath) ($($report.SizeKB) KB, $($report.LastModified))"

        if ($report.FileName -match '\.html$') {
            $item.Foreground = $brushGreen
        }
        else {
            $item.Foreground = $brushGray
        }

        $listBox.Items.Add($item) | Out-Null
    }
}

function Resolve-AuditOutputPath {
    <#
    .SYNOPSIS
        Resolves the absolute path to the Audit output directory.
        Reads from config if available, falls back to '.\Audit' relative to toolkit root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configAuditPath = $null
    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'Audit' -and
            $null -ne $config.Audit -and
            $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
            $configAuditPath = $config.Audit.OutputPath
        }
    }
    catch { }

    $rawPath = if ($configAuditPath) { $configAuditPath } else { '.\Audit' }

    # If relative, resolve against toolkit root
    if (-not [System.IO.Path]::IsPathRooted($rawPath)) {
        $rawPath = Join-Path $script:ToolkitRoot $rawPath
    }

    return [System.IO.Path]::GetFullPath($rawPath)
}

#endregion

#region Delta Cert Tab

function Initialize-DeltaCertTab {
    <#
    .SYNOPSIS
        Wires up the Delta Cert tab controls and event handlers.
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    $btnConfigure    = Find-Control -Parent $TabContent -Name 'BtnConfigureDeltaCert'
    $btnRun          = Find-Control -Parent $TabContent -Name 'BtnRunDeltaCert'
    $btnCleanup      = Find-Control -Parent $TabContent -Name 'BtnCleanupDeltaCert'
    $btnEscalate     = Find-Control -Parent $TabContent -Name 'BtnEscalateDeltaCert'
    $btnDeltaReport  = Find-Control -Parent $TabContent -Name 'BtnGenerateDeltaReport'
    $btnOpenFolder   = Find-Control -Parent $TabContent -Name 'BtnOpenDeltaCertFolder'
    $btnRefresh      = Find-Control -Parent $TabContent -Name 'BtnRefreshDeltaCertHistory'
    $grid            = Find-Control -Parent $TabContent -Name 'DeltaCertResultGrid'

    # Bind DataGrid to observable collection
    if ($null -ne $grid) {
        $grid.ItemsSource = $script:DeltaCertResultDataSource
    }

    # Configure button -- opens dialog, stores params, updates summary (does NOT run)
    if ($btnConfigure) {
        $btnConfigure.Add_Click({
            & $module {
                param($tc)

                $dialogXaml = Get-XamlPath -FileName 'DeltaCertRunDialog.xaml'
                $defaults   = Get-DeltaCertDialogDefaults
                $dialogResult = Show-SPGuiDialog `
                    -XamlPath      $dialogXaml `
                    -ControlNames  @('TxtSourceIds', 'TxtHoursBack', 'TxtDeadlineDays', 'CboReviewerMode') `
                    -Defaults      $defaults

                if ($null -ne $dialogResult) {
                    $script:LastDeltaCertParams = $dialogResult
                    Update-DeltaCertSummaryLabel -TabContent $tc
                }
            } $TabContent
        }.GetNewClosure())
    }

    # Run Delta Cert button
    if ($btnRun) {
        $btnRun.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDeltaCertRun -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Run Cleanup button
    if ($btnCleanup) {
        $btnCleanup.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDeltaCertCleanup -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Run Escalation button
    if ($btnEscalate) {
        $btnEscalate.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDeltaCertEscalation -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Generate Delta Report button
    if ($btnDeltaReport) {
        $btnDeltaReport.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDeltaReport -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Open Output Folder button
    if ($btnOpenFolder) {
        $btnOpenFolder.Add_Click({
            $outputPath = & $module { Resolve-DeltaCertOutputPath }
            if (-not (Test-Path $outputPath)) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$outputPath`""
        }.GetNewClosure())
    }

    # Refresh history button
    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            & $module {
                param($tc)
                Load-DeltaCertHistory -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Populate summary label and history on init
    Update-DeltaCertSummaryLabel -TabContent $TabContent
    Load-DeltaCertHistory -TabContent $TabContent
}

function Get-DeltaCertDialogDefaults {
    <#
    .SYNOPSIS
        Returns dialog defaults: last-used params if available, otherwise from config.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -ne $script:LastDeltaCertParams) {
        return $script:LastDeltaCertParams
    }

    $defaults = @{
        TxtSourceIds    = ''
        TxtHoursBack    = '24'
        TxtDeadlineDays = '2'
        CboReviewerMode = 'Manager'
    }

    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'DeltaCert' -and
            $null -ne $config.DeltaCert) {
            $dc = $config.DeltaCert
            if ($dc.PSObject.Properties.Name -contains 'SourceIds' -and $dc.SourceIds) {
                $defaults['TxtSourceIds'] = ($dc.SourceIds -join ', ')
            }
            if ($dc.PSObject.Properties.Name -contains 'DefaultHoursBack' -and $dc.DefaultHoursBack) {
                $defaults['TxtHoursBack'] = [string]$dc.DefaultHoursBack
            }
            if ($dc.PSObject.Properties.Name -contains 'DefaultDeadlineDays' -and $dc.DefaultDeadlineDays) {
                $defaults['TxtDeadlineDays'] = [string]$dc.DefaultDeadlineDays
            }
            if ($dc.PSObject.Properties.Name -contains 'DefaultReviewerMode' -and $dc.DefaultReviewerMode) {
                $defaults['CboReviewerMode'] = $dc.DefaultReviewerMode
            }
        }
    }
    catch { }

    return $defaults
}

function Get-EscalationDialogDefaults {
    <#
    .SYNOPSIS
        Returns escalation dialog defaults: last-used params if available, otherwise from config.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -ne $script:LastEscalationParams) {
        return $script:LastEscalationParams
    }

    $defaults = @{
        TxtCampaignPrefix = 'AD Delta Cert'
        TxtStaleHours     = '24'
        TxtMaxLevels      = '2'
    }

    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'DeltaCert' -and
            $null -ne $config.DeltaCert) {
            if ($config.DeltaCert.PSObject.Properties.Name -contains 'Escalation' -and
                $null -ne $config.DeltaCert.Escalation) {
                $esc = $config.DeltaCert.Escalation
                if ($esc.PSObject.Properties.Name -contains 'CampaignNamePrefix' -and
                    -not [string]::IsNullOrWhiteSpace($esc.CampaignNamePrefix)) {
                    $defaults['TxtCampaignPrefix'] = $esc.CampaignNamePrefix
                }
                if ($esc.PSObject.Properties.Name -contains 'DefaultStaleHours') {
                    $defaults['TxtStaleHours'] = [string]$esc.DefaultStaleHours
                }
                if ($esc.PSObject.Properties.Name -contains 'MaxEscalationLevels') {
                    $defaults['TxtMaxLevels'] = [string]$esc.MaxEscalationLevels
                }
            }
        }
    }
    catch { }

    return $defaults
}

function Update-DeltaCertSummaryLabel {
    <#
    .SYNOPSIS
        Updates the DeltaCert summary label to reflect current parameters.
    .DESCRIPTION
        Shows "Sources: src-ad-001 | 24h | 2d deadline | Manager" when configured,
        or "Not configured. Click Configure to set parameters." otherwise.
    #>
    [CmdletBinding()]
    param($TabContent)

    $label = Find-Control -Parent $TabContent -Name 'DeltaCertSummaryLabel'
    if ($null -eq $label) { return }

    $params = $script:LastDeltaCertParams
    if ($null -eq $params) {
        # Try loading from config defaults (without storing as LastDeltaCertParams)
        $defaults = Get-DeltaCertDialogDefaults
        $sourceText = if ($defaults['TxtSourceIds']) { $defaults['TxtSourceIds'].Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($sourceText)) {
            $label.Text = 'Not configured. Click Configure to set parameters.'
            return
        }
        $params = $defaults
    }

    $sourceText = if ($params['TxtSourceIds']) { $params['TxtSourceIds'].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($sourceText)) {
        $label.Text = 'Not configured. Click Configure to set parameters.'
        return
    }

    $hours    = if ($params['TxtHoursBack'])    { $params['TxtHoursBack'].Trim() }    else { '24' }
    $deadline = if ($params['TxtDeadlineDays']) { $params['TxtDeadlineDays'].Trim() } else { '2' }
    $reviewer = if ($params['CboReviewerMode']) { $params['CboReviewerMode'] }         else { 'Manager' }

    $label.Text = "Sources: $sourceText | ${hours}h | ${deadline}d deadline | $reviewer"
}

function Invoke-GuiDeltaCertRun {
    <#
    .SYNOPSIS
        Shows run parameters dialog, then runs delta cert in a background runspace.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsDeltaCertRunning) {
        Set-StatusMessage -Message 'A delta cert run is already in progress.' -IsError
        return
    }

    # Show parameters dialog
    $dialogXaml = Get-XamlPath -FileName 'DeltaCertRunDialog.xaml'
    $defaults   = Get-DeltaCertDialogDefaults
    $dialogResult = Show-SPGuiDialog `
        -XamlPath      $dialogXaml `
        -ControlNames  @('TxtSourceIds', 'TxtHoursBack', 'TxtDeadlineDays', 'CboReviewerMode') `
        -Defaults      $defaults

    if ($null -eq $dialogResult) { return }

    # Persist for next open and update summary label
    $script:LastDeltaCertParams = $dialogResult
    Update-DeltaCertSummaryLabel -TabContent $TabContent

    # Extract values from dialog result
    $sourceIdText = if ($dialogResult['TxtSourceIds']) { $dialogResult['TxtSourceIds'].Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($sourceIdText)) {
        Set-StatusMessage -Message 'No source IDs specified. Configure Source IDs in the dialog or Settings tab.' -IsError
        return
    }

    $sourceIds = @($sourceIdText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $hoursBack = 24
    if ($dialogResult['TxtHoursBack']) {
        [int]::TryParse($dialogResult['TxtHoursBack'].Trim(), [ref]$hoursBack) | Out-Null
    }

    $deadlineDays = 2
    if ($dialogResult['TxtDeadlineDays']) {
        [int]::TryParse($dialogResult['TxtDeadlineDays'].Trim(), [ref]$deadlineDays) | Out-Null
    }

    $reviewerMode = if ($dialogResult['CboReviewerMode']) { $dialogResult['CboReviewerMode'] } else { 'Manager' }

    $progressBar     = Find-Control -Parent $TabContent -Name 'DeltaCertProgressBar'
    $progressPercent = Find-Control -Parent $TabContent -Name 'DeltaCertProgressPercent'
    $statusLabel     = Find-Control -Parent $TabContent -Name 'DeltaCertStatusLabel'
    $btnRun          = Find-Control -Parent $TabContent -Name 'BtnRunDeltaCert'

    $script:IsDeltaCertRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Starting delta cert run. CorrelationID: $correlationID"

    if ($null -ne $statusLabel) {
        $statusLabel.Text = 'Running delta cert...'
    }

    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }

    if ($null -ne $progressPercent) {
        $progressPercent.Text = '0%'
    }

    if ($null -ne $btnRun) {
        $btnRun.IsEnabled = $false
    }

    # Create background runspace (STA)
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('SourceIds',      $sourceIds)
    $runspace.SessionStateProxy.SetVariable('HoursBack',      $hoursBack)
    $runspace.SessionStateProxy.SetVariable('DeadlineDays',   $deadlineDays)
    $runspace.SessionStateProxy.SetVariable('ReviewerMode',   $reviewerMode)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',  $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',    $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',     $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',    $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent', $progressPercent)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',    $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # Load modules in runspace
        $coreModule      = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule       = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $deltaCertModule = Join-Path $ToolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
        $guiModule       = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $deltaCertModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $runResult = Invoke-SPGuiDeltaCertRun `
            -SourceIds      $SourceIds `
            -HoursBack      $HoursBack `
            -DeadlineDays   $DeadlineDays `
            -ReviewerMode   $ReviewerMode `
            -CorrelationID  $CorrelationID

        # Marshal result back to UI thread
        $dispatcher       = $MainWindow.Dispatcher
        $capturedResult   = $runResult
        $capturedProgress = $ProgressBar
        $capturedPercent  = $ProgressPercent
        $capturedLabel    = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgress) {
                $capturedProgress.Value = 100
            }
            if ($null -ne $capturedPercent) {
                $capturedPercent.Text = '100%'
            }
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $data = $capturedResult.Data
                    $capturedLabel.Text = "Delta cert complete. Campaigns: $($data.CampaignsCreated), Reason: $($data.Reason)"
                } else {
                    $capturedLabel.Text = "Delta cert failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $runResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null

    $asyncResult = $psInstance.BeginInvoke()

    # DispatcherTimer polls for completion (500ms interval)
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnRun
    $capturedProg     = $progressBar
    $capturedPercent2 = $progressPercent
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Delta cert run failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Delta cert run complete.'

                    # Update DataGrid with result
                    try {
                        $psResult = $ps.EndInvoke($async)
                        if ($null -ne $psResult -and $psResult.Count -gt 0) {
                            $finalResult = $psResult[0]
                            if ($null -ne $finalResult -and $finalResult.Success -and $null -ne $finalResult.Data) {
                                $script:DeltaCertResultDataSource.Add($finalResult.Data)
                            }
                        }
                    }
                    catch { }
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) { $prog.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($null -ne $pct)  { $pct.Text = '' }

                Load-DeltaCertHistory -TabContent $tab

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsDeltaCertRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPercent2
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiDeltaCertCleanup {
    <#
    .SYNOPSIS
        Runs delta cert cleanup in a background runspace.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsDeltaCertRunning) {
        Set-StatusMessage -Message 'A delta cert operation is already in progress.' -IsError
        return
    }

    $statusLabel = Find-Control -Parent $TabContent -Name 'DeltaCertStatusLabel'
    $btnCleanup  = Find-Control -Parent $TabContent -Name 'BtnCleanupDeltaCert'

    $script:IsDeltaCertRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message 'Running delta cert cleanup...'
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running cleanup...' }
    if ($null -ne $btnCleanup) { $btnCleanup.IsEnabled = $false }

    # Read config for cleanup params
    $campaignNamePrefix = 'AD Delta Cert'
    $daysStale = 3
    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'DeltaCert' -and $null -ne $config.DeltaCert) {
            if ($config.DeltaCert.PSObject.Properties.Name -contains 'CampaignNamePrefix' -and
                -not [string]::IsNullOrWhiteSpace($config.DeltaCert.CampaignNamePrefix)) {
                $campaignNamePrefix = $config.DeltaCert.CampaignNamePrefix
            }
            if ($config.DeltaCert.PSObject.Properties.Name -contains 'CleanupDaysStale') {
                $daysStale = [int]$config.DeltaCert.CleanupDaysStale
            }
        }
    }
    catch { }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CampaignNamePrefix', $campaignNamePrefix)
    $runspace.SessionStateProxy.SetVariable('DaysStale',          $daysStale)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',      $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',        $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',         $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',        $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        $coreModule      = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule       = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $deltaCertModule = Join-Path $ToolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
        $guiModule       = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $deltaCertModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $cleanupResult = Invoke-SPGuiDeltaCertCleanup `
            -CampaignNamePrefix $CampaignNamePrefix `
            -DaysStale          $DaysStale `
            -CorrelationID      $CorrelationID

        $dispatcher    = $MainWindow.Dispatcher
        $capturedResult = $cleanupResult
        $capturedLabel  = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $capturedLabel.Text = $capturedResult.Message
                } else {
                    $capturedLabel.Text = "Cleanup failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $cleanupResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedBtn      = $btnCleanup
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $btn)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Cleanup failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Cleanup complete.'
                }

                if ($null -ne $btn) { $btn.IsEnabled = $true }

                try {
                    $ps.EndInvoke($async) | Out-Null
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsDeltaCertRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedBtn
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiDeltaCertEscalation {
    <#
    .SYNOPSIS
        Shows escalation parameters dialog, then runs escalation in a background runspace.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsDeltaCertRunning) {
        Set-StatusMessage -Message 'A delta cert operation is already in progress.' -IsError
        return
    }

    # Show escalation parameters dialog
    $dialogXaml = Get-XamlPath -FileName 'DeltaCertEscalateDialog.xaml'
    $defaults   = Get-EscalationDialogDefaults
    $dialogResult = Show-SPGuiDialog `
        -XamlPath      $dialogXaml `
        -ControlNames  @('TxtCampaignPrefix', 'TxtStaleHours', 'TxtMaxLevels') `
        -Defaults      $defaults

    if ($null -eq $dialogResult) { return }

    # Persist for next open
    $script:LastEscalationParams = $dialogResult

    $statusLabel  = Find-Control -Parent $TabContent -Name 'DeltaCertStatusLabel'
    $btnEscalate  = Find-Control -Parent $TabContent -Name 'BtnEscalateDeltaCert'

    $script:IsDeltaCertRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message 'Running delta cert escalation...'
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running escalation...' }
    if ($null -ne $btnEscalate) { $btnEscalate.IsEnabled = $false }

    # Extract values from dialog result
    $campaignNamePrefix = if ($dialogResult['TxtCampaignPrefix']) {
        $dialogResult['TxtCampaignPrefix'].Trim()
    } else { 'AD Delta Cert' }

    $staleHours = 24
    if ($dialogResult['TxtStaleHours']) {
        [int]::TryParse($dialogResult['TxtStaleHours'].Trim(), [ref]$staleHours) | Out-Null
    }

    $maxEscalationLevels = 2
    if ($dialogResult['TxtMaxLevels']) {
        [int]::TryParse($dialogResult['TxtMaxLevels'].Trim(), [ref]$maxEscalationLevels) | Out-Null
    }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CampaignNamePrefix',  $campaignNamePrefix)
    $runspace.SessionStateProxy.SetVariable('StaleHours',          $staleHours)
    $runspace.SessionStateProxy.SetVariable('MaxEscalationLevels', $maxEscalationLevels)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',       $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',         $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',          $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',         $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        $coreModule      = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule       = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $deltaCertModule = Join-Path $ToolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
        $guiModule       = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $deltaCertModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $escResult = Invoke-SPGuiDeltaCertEscalate `
            -CampaignNamePrefix  $CampaignNamePrefix `
            -StaleHours          $StaleHours `
            -MaxEscalationLevels $MaxEscalationLevels `
            -CorrelationID       $CorrelationID

        $dispatcher    = $MainWindow.Dispatcher
        $capturedResult = $escResult
        $capturedLabel  = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $capturedLabel.Text = $capturedResult.Message
                } else {
                    $capturedLabel.Text = "Escalation failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $escResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedBtn      = $btnEscalate
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $btn)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Escalation failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Escalation complete.'
                }

                if ($null -ne $btn) { $btn.IsEnabled = $true }

                try {
                    $ps.EndInvoke($async) | Out-Null
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsDeltaCertRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedBtn
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiDeltaReport {
    <#
    .SYNOPSIS
        Generates a delta report in a background runspace from the GUI.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsDeltaCertRunning) {
        Set-StatusMessage -Message 'A delta cert operation is already in progress.' -IsError
        return
    }

    $statusLabel     = Find-Control -Parent $TabContent -Name 'DeltaCertStatusLabel'
    $btnDeltaReport  = Find-Control -Parent $TabContent -Name 'BtnGenerateDeltaReport'

    # Resolve source IDs from last-used params or config defaults
    $params = $script:LastDeltaCertParams
    if ($null -eq $params) {
        $params = Get-DeltaCertDialogDefaults
    }

    $sourceIdText = if ($params['TxtSourceIds']) { $params['TxtSourceIds'].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($sourceIdText)) {
        Set-StatusMessage -Message 'No source IDs configured. Click Configure to set Source IDs first.' -IsError
        return
    }

    $sourceIds = @($sourceIdText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $hoursBack = 24
    if ($params['TxtHoursBack']) {
        [int]::TryParse($params['TxtHoursBack'].Trim(), [ref]$hoursBack) | Out-Null
    }

    $outputPath = Resolve-DeltaCertOutputPath
    $reportsPath = Join-Path $outputPath 'reports'

    $script:IsDeltaCertRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Generating delta report. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Generating delta report...' }
    if ($null -ne $btnDeltaReport) { $btnDeltaReport.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('SourceIds',     $sourceIds)
    $runspace.SessionStateProxy.SetVariable('HoursBack',     $hoursBack)
    $runspace.SessionStateProxy.SetVariable('OutputPath',    $reportsPath)
    $runspace.SessionStateProxy.SetVariable('CorrelationID', $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',   $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',    $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',   $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        $coreModule      = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule       = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $deltaCertModule = Join-Path $ToolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'
        $guiModule       = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $deltaCertModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $reportResult = Invoke-SPGuiDeltaReport `
            -SourceIds     $SourceIds `
            -HoursBack     $HoursBack `
            -OutputPath    $OutputPath `
            -CorrelationID $CorrelationID

        $dispatcher     = $MainWindow.Dispatcher
        $capturedResult = $reportResult
        $capturedLabel  = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $capturedLabel.Text = $capturedResult.Message
                } else {
                    $capturedLabel.Text = "Delta report failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $reportResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedBtn      = $btnDeltaReport
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $btn)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $finalResult = $null
                try {
                    $finalResult = $ps.EndInvoke($async)
                } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Delta report failed: $errMsg" -IsError
                } else {
                    # Open the HTML report in the default browser
                    if ($null -ne $finalResult -and $finalResult.Count -gt 0) {
                        $result = $finalResult[0]
                        if ($result.Success -and $null -ne $result.Data -and
                            -not [string]::IsNullOrWhiteSpace($result.Data.HtmlPath) -and
                            (Test-Path $result.Data.HtmlPath)) {
                            Start-Process $result.Data.HtmlPath
                        }
                    }
                    Set-StatusMessage -Message 'Delta report generated successfully.'
                }

                if ($null -ne $btn) { $btn.IsEnabled = $true }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsDeltaCertRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedBtn
    }.GetNewClosure())

    $timer.Start()
}

function Load-DeltaCertHistory {
    <#
    .SYNOPSIS
        Populates the DeltaCertHistoryList ListBox with color-coded run entries from JSONL.
        Green = campaigns created, Gray = no changes, Orange = errors present.
    #>
    [CmdletBinding()]
    param($TabContent)

    $listBox = Find-Control -Parent $TabContent -Name 'DeltaCertHistoryList'
    if ($null -eq $listBox) { return }

    $outputPath = Resolve-DeltaCertOutputPath

    $result = Get-SPGuiDeltaCertHistory -OutputPath $outputPath

    $listBox.Items.Clear()

    if (-not $result.Success -or $result.Data.Count -eq 0) {
        $item         = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = "No recent runs found (path: $outputPath)"
        $item.Foreground = [System.Windows.Media.Brushes]::Gray
        $listBox.Items.Add($item) | Out-Null
        return
    }

    $converter   = [System.Windows.Media.BrushConverter]::new()
    $brushGreen  = $converter.ConvertFromString('#339933')
    $brushGray   = $converter.ConvertFromString('#888899')
    $brushOrange = $converter.ConvertFromString('#FF9900')

    foreach ($entry in $result.Data) {
        $item         = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = "$($entry.Timestamp) | Campaigns: $($entry.CampaignsCreated) | $($entry.Reason)"
        $item.ToolTip = "Identities: $($entry.Identities), Groups: $($entry.ManagerGroups), Errors: $($entry.Errors)"

        if ($entry.Errors -and [int]$entry.Errors -gt 0) {
            $item.Foreground = $brushOrange
        }
        elseif ($entry.Reason -match 'Created' -or ($entry.CampaignsCreated -and [int]$entry.CampaignsCreated -gt 0)) {
            $item.Foreground = $brushGreen
        }
        elseif ($entry.Reason -eq 'NoChanges') {
            $item.Foreground = $brushGray
        }

        $listBox.Items.Add($item) | Out-Null
    }
}

function Resolve-DeltaCertOutputPath {
    <#
    .SYNOPSIS
        Resolves the absolute path to the DeltaCert output directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configDeltaCertPath = $null
    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'DeltaCert' -and
            $null -ne $config.DeltaCert -and
            $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
            $configDeltaCertPath = $config.DeltaCert.OutputPath
        }
    }
    catch { }

    $rawPath = if ($configDeltaCertPath) { $configDeltaCertPath } else { '.\DeltaCert' }

    if (-not [System.IO.Path]::IsPathRooted($rawPath)) {
        $rawPath = Join-Path $script:ToolkitRoot $rawPath
    }

    return [System.IO.Path]::GetFullPath($rawPath)
}

#endregion

#region Menu Handlers

function Wire-MenuHandlers {
    [CmdletBinding()]
    param()

    # File -> Exit
    $menuExit = Find-Control -Parent $script:MainWindow -Name 'MenuExit'
    if ($menuExit) {
        $menuExit.Add_Click({ $script:MainWindow.Close() })
    }

    # Top-right Close button (explicit UI exit, same behavior as File -> Exit)
    $btnCloseApp = Find-Control -Parent $script:MainWindow -Name 'BtnCloseApp'
    if ($btnCloseApp) {
        $btnCloseApp.Add_Click({ $script:MainWindow.Close() })
    }

    # Tools -> Test Connectivity
    $menuTestConn = Find-Control -Parent $script:MainWindow -Name 'MenuTestConnectivity'
    if ($menuTestConn) {
        $menuTestConn.Add_Click({
            Set-StatusMessage -Message 'Running connectivity test...'
            $result = Test-SPGuiConnectivity -ConfigPath $script:ConfigPath
            $icon   = if ($result.Success) { [System.Windows.MessageBoxImage]::Information } else { [System.Windows.MessageBoxImage]::Warning }
            [System.Windows.MessageBox]::Show($result.OverallMessage, 'Connectivity Test', [System.Windows.MessageBoxButton]::OK, $icon) | Out-Null
            Set-StatusMessage -Message $result.OverallMessage -IsError:(-not $result.Success)
        })
    }

    # Tools -> New Vault
    $menuNewVault = Find-Control -Parent $script:MainWindow -Name 'MenuNewVault'
    if ($menuNewVault) {
        $menuNewVault.Add_Click({
            $vaultScript = Join-Path $script:ToolkitRoot 'Scripts\New-SPVault.ps1'
            if (Test-Path $vaultScript) {
                Start-Process powershell.exe -ArgumentList @('-STA', '-File', "`"$vaultScript`"") -Wait
            }
            else {
                [System.Windows.MessageBox]::Show(
                    "New-SPVault.ps1 not found at:`n$vaultScript",
                    'Script Not Found',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                ) | Out-Null
            }
        })
    }

    # Help -> About
    $menuAbout = Find-Control -Parent $script:MainWindow -Name 'MenuAbout'
    if ($menuAbout) {
        $menuAbout.Add_Click({
            $aboutText = @"
SailPoint ISC Governance Toolkit
Version 1.0.0

Tests SailPoint ISC certification campaign workflows
via the ISC REST API v3.

PowerShell 5.1 | WPF Desktop | .NET Framework 4.5+
"@
            [System.Windows.MessageBox]::Show(
                $aboutText,
                'About',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
        })
    }
}

#endregion

#region Public Entry Point

function Show-SPDashboard {
    <#
    .SYNOPSIS
        Launch the WPF dashboard window.
    .DESCRIPTION
        Loads MainWindow.xaml, initializes each tab with data and event handlers,
        and runs the WPF message loop via ShowDialog(). Returns when the user
        closes the window.
    .PARAMETER ConfigPath
        Optional path to settings.json. If omitted, uses toolkit default.
    .EXAMPLE
        Show-SPDashboard
        Show-SPDashboard -ConfigPath 'C:\Toolkit\Config\settings.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    # Capture this module so handler bodies can re-enter module scope at fire time.
    # See $script:ThisModule comment near the top of this file.
    $script:ThisModule = $ExecutionContext.SessionState.Module

    # Resolve toolkit root from module location
    # Module is at: <toolkit>\Modules\SP.Gui\SP.MainWindow.psm1
    $script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:ConfigPath  = $ConfigPath

    if (-not $script:ConfigPath) {
        # Honor settings.local.json override convention.
        $script:ConfigPath = Resolve-SPConfigPath -ToolkitRoot $script:ToolkitRoot
    }

    # Initialize structured logging so handler/dispatcher errors have somewhere to go.
    # Other entry-point scripts do this; the dashboard was the only one that did not.
    try { Initialize-SPLogging -Force -ErrorAction SilentlyContinue } catch { }

    # Create WPF Application if not already running
    if ($null -eq [System.Windows.Application]::Current) {
        $app = [System.Windows.Application]::new()
    }

    # Load main window XAML
    $mainXamlPath = Get-XamlPath -FileName 'MainWindow.xaml'
    $window = Load-XamlWindow -XamlPath $mainXamlPath
    $script:MainWindow = $window

    # Wire menu handlers
    Wire-MenuHandlers

    # Initialize tabs
    $tabControl = Find-Control -Parent $window -Name 'MainTabControl'
    if ($null -ne $tabControl) {
        # Campaign tab
        $campaignTab = Find-Control -Parent $window -Name 'CampaignTabContent'
        if ($null -ne $campaignTab) {
            Initialize-CampaignTab -TabContent $campaignTab
        }

        # Evidence tab
        $evidenceTab = Find-Control -Parent $window -Name 'EvidenceTabContent'
        if ($null -ne $evidenceTab) {
            Initialize-EvidenceTab -TabContent $evidenceTab
        }

        # Settings tab
        $settingsTab = Find-Control -Parent $window -Name 'SettingsTabContent'
        if ($null -ne $settingsTab) {
            Initialize-SettingsTab -TabContent $settingsTab
        }

        # Audit tab
        $auditTab = Find-Control -Parent $window -Name 'AuditTabContent'
        if ($null -ne $auditTab) {
            Initialize-AuditTab -TabContent $auditTab
        }

        # Delta Cert tab
        $deltaCertTab = Find-Control -Parent $window -Name 'DeltaCertTabContent'
        if ($null -ne $deltaCertTab) {
            Initialize-DeltaCertTab -TabContent $deltaCertTab
        }
    }

    # Set initial status
    Set-StatusMessage -Message "Ready | Toolkit root: $($script:ToolkitRoot)"

    # Safety net: catch any unhandled exception from event handlers so a single
    # bad handler cannot tear down the dashboard. Log via Write-SPLog (if
    # available) and surface to the status bar; mark the event handled to
    # keep the dispatcher loop alive.
    $window.Dispatcher.add_UnhandledException({
        param($eventSender, $eventArgs)
        $ex = $eventArgs.Exception
        $detail = "$($ex.GetType().FullName): $($ex.Message)"
        try {
            Write-SPLog -Message "Unhandled GUI exception: $detail" `
                -Severity ERROR -Component 'SP.Gui' -Action 'UnhandledException'
        } catch { }
        try {
            Set-StatusMessage -Message "Error (see log): $($ex.Message)" -IsError
        } catch { }
        $eventArgs.Handled = $true
    })

    try {
        Write-SPLog -Message "Dashboard launched (ConfigPath: $($script:ConfigPath))" `
            -Severity INFO -Component 'SP.Gui' -Action 'Start'
    } catch { }

    # Clamp the window into the primary screen's work area once it's laid out.
    # On smaller displays (laptops, 1366x768, etc.) a Height of 780 + CenterScreen
    # pushes the title bar above pixel 0, leaving the window uncloseable. We shrink
    # to fit, then re-center inside WorkingArea.
    $window.add_Loaded({
        try {
            try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { }
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen
            if ($null -eq $screen) { return }
            $work = $screen.WorkingArea
            $margin = 8

            # If the window is taller/wider than the work area, shrink it.
            $newW = [Math]::Min($this.Width,  [double]($work.Width  - 2 * $margin))
            $newH = [Math]::Min($this.Height, [double]($work.Height - 2 * $margin))
            if ($newW -ne $this.Width)  { $this.Width  = $newW }
            if ($newH -ne $this.Height) { $this.Height = $newH }

            # Re-center inside the work area (accounts for taskbar + multi-monitor origin).
            $this.Left = [double]$work.X + [Math]::Max(0, ($work.Width  - $this.Width)  / 2)
            $this.Top  = [double]$work.Y + [Math]::Max(0, ($work.Height - $this.Height) / 2)
        } catch {
            try {
                Write-SPLog -Message "Window fit-to-screen failed: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.Gui' -Action 'FitToScreen'
            } catch { }
        }
    })

    # Show window
    $window.ShowDialog() | Out-Null
}

#endregion

Export-ModuleMember -Function @(
    'Show-SPDashboard'
)
