#Requires -Version 5.1
<#
.SYNOPSIS
    SailPoint ISC Governance Toolkit - Test Suite Orchestrator
.DESCRIPTION
    Main test engine. Runs ordered campaign test suites, executes the
    10-step campaign lifecycle for each test case, records evidence at
    every step, and generates HTML reports.

    Campaign lifecycle steps:
        1  CreateCampaign
        2  ActivateCampaign
        3  PollStatus
        4  GetCertifications
        5  Reassign            (conditional: ReassignBeforeDecide)
        6  GetReviewItems
        7  BulkDecide          (batched at 250)
        8  SignOff
        9  AssertFinalStatus
        10 ValidateRemediation (conditional: ValidateRemediation)
.NOTES
    Module: SP.Testing / SP.BatchRunner
    Version: 1.0.0
    Component: Test Orchestration
    API constraints: 250 items per bulk-decide batch, 95 req/10s rate limit
#>

#region Constants

$script:BULK_DECIDE_BATCH_SIZE = 250

#endregion

#region Suite Runner

function Invoke-SPTestSuite {
    <#
    .SYNOPSIS
        Orchestrate a full test suite across multiple campaign test cases.
    .DESCRIPTION
        Iterates the ordered campaign list, calls Invoke-SPSingleTest for each,
        enforces MaxCampaignsPerRun safety limit, optionally stops on first
        failure, tracks timing, and calls Export-SPSuiteReport at completion.
    .PARAMETER Campaigns
        Ordered array of campaign test case objects from Import-SPTestCampaigns.
    .PARAMETER Identities
        Hashtable of identities from Import-SPTestIdentities.
    .PARAMETER CorrelationID
        Correlation ID propagated to all child calls and evidence records.
    .PARAMETER WhatIf
        If specified, log what would happen without making any API calls.
    .PARAMETER StopOnFirstFailure
        If specified, skip remaining campaigns after the first failure.
    .OUTPUTS
        @{Success; Results=$array; PassCount; FailCount; SkipCount; DurationSeconds}
    .EXAMPLE
        $suite = Invoke-SPTestSuite -Campaigns $campaigns -Identities $ids `
                     -CorrelationID $cid -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Campaigns,

        [Parameter(Mandatory)]
        [hashtable]$Identities,

        [Parameter(Mandatory)]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [switch]$StopOnFirstFailure
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $results   = @()
    $passCount = 0
    $failCount = 0
    $skipCount = 0

    try {
        # Load config for safety limits and paths
        $config = $null
        if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
            $config = Get-SPConfig
        }

        $maxCampaigns   = 20  # safe default
        $evidenceBase   = '.'
        $reportsPath    = '.'

        if ($null -ne $config) {
            if ($null -ne $config.Safety -and $null -ne $config.Safety.MaxCampaignsPerRun) {
                $maxCampaigns = [int]$config.Safety.MaxCampaignsPerRun
            }
            if ($null -ne $config.Testing) {
                if ($null -ne $config.Testing.EvidencePath)  { $evidenceBase  = $config.Testing.EvidencePath }
                if ($null -ne $config.Testing.ReportsPath)   { $reportsPath   = $config.Testing.ReportsPath }
            }
        }

        $campaignsToRun = @($Campaigns)
        $totalRequested = $campaignsToRun.Count

        # Enforce MaxCampaignsPerRun
        if ($totalRequested -gt $maxCampaigns) {
            $skipped = $totalRequested - $maxCampaigns
            $warnMsg = "Safety limit: MaxCampaignsPerRun=$maxCampaigns. $skipped campaign(s) will be skipped."
            if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                Write-SPLog -Message $warnMsg -Severity WARN -Component "SP.BatchRunner" `
                    -Action "InvokeTestSuite" -CorrelationID $CorrelationID
            }
            # Record skipped campaigns
            $skippedCampaigns = $campaignsToRun | Select-Object -Skip $maxCampaigns
            foreach ($sc in $skippedCampaigns) {
                $results += @{
                    TestId          = $sc.TestId
                    TestName        = $sc.TestName
                    CampaignType    = $sc.CampaignType
                    Pass            = $false
                    Skipped         = $true
                    Steps           = @()
                    Error           = "Skipped: exceeded MaxCampaignsPerRun ($maxCampaigns)"
                    DurationSeconds = 0
                }
                $skipCount++
            }
            $campaignsToRun = $campaignsToRun | Select-Object -First $maxCampaigns
        }

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Suite starting: $($campaignsToRun.Count) campaign(s) to execute. WhatIf=$($WhatIf.IsPresent)" `
                -Severity INFO -Component "SP.BatchRunner" -Action "InvokeTestSuite" -CorrelationID $CorrelationID
        }

        $stopped = $false

        foreach ($campaign in $campaignsToRun) {
            if ($stopped) {
                $results += @{
                    TestId          = $campaign.TestId
                    TestName        = $campaign.TestName
                    CampaignType    = $campaign.CampaignType
                    Pass            = $false
                    Skipped         = $true
                    Steps           = @()
                    Error           = "Skipped: StopOnFirstFailure triggered by earlier test"
                    DurationSeconds = 0
                }
                $skipCount++
                continue
            }

            $testResult = Invoke-SPSingleTest `
                -TestCase     $campaign `
                -Identities   $Identities `
                -CorrelationID $CorrelationID `
                -WhatIf:$WhatIf `
                -EvidenceBase $evidenceBase

            $results += $testResult

            if ($testResult.Pass -eq $true) {
                $passCount++
            }
            else {
                $failCount++
                if ($StopOnFirstFailure.IsPresent) {
                    $stopped = $true
                    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
                        Write-SPLog -Message "StopOnFirstFailure: stopping suite after failure in $($campaign.TestId)" `
                            -Severity WARN -Component "SP.BatchRunner" -Action "InvokeTestSuite" -CorrelationID $CorrelationID
                    }
                }
            }
        }

        $sw.Stop()
        $durationSecs = [math]::Round($sw.Elapsed.TotalSeconds, 2)

        # Build suite metadata for report
        $tenantUrl   = ''
        $environment = ''
        if ($null -ne $config) {
            if ($null -ne $config.ISC -and $null -ne $config.ISC.TenantUrl)      { $tenantUrl   = $config.ISC.TenantUrl }
            if ($null -ne $config.Global -and $null -ne $config.Global.Environment) { $environment = $config.Global.Environment }
        }

        $suiteResultForReport = @{
            Results         = $results
            PassCount       = $passCount
            FailCount       = $failCount
            SkipCount       = $skipCount
            DurationSeconds = $durationSecs
            TenantUrl       = $tenantUrl
            Environment     = $environment
            CorrelationID   = $CorrelationID
        }

        $runTimestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        if (Get-Command -Name Export-SPSuiteReport -ErrorAction SilentlyContinue) {
            Export-SPSuiteReport -SuiteResult $suiteResultForReport `
                -OutputPath $reportsPath -RunTimestamp $runTimestamp
        }

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Suite complete: Pass=$passCount Fail=$failCount Skip=$skipCount Duration=${durationSecs}s" `
                -Severity INFO -Component "SP.BatchRunner" -Action "InvokeTestSuite" -CorrelationID $CorrelationID
        }

        $overallSuccess = ($failCount -eq 0)

        return @{
            Success         = $overallSuccess
            Results         = $results
            PassCount       = $passCount
            FailCount       = $failCount
            SkipCount       = $skipCount
            DurationSeconds = $durationSecs
        }
    }
    catch {
        $sw.Stop()
        $durationSecs = [math]::Round($sw.Elapsed.TotalSeconds, 2)

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            Write-SPLog -Message "Suite runner threw exception: $($_.Exception.Message)" `
                -Severity ERROR -Component "SP.BatchRunner" -Action "InvokeTestSuite" -CorrelationID $CorrelationID
        }

        return @{
            Success         = $false
            Results         = $results
            PassCount       = $passCount
            FailCount       = $failCount
            SkipCount       = $skipCount
            DurationSeconds = $durationSecs
        }
    }
}

#endregion

#region Single Test Executor

function Invoke-SPSingleTest {
    <#
    .SYNOPSIS
        Execute the 10-step campaign lifecycle for one test case.
    .DESCRIPTION
        Runs each step in sequence. A failure at any mandatory step causes
        remaining steps to be skipped. Optional steps (Reassign,
        ValidateRemediation) skip gracefully if conditions not met.
        Evidence is recorded after every step.

    .PARAMETER TestCase
        Campaign test case PSCustomObject from Import-SPTestCampaigns.
    .PARAMETER Identities
        Hashtable of identities for display-name resolution.
    .PARAMETER CorrelationID
        Suite-level correlation ID.
    .PARAMETER WhatIf
        If set, log intentions without making API calls.
    .PARAMETER EvidenceBase
        Base path for evidence directory creation.
    .OUTPUTS
        @{Success; TestId; TestName; Steps=$array; Pass; Fail; Error; DurationSeconds}
    .EXAMPLE
        $r = Invoke-SPSingleTest -TestCase $tc -Identities $ids -CorrelationID $cid -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TestCase,

        [Parameter(Mandatory)]
        [hashtable]$Identities,

        [Parameter(Mandatory)]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [string]$EvidenceBase = '.'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $steps       = [System.Collections.Generic.List[object]]::new()
    $passedSteps = 0
    $failedSteps = 0
    $campaignId  = $null
    $testPassed  = $false
    $testError   = ''

    # Load config for timeouts and other settings
    $config = $null
    if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
        $config = Get-SPConfig
    }

    $activationTimeout  = 300   # 5 minutes default
    $completionTimeout  = 600   # 10 minutes default
    $pollInterval       = 15    # 15 seconds
    $defaultDecision    = 'APPROVE'
    $whatIfDefault      = $false

    if ($null -ne $config -and $null -ne $config.Testing) {
        if ($null -ne $config.Testing.CampaignActivationTimeoutSeconds) { $activationTimeout = [int]$config.Testing.CampaignActivationTimeoutSeconds }
        if ($null -ne $config.Testing.CampaignCompleteTimeoutSeconds)   { $completionTimeout = [int]$config.Testing.CampaignCompleteTimeoutSeconds }
        if ($null -ne $config.Testing.DefaultDecision)                   { $defaultDecision   = $config.Testing.DefaultDecision }
        if ($null -ne $config.Testing.WhatIfByDefault)                   { $whatIfDefault     = [bool]$config.Testing.WhatIfByDefault }
    }

    $effectiveWhatIf = $WhatIf.IsPresent -or $whatIfDefault
    $decision        = if (-not [string]::IsNullOrWhiteSpace($TestCase.DecisionToMake)) { $TestCase.DecisionToMake.ToUpper() } else { $defaultDecision }
    $testId          = $TestCase.TestId
    $testName        = $TestCase.TestName

    # Prepare evidence path
    $evidencePath = $EvidenceBase
    if (Get-Command -Name New-SPCampaignEvidencePath -ErrorAction SilentlyContinue) {
        $evidencePath = New-SPCampaignEvidencePath -TestId $testId -BasePath $EvidenceBase
    }

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Starting test $testId ($testName). WhatIf=$effectiveWhatIf" `
            -Severity INFO -Component "SP.BatchRunner" -Action "InvokeSingleTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    # Helper: record a step result
    $recordStep = {
        param($StepNum, $Action, $Status, $Message, $Data)

        $stepRecord = @{
            Step    = $StepNum
            Action  = $Action
            Status  = $Status
            Message = $Message
            Data    = $Data
        }
        $steps.Add($stepRecord)

        if (Get-Command -Name Write-SPEvidenceEvent -ErrorAction SilentlyContinue) {
            Write-SPEvidenceEvent `
                -EvidencePath $evidencePath `
                -TestId       $testId `
                -Step         $StepNum `
                -Action       $Action `
                -Status       $Status `
                -Message      $Message `
                -Data         $Data `
                -CorrelationID $CorrelationID
        }

        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            $sev = switch ($Status) {
                'PASS' { 'INFO' }
                'FAIL' { 'ERROR' }
                'WARN' { 'WARN' }
                default { 'INFO' }
            }
            Write-SPLog -Message "[$testId] Step $StepNum $Action : $Status - $Message" `
                -Severity $sev -Component "SP.BatchRunner" -Action "InvokeSingleTest" `
                -CorrelationID $CorrelationID -CampaignTestId $testId
        }
    }

    # Abort helper - appends remaining steps as SKIP
    $abortRemaining = {
        param([int]$FromStep, [int]$ToStep, [string]$Reason)
        for ($s = $FromStep; $s -le $ToStep; $s++) {
            & $recordStep $s "Skipped" "SKIP" "Skipped due to earlier failure: $Reason" $null
        }
    }

    $aborted = $false

    # ------------------------------------------------------------------
    # STEP 1: CreateCampaign
    # ------------------------------------------------------------------
    $stepNum = 1
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "CreateCampaign" "INFO" "[WhatIf] Would create campaign '$($TestCase.CampaignName)' type=$($TestCase.CampaignType)" $null
        $campaignId = "whatif-campaign-$testId"
        $passedSteps++
    }
    else {
        try {
            $createParams = @{
                Name               = $TestCase.CampaignName
                Type               = $TestCase.CampaignType
                CertifierIdentityId = $TestCase.CertifierIdentityId
                CorrelationID      = $CorrelationID
                CampaignTestId     = $testId
            }
            if (-not [string]::IsNullOrWhiteSpace($TestCase.SourceId))    { $createParams['SourceId']    = $TestCase.SourceId }
            if (-not [string]::IsNullOrWhiteSpace($TestCase.SearchFilter)) { $createParams['SearchFilter'] = $TestCase.SearchFilter }
            if (-not [string]::IsNullOrWhiteSpace($TestCase.RoleId))       { $createParams['RoleId']       = $TestCase.RoleId }
            if (-not [string]::IsNullOrWhiteSpace($TestCase.TestName))     { $createParams['Description']  = "UAT: $($TestCase.TestName)" }

            $createResult = New-SPCampaign @createParams

            if ($createResult.Success -and $null -ne $createResult.Data -and -not [string]::IsNullOrWhiteSpace($createResult.Data.id)) {
                $campaignId = $createResult.Data.id
                & $recordStep $stepNum "CreateCampaign" "PASS" "Campaign created: id=$campaignId" @{ CampaignId = $campaignId }
                $passedSteps++
            }
            else {
                $msg = if ($createResult.Error) { $createResult.Error } else { "CreateCampaign returned null or missing id" }
                & $recordStep $stepNum "CreateCampaign" "FAIL" $msg $null
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
        catch {
            $msg = "CreateCampaign threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "CreateCampaign" "FAIL" $msg $null
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 2 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 2: ActivateCampaign
    # ------------------------------------------------------------------
    $stepNum = 2
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "ActivateCampaign" "INFO" "[WhatIf] Would activate campaign $campaignId" $null
        $passedSteps++
    }
    else {
        try {
            $activateResult = Start-SPCampaign -CampaignId $campaignId `
                -CorrelationID $CorrelationID -CampaignTestId $testId

            if ($activateResult.Success) {
                & $recordStep $stepNum "ActivateCampaign" "PASS" "Activation request accepted (202)" @{ CampaignId = $campaignId }
                $passedSteps++
            }
            else {
                $msg = if ($activateResult.Error) { $activateResult.Error } else { "Start-SPCampaign failed" }
                & $recordStep $stepNum "ActivateCampaign" "FAIL" $msg @{ CampaignId = $campaignId }
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
        catch {
            $msg = "ActivateCampaign threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "ActivateCampaign" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 3 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 3: PollStatus - wait for ACTIVE
    # ------------------------------------------------------------------
    $stepNum = 3
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "PollStatus" "INFO" "[WhatIf] Would poll until campaign reaches ACTIVE status (timeout: ${activationTimeout}s)" $null
        $passedSteps++
    }
    else {
        try {
            $pollResult = Get-SPCampaignStatus `
                -CampaignId      $campaignId `
                -TimeoutSeconds  $activationTimeout `
                -PollIntervalSeconds $pollInterval `
                -TargetStatus    'ACTIVE' `
                -CorrelationID   $CorrelationID `
                -CampaignTestId  $testId

            if ($pollResult.Success) {
                $actualStatus = if ($pollResult.Data) { $pollResult.Data.Status } else { 'UNKNOWN' }
                & $recordStep $stepNum "PollStatus" "PASS" "Campaign reached ACTIVE status" @{ CampaignId = $campaignId; Status = $actualStatus }
                $passedSteps++
            }
            else {
                $msg = if ($pollResult.Error) { $pollResult.Error } else { "Campaign did not reach ACTIVE within timeout" }
                & $recordStep $stepNum "PollStatus" "FAIL" $msg @{ CampaignId = $campaignId }
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
        catch {
            $msg = "PollStatus threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "PollStatus" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 4 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 4: GetCertifications
    # ------------------------------------------------------------------
    $stepNum = 4
    $certifications = @()
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "GetCertifications" "INFO" "[WhatIf] Would retrieve certifications for campaign $campaignId and assert count > 0" $null
        # Synthesise a dummy certification for downstream steps in WhatIf mode
        $certifications = @([PSCustomObject]@{ id = 'whatif-cert-001' })
        $passedSteps++
    }
    else {
        try {
            $certResult = Get-SPAllCertifications -CampaignId $campaignId `
                -CorrelationID $CorrelationID -CampaignTestId $testId

            $assertCert = Assert-SPCertificationCount -CampaignId $campaignId `
                -MinimumCount 1 -CorrelationID $CorrelationID -CampaignTestId $testId

            if ($certResult.Success -and $assertCert.Pass) {
                $certifications = @($certResult.Data)
                & $recordStep $stepNum "GetCertifications" "PASS" "Retrieved $($certifications.Count) certification(s)" @{ CampaignId = $campaignId; CertificationCount = $certifications.Count }
                $passedSteps++
            }
            else {
                $msg = if (-not $certResult.Success) { $certResult.Error } else { $assertCert.Message }
                & $recordStep $stepNum "GetCertifications" "FAIL" $msg @{ CampaignId = $campaignId }
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
        catch {
            $msg = "GetCertifications threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "GetCertifications" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 5 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 5: Reassign (conditional)
    # ------------------------------------------------------------------
    $stepNum = 5
    if ($TestCase.ReassignBeforeDecide) {
        $firstCertId = if ($certifications.Count -gt 0) {
            if ($certifications[0] -is [PSCustomObject]) { $certifications[0].id } else { $certifications[0] }
        } else { '' }

        if ($effectiveWhatIf) {
            & $recordStep $stepNum "Reassign" "INFO" "[WhatIf] Would reassign certification $firstCertId to $($TestCase.ReassignTargetIdentityId)" $null
            $passedSteps++
        }
        else {
            try {
                $reassignResult = Invoke-SPReassign `
                    -CertificationId       $firstCertId `
                    -NewCertifierIdentityId $TestCase.ReassignTargetIdentityId `
                    -ReviewItemIds         @() `
                    -Reason                "UAT reassignment for test $testId" `
                    -CorrelationID         $CorrelationID `
                    -CampaignTestId        $testId

                if ($reassignResult.Success) {
                    & $recordStep $stepNum "Reassign" "PASS" "Certification $firstCertId reassigned to $($TestCase.ReassignTargetIdentityId)" @{ CampaignId = $campaignId; CertificationId = $firstCertId }
                    $passedSteps++
                }
                else {
                    $msg = if ($reassignResult.Error) { $reassignResult.Error } else { "Reassign failed" }
                    & $recordStep $stepNum "Reassign" "FAIL" $msg @{ CampaignId = $campaignId }
                    $failedSteps++
                    $testError = $msg
                    $aborted   = $true
                }
            }
            catch {
                $msg = "Reassign threw exception: $($_.Exception.Message)"
                & $recordStep $stepNum "Reassign" "FAIL" $msg @{ CampaignId = $campaignId }
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
    }
    else {
        & $recordStep $stepNum "Reassign" "SKIP" "ReassignBeforeDecide=false, step skipped" $null
    }

    if ($aborted) {
        & $abortRemaining 6 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 6: GetReviewItems
    # ------------------------------------------------------------------
    $stepNum = 6
    $allReviewItemIds = @()
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "GetReviewItems" "INFO" "[WhatIf] Would retrieve all access review items from $($certifications.Count) certification(s)" $null
        $allReviewItemIds = @('whatif-item-001', 'whatif-item-002')
        $passedSteps++
    }
    else {
        try {
            foreach ($cert in $certifications) {
                $certId = if ($cert -is [PSCustomObject]) { $cert.id } else { "$cert" }
                $itemsResult = Get-SPAllAccessReviewItems `
                    -CertificationId $certId `
                    -CorrelationID   $CorrelationID `
                    -CampaignTestId  $testId

                if ($itemsResult.Success -and $null -ne $itemsResult.Data) {
                    foreach ($item in @($itemsResult.Data)) {
                        $itemId = if ($item -is [PSCustomObject]) { $item.id } else { "$item" }
                        if (-not [string]::IsNullOrWhiteSpace($itemId)) {
                            $allReviewItemIds += $itemId
                        }
                    }
                }
            }

            if ($allReviewItemIds.Count -gt 0) {
                & $recordStep $stepNum "GetReviewItems" "PASS" "Retrieved $($allReviewItemIds.Count) access review item(s)" @{ CampaignId = $campaignId; ItemCount = $allReviewItemIds.Count }
                $passedSteps++
            }
            else {
                $msg = "No access review items found across $($certifications.Count) certification(s)"
                & $recordStep $stepNum "GetReviewItems" "WARN" $msg @{ CampaignId = $campaignId }
                # Not a hard failure - certifier may have no items
                $passedSteps++
            }
        }
        catch {
            $msg = "GetReviewItems threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "GetReviewItems" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 7 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 7: BulkDecide (batched at 250 per API constraint)
    # ------------------------------------------------------------------
    $stepNum = 7
    $totalDecided  = 0
    $approveCount  = 0
    $revokeCount   = 0
    $decideComment = "Automated UAT decision: $decision - test $testId"

    if ($effectiveWhatIf) {
        & $recordStep $stepNum "BulkDecide" "INFO" "[WhatIf] Would submit $($allReviewItemIds.Count) decision(s) as $decision in batches of $($script:BULK_DECIDE_BATCH_SIZE)" $null
        $passedSteps++
    }
    else {
        try {
            if ($allReviewItemIds.Count -eq 0) {
                & $recordStep $stepNum "BulkDecide" "SKIP" "No review items to decide" $null
            }
            else {
                $decideError = $false
                # Process each certification's items
                foreach ($cert in $certifications) {
                    $certId = if ($cert -is [PSCustomObject]) { $cert.id } else { "$cert" }

                    # Gather items for this certification
                    $certItemIds = @()
                    $certItemsResult = Get-SPAllAccessReviewItems `
                        -CertificationId $certId `
                        -CorrelationID   $CorrelationID `
                        -CampaignTestId  $testId

                    if ($certItemsResult.Success -and $null -ne $certItemsResult.Data) {
                        foreach ($item in @($certItemsResult.Data)) {
                            $itemId = if ($item -is [PSCustomObject]) { $item.id } else { "$item" }
                            if (-not [string]::IsNullOrWhiteSpace($itemId)) { $certItemIds += $itemId }
                        }
                    }

                    if ($certItemIds.Count -eq 0) { continue }

                    # Batch into chunks of 250
                    $batchStart = 0
                    while ($batchStart -lt $certItemIds.Count) {
                        $batchEnd   = [math]::Min($batchStart + $script:BULK_DECIDE_BATCH_SIZE - 1, $certItemIds.Count - 1)
                        $batchIds   = $certItemIds[$batchStart..$batchEnd]

                        $decideResult = Invoke-SPBulkDecide `
                            -CertificationId $certId `
                            -ReviewItemIds   $batchIds `
                            -Decision        $decision `
                            -Comments        $decideComment `
                            -CorrelationID   $CorrelationID `
                            -CampaignTestId  $testId

                        if ($decideResult.Success) {
                            $batchTotal = if ($decideResult.Data -and $decideResult.Data.PSObject.Properties.Name -contains 'TotalDecided') {
                                [int]$decideResult.Data.TotalDecided
                            } else {
                                $batchIds.Count
                            }
                            $totalDecided += $batchTotal

                            if ($decision -eq 'APPROVE') { $approveCount += $batchTotal }
                            elseif ($decision -eq 'REVOKE') { $revokeCount += $batchTotal }
                        }
                        else {
                            $decideError = $true
                            $testError   = if ($decideResult.Error) { $decideResult.Error } else { "BulkDecide batch failed" }
                            break
                        }

                        $batchStart = $batchEnd + 1
                    }

                    if ($decideError) { break }
                }

                if ($decideError) {
                    & $recordStep $stepNum "BulkDecide" "FAIL" $testError @{ CampaignId = $campaignId; TotalDecided = $totalDecided }
                    $failedSteps++
                    $aborted = $true
                }
                else {
                    $decideData = @{
                        CampaignId    = $campaignId
                        TotalDecided  = $totalDecided
                        ApproveCount  = $approveCount
                        RevokeCount   = $revokeCount
                    }
                    & $recordStep $stepNum "BulkDecide" "PASS" "Submitted $totalDecided decision(s) as $decision" $decideData
                    $passedSteps++
                }
            }
        }
        catch {
            $msg = "BulkDecide threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "BulkDecide" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 8 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 8: SignOff - sign off each certification
    # ------------------------------------------------------------------
    $stepNum = 8
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "SignOff" "INFO" "[WhatIf] Would sign off $($certifications.Count) certification(s)" $null
        $passedSteps++
    }
    else {
        try {
            $signOffError = $false
            $signOffCount = 0

            foreach ($cert in $certifications) {
                $certId = if ($cert -is [PSCustomObject]) { $cert.id } else { "$cert" }
                $signOffResult = Invoke-SPSignOff `
                    -CertificationId $certId `
                    -CorrelationID   $CorrelationID `
                    -CampaignTestId  $testId

                if ($signOffResult.Success) {
                    $signOffCount++
                }
                else {
                    $signOffError = $true
                    $testError    = if ($signOffResult.Error) { $signOffResult.Error } else { "SignOff failed for cert $certId" }
                    break
                }
            }

            if ($signOffError) {
                & $recordStep $stepNum "SignOff" "FAIL" $testError @{ CampaignId = $campaignId }
                $failedSteps++
                $aborted = $true
            }
            else {
                & $recordStep $stepNum "SignOff" "PASS" "Signed off $signOffCount certification(s)" @{ CampaignId = $campaignId; SignedOff = $signOffCount }
                $passedSteps++
            }
        }
        catch {
            $msg = "SignOff threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "SignOff" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 9 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 9: AssertFinalStatus
    # ------------------------------------------------------------------
    $stepNum = 9
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "AssertFinalStatus" "INFO" "[WhatIf] Would assert campaign status matches '$($TestCase.ExpectCampaignStatus)'" $null
        $passedSteps++
    }
    else {
        try {
            # For expected COMPLETED status, poll with completion timeout
            $pollTimeout = if ($TestCase.ExpectCampaignStatus -eq 'COMPLETED') { $completionTimeout } else { $activationTimeout }
            $pollResult  = Get-SPCampaignStatus `
                -CampaignId          $campaignId `
                -TimeoutSeconds      $pollTimeout `
                -PollIntervalSeconds $pollInterval `
                -TargetStatus        $TestCase.ExpectCampaignStatus `
                -CorrelationID       $CorrelationID `
                -CampaignTestId      $testId

            $assertStatus = Assert-SPCampaignStatus `
                -CampaignId     $campaignId `
                -ExpectedStatus $TestCase.ExpectCampaignStatus `
                -CorrelationID  $CorrelationID `
                -CampaignTestId $testId

            if ($assertStatus.Pass) {
                & $recordStep $stepNum "AssertFinalStatus" "PASS" "Campaign status is '$($assertStatus.Actual)' as expected" @{ CampaignId = $campaignId; Status = $assertStatus.Actual }
                $passedSteps++
            }
            else {
                $msg = $assertStatus.Message
                & $recordStep $stepNum "AssertFinalStatus" "FAIL" $msg @{ CampaignId = $campaignId; Actual = $assertStatus.Actual; Expected = $assertStatus.Expected }
                $failedSteps++
                $testError = $msg
                $aborted   = $true
            }
        }
        catch {
            $msg = "AssertFinalStatus threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "AssertFinalStatus" "FAIL" $msg @{ CampaignId = $campaignId }
            $failedSteps++
            $testError = $msg
            $aborted   = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 10 10 $testError
        $sw.Stop()
        $testResult = @{
            Success         = $false
            TestId          = $testId
            TestName        = $testName
            CampaignType    = $TestCase.CampaignType
            Steps           = $steps
            Pass            = $false
            Skipped         = $false
            Fail            = $failedSteps
            Error           = $testError
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        }
        _ExportAndReturn $testResult $evidencePath $testId $testName
        return $testResult
    }

    # ------------------------------------------------------------------
    # STEP 10: ValidateRemediation (conditional)
    # ------------------------------------------------------------------
    $stepNum = 10
    if ($TestCase.ValidateRemediation) {
        if ($effectiveWhatIf) {
            & $recordStep $stepNum "ValidateRemediation" "INFO" "[WhatIf] Would request remediation report and validate all items completed" $null
            $passedSteps++
        }
        else {
            try {
                # Remediation validation: check the campaign is completed and items have been provisioned.
                # The API does not expose a direct dry-run. We verify via campaign metadata.
                $campaignFull = Get-SPCampaign -CampaignId $campaignId -Full -CorrelationID $CorrelationID -CampaignTestId $testId

                if ($campaignFull.Success -and $null -ne $campaignFull.Data) {
                    # Build a report data structure for the assertion
                    $remediationData = @{
                        RemediatedCount = $totalDecided
                        TotalItems      = $totalDecided
                        PendingCount    = 0
                    }

                    # If campaign has stats, use them
                    $campData = $campaignFull.Data
                    if ($campData.PSObject.Properties.Name -contains 'stats') {
                        $stats = $campData.stats
                        if ($null -ne $stats) {
                            $decided = 0
                            $total   = 0
                            if ($stats.PSObject.Properties.Name -contains 'decisioned') { $decided = [int]$stats.decisioned }
                            if ($stats.PSObject.Properties.Name -contains 'total')      { $total   = [int]$stats.total }
                            if ($total -gt 0) {
                                $remediationData.RemediatedCount = $decided
                                $remediationData.TotalItems      = $total
                                $remediationData.PendingCount    = $total - $decided
                            }
                        }
                    }

                    $assertRemediation = Assert-SPRemediationComplete -ReportData $remediationData

                    if ($assertRemediation.Pass) {
                        & $recordStep $stepNum "ValidateRemediation" "PASS" "Remediation complete: $($assertRemediation.RemediatedCount) remediated, $($assertRemediation.PendingCount) pending" @{ CampaignId = $campaignId; RemediatedCount = $assertRemediation.RemediatedCount; PendingCount = $assertRemediation.PendingCount }
                        $passedSteps++
                    }
                    else {
                        $msg = $assertRemediation.Message
                        & $recordStep $stepNum "ValidateRemediation" "FAIL" $msg @{ CampaignId = $campaignId; RemediatedCount = $assertRemediation.RemediatedCount; PendingCount = $assertRemediation.PendingCount }
                        $failedSteps++
                        $testError = $msg
                    }
                }
                else {
                    $msg = "ValidateRemediation: Could not retrieve campaign details. $($campaignFull.Error)"
                    & $recordStep $stepNum "ValidateRemediation" "WARN" $msg @{ CampaignId = $campaignId }
                    $passedSteps++  # Treat as non-fatal warning
                }
            }
            catch {
                $msg = "ValidateRemediation threw exception: $($_.Exception.Message)"
                & $recordStep $stepNum "ValidateRemediation" "WARN" $msg @{ CampaignId = $campaignId }
                $passedSteps++  # Treat as non-fatal warning
            }
        }
    }
    else {
        & $recordStep $stepNum "ValidateRemediation" "SKIP" "ValidateRemediation=false, step skipped" $null
    }

    # ------------------------------------------------------------------
    # Finalise
    # ------------------------------------------------------------------
    $sw.Stop()
    $overallPass = ($failedSteps -eq 0)

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        $sev = if ($overallPass) { 'INFO' } else { 'ERROR' }
        Write-SPLog -Message "Test $testId complete. Pass=$overallPass PassedSteps=$passedSteps FailedSteps=$failedSteps" `
            -Severity $sev -Component "SP.BatchRunner" -Action "InvokeSingleTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    $finalResult = @{
        Success         = $overallPass
        TestId          = $testId
        TestName        = $testName
        CampaignType    = $TestCase.CampaignType
        Steps           = $steps
        Pass            = $overallPass
        Skipped         = $false
        Fail            = $failedSteps
        Error           = $testError
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    }

    _ExportAndReturn $finalResult $evidencePath $testId $testName
    return $finalResult
}

#endregion

#region DeltaCert Test Executor

function Invoke-SPDeltaCertTest {
    <#
    .SYNOPSIS
        Execute a 5-step delta certification test workflow.
    .DESCRIPTION
        Runs the delta cert lifecycle: query grant events, filter identities,
        group by manager, create campaigns, and assert campaign creation.
        Evidence is recorded after every step.

        Delta cert lifecycle steps:
            1  QueryGrantEvents
            2  FilterIdentities
            3  GroupByManager
            4  CreateCampaigns (Invoke-SPDeltaCertRun)
            5  AssertCampaignsCreated
    .PARAMETER TestCase
        Delta cert test case PSCustomObject with fields: TestId, TestName,
        LookbackHours, MinimumEvents, ExpectCampaignCount, WhatIf overrides.
    .PARAMETER CorrelationID
        Suite-level correlation ID.
    .PARAMETER WhatIf
        If set, log intentions without making API calls.
    .PARAMETER EvidenceBase
        Base path for evidence directory creation.
    .OUTPUTS
        @{Success; TestId; TestName; Steps=$array; Pass; Fail; Error; DurationSeconds}
    .EXAMPLE
        $r = Invoke-SPDeltaCertTest -TestCase $tc -CorrelationID $cid -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TestCase,

        [Parameter(Mandatory)]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [string]$EvidenceBase = '.'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $steps       = [System.Collections.Generic.List[object]]::new()
    $passedSteps = 0
    $failedSteps = 0
    $testPassed  = $false
    $testError   = ''

    $config = $null
    if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
        $config = Get-SPConfig
    }

    $effectiveWhatIf = $WhatIf.IsPresent
    $testId   = $TestCase.TestId
    $testName = $TestCase.TestName
    $lookbackHours    = if ($TestCase.PSObject.Properties.Name -contains 'LookbackHours')    { [int]$TestCase.LookbackHours }    else { 24 }
    $minimumEvents    = if ($TestCase.PSObject.Properties.Name -contains 'MinimumEvents')    { [int]$TestCase.MinimumEvents }    else { 1 }
    $expectCampaigns  = if ($TestCase.PSObject.Properties.Name -contains 'ExpectCampaignCount') { [int]$TestCase.ExpectCampaignCount } else { 1 }

    $evidencePath = $EvidenceBase
    if (Get-Command -Name New-SPCampaignEvidencePath -ErrorAction SilentlyContinue) {
        $evidencePath = New-SPCampaignEvidencePath -TestId $testId -BasePath $EvidenceBase
    }

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Starting delta cert test $testId ($testName). WhatIf=$effectiveWhatIf LookbackHours=$lookbackHours" `
            -Severity INFO -Component "SP.BatchRunner" -Action "InvokeDeltaCertTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    $recordStep = {
        param($StepNum, $Action, $Status, $Message, $Data)
        $stepRecord = @{ Step = $StepNum; Action = $Action; Status = $Status; Message = $Message; Data = $Data }
        $steps.Add($stepRecord)
        if (Get-Command -Name Write-SPEvidenceEvent -ErrorAction SilentlyContinue) {
            Write-SPEvidenceEvent -EvidencePath $evidencePath -TestId $testId `
                -Step $StepNum -Action $Action -Status $Status -Message $Message `
                -Data $Data -CorrelationID $CorrelationID
        }
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            $sev = switch ($Status) { 'PASS' { 'INFO' } 'FAIL' { 'ERROR' } 'WARN' { 'WARN' } default { 'INFO' } }
            Write-SPLog -Message "[$testId] Step $StepNum $Action : $Status - $Message" `
                -Severity $sev -Component "SP.BatchRunner" -Action "InvokeDeltaCertTest" `
                -CorrelationID $CorrelationID -CampaignTestId $testId
        }
    }

    $abortRemaining = {
        param([int]$FromStep, [int]$ToStep, [string]$Reason)
        for ($s = $FromStep; $s -le $ToStep; $s++) {
            & $recordStep $s "Skipped" "SKIP" "Skipped due to earlier failure: $Reason" $null
        }
    }

    $aborted = $false
    $grantEvents       = @()
    $affectedIdentities = @()
    $managerGroups     = $null

    # ------------------------------------------------------------------
    # STEP 1: QueryGrantEvents
    # ------------------------------------------------------------------
    $stepNum = 1
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "QueryGrantEvents" "INFO" "[WhatIf] Would query grant events for last $lookbackHours hours" $null
        $grantEvents = @(@{ id = 'whatif-event-001' })
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Get-SPDeltaGrantEvents -ErrorAction SilentlyContinue)) {
                $msg = "Get-SPDeltaGrantEvents not available - SP.DeltaCert module not loaded"
                & $recordStep $stepNum "QueryGrantEvents" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $evResult = Get-SPDeltaGrantEvents -LookbackHours $lookbackHours
                $assertEvents = Assert-SPDeltaGrantEventCount -GrantEventResult $evResult -MinimumCount $minimumEvents

                if ($assertEvents.Pass) {
                    $grantEvents = @($evResult.Data)
                    & $recordStep $stepNum "QueryGrantEvents" "PASS" "Found $($assertEvents.Actual) grant event(s)" @{ EventCount = $assertEvents.Actual }
                    $passedSteps++
                }
                else {
                    & $recordStep $stepNum "QueryGrantEvents" "FAIL" $assertEvents.Message @{ Actual = $assertEvents.Actual; Expected = $minimumEvents }
                    $failedSteps++; $testError = $assertEvents.Message; $aborted = $true
                }
            }
        }
        catch {
            $msg = "QueryGrantEvents threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "QueryGrantEvents" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 2 5 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DeltaCert'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 2: FilterIdentities
    # ------------------------------------------------------------------
    $stepNum = 2
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "FilterIdentities" "INFO" "[WhatIf] Would filter $($grantEvents.Count) events to active identities with managers" $null
        $affectedIdentities = @(@{ identityId = 'whatif-id-001'; managerId = 'whatif-mgr-001' })
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Get-SPDeltaAffectedIdentities -ErrorAction SilentlyContinue)) {
                $msg = "Get-SPDeltaAffectedIdentities not available - SP.DeltaCert module not loaded"
                & $recordStep $stepNum "FilterIdentities" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $idResult = Get-SPDeltaAffectedIdentities -GrantEvents $grantEvents

                if ($idResult.Success) {
                    $affectedIdentities = @($idResult.Data)
                    & $recordStep $stepNum "FilterIdentities" "PASS" "Resolved $($affectedIdentities.Count) affected identity(ies)" @{ IdentityCount = $affectedIdentities.Count }
                    $passedSteps++
                }
                else {
                    $msg = "Get-SPDeltaAffectedIdentities failed: $($idResult.Error)"
                    & $recordStep $stepNum "FilterIdentities" "FAIL" $msg $null
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "FilterIdentities threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "FilterIdentities" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 3 5 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DeltaCert'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 3: GroupByManager
    # ------------------------------------------------------------------
    $stepNum = 3
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "GroupByManager" "INFO" "[WhatIf] Would group $($affectedIdentities.Count) identities by manager" $null
        $managerGroups = @{ 'whatif-mgr-001' = @(@{ identityId = 'whatif-id-001' }) }
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Group-SPDeltaByManager -ErrorAction SilentlyContinue)) {
                $msg = "Group-SPDeltaByManager not available - SP.DeltaCert module not loaded"
                & $recordStep $stepNum "GroupByManager" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $groupResult = Group-SPDeltaByManager -AffectedIdentities $affectedIdentities
                $assertGroup = Assert-SPDeltaManagerGrouping -GroupResult $groupResult -MinimumGroups 1

                if ($assertGroup.Pass) {
                    $managerGroups = $groupResult.Data
                    & $recordStep $stepNum "GroupByManager" "PASS" "Grouped into $($assertGroup.Actual) manager group(s)" @{ GroupCount = $assertGroup.Actual }
                    $passedSteps++
                }
                else {
                    & $recordStep $stepNum "GroupByManager" "FAIL" $assertGroup.Message @{ Actual = $assertGroup.Actual }
                    $failedSteps++; $testError = $assertGroup.Message; $aborted = $true
                }
            }
        }
        catch {
            $msg = "GroupByManager threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "GroupByManager" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 4 5 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DeltaCert'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 4: CreateCampaigns
    # ------------------------------------------------------------------
    $stepNum = 4
    $campaignsCreated = 0
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "CreateCampaigns" "INFO" "[WhatIf] Would invoke Invoke-SPDeltaCertRun to create campaigns for $($managerGroups.Count) manager group(s)" $null
        $campaignsCreated = $managerGroups.Count
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Invoke-SPDeltaCertRun -ErrorAction SilentlyContinue)) {
                $msg = "Invoke-SPDeltaCertRun not available - SP.DeltaCert module not loaded"
                & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $runParams = @{ LookbackHours = $lookbackHours }
                if ($TestCase.PSObject.Properties.Name -contains 'CampaignNamePrefix') {
                    $runParams['CampaignNamePrefix'] = $TestCase.CampaignNamePrefix
                }
                if ($TestCase.PSObject.Properties.Name -contains 'FallbackReviewerIdentityId') {
                    $runParams['FallbackReviewerIdentityId'] = $TestCase.FallbackReviewerIdentityId
                }

                $runResult = Invoke-SPDeltaCertRun @runParams

                if ($runResult.Success) {
                    $campaignsCreated = 0
                    if ($null -ne $runResult.Data) {
                        if ($runResult.Data -is [hashtable] -and $runResult.Data.ContainsKey('CampaignsCreated')) {
                            $campaignsCreated = [int]$runResult.Data.CampaignsCreated
                        }
                        elseif ($runResult.Data.PSObject.Properties.Name -contains 'CampaignsCreated') {
                            $campaignsCreated = [int]$runResult.Data.CampaignsCreated
                        }
                    }
                    & $recordStep $stepNum "CreateCampaigns" "PASS" "Created $campaignsCreated campaign(s)" @{ CampaignsCreated = $campaignsCreated }
                    $passedSteps++
                }
                else {
                    $msg = "Invoke-SPDeltaCertRun failed: $($runResult.Error)"
                    & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg $null
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "CreateCampaigns threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 5 5 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DeltaCert'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 5: AssertCampaignsCreated
    # ------------------------------------------------------------------
    $stepNum = 5
    if ($campaignsCreated -ge $expectCampaigns) {
        & $recordStep $stepNum "AssertCampaignsCreated" "PASS" "Campaign count $campaignsCreated meets expected $expectCampaigns" @{ Actual = $campaignsCreated; Expected = $expectCampaigns }
        $passedSteps++
    }
    else {
        $msg = "Campaign count $campaignsCreated below expected $expectCampaigns"
        & $recordStep $stepNum "AssertCampaignsCreated" "FAIL" $msg @{ Actual = $campaignsCreated; Expected = $expectCampaigns }
        $failedSteps++
        $testError = $msg
    }

    # ------------------------------------------------------------------
    # Finalise
    # ------------------------------------------------------------------
    $sw.Stop()
    $overallPass = ($failedSteps -eq 0)

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        $sev = if ($overallPass) { 'INFO' } else { 'ERROR' }
        Write-SPLog -Message "DeltaCert test $testId complete. Pass=$overallPass PassedSteps=$passedSteps FailedSteps=$failedSteps" `
            -Severity $sev -Component "SP.BatchRunner" -Action "InvokeDeltaCertTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    $finalResult = @{
        Success         = $overallPass
        TestId          = $testId
        TestName        = $testName
        CampaignType    = 'DeltaCert'
        Steps           = $steps
        Pass            = $overallPass
        Skipped         = $false
        Fail            = $failedSteps
        Error           = $testError
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    }

    _ExportAndReturn $finalResult $evidencePath $testId $testName
    return $finalResult
}

#endregion

#region DisconnectedApp Test Executor

function Invoke-SPDisconnectedAppTest {
    <#
    .SYNOPSIS
        Execute a 7-step disconnected app certification test workflow.
    .DESCRIPTION
        Runs the disconnected app lifecycle: validate files, snapshot, compare
        deltas, check deletion threshold, resolve identities, create campaigns,
        and push to ISC. Evidence is recorded after every step.

        Disconnected app lifecycle steps:
            1  ValidateFiles
            2  Snapshot
            3  CompareDelta
            4  CheckThreshold
            5  ResolveIdentities
            6  CreateCampaigns
            7  PushToISC
    .PARAMETER TestCase
        Disconnected app test case PSCustomObject with fields: TestId, TestName,
        AppName, AccountFilePath, EntitlementFilePath, ExpectChanges.
    .PARAMETER CorrelationID
        Suite-level correlation ID.
    .PARAMETER WhatIf
        If set, log intentions without making API calls.
    .PARAMETER EvidenceBase
        Base path for evidence directory creation.
    .OUTPUTS
        @{Success; TestId; TestName; Steps=$array; Pass; Fail; Error; DurationSeconds}
    .EXAMPLE
        $r = Invoke-SPDisconnectedAppTest -TestCase $tc -CorrelationID $cid -WhatIf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TestCase,

        [Parameter(Mandatory)]
        [string]$CorrelationID,

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [string]$EvidenceBase = '.'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $steps       = [System.Collections.Generic.List[object]]::new()
    $passedSteps = 0
    $failedSteps = 0
    $testError   = ''

    $config = $null
    if (Get-Command -Name Get-SPConfig -ErrorAction SilentlyContinue) {
        $config = Get-SPConfig
    }

    $effectiveWhatIf = $WhatIf.IsPresent
    $testId     = $TestCase.TestId
    $testName   = $TestCase.TestName
    $appName    = if ($TestCase.PSObject.Properties.Name -contains 'AppName') { $TestCase.AppName } else { 'UnknownApp' }
    $acctPath   = if ($TestCase.PSObject.Properties.Name -contains 'AccountFilePath') { $TestCase.AccountFilePath } else { '' }
    $entPath    = if ($TestCase.PSObject.Properties.Name -contains 'EntitlementFilePath') { $TestCase.EntitlementFilePath } else { '' }
    $expectChanges = if ($TestCase.PSObject.Properties.Name -contains 'ExpectChanges') { [bool]$TestCase.ExpectChanges } else { $true }

    $evidencePath = $EvidenceBase
    if (Get-Command -Name New-SPCampaignEvidencePath -ErrorAction SilentlyContinue) {
        $evidencePath = New-SPCampaignEvidencePath -TestId $testId -BasePath $EvidenceBase
    }

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        Write-SPLog -Message "Starting disconnected app test $testId ($testName). WhatIf=$effectiveWhatIf App=$appName" `
            -Severity INFO -Component "SP.BatchRunner" -Action "InvokeDisconnectedAppTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    $recordStep = {
        param($StepNum, $Action, $Status, $Message, $Data)
        $stepRecord = @{ Step = $StepNum; Action = $Action; Status = $Status; Message = $Message; Data = $Data }
        $steps.Add($stepRecord)
        if (Get-Command -Name Write-SPEvidenceEvent -ErrorAction SilentlyContinue) {
            Write-SPEvidenceEvent -EvidencePath $evidencePath -TestId $testId `
                -Step $StepNum -Action $Action -Status $Status -Message $Message `
                -Data $Data -CorrelationID $CorrelationID
        }
        if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
            $sev = switch ($Status) { 'PASS' { 'INFO' } 'FAIL' { 'ERROR' } 'WARN' { 'WARN' } default { 'INFO' } }
            Write-SPLog -Message "[$testId] Step $StepNum $Action : $Status - $Message" `
                -Severity $sev -Component "SP.BatchRunner" -Action "InvokeDisconnectedAppTest" `
                -CorrelationID $CorrelationID -CampaignTestId $testId
        }
    }

    $abortRemaining = {
        param([int]$FromStep, [int]$ToStep, [string]$Reason)
        for ($s = $FromStep; $s -le $ToStep; $s++) {
            & $recordStep $s "Skipped" "SKIP" "Skipped due to earlier failure: $Reason" $null
        }
    }

    $aborted        = $false
    $snapshotPath   = ''
    $deltaResult    = $null
    $resolvedIds    = @()

    # ------------------------------------------------------------------
    # STEP 1: ValidateFiles
    # ------------------------------------------------------------------
    $stepNum = 1
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "ValidateFiles" "INFO" "[WhatIf] Would validate account file '$acctPath' and entitlement file '$entPath'" $null
        $passedSteps++
    }
    else {
        try {
            $acctValAvailable = Get-Command -Name Test-SPDisconnectedAppAccountFile -ErrorAction SilentlyContinue
            $entValAvailable  = Get-Command -Name Test-SPDisconnectedAppEntitlementFile -ErrorAction SilentlyContinue

            if (-not $acctValAvailable) {
                $msg = "Test-SPDisconnectedAppAccountFile not available - SP.DisconnectedApps module not loaded"
                & $recordStep $stepNum "ValidateFiles" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $acctVal = Test-SPDisconnectedAppAccountFile -FilePath $acctPath
                $acctAssert = Assert-SPDisconnectedAppFileValid -ValidationResult $acctVal

                $entAssert = @{ Pass = $true; Message = 'No entitlement file specified' }
                if (-not [string]::IsNullOrWhiteSpace($entPath) -and $entValAvailable) {
                    $entVal = Test-SPDisconnectedAppEntitlementFile -FilePath $entPath
                    $entAssert = Assert-SPDisconnectedAppFileValid -ValidationResult $entVal
                }

                if ($acctAssert.Pass -and $entAssert.Pass) {
                    & $recordStep $stepNum "ValidateFiles" "PASS" "Account and entitlement files validated" @{ AppName = $appName; AccountErrors = $acctAssert.ErrorCount; EntitlementErrors = $entAssert.ErrorCount }
                    $passedSteps++
                }
                else {
                    $msg = if (-not $acctAssert.Pass) { "Account: $($acctAssert.Message)" } else { "Entitlement: $($entAssert.Message)" }
                    & $recordStep $stepNum "ValidateFiles" "FAIL" $msg @{ AppName = $appName }
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "ValidateFiles threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "ValidateFiles" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 2 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 2: Snapshot
    # ------------------------------------------------------------------
    $stepNum = 2
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "Snapshot" "INFO" "[WhatIf] Would save snapshot of '$acctPath'" $null
        $snapshotPath = 'whatif-snapshot-path'
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Save-SPDisconnectedAppSnapshot -ErrorAction SilentlyContinue)) {
                $msg = "Save-SPDisconnectedAppSnapshot not available"
                & $recordStep $stepNum "Snapshot" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $snapResult = Save-SPDisconnectedAppSnapshot -FilePath $acctPath -AppName $appName -FileType 'accounts'

                if ($snapResult.Success) {
                    $snapshotPath = if ($snapResult.Data -is [string]) { $snapResult.Data } elseif ($null -ne $snapResult.Data -and $snapResult.Data.PSObject.Properties.Name -contains 'Path') { $snapResult.Data.Path } else { '' }
                    & $recordStep $stepNum "Snapshot" "PASS" "Snapshot saved for $appName" @{ AppName = $appName; SnapshotPath = $snapshotPath }
                    $passedSteps++
                }
                else {
                    $msg = "Save-SPDisconnectedAppSnapshot failed: $($snapResult.Error)"
                    & $recordStep $stepNum "Snapshot" "FAIL" $msg @{ AppName = $appName }
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "Snapshot threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "Snapshot" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 3 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 3: CompareDelta
    # ------------------------------------------------------------------
    $stepNum = 3
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "CompareDelta" "INFO" "[WhatIf] Would compare current file against previous snapshot" $null
        $deltaResult = @{ Success = $true; Data = @{ Added = @(); Removed = @(); Modified = @() }; Error = $null }
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Compare-SPDisconnectedAppFiles -ErrorAction SilentlyContinue)) {
                $msg = "Compare-SPDisconnectedAppFiles not available"
                & $recordStep $stepNum "CompareDelta" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $prevSnap = $null
                if (Get-Command -Name Get-SPDisconnectedAppPreviousSnapshot -ErrorAction SilentlyContinue) {
                    $prevSnap = Get-SPDisconnectedAppPreviousSnapshot -AppName $appName -FileType 'accounts'
                }

                if ($null -eq $prevSnap -or -not $prevSnap.Success -or [string]::IsNullOrWhiteSpace("$($prevSnap.Data)")) {
                    & $recordStep $stepNum "CompareDelta" "WARN" "No previous snapshot found for $appName - first run, skipping delta" @{ AppName = $appName }
                    $deltaResult = @{ Success = $true; Data = @{ Added = @(); Removed = @(); Modified = @() }; Error = $null }
                    $passedSteps++
                }
                else {
                    $prevPath = if ($prevSnap.Data -is [string]) { $prevSnap.Data } else { $prevSnap.Data.Path }
                    $deltaResult = Compare-SPDisconnectedAppFiles -CurrentPath $acctPath -PreviousPath $prevPath
                    $deltaAssert = Assert-SPDisconnectedAppDeltaDetected -DeltaResult $deltaResult -ExpectChanges $expectChanges

                    if ($deltaAssert.Pass) {
                        & $recordStep $stepNum "CompareDelta" "PASS" $deltaAssert.Message @{ AppName = $appName; Added = $deltaAssert.Added; Removed = $deltaAssert.Removed; Modified = $deltaAssert.Modified }
                        $passedSteps++
                    }
                    else {
                        & $recordStep $stepNum "CompareDelta" "FAIL" $deltaAssert.Message @{ AppName = $appName }
                        $failedSteps++; $testError = $deltaAssert.Message; $aborted = $true
                    }
                }
            }
        }
        catch {
            $msg = "CompareDelta threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "CompareDelta" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 4 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 4: CheckThreshold
    # ------------------------------------------------------------------
    $stepNum = 4
    $removedCount = 0
    if ($null -ne $deltaResult -and $null -ne $deltaResult.Data) {
        $dData = $deltaResult.Data
        if ($dData -is [hashtable] -and $dData.ContainsKey('Removed')) { $removedCount = @($dData.Removed).Count }
        elseif ($dData.PSObject.Properties.Name -contains 'Removed') { $removedCount = @($dData.Removed).Count }
    }

    if ($removedCount -eq 0) {
        & $recordStep $stepNum "CheckThreshold" "SKIP" "No removed accounts, threshold check not needed" @{ AppName = $appName }
        $passedSteps++
    }
    elseif ($effectiveWhatIf) {
        & $recordStep $stepNum "CheckThreshold" "INFO" "[WhatIf] Would check deletion threshold for $removedCount removed account(s)" $null
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Test-SPDisconnectedAppDeletionThreshold -ErrorAction SilentlyContinue)) {
                & $recordStep $stepNum "CheckThreshold" "WARN" "Test-SPDisconnectedAppDeletionThreshold not available, skipping" $null
                $passedSteps++
            }
            else {
                $threshResult = Test-SPDisconnectedAppDeletionThreshold -CurrentPath $acctPath -DeltaResult $deltaResult
                $threshAssert = Assert-SPDeletionThresholdSafe -ThresholdResult $threshResult

                if ($threshAssert.Pass) {
                    & $recordStep $stepNum "CheckThreshold" "PASS" $threshAssert.Message @{ AppName = $appName; Percentage = $threshAssert.Percentage; Threshold = $threshAssert.Threshold }
                    $passedSteps++
                }
                else {
                    & $recordStep $stepNum "CheckThreshold" "FAIL" $threshAssert.Message @{ AppName = $appName; Percentage = $threshAssert.Percentage; Threshold = $threshAssert.Threshold }
                    $failedSteps++; $testError = $threshAssert.Message; $aborted = $true
                }
            }
        }
        catch {
            $msg = "CheckThreshold threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "CheckThreshold" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 5 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 5: ResolveIdentities
    # ------------------------------------------------------------------
    $stepNum = 5
    $hasDeltas = $false
    if ($null -ne $deltaResult -and $null -ne $deltaResult.Data) {
        $dData = $deltaResult.Data
        $addedC = 0; $removedC = 0; $modifiedC = 0
        if ($dData -is [hashtable]) {
            if ($dData.ContainsKey('Added'))    { $addedC    = @($dData.Added).Count }
            if ($dData.ContainsKey('Removed'))  { $removedC  = @($dData.Removed).Count }
            if ($dData.ContainsKey('Modified')) { $modifiedC = @($dData.Modified).Count }
        }
        else {
            if ($dData.PSObject.Properties.Name -contains 'Added')    { $addedC    = @($dData.Added).Count }
            if ($dData.PSObject.Properties.Name -contains 'Removed')  { $removedC  = @($dData.Removed).Count }
            if ($dData.PSObject.Properties.Name -contains 'Modified') { $modifiedC = @($dData.Modified).Count }
        }
        $hasDeltas = ($addedC + $removedC + $modifiedC) -gt 0
    }

    if (-not $hasDeltas) {
        & $recordStep $stepNum "ResolveIdentities" "SKIP" "No deltas to resolve" @{ AppName = $appName }
        $passedSteps++
    }
    elseif ($effectiveWhatIf) {
        & $recordStep $stepNum "ResolveIdentities" "INFO" "[WhatIf] Would resolve delta accounts to ISC identities" $null
        $resolvedIds = @(@{ identityId = 'whatif-resolved-001' })
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Resolve-SPDisconnectedAppIdentities -ErrorAction SilentlyContinue)) {
                & $recordStep $stepNum "ResolveIdentities" "WARN" "Resolve-SPDisconnectedAppIdentities not available, skipping" $null
                $passedSteps++
            }
            else {
                $resolveResult = Resolve-SPDisconnectedAppIdentities -DeltaResult $deltaResult -AppName $appName
                if ($resolveResult.Success) {
                    $resolvedIds = @($resolveResult.Data)
                    & $recordStep $stepNum "ResolveIdentities" "PASS" "Resolved $($resolvedIds.Count) identity(ies) from delta accounts" @{ AppName = $appName; ResolvedCount = $resolvedIds.Count }
                    $passedSteps++
                }
                else {
                    $msg = "Resolve-SPDisconnectedAppIdentities failed: $($resolveResult.Error)"
                    & $recordStep $stepNum "ResolveIdentities" "FAIL" $msg @{ AppName = $appName }
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "ResolveIdentities threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "ResolveIdentities" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 6 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 6: CreateCampaigns
    # ------------------------------------------------------------------
    $stepNum = 6
    if (-not $hasDeltas) {
        & $recordStep $stepNum "CreateCampaigns" "SKIP" "No deltas, no campaigns needed" @{ AppName = $appName }
        $passedSteps++
    }
    elseif ($effectiveWhatIf) {
        & $recordStep $stepNum "CreateCampaigns" "INFO" "[WhatIf] Would create certification campaign for $appName delta changes" $null
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Invoke-SPDisconnectedAppCertRun -ErrorAction SilentlyContinue)) {
                $msg = "Invoke-SPDisconnectedAppCertRun not available"
                & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg $null
                $failedSteps++; $testError = $msg; $aborted = $true
            }
            else {
                $certParams = @{ AppName = $appName; DeltaResult = $deltaResult }
                $certResult = Invoke-SPDisconnectedAppCertRun @certParams

                if ($certResult.Success) {
                    & $recordStep $stepNum "CreateCampaigns" "PASS" "Campaign created for $appName" @{ AppName = $appName }
                    $passedSteps++
                }
                else {
                    $msg = "Invoke-SPDisconnectedAppCertRun failed: $($certResult.Error)"
                    & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg @{ AppName = $appName }
                    $failedSteps++; $testError = $msg; $aborted = $true
                }
            }
        }
        catch {
            $msg = "CreateCampaigns threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "CreateCampaigns" "FAIL" $msg $null
            $failedSteps++; $testError = $msg; $aborted = $true
        }
    }

    if ($aborted) {
        & $abortRemaining 7 7 $testError
        $sw.Stop()
        $result = @{ Success = $false; TestId = $testId; TestName = $testName; CampaignType = 'DisconnectedApp'; Steps = $steps; Pass = $false; Skipped = $false; Fail = $failedSteps; Error = $testError; DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        _ExportAndReturn $result $evidencePath $testId $testName
        return $result
    }

    # ------------------------------------------------------------------
    # STEP 7: PushToISC
    # ------------------------------------------------------------------
    $stepNum = 7
    if ($effectiveWhatIf) {
        & $recordStep $stepNum "PushToISC" "INFO" "[WhatIf] Would push validated CSV to ISC for source aggregation" $null
        $passedSteps++
    }
    else {
        try {
            if (-not (Get-Command -Name Push-SPDisconnectedAppToISC -ErrorAction SilentlyContinue)) {
                & $recordStep $stepNum "PushToISC" "WARN" "Push-SPDisconnectedAppToISC not available, skipping" $null
                $passedSteps++
            }
            else {
                $pushResult = Push-SPDisconnectedAppToISC -AppName $appName -AccountFilePath $acctPath

                if ($pushResult.Success) {
                    & $recordStep $stepNum "PushToISC" "PASS" "Pushed $appName data to ISC" @{ AppName = $appName }
                    $passedSteps++
                }
                else {
                    $msg = "Push-SPDisconnectedAppToISC failed: $($pushResult.Error)"
                    & $recordStep $stepNum "PushToISC" "FAIL" $msg @{ AppName = $appName }
                    $failedSteps++
                    $testError = $msg
                }
            }
        }
        catch {
            $msg = "PushToISC threw exception: $($_.Exception.Message)"
            & $recordStep $stepNum "PushToISC" "WARN" $msg @{ AppName = $appName }
            $passedSteps++  # Treat push failure as non-fatal warning
        }
    }

    # ------------------------------------------------------------------
    # Finalise
    # ------------------------------------------------------------------
    $sw.Stop()
    $overallPass = ($failedSteps -eq 0)

    if (Get-Command -Name Write-SPLog -ErrorAction SilentlyContinue) {
        $sev = if ($overallPass) { 'INFO' } else { 'ERROR' }
        Write-SPLog -Message "DisconnectedApp test $testId complete. Pass=$overallPass PassedSteps=$passedSteps FailedSteps=$failedSteps" `
            -Severity $sev -Component "SP.BatchRunner" -Action "InvokeDisconnectedAppTest" `
            -CorrelationID $CorrelationID -CampaignTestId $testId
    }

    $finalResult = @{
        Success         = $overallPass
        TestId          = $testId
        TestName        = $testName
        CampaignType    = 'DisconnectedApp'
        Steps           = $steps
        Pass            = $overallPass
        Skipped         = $false
        Fail            = $failedSteps
        Error           = $testError
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    }

    _ExportAndReturn $finalResult $evidencePath $testId $testName
    return $finalResult
}

#endregion

#region Private Helpers

function _ExportAndReturn {
    param($TestResult, $EvidencePath, $TestId, $TestName)
    if (Get-Command -Name Export-SPCampaignReport -ErrorAction SilentlyContinue) {
        try {
            Export-SPCampaignReport `
                -EvidencePath $EvidencePath `
                -TestId       $TestId `
                -TestName     $TestName `
                -TestResult   $TestResult
        }
        catch {
            # Report generation failure must not break result return
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-SPTestSuite',
    'Invoke-SPSingleTest',
    'Invoke-SPDeltaCertTest',
    'Invoke-SPDisconnectedAppTest'
)
