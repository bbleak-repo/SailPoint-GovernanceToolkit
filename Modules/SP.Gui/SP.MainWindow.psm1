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

try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop } catch {}
try { Add-Type -AssemblyName PresentationCore      -ErrorAction Stop } catch {}
try { Add-Type -AssemblyName WindowsBase           -ErrorAction Stop } catch {}
try { Add-Type -AssemblyName System.Xml            -ErrorAction Stop } catch {}

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
# Adaptive Reports tab state (AR-15). IsAdaptiveRunning guards the Generate
# handler against re-entrancy; LastAdaptiveReportPath feeds BtnArOpenReport.
$script:IsAdaptiveRunning           = $false
$script:LastAdaptiveReportPath      = $null
$script:IsGovernanceRunning         = $false
$script:LastDeltaCertParams         = $null
$script:LastEscalationParams        = $null
$script:LastAuditQueryParams        = $null

# SDK Features tab data sources (one ObservableCollection per sub-tab grid).
# Populated on a background runspace in SDK-11; bound to each grid's
# ItemsSource inside Initialize-SdkTab.
$script:SdkTemplateDataSource       = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkCertSummaryDataSource    = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkApprovalDataSource       = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkWorkItemDataSource       = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkWorkflowDataSource       = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkExecutionDataSource      = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:SdkFilterDataSource         = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()

# Cert Summaries cascade state (SDK-18 shipped). $SdkCertCascadeBusy guards the
# combo SelectionChanged handlers against re-entrancy while we mutate the combos
# programmatically; $SdkCertLoadedCampaign records which campaign's certifications
# are currently loaded so we only repopulate the cert combo on a campaign change.
$script:SdkCertCascadeBusy           = $false
$script:SdkCertLoadedCampaign        = $null
$script:IsSdkRunning                 = $false
# Round-05 T-01 fix: identity-keyed snapshot of each SDK sub-tab button's
# IsEnabled at the moment Set-SdkSubTabButtonsEnabled disables it for a load, so
# the matching re-enable restores the prior state instead of unconditionally
# forcing IsEnabled=$true (which would wrongly enable design-disabled controls
# such as BtnSdkRefreshSummaries, IsEnabled="False" in SdkTab.xaml per SDK-18).
$script:SdkButtonEnabledSnapshot     = $null
# Cached checkbox reference set by Initialize-SdkTab so OnLoaded closures can
# read IsChecked without a FindName call (avoids namescope resolution issues
# when the dashboard is driven by a cross-process automation tool).
$script:SdkWorkItemShowCompletedChk  = $null
# Shadow of ChkSdkShowCompleted.IsChecked -- updated in the Checked/Unchecked
# handlers so Invoke-SdkWorkItemRefresh never has to read WPF property state
# cross-message-pump (where COM automation toggles may not have propagated yet).
$script:SdkWorkItemShowCompleted     = $false

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

    # Governance settings
    if ($config.PSObject.Properties.Name -contains 'Governance') {
        $gov = $config.Governance
        if ($gov.PSObject.Properties.Name -contains 'MetricsOutputPath') {
            & $setField 'TxtGovMetricsPath' $gov.MetricsOutputPath
        }
        if ($gov.PSObject.Properties.Name -contains 'HealthCheckOnStartup') {
            & $setField 'ChkGovHealthCheckOnStartup' $gov.HealthCheckOnStartup
        }
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

    $timeoutVal     = 60; [int]::TryParse((& $getField 'TxtApiTimeout'),    [ref]$timeoutVal)     | Out-Null
    $retryVal       = 3;  [int]::TryParse((& $getField 'TxtRetryCount'),    [ref]$retryVal)       | Out-Null
    $maxRunVal      = 10; [int]::TryParse((& $getField 'TxtMaxCampaignsPerRun'), [ref]$maxRunVal) | Out-Null
    $retryDelayVal  = 5;  [int]::TryParse((& $getField 'TxtRetryDelay'),    [ref]$retryDelayVal)  | Out-Null
    $rateLimitVal   = 95; [int]::TryParse((& $getField 'TxtRateLimit'),     [ref]$rateLimitVal)   | Out-Null
    $rateWindowVal  = 10; [int]::TryParse((& $getField 'TxtRateWindow'),    [ref]$rateWindowVal)  | Out-Null

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
            RetryDelaySeconds          = $retryDelayVal
            RateLimitRequestsPerWindow = $rateLimitVal
            RateLimitWindowSeconds     = $rateWindowVal
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

    # Governance: overlay GUI fields onto existing config to preserve non-GUI keys
    if ($null -ne $existingConfig -and
        $existingConfig.PSObject.Properties.Name -contains 'Governance') {
        $govExisting = $existingConfig.Governance
        $govConfig = [ordered]@{}
        foreach ($prop in $govExisting.PSObject.Properties) {
            $govConfig[$prop.Name] = $prop.Value
        }
        $govConfig['MetricsOutputPath']      = & $getField 'TxtGovMetricsPath' '.\GovernanceMetrics'
        $govConfig['HealthCheckOnStartup']   = (& $getField 'ChkGovHealthCheckOnStartup' $false)
    }
    else {
        $govConfig = [ordered]@{
            MetricsOutputPath    = & $getField 'TxtGovMetricsPath' '.\GovernanceMetrics'
            HealthCheckOnStartup = (& $getField 'ChkGovHealthCheckOnStartup' $false)
        }
    }
    $newConfig['Governance'] = $govConfig

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
                    -ControlNames  @('TxtCampaignName', 'CboStatus', 'CboTimespan', 'CboType', 'TxtCreatedAfter', 'TxtCreatedBefore') `
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

    # Double-click on report list item opens file.
    # WPF event delegates drop module SessionState in PS 5.1; .GetNewClosure()
    # alone is not enough -- the body needs to run inside the module via
    # `& $module { param() ... } $args` so that $auditReportList resolves.
    if ($auditReportList) {
        $auditReportList.Add_MouseDoubleClick({
            & $module {
                param($lb)
                $selected = $lb.SelectedItem
                if ($null -ne $selected -and $null -ne $selected.Tag -and (Test-Path $selected.Tag)) {
                    try { Write-SPLog -Message ("Opening audit report: {0}" -f $selected.Tag) -Severity INFO -Component 'SP.Gui' -Action 'OpenReport' } catch { }
                    Start-Process $selected.Tag
                }
            } $auditReportList
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
        -ControlNames  @('TxtCampaignName', 'CboStatus', 'CboTimespan', 'CboType', 'TxtCreatedAfter', 'TxtCreatedBefore') `
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

    $campaignType = $null
    if ($dialogResult['CboType'] -and $dialogResult['CboType'] -ne '(All)') {
        $campaignType = $dialogResult['CboType']
    }

    $createdAfter  = ''
    if ($dialogResult['TxtCreatedAfter']) {
        $createdAfter = $dialogResult['TxtCreatedAfter'].Trim()
    }

    $createdBefore = ''
    if ($dialogResult['TxtCreatedBefore']) {
        $createdBefore = $dialogResult['TxtCreatedBefore'].Trim()
    }

    # Build parameters
    $queryParams = @{ DaysBack = $daysBack }
    if ($campaignName)  { $queryParams['CampaignNameContains'] = $campaignName }
    if ($statusFilter)  { $queryParams['Status']               = $statusFilter }
    if ($campaignType)  { $queryParams['CampaignType']         = $campaignType }
    if ($createdAfter)  { $queryParams['CreatedAfter']         = $createdAfter }
    if ($createdBefore) { $queryParams['CreatedBefore']        = $createdBefore }

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

    # Map Audit.DefaultDaysBack from config to the nearest CboTimespan label.
    # Valid labels: '1 day', '7 days', '14 days', '30 days', '60 days',
    #               '90 days', '180 days', '365 days'.
    $defaultTimespan = '30 days'
    try {
        $auditCfg = (Get-SPConfig).Audit
        if ($null -ne $auditCfg -and
            $auditCfg.PSObject.Properties.Name -contains 'DefaultDaysBack') {
            $days = [int]$auditCfg.DefaultDaysBack
            $defaultTimespan = switch ($true) {
                ($days -le 1)   { '1 day' }
                ($days -le 7)   { '7 days' }
                ($days -le 14)  { '14 days' }
                ($days -le 30)  { '30 days' }
                ($days -le 60)  { '60 days' }
                ($days -le 90)  { '90 days' }
                ($days -le 180) { '180 days' }
                default         { '365 days' }
            }
        }
    } catch { }

    return @{
        TxtCampaignName  = ''
        CboStatus        = '(All)'
        CboTimespan      = $defaultTimespan
        CboType          = '(All)'
        TxtCreatedAfter  = ''
        TxtCreatedBefore = ''
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
    $type     = if ($params['CboType'] -and $params['CboType'] -ne '(All)') { $params['CboType'] } else { $null }

    $campaignName = ''
    if ($params['TxtCampaignName']) {
        $campaignName = $params['TxtCampaignName'].Trim()
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($campaignName)) { $parts.Add("Campaign: $campaignName") }
    $parts.Add("Status: $status")
    if ($null -ne $type) { $parts.Add("Type: $type") }
    $parts.Add("Timespan: $timespan")

    $label.Text = ($parts -join ' | ')
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

    # Disconnected Apps controls
    $btnRunBatch      = Find-Control -Parent $TabContent -Name 'BtnRunDisconnectedBatch'
    $btnCheckDelivery = Find-Control -Parent $TabContent -Name 'BtnCheckDelivery'
    $btnViewSla       = Find-Control -Parent $TabContent -Name 'BtnViewSla'
    $btnRefreshDcApp  = Find-Control -Parent $TabContent -Name 'BtnRefreshDcAppStatus'

    if ($btnRunBatch) {
        $btnRunBatch.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDisconnectedAppBatch -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnCheckDelivery) {
        $btnCheckDelivery.Add_Click({
            & $module {
                param($tc)
                Load-DisconnectedAppStatus -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnViewSla) {
        $btnViewSla.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiViewDisconnectedAppSla -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnRefreshDcApp) {
        $btnRefreshDcApp.Add_Click({
            & $module {
                param($tc)
                Load-DisconnectedAppStatus -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Populate summary label, history, and disconnected app status on init
    Update-DeltaCertSummaryLabel -TabContent $TabContent
    Load-DeltaCertHistory -TabContent $TabContent
    Load-DisconnectedAppStatus -TabContent $TabContent
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

function Wait-SPReportFileReady {
    <#
    .SYNOPSIS
        Waits for a freshly-generated report file to be fully written before a
        consumer (the default browser) is told to open it.
    .DESCRIPTION
        Report HTML is written by a background runspace. On some systems the file
        is briefly present-but-not-readable -- the OS write-behind cache or an
        anti-virus on-write scan can hold a lock for a moment after the path
        exists -- so opening it immediately shows a blank or partial page. A bare
        Test-Path is not enough. This polls until the file length is non-zero AND
        stable across two consecutive reads AND it can be opened for shared read,
        or until TimeoutMs elapses (caller then opens anyway, best-effort).

        Runs on the UI thread, so the ceiling is deliberately low; for an
        already-written report it returns after ~2 polls (~240ms), which is also
        the small "settle" delay we want before handing the file to the browser.
        Returns $true once ready, $false on timeout.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutMs = 2500,
        [int]$PollMs    = 120
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $lastLen  = [long]-1
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $len = (Get-Item -LiteralPath $Path).Length
                if ($len -gt 0 -and $len -eq $lastLen) {
                    # Length stable across two polls -- confirm it actually opens.
                    $fs = [System.IO.File]::Open(
                        $Path,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite)
                    $fs.Close()
                    return $true
                }
                $lastLen = $len
            }
        } catch {
            # Still locked / mid-write -- keep polling until the deadline.
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
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
                            # Let the runspace-written file fully flush + unlock
                            # before the browser opens it, otherwise it can render
                            # a blank or partial page.
                            Wait-SPReportFileReady -Path $result.Data.HtmlPath | Out-Null
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

function Load-DisconnectedAppStatus {
    <#
    .SYNOPSIS
        Calls Get-SPGuiDisconnectedAppStatus and updates the DcAppStatusLabel.
    #>
    [CmdletBinding()]
    param($TabContent)

    $label = Find-Control -Parent $TabContent -Name 'DcAppStatusLabel'
    if ($null -eq $label) { return }

    $label.Text = 'Checking...'

    $result = Get-SPGuiDisconnectedAppStatus

    if ($null -ne $result -and $null -ne $result.Data) {
        $label.Text = $result.Data.SummaryText
    }
    else {
        $label.Text = 'Status unavailable'
    }
}

function Invoke-GuiDisconnectedAppBatch {
    <#
    .SYNOPSIS
        Launches the disconnected app batch script in a new PowerShell window.
    .DESCRIPTION
        Runs Scripts\Invoke-SPDisconnectedAppBatch.ps1 via Start-Process so the
        long-running batch pipeline does not block the GUI. The console window
        stays open on completion so the user can review output.
        A background runspace monitors the process exit code and updates the
        status bar when the batch completes.
    #>
    [CmdletBinding()]
    param($TabContent)

    $batchScript = Join-Path $script:ToolkitRoot 'Scripts\Invoke-SPDisconnectedAppBatch.ps1'

    if (-not (Test-Path -Path $batchScript -PathType Leaf)) {
        Set-StatusMessage -Message 'Batch script not found: Scripts\Invoke-SPDisconnectedAppBatch.ps1' -IsError
        return
    }

    try {
        $proc = Start-Process 'powershell.exe' `
            -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$batchScript`"" `
            -WorkingDirectory $script:ToolkitRoot `
            -PassThru
        Set-StatusMessage -Message 'Disconnected app batch launched in a new window. Waiting for completion...'
    }
    catch {
        Set-StatusMessage -Message "Failed to launch batch: $($_.Exception.Message)" -IsError
        return
    }

    # Spin up a runspace that blocks until the process exits, then marshals
    # the exit code back to the GUI thread via the Dispatcher.
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('BatchProcess', $proc)
    $runspace.SessionStateProxy.SetVariable('MainWindow',   $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('StatusBarText', (Find-Control $script:MainWindow 'StatusBarText'))

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $psInstance.AddScript({
        try {
            $BatchProcess.WaitForExit()
            $exitCode = $BatchProcess.ExitCode
        }
        catch {
            $exitCode = -1
        }

        $capturedWindow   = $MainWindow
        $capturedExitCode = $exitCode

        if ($null -ne $capturedWindow) {
            $capturedWindow.Dispatcher.Invoke([System.Action]{
                $msg = if ($capturedExitCode -eq 0) { "Batch complete (exit code 0)." } else { "Batch failed (exit code $capturedExitCode)." }
                if ($null -ne $StatusBarText) { $StatusBarText.Text = $msg }
            }, [System.Windows.Threading.DispatcherPriority]::Normal)
        }
    }) | Out-Null

    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $asyncResult      = $psInstance.BeginInvoke()

    # Fire-and-forget: clean up once the monitor runspace finishes.
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromSeconds(2)

    $capturedTimer    = $timer
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()
            try { $ps.EndInvoke($async) } catch { }
            try { $ps.Dispose(); $rs.Close() } catch { }
        } $capturedTimer $capturedPs $capturedRunspace $asyncResult
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiViewDisconnectedAppSla {
    <#
    .SYNOPSIS
        Shows a per-app SLA compliance summary for disconnected apps in the status bar.
    .DESCRIPTION
        Reads DisconnectedApps.Applications from settings.json and checks the most
        recent snapshot file for each enabled app. Calculates whether the snapshot
        age is within the app's SlaDays budget and formats a compact summary into
        the main status label, e.g.:
            "PEP-Plus: SLA 1d [OK] | DebtNext: SLA 2d [MISS]"
        No external module dependency -- all logic is self-contained.
    #>
    [CmdletBinding()]
    param($TabContent)

    Set-StatusMessage -Message 'Checking SLA status...'

    try {
        # Resolve config
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams

        if ($null -eq $config -or
            -not ($config.PSObject.Properties.Name -contains 'DisconnectedApps') -or
            $null -eq $config.DisconnectedApps) {
            Set-StatusMessage -Message 'SLA check: DisconnectedApps config not found.'
            return
        }

        $daConfig = $config.DisconnectedApps
        $apps     = $daConfig.Applications
        if ($null -eq $apps -or $apps.Count -eq 0) {
            Set-StatusMessage -Message 'SLA check: No applications defined in config.'
            return
        }

        # Resolve snapshot root
        $rawSnapshotPath = if (-not [string]::IsNullOrWhiteSpace($daConfig.SnapshotPath)) {
            $daConfig.SnapshotPath
        } else {
            '.\DisconnectedApps\Snapshots'
        }
        if (-not [System.IO.Path]::IsPathRooted($rawSnapshotPath)) {
            $rawSnapshotPath = Join-Path $script:ToolkitRoot $rawSnapshotPath
        }
        $snapshotRoot = [System.IO.Path]::GetFullPath($rawSnapshotPath)

        $now     = [System.DateTime]::UtcNow
        $parts   = [System.Collections.Generic.List[string]]::new()
        $enabled = @($apps | Where-Object { $_.Enabled -eq $true })

        if ($enabled.Count -eq 0) {
            Set-StatusMessage -Message 'SLA check: No enabled applications in config.'
            return
        }

        foreach ($app in $enabled) {
            $appName = $app.Name
            $slaDays = [int]$app.SlaDays

            # Look for the most recent snapshot file for this app.
            # Convention: snapshot files live under SnapshotPath\<AppName>\
            # or directly under SnapshotPath with the app name in the filename.
            $appSnapshotDir = Join-Path $snapshotRoot $appName
            $latestFile     = $null

            if (Test-Path -Path $appSnapshotDir -PathType Container) {
                $latestFile = Get-ChildItem -Path $appSnapshotDir -File -Recurse |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1
            }

            if ($null -eq $latestFile) {
                # Fallback: any file in snapshot root whose name contains the app name
                if (Test-Path -Path $snapshotRoot -PathType Container) {
                    $latestFile = Get-ChildItem -Path $snapshotRoot -File -Recurse |
                        Where-Object { $_.Name -like "*$appName*" } |
                        Sort-Object LastWriteTimeUtc -Descending |
                        Select-Object -First 1
                }
            }

            if ($null -eq $latestFile) {
                $parts.Add("${appName}: SLA ${slaDays}d [NO SNAPSHOT]")
                continue
            }

            $ageDays = ($now - $latestFile.LastWriteTimeUtc).TotalDays
            $status  = if ($ageDays -le $slaDays) { 'OK' } else { 'MISS' }
            $parts.Add("${appName}: SLA ${slaDays}d [$status]")
        }

        $summary = $parts -join ' | '
        Set-StatusMessage -Message "SLA: $summary"
    }
    catch {
        Set-StatusMessage -Message "SLA check error: $($_.Exception.Message)" -IsError
    }
}

#endregion

#region Adaptive Reports Tab

function Resolve-AdaptiveOutputPath {
    <#
    .SYNOPSIS
        Resolves the absolute path to the Adaptive Reports output directory.
    .DESCRIPTION
        Mirrors Resolve-AuditOutputPath but appends 'adaptive' to the audit base,
        matching the CLI's effectiveOutputPath ({Audit.OutputPath}\adaptive used by
        Invoke-SPAdaptiveReport.ps1) so the GUI writes/opens the same location.
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

    return [System.IO.Path]::GetFullPath((Join-Path $rawPath 'adaptive'))
}

function Initialize-SPAdaptiveTab {
    <#
    .SYNOPSIS
        Wires up the Adaptive Reports tab controls and event handlers.
    .DESCRIPTION
        Captures the module reference once, looks up the AR-14 named controls, and
        wires each button through the module-scope re-entry closure
        (& $module { param(...) } $args + .GetNewClosure()) so private helpers
        resolve at fire-time. No API/IO runs on init -- generation happens only on
        the Generate handler, on a background STA runspace.
    #>
    [CmdletBinding()]
    param($TabContent)

    # Local capture of module reference. .GetNewClosure() preserves locals across
    # the WPF delegate conversion; $script:* lookups don't survive it.
    $module = $script:ThisModule

    $btnGenerate   = Find-Control -Parent $TabContent -Name 'BtnArGenerate'
    $btnOpenFolder = Find-Control -Parent $TabContent -Name 'BtnArOpenFolder'
    $btnOpenReport = Find-Control -Parent $TabContent -Name 'BtnArOpenReport'
    $statusLabel   = Find-Control -Parent $TabContent -Name 'AdaptiveReportsStatusLabel'

    # Generate button -- runs the report chain on a background STA runspace
    if ($btnGenerate) {
        $btnGenerate.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiAdaptiveReport -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Open Output Folder button (mirrors the Delta Cert 'Open Output Folder' handler)
    if ($btnOpenFolder) {
        $btnOpenFolder.Add_Click({
            $outputPath = & $module { Resolve-AdaptiveOutputPath }
            if (-not (Test-Path $outputPath)) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$outputPath`""
        }.GetNewClosure())
    }

    # Open Report button -- opens the most recently generated report, if any
    if ($btnOpenReport) {
        $btnOpenReport.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiAdaptiveOpenReport -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Initial status -- no auto-run on init (read happens only on Generate)
    if ($null -ne $statusLabel) {
        $statusLabel.Text = 'Ready. Choose anchor / components / baselines, then Generate.'
    }
}

function Invoke-GuiAdaptiveOpenReport {
    <#
    .SYNOPSIS
        Opens the most recently generated adaptive report in the default browser.
    #>
    [CmdletBinding()]
    param($TabContent)

    $path = $script:LastAdaptiveReportPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        Set-StatusMessage -Message 'No report generated yet.' -IsError
        return
    }
    Wait-SPReportFileReady -Path $path | Out-Null
    Start-Process $path
}

function Invoke-GuiAdaptiveReport {
    <#
    .SYNOPSIS
        Generates an adaptive report in a background runspace from the GUI.
    .DESCRIPTION
        Gathers UI selections on the UI thread (no API/IO here), then runs the same
        chain the Invoke-SPAdaptiveReport.ps1 CLI uses (Get-SPAuditCampaigns ->
        build audits -> Build-SPRCDataset -> New-ComposableReport / Export-SPRC*)
        on a background STA runspace. Status is marshalled back via the dispatcher;
        on success the primary HTML is opened with Wait-SPReportFileReady +
        Start-Process. No API/IO runs on the UI thread.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsAdaptiveRunning) {
        Set-StatusMessage -Message 'An adaptive report run is already in progress.' -IsError
        return
    }

    # --- UI-thread gathering (no API/IO) ------------------------------------
    $anchorCombo   = Find-Control -Parent $TabContent -Name 'AdaptiveReportsAnchorCombo'
    $themeCombo    = Find-Control -Parent $TabContent -Name 'AdaptiveReportsThemeCombo'
    $daysBackBox   = Find-Control -Parent $TabContent -Name 'AdaptiveReportsDaysBackBox'
    $progressBar   = Find-Control -Parent $TabContent -Name 'AdaptiveReportsProgressBar'
    $statusLabel   = Find-Control -Parent $TabContent -Name 'AdaptiveReportsStatusLabel'
    $btnGenerate   = Find-Control -Parent $TabContent -Name 'BtnArGenerate'

    $anchor = 'Entitlement'
    if ($null -ne $anchorCombo -and $null -ne $anchorCombo.SelectedItem -and
        $null -ne $anchorCombo.SelectedItem.Content) {
        $anchor = [string]$anchorCombo.SelectedItem.Content
    }

    $theme = 'light'
    if ($null -ne $themeCombo -and $null -ne $themeCombo.SelectedItem -and
        $null -ne $themeCombo.SelectedItem.Content) {
        $theme = [string]$themeCombo.SelectedItem.Content
    }

    $daysBack = 90
    if ($null -ne $daysBackBox -and -not [string]::IsNullOrWhiteSpace($daysBackBox.Text)) {
        [int]::TryParse($daysBackBox.Text.Trim(), [ref]$daysBack) | Out-Null
    }

    # Read the Status checkboxes (new controls -- fall back to COMPLETED+ACTIVE if absent)
    $statusList = New-Object System.Collections.Generic.List[string]
    $statusMap  = [ordered]@{
        'ChkArStatusCompleted'  = 'COMPLETED'
        'ChkArStatusActive'     = 'ACTIVE'
        'ChkArStatusStaged'     = 'STAGED'
        'ChkArStatusCompleting' = 'COMPLETING'
    }
    foreach ($ctrlName in $statusMap.Keys) {
        $chkCtrl = Find-Control -Parent $TabContent -Name $ctrlName
        if ($null -eq $chkCtrl -or $chkCtrl.IsChecked -eq $true) {
            # If the control is missing (pre-existing XAML without the new controls)
            # fall back to including the status by default.
            $statusList.Add($statusMap[$ctrlName])
        }
    }
    if ($statusList.Count -eq 0) {
        $statusList.AddRange(@('COMPLETED', 'ACTIVE'))
    }
    $statusArr = $statusList.ToArray()

    # Optional campaign name filter
    $campaignNameContains = ''
    $nameBox = Find-Control -Parent $TabContent -Name 'TxtArCampaignNameContains'
    if ($null -ne $nameBox -and -not [string]::IsNullOrWhiteSpace($nameBox.Text)) {
        $campaignNameContains = $nameBox.Text.Trim()
    }

    # Map component checkboxes to the CLI keys
    $componentMap = [ordered]@{
        'ChkArCompKpiCards'   = 'kpi-cards'
        'ChkArCompHeatmap'    = 'heatmap'
        'ChkArCompTree'       = 'tree'
        'ChkArCompTopN'       = 'top-n'
        'ChkArCompGroupTable' = 'group-table'
    }
    $components = New-Object System.Collections.Generic.List[string]
    foreach ($name in $componentMap.Keys) {
        $chk = Find-Control -Parent $TabContent -Name $name
        if ($null -ne $chk -and $chk.IsChecked -eq $true) { $components.Add($componentMap[$name]) }
    }

    # Map baseline checkboxes to the CLI keys
    $baselineMap = [ordered]@{
        'ChkArBaseInventory'   = 'inventory'
        'ChkArBasePrivileged'  = 'privileged'
        'ChkArBaseOrphaned'    = 'orphaned'
        'ChkArBaseExecSummary' = 'exec-summary'
        'ChkArBaseRoster'      = 'roster'
        'ChkArBaseAccessCert'  = 'access-cert'
        'ChkArBaseSod'         = 'sod'
    }
    $baselines = New-Object System.Collections.Generic.List[string]
    foreach ($name in $baselineMap.Keys) {
        $chk = Find-Control -Parent $TabContent -Name $name
        if ($null -ne $chk -and $chk.IsChecked -eq $true) { $baselines.Add($baselineMap[$name]) }
    }

    # Map enriched-report checkboxes to the enriched-exporter keys (T-05)
    $enrichedMap = [ordered]@{
        'ChkArEnrichedPrivilegedAttestation' = 'privileged-attestation'
        'ChkArEnrichedAccountability'        = 'accountability'
        'ChkArEnrichedTrend'                 = 'trend'
        'ChkArEnrichedDisconnected'          = 'disconnected'
    }
    $enriched = New-Object System.Collections.Generic.List[string]
    foreach ($name in $enrichedMap.Keys) {
        $chk = Find-Control -Parent $TabContent -Name $name
        if ($null -ne $chk -and $chk.IsChecked -eq $true) { $enriched.Add($enrichedMap[$name]) }
    }

    if ($components.Count -eq 0 -and $baselines.Count -eq 0 -and $enriched.Count -eq 0) {
        Set-StatusMessage -Message 'Select at least one component, baseline or enriched report.' -IsError
        return
    }

    $componentArr = $components.ToArray()
    $baselineArr  = $baselines.ToArray()
    $enrichedArr  = $enriched.ToArray()

    $outputPath = Resolve-AdaptiveOutputPath

    $script:IsAdaptiveRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Generating adaptive report. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Generating adaptive report...' }
    if ($null -ne $progressBar) {
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility      = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $btnGenerate) { $btnGenerate.IsEnabled = $false }

    # --- Background STA runspace --------------------------------------------
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('OutputPath',           $outputPath)
    $runspace.SessionStateProxy.SetVariable('Anchor',               $anchor)
    $runspace.SessionStateProxy.SetVariable('Theme',                $theme)
    $runspace.SessionStateProxy.SetVariable('DaysBack',             $daysBack)
    $runspace.SessionStateProxy.SetVariable('StatusArr',            $statusArr)
    $runspace.SessionStateProxy.SetVariable('CampaignNameContains', $campaignNameContains)
    $runspace.SessionStateProxy.SetVariable('Components',           $componentArr)
    $runspace.SessionStateProxy.SetVariable('Baselines',            $baselineArr)
    $runspace.SessionStateProxy.SetVariable('Enriched',             $enrichedArr)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # Same module set the Invoke-SPAdaptiveReport.ps1 CLI imports, plus SP.Gui
        # for parity with the Delta block (Set-StatusMessage availability).
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1', 'SP.Audit\SP.Audit.psd1',
                'SP.DeltaCert\SP.DeltaCert.psd1',
                'SP.ReportComponents\SP.ReportComponents.psd1',
                'SP.AdaptiveReports\SP.AdaptiveReports.psd1',
                'SP.DisconnectedApps\SP.DisconnectedApps.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $result = @{ Success = $false; Data = @{ Generated = @(); Primary = $null }; Error = $null }

        try {
            if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

            # --- Pull campaigns + build audits ---
            # Use the Status and CampaignNameContains values the user set on the UI thread.
            $campArgs = @{
                Status        = $StatusArr
                DaysBack      = $DaysBack
                CorrelationID = $CorrelationID
            }
            if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
                $campArgs['CampaignNameContains'] = $CampaignNameContains
            }
            $campaigns = @()
            $cr = Get-SPAuditCampaigns @campArgs
            if ($cr.Success -and $null -ne $cr.Data) { $campaigns = @($cr.Data) }
            if ($campaigns.Count -eq 0) {
                $filterDesc = "Status: $($StatusArr -join ', ') | Last $DaysBack days"
                if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
                    $filterDesc += " | Name contains: '$CampaignNameContains'"
                }
                throw "No campaigns found ($filterDesc). Widen the Days Back window, check the Status filter, or clear the name filter."
            }

            $audits = New-Object System.Collections.Generic.List[hashtable]
            foreach ($camp in $campaigns) {
                $wrapped = New-Object System.Collections.Generic.List[object]
                $certR = Get-SPAuditCertifications -CampaignId $camp.id -CorrelationID $CorrelationID
                foreach ($cert in @(if ($certR.Success) { $certR.Data } else { @() })) {
                    $itemR = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $CorrelationID
                    foreach ($item in @(if ($itemR.Success) { $itemR.Data } else { @() })) {
                        $wrapped.Add(@{ Item = $item; CertificationId = [string]$cert.id; CertificationName = [string]$cert.name; CampaignName = [string]$camp.name })
                    }
                }
                $dg = Group-SPAuditDecisions -Items $wrapped.ToArray() -CampaignMetadata @{ StartDate = [string]$camp.created; DueDate = ''; CompletionDate = '' }
                $audits.Add(@{ CampaignName = [string]$camp.name; CampaignId = [string]$camp.id; Decisions = $dg })
            }

            # --- Adapt to the RC GroupResults shape ---
            $ds = Build-SPRCDataset -CampaignAudits $audits.ToArray() -Anchor $Anchor -CorrelationID $CorrelationID
            if (-not $ds.Success) { throw "adapter failed: $($ds.Error)" }
            $gr = @($ds.Data.GroupResults)
            if ($gr.Count -eq 0) { throw 'No groups produced from the window -- nothing to render.' }

            $stamp     = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $generated = New-Object System.Collections.Generic.List[string]
            $composableFile = $null

            # Composable report
            if (@($Components).Count -gt 0) {
                $ctx     = New-RCContext -GroupResults $gr -StaleResults $ds.Data.StaleResults -Theme $Theme
                $outFile = Join-Path $OutputPath "adaptive-$Anchor-$stamp.html"
                New-ComposableReport -Components $Components -Context $ctx -Title "Adaptive $Anchor Report" -Theme $Theme -OutputPath $outFile | Out-Null
                $generated.Add($outFile)
                $composableFile = $outFile
            }

            # Baseline reports (same dispatch map the CLI uses)
            $baselineFnMap = [ordered]@{
                'inventory'    = 'Export-GroupInventoryCatalogReport'
                'privileged'   = 'Export-PrivilegedGroupReviewReport'
                'orphaned'     = 'Export-OrphanedDisabledMembersReport'
                'exec-summary' = 'Export-GovernanceExecutiveSummaryReport'
                'roster'       = 'Export-MembershipSnapshotRosterReport'
                'access-cert'  = 'Export-AccessCertificationAttestationReport'
                'sod'          = 'Export-SodToxicComembershipReport'
            }
            foreach ($key in @($Baselines)) {
                $fn = $baselineFnMap[$key]
                if (-not $fn) { continue }
                $outFile = Join-Path $OutputPath "$key-$stamp.html"
                & $fn -GroupResults $gr -OutputPath $outFile -Theme $Theme | Out-Null
                $generated.Add($outFile)
            }

            # Enriched reports (T-05). Their exporter inputs differ from the
            # baseline GroupResults shape and may not be derivable from the
            # in-runspace audits/gr/ds chain, so each branch is a SOFT-SKIP on
            # failure (status note appended) rather than a crash. The headless
            # additive gate only requires that the controls/map/wiring exist.
            $enrichedNotes = New-Object System.Collections.Generic.List[string]
            foreach ($key in @($Enriched)) {
                try {
                    switch ($key) {
                        'privileged-attestation' {
                            # Privileged-attestation sections live in Export-SPAuditHtml,
                            # which consumes the CampaignAudits hashtable array built above.
                            $paths = Export-SPAuditHtml -CampaignAudits $audits.ToArray() -OutputPath $OutputPath -CorrelationID $CorrelationID
                            foreach ($p in @($paths)) { if ($p) { $generated.Add([string]$p) } }
                        }
                        'accountability' {
                            # Reviewer-accountability sections also render via Export-SPAuditHtml.
                            $paths = Export-SPAuditHtml -CampaignAudits $audits.ToArray() -OutputPath $OutputPath -CorrelationID $CorrelationID
                            foreach ($p in @($paths)) { if ($p) { $generated.Add([string]$p) } }
                        }
                        'trend' {
                            # Campaign-trend takes TrendData from Measure-SPCampaignTrends, not GroupResults.
                            $metrics = @($audits | ForEach-Object {
                                @{ CampaignName = [string]$_.CampaignName; CampaignId = [string]$_.CampaignId }
                            })
                            $trend = Measure-SPCampaignTrends -CampaignMetrics $metrics
                            $trendData = if ($trend -is [hashtable] -and $trend.ContainsKey('Data')) { $trend.Data } else { $trend }
                            $outFile = Export-SPCampaignTrendHtml -TrendData $trendData -OutputPath $OutputPath -CorrelationID $CorrelationID
                            if ($outFile) { $generated.Add([string]$outFile) }
                        }
                        'disconnected' {
                            # The disconnected-app report needs CSV/delta inputs that are not
                            # part of the campaign gr/ds chain -- soft-skip in the GUI runspace.
                            throw 'disconnected-app report requires CSV/delta inputs not available in the adaptive runspace'
                        }
                        default { throw "unknown enriched key '$key'" }
                    }
                }
                catch {
                    $enrichedNotes.Add("$key skipped: $($_.Exception.Message)")
                }
            }

            if ($generated.Count -eq 0) { throw 'No reports were produced.' }

            $primary = if ($composableFile) { $composableFile } else { $generated[0] }
            $result.Success      = $true
            $result.Data.Generated = $generated.ToArray()
            $result.Data.Primary = $primary
        }
        catch {
            $result.Success = $false
            $result.Error   = $_.Exception.Message
        }

        # Marshal a status summary back to the UI thread
        $dispatcher     = $MainWindow.Dispatcher
        $capturedResult = $result
        $capturedLabel  = $StatusLabel
        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedLabel) {
                if ($capturedResult.Success) {
                    $capturedLabel.Text = "Generated $(@($capturedResult.Data.Generated).Count) report(s)."
                } else {
                    $capturedLabel.Text = "Adaptive report failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $result
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    # --- Completion poll (mirrors Invoke-GuiDeltaReport) ---------------------
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedBtn      = $btnGenerate
    $capturedProgress = $progressBar
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $btn, $progress)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $finalResult = $null
                try {
                    $finalResult = $ps.EndInvoke($async)
                } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Adaptive report failed: $errMsg" -IsError
                } else {
                    $opened = $false
                    if ($null -ne $finalResult -and $finalResult.Count -gt 0) {
                        $result = $finalResult[0]
                        if ($result.Success -and $null -ne $result.Data -and
                            -not [string]::IsNullOrWhiteSpace($result.Data.Primary) -and
                            (Test-Path $result.Data.Primary)) {
                            # Let the runspace-written file fully flush + unlock
                            # before the browser opens it.
                            Wait-SPReportFileReady -Path $result.Data.Primary | Out-Null
                            Start-Process $result.Data.Primary
                            $script:LastAdaptiveReportPath = $result.Data.Primary
                            $opened = $true
                        }
                    }
                    if ($opened) {
                        Set-StatusMessage -Message 'Adaptive report generated successfully.'
                    } else {
                        $failMsg = if ($null -ne $finalResult -and $finalResult.Count -gt 0 -and $finalResult[0].Error) { $finalResult[0].Error } else { 'no report produced' }
                        Set-StatusMessage -Message "Adaptive report failed: $failMsg" -IsError
                    }
                }

                if ($null -ne $btn) { $btn.IsEnabled = $true }
                if ($null -ne $progress) {
                    $progress.IsIndeterminate = $false
                    $progress.Visibility      = [System.Windows.Visibility]::Collapsed
                }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsAdaptiveRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedBtn $capturedProgress
    }.GetNewClosure())

    $timer.Start()
}

#endregion

#region Governance Tab

function Initialize-GovernanceTab {
    <#
    .SYNOPSIS
        Wires up the Governance tab controls and event handlers.
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    $btnHealthCheck   = Find-Control -Parent $TabContent -Name 'BtnRunHealthCheck'
    $btnGovReport     = Find-Control -Parent $TabContent -Name 'BtnGenerateGovReport'
    $btnCampaignDiff  = Find-Control -Parent $TabContent -Name 'BtnCampaignDiff'
    $btnCertTracker   = Find-Control -Parent $TabContent -Name 'BtnCertTracker'
    $btnDailyEvidence = Find-Control -Parent $TabContent -Name 'BtnDailyEvidence'
    $btnExportData    = Find-Control -Parent $TabContent -Name 'BtnExportDashboardData'
    $btnOpenFolder    = Find-Control -Parent $TabContent -Name 'BtnOpenGovFolder'
    $btnRefresh       = Find-Control -Parent $TabContent -Name 'BtnRefreshGovReports'
    $govReportList    = Find-Control -Parent $TabContent -Name 'GovReportList'
    $btnEntitlementHist   = Find-Control -Parent $TabContent -Name 'BtnEntitlementHistory'
    $btnCacheValidate     = Find-Control -Parent $TabContent -Name 'BtnCacheValidate'
    $btnIscRecon          = Find-Control -Parent $TabContent -Name 'BtnIscReconciliation'

    if ($btnHealthCheck) {
        $btnHealthCheck.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiHealthCheck -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnGovReport) {
        $btnGovReport.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiGovernanceReport -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnCampaignDiff) {
        $btnCampaignDiff.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiCampaignDiff -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnCertTracker) {
        $btnCertTracker.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiCertTracker -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnDailyEvidence) {
        $btnDailyEvidence.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiDailyEvidence -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnExportData) {
        $btnExportData.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiExportDashboardData -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnOpenFolder) {
        $btnOpenFolder.Add_Click({
            $outputPath = & $module { Resolve-GovernanceOutputPath }
            if (-not (Test-Path $outputPath)) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$outputPath`""
        }.GetNewClosure())
    }

    if ($btnEntitlementHist) {
        $btnEntitlementHist.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiEntitlementHistory -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnCacheValidate) {
        $btnCacheValidate.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiCacheValidate -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnIscRecon) {
        $btnIscRecon.Add_Click({
            & $module {
                param($tc)
                Invoke-GuiIscReconciliation -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            & $module {
                param($tc)
                Load-GovernanceReports -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # Double-click on a report list item opens the file
    if ($govReportList) {
        $govReportList.Add_MouseDoubleClick({
            & $module {
                param($lb)
                $selected = $lb.SelectedItem
                if ($null -ne $selected -and $null -ne $selected.Tag -and (Test-Path $selected.Tag)) {
                    try {
                        Write-SPLog -Message ("Opening governance report: {0}" -f $selected.Tag) `
                            -Severity INFO -Component 'SP.Gui' -Action 'OpenGovReport'
                    } catch { }
                    Start-Process $selected.Tag
                }
            } $govReportList
        }.GetNewClosure())
    }

    # Distribution buttons
    $btnDistPreview  = Find-Control -Parent $TabContent -Name 'BtnDistributionPreview'
    $btnDistGenerate = Find-Control -Parent $TabContent -Name 'BtnDistributionGenerate'
    $btnDistSend     = Find-Control -Parent $TabContent -Name 'BtnDistributionSend'

    if ($btnDistPreview) {
        $btnDistPreview.Add_Click({
            & $module { param($tc) Invoke-GuiReportDistribution -TabContent $tc -Mode Preview } $TabContent
        }.GetNewClosure())
    }
    if ($btnDistGenerate) {
        $btnDistGenerate.Add_Click({
            & $module { param($tc) Invoke-GuiReportDistribution -TabContent $tc -Mode Generate } $TabContent
        }.GetNewClosure())
    }
    if ($btnDistSend) {
        $btnDistSend.Add_Click({
            & $module { param($tc) Invoke-GuiReportDistribution -TabContent $tc -Mode Send } $TabContent
        }.GetNewClosure())
    }

    # Set initial status text
    $statusLabel = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    if ($null -ne $statusLabel) {
        $statusLabel.Text = 'Ready. Click Run Health Check to populate badges.'
    }

    # Auto-trigger health check on tab init when the user has enabled the
    # HealthCheckOnStartup setting (Governance section in config).
    $autoRun = $false
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.Governance -and
            $cfg.Governance.PSObject.Properties.Name -contains 'HealthCheckOnStartup' -and
            $cfg.Governance.HealthCheckOnStartup -eq $true) {
            $autoRun = $true
        }
    } catch { }
    if ($autoRun) {
        Invoke-GuiHealthCheck -TabContent $TabContent
    }

    # Hierarchical Leadership Report buttons
    $btnHierPreview  = Find-Control -Parent $TabContent -Name 'BtnHierPreview'
    $btnHierGenerate = Find-Control -Parent $TabContent -Name 'BtnHierGenerate'

    if ($btnHierPreview) {
        $btnHierPreview.Add_Click({
            & $module { param($tc) Invoke-GuiHierarchicalReport -TabContent $tc -PreviewOnly } $TabContent
        }.GetNewClosure())
    }
    if ($btnHierGenerate) {
        $btnHierGenerate.Add_Click({
            & $module { param($tc) Invoke-GuiHierarchicalReport -TabContent $tc } $TabContent
        }.GetNewClosure())
    }

    Load-GovernanceReports -TabContent $TabContent
}

function Invoke-GuiHierarchicalReport {
    <#
    .SYNOPSIS
        Runs the hierarchical leadership drill-down report in a background STA runspace.
        Reads DaysBack, CampaignNameContains, and MinReportLevel from the Governance tab controls.
    #>
    [CmdletBinding()]
    param(
        $TabContent,
        [switch]$PreviewOnly
    )

    $hierLabel  = Find-Control -Parent $TabContent -Name 'HierStatusLabel'
    $txtDays    = Find-Control -Parent $TabContent -Name 'TxtHierDaysBack'
    $txtFilter  = Find-Control -Parent $TabContent -Name 'TxtHierCampaignContains'
    $cboLevel   = Find-Control -Parent $TabContent -Name 'CboHierMinLevel'

    # Read control values
    $daysBack  = 30
    if ($null -ne $txtDays)   { [int]::TryParse([string]$txtDays.Text, [ref]$daysBack) | Out-Null }
    $campaignFilter = if ($null -ne $txtFilter) { [string]$txtFilter.Text } else { '' }

    $minLevel = 1
    if ($null -ne $cboLevel -and $null -ne $cboLevel.SelectedItem) {
        $selTag = $cboLevel.SelectedItem.Tag
        if ($null -ne $selTag) { [int]::TryParse([string]$selTag, [ref]$minLevel) | Out-Null }
    }

    $levelLabel = switch ($minLevel) {
        0 { 'All Certifiers' }
        1 { 'Directors+' }
        2 { 'VPs+' }
        default { "Level $minLevel+" }
    }

    if ($PreviewOnly) {
        # Quick preview: just count campaigns without generating files
        if ($null -ne $hierLabel) { $hierLabel.Text = "Fetching campaigns (DaysBack=$daysBack)..." }
        $campParams = @{ DaysBack=$daysBack; Status=@('COMPLETED','ACTIVE') }
        if (-not [string]::IsNullOrWhiteSpace($campaignFilter)) {
            $campParams['CampaignNameContains'] = $campaignFilter
        }
        try {
            $res = Get-SPAuditCampaigns @campParams
            $cnt = if ($res.Success) { @($res.Data).Count } else { 0 }
            $msg = "Preview: $cnt campaign(s) in last $daysBack day(s)"
            if (-not [string]::IsNullOrWhiteSpace($campaignFilter)) { $msg += " matching '$campaignFilter'" }
            $msg += ". Click 'Generate' to produce $levelLabel reports."
            if ($null -ne $hierLabel) { $hierLabel.Text = $msg }
        }
        catch {
            if ($null -ne $hierLabel) { $hierLabel.Text = "Preview failed: $($_.Exception.Message)" }
        }
        return
    }

    # Full generation — run in background STA runspace
    if ($null -ne $hierLabel) { $hierLabel.Text = "Generating $levelLabel reports (DaysBack=$daysBack)..." }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',      $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',       $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('HierLabel',        $hierLabel)
    $runspace.SessionStateProxy.SetVariable('DaysBack',         $daysBack)
    $runspace.SessionStateProxy.SetVariable('CampaignFilter',   $campaignFilter)
    $runspace.SessionStateProxy.SetVariable('MinLevel',         $minLevel)
    $runspace.SessionStateProxy.SetVariable('LevelLabel',       $levelLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $psInstance.AddScript({
        foreach ($rel in @(
            'Modules\SP.Core\SP.Core.psd1',
            'Modules\SP.Api\SP.Api.psd1',
            'Modules\SP.Audit\SP.Audit.psd1',
            'Modules\SP.DeltaCert\SP.DeltaCert.psd1',
            'Modules\SP.Gui\SP.Gui.psd1'
        )) {
            $modPath = Join-Path $ToolkitRoot $rel
            if (Test-Path $modPath) {
                Import-Module $modPath -Force -DisableNameChecking -ErrorAction SilentlyContinue
            }
        }

        $bridgeParams = @{
            DaysBack       = $DaysBack
            MinReportLevel = $MinLevel
        }
        if (-not [string]::IsNullOrWhiteSpace($CampaignFilter)) {
            $bridgeParams['CampaignNameContains'] = $CampaignFilter
        }

        $result = Invoke-SPGuiHierarchicalReport @bridgeParams

        $msg = if ($result.Success) {
            $d = $result.Data
            if ($d.ReportsGenerated -gt 0) {
                "$($d.ReportsGenerated) $LevelLabel report(s) generated - $($d.CampaignCount) campaign(s), $($d.OrgNodes) org nodes"
            }
            else {
                "No reports generated. $($d.Message)"
            }
        }
        else {
            "Error: $($result.Error)"
        }

        $MainWindow.Dispatcher.Invoke([Action]{
            if ($null -ne $HierLabel) {
                $HierLabel.Text = $msg
            }
        })
    }) | Out-Null

    $psInstance.BeginInvoke() | Out-Null
}

function Invoke-GuiReportDistribution {
    <#
    .SYNOPSIS
        Shows the ReportDistributionDialog then runs report distribution in a background
        runspace. Mode: Preview (no files), Generate (files, no email), Send (files + email).
    #>
    [CmdletBinding()]
    param(
        $TabContent,
        [ValidateSet('Preview','Generate','Send')]
        [string]$Mode = 'Preview'
    )

    $distLabel = Find-Control -Parent $TabContent -Name 'GovDistributionStatusLabel'

    # Open config dialog
    $_govDays = 7
    try {
        $_c = Get-SPConfig
        if ($_c.Audit.PSObject.Properties.Name -contains 'DefaultDaysBack' -and [int]$_c.Audit.DefaultDaysBack -gt 0) {
            $_govDays = [int]$_c.Audit.DefaultDaysBack
        }
    } catch { }

    $dialogXaml = Get-XamlPath -FileName 'ReportDistributionDialog.xaml'
    if (-not (Test-Path $dialogXaml)) {
        if ($null -ne $distLabel) { $distLabel.Text = 'ReportDistributionDialog.xaml not found in Gui\.' }
        return
    }

    # Pre-select the radio button matching the clicked button
    $modeDefault = @{ RbDistPreview=$false; RbDistGenerate=$false; RbDistSend=$false }
    switch ($Mode) {
        'Preview'  { $modeDefault['RbDistPreview']  = $true }
        'Generate' { $modeDefault['RbDistGenerate'] = $true }
        'Send'     { $modeDefault['RbDistSend']     = $true }
    }

    $dialogResult = Show-SPGuiDialog `
        -XamlPath     $dialogXaml `
        -ControlNames @('TxtDistCampaignName','CboDistStatus','TxtDistDaysBack',
                        'TxtDistDepth','TxtDistBands',
                        'RbDistPreview','RbDistGenerate','RbDistSend') `
        -Defaults     @{
            CboDistStatus   = 'COMPLETED'
            TxtDistDaysBack = [string]$_govDays
            TxtDistDepth    = '4'
        } `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $dialogResult) { return }

    # Parse dialog values
    $campaignName = [string]$dialogResult['TxtDistCampaignName']
    $status       = [string]$dialogResult['CboDistStatus']
    if ($status -eq '(All)') { $status = $null }
    $daysBack   = 7;  [int]::TryParse([string]$dialogResult['TxtDistDaysBack'], [ref]$daysBack) | Out-Null
    $depth      = 4;  [int]::TryParse([string]$dialogResult['TxtDistDepth'],    [ref]$depth)    | Out-Null
    $bandsRaw   = ([string]$dialogResult['TxtDistBands']).Trim()
    $bands      = if ([string]::IsNullOrWhiteSpace($bandsRaw)) { @() } else { @($bandsRaw -split ',' | ForEach-Object { $_.Trim() }) }

    $previewOnly  = [bool]$dialogResult['RbDistPreview']
    $sendReports  = [bool]$dialogResult['RbDistSend']

    $modeLabel = if ($previewOnly) { 'Previewing' } elseif ($sendReports) { 'Generating + Sending' } else { 'Generating' }
    if ($null -ne $distLabel) { $distLabel.Text = "$modeLabel reports (DaysBack=$daysBack)..." }

    # Run in background runspace
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'; $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',    $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',     $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('DistLabel',      $distLabel)
    $runspace.SessionStateProxy.SetVariable('CampaignName',   $campaignName)
    $runspace.SessionStateProxy.SetVariable('Status',         $status)
    $runspace.SessionStateProxy.SetVariable('DaysBack',       $daysBack)
    $runspace.SessionStateProxy.SetVariable('Depth',          $depth)
    $runspace.SessionStateProxy.SetVariable('Bands',          $bands)
    $runspace.SessionStateProxy.SetVariable('PreviewOnly',    $previewOnly)
    $runspace.SessionStateProxy.SetVariable('SendReports',    $sendReports)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $psInstance.AddScript({
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1', 'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1', 'SP.DeltaCert\SP.DeltaCert.psd1',
                'SP.DisconnectedApps\SP.DisconnectedApps.psd1',
                'SP.ReportComponents\SP.ReportComponents.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $params = @{
            Status            = if ($Status) { @($Status) } else { @('COMPLETED','ACTIVE') }
            DaysBack          = $DaysBack
            LeadershipDepth   = $Depth
            PreviewOnly       = $PreviewOnly
            SendReports       = $SendReports
            CorrelationID     = [guid]::NewGuid().ToString()
        }
        if (-not [string]::IsNullOrWhiteSpace($CampaignName)) { $params['CampaignName'] = $CampaignName }
        if (@($Bands).Count -gt 0) { $params['TargetBands'] = $Bands }

        $result = Invoke-SPGuiReportDistribution @params

        $dispatcher = $MainWindow.Dispatcher
        $captured   = $result
        $captLbl    = $DistLabel
        $dispatcher.Invoke([System.Action]{
            if ($null -ne $captLbl) {
                if ($null -ne $captured -and $captured.Success) {
                    $captLbl.Text = if ($captured.Data.PreviewOnly) {
                        "Preview: $($captured.Data.RecipientCount) leader(s) would receive reports."
                    } else {
                        "Done: $($captured.Data.ReportsGenerated) report(s) written$(if ($captured.Data.EmailsSent -gt 0){", $($captured.Data.EmailsSent) sent"}else{''})."
                    }
                } elseif ($null -ne $captured) {
                    $captLbl.Text = "Failed: $($captured.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)
    }) | Out-Null

    $psInstance.BeginInvoke() | Out-Null
}

function Invoke-GuiHealthCheck {
    <#
    .SYNOPSIS
        Runs governance health check in a background runspace and updates
        the six health badges and three metric cards on completion.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $progressBar    = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct    = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $statusLabel    = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $btnHealthCheck = Find-Control -Parent $TabContent -Name 'BtnRunHealthCheck'

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Starting governance health check. CorrelationID: $correlationID"

    if ($null -ne $statusLabel)    { $statusLabel.Text = 'Running health check...' }
    if ($null -ne $progressBar)    {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct)    { $progressPct.Text = '0%' }
    if ($null -ne $btnHealthCheck) { $btnHealthCheck.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('GovernanceTabContent', $TabContent)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',          $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',      $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        $coreModule  = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule   = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $auditModule = Join-Path $ToolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'
        $guiModule   = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $auditModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $checkResult = Invoke-SPGuiHealthCheck -CorrelationID $CorrelationID

        $dispatcher           = $MainWindow.Dispatcher
        $capturedResult       = $checkResult
        $capturedTab          = $GovernanceTabContent
        $capturedProgressBar  = $ProgressBar
        $capturedProgressPct  = $ProgressPercent
        $capturedLabel        = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) { $capturedProgressBar.Value = 100 }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }

            if ($null -eq $capturedResult -or -not $capturedResult.Success) {
                $errMsg = if ($null -ne $capturedResult) { $capturedResult.Error } else { 'Unknown error' }
                if ($null -ne $capturedLabel) { $capturedLabel.Text = "Health check failed: $errMsg" }
                return
            }

            $data = $capturedResult.Data
            $conv = [System.Windows.Media.BrushConverter]::new()

            # Badge control name map keyed by check Key
            $badgeMap = @{
                'SourceHealth' = 'GovBadgeSourceHealth'
                'DataQuality'  = 'GovBadgeDataQuality'
                'Policy'       = 'GovBadgePolicy'
                'ConfigDrift'  = 'GovBadgeConfigDrift'
                'Orphans'      = 'GovBadgeOrphans'
                'Coverage'     = 'GovBadgeCoverage'
            }

            foreach ($check in $data.Checks) {
                $ctrlName = $badgeMap[$check.Key]
                if ([string]::IsNullOrWhiteSpace($ctrlName)) { continue }
                $badge = $capturedTab.FindName($ctrlName)
                if ($null -eq $badge) { continue }

                $colorHex = if (-not [string]::IsNullOrWhiteSpace($check.Color)) { $check.Color } else { '#999999' }
                try {
                    $brush = $conv.ConvertFromString($colorHex)
                    $badge.BorderBrush = $brush

                    # StackPanel is the direct child of the Border
                    $sp = $badge.Child
                    if ($null -ne $sp -and $sp.Children.Count -ge 2) {
                        $valBlock = $sp.Children[1]
                        $valBlock.Text       = $check.Grade
                        $valBlock.Foreground = $brush
                        $valBlock.ToolTip    = "$($check.Status): $($check.Detail)"
                    }
                } catch { }
            }

            # Metric card name map keyed by metric Key
            $metricMap = @{
                'Maturity'         = 'GovMetricMaturity'
                'PolicyCompliance' = 'GovMetricPolicyPct'
                'CoverageRate'     = 'GovMetricCoveragePct'
            }

            foreach ($metric in $data.MetricCards) {
                $ctrlName = $metricMap[$metric.Key]
                if ([string]::IsNullOrWhiteSpace($ctrlName)) { continue }
                $card = $capturedTab.FindName($ctrlName)
                if ($null -eq $card) { continue }

                $colorHex = if (-not [string]::IsNullOrWhiteSpace($metric.Color)) { $metric.Color } else { '#5B9BD5' }
                try {
                    $brush = $conv.ConvertFromString($colorHex)
                    $sp = $card.Child
                    if ($null -ne $sp -and $sp.Children.Count -ge 1) {
                        $valBlock = $sp.Children[0]
                        $valBlock.Text       = $metric.Value
                        $valBlock.Foreground = $brush
                    }
                } catch { }
            }

            if ($null -ne $capturedLabel) {
                $capturedLabel.Text = "Health check complete. Overall grade: $($data.OverallGrade)"
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $checkResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnHealthCheck
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Health check failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Governance health check complete.'
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) { $prog.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($null -ne $pct)  { $pct.Text = '' }

                Load-GovernanceReports -TabContent $tab

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiGovernanceReport {
    <#
    .SYNOPSIS
        Shows the GovernanceRunDialog (when available) then runs report generation
        in a background runspace.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    # Read the configured default DaysBack from Audit.DefaultDaysBack so a single
    # config change controls all report windows. Fall back to 7 if not set.
    $_govDefaultDays = 7
    try {
        $_govCfg = Get-SPConfig
        if ($null -ne $_govCfg.Audit -and
            $_govCfg.Audit.PSObject.Properties.Name -contains 'DefaultDaysBack' -and
            [int]$_govCfg.Audit.DefaultDaysBack -gt 0) {
            $_govDefaultDays = [int]$_govCfg.Audit.DefaultDaysBack
        }
    } catch { }
    $_govDefaultDaysStr = [string]$_govDefaultDays

    # Show GovernanceRunDialog.xaml (GU-04) when present; otherwise use safe defaults.
    # If the file exists and the user cancels, $reportParams will be $null -> bail out.
    $reportParams = $null
    $dialogXaml = Get-XamlPath -FileName 'GovernanceRunDialog.xaml'
    if (Test-Path $dialogXaml) {
        $reportParams = Show-SPGuiDialog `
            -XamlPath     $dialogXaml `
            -ControlNames @(
                'ChkIncludeCampaignAudit', 'ChkIncludeLeadershipRollup',
                'ChkIncludePolicyCheck', 'ChkIncludeDataQuality',
                'ChkIncludeDashboardExport', 'CboStatus', 'TxtDaysBack') `
            -Defaults     @{ CboStatus = 'COMPLETED'; TxtDaysBack = $_govDefaultDaysStr }
        if ($null -eq $reportParams) { return }
    }
    else {
        $reportParams = @{
            ChkIncludeCampaignAudit    = $true
            ChkIncludeLeadershipRollup = $false
            ChkIncludePolicyCheck      = $false
            ChkIncludeDataQuality      = $false
            ChkIncludeDashboardExport  = $false
            CboStatus                  = 'COMPLETED'
            TxtDaysBack                = $_govDefaultDaysStr
        }
    }

    $statusLabel = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnGenerate = Find-Control -Parent $TabContent -Name 'BtnGenerateGovReport'

    # Parse dialog values
    $status = if ($reportParams['CboStatus']) { $reportParams['CboStatus'] } else { 'COMPLETED' }
    $daysBack = $_govDefaultDays
    if ($reportParams['TxtDaysBack']) {
        [int]::TryParse([string]$reportParams['TxtDaysBack'], [ref]$daysBack) | Out-Null
    }
    $includeLeadership  = [bool]$reportParams['ChkIncludeLeadershipRollup']
    $includePolicyCheck = [bool]$reportParams['ChkIncludePolicyCheck']
    $includeDataQuality = [bool]$reportParams['ChkIncludeDataQuality']
    $includeDashExport  = [bool]$reportParams['ChkIncludeDashboardExport']

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Generating governance report. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Generating governance report...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '0%' }
    if ($null -ne $btnGenerate) { $btnGenerate.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('ReportStatus',         $status)
    $runspace.SessionStateProxy.SetVariable('DaysBack',             $daysBack)
    $runspace.SessionStateProxy.SetVariable('IncludeLeadership',    $includeLeadership)
    $runspace.SessionStateProxy.SetVariable('IncludePolicyCheck',   $includePolicyCheck)
    $runspace.SessionStateProxy.SetVariable('IncludeDataQuality',   $includeDataQuality)
    $runspace.SessionStateProxy.SetVariable('IncludeDashExport',    $includeDashExport)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',          $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',      $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # Import every module the governance report can call -- missing modules
        # produce "term not recognized" errors (e.g. Get-SPRegisteredApps needs
        # SP.DisconnectedApps; Build-SPOrgTree needs SP.DeltaCert; the RC
        # generators need SP.ReportComponents). Keep in sync with the CLI script
        # Invoke-SPGovernanceReport.ps1 which imports the same set.
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.DeltaCert\SP.DeltaCert.psd1',
                'SP.DisconnectedApps\SP.DisconnectedApps.psd1',
                'SP.ReportComponents\SP.ReportComponents.psd1',
                'SP.AdaptiveReports\SP.AdaptiveReports.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $govReportParams = @{
            Status                  = $ReportStatus
            DaysBack                = $DaysBack
            IncludeLeadershipRollup = $IncludeLeadership
            IncludePolicyCheck      = $IncludePolicyCheck
            IncludeDataQuality      = $IncludeDataQuality
            IncludeDashboardExport  = $IncludeDashExport
            CorrelationID           = $CorrelationID
        }
        $reportResult = Invoke-SPGuiGovernanceReport @govReportParams

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $reportResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPercent
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) { $capturedProgressBar.Value = 100 }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $capturedResult.Success) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "Report generated: $($d.FilesWritten) file(s) in $($d.DurationSeconds)s"
                }
                elseif ($null -ne $capturedResult) {
                    $capturedLabel.Text = "Report generation failed: $($capturedResult.Error)"
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
    $capturedTab      = $TabContent
    $capturedBtn      = $btnGenerate
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Governance report failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Governance report generated.'
                    Load-GovernanceReports -TabContent $tab
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) { $prog.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiExportDashboardData {
    <#
    .SYNOPSIS
        Exports governance dashboard data to CSV (synchronous -- fast operation).
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $btnExport   = Find-Control -Parent $TabContent -Name 'BtnExportDashboardData'

    if ($null -ne $statusLabel) { $statusLabel.Text = 'Exporting dashboard data...' }
    if ($null -ne $btnExport)   { $btnExport.IsEnabled = $false }

    Set-StatusMessage -Message 'Exporting governance dashboard data...'

    $correlationID = [guid]::NewGuid().ToString()

    try {
        $result = Export-SPGuiDashboardData -CorrelationID $correlationID
        if ($result.Success) {
            $msg = "Exported $($result.Data.RowCount) rows to: $($result.Data.CsvPath)"
            if ($null -ne $statusLabel) { $statusLabel.Text = $msg }
            Set-StatusMessage -Message $msg
        }
        else {
            $msg = "Export failed: $($result.Error)"
            if ($null -ne $statusLabel) { $statusLabel.Text = $msg }
            Set-StatusMessage -Message $msg -IsError
        }
    }
    catch {
        $msg = "Export error: $($_.Exception.Message)"
        if ($null -ne $statusLabel) { $statusLabel.Text = $msg }
        Set-StatusMessage -Message $msg -IsError
    }
    finally {
        if ($null -ne $btnExport) { $btnExport.IsEnabled = $true }
    }
}

function Load-GovernanceReports {
    <#
    .SYNOPSIS
        Populates the GovReportList ListBox with recent governance report files.
        Green = HTML reports, Gray = other file types.
    #>
    [CmdletBinding()]
    param($TabContent)

    $listBox = Find-Control -Parent $TabContent -Name 'GovReportList'
    if ($null -eq $listBox) { return }

    $result = Get-SPGuiGovernanceReports

    $listBox.Items.Clear()

    if (-not $result.Success -or $result.Data.Count -eq 0) {
        $item         = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = 'No governance reports found yet.'
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

function Resolve-GovernanceOutputPath {
    <#
    .SYNOPSIS
        Resolves the absolute path to the Governance output directory.
        Reads from config (Audit.OutputPath) if available, falls back to .\Audit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configPath = $null
    try {
        $configParams = @{}
        if ($script:ConfigPath) { $configParams['ConfigPath'] = $script:ConfigPath }
        $config = Get-SPConfig @configParams
        if ($null -ne $config -and
            $config.PSObject.Properties.Name -contains 'Audit' -and
            $null -ne $config.Audit -and
            $config.Audit.PSObject.Properties.Name -contains 'OutputPath' -and
            -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
            $configPath = $config.Audit.OutputPath
        }
    }
    catch { }

    $rawPath = if ($configPath) { $configPath } else { '.\Audit' }

    if (-not [System.IO.Path]::IsPathRooted($rawPath)) {
        $rawPath = Join-Path $script:ToolkitRoot $rawPath
    }

    return [System.IO.Path]::GetFullPath($rawPath)
}

function Invoke-GuiCampaignDiff {
    <#
    .SYNOPSIS
        Runs the day-over-day campaign diff in a background runspace and opens
        the resulting HTML report on completion.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel     = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar     = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct     = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnCampaignDiff = Find-Control -Parent $TabContent -Name 'BtnCampaignDiff'

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running campaign diff. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running campaign diff...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '' }
    if ($null -ne $btnCampaignDiff) { $btnCampaignDiff.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CorrelationID', $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',   $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',    $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',   $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPct',   $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',   $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.DeltaCert\SP.DeltaCert.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $diffResult = Invoke-SPGuiCampaignDiff -CorrelationID $CorrelationID

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $diffResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPct
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) {
                $capturedProgressBar.IsIndeterminate = $false
                $capturedProgressBar.Value = 100
            }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $capturedResult.Success) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "Campaign diff complete ($($d.DurationSeconds)s). Report: $($d.OutputPath)"
                }
                elseif ($null -ne $capturedResult) {
                    $capturedLabel.Text = "Campaign diff failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $diffResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnCampaignDiff
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $reportResult = $null
                try { $reportResult = $ps.EndInvoke($async) | Select-Object -First 1 } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Campaign diff failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Campaign diff complete.'
                    Load-GovernanceReports -TabContent $tab

                    # Open the HTML report if available
                    if ($null -ne $reportResult -and $reportResult.Success -and
                        -not [string]::IsNullOrWhiteSpace($reportResult.Data.OutputPath) -and
                        (Test-Path $reportResult.Data.OutputPath) -and
                        $reportResult.Data.OutputPath -match '\.html$') {
                        # Let the runspace-written file fully flush/unlock before the browser
                        # opens it, else it can render a blank/partial page. (MacBook-validation fix.)
                        Wait-SPReportFileReady -Path $reportResult.Data.OutputPath | Out-Null
                        Start-Process $reportResult.Data.OutputPath
                    }
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiCertTracker {
    <#
    .SYNOPSIS
        Runs the Certification Progress Tracker in a background runspace and
        opens the generated HTML board on completion.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $progressBar    = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct    = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $statusLabel    = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $btnCertTracker = Find-Control -Parent $TabContent -Name 'BtnCertTracker'

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running Cert Tracker. CorrelationID: $correlationID"

    if ($null -ne $statusLabel)    { $statusLabel.Text = 'Running Cert Tracker...' }
    if ($null -ne $progressBar)    {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct)    { $progressPct.Text = '0%' }
    if ($null -ne $btnCertTracker) { $btnCertTracker.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',          $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',      $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $trackerResult = Invoke-SPGuiCertTracker -CorrelationID $CorrelationID

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $trackerResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPercent
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) { $capturedProgressBar.Value = 100 }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }

            if ($null -ne $capturedResult -and $capturedResult.Success) {
                $d = $capturedResult.Data
                if ($null -ne $capturedLabel) {
                    $capturedLabel.Text = "Cert Tracker complete ($($d.DurationSeconds)s). Opening report..."
                }
                # Open the generated HTML report
                if (-not [string]::IsNullOrWhiteSpace($d.HtmlFile) -and (Test-Path $d.HtmlFile)) {
                    Wait-SPReportFileReady -Path $d.HtmlFile | Out-Null
                    Start-Process $d.HtmlFile
                }
            }
            elseif ($null -ne $capturedResult) {
                if ($null -ne $capturedLabel) {
                    $capturedLabel.Text = "Cert Tracker failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $trackerResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnCertTracker
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                try { $ps.EndInvoke($async) } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Cert Tracker failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Cert Tracker complete.'
                    Load-GovernanceReports -TabContent $tab
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiDailyEvidence {
    <#
    .SYNOPSIS
        Runs the Daily Evidence Report V3 in a background runspace and opens the
        generated HTML report on completion.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel    = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar    = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct    = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnEvidence    = Find-Control -Parent $TabContent -Name 'BtnDailyEvidence'

    # Read DaysBack from config (Audit.DefaultDaysBack), fall back to 1
    $daysBack = 1
    try {
        $cfg = Get-SPConfig
        if ($null -ne $cfg.Audit -and
            $cfg.Audit.PSObject.Properties.Name -contains 'DefaultDaysBack' -and
            [int]$cfg.Audit.DefaultDaysBack -gt 0) {
            $daysBack = [int]$cfg.Audit.DefaultDaysBack
        }
    } catch { }

    # Read campaign filter from Governance tab control if present
    $campaignFilter = ''
    $txtFilter = Find-Control -Parent $TabContent -Name 'TxtHierCampaignContains'
    if ($null -ne $txtFilter -and -not [string]::IsNullOrWhiteSpace($txtFilter.Text)) {
        $campaignFilter = [string]$txtFilter.Text
    }

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running Daily Evidence Report. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running Daily Evidence Report...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '0%' }
    if ($null -ne $btnEvidence) { $btnEvidence.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('DaysBack',             $daysBack)
    $runspace.SessionStateProxy.SetVariable('CampaignFilter',       $campaignFilter)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',        $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',          $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',           $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',          $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPercent',      $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',          $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $evidenceParams = @{
            DaysBack      = $DaysBack
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($CampaignFilter)) {
            $evidenceParams['CampaignNameContains'] = $CampaignFilter
        }

        $evidenceResult = Invoke-SPGuiDailyEvidence @evidenceParams

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $evidenceResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPercent
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) { $capturedProgressBar.Value = 100 }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $capturedResult.Success) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "Daily Evidence report generated in $($d.DurationSeconds)s"
                }
                elseif ($null -ne $capturedResult) {
                    $capturedLabel.Text = "Daily Evidence failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $evidenceResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnEvidence
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Daily Evidence report failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Daily Evidence report generated.'
                    Load-GovernanceReports -TabContent $tab

                    # Open the HTML report automatically
                    try {
                        $output = $ps.EndInvoke($async)
                        if ($null -ne $output -and $output.Count -gt 0) {
                            $result = $output[0]
                            if ($null -ne $result -and $result.Success -and
                                -not [string]::IsNullOrWhiteSpace($result.Data.HtmlPath) -and
                                (Test-Path $result.Data.HtmlPath)) {
                                Wait-SPReportFileReady -Path $result.Data.HtmlPath | Out-Null
                                Start-Process $result.Data.HtmlPath
                            }
                        }
                    } catch { }
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

#endregion

#region Entitlement History + Cache Validate Handlers

function Invoke-GuiEntitlementHistory {
    <#
    .SYNOPSIS
        Runs the Entitlement History report in a background runspace and opens
        the generated HTML report on completion.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel   = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar   = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct   = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnHistory    = Find-Control -Parent $TabContent -Name 'BtnEntitlementHistory'

    # Read campaign filter from the Hierarchical controls if present
    $campaignFilter = ''
    $txtFilter = Find-Control -Parent $TabContent -Name 'TxtHierCampaignContains'
    if ($null -ne $txtFilter -and -not [string]::IsNullOrWhiteSpace($txtFilter.Text)) {
        $campaignFilter = [string]$txtFilter.Text
    }

    # Read DaysBack from the Hierarchical controls if present
    $daysBack = 30
    $txtDays = Find-Control -Parent $TabContent -Name 'TxtHierDaysBack'
    if ($null -ne $txtDays) { [int]::TryParse([string]$txtDays.Text, [ref]$daysBack) | Out-Null }

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running Entitlement History. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running Entitlement History...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '' }
    if ($null -ne $btnHistory) { $btnHistory.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CampaignFilter',  $campaignFilter)
    $runspace.SessionStateProxy.SetVariable('DaysBack',        $daysBack)
    $runspace.SessionStateProxy.SetVariable('CorrelationID',   $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',     $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',      $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',     $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPct',     $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',     $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $histParams = @{
            DaysBack      = $DaysBack
            CorrelationID = $CorrelationID
        }
        if (-not [string]::IsNullOrWhiteSpace($CampaignFilter)) {
            $histParams['CampaignNameContains'] = $CampaignFilter
        }

        $histResult = Invoke-SPGuiEntitlementHistory @histParams

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $histResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPct
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) {
                $capturedProgressBar.IsIndeterminate = $false
                $capturedProgressBar.Value = 100
            }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $capturedResult.Success) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "Entitlement History complete ($($d.DurationSeconds)s)"
                }
                elseif ($null -ne $capturedResult) {
                    $capturedLabel.Text = "Entitlement History failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $histResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnHistory
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Entitlement History failed: $errMsg" -IsError
                } else {
                    Set-StatusMessage -Message 'Entitlement History report generated.'
                    Load-GovernanceReports -TabContent $tab

                    # Open the HTML report automatically
                    try {
                        $output = $ps.EndInvoke($async)
                        if ($null -ne $output -and $output.Count -gt 0) {
                            $result = $output[0]
                            if ($null -ne $result -and $result.Success -and
                                -not [string]::IsNullOrWhiteSpace($result.Data.HtmlPath) -and
                                (Test-Path $result.Data.HtmlPath)) {
                                Wait-SPReportFileReady -Path $result.Data.HtmlPath | Out-Null
                                Start-Process $result.Data.HtmlPath
                            }
                        }
                    } catch { }
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiCacheValidate {
    <#
    .SYNOPSIS
        Runs the snapshot/cache validation diagnostic in a background runspace
        and displays the results summary in the Governance status label.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel    = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar    = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct    = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnValidate    = Find-Control -Parent $TabContent -Name 'BtnCacheValidate'

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running Cache Validation. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running cache validation...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '' }
    if ($null -ne $btnValidate) { $btnValidate.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CorrelationID',   $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',     $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',      $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',     $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPct',     $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',     $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Audit\SP.Audit.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $validateResult = Invoke-SPGuiCacheValidate -CorrelationID $CorrelationID

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $validateResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPct
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) {
                $capturedProgressBar.IsIndeterminate = $false
                $capturedProgressBar.Value = 100
            }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $null -ne $capturedResult.Data) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "Cache validation: $($d.Summary) ($($d.DurationSeconds)s)"
                }
                elseif ($null -ne $capturedResult -and $null -ne $capturedResult.Error) {
                    $capturedLabel.Text = "Cache validation failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $validateResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnValidate
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $validateOutput = $null
                try { $validateOutput = $ps.EndInvoke($async) | Select-Object -First 1 } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "Cache validation failed: $errMsg" -IsError
                } else {
                    # Build a status message from the result
                    $msg = 'Cache validation complete.'
                    if ($null -ne $validateOutput -and $null -ne $validateOutput.Data) {
                        $msg = "Cache validation: $($validateOutput.Data.Summary)"
                    }
                    Set-StatusMessage -Message $msg
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-GuiIscReconciliation {
    <#
    .SYNOPSIS
        Runs the ISC Reconciliation export in a background runspace.
        On completion, shows summary in status bar and opens the output directory.
    #>
    [CmdletBinding()]
    param($TabContent)

    if ($script:IsGovernanceRunning) {
        Set-StatusMessage -Message 'A governance operation is already in progress.' -IsError
        return
    }

    $statusLabel   = Find-Control -Parent $TabContent -Name 'GovStatusLabel'
    $progressBar   = Find-Control -Parent $TabContent -Name 'GovProgressBar'
    $progressPct   = Find-Control -Parent $TabContent -Name 'GovProgressPercent'
    $btnIscRecon   = Find-Control -Parent $TabContent -Name 'BtnIscReconciliation'

    $script:IsGovernanceRunning = $true
    $correlationID = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Running ISC Reconciliation. CorrelationID: $correlationID"
    if ($null -ne $statusLabel) { $statusLabel.Text = 'Running ISC Reconciliation export...' }
    if ($null -ne $progressBar) {
        $progressBar.Value      = 0
        $progressBar.Maximum    = 100
        $progressBar.IsIndeterminate = $true
        $progressBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($null -ne $progressPct) { $progressPct.Text = '' }
    if ($null -ne $btnIscRecon) { $btnIscRecon.IsEnabled = $false }

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $runspace.SessionStateProxy.SetVariable('CorrelationID',   $correlationID)
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',     $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',      $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('ProgressBar',     $progressBar)
    $runspace.SessionStateProxy.SetVariable('ProgressPct',     $progressPct)
    $runspace.SessionStateProxy.SetVariable('StatusLabel',     $statusLabel)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        foreach ($rel in @(
                'SP.Core\SP.Core.psd1',
                'SP.Api\SP.Api.psd1',
                'SP.Reconciliation\SP.Reconciliation.psd1',
                'SP.Gui\SP.Gui.psd1')) {
            $mod = Join-Path $ToolkitRoot "Modules\$rel"
            if (Test-Path $mod) { Import-Module $mod -Force -DisableNameChecking -ErrorAction SilentlyContinue }
        }

        $reconResult = Invoke-SPGuiIscReconciliation -CorrelationID $CorrelationID

        $dispatcher          = $MainWindow.Dispatcher
        $capturedResult      = $reconResult
        $capturedProgressBar = $ProgressBar
        $capturedProgressPct = $ProgressPct
        $capturedLabel       = $StatusLabel

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgressBar) {
                $capturedProgressBar.IsIndeterminate = $false
                $capturedProgressBar.Value = 100
            }
            if ($null -ne $capturedProgressPct) { $capturedProgressPct.Text = '100%' }
            if ($null -ne $capturedLabel) {
                if ($null -ne $capturedResult -and $capturedResult.Success) {
                    $d = $capturedResult.Data
                    $capturedLabel.Text = "ISC Reconciliation complete: $($d.FileCount) files, $($d.IdentityCount) identities, $($d.CoveragePct)% coverage ($($d.DurationSeconds)s)"
                }
                elseif ($null -ne $capturedResult -and $null -ne $capturedResult.Error) {
                    $capturedLabel.Text = "ISC Reconciliation failed: $($capturedResult.Error)"
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $reconResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null
    $asyncResult = $psInstance.BeginInvoke()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedBtn      = $btnIscRecon
    $capturedProg     = $progressBar
    $capturedPct      = $progressPct
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $btn, $prog, $pct)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $reconOutput = $null
                try { $reconOutput = $ps.EndInvoke($async) | Select-Object -First 1 } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-StatusMessage -Message "ISC Reconciliation failed: $errMsg" -IsError
                } else {
                    # Build a status message from the result
                    $msg = 'ISC Reconciliation export complete.'
                    if ($null -ne $reconOutput -and $reconOutput.Success -and $null -ne $reconOutput.Data) {
                        $d = $reconOutput.Data
                        $msg = "ISC Reconciliation: $($d.FileCount) files generated, $($d.IdentityCount) identities, $($d.CoveragePct)% join-key coverage"
                    }
                    Set-StatusMessage -Message $msg

                    # Open the output directory (not a single file -- it produces JSON+CSV+SHA256)
                    try {
                        if ($null -ne $reconOutput -and $reconOutput.Success -and
                            -not [string]::IsNullOrWhiteSpace($reconOutput.Data.OutputDir) -and
                            (Test-Path $reconOutput.Data.OutputDir)) {
                            Start-Process 'explorer.exe' -ArgumentList "`"$($reconOutput.Data.OutputDir)`""
                        }
                    } catch { }
                }

                if ($null -ne $btn)  { $btn.IsEnabled = $true }
                if ($null -ne $prog) {
                    $prog.IsIndeterminate = $false
                    $prog.Visibility = [System.Windows.Visibility]::Collapsed
                }
                if ($null -ne $pct)  { $pct.Text = '' }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsGovernanceRunning = $false
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedBtn $capturedProg $capturedPct
    }.GetNewClosure())

    $timer.Start()
}

#endregion

#region SDK Features Tab

function Initialize-SdkTab {
    <#
    .SYNOPSIS
        Wires up the SDK Features tab controls and event handlers.
    .DESCRIPTION
        Structure/wiring only (SDK-10). Captures the module reference, binds each
        sub-tab grid to its module-scoped ObservableCollection, locates every
        control via Find-Control, and attaches every button / checkbox / radio /
        sub-tab handler using the mandatory `& $module { } + .GetNewClosure()`
        idiom (WPF note 2) so private helpers resolve at fire-time.

        No bridge/API calls are made on the UI thread (WPF note 3). Each handler
        routes to a module-private refresh/action helper. In SDK-10 those helpers
        are thin stubs that only set the sub-tab status label to a
        'deferred to SDK-11' message; SDK-11 replaces the stub bodies with the
        background-runspace data loads. SDK-12 adds the Show-SPGuiDialog modals
        and Safety/What-If confirmations.
    .PARAMETER TabContent
        The inlined SDK Features tab content root (Grid 'SdkTabContent').
    #>
    [CmdletBinding()]
    param($TabContent)

    $module = $script:ThisModule

    # --- Bind each grid to its module-scoped ObservableCollection ---------------
    $templateGrid = Find-Control -Parent $TabContent -Name 'SdkTemplateGrid'
    if ($templateGrid)    { $templateGrid.ItemsSource    = $script:SdkTemplateDataSource }
    $certSummaryGrid = Find-Control -Parent $TabContent -Name 'SdkCertSummaryGrid'
    if ($certSummaryGrid) { $certSummaryGrid.ItemsSource = $script:SdkCertSummaryDataSource }
    $approvalGrid = Find-Control -Parent $TabContent -Name 'SdkApprovalGrid'
    if ($approvalGrid)    { $approvalGrid.ItemsSource    = $script:SdkApprovalDataSource }
    $workItemGrid = Find-Control -Parent $TabContent -Name 'SdkWorkItemGrid'
    if ($workItemGrid)    { $workItemGrid.ItemsSource    = $script:SdkWorkItemDataSource }
    $workflowGrid = Find-Control -Parent $TabContent -Name 'SdkWorkflowGrid'
    if ($workflowGrid)    { $workflowGrid.ItemsSource    = $script:SdkWorkflowDataSource }
    $executionGrid = Find-Control -Parent $TabContent -Name 'SdkExecutionGrid'
    if ($executionGrid)   { $executionGrid.ItemsSource   = $script:SdkExecutionDataSource }
    $filterGrid = Find-Control -Parent $TabContent -Name 'SdkFilterGrid'
    if ($filterGrid)      { $filterGrid.ItemsSource      = $script:SdkFilterDataSource }

    # === Sub-tab 1: Templates ==================================================
    $btnRefreshTemplates = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshTemplates'
    if ($btnRefreshTemplates) {
        $btnRefreshTemplates.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkTemplateRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnNewTemplate = Find-Control -Parent $TabContent -Name 'BtnSdkNewTemplate'
    if ($btnNewTemplate) {
        $btnNewTemplate.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkTemplateNew -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnEditSchedule = Find-Control -Parent $TabContent -Name 'BtnSdkEditSchedule'
    if ($btnEditSchedule) {
        $btnEditSchedule.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkTemplateEditSchedule -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnRemoveSchedule = Find-Control -Parent $TabContent -Name 'BtnSdkRemoveSchedule'
    if ($btnRemoveSchedule) {
        $btnRemoveSchedule.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkTemplateRemoveSchedule -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnDeleteTemplate = Find-Control -Parent $TabContent -Name 'BtnSdkDeleteTemplate'
    if ($btnDeleteTemplate) {
        $btnDeleteTemplate.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkTemplateDelete -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab 2: Cert Summaries ============================================
    $btnRefreshSummaries = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshSummaries'
    if ($btnRefreshSummaries) {
        $btnRefreshSummaries.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkCertSummaryRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $cboCertCampaign = Find-Control -Parent $TabContent -Name 'CboSdkCertCampaign'
    if ($cboCertCampaign) {
        $cboCertCampaign.Add_SelectionChanged({
            & $module {
                param($tc)
                Invoke-SdkCertSummaryRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $cboCertification = Find-Control -Parent $TabContent -Name 'CboSdkCertification'
    if ($cboCertification) {
        $cboCertification.Add_SelectionChanged({
            & $module {
                param($tc)
                Invoke-SdkCertSummaryRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $cboAccessType = Find-Control -Parent $TabContent -Name 'CboSdkAccessType'
    if ($cboAccessType) {
        $cboAccessType.Add_SelectionChanged({
            & $module {
                param($tc)
                Invoke-SdkCertSummaryRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab 3: Approvals =================================================
    $rbPending = Find-Control -Parent $TabContent -Name 'RbSdkPending'
    if ($rbPending) {
        $rbPending.Add_Checked({
            & $module {
                param($tc)
                Invoke-SdkApprovalRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $rbCompleted = Find-Control -Parent $TabContent -Name 'RbSdkCompleted'
    if ($rbCompleted) {
        $rbCompleted.Add_Checked({
            & $module {
                param($tc)
                Invoke-SdkApprovalRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnRefreshApprovals = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshApprovals'
    if ($btnRefreshApprovals) {
        $btnRefreshApprovals.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkApprovalRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnApprove = Find-Control -Parent $TabContent -Name 'BtnSdkApprove'
    if ($btnApprove) {
        $btnApprove.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkApprovalApprove -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnDeny = Find-Control -Parent $TabContent -Name 'BtnSdkDeny'
    if ($btnDeny) {
        $btnDeny.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkApprovalDeny -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnForward = Find-Control -Parent $TabContent -Name 'BtnSdkForward'
    if ($btnForward) {
        $btnForward.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkApprovalForward -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab 4: Work Items ================================================
    $btnRefreshWorkItems = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshWorkItems'
    if ($btnRefreshWorkItems) {
        $btnRefreshWorkItems.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkItemRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnCompleteWorkItem = Find-Control -Parent $TabContent -Name 'BtnSdkCompleteWorkItem'
    if ($btnCompleteWorkItem) {
        $btnCompleteWorkItem.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkItemComplete -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnForwardWorkItem = Find-Control -Parent $TabContent -Name 'BtnSdkForwardWorkItem'
    if ($btnForwardWorkItem) {
        $btnForwardWorkItem.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkItemForward -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnBulkApprove = Find-Control -Parent $TabContent -Name 'BtnSdkBulkApprove'
    if ($btnBulkApprove) {
        $btnBulkApprove.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkItemBulkApprove -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $chkShowCompleted = Find-Control -Parent $TabContent -Name 'ChkSdkShowCompleted'
    if ($chkShowCompleted) {
        # Cache reference and keep the shadow $script:SdkWorkItemShowCompleted in
        # sync. The shadow is read by Invoke-SdkWorkItemRefresh instead of
        # .IsChecked, which can lag cross-process COM automation calls.
        $script:SdkWorkItemShowCompletedChk = $chkShowCompleted
        $chkShowCompleted.Add_Checked({
            & $module {
                param($tc)
                $script:SdkWorkItemShowCompleted = $true
                Invoke-SdkWorkItemRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
        $chkShowCompleted.Add_Unchecked({
            & $module {
                param($tc)
                $script:SdkWorkItemShowCompleted = $false
                Invoke-SdkWorkItemRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab 5: Workflows =================================================
    $btnRefreshWorkflows = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshWorkflows'
    if ($btnRefreshWorkflows) {
        $btnRefreshWorkflows.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkflowRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnEnableWorkflow = Find-Control -Parent $TabContent -Name 'BtnSdkEnableWorkflow'
    if ($btnEnableWorkflow) {
        $btnEnableWorkflow.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkflowToggleEnabled -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnTestWorkflow = Find-Control -Parent $TabContent -Name 'BtnSdkTestWorkflow'
    if ($btnTestWorkflow) {
        $btnTestWorkflow.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkflowTest -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnViewExecutions = Find-Control -Parent $TabContent -Name 'BtnSdkViewExecutions'
    if ($btnViewExecutions) {
        $btnViewExecutions.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkflowViewExecutions -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnCreateOOO = Find-Control -Parent $TabContent -Name 'BtnSdkCreateOOO'
    if ($btnCreateOOO) {
        $btnCreateOOO.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkWorkflowCreateOOO -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab 6: Filters ===================================================
    $btnRefreshFilters = Find-Control -Parent $TabContent -Name 'BtnSdkRefreshFilters'
    if ($btnRefreshFilters) {
        $btnRefreshFilters.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkFilterRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnNewFilter = Find-Control -Parent $TabContent -Name 'BtnSdkNewFilter'
    if ($btnNewFilter) {
        $btnNewFilter.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkFilterNew -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnEditFilter = Find-Control -Parent $TabContent -Name 'BtnSdkEditFilter'
    if ($btnEditFilter) {
        $btnEditFilter.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkFilterEdit -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $btnDeleteFilter = Find-Control -Parent $TabContent -Name 'BtnSdkDeleteFilter'
    if ($btnDeleteFilter) {
        $btnDeleteFilter.Add_Click({
            & $module {
                param($tc)
                Invoke-SdkFilterDelete -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    $chkIncludeSystem = Find-Control -Parent $TabContent -Name 'ChkSdkIncludeSystem'
    if ($chkIncludeSystem) {
        $chkIncludeSystem.Add_Checked({
            & $module {
                param($tc)
                Invoke-SdkFilterRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
        $chkIncludeSystem.Add_Unchecked({
            & $module {
                param($tc)
                Invoke-SdkFilterRefresh -TabContent $tc
            } $TabContent
        }.GetNewClosure())
    }

    # === Sub-tab control: lazy-load the newly-selected sub-tab's data ==========
    $subTabControl = Find-Control -Parent $TabContent -Name 'SdkSubTabControl'
    if ($subTabControl) {
        $subTabControl.Add_SelectionChanged({
            & $module {
                param($tc, $sender, $evt)
                # Only react to the TabControl's own selection, not bubbled
                # SelectionChanged events from inner ComboBoxes / grids.
                if ($null -ne $evt -and $evt.OriginalSource -ne $sender) { return }
                Invoke-SdkSubTabLoad -TabContent $tc -SelectedTab $sender.SelectedItem
            } $TabContent $this $_
        }.GetNewClosure())
    }

    # Initial status labels for every sub-tab, then load the default (Templates).
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel'    -Message 'Ready. Click Refresh to load campaign templates.'
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkCertSummaryStatusLabel' -Message 'Select a campaign, then a certification, to load summaries.'
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkApprovalStatusLabel'    -Message 'Ready. Click Refresh to load approvals.'
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel'    -Message 'Ready. Click Refresh to load work items.'
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel'    -Message 'Ready. Click Refresh to load workflows.'
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel'      -Message 'Ready. Click Refresh to load filters.'

    # Default sub-tab is Templates -- trigger its initial (stub) load.
    Invoke-SdkTemplateRefresh -TabContent $TabContent
}

# ---------------------------------------------------------------------------
# Sub-tab helpers
#
# SDK-10 ships THIN STUBS: each only updates the sub-tab status label to a
# 'deferred to SDK-11' message. They are the named extension points the SDK-11
# background-runspace data loads (and SDK-12 dialog/Safety wiring) plug into.
# No bridge/API call (Get-SPGuiSdk* / Invoke-SPGuiSdk*) is made here yet.
# ---------------------------------------------------------------------------

function Set-SdkSubTabStatus {
    <#
    .SYNOPSIS
        Sets the text of a named SDK sub-tab status label, if present.
    #>
    [CmdletBinding()]
    param(
        $TabContent,
        [Parameter(Mandatory)][string]$StatusName,
        [Parameter(Mandatory)][string]$Message
    )

    $label = Find-Control -Parent $TabContent -Name $StatusName
    if ($null -ne $label) {
        $label.Text = $Message
    }
}

function Set-SdkSubTabButtonsEnabled {
    <#
    .SYNOPSIS
        Enables/disables every per-sub-tab SDK Refresh/action Button under $TabContent.
    .DESCRIPTION
        Used by the SDK load engines to give the single-load guard
        ($script:IsSdkRunning) a visible state: disabled buttons during a load make
        a click an obvious no-op instead of a silent one. Each button is resolved by
        x:Name via Find-Control and null-guarded (a button may be absent in some
        sub-tab). Writes .IsEnabled directly because every caller is already on the
        UI thread (mirrors Set-SdkSubTabStatus): the initial disable runs
        synchronously in the button-click handler, and the re-enable runs inside the
        DispatcherTimer Add_Tick body -- both on the dispatcher (UI) thread.

        ADDITIVE / behaviour-preserving (round-05 fix): the re-enable pass MUST NOT
        flip a control that was already disabled BEFORE the load to clickable. Some
        controls are intentionally disabled by design (e.g. BtnSdkRefreshSummaries +
        the Cert-Summaries combos are IsEnabled="False" in SdkTab.xaml per SDK-18,
        because that deferred sub-tab is still collapsed). Unconditionally setting
        IsEnabled=$true on re-enable would silently enable that deferred button while
        its driving combos stay disabled -- a regression and an inconsistent state.

        To avoid that we SNAPSHOT each button's IsEnabled at the moment of disable
        (-Enabled $false) into $script:SdkButtonEnabledSnapshot, keyed by the control
        instance, and on re-enable (-Enabled $true) restore ONLY the prior value
        (default $true when no snapshot exists, preserving legacy behaviour for any
        control that was enabled going in). A control that was disabled going in
        stays disabled coming out.
    #>
    [CmdletBinding()]
    param(
        $TabContent,
        [Parameter(Mandatory)][bool]$Enabled
    )

    if ($null -eq $TabContent) { return }

    if ($null -eq $script:SdkButtonEnabledSnapshot) {
        # Identity-keyed snapshot map. PS 5.1 / .NET Framework 4.8 has no
        # ReferenceEqualityComparer, so we key by the object's identity hash
        # (RuntimeHelpers.GetHashCode -- stable for the object's lifetime,
        # independent of any overridden GetHashCode/Equals) and store the live
        # reference alongside the remembered bool to verify identity on read.
        $script:SdkButtonEnabledSnapshot = @{}
    }

    $names = @(
        'BtnSdkRefreshTemplates','BtnSdkNewTemplate','BtnSdkEditSchedule','BtnSdkRemoveSchedule','BtnSdkDeleteTemplate',
        'BtnSdkRefreshSummaries',
        'BtnSdkRefreshApprovals','BtnSdkApprove','BtnSdkDeny','BtnSdkForward',
        'BtnSdkRefreshWorkItems','BtnSdkCompleteWorkItem','BtnSdkForwardWorkItem','BtnSdkBulkApprove',
        'BtnSdkRefreshWorkflows','BtnSdkEnableWorkflow','BtnSdkTestWorkflow','BtnSdkViewExecutions','BtnSdkCreateOOO',
        'BtnSdkRefreshFilters','BtnSdkNewFilter','BtnSdkEditFilter','BtnSdkDeleteFilter'
    )
    foreach ($n in $names) {
        $btn = Find-Control -Parent $TabContent -Name $n
        if ($null -eq $btn) { continue }

        $key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($btn)

        if (-not $Enabled) {
            # Disabling for a load -- remember the control's current state so the
            # matching re-enable restores it exactly (a default-disabled control
            # is recorded as $false and therefore stays disabled afterwards).
            # Re-entrancy-safe: a NESTED disable (e.g. an action whose success
            # chains a grid refresh that disables again before the action's finally
            # runs) must NOT overwrite an existing snapshot with the already-forced
            # $false state -- keep the ORIGINAL pre-disable value.
            $existing = $script:SdkButtonEnabledSnapshot[$key]
            if ($null -eq $existing -or -not [object]::ReferenceEquals($existing.Control, $btn)) {
                $script:SdkButtonEnabledSnapshot[$key] = `
                    [pscustomobject]@{ Control = $btn; Prior = [bool]$btn.IsEnabled }
            }
            $btn.IsEnabled = $false
        }
        else {
            # Re-enabling after a load -- restore the snapshotted prior value.
            # Default to $true (legacy behaviour) when no snapshot was taken, so a
            # control we never disabled is never wrongly forced off. Verify object
            # identity (ReferenceEquals) to be safe against any hash collision.
            $prior = $true
            $snap  = $script:SdkButtonEnabledSnapshot[$key]
            if ($null -ne $snap -and [object]::ReferenceEquals($snap.Control, $btn)) {
                $prior = $snap.Prior
                [void]$script:SdkButtonEnabledSnapshot.Remove($key)
            }
            $btn.IsEnabled = $prior
        }
    }
}

function Invoke-SdkGridRefresh {
    <#
    .SYNOPSIS
        Shared background-runspace data loader for the SDK sub-tab grids (SDK-11).
    .DESCRIPTION
        DRY engine behind the 5 data-loading refresh helpers (Templates,
        Approvals, Work Items, Workflows, Filters). Mirrors the runspace skeleton
        of Invoke-GuiAuditRun (WPF note 3): spins a background STA runspace,
        re-imports the modules the runspace needs (it starts empty -- SP.Core,
        SP.Api, SP.Sdk, SP.Gui; SP.Gui brings SP.SdkBridge as a nested module so
        Get-SPGuiSdk* resolve here), calls the named bridge read function, then
        marshals the @{Success;Data;...} result back to the UI thread via
        $MainWindow.Dispatcher.

        NEVER touches a control or ObservableCollection from the runspace thread:
        the .Clear()/.Add() and all label/badge writes happen inside the
        Dispatcher.Invoke([System.Action]{...}) block, and the completion timer
        Tick re-enters module scope via `& $module {...}.GetNewClosure()` (WPF
        note 2) so private helpers and $script:* resolve at fire-time.

        Re-entrancy is guarded by $script:IsSdkRunning the way Invoke-GuiAuditRun
        uses $script:IsAuditRunning.
    .PARAMETER OnLoaded
        Optional scriptblock run INSIDE the Dispatcher block AFTER rows are
        marshalled. Receives ($result, $TabContent) and is invoked with module
        scope re-entered (& $module {...}) so it can update badges / summary
        panels / apply the work-item open-only filter via module-private helpers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TabContent,
        [Parameter(Mandatory)][string]$BridgeFunction,
        [hashtable]$BridgeArgs = @{},
        [Parameter(Mandatory)]$DataSource,
        [Parameter(Mandatory)][string]$StatusLabelName,
        [string]$LoadingMessage,
        [scriptblock]$OnLoaded
    )

    if ($script:IsSdkRunning) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName $StatusLabelName -Message 'An SDK data load is already in progress. Please wait...'
        return
    }

    if ([string]::IsNullOrWhiteSpace($LoadingMessage)) {
        $LoadingMessage = 'Loading...'
    }
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName $StatusLabelName -Message $LoadingMessage

    $script:IsSdkRunning = $true
    Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false

    # Create background runspace (STA) -- mirror Invoke-GuiAuditRun.
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    # Share inputs explicitly (PS 5.1: no closures across runspace boundaries).
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',    $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',     $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('BridgeFunction', $BridgeFunction)
    $runspace.SessionStateProxy.SetVariable('BridgeArgs',     $BridgeArgs)
    $runspace.SessionStateProxy.SetVariable('DataSource',     $DataSource)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # The runspace starts empty (WPF note 3): re-import every module the
        # bridge call needs. SP.Sdk is imported explicitly because it is not yet
        # in the dashboard module chain (that wiring is SDK-13). SP.Gui brings
        # SP.SdkBridge as a nested module so Get-SPGuiSdk* resolve here.
        $coreModule = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule  = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $sdkModule  = Join-Path $ToolkitRoot 'Modules\SP.Sdk\SP.Sdk.psd1'
        $guiModule  = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $sdkModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        # Call the bridge read function (returns @{Success;Data;...}).
        $bridgeResult = & $BridgeFunction @BridgeArgs

        # Marshal back to the UI thread -- this is the ONLY place the bound
        # ObservableCollection and any control are touched.
        $dispatcher       = $MainWindow.Dispatcher
        $capturedResult   = $bridgeResult
        $capturedSource   = $DataSource

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedResult -and $capturedResult.Success) {
                $capturedSource.Clear()
                foreach ($row in @($capturedResult.Data)) {
                    $capturedSource.Add($row)
                }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Normal)

        return $bridgeResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null

    $asyncResult = $psInstance.BeginInvoke()

    # DispatcherTimer polls for completion (500ms), mirror Invoke-GuiAuditRun.
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult
    $capturedTab      = $TabContent
    $capturedStatus   = $StatusLabelName
    $capturedOnLoaded = $OnLoaded
    $capturedModule   = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $statusName, $onLoaded)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            try {
                $result = $null
                try { $result = $ps.EndInvoke($async) | Select-Object -First 1 } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    # Classify the error so we can show a targeted, sub-tab-only message
                    # without alarming the main status bar for expected configuration gaps.
                    $isAuthErr   = $errMsg -match '(?i)access.?token|401|authenticat|not.*authoriz|credential|scope|connect'
                    $isScopeErr  = $errMsg -match '(?i)403|forbidden'
                    if ($isScopeErr) {
                        # 403 = token is valid but the OAuth client lacks the required scope.
                        # SDK endpoints need sp:scopes:all (or specific idn:* scopes).
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName `
                            -Message 'Access denied (403). Add sp:scopes:all to your Personal Access Token in ISC Admin → Security Settings → Personal Access Tokens.'
                    } elseif ($isAuthErr) {
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName `
                            -Message 'Not connected — configure credentials in the Settings tab, then click Refresh.'
                    } else {
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message "Load failed: $errMsg"
                        Set-StatusMessage -Message "SDK load failed: $errMsg" -IsError
                    }
                }
                elseif ($null -ne $result -and -not $result.Success) {
                    $errDetail  = [string]$result.Error
                    $isAuthErr  = $errDetail -match '(?i)access.?token|401|authenticat|not.*authoriz|credential|scope|connect'
                    $isScopeErr = $errDetail -match '(?i)403|forbidden'
                    if ($isScopeErr) {
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName `
                            -Message 'Access denied (403). Add sp:scopes:all to your Personal Access Token in ISC Admin → Security Settings → Personal Access Tokens.'
                    } elseif ($isAuthErr) {
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName `
                            -Message 'Not connected — configure credentials in the Settings tab, then click Refresh.'
                    } else {
                        Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message "Load failed: $errDetail"
                        Set-StatusMessage -Message "SDK load failed: $errDetail" -IsError
                    }
                }
                else {
                    $count = if ($null -ne $result) { @($result.Data).Count } else { 0 }
                    Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message "$count item(s) loaded."

                    # Post-marshal hook (badges / summary panel / row filter).
                    if ($null -ne $onLoaded -and $null -ne $result -and $result.Success) {
                        & $onLoaded $result $tab
                    }
                }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                $script:IsSdkRunning = $false
                Set-SdkSubTabButtonsEnabled -TabContent $tab -Enabled $true
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedStatus $capturedOnLoaded
    }.GetNewClosure())

    $timer.Start()
}

function Test-SdkRequireWhatIfConfirm {
    <#
    .SYNOPSIS
        UI-thread Safety.RequireWhatIfOnProd confirmation for SDK write actions.
    .DESCRIPTION
        Mirrors the Invoke-GuiTestRun guard (SP.MainWindow.psm1:464-490): reads
        Safety.RequireWhatIfOnProd + Global.EnvironmentName from settings.json via
        Get-SPConfig with the defensive `PSObject.Properties.Name -contains` idiom,
        defaulting to safe (prompt) if config cannot be read. When the flag is set
        it shows a YesNo MessageBox describing the live action and the environment.

        Returns $true when the caller may proceed (flag off, or user chose Yes),
        $false when the user cancelled (the caller then aborts and sets a
        'cancelled by user (Safety.RequireWhatIfOnProd)' status). Runs entirely on
        the UI thread BEFORE any runspace -- the bridge cannot show UI (SDK-03).
    .PARAMETER ActionDescription
        Human-readable description of the live action (e.g. 'delete 1 template').
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ActionDescription
    )

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

    if (-not $requireConfirm) {
        return $true
    }

    $msg = "Safety.RequireWhatIfOnProd is enabled in settings.json.`n`n" +
           "About to $ActionDescription against environment: $envName`n`n" +
           "Continue with live API execution?"
    $choice = [System.Windows.MessageBox]::Show(
        $msg,
        'Confirm Live SDK Action',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-SdkActionRun {
    <#
    .SYNOPSIS
        Shared background-runspace WRITE engine for the SDK sub-tab action buttons
        (SDK-12).
    .DESCRIPTION
        Mirrors the SDK-11 read engine Invoke-SdkGridRefresh skeleton: spins a
        background STA runspace, re-imports the modules the runspace needs (it
        starts empty -- SP.Core, SP.Api, SP.Sdk, SP.Gui; SP.Gui brings SP.SdkBridge
        as a nested module so Invoke-SPGuiSdk* resolve here -- WPF note 3), calls
        the named bridge WRITE dispatcher, then marshals the @{Success;Data;Error}
        result back to the UI thread via $MainWindow.Dispatcher. Re-entrancy is
        guarded by $script:IsSdkRunning (shared with the read engine).

        The runspace ONLY runs the dispatcher: NO MessageBox / Show-SPGuiDialog /
        control access happens off the UI thread. All confirms + dialog input must
        be gathered on the UI thread BEFORE calling this engine (SDK-03 contract).

        On dispatcher Success the completion-timer Tick re-enters module scope via
        `& $module {...}.GetNewClosure()` (WPF note 2) and invokes the OnSuccess
        scriptblock (the sub-tab *Refresh helper) so private helpers and $script:*
        resolve at fire-time. On @{Success=$false} it sets the sub-tab status +
        Set-StatusMessage -IsError with the Error string and never throws.
    .PARAMETER OnSuccess
        Optional scriptblock run (in module scope, on the UI thread) AFTER a
        successful dispatch -- typically the affected sub-tab's refresh helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TabContent,
        [Parameter(Mandatory)][string]$BridgeFunction,
        [hashtable]$BridgeArgs = @{},
        [Parameter(Mandatory)][string]$StatusLabelName,
        [string]$RunningMessage,
        [scriptblock]$OnSuccess
    )

    if ($script:IsSdkRunning) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName $StatusLabelName -Message 'An SDK operation is already in progress. Please wait...'
        return
    }

    if ([string]::IsNullOrWhiteSpace($RunningMessage)) {
        $RunningMessage = 'Working...'
    }
    Set-SdkSubTabStatus -TabContent $TabContent -StatusName $StatusLabelName -Message $RunningMessage

    $script:IsSdkRunning = $true
    Set-SdkSubTabButtonsEnabled -TabContent $TabContent -Enabled $false

    # Create background runspace (STA) -- mirror Invoke-SdkGridRefresh.
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    # Share inputs explicitly (PS 5.1: no closures across runspace boundaries).
    $runspace.SessionStateProxy.SetVariable('ToolkitRoot',    $script:ToolkitRoot)
    $runspace.SessionStateProxy.SetVariable('MainWindow',     $script:MainWindow)
    $runspace.SessionStateProxy.SetVariable('BridgeFunction', $BridgeFunction)
    $runspace.SessionStateProxy.SetVariable('BridgeArgs',     $BridgeArgs)

    $psInstance = [System.Management.Automation.PowerShell]::Create()
    $psInstance.Runspace = $runspace

    $scriptBlock = {
        # The runspace starts empty (WPF note 3): re-import every module the
        # bridge call needs. SP.Sdk is imported explicitly because it is not yet
        # in the dashboard module chain (that wiring is SDK-13). SP.Gui brings
        # SP.SdkBridge as a nested module so Invoke-SPGuiSdk* resolve here.
        $coreModule = Join-Path $ToolkitRoot 'Modules\SP.Core\SP.Core.psd1'
        $apiModule  = Join-Path $ToolkitRoot 'Modules\SP.Api\SP.Api.psd1'
        $sdkModule  = Join-Path $ToolkitRoot 'Modules\SP.Sdk\SP.Sdk.psd1'
        $guiModule  = Join-Path $ToolkitRoot 'Modules\SP.Gui\SP.Gui.psd1'

        foreach ($mod in @($coreModule, $apiModule, $sdkModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        # Call the bridge WRITE dispatcher (returns @{Success;Data;Error}). No UI
        # is touched here -- the bridge enforces the Safety gate and returns a
        # @{Success=$false;Error='blocked by Safety...'} result rather than throwing.
        $bridgeResult = & $BridgeFunction @BridgeArgs

        return $bridgeResult
    }

    $psInstance.AddScript($scriptBlock) | Out-Null

    $asyncResult = $psInstance.BeginInvoke()

    # DispatcherTimer polls for completion (500ms), mirror Invoke-SdkGridRefresh.
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer     = $timer
    $capturedPs        = $psInstance
    $capturedRunspace  = $runspace
    $capturedAsync     = $asyncResult
    $capturedTab       = $TabContent
    $capturedStatus    = $StatusLabelName
    $capturedOnSuccess = $OnSuccess
    $capturedModule    = $script:ThisModule

    $timer.Add_Tick({
        & $capturedModule {
            param($t, $ps, $rs, $async, $tab, $statusName, $onSuccess)

            if ($ps.InvocationStateInfo.State -notin @('Completed', 'Failed', 'Stopped')) { return }

            $t.Stop()

            # Round-05 T-01 fix: tracks whether the success-path $onSuccess started
            # a CHAINED refresh (Invoke-SdkGridRefresh) that re-took the single-load
            # guard + re-disabled the buttons for its OWN background load. When it
            # has, this action's finally must NOT re-enable the buttons or clear the
            # guard -- doing so would clobber the chained refresh (a disable->enable
            # ->enable flicker and a window where SDK buttons are clickable mid-load).
            # The chained refresh owns and will release that state in its own Tick.
            $chainedRefreshOwnsState = $false

            try {
                $result = $null
                try { $result = $ps.EndInvoke($async) | Select-Object -First 1 } catch { }

                if ($ps.HadErrors) {
                    $errMsg = ($ps.Streams.Error | Select-Object -First 1).Exception.Message
                    Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message "Action failed: $errMsg"
                    Set-StatusMessage -Message "SDK action failed: $errMsg" -IsError
                }
                elseif ($null -eq $result -or -not $result.Success) {
                    # Surfaces the dispatcher's @{Success=$false;Error=...} verbatim --
                    # including Safety-blocked results ('blocked by Safety...'). Never throws.
                    $errMsg = if ($null -ne $result) { [string]$result.Error } else { 'Unknown error (no result returned).' }
                    Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message "Action failed: $errMsg"
                    Set-StatusMessage -Message "SDK action failed: $errMsg" -IsError
                }
                else {
                    Set-SdkSubTabStatus -TabContent $tab -StatusName $statusName -Message 'Action completed.'
                    Set-StatusMessage -Message 'SDK action completed.'
                    # Refresh the affected grid (the OnSuccess scriptblock runs in
                    # module scope so $script:* and private helpers resolve, and
                    # the IsSdkRunning guard is cleared first so the refresh runs).
                    $script:IsSdkRunning = $false
                    if ($null -ne $onSuccess) {
                        & $onSuccess $tab
                        # If the chained refresh successfully started, it set the
                        # guard back to $true and re-disabled the buttons. Detect
                        # that and hand ownership over to it.
                        if ($script:IsSdkRunning) { $chainedRefreshOwnsState = $true }
                    }
                }

                try {
                    $ps.Dispose()
                    $rs.Close()
                } catch { }
            }
            finally {
                # Skip the re-enable / guard-clear when a chained refresh has taken
                # ownership -- it will release them in its own completion Tick.
                if (-not $chainedRefreshOwnsState) {
                    $script:IsSdkRunning = $false
                    Set-SdkSubTabButtonsEnabled -TabContent $tab -Enabled $true
                }
            }
        } $capturedTimer $capturedPs $capturedRunspace $capturedAsync $capturedTab $capturedStatus $capturedOnSuccess
    }.GetNewClosure())

    $timer.Start()
}

function Invoke-SdkSubTabLoad {
    <#
    .SYNOPSIS
        Lazy-loads the default data for the newly-selected SDK sub-tab by routing
        to that sub-tab's refresh helper (stub in SDK-10).
    #>
    [CmdletBinding()]
    param($TabContent, $SelectedTab)

    $header = if ($null -ne $SelectedTab) { [string]$SelectedTab.Header } else { '' }
    switch ($header) {
        'Templates'      { Invoke-SdkTemplateRefresh    -TabContent $TabContent }
        'Cert Summaries' { Invoke-SdkCertSummaryRefresh -TabContent $TabContent }
        'Approvals'      { Invoke-SdkApprovalRefresh     -TabContent $TabContent }
        'Work Items'     { Invoke-SdkWorkItemRefresh     -TabContent $TabContent }
        'Workflows'      { Invoke-SdkWorkflowRefresh      -TabContent $TabContent }
        'Filters'        { Invoke-SdkFilterRefresh        -TabContent $TabContent }
    }
}

# --- Templates -------------------------------------------------------------
function Invoke-SdkTemplateRefresh {
    # SDK-11: background-runspace load of campaign templates into the grid.
    [CmdletBinding()] param($TabContent)
    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkCampaignTemplates' `
        -DataSource      $script:SdkTemplateDataSource `
        -StatusLabelName 'SdkTemplateStatusLabel' `
        -LoadingMessage  'Loading templates...'
}
function Get-SdkSelectedRow {
    <#
    .SYNOPSIS
        Returns the .SelectedItem of a named SDK grid, or $null if none selected.
    .DESCRIPTION
        UI-thread helper. SDK action handlers call this FIRST (before any confirm
        or runspace) to read the operator's selected grid row. Returns $null when
        the grid is missing or nothing is selected so callers can surface a
        'select a row first' status without an exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TabContent,
        [Parameter(Mandatory)][string]$GridName
    )

    # Use window-root FindName so the search isn't constrained by the sub-tab's
    # namescope when driven by a UI automation tool cross-process.
    $grid = $null
    if ($null -ne $script:MainWindow) { $grid = $script:MainWindow.FindName($GridName) }
    if ($null -eq $grid) { $grid = Find-Control -Parent $TabContent -Name $GridName }
    if ($null -eq $grid) { return $null }

    # Return SelectedItem when something is selected. When nothing is selected
    # (automation tools may call SelectionItem.Pattern.Select() which doesn't
    # always propagate synchronously to WPF's SelectedItem), fall back to the
    # first item in the underlying data source so single-row grids remain operable.
    $selected = $grid.SelectedItem
    if ($null -ne $selected) { return $selected }

    # Fallback: first item from the ObservableCollection that backs this grid.
    $source = $grid.ItemsSource
    if ($null -ne $source) {
        $enum = $source.GetEnumerator()
        if ($enum.MoveNext()) { return $enum.Current }
    }
    return $null
}

function Invoke-SdkTemplateNew {
    [CmdletBinding()] param($TabContent)

    $dialogPath = Get-XamlPath -FileName 'SdkTemplateCreateDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath `
        -ControlNames @('TxtTemplateName', 'TxtDeadlineDuration', 'TxtTemplateOwnerId', 'CboReviewerType') `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'New Template cancelled.'
        return
    }

    $name     = [string]$values['TxtTemplateName']
    $deadline = [string]$values['TxtDeadlineDuration']
    $ownerId  = [string]$values['TxtTemplateOwnerId']
    $reviewer = if ($null -ne $values['CboReviewerType']) { [string]$values['CboReviewerType'] } else { 'MANAGER' }

    if ([string]::IsNullOrWhiteSpace($name)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Template Name is required.' -IsError
        return
    }
    if ([string]::IsNullOrWhiteSpace($deadline)) { $deadline = 'P14D' }

    $templateBody = @{
        name             = $name
        deadlineDuration = $deadline
        type             = 'MANAGER'
        reviewerType     = $reviewer
    }
    if (-not [string]::IsNullOrWhiteSpace($ownerId)) {
        $templateBody['ownerRef'] = @{ id = $ownerId; type = 'IDENTITY' }
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "create template '$name'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd).'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkTemplateRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkTemplateAction' `
        -BridgeArgs      @{ Action = 'Create'; Template = $templateBody } `
        -StatusLabelName 'SdkTemplateStatusLabel' `
        -RunningMessage  "Creating template '$name'..." `
        -OnSuccess       $onSuccess
}
function Invoke-SdkTemplateEditSchedule {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkTemplateGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Select a template first.'
        return
    }

    # Gather schedule fields via the SDK-09 modal (UI thread, before runspace).
    $dialogPath = Get-XamlPath -FileName 'SdkTemplateScheduleDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath -ControlNames @(
        'CboScheduleType', 'TxtScheduleHours', 'TxtScheduleDays', 'CboScheduleTimeZone', 'TxtScheduleExpiration'
    )
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Edit Schedule cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "set the schedule for template '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $schedule = @{
        Type       = [string]$values['CboScheduleType']
        Hours      = [string]$values['TxtScheduleHours']
        Days       = [string]$values['TxtScheduleDays']
        TimeZoneId = [string]$values['CboScheduleTimeZone']
        Expiration = [string]$values['TxtScheduleExpiration']
    }

    $onSuccess = { param($tab) Invoke-SdkTemplateRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkTemplateAction' `
        -BridgeArgs      @{ Action = 'SetSchedule'; TemplateId = [string]$row.Id; Schedule = $schedule } `
        -StatusLabelName 'SdkTemplateStatusLabel' `
        -RunningMessage  'Setting template schedule...' `
        -OnSuccess       $onSuccess
}
function Invoke-SdkTemplateRemoveSchedule {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkTemplateGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Select a template first.'
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Remove the schedule from 1 template ('$($row.Name)')?",
        'Confirm Remove Schedule',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Remove Schedule cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "remove the schedule from template '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkTemplateRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkTemplateAction' `
        -BridgeArgs      @{ Action = 'RemoveSchedule'; TemplateId = [string]$row.Id } `
        -StatusLabelName 'SdkTemplateStatusLabel' `
        -RunningMessage  'Removing template schedule...' `
        -OnSuccess       $onSuccess
}
function Invoke-SdkTemplateDelete {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkTemplateGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Select a template first.'
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Delete 1 template ('$($row.Name)')? This cannot be undone.",
        'Confirm Delete Template',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'Delete cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "delete template '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkTemplateStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkTemplateRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkTemplateAction' `
        -BridgeArgs      @{ Action = 'Delete'; TemplateId = [string]$row.Id } `
        -StatusLabelName 'SdkTemplateStatusLabel' `
        -RunningMessage  'Deleting template...' `
        -OnSuccess       $onSuccess
}

# --- Cert Summaries --------------------------------------------------------
function Invoke-SdkCertSummaryRefresh {
    # SDK-18 (SHIPPED): drives the campaign -> certification cascade and then loads
    # Identity or Access summaries into SdkCertSummaryGrid.
    #
    # The two combo lists (campaigns, certifications) are small reads and are
    # populated SYNCHRONOUSLY here so the cascade stays simple; the potentially
    # larger summary read runs on the background runspace via Invoke-SdkGridRefresh
    # (WPF note 3). $script:SdkCertCascadeBusy guards the combo SelectionChanged
    # handlers from re-entering while we set ItemsSource/SelectedIndex ourselves.
    [CmdletBinding()] param($TabContent)

    if ($script:SdkCertCascadeBusy) { return }

    $cboCampaign = Find-Control -Parent $TabContent -Name 'CboSdkCertCampaign'
    $cboCert     = Find-Control -Parent $TabContent -Name 'CboSdkCertification'
    $cboType     = Find-Control -Parent $TabContent -Name 'CboSdkAccessType'

    # 1. Populate the campaign combo once (from the existing GUI campaign cache).
    if ($null -ne $cboCampaign -and $cboCampaign.Items.Count -eq 0) {
        $script:SdkCertCascadeBusy = $true
        try {
            $campaigns = Get-SPGuiSdkCertCampaigns
            if ($campaigns.Success) {
                $cboCampaign.ItemsSource = @($campaigns.Data)
            }
            else {
                Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkCertSummaryStatusLabel' `
                    -Message "Cannot load campaigns: $($campaigns.Error)"
            }
        }
        finally { $script:SdkCertCascadeBusy = $false }
    }

    # 2. A campaign must be selected to go further.
    $campaignId = if ($null -ne $cboCampaign -and $null -ne $cboCampaign.SelectedValue) { [string]$cboCampaign.SelectedValue } else { '' }
    if ([string]::IsNullOrWhiteSpace($campaignId)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkCertSummaryStatusLabel' -Message 'Select a campaign to load certifications.'
        return
    }

    # 3. (Re)populate the certification combo only when the campaign changed.
    if ($script:SdkCertLoadedCampaign -ne $campaignId) {
        $script:SdkCertCascadeBusy = $true
        try {
            $certs = Get-SPGuiSdkCertifications -CampaignId $campaignId
            if ($certs.Success) {
                $cboCert.ItemsSource = @($certs.Data)
                $script:SdkCertLoadedCampaign = $campaignId
                if ($cboCert.Items.Count -gt 0) { $cboCert.SelectedIndex = 0 }
            }
            else {
                $cboCert.ItemsSource = @()
                $script:SdkCertLoadedCampaign = $campaignId
                Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkCertSummaryStatusLabel' `
                    -Message "Cannot load certifications: $($certs.Error)"
                return
            }
        }
        finally { $script:SdkCertCascadeBusy = $false }
    }

    # 4. A certification must be selected to load summaries.
    $certId = if ($null -ne $cboCert -and $null -ne $cboCert.SelectedValue) { [string]$cboCert.SelectedValue } else { '' }
    if ([string]::IsNullOrWhiteSpace($certId)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkCertSummaryStatusLabel' -Message 'Select a certification to load summaries.'
        return
    }

    # 5. Identity (default) vs Access-by-type, from CboSdkAccessType.
    $typeChoice = if ($null -ne $cboType -and $null -ne $cboType.SelectedItem) { [string]$cboType.SelectedItem.Content } else { 'Identity' }
    $bridgeArgs = @{ CertificationId = $certId }
    if ([string]::IsNullOrWhiteSpace($typeChoice) -or $typeChoice -eq 'Identity') {
        $bridgeArgs['SummaryType'] = 'Identity'
        $loadingMsg = 'Loading identity summaries...'
    }
    else {
        $apiType = switch ($typeChoice) {
            'Entitlement'    { 'ENTITLEMENT' }
            'Role'           { 'ROLE' }
            'Access Profile' { 'ACCESS_PROFILE' }
            default          { 'ENTITLEMENT' }
        }
        $bridgeArgs['SummaryType'] = 'Access'
        $bridgeArgs['AccessType']  = $apiType
        $loadingMsg = "Loading $typeChoice access summaries..."
    }

    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkCertSummaries' `
        -BridgeArgs      $bridgeArgs `
        -DataSource      $script:SdkCertSummaryDataSource `
        -StatusLabelName 'SdkCertSummaryStatusLabel' `
        -LoadingMessage  $loadingMsg
}

# --- Approvals -------------------------------------------------------------
function Invoke-SdkApprovalRefresh {
    # SDK-11: load pending/completed approvals; rebuild the summary badges.
    [CmdletBinding()] param($TabContent)

    # Read the Pending/Completed radio on the UI thread BEFORE the runspace.
    $rbCompleted = Find-Control -Parent $TabContent -Name 'RbSdkCompleted'
    $state = if ($null -ne $rbCompleted -and $rbCompleted.IsChecked -eq $true) { 'Completed' } else { 'Pending' }

    $onLoaded = {
        param($result, $tab)

        # Derive counts: when Completed is shown the rows carry a State field
        # (APPROVED/REJECTED/...); when Pending is shown all rows are pending.
        $pending  = 0
        $approved = 0
        $rejected = 0

        foreach ($row in @($result.Data)) {
            $rowState = if ($null -ne $row.State) { ([string]$row.State).ToUpperInvariant() } else { '' }
            switch -Wildcard ($rowState) {
                '*APPROV*' { $approved++ }
                '*REJECT*' { $rejected++ }
                '*DENI*'   { $rejected++ }
                default    { $pending++ }
            }
        }

        $badgePending  = Find-Control -Parent $tab -Name 'SdkApprovalBadgePending'
        $badgeApproved = Find-Control -Parent $tab -Name 'SdkApprovalBadgeApproved'
        $badgeRejected = Find-Control -Parent $tab -Name 'SdkApprovalBadgeRejected'
        if ($null -ne $badgePending)  { $badgePending.Text  = [string]$pending }
        if ($null -ne $badgeApproved) { $badgeApproved.Text = [string]$approved }
        if ($null -ne $badgeRejected) { $badgeRejected.Text = [string]$rejected }
    }

    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkApprovals' `
        -BridgeArgs      @{ State = $state } `
        -DataSource      $script:SdkApprovalDataSource `
        -StatusLabelName 'SdkApprovalStatusLabel' `
        -LoadingMessage  "Loading $state approvals..." `
        -OnLoaded        $onLoaded
}
function Invoke-SdkApprovalAction {
    <#
    .SYNOPSIS
        Shared UI-thread driver for the three approval verbs (Approve/Deny/Forward).
    .DESCRIPTION
        Reads the selected approval row, gathers Comment/Forward-To via the SDK-09
        SdkApprovalActionDialog (UI thread), applies the destructive-verb confirm
        (Deny/Forward) + RequireWhatIfOnProd gate, then dispatches via the write
        engine. Approve is non-destructive (no affected-count confirm); Deny and
        Forward show a YesNo confirm before dispatch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TabContent,
        [Parameter(Mandatory)][ValidateSet('Approve', 'Deny', 'Forward')][string]$Action
    )

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkApprovalGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkApprovalStatusLabel' -Message 'Select an approval first.'
        return
    }

    # Gather Comment / Forward-To via the SDK-09 modal (UI thread, before runspace).
    $dialogPath = Get-XamlPath -FileName 'SdkApprovalActionDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath -ControlNames @('TxtComment', 'TxtForwardTo')
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkApprovalStatusLabel' -Message "$Action cancelled."
        return
    }

    $comment    = [string]$values['TxtComment']
    $forwardTo  = [string]$values['TxtForwardTo']

    # Destructive/hand-off verbs (Deny/Forward) get an affected-count confirm.
    if ($Action -in @('Deny', 'Forward')) {
        $confirm = [System.Windows.MessageBox]::Show(
            "$Action 1 approval ('$($row.Name)')?",
            "Confirm $Action",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkApprovalStatusLabel' -Message "$Action cancelled."
            return
        }
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "$($Action.ToLower()) approval '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkApprovalStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $bridgeArgs = @{ Action = $Action; ApprovalId = [string]$row.Id }
    if (-not [string]::IsNullOrWhiteSpace($comment))   { $bridgeArgs['Comment']    = $comment }
    if ($Action -eq 'Forward' -and -not [string]::IsNullOrWhiteSpace($forwardTo)) { $bridgeArgs['NewOwnerId'] = $forwardTo }

    $onSuccess = { param($tab) Invoke-SdkApprovalRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkApprovalAction' `
        -BridgeArgs      $bridgeArgs `
        -StatusLabelName 'SdkApprovalStatusLabel' `
        -RunningMessage  "$Action in progress..." `
        -OnSuccess       $onSuccess
}
function Invoke-SdkApprovalApprove {
    [CmdletBinding()] param($TabContent)
    Invoke-SdkApprovalAction -TabContent $TabContent -Action 'Approve'
}
function Invoke-SdkApprovalDeny {
    [CmdletBinding()] param($TabContent)
    Invoke-SdkApprovalAction -TabContent $TabContent -Action 'Deny'
}
function Invoke-SdkApprovalForward {
    [CmdletBinding()] param($TabContent)
    Invoke-SdkApprovalAction -TabContent $TabContent -Action 'Forward'
}

# --- Work Items ------------------------------------------------------------
function Invoke-SdkWorkItemRefresh {
    # SDK-11: load work items + open/completed/total badges; open-only filter
    # is applied from the full Data set in OnLoaded so the toggle never re-hits
    # the API.
    [CmdletBinding()] param($TabContent)

    # Read the checkbox state HERE on the UI thread before the runspace starts.
    # This is the only reliable approach: reading $chk.IsChecked inside OnLoaded
    # is unreliable because the WPF element reference may not reflect the current
    # state cross-process (automation tools set the toggle via a COM pattern that
    # dispatches asynchronously; the WPF property update lags). Capturing the
    # value now, on the same UI thread call that launched the refresh, guarantees
    # the correct state is seen in the closure.
    # Read the current checkbox state. We try three sources in priority order so
    # the behavior is correct for both interactive use (where IsChecked is reliable)
    # and cross-process automation (where COM Toggle may not fire Add_Checked).
    #
    # Source 1: re-read IsChecked directly (works for normal user interaction).
    # Source 2: shadow variable $script:SdkWorkItemShowCompleted (updated by
    #           Add_Checked/Add_Unchecked; reliable for normal interaction but
    #           not for COM-based automation that bypasses routed events).
    # Source 3: IsChecked again as the authoritative final read.
    #
    # To handle the automation case: sync the shadow from IsChecked now so both
    # agree, then use IsChecked as the value. The shadow is updated as a side
    # effect for the next call.
    # Read the checkbox state. Use the shadow $script:SdkWorkItemShowCompleted
    # (set by Add_Checked/Add_Unchecked and synced from IsChecked on each call)
    # as the primary value; fall back to a live IsChecked read as a safety net.
    $chkWi = $script:SdkWorkItemShowCompletedChk
    if ($null -eq $chkWi -and $null -ne $script:MainWindow) {
        try { $chkWi = $script:MainWindow.FindName('ChkSdkShowCompleted') } catch { }
    }
    if ($null -ne $chkWi) {
        # Always sync the shadow so both agree; use the live value.
        $script:SdkWorkItemShowCompleted = ($chkWi.IsChecked -eq $true)
    }
    $capturedShowCompleted = $script:SdkWorkItemShowCompleted

    $onLoaded = {
        param($result, $tab)

        # Badges from the bridge Summary (open/completed/total).
        $summary = $result.Summary
        $badgeOpen      = Find-Control -Parent $tab -Name 'SdkWiBadgeOpen'
        $badgeCompleted = Find-Control -Parent $tab -Name 'SdkWiBadgeCompleted'
        $badgeTotal     = Find-Control -Parent $tab -Name 'SdkWiBadgeTotal'
        if ($null -ne $summary) {
            if ($null -ne $badgeOpen)      { $badgeOpen.Text      = [string]$summary.Open }
            if ($null -ne $badgeCompleted) { $badgeCompleted.Text = [string]$summary.Completed }
            if ($null -ne $badgeTotal)     { $badgeTotal.Text     = [string]$summary.Total }
        }

        # The bridge already returned the correct set (open-only or open+completed)
        # based on ShowCompleted passed as a BridgeArg. No post-filter needed here.
    }

    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkWorkItems' `
        -BridgeArgs      @{ ShowCompleted = $capturedShowCompleted } `
        -DataSource      $script:SdkWorkItemDataSource `
        -StatusLabelName 'SdkWorkItemStatusLabel' `
        -LoadingMessage  'Loading work items...' `
        -OnLoaded        $onLoaded
}
function Invoke-SdkWorkItemComplete {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkItemGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Select a work item first.'
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Complete 1 work item ('$($row.Name)')?",
        'Confirm Complete Work Item',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Complete cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "complete work item '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkItemRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkItemAction' `
        -BridgeArgs      @{ Action = 'Complete'; WorkItemId = [string]$row.Id } `
        -StatusLabelName 'SdkWorkItemStatusLabel' `
        -RunningMessage  'Completing work item...' `
        -OnSuccess       $onSuccess
}
function Invoke-SdkWorkItemForward {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkItemGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Select a work item first.'
        return
    }

    $dialogPath = Get-XamlPath -FileName 'SdkWorkItemForwardDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath `
        -ControlNames @('TxtForwardTargetId', 'TxtForwardComment') `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Forward cancelled.'
        return
    }

    $targetId = [string]$values['TxtForwardTargetId']
    $comment  = [string]$values['TxtForwardComment']

    if ([string]::IsNullOrWhiteSpace($targetId)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Target owner identity ID is required.' -IsError
        return
    }
    if ([string]::IsNullOrWhiteSpace($comment)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Comment is required for Forward.' -IsError
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Forward work item '$($row.Description)' to identity '$targetId'?",
        'Confirm Forward',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Forward cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "forward work item '$($row.Description)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd).'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkItemRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkItemAction' `
        -BridgeArgs      @{ Action = 'Forward'; WorkItemId = [string]$row.Id; TargetOwnerId = $targetId; Comment = $comment } `
        -StatusLabelName 'SdkWorkItemStatusLabel' `
        -RunningMessage  'Forwarding work item...' `
        -OnSuccess       $onSuccess
}
function Invoke-SdkWorkItemBulkApprove {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkItemGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Select a work item first.'
        return
    }

    # Affected-count confirm: BulkApprove approves every item under the work item.
    $confirm = [System.Windows.MessageBox]::Show(
        "Bulk approve all items under 1 work item ('$($row.Name)')? This approves every decision in the item.",
        'Confirm Bulk Approve',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'Bulk Approve cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "bulk approve work item '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkItemStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkItemRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkItemAction' `
        -BridgeArgs      @{ Action = 'BulkApprove'; WorkItemId = [string]$row.Id } `
        -StatusLabelName 'SdkWorkItemStatusLabel' `
        -RunningMessage  'Bulk approving...' `
        -OnSuccess       $onSuccess
}

# --- Workflows -------------------------------------------------------------
function Invoke-SdkWorkflowRefresh {
    # SDK-11: load workflows into the grid. Executions are loaded by the
    # "View Executions" action button (SDK-12), not auto-loaded here.
    [CmdletBinding()] param($TabContent)
    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkWorkflows' `
        -DataSource      $script:SdkWorkflowDataSource `
        -StatusLabelName 'SdkWorkflowStatusLabel' `
        -LoadingMessage  'Loading workflows...'
}
function Invoke-SdkWorkflowToggleEnabled {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkflowGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Select a workflow first.'
        return
    }

    $currentlyEnabled = [bool]$row.Enabled
    $newEnabled       = -not $currentlyEnabled
    $verb             = if ($newEnabled) { 'Enable' } else { 'Disable' }

    # Disabling is the safety-relevant direction: confirm with an affected count.
    if (-not $newEnabled) {
        $confirm = [System.Windows.MessageBox]::Show(
            "Disable 1 workflow ('$($row.Name)')? It will stop running until re-enabled.",
            'Confirm Disable Workflow',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Disable cancelled.'
            return
        }
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "$($verb.ToLower()) workflow '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkflowRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkflowAction' `
        -BridgeArgs      @{ Action = 'Toggle'; WorkflowId = [string]$row.Id; Enabled = $newEnabled } `
        -StatusLabelName 'SdkWorkflowStatusLabel' `
        -RunningMessage  "$($verb)ing workflow..." `
        -OnSuccess       $onSuccess
}
function Invoke-SdkWorkflowTest {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkflowGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Select a workflow first.'
        return
    }

    # Gather JSON test input via the SDK-09 modal (UI thread, before runspace).
    $dialogPath = Get-XamlPath -FileName 'SdkWorkflowDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath -ControlNames @('TxtTestInput')
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Test cancelled.'
        return
    }

    # Parse the JSON test input on the UI thread; surface a parse error here so
    # the operator can fix it without a round-trip through the runspace.
    $testInput = @{}
    $raw = [string]$values['TxtTestInput']
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($prop in $parsed.PSObject.Properties) { $testInput[$prop.Name] = $prop.Value }
        }
        catch {
            Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message "Test input is not valid JSON: $($_.Exception.Message)"
            Set-StatusMessage -Message "Workflow test input is not valid JSON: $($_.Exception.Message)" -IsError
            return
        }
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "run a test on workflow '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkflowRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkflowAction' `
        -BridgeArgs      @{ Action = 'Test'; WorkflowId = [string]$row.Id; TestInput = $testInput } `
        -StatusLabelName 'SdkWorkflowStatusLabel' `
        -RunningMessage  'Testing workflow...' `
        -OnSuccess       $onSuccess
}
function Invoke-SdkWorkflowViewExecutions {
    # READ path: load executions for the selected workflow into the executions
    # grid via the SDK-11 read engine -- NOT a write dispatcher.
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkWorkflowGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Select a workflow first.'
        return
    }

    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkWorkflowExecutions' `
        -BridgeArgs      @{ WorkflowId = [string]$row.Id } `
        -DataSource      $script:SdkExecutionDataSource `
        -StatusLabelName 'SdkWorkflowStatusLabel' `
        -LoadingMessage  "Loading executions for '$($row.Name)'..."
}
function Invoke-SdkWorkflowCreateOOO {
    [CmdletBinding()] param($TabContent)

    $dialogPath = Get-XamlPath -FileName 'SdkWorkflowOOODialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath `
        -ControlNames @('TxtOOOPrimaryReviewerId', 'TxtOOOFallbackReviewerId', 'TxtOOOFallbackDays') `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Create OOO cancelled.'
        return
    }

    $primaryId  = [string]$values['TxtOOOPrimaryReviewerId']
    $fallbackId = [string]$values['TxtOOOFallbackReviewerId']
    $days       = [string]$values['TxtOOOFallbackDays']

    if ([string]::IsNullOrWhiteSpace($primaryId)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Primary reviewer identity ID is required.' -IsError
        return
    }
    if ([string]::IsNullOrWhiteSpace($fallbackId)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'Fallback reviewer identity ID is required.' -IsError
        return
    }

    [int]$fallbackDays = 3
    if (-not [string]::IsNullOrWhiteSpace($days)) { [int]::TryParse($days, [ref]$fallbackDays) | Out-Null }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "create OOO fallback workflow (primary=$primaryId -> fallback=$fallbackId after $fallbackDays days)")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkWorkflowStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd).'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkWorkflowRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkWorkflowAction' `
        -BridgeArgs      @{ Action = 'CreateOOO'; PrimaryReviewerId = $primaryId; FallbackReviewerId = $fallbackId; FallbackDays = $fallbackDays } `
        -StatusLabelName 'SdkWorkflowStatusLabel' `
        -RunningMessage  'Creating OOO fallback workflow...' `
        -OnSuccess       $onSuccess
}

# --- Filters ---------------------------------------------------------------
function Invoke-SdkFilterRefresh {
    # SDK-11: load campaign filters. NOTE: ChkSdkIncludeSystem is presently a
    # no-op at the bridge layer (Get-SPGuiSdkCampaignFilters defaults to
    # include-all -- see SP.SdkBridge round-01 disagreement). The checkbox is
    # still read and forwarded so real narrowing is a single bridge follow-up.
    [CmdletBinding()] param($TabContent)

    # Read Include-System on the UI thread BEFORE the runspace.
    $chkIncludeSystem = Find-Control -Parent $TabContent -Name 'ChkSdkIncludeSystem'
    $includeSystem    = ($null -ne $chkIncludeSystem -and $chkIncludeSystem.IsChecked -eq $true)

    Invoke-SdkGridRefresh `
        -TabContent      $TabContent `
        -BridgeFunction  'Get-SPGuiSdkCampaignFilters' `
        -BridgeArgs      @{ IncludeSystem = $includeSystem } `
        -DataSource      $script:SdkFilterDataSource `
        -StatusLabelName 'SdkFilterStatusLabel' `
        -LoadingMessage  'Loading filters...'
}
function Invoke-SdkFilterNew {
    [CmdletBinding()] param($TabContent)

    $dialogPath = Get-XamlPath -FileName 'SdkFilterDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath `
        -ControlNames @('TxtFilterName', 'CboFilterMode', 'TxtFilterDescription') `
        -Defaults      @{ 'LblFilterAction' = 'New Filter'; 'CboFilterMode' = 'INCLUSION' } `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'New Filter cancelled.'
        return
    }

    $filterName = [string]$values['TxtFilterName']
    $mode       = if ($null -ne $values['CboFilterMode']) { [string]$values['CboFilterMode'] } else { 'INCLUSION' }
    $desc       = [string]$values['TxtFilterDescription']

    if ([string]::IsNullOrWhiteSpace($filterName)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Filter Name is required.' -IsError
        return
    }

    $filterBody = @{ name = $filterName; mode = $mode }
    if (-not [string]::IsNullOrWhiteSpace($desc)) { $filterBody['description'] = $desc }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "create filter '$filterName'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd).'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkFilterRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkFilterAction' `
        -BridgeArgs      @{ Action = 'Create'; Filter = $filterBody } `
        -StatusLabelName 'SdkFilterStatusLabel' `
        -RunningMessage  "Creating filter '$filterName'..." `
        -OnSuccess       $onSuccess
}
function Invoke-SdkFilterEdit {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkFilterGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Select a filter first.'
        return
    }

    # Pre-populate dialog with the selected filter's current values.
    $currentMode = if ($null -ne $row._Raw -and $null -ne $row._Raw.mode) { [string]$row._Raw.mode } else { 'INCLUSION' }
    $currentDesc = if ($null -ne $row._Raw -and $null -ne $row._Raw.description) { [string]$row._Raw.description } else { '' }

    $dialogPath = Get-XamlPath -FileName 'SdkFilterDialog.xaml'
    $values = Show-SPGuiDialog -XamlPath $dialogPath `
        -ControlNames @('TxtFilterName', 'CboFilterMode', 'TxtFilterDescription') `
        -Defaults @{
            'LblFilterAction'      = ("Edit Filter - " + $row.Name)
            'TxtFilterName'        = [string]$row.Name
            'CboFilterMode'        = $currentMode
            'TxtFilterDescription' = $currentDesc
        } `
        -OkButtonName 'BtnOK' -CancelButtonName 'BtnCancel'
    if ($null -eq $values) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Edit Filter cancelled.'
        return
    }

    $filterName = [string]$values['TxtFilterName']
    $mode       = if ($null -ne $values['CboFilterMode']) { [string]$values['CboFilterMode'] } else { $currentMode }
    $desc       = [string]$values['TxtFilterDescription']

    if ([string]::IsNullOrWhiteSpace($filterName)) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Filter Name is required.' -IsError
        return
    }

    $filterBody = @{ name = $filterName; mode = $mode }
    if (-not [string]::IsNullOrWhiteSpace($desc)) { $filterBody['description'] = $desc }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "update filter '$($row.Name)'")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd).'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkFilterRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkFilterAction' `
        -BridgeArgs      @{ Action = 'Update'; FilterId = @([string]$row.Id); Filter = $filterBody } `
        -StatusLabelName 'SdkFilterStatusLabel' `
        -RunningMessage  "Updating filter '$filterName'..." `
        -OnSuccess       $onSuccess
}
function Invoke-SdkFilterDelete {
    [CmdletBinding()] param($TabContent)

    $row = Get-SdkSelectedRow -TabContent $TabContent -GridName 'SdkFilterGrid'
    if ($null -eq $row) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Select a filter first.'
        return
    }

    # The bridge Delete dispatcher accepts a string[] (bulk) and enforces the
    # MaxCampaignsPerRun cap; here the grid is single-select so the count is 1.
    $filterIds = @([string]$row.Id)
    $count     = $filterIds.Count

    $confirm = [System.Windows.MessageBox]::Show(
        "Delete $count filter(s) ('$($row.Name)')? This cannot be undone.",
        'Confirm Delete Filter',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'Delete cancelled.'
        return
    }

    if (-not (Test-SdkRequireWhatIfConfirm -ActionDescription "delete $count filter(s)")) {
        Set-SdkSubTabStatus -TabContent $TabContent -StatusName 'SdkFilterStatusLabel' -Message 'cancelled by user (Safety.RequireWhatIfOnProd)'
        return
    }

    $onSuccess = { param($tab) Invoke-SdkFilterRefresh -TabContent $tab }
    Invoke-SdkActionRun `
        -TabContent      $TabContent `
        -BridgeFunction  'Invoke-SPGuiSdkFilterAction' `
        -BridgeArgs      @{ Action = 'Delete'; FilterId = $filterIds } `
        -StatusLabelName 'SdkFilterStatusLabel' `
        -RunningMessage  'Deleting filter(s)...' `
        -OnSuccess       $onSuccess
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

    # --- Defensive WPF Application lifecycle handling ---
    # The launcher's STA-relaunch path spawns a fresh powershell.exe child
    # process for each run, which gets a clean AppDomain. But when invoked
    # from a session that is already STA (PowerShell ISE, a terminal launched
    # with -STA, a re-run inside an STA child), we run in-process and
    # [Application] state from a prior dashboard run persists:
    #   1. [Application]::Current is null but a prior instance existed -> new()
    #      fails with "Cannot create more than one System.Windows.Application
    #      instance in the same AppDomain".
    #   2. [Application]::Current is non-null but Dispatcher has shut down
    #      (default ShutdownMode = OnLastWindowClose) -> ShowDialog() on a
    #      fresh window fails with "Cannot set Visibility ... after a Window
    #      has closed" because WPF treats the application as terminating.
    # Guard for both, set ShutdownMode = OnExplicitShutdown so closing a
    # window does not kill the Application singleton, and surface a clear
    # operator-facing error when the AppDomain is unrecoverable.
    $existingApp = [System.Windows.Application]::Current
    if ($null -eq $existingApp) {
        try {
            $app = [System.Windows.Application]::new()
            $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
        }
        catch [System.InvalidOperationException] {
            throw [System.InvalidOperationException]::new(
                ("WPF Application cannot be created in this PowerShell session because one " +
                 "was already created in this AppDomain and is no longer usable. This " +
                 "happens when a prior Show-SPDashboard run in the same STA session left " +
                 "state behind (e.g. you closed the previous dashboard window and are now " +
                 "re-launching from the same PowerShell prompt). WPF does not permit " +
                 "Application to be re-initialised in a single AppDomain. " +
                 "RESOLUTION: close this PowerShell window and open a fresh one before " +
                 "launching the dashboard again. (Inner: $($_.Exception.Message))"),
                $_.Exception)
        }
    }
    else {
        $dispatcher = $existingApp.Dispatcher
        if ($null -ne $dispatcher -and
            ($dispatcher.HasShutdownStarted -or $dispatcher.HasShutdownFinished)) {
            throw [System.InvalidOperationException]::new(
                ("The WPF Application in this PowerShell session has already shut down " +
                 "(HasShutdownStarted=$($dispatcher.HasShutdownStarted), " +
                 "HasShutdownFinished=$($dispatcher.HasShutdownFinished)) and cannot host " +
                 "another window. WPF Application state is per-AppDomain and is " +
                 "not recoverable once the dispatcher has stopped. " +
                 "RESOLUTION: close this PowerShell window and open a fresh one before " +
                 "launching the dashboard again."))
        }
        $existingApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }

    # Drop any stale window reference from a prior run in this session so
    # Find-Control / status-bar helpers don't walk a closed visual tree.
    $script:MainWindow = $null

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

        # SDK Features tab
        $sdkTab = Find-Control -Parent $window -Name 'SdkTabContent'
        if ($null -ne $sdkTab) {
            Initialize-SdkTab -TabContent $sdkTab
        }

        # Adaptive Reports tab
        $adaptiveTab = Find-Control -Parent $window -Name 'AdaptiveReportsTabContent'
        if ($null -ne $adaptiveTab) {
            Initialize-SPAdaptiveTab -TabContent $adaptiveTab
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

        # Governance tab
        $governanceTab = Find-Control -Parent $window -Name 'GovernanceTabContent'
        if ($null -ne $governanceTab) {
            Initialize-GovernanceTab -TabContent $governanceTab
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
            # Use WPF's DIP-based work area, NOT System.Windows.Forms (which reports
            # PHYSICAL pixels). $this.Width/Height are device-independent units;
            # mixing them with physical px makes this clamp wrong on DPI-scaled
            # displays (125%/150% laptops), leaving the window -- and the right-edge
            # toolbar buttons -- partly off-screen. SystemParameters.WorkArea is in
            # the same DIP units as the window, so the math is correct at any DPI.
            $work = [System.Windows.SystemParameters]::WorkArea
            $margin = 8.0

            # If the window is taller/wider than the work area, shrink it.
            $maxW = $work.Width  - 2 * $margin
            $maxH = $work.Height - 2 * $margin
            if ($this.Width  -gt $maxW) { $this.Width  = $maxW }
            if ($this.Height -gt $maxH) { $this.Height = $maxH }

            # Re-center inside the work area (accounts for taskbar position).
            $this.Left = $work.X + [Math]::Max(0, ($work.Width  - $this.Width)  / 2)
            $this.Top  = $work.Y + [Math]::Max(0, ($work.Height - $this.Height) / 2)
        } catch {
            try {
                Write-SPLog -Message "Window fit-to-screen failed: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.Gui' -Action 'FitToScreen'
            } catch { }
        }
    })

    # Show window. ShowDialog blocks until the user closes the window.
    # Defensive try/finally:
    #   - Translate the cryptic "Cannot set Visibility ... after a Window has
    #     closed" InvalidOperationException into an actionable message.
    #   - Always clear $script:MainWindow on exit so a subsequent in-process
    #     Show-SPDashboard call in the same session starts without stale
    #     references to a closed window.
    try {
        $window.ShowDialog() | Out-Null
    }
    catch [System.InvalidOperationException] {
        $msg = $_.Exception.Message
        if ($msg -match 'Cannot set Visibility|after a Window has closed|EnsureHandle') {
            throw [System.InvalidOperationException]::new(
                ("Failed to show the dashboard window: the WPF Application in this " +
                 "PowerShell session is in a shutdown state, usually because the " +
                 "previous dashboard window in this same STA session was closed. WPF " +
                 "does not allow a new window to be shown after Application has begun " +
                 "shutting down. " +
                 "RESOLUTION: close this PowerShell window and open a fresh one before " +
                 "launching the dashboard again. (Inner: $msg)"),
                $_.Exception)
        }
        throw
    }
    finally {
        $script:MainWindow = $null
    }
}

#endregion

Export-ModuleMember -Function @(
    'Show-SPDashboard',
    'Initialize-SPAdaptiveTab'
)
