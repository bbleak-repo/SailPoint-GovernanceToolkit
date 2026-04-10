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
$script:AuditCampaignDataSource = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:IsAuditRunning          = $false

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

    $campaignGrid   = Find-Control -Parent $TabContent -Name 'CampaignGrid'
    $btnRunSelected = Find-Control -Parent $TabContent -Name 'BtnRunSelected'
    $btnRunAll      = Find-Control -Parent $TabContent -Name 'BtnRunAll'
    $btnRunSmoke    = Find-Control -Parent $TabContent -Name 'BtnRunSmoke'
    $btnRefresh     = Find-Control -Parent $TabContent -Name 'BtnRefreshCampaigns'
    $tagFilter      = Find-Control -Parent $TabContent -Name 'TagFilterCombo'
    $progressBar    = Find-Control -Parent $TabContent -Name 'SuiteProgressBar'
    $progressLabel  = Find-Control -Parent $TabContent -Name 'CurrentTestLabel'
    $resultSummary  = Find-Control -Parent $TabContent -Name 'ResultSummaryText'

    # Load initial data
    Load-CampaignData -Grid $campaignGrid -TagFilter $tagFilter -ProgressLabel $progressLabel

    # Refresh button
    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            Load-CampaignData -Grid $campaignGrid -TagFilter $tagFilter -ProgressLabel $progressLabel
        })
    }

    # Run Selected
    if ($btnRunSelected) {
        $btnRunSelected.Add_Click({
            $selected = @($script:LoadedCampaigns | Where-Object { $_.IsSelected -eq $true })
            if ($selected.Count -eq 0) {
                Set-StatusMessage -Message 'No campaigns selected. Use the checkbox column to select tests.' -IsError
                return
            }
            Invoke-GuiTestRun -Campaigns $selected -ProgressBar $progressBar `
                -ProgressLabel $progressLabel -ResultSummary $resultSummary
        })
    }

    # Run All
    if ($btnRunAll) {
        $btnRunAll.Add_Click({
            $all = @($script:LoadedCampaigns | ForEach-Object { $_._Original })
            if ($all.Count -eq 0) {
                Set-StatusMessage -Message 'No campaigns loaded.' -IsError
                return
            }
            Invoke-GuiTestRun -Campaigns $all -ProgressBar $progressBar `
                -ProgressLabel $progressLabel -ResultSummary $resultSummary
        })
    }

    # Run Smoke
    if ($btnRunSmoke) {
        $btnRunSmoke.Add_Click({
            $smoke = @($script:LoadedCampaigns | Where-Object {
                $tags = $_._Original.Tags -split ',' | ForEach-Object { $_.Trim().ToLower() }
                $tags -contains 'smoke'
            } | ForEach-Object { $_._Original })

            if ($smoke.Count -eq 0) {
                Set-StatusMessage -Message 'No smoke-tagged campaigns found. Add Tags=smoke to test cases.' -IsError
                return
            }
            Invoke-GuiTestRun -Campaigns $smoke -ProgressBar $progressBar `
                -ProgressLabel $progressLabel -ResultSummary $resultSummary
        })
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
        $TagFilter.Items.Add('(All)')
        foreach ($tag in $allTags) {
            $TagFilter.Items.Add($tag)
        }
        $TagFilter.SelectedIndex = 0
    }

    Set-StatusMessage -Message "Loaded $($result.Data.Count) campaign(s) and $($result.Identities.Count) identity(ies)."
}

function Invoke-GuiTestRun {
    [CmdletBinding()]
    param($Campaigns, $ProgressBar, $ProgressLabel, $ResultSummary)

    if ($script:IsRunning) {
        Set-StatusMessage -Message 'A test run is already in progress.' -IsError
        return
    }

    $script:IsRunning = $true
    $correlationID    = [guid]::NewGuid().ToString()

    Set-StatusMessage -Message "Starting test run. CorrelationID: $correlationID"

    if ($null -ne $ProgressBar) {
        $ProgressBar.Value   = 0
        $ProgressBar.Maximum = $Campaigns.Count
        $ProgressBar.Visibility = [System.Windows.Visibility]::Visible
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
        $capturedResult = $suiteResult
        $capturedProgress = $ProgressBar
        $capturedLabel = $ProgressLabel
        $capturedSummary = $ResultSummary

        $dispatcher.Invoke([System.Action]{
            if ($null -ne $capturedProgress) {
                $capturedProgress.Value      = $capturedResult.PassCount + $capturedResult.FailCount + $capturedResult.SkipCount
                $capturedProgress.Visibility = [System.Windows.Visibility]::Visible
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

    # Register callback to clean up and update status when done
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(500)

    $capturedTimer    = $timer
    $capturedPs       = $psInstance
    $capturedRunspace = $runspace
    $capturedAsync    = $asyncResult

    $timer.Add_Tick({
        if ($capturedPs.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')) {
            $capturedTimer.Stop()

            if ($capturedPs.HadErrors) {
                $errMsg = ($capturedPs.Streams.Error | Select-Object -First 1).Exception.Message
                Set-StatusMessage -Message "Test run failed: $errMsg" -IsError
            }
            else {
                Set-StatusMessage -Message 'Test run complete.'
            }

            try {
                $capturedPs.EndInvoke($capturedAsync) | Out-Null
                $capturedPs.Dispose()
                $capturedRunspace.Close()
            }
            catch { }

            $script:IsRunning = $false
        }
    })

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

    $evidenceTree   = Find-Control -Parent $TabContent -Name 'EvidenceTree'
    $btnRefresh     = Find-Control -Parent $TabContent -Name 'BtnRefreshEvidence'
    $btnOpenBrowser = Find-Control -Parent $TabContent -Name 'BtnOpenInBrowser'
    $detailGrid     = Find-Control -Parent $TabContent -Name 'EvidenceDetailGrid'

    if ($btnRefresh) {
        $btnRefresh.Add_Click({
            Load-EvidenceTree -Tree $evidenceTree
        })
    }

    if ($evidenceTree) {
        $evidenceTree.Add_SelectedItemChanged({
            $selectedNode = $evidenceTree.SelectedItem
            if ($null -ne $selectedNode -and $selectedNode.Tag -and (Test-Path $selectedNode.Tag)) {
                Load-EvidenceDetail -FilePath $selectedNode.Tag -DetailGrid $detailGrid
            }
        })
    }

    if ($btnOpenBrowser) {
        $btnOpenBrowser.Add_Click({
            $selectedNode = $evidenceTree.SelectedItem
            if ($null -ne $selectedNode -and $selectedNode.Tag -and (Test-Path $selectedNode.Tag)) {
                Start-Process $selectedNode.Tag
            }
        })
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
        $Tree.Items.Add($rootNode)
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
            $dirNode.Items.Add($fileNode)
        }

        $rootNode.Items.Add($dirNode)
    }

    $rootNode.IsExpanded = $true
    $Tree.Items.Add($rootNode)
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

    $btnSave         = Find-Control -Parent $TabContent -Name 'BtnSaveSettings'
    $btnReset        = Find-Control -Parent $TabContent -Name 'BtnResetDefaults'
    $btnTestConn     = Find-Control -Parent $TabContent -Name 'BtnTestConnectivity'
    $connStatus      = Find-Control -Parent $TabContent -Name 'ConnectivityStatusText'
    $pbBrowserToken  = Find-Control -Parent $TabContent -Name 'PbBrowserToken'
    $btnApplyToken   = Find-Control -Parent $TabContent -Name 'BtnApplyToken'
    $btnClearToken   = Find-Control -Parent $TabContent -Name 'BtnClearToken'
    $tokenStatus     = Find-Control -Parent $TabContent -Name 'BrowserTokenStatus'

    # Load current settings into form
    Load-SettingsForm -TabContent $TabContent

    # Save settings
    if ($btnSave) {
        $btnSave.Add_Click({
            Save-SettingsForm -TabContent $TabContent
        })
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
                Load-SettingsForm -TabContent $TabContent
            }
        })
    }

    # Test connectivity
    if ($btnTestConn) {
        $btnTestConn.Add_Click({
            if ($null -ne $connStatus) {
                $connStatus.Text = 'Testing connectivity...'
                $connStatus.Foreground = [System.Windows.Media.Brushes]::LightGray
            }
            Set-StatusMessage -Message 'Running connectivity test...'

            $statusResult = Test-SPGuiConnectivity -ConfigPath $script:ConfigPath

            if ($null -ne $connStatus) {
                $connStatus.Text = $statusResult.OverallMessage
                $connStatus.Foreground = if ($statusResult.Success) {
                    [System.Windows.Media.Brushes]::LightGreen
                } else {
                    [System.Windows.Media.Brushes]::Salmon
                }
            }
            Set-StatusMessage -Message $statusResult.OverallMessage -IsError:(-not $statusResult.Success)
        })
    }

    # Apply browser token
    if ($btnApplyToken) {
        $btnApplyToken.Add_Click({
            $tokenValue = ''
            if ($null -ne $pbBrowserToken) {
                $tokenValue = $pbBrowserToken.Password
            }

            $result = Set-SPGuiBrowserToken -Token $tokenValue

            if ($null -ne $tokenStatus) {
                $tokenStatus.Text = $result.Message
                $tokenStatus.Foreground = if ($result.Success) {
                    [System.Windows.Media.Brushes]::LightGreen
                } else {
                    [System.Windows.Media.Brushes]::Salmon
                }
            }

            Set-StatusMessage -Message $result.Message -IsError:(-not $result.Success)
        })
    }

    # Clear browser token
    if ($btnClearToken) {
        $btnClearToken.Add_Click({
            Clear-SPAuthToken

            if ($null -ne $pbBrowserToken) {
                $pbBrowserToken.Clear()
            }

            if ($null -ne $tokenStatus) {
                $tokenStatus.Text = 'Browser token cleared. Toolkit will use configured OAuth credentials.'
                $tokenStatus.Foreground = [System.Windows.Media.Brushes]::LightGray
            }

            Set-StatusMessage -Message 'Browser token cleared.'
        })
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
}

function Save-SettingsForm {
    [CmdletBinding()]
    param($TabContent)

    Set-StatusMessage -Message 'Saving settings...'

    $configPath = $script:ConfigPath
    if (-not $configPath) {
        $configPath = Join-Path $script:ToolkitRoot 'Config\settings.json'
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
                ClientSecret  = 'VAULT_OR_ENV_ONLY'
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

    $txtName              = Find-Control -Parent $TabContent -Name 'TxtAuditCampaignName'
    $cboStatus            = Find-Control -Parent $TabContent -Name 'CboAuditStatus'
    $cboTimespan          = Find-Control -Parent $TabContent -Name 'CboAuditTimespan'
    $btnQuery             = Find-Control -Parent $TabContent -Name 'BtnQueryCampaigns'
    $btnClear             = Find-Control -Parent $TabContent -Name 'BtnClearFilter'
    $btnRunAudit          = Find-Control -Parent $TabContent -Name 'BtnRunAudit'
    $btnOpenFolder        = Find-Control -Parent $TabContent -Name 'BtnOpenAuditFolder'
    $btnRefreshReports    = Find-Control -Parent $TabContent -Name 'BtnRefreshAuditReports'
    $auditReportList      = Find-Control -Parent $TabContent -Name 'AuditReportList'

    # Query Campaigns button
    if ($btnQuery) {
        $btnQuery.Add_Click({
            Invoke-AuditCampaignQuery -TabContent $TabContent
        })
    }

    # Clear filter button
    if ($btnClear) {
        $btnClear.Add_Click({
            if ($null -ne $txtName) {
                $txtName.Text       = 'Search by keyword...'
                $txtName.Foreground = [System.Windows.Media.Brushes]::Gray
            }
            if ($null -ne $cboStatus) {
                $cboStatus.SelectedIndex = 0
            }
            if ($null -ne $cboTimespan) {
                $cboTimespan.SelectedIndex = 2
            }
        })
    }

    # Run Audit button
    if ($btnRunAudit) {
        $btnRunAudit.Add_Click({
            Invoke-GuiAuditRun -TabContent $TabContent
        })
    }

    # Open Reports Folder button
    if ($btnOpenFolder) {
        $btnOpenFolder.Add_Click({
            $outputPath = Resolve-AuditOutputPath
            if (-not (Test-Path $outputPath)) {
                [System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
            }
            Start-Process 'explorer.exe' -ArgumentList "`"$outputPath`""
        })
    }

    # Refresh audit reports button
    if ($btnRefreshReports) {
        $btnRefreshReports.Add_Click({
            Load-AuditReportList -TabContent $TabContent
        })
    }

    # Double-click on report list item opens file
    if ($auditReportList) {
        $auditReportList.Add_MouseDoubleClick({
            $selected = $auditReportList.SelectedItem
            if ($null -ne $selected -and $null -ne $selected.Tag -and (Test-Path $selected.Tag)) {
                Start-Process $selected.Tag
            }
        })
    }

    # Populate recent reports on init
    Load-AuditReportList -TabContent $TabContent
}

function Invoke-AuditCampaignQuery {
    <#
    .SYNOPSIS
        Queries ISC for campaigns matching the current filter values and populates
        the AuditCampaignGrid. Synchronous (runs on UI thread).
    #>
    [CmdletBinding()]
    param($TabContent)

    $txtName     = Find-Control -Parent $TabContent -Name 'TxtAuditCampaignName'
    $cboStatus   = Find-Control -Parent $TabContent -Name 'CboAuditStatus'
    $cboTimespan = Find-Control -Parent $TabContent -Name 'CboAuditTimespan'
    $grid        = Find-Control -Parent $TabContent -Name 'AuditCampaignGrid'
    $statusLabel = Find-Control -Parent $TabContent -Name 'AuditStatusLabel'
    $btnRunAudit = Find-Control -Parent $TabContent -Name 'BtnRunAudit'

    Set-StatusMessage -Message 'Querying campaigns...'

    # Extract filter values
    $campaignName = ''
    if ($null -ne $txtName -and $txtName.Text -ne 'Search by keyword...') {
        $campaignName = $txtName.Text.Trim()
    }

    $statusFilter = $null
    if ($null -ne $cboStatus -and $null -ne $cboStatus.SelectedItem) {
        $selectedContent = $cboStatus.SelectedItem.Content
        if ($selectedContent -ne '(All)') {
            $statusFilter = $selectedContent
        }
    }

    $daysBack = 3
    if ($null -ne $cboTimespan -and $null -ne $cboTimespan.SelectedItem) {
        $tagValue = $cboTimespan.SelectedItem.Tag
        if ($null -ne $tagValue) {
            [int]::TryParse($tagValue.ToString(), [ref]$daysBack) | Out-Null
        }
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

        foreach ($mod in @($coreModule, $apiModule, $auditModule, $guiModule)) {
            if (Test-Path $mod) { Import-Module $mod -Force -ErrorAction SilentlyContinue }
        }

        $auditResult = Invoke-SPGuiAudit `
            -SelectedCampaigns      $SelectedCampaigns `
            -CorrelationID          $CorrelationID `
            -OutputPath             $OutputPath `
            -IncludeCampaignReports:$IncludeCampaignReports `
            -IncludeIdentityEvents:$IncludeIdentEvents

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

    $timer.Add_Tick({
        if ($capturedPs.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')) {
            $capturedTimer.Stop()

            if ($capturedPs.HadErrors) {
                $errMsg = ($capturedPs.Streams.Error | Select-Object -First 1).Exception.Message
                Set-StatusMessage -Message "Audit run failed: $errMsg" -IsError
            } else {
                Set-StatusMessage -Message 'Audit run complete.'
            }

            # Re-enable the Run Audit button and hide progress bar
            if ($null -ne $capturedBtn) {
                $capturedBtn.IsEnabled = $true
            }
            if ($null -ne $capturedProg) {
                $capturedProg.Visibility = [System.Windows.Visibility]::Collapsed
            }
            if ($null -ne $capturedPercent2) {
                $capturedPercent2.Text = ''
            }

            # Refresh report list
            Load-AuditReportList -TabContent $capturedTab

            try {
                $capturedPs.EndInvoke($capturedAsync) | Out-Null
                $capturedPs.Dispose()
                $capturedRunspace.Close()
            }
            catch { }

            $script:IsAuditRunning = $false
        }
    })

    $timer.Start()
}

function Load-AuditReportList {
    <#
    .SYNOPSIS
        Populates the AuditReportList ListBox with recent audit report files.
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

    foreach ($report in $result.Data) {
        $item         = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = $report.FileName
        $item.Tag     = $report.FullPath
        $item.ToolTip = "$($report.FullPath) ($($report.SizeKB) KB, $($report.LastModified))"
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

#region Menu Handlers

function Wire-MenuHandlers {
    [CmdletBinding()]
    param()

    # File -> Exit
    $menuExit = Find-Control -Parent $script:MainWindow -Name 'MenuExit'
    if ($menuExit) {
        $menuExit.Add_Click({ $script:MainWindow.Close() })
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

    # Resolve toolkit root from module location
    # Module is at: <toolkit>\Modules\SP.Gui\SP.MainWindow.psm1
    $script:ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:ConfigPath  = $ConfigPath

    if (-not $script:ConfigPath) {
        $script:ConfigPath = Join-Path $script:ToolkitRoot 'Config\settings.json'
    }

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
    }

    # Set initial status
    Set-StatusMessage -Message "Ready | Toolkit root: $($script:ToolkitRoot)"

    # Show window
    $window.ShowDialog() | Out-Null
}

#endregion

Export-ModuleMember -Function @(
    'Show-SPDashboard'
)
