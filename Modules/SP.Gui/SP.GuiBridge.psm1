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
        [int]$DaysBack = 3
    )

    try {
        $params = @{ DaysBack = $DaysBack }

        if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
            $params['CampaignNameContains'] = $CampaignNameContains
        }

        if (-not [string]::IsNullOrWhiteSpace($Status) -and $Status -ne '(All)') {
            $params['Status'] = @($Status)
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
    'Get-SPGuiDeltaCertHistory'
)
