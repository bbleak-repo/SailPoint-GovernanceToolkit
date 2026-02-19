#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - GUI-to-Module Bridge Adapter
.DESCRIPTION
    Provides an adapter layer between the WPF GUI components and the core
    SP.Testing, SP.Api, and SP.Core modules. The bridge translates GUI
    selections (campaign objects, identity hashtables) into module calls
    and returns normalized result structures for GUI display.

    All functions return hashtables compatible with WPF data binding and
    background worker patterns in SP.MainWindow.
.NOTES
    Module:  SP.GuiBridge
    Version: 1.0.0
#>

Set-StrictMode -Version 1

#region Public Bridge Functions

function Invoke-SPGuiTest {
    <#
    .SYNOPSIS
        Execute a selection of campaigns from the GUI test runner.
    .DESCRIPTION
        Bridge function called by the GUI when the user clicks "Run Selected",
        "Run All", or "Run Smoke". Delegates to Invoke-SPTestSuite and returns
        the result in the same structure for GUI display.
    .PARAMETER SelectedCampaigns
        Array of campaign test case PSCustomObjects selected in the DataGrid.
    .PARAMETER Identities
        Hashtable of loaded identities (keyed by IdentityId).
    .PARAMETER CorrelationID
        Correlation ID for this test run. Generate with [guid]::NewGuid().ToString().
    .OUTPUTS
        Same structure as Invoke-SPTestSuite:
        @{Success; Results; PassCount; FailCount; SkipCount; DurationSeconds}
    .EXAMPLE
        $result = Invoke-SPGuiTest -SelectedCampaigns $campaigns -Identities $ids -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [array]$SelectedCampaigns,

        [Parameter(Mandatory)]
        [hashtable]$Identities,

        [Parameter(Mandatory)]
        [string]$CorrelationID
    )

    if ($SelectedCampaigns.Count -eq 0) {
        return @{
            Success         = $false
            Results         = @()
            PassCount       = 0
            FailCount       = 0
            SkipCount       = 0
            DurationSeconds = 0
            Error           = 'No campaigns selected. Select at least one campaign to run.'
        }
    }

    try {
        $suiteResult = Invoke-SPTestSuite `
            -Campaigns          $SelectedCampaigns `
            -Identities         $Identities `
            -CorrelationID      $CorrelationID `
            -WhatIf:$false `
            -StopOnFirstFailure:$false

        return $suiteResult
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiTest failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiTest' -CorrelationID $CorrelationID
        return @{
            Success         = $false
            Results         = @()
            PassCount       = 0
            FailCount       = 0
            SkipCount       = 0
            DurationSeconds = 0
            Error           = "Test suite execution failed: $($_.Exception.Message)"
        }
    }
}

function Get-SPGuiCampaignList {
    <#
    .SYNOPSIS
        Load the full campaign list for display in the GUI DataGrid.
    .DESCRIPTION
        Loads identities and campaigns from the configured CSV paths, applies no
        tag filter, and returns a flat array suitable for WPF DataGrid binding.
        Each item includes all CSV columns plus a display-ready Status field.
    .PARAMETER ConfigPath
        Path to settings.json. If omitted, uses module default resolution.
    .OUTPUTS
        @{Success=$bool; Data=@([PSCustomObject],...); Identities=@{}; Error=$string}
    .EXAMPLE
        $result = Get-SPGuiCampaignList -ConfigPath 'C:\Toolkit\Config\settings.json'
        if ($result.Success) { $dataGrid.ItemsSource = $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    try {
        $configParams = @{}
        if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }

        $config = Get-SPConfig @configParams
        if (Test-SPConfigFirstRun -Config $config) {
            return @{
                Success    = $false
                Data       = @()
                Identities = @{}
                Error      = 'First-run configuration detected. Configure settings.json before launching the GUI.'
            }
        }

        # Resolve CSV paths
        $toolkitRoot = Resolve-SPToolkitRoot
        $identCsv    = Resolve-SPRelativePath -Path $config.Testing.IdentitiesCsvPath -BasePath $toolkitRoot
        $campaignCsv = Resolve-SPRelativePath -Path $config.Testing.CampaignsCsvPath  -BasePath $toolkitRoot

        # Load identities
        $identResult = Import-SPTestIdentities -CsvPath $identCsv
        if (-not $identResult.Success) {
            return @{
                Success    = $false
                Data       = @()
                Identities = @{}
                Error      = "Failed to load identities: $($identResult.Error)"
            }
        }

        # Load all campaigns (no tag filter)
        $campaignResult = Import-SPTestCampaigns -CsvPath $campaignCsv -Identities $identResult.Data
        if (-not $campaignResult.Success) {
            return @{
                Success    = $false
                Data       = @()
                Identities = $identResult.Data
                Error      = "Failed to load campaigns: $($campaignResult.Error)"
            }
        }

        # Decorate with display fields
        $displayItems = foreach ($campaign in $campaignResult.Data) {
            [PSCustomObject]@{
                IsSelected               = $false
                TestId                   = $campaign.TestId
                TestName                 = $campaign.TestName
                CampaignType             = $campaign.CampaignType
                Priority                 = $campaign.Priority
                Tags                     = $campaign.Tags
                DecisionToMake           = $campaign.DecisionToMake
                ReassignBeforeDecide     = $campaign.ReassignBeforeDecide
                ValidateRemediation      = $campaign.ValidateRemediation
                CertifierIdentityId      = $campaign.CertifierIdentityId
                ExpectCampaignStatus     = $campaign.ExpectCampaignStatus
                Status                   = 'Ready'
                LastResult               = ''
                _Original                = $campaign
            }
        }

        return @{
            Success    = $true
            Data       = @($displayItems)
            Identities = $identResult.Data
            Error      = $null
        }
    }
    catch {
        return @{
            Success    = $false
            Data       = @()
            Identities = @{}
            Error      = "Get-SPGuiCampaignList failed: $($_.Exception.Message)"
        }
    }
}

function Get-SPGuiIdentityList {
    <#
    .SYNOPSIS
        Load the identity list for display in the GUI.
    .DESCRIPTION
        Loads identities from the configured CSV path and returns an array
        suitable for WPF DataGrid binding (flattened from hashtable).
    .PARAMETER ConfigPath
        Path to settings.json. If omitted, uses module default resolution.
    .OUTPUTS
        @{Success=$bool; Data=@([PSCustomObject],...); Error=$string}
    .EXAMPLE
        $result = Get-SPGuiIdentityList
        if ($result.Success) { $grid.ItemsSource = $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    try {
        $configParams = @{}
        if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }

        $config = Get-SPConfig @configParams
        if (Test-SPConfigFirstRun -Config $config) {
            return @{
                Success = $false
                Data    = @()
                Error   = 'First-run configuration detected.'
            }
        }

        $toolkitRoot = Resolve-SPToolkitRoot
        $identCsv    = Resolve-SPRelativePath -Path $config.Testing.IdentitiesCsvPath -BasePath $toolkitRoot

        $identResult = Import-SPTestIdentities -CsvPath $identCsv
        if (-not $identResult.Success) {
            return @{
                Success = $false
                Data    = @()
                Error   = $identResult.Error
            }
        }

        # Flatten hashtable to array for grid display
        $displayItems = foreach ($key in ($identResult.Data.Keys | Sort-Object)) {
            $identity = $identResult.Data[$key]
            [PSCustomObject]@{
                IdentityId       = $identity.IdentityId
                DisplayName      = $identity.DisplayName
                Email            = $identity.Email
                Role             = $identity.Role
                CertifierFor     = $identity.CertifierFor
                IsReassignTarget = $identity.IsReassignTarget
            }
        }

        return @{
            Success = $true
            Data    = @($displayItems)
            Error   = $null
        }
    }
    catch {
        return @{
            Success = $false
            Data    = @()
            Error   = "Get-SPGuiIdentityList failed: $($_.Exception.Message)"
        }
    }
}

function Test-SPGuiConnectivity {
    <#
    .SYNOPSIS
        Run a connectivity check for display in the GUI Settings tab.
    .DESCRIPTION
        Wraps the connectivity check logic (config load, token acquisition,
        live API call) and returns a status hashtable suitable for updating
        the GUI status indicator without writing to stdout.
    .PARAMETER ConfigPath
        Path to settings.json. If omitted, uses module default resolution.
    .OUTPUTS
        @{
            Success         = $bool
            Steps           = @(@{Step; Description; Passed; ElapsedMs; Detail})
            OverallMessage  = $string
            Environment     = $string
        }
    .EXAMPLE
        $status = Test-SPGuiConnectivity
        $statusLabel.Content = $status.OverallMessage
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$ConfigPath
    )

    $correlationID = [guid]::NewGuid().ToString()
    $steps         = [System.Collections.Generic.List[hashtable]]::new()
    $overallPass   = $true

    # Helper to record a step
    function Add-Step {
        param([string]$Description, [bool]$Passed, [double]$ElapsedMs, [string]$Detail)
        $steps.Add(@{
            Description = $Description
            Passed      = $Passed
            ElapsedMs   = [math]::Round($ElapsedMs, 0)
            Detail      = $Detail
        })
    }

    # Step 1: Configuration
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $config = $null
    $step1Ok = $false
    $step1Detail = ''
    $configParams = @{}
    if ($ConfigPath) { $configParams['ConfigPath'] = $ConfigPath }

    try {
        $config = Get-SPConfig @configParams
        if (Test-SPConfigFirstRun -Config $config) {
            $step1Detail = 'First-run: settings.json not configured.'
        }
        elseif (Test-SPConfig -Config $config) {
            $step1Ok     = $true
            $step1Detail = "Environment: $($config.Global.EnvironmentName)"
        }
        else {
            $step1Detail = 'Validation failed. Check required fields.'
        }
    }
    catch {
        $step1Detail = "Exception: $($_.Exception.Message)"
    }
    $sw.Stop()
    Add-Step -Description 'Load and validate settings.json' -Passed $step1Ok `
        -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step1Detail
    if (-not $step1Ok) { $overallPass = $false }

    # Step 2: OAuth token
    $step2Ok = $false
    $step2Detail = ''
    if ($step1Ok) {
        $sw.Restart()
        try {
            $tokenResult = Get-SPAuthToken -CorrelationID $correlationID -Force
            if ($tokenResult.Success) {
                $step2Ok     = $true
                $step2Detail = "Mode: $($tokenResult.Data.Mode)"
            }
            else {
                $step2Detail = "Failed: $($tokenResult.Error)"
            }
        }
        catch {
            $step2Detail = "Exception: $($_.Exception.Message)"
        }
        $sw.Stop()
        Add-Step -Description 'Acquire OAuth 2.0 bearer token' -Passed $step2Ok `
            -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step2Detail
        if (-not $step2Ok) { $overallPass = $false }
    }
    else {
        Add-Step -Description 'Acquire OAuth 2.0 bearer token' -Passed $false `
            -ElapsedMs 0 -Detail 'Skipped (Step 1 failed)'
        $overallPass = $false
    }

    # Step 3: Live API call
    $step3Ok = $false
    $step3Detail = ''
    if ($step2Ok) {
        $sw.Restart()
        try {
            $apiResult = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -QueryParams @{ limit = '1' } -CorrelationID $correlationID
            if ($apiResult.Success) {
                $step3Ok     = $true
                $step3Detail = 'GET /v3/campaigns responded OK'
            }
            else {
                $step3Detail = "HTTP $($apiResult.StatusCode): $($apiResult.Error)"
            }
        }
        catch {
            $step3Detail = "Exception: $($_.Exception.Message)"
        }
        $sw.Stop()
        Add-Step -Description 'GET /v3/campaigns?limit=1 (live API)' -Passed $step3Ok `
            -ElapsedMs $sw.Elapsed.TotalMilliseconds -Detail $step3Detail
        if (-not $step3Ok) { $overallPass = $false }
    }
    else {
        Add-Step -Description 'GET /v3/campaigns?limit=1 (live API)' -Passed $false `
            -ElapsedMs 0 -Detail 'Skipped (Step 2 failed)'
        $overallPass = $false
    }

    $envName = if ($config -and $config.PSObject.Properties.Name -contains 'Global') {
        $config.Global.EnvironmentName
    } else { 'Unknown' }

    $overallMessage = if ($overallPass) {
        "Connected to $envName - All checks passed"
    } else {
        "Connection failed - Check errors in steps above"
    }

    return @{
        Success        = $overallPass
        Steps          = $steps.ToArray()
        OverallMessage = $overallMessage
        Environment    = $envName
        CorrelationID  = $correlationID
    }
}

#endregion

#region Internal Helper Functions

function Resolve-SPToolkitRoot {
    <#
    .SYNOPSIS
        Resolves the toolkit root directory from the module's PSScriptRoot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Module is at: <toolkit root>\Modules\SP.Gui\SP.GuiBridge.psm1
    # So toolkit root is two levels up from PSScriptRoot
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

function Resolve-SPRelativePath {
    <#
    .SYNOPSIS
        Converts a relative config path (e.g. .\Config\...) to an absolute path.
    .PARAMETER Path
        The potentially relative path from configuration.
    .PARAMETER BasePath
        The base directory (toolkit root) to resolve from.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $cleaned = $Path.TrimStart('.\').TrimStart('./')
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $cleaned))
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPGuiTest',
    'Get-SPGuiCampaignList',
    'Get-SPGuiIdentityList',
    'Test-SPGuiConnectivity'
)
