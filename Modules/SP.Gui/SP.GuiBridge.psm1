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

#region Audit Bridge Functions

function Get-SPGuiAuditCampaigns {
    <#
    .SYNOPSIS
        Retrieve campaigns from SailPoint ISC for display in the Audit tab DataGrid.
    .DESCRIPTION
        Bridge function that delegates to Get-SPAuditCampaigns and transforms the
        raw API objects into grid-bindable PSCustomObjects suitable for WPF DataGrid
        binding. Each item includes an IsSelected checkbox field and retains a
        reference to the raw campaign object for downstream use in Invoke-SPGuiAudit.
    .PARAMETER CampaignNameContains
        Optional substring (contains) filter. Passed to Get-SPAuditCampaigns
        using the 'co' operator for case-insensitive substring matching.
        Matches campaigns where the keyword appears anywhere in the name.
    .PARAMETER Status
        Optional status filter. Pass "(All)" or empty string to skip filtering.
        Otherwise passed as a single-element array to Get-SPAuditCampaigns.
    .PARAMETER DaysBack
        Number of calendar days to look back. Defaults to 3. Passed to
        Get-SPAuditCampaigns for client-side date filtering.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    .EXAMPLE
        $result = Get-SPGuiAuditCampaigns -Status 'COMPLETED' -DaysBack 7
        if ($result.Success) { $grid.ItemsSource = $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNameContains,

        [Parameter()]
        [string]$Status,

        [Parameter()]
        [int]$DaysBack = 3,

        [Parameter()]
        [string]$CampaignType,

        [Parameter()]
        [string]$CreatedAfter,

        [Parameter()]
        [string]$CreatedBefore
    )

    try {
        $params = @{ DaysBack = $DaysBack }

        if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $params['CampaignNameContains'] = $CampaignNameContains
        }

        if (-not [string]::IsNullOrWhiteSpace($Status) -and $Status -ne '(All)') {
            $params['Status'] = @($Status)
        }

        if (-not [string]::IsNullOrWhiteSpace($CampaignType) -and $CampaignType -ne '(All)') {
            $params['CampaignType'] = $CampaignType
        }

        if (-not [string]::IsNullOrWhiteSpace($CreatedAfter)) {
            $dtAfter = [DateTime]::MinValue
            if ([DateTime]::TryParse($CreatedAfter, [ref]$dtAfter)) {
                $params['CreatedAfter'] = $dtAfter
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($CreatedBefore)) {
            $dtBefore = [DateTime]::MinValue
            if ([DateTime]::TryParse($CreatedBefore, [ref]$dtBefore)) {
                $params['CreatedBefore'] = $dtBefore
            }
        }

        $result = Get-SPAuditCampaigns @params

        if (-not $result.Success) {
            return @{ Success = $false; Data = @(); Error = $result.Error }
        }

        $displayItems = foreach ($campaign in $result.Data) {
            [PSCustomObject]@{
                IsSelected          = $false
                CampaignId          = $campaign.id
                CampaignName        = $campaign.name
                Status              = if ($null -ne $campaign.status)               { [string]$campaign.status }               else { '' }
                Created             = if ($null -ne $campaign.created)              { [string]$campaign.created }              else { '' }
                Completed           = if ($null -ne $campaign.completed)            { [string]$campaign.completed }            else { '' }
                TotalCertifications = if ($null -ne $campaign.totalCertifications)  { [int]$campaign.totalCertifications }     else { 0 }
                _RawCampaign        = $campaign
            }
        }

        return @{ Success = $true; Data = @($displayItems); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiAuditCampaigns failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Get-SPGuiAuditCampaigns'
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiAuditCampaigns failed: $($_.Exception.Message)" }
    }
}

function Invoke-SPGuiAudit {
    <#
    .SYNOPSIS
        Orchestrate a full campaign audit for campaigns selected in the Audit tab.
    .DESCRIPTION
        Bridge function that mirrors the orchestration logic of Invoke-SPCampaignAudit.ps1
        but is callable from the WPF GUI background worker. For each selected campaign it:
          1. Retrieves certifications via Get-SPAuditCertifications
          2. Retrieves per-certification items via Get-SPAuditCertificationItems
          3. Wraps items for Group-SPAuditDecisions
          4. Optionally downloads legacy campaign reports
          5. Optionally retrieves identity provisioning events for revoked identities
          6. Categorizes decisions, reviewer actions, and identity events
          7. Exports per-campaign HTML and text reports
          8. Exports a combined HTML report when multiple campaigns are audited
          9. Appends a JSONL audit trail

        Returns a summary hashtable that the GUI worker can surface in the status bar.
    .PARAMETER SelectedCampaigns
        Array of PSCustomObjects returned by Get-SPGuiAuditCampaigns (must include
        the _RawCampaign property).
    .PARAMETER IncludeCampaignReports
        When present, calls Get-SPAuditCampaignReport (v3-first with legacy fallback)
        for each standard report type: CAMPAIGN_STATUS_REPORT and CERTIFICATION_SIGNOFF_REPORT.
    .PARAMETER IncludeIdentityEvents
        When present, calls Get-SPAuditIdentityEvents for each identity whose
        access was revoked during the campaign.
    .PARAMETER IncludeLeadershipRollup
        When present, generates leadership rollup reports (executive summary +
        per-director HTML) after the standard audit pipeline completes. Walks the
        ISC org tree via Build-SPOrgTree and groups decisions by leader.
        Requires SP.DeltaCert module for Build-SPOrgTree.
    .PARAMETER LeadershipDepth
        Maximum number of levels to walk above reviewed identities when building
        the org tree. Default: 3 (identity -> manager -> director -> VP).
    .PARAMETER IdentityEventDays
        Days back to search for identity events. Defaults to 2. Only used when
        -IncludeIdentityEvents is specified.
    .PARAMETER OutputPath
        Directory to write HTML, text, and JSONL output. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{
            Success          = $bool
            CampaignsAudited = $int
            OutputPath       = $string
            DurationSeconds  = $double
            FilesWritten     = $int
            Error            = $string
        }
    .EXAMPLE
        $result = Invoke-SPGuiAudit -SelectedCampaigns $selected -OutputPath 'C:\Toolkit\Audit' -CorrelationID $cid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object[]]$SelectedCampaigns,

        [Parameter()]
        [switch]$IncludeCampaignReports,

        [Parameter()]
        [switch]$IncludeIdentityEvents,

        [Parameter()]
        [switch]$IncludeLeadershipRollup,

        [Parameter()]
        [int]$LeadershipDepth = 3,

        [Parameter()]
        [int]$LeadershipStartLevel = -1,

        [Parameter()]
        [int]$IdentityEventDays = 2,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID,

        [Parameter()]
        [ValidateSet('Summary', 'Detailed', 'Verbose')]
        [string]$DetailLevel = 'Verbose'
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($SelectedCampaigns.Count -eq 0) {
            return @{
                Success          = $false
                CampaignsAudited = 0
                OutputPath       = $OutputPath
                DurationSeconds  = 0
                FilesWritten     = 0
                Error            = 'No campaigns selected. Select at least one campaign to audit.'
            }
        }

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $toolkitRoot = Resolve-SPToolkitRoot
            $OutputPath  = Join-Path $toolkitRoot 'Audit'
        }

        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        Write-SPLog -Message "Invoke-SPGuiAudit started: $($SelectedCampaigns.Count) campaign(s), OutputPath='$OutputPath'" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID

        $allCampaignAudits = [System.Collections.Generic.List[object]]::new()
        $allWrittenFiles   = [System.Collections.Generic.List[string]]::new()
        $jsonlEvents       = [System.Collections.Generic.List[object]]::new()

        foreach ($campaign in $SelectedCampaigns) {
            $rawCampaign = $campaign._RawCampaign
            $campId      = $rawCampaign.id
            $campName    = $rawCampaign.name

            Write-SPLog -Message "Auditing campaign '$campName' ($campId)" `
                -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID

            # --- Certifications ---
            $certResult     = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $CorrelationID
            $certifications = @()
            if ($certResult.Success -and $null -ne $certResult.Data) {
                $certifications = @($certResult.Data)
            }
            else {
                Write-SPLog -Message "Could not retrieve certifications for '$campId': $($certResult.Error)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
            }

            # --- Certification items (wrapped for Group-SPAuditDecisions) ---
            $wrappedItems = [System.Collections.Generic.List[object]]::new()
            foreach ($cert in $certifications) {
                $certName  = if ($null -ne $cert.name) { $cert.name } else { '' }
                $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $CorrelationID
                if ($itemResult.Success -and $null -ne $itemResult.Data) {
                    foreach ($rawItem in $itemResult.Data) {
                        $wrappedItems.Add(@{
                            Item              = $rawItem
                            CertificationId   = $cert.id
                            CertificationName = $certName
                            CampaignName      = $campName
                        })
                    }
                }
                else {
                    Write-SPLog -Message "Could not retrieve items for certification '$($cert.id)': $($itemResult.Error)" `
                        -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                }
            }

            # --- Optional: Campaign reports (v3-first with legacy fallback) ---
            $campaignReports = $null
            if ($IncludeCampaignReports) {
                $campaignReports = @{}
                foreach ($reportType in @('CAMPAIGN_STATUS_REPORT', 'CERTIFICATION_SIGNOFF_REPORT')) {
                    $rptResult = Get-SPAuditCampaignReport -CampaignId $campId -ReportType $reportType `
                        -CorrelationID $CorrelationID
                    if ($rptResult.Success) {
                        $campaignReports[$reportType] = $rptResult.Data
                    }
                    else {
                        Write-SPLog -Message "Campaign report '$reportType' unavailable for '$campId': $($rptResult.Error)" `
                            -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                    }
                }
                if ($campaignReports.Count -eq 0) {
                    $campaignReports = $null
                }
            }

            # --- Optional: Identity provisioning events for revoked identities ---
            $allIdentityEvents = @()
            if ($IncludeIdentityEvents) {
                $revokedIds = @($wrappedItems | ForEach-Object {
                    $item = $_.Item
                    if ($null -ne $item.decision -and $item.decision -eq 'REVOKE' -and
                        $null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) {
                        $item.identitySummary.id
                    }
                } | Where-Object { $_ } | Sort-Object -Unique)

                foreach ($identityId in $revokedIds) {
                    $evtResult = Get-SPAuditIdentityEvents -IdentityId $identityId `
                        -DaysBack $IdentityEventDays -CorrelationID $CorrelationID
                    if ($evtResult.Success -and $null -ne $evtResult.Data) {
                        foreach ($evt in $evtResult.Data) {
                            $allIdentityEvents += $evt
                        }
                    }
                    else {
                        Write-SPLog -Message "Could not retrieve identity events for '$identityId': $($evtResult.Error)" `
                            -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                    }
                }
            }

            # --- Resolve identity accounts for UPN/sAMAccountName ---
            $uniqueIdentityIds = @($wrappedItems | ForEach-Object {
                $item = $_.Item
                $iid = if ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.identityId) { $item.identitySummary.identityId }
                       elseif ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) { $item.identitySummary.id }
                       else { $null }
                $iid
            } | Where-Object { $_ } | Sort-Object -Unique)

            $accountMap = @{}
            if ($uniqueIdentityIds.Count -gt 0) {
                $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $uniqueIdentityIds -CorrelationID $CorrelationID
                if ($acctResult.Success) { $accountMap = $acctResult.Data }
                else {
                    Write-SPLog -Message "Account resolution failed (non-fatal): $($acctResult.Error)" `
                        -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                }
            }

            # --- Categorize ---
            $decisions        = Group-SPAuditDecisions         -Items $wrappedItems.ToArray() -AccountMap $accountMap
            $reviewers        = Group-SPReviewerActions        -Certifications $certifications
            $reviewerMetrics  = Measure-SPAuditReviewerMetrics -Certifications $certifications
            $eventGroups      = Group-SPAuditIdentityEvents    -Events $allIdentityEvents
            $remediationProof = Group-SPAuditRemediationProof  -Items $wrappedItems.ToArray() -Certifications $certifications -AccountMap $accountMap

            # --- Build campaign audit hashtable (keys match Export-SPAuditHtml schema) ---
            $campaignAudit = @{
                CampaignName             = $campName
                CampaignId               = $campId
                Status                   = if ($null -ne $rawCampaign.status)               { [string]$rawCampaign.status }           else { '' }
                Created                  = if ($null -ne $rawCampaign.created)              { [string]$rawCampaign.created }          else { '' }
                Completed                = if ($null -ne $rawCampaign.completed)            { [string]$rawCampaign.completed }        else { '' }
                TotalCertifications      = if ($null -ne $rawCampaign.totalCertifications)  { [int]$rawCampaign.totalCertifications } else { 0 }
                Decisions                = $decisions
                Reviewers                = $reviewers
                ReviewerMetrics          = $reviewerMetrics
                Events                   = $eventGroups
                RemediationProof         = $remediationProof
                CampaignReports          = $campaignReports
                CampaignReportsAvailable = ($null -ne $campaignReports)
            }

            # --- Per-campaign export ---
            $htmlFiles = Export-SPAuditHtml -CampaignAudits @($campaignAudit) `
                -OutputPath $OutputPath -CorrelationID $CorrelationID -DetailLevel $DetailLevel
            Export-SPAuditText -CampaignAudits @($campaignAudit) `
                -OutputPath $OutputPath -CorrelationID $CorrelationID

            foreach ($f in $htmlFiles) { $allWrittenFiles.Add($f) }

            $allCampaignAudits.Add($campaignAudit)

            # Accumulate a JSONL event per campaign for the audit trail
            $jsonlEvents.Add(@{
                Action     = 'CampaignAudited'
                CampaignId = $campId
                CampaignName = $campName
                DecisionsApproved = @($decisions.Approved).Count
                DecisionsRevoked  = @($decisions.Revoked).Count
                DecisionsPending  = @($decisions.Pending).Count
            })
        }

        # --- Combined HTML if multiple campaigns ---
        if ($allCampaignAudits.Count -gt 1) {
            $combinedFiles = Export-SPAuditHtml -CampaignAudits $allCampaignAudits.ToArray() `
                -OutputPath $OutputPath -Combined -CorrelationID $CorrelationID -DetailLevel $DetailLevel
            foreach ($f in $combinedFiles) { $allWrittenFiles.Add($f) }
        }

        # --- Leadership rollup reports (supplementary) ---
        if ($IncludeLeadershipRollup) {
            $leadershipOutputPath = Join-Path $OutputPath 'leadership'
            if (-not (Test-Path -Path $leadershipOutputPath -PathType Container)) {
                New-Item -Path $leadershipOutputPath -ItemType Directory -Force | Out-Null
            }

            if (-not (Get-Command -Name Build-SPOrgTree -ErrorAction SilentlyContinue)) {
                Write-SPLog -Message "Leadership rollup skipped: Build-SPOrgTree not available (SP.DeltaCert not loaded)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
            }
            else {
                # Collect all unique identity IDs from all campaigns
                $allIdentityIds = [System.Collections.Generic.List[string]]::new()
                foreach ($audit in $allCampaignAudits) {
                    $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
                    if ($null -eq $d) { continue }
                    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                        if (-not $d.ContainsKey($category) -or $null -eq $d[$category]) { continue }
                        foreach ($item in @($d[$category])) {
                            if ($null -ne $item.IdentityId -and -not [string]::IsNullOrWhiteSpace($item.IdentityId)) {
                                if (-not $allIdentityIds.Contains($item.IdentityId)) {
                                    $allIdentityIds.Add($item.IdentityId)
                                }
                            }
                        }
                    }
                }

                if ($allIdentityIds.Count -eq 0) {
                    Write-SPLog -Message "Leadership rollup skipped: no identity IDs in decisions" `
                        -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                }
                else {
                    $orgTreeResult = Build-SPOrgTree -IdentityIds $allIdentityIds.ToArray() `
                        -MaxDepth $LeadershipDepth -CorrelationID $CorrelationID

                    if (-not $orgTreeResult.Success) {
                        Write-SPLog -Message "Leadership rollup: org tree build failed: $($orgTreeResult.Error)" `
                            -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                    }
                    else {
                        $orgTree = $orgTreeResult.Data

                        # Merge decisions across all campaigns
                        $mergedDecisions = @{
                            Approved = [System.Collections.Generic.List[object]]::new()
                            Revoked  = [System.Collections.Generic.List[object]]::new()
                            Pending  = [System.Collections.Generic.List[object]]::new()
                        }
                        foreach ($audit in $allCampaignAudits) {
                            $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
                            if ($null -eq $d) { continue }
                            foreach ($category in @('Approved', 'Revoked', 'Pending')) {
                                if ($d.ContainsKey($category) -and $null -ne $d[$category]) {
                                    foreach ($item in @($d[$category])) {
                                        $mergedDecisions[$category].Add($item)
                                    }
                                }
                            }
                        }
                        $mergedDecisionsHt = @{
                            Approved = $mergedDecisions['Approved'].ToArray()
                            Revoked  = $mergedDecisions['Revoked'].ToArray()
                            Pending  = $mergedDecisions['Pending'].ToArray()
                        }

                        # Merge reviewer metrics across all campaigns
                        $mergedReviewerMetrics = $null
                        if ($allCampaignAudits.Count -eq 1 -and $allCampaignAudits[0].ContainsKey('ReviewerMetrics')) {
                            $mergedReviewerMetrics = $allCampaignAudits[0]['ReviewerMetrics']
                        }
                        elseif ($allCampaignAudits.Count -gt 1) {
                            $combinedMetrics = [System.Collections.Generic.List[object]]::new()
                            foreach ($audit in $allCampaignAudits) {
                                if ($audit.ContainsKey('ReviewerMetrics') -and $null -ne $audit['ReviewerMetrics'] -and
                                    $null -ne $audit['ReviewerMetrics']['ReviewerMetrics']) {
                                    foreach ($rm in @($audit['ReviewerMetrics']['ReviewerMetrics'])) {
                                        $combinedMetrics.Add($rm)
                                    }
                                }
                            }
                            if ($combinedMetrics.Count -gt 0) {
                                $mergedReviewerMetrics = @{ ReviewerMetrics = $combinedMetrics.ToArray() }
                            }
                        }

                        $groupParams = @{
                            Decisions = $mergedDecisionsHt
                            OrgTree   = $orgTree
                        }
                        if ($null -ne $mergedReviewerMetrics) {
                            $groupParams['ReviewerMetrics'] = $mergedReviewerMetrics
                        }
                        $leadershipData = Group-SPAuditByLeadership @groupParams

                        # Build campaign name and date range for report headers
                        $leadershipCampaignName = if ($allCampaignAudits.Count -eq 1) {
                            $allCampaignAudits[0]['CampaignName']
                        }
                        else {
                            "$($allCampaignAudits.Count) Campaigns (Combined)"
                        }
                        $leadershipDateRange = ''
                        $allCreated = @($allCampaignAudits | ForEach-Object {
                            if ($_['Created']) { $_['Created'] }
                        } | Where-Object { $_ } | Sort-Object)
                        if ($allCreated.Count -gt 0) {
                            $startDate = ($allCreated[0] -split 'T')[0]
                            $endDate   = ((Get-Date).ToString('yyyy-MM-dd'))
                            $leadershipDateRange = "$startDate to $endDate"
                        }

                        # Determine start and lowest levels for per-level generation
                        $topLevel = $leadershipData.TopLevel
                        $resolvedStartLevel = if ($LeadershipStartLevel -ge 2) {
                            [Math]::Min($LeadershipStartLevel, $topLevel)
                        } else { $topLevel }
                        $resolvedLowestLevel = 2

                        # Generate per-level reports
                        for ($lvl = $resolvedStartLevel; $lvl -ge $resolvedLowestLevel; $lvl--) {
                            if (-not $leadershipData.Levels.ContainsKey($lvl)) { continue }
                            $lvlPaths = Export-SPLeadershipLevelHtml `
                                -LeadershipData $leadershipData `
                                -Decisions $mergedDecisionsHt `
                                -OrgTree $orgTree `
                                -Level $lvl `
                                -StartLevel $resolvedStartLevel `
                                -LowestLevel $resolvedLowestLevel `
                                -CampaignName $leadershipCampaignName `
                                -DateRange $leadershipDateRange `
                                -OutputPath $leadershipOutputPath `
                                -CorrelationID $CorrelationID `
                                -DetailLevel $DetailLevel
                            foreach ($lp in @($lvlPaths)) {
                                $allWrittenFiles.Add($lp)
                            }
                        }

                        # Backward-compatible: executive summary + director reports
                        $execPath = Export-SPLeadershipExecutiveHtml `
                            -LeadershipData $leadershipData `
                            -CampaignName $leadershipCampaignName `
                            -DateRange $leadershipDateRange `
                            -OutputPath $leadershipOutputPath `
                            -CorrelationID $CorrelationID
                        $allWrittenFiles.Add($execPath)

                        $directorCount = @($leadershipData.Directors.Keys | Where-Object { $_ -ne '__unmanaged__' }).Count
                        if ($directorCount -gt 0) {
                            $dirPaths = Export-SPLeadershipDirectorHtml `
                                -LeadershipData $leadershipData `
                                -Decisions $mergedDecisionsHt `
                                -OrgTree $orgTree `
                                -CampaignName $leadershipCampaignName `
                                -DateRange $leadershipDateRange `
                                -OutputPath $leadershipOutputPath `
                                -CorrelationID $CorrelationID `
                                -DetailLevel $DetailLevel
                            foreach ($dp in @($dirPaths)) {
                                $allWrittenFiles.Add($dp)
                            }
                        }

                        Write-SPLog -Message "Leadership rollup generated: per-level + exec summary + $directorCount director report(s)" `
                            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
                    }
                }
            }
        }

        # --- JSONL audit trail ---
        $jsonlPath = Export-SPAuditJsonl -OutputPath $OutputPath -Events $jsonlEvents.ToArray() `
            -CorrelationID $CorrelationID
        $allWrittenFiles.Add($jsonlPath)

        $sw.Stop()

        Write-SPLog -Message "Invoke-SPGuiAudit complete: $($allCampaignAudits.Count) campaign(s), $($allWrittenFiles.Count) file(s)" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID

        return @{
            Success          = $true
            CampaignsAudited = $allCampaignAudits.Count
            OutputPath       = $OutputPath
            DurationSeconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            FilesWritten     = $allWrittenFiles.Count
            Error            = $null
        }
    }
    catch {
        $sw.Stop()
        Write-SPLog -Message "Invoke-SPGuiAudit failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiAudit' -CorrelationID $CorrelationID
        return @{
            Success          = $false
            CampaignsAudited = 0
            OutputPath       = $OutputPath
            DurationSeconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            FilesWritten     = 0
            Error            = "Invoke-SPGuiAudit failed: $($_.Exception.Message)"
        }
    }
}

function Get-SPGuiAuditReports {
    <#
    .SYNOPSIS
        Enumerate recently generated audit HTML reports for display in the Audit tab.
    .DESCRIPTION
        Scans AuditOutputPath for HTML files and returns the most recent 20,
        sorted newest-first, as PSCustomObjects suitable for WPF DataGrid binding.
        Returns an empty Data array (not an error) when the directory does not exist.
    .PARAMETER AuditOutputPath
        Directory to scan for HTML files. Subdirectories are included (-Recurse).
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    .EXAMPLE
        $result = Get-SPGuiAuditReports -AuditOutputPath 'C:\Toolkit\Audit'
        if ($result.Success) { $grid.ItemsSource = $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$AuditOutputPath
    )

    try {
        if ([string]::IsNullOrWhiteSpace($AuditOutputPath) -or -not (Test-Path -Path $AuditOutputPath -PathType Container)) {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $files = Get-ChildItem -Path $AuditOutputPath -Filter '*.html' -Recurse -File -ErrorAction Stop |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 20

        $items = foreach ($file in $files) {
            [PSCustomObject]@{
                FileName     = $file.Name
                FullPath     = $file.FullName
                LastModified = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                SizeKB       = [math]::Round($file.Length / 1024, 1)
            }
        }

        return @{ Success = $true; Data = @($items); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiAuditReports failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Get-SPGuiAuditReports'
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiAuditReports failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Delta Cert Bridge Functions

function Invoke-SPGuiDeltaCertRun {
    <#
    .SYNOPSIS
        Execute a delta cert run from the GUI.
    .DESCRIPTION
        Bridge function that wraps Invoke-SPDeltaCertRun for the WPF GUI.
        Transforms the result into a display-ready PSCustomObject suitable
        for DataGrid binding.
    .PARAMETER SourceIds
        Array of AD source IDs to scan for GRANT_ACCESS events.
    .PARAMETER HoursBack
        Number of hours to look back for grant events. Default: 24.
    .PARAMETER DeadlineDays
        Number of days for campaign deadline. Default: 2.
    .PARAMETER ReviewerMode
        Reviewer routing mode: Manager or SourceOwner. Default: Manager.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{ Success=$bool; Data=[PSCustomObject]; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [int]$DeadlineDays = 2,

        [Parameter()]
        [ValidateSet('Manager', 'SourceOwner')]
        [string]$ReviewerMode = 'Manager',

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertRun started: SourceIds=$($SourceIds -join ','), HoursBack=$HoursBack, ReviewerMode=$ReviewerMode" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertRun' -CorrelationID $CorrelationID

        $runParams = @{
            SourceIds    = $SourceIds
            HoursBack    = $HoursBack
            DeadlineDays = $DeadlineDays
            ReviewerMode = $ReviewerMode
            CorrelationID = $CorrelationID
        }

        $result = Invoke-SPDeltaCertRun @runParams

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; Error = $result.Error }
        }

        $displayItem = [PSCustomObject]@{
            Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            CampaignsCreated = $result.Data.CampaignsCreated
            Identities       = $result.Data.IdentityCount
            ManagerGroups    = $result.Data.ManagerGroups
            Reason           = $result.Data.Reason
            Errors           = @($result.Data.Errors).Count
        }

        return @{ Success = $true; Data = $displayItem; Error = $null }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertRun failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertRun'
        return @{ Success = $false; Data = $null; Error = "Invoke-SPGuiDeltaCertRun failed: $($_.Exception.Message)" }
    }
}

function Invoke-SPGuiDeltaCertCleanup {
    <#
    .SYNOPSIS
        Run delta cert cleanup (auto-complete stale campaigns) from the GUI.
    .DESCRIPTION
        Bridge function that wraps Invoke-SPDeltaCertCleanup for the WPF GUI.
        Returns a summary suitable for status bar display.
    .PARAMETER CampaignNamePrefix
        Campaign name prefix to search for. Default: 'AD Delta Cert'.
    .PARAMETER DaysStale
        Number of days before a campaign is considered stale. Default: 3.
    .PARAMETER CorrelationID
        Correlation ID for log tracing.
    .OUTPUTS
        @{ Success=$bool; Data=@{Completed; StillActive; Errors}; Message=$string; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$DaysStale = 3,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertCleanup started: Prefix='$CampaignNamePrefix', DaysStale=$DaysStale" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertCleanup' -CorrelationID $CorrelationID

        $result = Invoke-SPDeltaCertCleanup -CampaignNamePrefix $CampaignNamePrefix `
            -DaysStale $DaysStale -CorrelationID $CorrelationID

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; Message = $null; Error = $result.Error }
        }

        $completedCount  = @($result.Data.Completed).Count
        $stillActiveCount = @($result.Data.StillActive).Count
        $errorCount      = @($result.Data.Errors).Count
        $message = "Cleanup complete: $completedCount completed, $stillActiveCount still active, $errorCount error(s)"

        return @{
            Success = $true
            Data    = $result.Data
            Message = $message
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertCleanup failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertCleanup'
        return @{ Success = $false; Data = $null; Message = $null; Error = "Invoke-SPGuiDeltaCertCleanup failed: $($_.Exception.Message)" }
    }
}

function Invoke-SPGuiDeltaCertEscalate {
    <#
    .SYNOPSIS
        Run delta cert escalation (detect stale certs + reassign) from the GUI.
    .DESCRIPTION
        Bridge function that wraps Get-SPDeltaCertStaleCertifications and
        Invoke-SPDeltaCertEscalate for the WPF GUI. Performs both stale detection
        and escalation in a single call for GUI convenience.
    .PARAMETER CampaignNamePrefix
        Campaign name prefix to search for. Default: 'AD Delta Cert'.
    .PARAMETER StaleHours
        Hours without reviewer action before a cert is considered stale. Default: 24.
    .PARAMETER MaxEscalationLevels
        Maximum org tree levels to escalate. Default: 2.
    .PARAMETER CorrelationID
        Correlation ID for log tracing.
    .OUTPUTS
        @{ Success=$bool; Data=@{StaleCerts; Escalated; Skipped; Errors}; Message=$string; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$CampaignNamePrefix = 'AD Delta Cert',

        [Parameter()]
        [int]$StaleHours = 24,

        [Parameter()]
        [int]$MaxEscalationLevels = 2,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertEscalate started: Prefix='$CampaignNamePrefix', StaleHours=$StaleHours" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertEscalate' -CorrelationID $CorrelationID

        # Step 1: Detect stale certifications
        $staleCerts = Get-SPDeltaCertStaleCertifications `
            -CampaignNamePrefix $CampaignNamePrefix `
            -StaleHours $StaleHours `
            -CorrelationID $CorrelationID

        if ($null -eq $staleCerts -or @($staleCerts).Count -eq 0) {
            return @{
                Success = $true
                Data    = @{ StaleCerts = 0; Escalated = @(); Skipped = @(); Errors = @() }
                Message = 'No stale certifications found. Nothing to escalate.'
                Error   = $null
            }
        }

        $staleCount = @($staleCerts).Count

        # Step 2: Escalate
        $result = Invoke-SPDeltaCertEscalate `
            -StaleCertifications $staleCerts `
            -MaxEscalationLevels $MaxEscalationLevels `
            -CorrelationID $CorrelationID

        if (-not $result.Success) {
            return @{ Success = $false; Data = $null; Message = $null; Error = $result.Error }
        }

        $escalatedCount = @($result.Data.Escalated).Count
        $skippedCount   = @($result.Data.Skipped).Count
        $errorCount     = @($result.Data.Errors).Count
        $message = "Escalation complete: $staleCount stale, $escalatedCount escalated, $skippedCount skipped, $errorCount error(s)"

        return @{
            Success = $true
            Data    = @{
                StaleCerts = $staleCount
                Escalated  = $result.Data.Escalated
                Skipped    = $result.Data.Skipped
                Errors     = $result.Data.Errors
            }
            Message = $message
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiDeltaCertEscalate failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaCertEscalate'
        return @{ Success = $false; Data = $null; Message = $null; Error = "Invoke-SPGuiDeltaCertEscalate failed: $($_.Exception.Message)" }
    }
}

function Get-SPGuiDeltaCertHistory {
    <#
    .SYNOPSIS
        Read recent delta cert run history from the JSONL audit trail.
    .DESCRIPTION
        Reads the deltacert-audit.jsonl file and returns the most recent 20
        entries as PSCustomObjects suitable for display in the GUI ListBox
        or DataGrid.
    .PARAMETER OutputPath
        Directory containing deltacert-audit.jsonl. If not specified, reads
        from DeltaCert.OutputPath in config.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject],...); Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$OutputPath
    )

    try {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $toolkitRoot = Resolve-SPToolkitRoot
            try {
                $configPath = Join-Path $toolkitRoot 'Config\settings.json'
                $config = Get-SPConfig -ConfigPath $configPath
                if ($null -ne $config -and
                    $config.PSObject.Properties.Name -contains 'DeltaCert' -and
                    $null -ne $config.DeltaCert -and
                    $config.DeltaCert.PSObject.Properties.Name -contains 'OutputPath' -and
                    -not [string]::IsNullOrWhiteSpace($config.DeltaCert.OutputPath)) {
                    $OutputPath = Resolve-SPRelativePath -Path $config.DeltaCert.OutputPath -BasePath $toolkitRoot
                }
            }
            catch { }

            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                $OutputPath = Join-Path $toolkitRoot 'DeltaCert'
            }
        }

        $jsonlPath = Join-Path $OutputPath 'deltacert-audit.jsonl'

        if (-not (Test-Path -Path $jsonlPath -PathType Leaf)) {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        $lines = @(Get-Content -Path $jsonlPath -Encoding UTF8 -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        # Take last 20 entries (most recent)
        if ($lines.Count -gt 20) {
            $lines = $lines[($lines.Count - 20)..($lines.Count - 1)]
        }

        # Parse and reverse so newest first
        $items = [System.Collections.Generic.List[PSObject]]::new()
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try {
                $entry = $lines[$i] | ConvertFrom-Json
                $items.Add([PSCustomObject]@{
                    Timestamp        = if ($null -ne $entry.Timestamp) { [string]$entry.Timestamp } else { '' }
                    CampaignsCreated = if ($null -ne $entry.CampaignsCreated) { [int]$entry.CampaignsCreated } else { 0 }
                    Identities       = if ($null -ne $entry.IdentitiesProcessed) { [int]$entry.IdentitiesProcessed } else { 0 }
                    ManagerGroups    = if ($null -ne $entry.ManagerGroups) { [int]$entry.ManagerGroups } else { 0 }
                    Reason           = if ($null -ne $entry.Reason) { [string]$entry.Reason } else { '' }
                    Errors           = if ($null -ne $entry.Errors) { @($entry.Errors).Count } else { 0 }
                })
            }
            catch {
                # Skip malformed JSONL lines
            }
        }

        return @{ Success = $true; Data = @($items); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiDeltaCertHistory failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Get-SPGuiDeltaCertHistory'
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiDeltaCertHistory failed: $($_.Exception.Message)" }
    }
}

function Invoke-SPGuiDeltaReport {
    <#
    .SYNOPSIS
        Generate a delta certification report from the GUI.
    .DESCRIPTION
        Bridge function that wraps Get-SPDeltaReportData and Export-SPDeltaReportHtml
        for the WPF GUI. Gathers delta data for the configured time window and
        source IDs, then generates HTML + JSONL output.
    .PARAMETER SourceIds
        Array of AD source IDs to include in the report.
    .PARAMETER HoursBack
        Number of hours to look back for changes. Default: 24.
    .PARAMETER OutputPath
        Directory for output files. Created if absent.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{ Success=$bool; Data=@{HtmlPath; JsonlPath; Summary}; Message=$string; Error=$string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$HoursBack = 24,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        Write-SPLog -Message "Invoke-SPGuiDeltaReport started: SourceIds=$($SourceIds -join ','), HoursBack=$HoursBack" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaReport' -CorrelationID $CorrelationID

        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $tkRoot     = Resolve-SPToolkitRoot
            $OutputPath = Join-Path $tkRoot 'DeltaCert\reports'
        }

        $dataResult = Get-SPDeltaReportData -SourceIds $SourceIds -HoursBack $HoursBack `
            -CorrelationID $CorrelationID

        if (-not $dataResult.Success) {
            return @{ Success = $false; Data = $null; Message = $null; Error = $dataResult.Error }
        }

        $reportData = $dataResult.Data

        $exportResult = Export-SPDeltaReportHtml -ReportData $reportData -OutputPath $OutputPath `
            -CorrelationID $CorrelationID

        $grantCount   = @($reportData.NewGrants).Count
        $revokeCount  = @($reportData.Revocations).Count
        $pendingCount = @($reportData.PendingReviews).Count
        $anomalyCount = @($reportData.Anomalies).Count

        $message = "Delta report generated: $grantCount grants, $revokeCount revocations, $pendingCount pending, $anomalyCount anomalies"

        return @{
            Success = $true
            Data    = @{
                HtmlPath  = $exportResult.HtmlPath
                JsonlPath = $exportResult.JsonlPath
                Summary   = [PSCustomObject]@{
                    NewGrants      = $grantCount
                    Revocations    = $revokeCount
                    PendingReviews = $pendingCount
                    Anomalies      = $anomalyCount
                }
            }
            Message = $message
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Invoke-SPGuiDeltaReport failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiDeltaReport'
        return @{ Success = $false; Data = $null; Message = $null; Error = "Invoke-SPGuiDeltaReport failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Governance Bridge Functions

function Invoke-SPGuiHealthCheck {
    <#
    .SYNOPSIS
        Run all six governance health checks and return normalized badge and metric data.
    .DESCRIPTION
        Orchestrates the six health dimensions (Source Aggregation, Identity Data Quality,
        Policy Compliance, Configuration Drift, Orphan Accounts, Campaign Coverage Gaps)
        and returns badge status objects and metric card values suitable for direct WPF
        dispatcher binding via the DispatcherTimer callback pattern in SP.MainWindow.
    .PARAMETER SourceIds
        AD source IDs for aggregation and orphan checks. If omitted, all enabled sources.
    .PARAMETER DaysBack
        Campaign lookback window for coverage gap analysis. Default: 90.
    .PARAMETER MaxStalenessHours
        Hours after which a source aggregation is considered stale. Default: 48.
    .PARAMETER IdentityLimit
        Maximum identities to evaluate for data quality scoring. Default: 200.
    .PARAMETER SnapshotPath
        Directory containing configuration snapshots for drift comparison.
        Resolved from config (Audit.OutputPath/snapshots) if omitted.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{
            Success = $bool
            Data    = @{
                Checks       = @(@{Key; Name; Status; Detail; Color; Grade})
                MetricCards  = @(@{Key; Label; Value; Color})
                OverallGrade = $string
            }
            Error   = $string
        }
    .EXAMPLE
        $result = Invoke-SPGuiHealthCheck -SourceIds @('src-abc') -DaysBack 90
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string[]]$SourceIds,

        [Parameter()]
        [int]$DaysBack = 90,

        [Parameter()]
        [int]$MaxStalenessHours = 48,

        [Parameter()]
        [int]$IdentityLimit = 200,

        [Parameter()]
        [string]$SnapshotPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $toolkitRoot = Resolve-SPToolkitRoot

    # Resolve snapshot path from config when not specified
    $effectiveSnapshotPath = $SnapshotPath
    if ([string]::IsNullOrWhiteSpace($effectiveSnapshotPath)) {
        try {
            $cfg = Get-SPConfig
            if ($null -ne $cfg.PSObject.Properties['Audit'] -and
                $null -ne $cfg.Audit -and
                $null -ne $cfg.Audit.PSObject.Properties['OutputPath'] -and
                -not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                $sp = Join-Path ([string]$cfg.Audit.OutputPath) 'snapshots'
                if (-not [System.IO.Path]::IsPathRooted($sp)) {
                    $sp = Join-Path $toolkitRoot $sp
                }
                $effectiveSnapshotPath = $sp
            }
        }
        catch { }

        if ([string]::IsNullOrWhiteSpace($effectiveSnapshotPath)) {
            $effectiveSnapshotPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'snapshots')
        }
    }

    $statusColor = @{
        'Pass'    = '#339933'
        'Warn'    = '#FF9900'
        'Fail'    = '#CC3333'
        'Error'   = '#CC3333'
        'Skipped' = '#999999'
        'Unknown' = '#999999'
    }

    $checks = [System.Collections.Generic.List[hashtable]]::new()

    # Check 1: Source Aggregation Health
    $c1 = @{ Key = 'SourceHealth'; Name = 'Source Health'; Status = 'Unknown'; Detail = ''; Color = '#999999'; Grade = '?' }
    try {
        $aggParams = @{ CorrelationID = $CorrelationID; MaxStalenessHours = $MaxStalenessHours }
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $aggParams['SourceIds'] = $SourceIds }
        $aggResult = Get-SPSourceAggregationHealth @aggParams
        if ($aggResult.Success) {
            $healthy = @($aggResult.Data.Sources | Where-Object { $_.Status -eq 'Healthy' }).Count
            $stale   = @($aggResult.Data.Sources | Where-Object { $_.Status -eq 'Stale'   }).Count
            $failed  = @($aggResult.Data.Sources | Where-Object { $_.Status -eq 'Failed'  }).Count
            $total   = $aggResult.Data.Sources.Count
            $g = if ($failed -gt 0) { 'F' }
                 elseif ($stale -gt 0 -and $stale -ge ($total / 2)) { 'D' }
                 elseif ($stale -gt 0) { 'C' }
                 elseif ($healthy -eq $total) { 'A' }
                 else { 'B' }
            $d = "$healthy/$total healthy"
            if ($stale  -gt 0) { $d += ", $stale stale"  }
            if ($failed -gt 0) { $d += ", $failed failed" }
            $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
            $c1 = @{ Key = 'SourceHealth'; Name = 'Source Health'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
        }
        else {
            $c1 = @{ Key = 'SourceHealth'; Name = 'Source Health'; Status = 'Error'; Detail = $aggResult.Error; Color = '#CC3333'; Grade = '?' }
        }
    }
    catch {
        $c1 = @{ Key = 'SourceHealth'; Name = 'Source Health'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c1)

    # Check 2: Identity Data Quality
    $c2 = @{ Key = 'DataQuality'; Name = 'Data Quality'; Status = 'Unknown'; Detail = ''; Color = '#999999'; Grade = '?' }
    try {
        $qr = Measure-SPIdentityDataQuality -Limit $IdentityLimit -ActiveOnly -CorrelationID $CorrelationID
        if ($null -ne $qr -and $null -ne $qr.Summary) {
            $score = $qr.Summary.OverallScore
            $g = if ($score -ge 90) { 'A' } elseif ($score -ge 80) { 'B' } elseif ($score -ge 70) { 'C' }
                 elseif ($score -ge 60) { 'D' } else { 'F' }
            $d = "Score: $score% ($($qr.Summary.IdentitiesEvaluated) identities)"
            $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
            $c2 = @{ Key = 'DataQuality'; Name = 'Data Quality'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
        }
        else {
            $c2 = @{ Key = 'DataQuality'; Name = 'Data Quality'; Status = 'Error'; Detail = 'No quality data returned'; Color = '#CC3333'; Grade = '?' }
        }
    }
    catch {
        $c2 = @{ Key = 'DataQuality'; Name = 'Data Quality'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c2)

    # Check 3: Policy Compliance
    $c3 = @{ Key = 'Policy'; Name = 'Policy'; Status = 'Unknown'; Detail = ''; Color = '#999999'; Grade = '?' }
    $policyPassedCount = $null
    $policyTotalCount  = $null
    try {
        $pr = Test-SPGovernancePolicy -CorrelationID $CorrelationID
        if ($null -ne $pr) {
            $passed = $pr.Summary.Passed
            $failedP = $pr.Summary.Failed
            $total   = $passed + $failedP
            $policyPassedCount = $passed
            $policyTotalCount  = $total
            $g = if ($failedP -eq 0) { 'A' }
                 elseif ($failedP -le 1 -and $total -gt 3) { 'B' }
                 elseif ($total -gt 0 -and $failedP -le ($total / 3)) { 'C' }
                 elseif ($total -gt 0 -and $failedP -le ($total / 2)) { 'D' }
                 else { 'F' }
            $d = "$passed/$total policies passed"
            if ($failedP -gt 0) { $d += " ($failedP violations)" }
            $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
            $c3 = @{ Key = 'Policy'; Name = 'Policy'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
        }
        else {
            $c3 = @{ Key = 'Policy'; Name = 'Policy'; Status = 'Error'; Detail = 'No policy results returned'; Color = '#CC3333'; Grade = '?' }
        }
    }
    catch {
        $c3 = @{ Key = 'Policy'; Name = 'Policy'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c3)

    # Check 4: Configuration Drift
    $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = 'Skipped'; Detail = 'No snapshots available'; Color = '#999999'; Grade = '-' }
    try {
        $snapshotFiles = @()
        if (Test-Path $effectiveSnapshotPath) {
            $snapshotFiles = @(Get-ChildItem -Path $effectiveSnapshotPath -Filter 'snapshot-*.json' |
                Sort-Object -Property LastWriteTime -Descending |
                Select-Object -First 2)
        }
        if ($snapshotFiles.Count -lt 2) {
            $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = 'Skipped'; Detail = "Need 2+ snapshots (found $($snapshotFiles.Count))"; Color = '#999999'; Grade = '-' }
        }
        else {
            $newer = Get-SPConfigurationSnapshot -Path $snapshotFiles[0].FullName -CorrelationID $CorrelationID
            $older = Get-SPConfigurationSnapshot -Path $snapshotFiles[1].FullName -CorrelationID $CorrelationID
            $newerOk = ($null -ne $newer -and -not ($newer.ContainsKey('Success') -and $newer['Success'] -eq $false))
            $olderOk = ($null -ne $older -and -not ($older.ContainsKey('Success') -and $older['Success'] -eq $false))
            if (-not $newerOk -or -not $olderOk) {
                $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = 'Error'; Detail = 'Failed to load snapshot files'; Color = '#CC3333'; Grade = '?' }
            }
            else {
                $dr = Compare-SPConfigurationSnapshots -SnapshotA $older -SnapshotB $newer -CorrelationID $CorrelationID
                if ($dr.Success) {
                    $changes = $dr.Data.Summary.TotalChanges
                    $g = if ($changes -eq 0) { 'A' } elseif ($changes -le 3) { 'B' }
                         elseif ($changes -le 10) { 'C' } elseif ($changes -le 20) { 'D' } else { 'F' }
                    $d = if ($changes -eq 0) { 'No drift detected' } else { "$changes change(s) detected" }
                    $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
                    $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
                }
                else {
                    $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = 'Error'; Detail = $dr.Error; Color = '#CC3333'; Grade = '?' }
                }
            }
        }
    }
    catch {
        $c4 = @{ Key = 'ConfigDrift'; Name = 'Config Drift'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c4)

    # Check 5: Orphan Accounts
    $c5 = @{ Key = 'Orphans'; Name = 'Orphans'; Status = 'Unknown'; Detail = ''; Color = '#999999'; Grade = '?' }
    try {
        $orpParams = @{ CorrelationID = $CorrelationID }
        if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $orpParams['SourceIds'] = $SourceIds }
        $or = Get-SPOrphanAccounts @orpParams
        if ($or.Success) {
            $orphanCount = $or.Data.TotalOrphans
            $totalAccts  = $or.Data.TotalAccounts
            $pct = if ($totalAccts -gt 0) { [math]::Round(($orphanCount / $totalAccts) * 100, 1) } else { 0 }
            $g = if ($pct -eq 0) { 'A' } elseif ($pct -le 2) { 'B' } elseif ($pct -le 5) { 'C' }
                 elseif ($pct -le 10) { 'D' } else { 'F' }
            $d = if ($orphanCount -eq 0) { 'No orphan accounts' } else { "$orphanCount orphan(s) of $totalAccts ($pct%)" }
            $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
            $c5 = @{ Key = 'Orphans'; Name = 'Orphans'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
        }
        else {
            $c5 = @{ Key = 'Orphans'; Name = 'Orphans'; Status = 'Error'; Detail = $or.Error; Color = '#CC3333'; Grade = '?' }
        }
    }
    catch {
        $c5 = @{ Key = 'Orphans'; Name = 'Orphans'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c5)

    # Check 6: Campaign Coverage Gaps
    $c6 = @{ Key = 'Coverage'; Name = 'Coverage'; Status = 'Unknown'; Detail = ''; Color = '#999999'; Grade = '?' }
    $coverageRatePct = $null
    try {
        $campResult = Get-SPAuditCampaigns -DaysBack $DaysBack -CorrelationID $CorrelationID
        if (-not $campResult.Success -or $null -eq $campResult.Data -or $campResult.Data.Count -eq 0) {
            $c6 = @{ Key = 'Coverage'; Name = 'Coverage'; Status = 'Skipped'; Detail = "No campaigns in last $DaysBack days"; Color = '#999999'; Grade = '-' }
        }
        else {
            $invParams = @{ CorrelationID = $CorrelationID; IncludeReviewHistory = $true }
            if ($null -ne $SourceIds -and $SourceIds.Count -gt 0) { $invParams['SourceIds'] = $SourceIds }
            $invResult = Get-SPEntitlementInventory @invParams
            if (-not $invResult.Success) {
                $c6 = @{ Key = 'Coverage'; Name = 'Coverage'; Status = 'Error'; Detail = "Inventory failed: $($invResult.Error)"; Color = '#CC3333'; Grade = '?' }
            }
            else {
                $auditHts = @($campResult.Data | ForEach-Object {
                    @{
                        CampaignId   = $_.id
                        CampaignName = $_.name
                        Status       = if ($null -ne $_.status) { [string]$_.status } else { '' }
                    }
                })
                $gapResult     = Get-SPCampaignCoverageGaps -CampaignAudits $auditHts -EntitlementInventory $invResult.Data -CorrelationID $CorrelationID
                $neverReviewed = @($gapResult.Gaps | Where-Object { $_.Coverage -eq 'NeverReviewed'     }).Count
                $partial       = @($gapResult.Gaps | Where-Object { $_.Coverage -eq 'PartiallyReviewed' }).Count
                $totalEnt      = $gapResult.Summary.TotalEntitlements
                $gapPct        = if ($totalEnt -gt 0) { [math]::Round(($neverReviewed / $totalEnt) * 100, 1) } else { 0 }
                $coverageRatePct = [math]::Round(100 - $gapPct, 1)
                $g = if ($neverReviewed -eq 0 -and $partial -eq 0) { 'A' }
                     elseif ($gapPct -le 5) { 'B' } elseif ($gapPct -le 15) { 'C' }
                     elseif ($gapPct -le 30) { 'D' } else { 'F' }
                $d = if ($neverReviewed -eq 0 -and $partial -eq 0) { 'Full coverage' }
                     else { "$neverReviewed never reviewed, $partial partial (of $totalEnt)" }
                $s = if ($g -in @('A', 'B')) { 'Pass' } elseif ($g -eq 'C') { 'Warn' } else { 'Fail' }
                $c6 = @{ Key = 'Coverage'; Name = 'Coverage'; Status = $s; Detail = $d; Color = $statusColor[$s]; Grade = $g }
            }
        }
    }
    catch {
        $c6 = @{ Key = 'Coverage'; Name = 'Coverage'; Status = 'Error'; Detail = $_.Exception.Message; Color = '#CC3333'; Grade = '?' }
    }
    $checks.Add($c6)

    # Overall grade from graded checks
    $gradeValues  = @{ 'A' = 4; 'B' = 3; 'C' = 2; 'D' = 1; 'F' = 0 }
    $gradedChecks = @($checks | Where-Object { $_.Grade -notin @('-', '?') -and $_.Status -ne 'Skipped' })
    $overallGrade = '-'
    if ($gradedChecks.Count -gt 0) {
        $totalScore = 0
        foreach ($ch in $gradedChecks) { $totalScore += $gradeValues[$ch.Grade] }
        $avg = $totalScore / $gradedChecks.Count
        $overallGrade = if ($avg -ge 3.5) { 'A' } elseif ($avg -ge 2.5) { 'B' }
                        elseif ($avg -ge 1.5) { 'C' } elseif ($avg -ge 0.5) { 'D' } else { 'F' }
    }

    # Metric card values
    $maturityValue = switch ($overallGrade) { 'A' { '5.0' } 'B' { '4.0' } 'C' { '3.0' } 'D' { '2.0' } 'F' { '1.0' } default { '--' } }
    $maturityColor = switch ($overallGrade) { 'A' { '#339933' } 'B' { '#339933' } 'C' { '#FF9900' } 'D' { '#CC3333' } 'F' { '#CC3333' } default { '#999999' } }

    $policyValue = if ($null -ne $policyPassedCount -and $null -ne $policyTotalCount -and $policyTotalCount -gt 0) {
        "$([math]::Round(($policyPassedCount / $policyTotalCount) * 100, 0))%"
    } else { '---%' }
    $policyColor = if ($policyValue -ne '---%') {
        $ppct = [int]($policyValue.TrimEnd('%'))
        if ($ppct -ge 90) { '#339933' } elseif ($ppct -ge 70) { '#FF9900' } else { '#CC3333' }
    } else { '#999999' }

    $coverageValue = if ($null -ne $coverageRatePct) { "$coverageRatePct%" } else { '---%' }
    $coverageColor = if ($null -ne $coverageRatePct) {
        if ($coverageRatePct -ge 95) { '#339933' } elseif ($coverageRatePct -ge 80) { '#FF9900' } else { '#CC3333' }
    } else { '#999999' }

    $metricCards = @(
        @{ Key = 'Maturity';         Label = 'Maturity';          Value = "$maturityValue/5"; Color = $maturityColor }
        @{ Key = 'PolicyCompliance'; Label = 'Policy Compliance';  Value = $policyValue;      Color = $policyColor   }
        @{ Key = 'CoverageRate';     Label = 'Coverage Rate';      Value = $coverageValue;    Color = $coverageColor }
    )

    Write-SPLog -Message "Invoke-SPGuiHealthCheck complete: OverallGrade=$overallGrade, Checks=$($checks.Count)" `
        -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiHealthCheck' -CorrelationID $CorrelationID

    return @{
        Success = $true
        Data    = @{
            Checks       = $checks.ToArray()
            MetricCards  = $metricCards
            OverallGrade = $overallGrade
        }
        Error   = $null
    }
}

function Invoke-SPGuiGovernanceReport {
    <#
    .SYNOPSIS
        Generate a full governance report package from the GUI.
    .DESCRIPTION
        Bridge function called from the GovernanceRunDialog handler. Fetches campaigns,
        runs the full audit pipeline via Invoke-SPGuiAudit, and optionally adds policy
        compliance, data quality, and dashboard export sections to a timestamped
        package directory.
    .PARAMETER Status
        Campaign status filter (single value). Default: 'COMPLETED'.
    .PARAMETER DaysBack
        Campaign lookback window in days. Default: 90.
    .PARAMETER IncludeLeadershipRollup
        Generate leadership-level rollup reports.
    .PARAMETER IncludePolicyCheck
        Add governance policy compliance section.
    .PARAMETER IncludeDataQuality
        Add data quality assessment section (aggregation health, orphan accounts,
        identity attribute quality).
    .PARAMETER IncludeDashboardExport
        Add dashboard data CSV export.
    .PARAMETER OutputPath
        Root directory for output. Auto-resolved from config (Audit.OutputPath) if omitted.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{ Success=$bool; Data=@{OutputPath; FilesWritten; DurationSeconds}; Error=$string }
    .EXAMPLE
        $result = Invoke-SPGuiGovernanceReport -Status 'COMPLETED' -DaysBack 90 -IncludePolicyCheck
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
        [string]$Status = 'COMPLETED',

        [Parameter()]
        [int]$DaysBack = 90,

        [Parameter()]
        [switch]$IncludeLeadershipRollup,

        [Parameter()]
        [switch]$IncludePolicyCheck,

        [Parameter()]
        [switch]$IncludeDataQuality,

        [Parameter()]
        [switch]$IncludeDashboardExport,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Resolve output path
        $toolkitRoot = Resolve-SPToolkitRoot
        $effectiveOutputPath = $OutputPath
        if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
            try {
                $cfg = Get-SPConfig
                if ($null -ne $cfg.PSObject.Properties['Audit'] -and
                    $null -ne $cfg.Audit -and
                    $null -ne $cfg.Audit.PSObject.Properties['OutputPath'] -and
                    -not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                    $ap = [string]$cfg.Audit.OutputPath
                    if (-not [System.IO.Path]::IsPathRooted($ap)) { $ap = Join-Path $toolkitRoot $ap }
                    $effectiveOutputPath = $ap
                }
            }
            catch { }

            if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
                $effectiveOutputPath = Join-Path $toolkitRoot 'Audit'
            }
        }

        # Create timestamped package directory
        $packageName = "GovernanceReport-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        $packagePath = Join-Path $effectiveOutputPath $packageName
        if (-not (Test-Path -Path $packagePath -PathType Container)) {
            New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
        }

        Write-SPLog -Message "Invoke-SPGuiGovernanceReport started: Status=$Status, DaysBack=$DaysBack, Package=$packageName" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID

        # Fetch campaigns
        $campQueryParams = @{ DaysBack = $DaysBack }
        if (-not [string]::IsNullOrWhiteSpace($Status)) { $campQueryParams['Status'] = $Status }
        $campaignResult = Get-SPGuiAuditCampaigns @campQueryParams

        if (-not $campaignResult.Success) {
            $sw.Stop()
            return @{
                Success = $false
                Data    = $null
                Error   = "Failed to retrieve campaigns: $($campaignResult.Error)"
            }
        }

        if ($campaignResult.Data.Count -eq 0) {
            $sw.Stop()
            return @{
                Success = $false
                Data    = $null
                Error   = "No campaigns found matching Status='$Status', DaysBack=$DaysBack."
            }
        }

        # Campaign audit pipeline
        $auditParams = @{
            SelectedCampaigns       = $campaignResult.Data
            OutputPath              = $packagePath
            IncludeCampaignReports  = $false
            IncludeIdentityEvents   = $false
            IncludeLeadershipRollup = [bool]$IncludeLeadershipRollup
            CorrelationID           = $CorrelationID
        }
        $auditResult  = Invoke-SPGuiAudit @auditParams
        $filesWritten = if ($auditResult.FilesWritten) { $auditResult.FilesWritten } else { 0 }

        if (-not $auditResult.Success) {
            Write-SPLog -Message "Campaign audit step non-fatal failure: $($auditResult.Error)" `
                -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
        }

        # Optional: Policy Compliance
        if ($IncludePolicyCheck) {
            try {
                $pr = Test-SPGovernancePolicy -CorrelationID $CorrelationID
                if ($null -ne $pr) {
                    $ph = Export-SPPolicyComplianceHtml -PolicyResults $pr -OutputPath $packagePath -CorrelationID $CorrelationID
                    if (-not [string]::IsNullOrWhiteSpace($ph)) { $filesWritten++ }
                }
            }
            catch {
                Write-SPLog -Message "Policy compliance step non-fatal: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
            }
        }

        # Optional: Data Quality (3 sub-sections)
        if ($IncludeDataQuality) {
            try {
                $ah = Get-SPSourceAggregationHealth -CorrelationID $CorrelationID
                if ($ah.Success) {
                    $ahPath = Export-SPSourceAggregationHealthHtml -HealthData $ah.Data -OutputPath $packagePath -CorrelationID $CorrelationID
                    if (-not [string]::IsNullOrWhiteSpace($ahPath)) { $filesWritten++ }
                }
            }
            catch {
                Write-SPLog -Message "Aggregation health HTML non-fatal: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
            }

            try {
                $oh = Get-SPOrphanAccounts -CorrelationID $CorrelationID
                if ($oh.Success) {
                    $ohPath = Export-SPOrphanAccountHtml -OrphanData $oh.Data -OutputPath $packagePath -CorrelationID $CorrelationID
                    if (-not [string]::IsNullOrWhiteSpace($ohPath)) { $filesWritten++ }
                }
            }
            catch {
                Write-SPLog -Message "Orphan account HTML non-fatal: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
            }

            try {
                $qr = Measure-SPIdentityDataQuality -Limit 200 -ActiveOnly -CorrelationID $CorrelationID
                if ($null -ne $qr -and $null -ne $qr.Summary) {
                    $qPath = Export-SPIdentityDataQualityHtml -QualityData $qr -OutputPath $packagePath -CorrelationID $CorrelationID
                    if (-not [string]::IsNullOrWhiteSpace($qPath)) { $filesWritten++ }
                }
            }
            catch {
                Write-SPLog -Message "Identity quality HTML non-fatal: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
            }
        }

        # Optional: Dashboard Data Export
        if ($IncludeDashboardExport) {
            try {
                $dr = Export-SPGuiDashboardData -DaysBack $DaysBack -OutputPath $packagePath -CorrelationID $CorrelationID
                if ($dr.Success) { $filesWritten++ }
                else {
                    Write-SPLog -Message "Dashboard export non-fatal: $($dr.Error)" `
                        -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
                }
            }
            catch {
                Write-SPLog -Message "Dashboard export non-fatal: $($_.Exception.Message)" `
                    -Severity WARN -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
            }
        }

        $sw.Stop()

        Write-SPLog -Message "Invoke-SPGuiGovernanceReport complete: $filesWritten file(s), OutputPath='$packagePath'" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                OutputPath      = $packagePath
                FilesWritten    = $filesWritten
                DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            }
            Error   = $null
        }
    }
    catch {
        $sw.Stop()
        Write-SPLog -Message "Invoke-SPGuiGovernanceReport failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Invoke-SPGuiGovernanceReport' -CorrelationID $CorrelationID
        return @{
            Success = $false
            Data    = $null
            Error   = "Invoke-SPGuiGovernanceReport failed: $($_.Exception.Message)"
        }
    }
}

function Export-SPGuiDashboardData {
    <#
    .SYNOPSIS
        Export governance dashboard data to CSV for BI/SIEM consumption.
    .DESCRIPTION
        Bridge function for the [Export Dashboard Data] button. Fetches recent
        completed campaigns, builds campaign audit hashtables (certifications,
        items, decisions, reviewer metrics), and delegates to
        Export-SPGovernanceDashboardData. Returns the path to the generated
        CSV file and a row count for status display.
    .PARAMETER DaysBack
        Campaign lookback window in days. Default: 30.
    .PARAMETER OutputPath
        Directory to write the CSV file. Defaults to ToolkitRoot/GovernanceMetrics.
    .PARAMETER CorrelationID
        Correlation ID for log tracing. Auto-generated if omitted.
    .OUTPUTS
        @{ Success=$bool; Data=@{CsvPath; RowCount}; Error=$string }
    .EXAMPLE
        $result = Export-SPGuiDashboardData -DaysBack 30
        if ($result.Success) { Write-Host "Exported $($result.Data.RowCount) rows to $($result.Data.CsvPath)" }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [int]$DaysBack = 30,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$CorrelationID
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationID)) {
        $CorrelationID = [guid]::NewGuid().ToString()
    }

    try {
        # Resolve output path
        $toolkitRoot = Resolve-SPToolkitRoot
        $effectiveOutputPath = $OutputPath
        if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
            $effectiveOutputPath = Join-Path $toolkitRoot 'GovernanceMetrics'
        }
        if (-not (Test-Path -Path $effectiveOutputPath -PathType Container)) {
            New-Item -Path $effectiveOutputPath -ItemType Directory -Force | Out-Null
        }

        Write-SPLog -Message "Export-SPGuiDashboardData started: DaysBack=$DaysBack, OutputPath='$effectiveOutputPath'" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Export-SPGuiDashboardData' -CorrelationID $CorrelationID

        # Fetch completed campaigns
        $campaignResult = Get-SPGuiAuditCampaigns -Status 'COMPLETED' -DaysBack $DaysBack
        if (-not $campaignResult.Success) {
            return @{ Success = $false; Data = $null; Error = "Failed to retrieve campaigns: $($campaignResult.Error)" }
        }
        if ($campaignResult.Data.Count -eq 0) {
            return @{ Success = $false; Data = $null; Error = "No completed campaigns found in last $DaysBack days." }
        }

        # Build campaign audit hashtables
        $allCampaignAudits = [System.Collections.Generic.List[object]]::new()

        foreach ($displayCampaign in $campaignResult.Data) {
            $rawCampaign = $displayCampaign._RawCampaign
            $campId      = $rawCampaign.id
            $campName    = $rawCampaign.name

            # Certifications
            $certResult     = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $CorrelationID
            $certifications = @()
            if ($certResult.Success -and $null -ne $certResult.Data) {
                $certifications = @($certResult.Data)
            }

            # Certification items (wrapped)
            $wrappedItems = [System.Collections.Generic.List[object]]::new()
            foreach ($cert in $certifications) {
                $certName   = if ($null -ne $cert.name) { $cert.name } else { '' }
                $itemResult = Get-SPAuditCertificationItems -CertificationId $cert.id -CorrelationID $CorrelationID
                if ($itemResult.Success -and $null -ne $itemResult.Data) {
                    foreach ($rawItem in $itemResult.Data) {
                        $wrappedItems.Add(@{
                            Item              = $rawItem
                            CertificationId   = $cert.id
                            CertificationName = $certName
                            CampaignName      = $campName
                        })
                    }
                }
            }

            # Identity account resolution (non-fatal)
            $accountMap = @{}
            $uniqueIds = @($wrappedItems | ForEach-Object {
                $item = $_.Item
                if ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.identityId) { $item.identitySummary.identityId }
                elseif ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) { $item.identitySummary.id }
            } | Where-Object { $_ } | Sort-Object -Unique)

            if ($uniqueIds.Count -gt 0) {
                try {
                    $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $uniqueIds -CorrelationID $CorrelationID
                    if ($acctResult.Success) { $accountMap = $acctResult.Data }
                }
                catch { }
            }

            # Analytics
            $decisions      = Group-SPAuditDecisions         -Items $wrappedItems.ToArray() -AccountMap $accountMap
            $reviewerMetrics = Measure-SPAuditReviewerMetrics -Certifications $certifications

            $allCampaignAudits.Add(@{
                CampaignName        = $campName
                CampaignId          = $campId
                Status              = if ($null -ne $rawCampaign.status)              { [string]$rawCampaign.status }           else { '' }
                Created             = if ($null -ne $rawCampaign.created)             { [string]$rawCampaign.created }          else { '' }
                Completed           = if ($null -ne $rawCampaign.completed)           { [string]$rawCampaign.completed }        else { '' }
                TotalCertifications = if ($null -ne $rawCampaign.totalCertifications) { [int]$rawCampaign.totalCertifications } else { 0 }
                Decisions           = $decisions
                ReviewerMetrics     = $reviewerMetrics
            })
        }

        # Export CSV
        $dashResult = Export-SPGovernanceDashboardData `
            -CampaignAudits $allCampaignAudits.ToArray() `
            -OutputPath     $effectiveOutputPath `
            -Format         'CSV' `
            -CorrelationID  $CorrelationID

        if (-not $dashResult.Success) {
            return @{ Success = $false; Data = $null; Error = "Dashboard export failed: $($dashResult.Error)" }
        }

        Write-SPLog -Message "Export-SPGuiDashboardData complete: $($dashResult.Data.RowCount) rows, CsvPath='$($dashResult.Data.CsvFile)'" `
            -Severity INFO -Component 'SP.GuiBridge' -Action 'Export-SPGuiDashboardData' -CorrelationID $CorrelationID

        return @{
            Success = $true
            Data    = @{
                CsvPath  = $dashResult.Data.CsvFile
                RowCount = $dashResult.Data.RowCount
            }
            Error   = $null
        }
    }
    catch {
        Write-SPLog -Message "Export-SPGuiDashboardData failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Export-SPGuiDashboardData' -CorrelationID $CorrelationID
        return @{ Success = $false; Data = $null; Error = "Export-SPGuiDashboardData failed: $($_.Exception.Message)" }
    }
}

function Get-SPGuiGovernanceReports {
    <#
    .SYNOPSIS
        Enumerate recently generated governance report HTML files for the Governance tab list.
    .DESCRIPTION
        Scans the Audit output path for GovernanceReport-* package directories and
        standalone governance HTML files (healthcheck-*, policy-compliance-*, orphan-*,
        data-quality-*, governance-dashboard-*). Returns the most recent 20 files,
        newest-first, as PSCustomObjects suitable for WPF ListBox binding.
        Returns an empty Data array (not an error) when no output exists yet.
    .PARAMETER ReportsPath
        Root directory to scan. If omitted, resolved from config (Audit.OutputPath).
        Falls back to ToolkitRoot/Audit if config is unavailable.
    .OUTPUTS
        @{ Success=$bool; Data=@([PSCustomObject]@{FileName;FullPath;LastModified;SizeKB}); Error=$string }
    .EXAMPLE
        $result = Get-SPGuiGovernanceReports
        if ($result.Success) { $govReportList.ItemsSource = $result.Data }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string]$ReportsPath
    )

    try {
        $toolkitRoot = Resolve-SPToolkitRoot
        $effectivePath = $ReportsPath

        if ([string]::IsNullOrWhiteSpace($effectivePath)) {
            try {
                $cfg = Get-SPConfig
                if ($null -ne $cfg.PSObject.Properties['Audit'] -and
                    $null -ne $cfg.Audit -and
                    $null -ne $cfg.Audit.PSObject.Properties['OutputPath'] -and
                    -not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
                    $ap = [string]$cfg.Audit.OutputPath
                    if (-not [System.IO.Path]::IsPathRooted($ap)) { $ap = Join-Path $toolkitRoot $ap }
                    $effectivePath = $ap
                }
            }
            catch { }

            if ([string]::IsNullOrWhiteSpace($effectivePath)) {
                $effectivePath = Join-Path $toolkitRoot 'Audit'
            }
        }

        if (-not (Test-Path -Path $effectivePath -PathType Container)) {
            return @{ Success = $true; Data = @(); Error = $null }
        }

        # Gather HTML files from GovernanceReport-* package directories and
        # governance-named files directly in the root path
        $govPatterns = @('healthcheck-*.html', 'policy-compliance-*.html',
                         'orphan-*.html', 'identity-quality-*.html',
                         'governance-dashboard-*.html', 'governance-*.html')

        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

        # GovernanceReport-* subdirectories
        $govDirs = @(Get-ChildItem -Path $effectivePath -Directory -Filter 'GovernanceReport-*' -ErrorAction SilentlyContinue)
        foreach ($dir in $govDirs) {
            $htmls = @(Get-ChildItem -Path $dir.FullName -Filter '*.html' -Recurse -File -ErrorAction SilentlyContinue)
            foreach ($h in $htmls) { $files.Add($h) }
        }

        # Legacy Reports directory (GovernanceRun_*.html)
        $legacyDir = Join-Path $toolkitRoot 'Reports'
        if (Test-Path -Path $legacyDir -PathType Container) {
            $legacyHtml = @(Get-ChildItem -Path $legacyDir -Filter 'GovernanceRun_*.html' -File -ErrorAction SilentlyContinue)
            foreach ($h in $legacyHtml) { $files.Add($h) }
        }

        # Governance-named files directly in Audit path
        foreach ($pattern in $govPatterns) {
            $direct = @(Get-ChildItem -Path $effectivePath -Filter $pattern -File -ErrorAction SilentlyContinue)
            foreach ($h in $direct) { $files.Add($h) }
        }

        $sorted = @($files | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 20)

        $items = foreach ($file in $sorted) {
            [PSCustomObject]@{
                FileName     = $file.Name
                FullPath     = $file.FullName
                LastModified = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                SizeKB       = [math]::Round($file.Length / 1024, 1)
            }
        }

        return @{ Success = $true; Data = @($items); Error = $null }
    }
    catch {
        Write-SPLog -Message "Get-SPGuiGovernanceReports failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Get-SPGuiGovernanceReports'
        return @{ Success = $false; Data = @(); Error = "Get-SPGuiGovernanceReports failed: $($_.Exception.Message)" }
    }
}

#endregion

#region Browser Token Functions

function Set-SPGuiBrowserToken {
    <#
    .SYNOPSIS
        Injects a browser-obtained JWT token for use by all toolkit API calls.
    .DESCRIPTION
        Bridge function for the Settings tab "Apply Token" button. Accepts a JWT
        from the PasswordBox, validates it, and delegates to Set-SPBrowserToken
        in SP.Auth. Returns a status hashtable for GUI display.

        After applying, the toolkit uses this token for all API calls until it
        expires or the user clears it. When the token expires, the toolkit falls
        back to the configured OAuth authentication mode.
    .PARAMETER Token
        The JWT bearer token string. "Bearer " prefix is stripped automatically.
    .PARAMETER ExpiryMinutes
        Minutes until the token is considered expired. Default: 10.
    .OUTPUTS
        @{Success=$bool; Message=$string; ExpiresAt=$datetime}
    .EXAMPLE
        $result = Set-SPGuiBrowserToken -Token $passwordBox.Password
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter()]
        [int]$ExpiryMinutes = 10
    )

    if ([string]::IsNullOrWhiteSpace($Token) -or $Token -eq 'Paste browser token here...') {
        return @{
            Success   = $false
            Message   = 'No token provided. Paste a JWT from the browser dev tools Network tab.'
            ExpiresAt = $null
        }
    }

    try {
        $result = Set-SPBrowserToken -Token $Token -ExpiryMinutes $ExpiryMinutes

        if ($result.Success) {
            $expiresAt = $result.Data.ExpiresAt
            return @{
                Success   = $true
                Message   = "Token applied. Expires at $($expiresAt.ToString('HH:mm:ss')). All API calls will use this token."
                ExpiresAt = $expiresAt
            }
        }
        else {
            return @{
                Success   = $false
                Message   = "Token rejected: $($result.Error)"
                ExpiresAt = $null
            }
        }
    }
    catch {
        Write-SPLog -Message "Set-SPGuiBrowserToken failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'SP.GuiBridge' -Action 'Set-SPGuiBrowserToken'
        return @{
            Success   = $false
            Message   = "Failed: $($_.Exception.Message)"
            ExpiresAt = $null
        }
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
    # Strip exactly one leading .\ or ./ if present. The previous TrimStart(char[])
    # form collapsed inputs like '..\..\foo' to 'foo' by removing every leading
    # '.' and '\' character.
    if ($Path.StartsWith('.\') -or $Path.StartsWith('./')) {
        $cleaned = $Path.Substring(2)
    }
    else {
        $cleaned = $Path
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $cleaned))
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPGuiTest',
    'Get-SPGuiCampaignList',
    'Get-SPGuiIdentityList',
    'Test-SPGuiConnectivity',
    'Set-SPGuiBrowserToken',
    'Get-SPGuiAuditCampaigns',
    'Invoke-SPGuiAudit',
    'Get-SPGuiAuditReports',
    'Invoke-SPGuiDeltaCertRun',
    'Invoke-SPGuiDeltaCertCleanup',
    'Invoke-SPGuiDeltaCertEscalate',
    'Invoke-SPGuiDeltaReport',
    'Get-SPGuiDeltaCertHistory',
    'Invoke-SPGuiHealthCheck',
    'Invoke-SPGuiGovernanceReport',
    'Export-SPGuiDashboardData',
    'Get-SPGuiGovernanceReports'
)
