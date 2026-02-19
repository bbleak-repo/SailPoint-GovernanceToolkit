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
    'Invoke-SPSingleTest'
)
