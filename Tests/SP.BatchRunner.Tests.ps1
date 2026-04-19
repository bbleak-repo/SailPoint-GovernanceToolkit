#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.BatchRunner module.
.DESCRIPTION
    Tests suite orchestration, stop-on-failure, WhatIf mode execution,
    and safety limit enforcement.
    Test IDs: BATCH-001 through BATCH-004.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Testing

    # Mock all SP.Core functions
    Mock -ModuleName SP.BatchRunner -CommandName Get-SPConfig {
        [PSCustomObject]@{
            ISC     = [PSCustomObject]@{ TenantUrl = 'https://test.identitynow.com' }
            Global  = [PSCustomObject]@{ Environment = 'NonProd' }
            Testing = [PSCustomObject]@{
                EvidencePath                      = $TestDrive
                ReportsPath                       = $TestDrive
                DecisionBatchSize                 = 250
                DefaultDecision                   = 'APPROVE'
                CampaignActivationTimeoutSeconds  = 30
                CampaignCompleteTimeoutSeconds    = 60
                WhatIfByDefault                   = $false
            }
            Safety  = [PSCustomObject]@{
                MaxCampaignsPerRun      = 10
                RequireWhatIfOnProd     = $false
                AllowCompleteCampaign   = $true
            }
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Write-SPLog { }

    # Mock all SP.Api functions to return successful results
    Mock -ModuleName SP.BatchRunner -CommandName New-SPCampaign {
        param($Name, $Type, $CertifierIdentityId, $SourceId, $SearchFilter, $RoleId, $Description, $CorrelationID, $CampaignTestId)
        @{
            Success = $true
            Data    = @{ id = "camp-mock-$([guid]::NewGuid().ToString('N').Substring(0,8))"; name = $Name; type = $Type; status = 'STAGED' }
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Start-SPCampaign {
        @{ Success = $true; Data = @{}; Error = $null }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Get-SPCampaign {
        param($CampaignId, $Full)
        @{
            Success = $true
            Data    = [PSCustomObject]@{ id = $CampaignId; status = 'COMPLETED'; name = 'MockCampaign' }
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Get-SPCampaignStatus {
        param($CampaignId, $TimeoutSeconds, $PollIntervalSeconds, $TargetStatus)
        @{
            Success = $true
            Data    = @{ Status = $TargetStatus; Campaign = @{ id = $CampaignId; status = $TargetStatus } }
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Get-SPAllCertifications {
        param($CampaignId)
        @{
            Success = $true
            Data    = @(
                [PSCustomObject]@{ id = "cert-mock-001"; campaignId = $CampaignId }
            )
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Get-SPAllAccessReviewItems {
        param($CertificationId)
        @{
            Success = $true
            Data    = @(
                [PSCustomObject]@{ id = "item-001"; certificationId = $CertificationId },
                [PSCustomObject]@{ id = "item-002"; certificationId = $CertificationId }
            )
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Invoke-SPBulkDecide {
        param($CertificationId, $ReviewItemIds, $Decision, $Comments)
        @{
            Success = $true
            Data    = [PSCustomObject]@{
                BatchResults  = @()
                TotalDecided  = $ReviewItemIds.Count
            }
            Error   = $null
        }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Invoke-SPReassign {
        @{ Success = $true; Data = @{}; Error = $null }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Invoke-SPSignOff {
        @{ Success = $true; Error = $null }
    }

    Mock -ModuleName SP.BatchRunner -CommandName Complete-SPCampaign {
        @{ Success = $true; Error = $null }
    }

    # Suppress report generation to avoid file I/O in tests
    Mock -ModuleName SP.BatchRunner -CommandName Export-SPCampaignReport { }
    Mock -ModuleName SP.BatchRunner -CommandName Export-SPSuiteReport    { }
    Mock -ModuleName SP.BatchRunner -CommandName Write-SPEvidenceEvent   { }
    Mock -ModuleName SP.BatchRunner -CommandName New-SPCampaignEvidencePath { return $TestDrive }

    # Helper: build standard test identities
    $script:TestIdentities = @{
        'id-alice-001' = [PSCustomObject]@{
            IdentityId       = 'id-alice-001'
            DisplayName      = 'Alice Johnson'
            Email            = 'alice@lab.local'
            Role             = 'CertificationOwner'
            CertifierFor     = 'SOURCE_OWNER'
            IsReassignTarget = $false
        }
        'id-bob-002'   = [PSCustomObject]@{
            IdentityId       = 'id-bob-002'
            DisplayName      = 'Bob Smith'
            Email            = 'bob@lab.local'
            Role             = 'Manager'
            CertifierFor     = 'MANAGER'
            IsReassignTarget = $true
        }
        'id-carol-003' = [PSCustomObject]@{
            IdentityId       = 'id-carol-003'
            DisplayName      = 'Carol White'
            Email            = 'carol@lab.local'
            Role             = 'Certifier'
            CertifierFor     = 'SEARCH'
            IsReassignTarget = $false
        }
    }

    # Helper: build standard test campaigns array
    function New-MockCampaigns {
        param([int]$Count = 2)
        $out = @()
        for ($i = 1; $i -le $Count; $i++) {
            $out += [PSCustomObject]@{
                TestId                   = "TC-$('{0:D3}' -f $i)"
                TestName                 = "Test Campaign $i"
                CampaignType             = 'SOURCE_OWNER'
                CampaignName             = "UAT-Mock-$i"
                CertifierIdentityId      = 'id-alice-001'
                ReassignTargetIdentityId = ''
                SourceId                 = "src-00$i"
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = $i
                Tags                     = 'smoke'
            }
        }
        return $out
    }
}

# ---------------------------------------------------------------------------
# BATCH-001: Invoke-SPTestSuite runs all campaigns
# ---------------------------------------------------------------------------
Describe "BATCH-001: Invoke-SPTestSuite runs all campaigns" {
    It "Should execute all campaigns and return aggregated results" {
        $campaigns = New-MockCampaigns -Count 3
        $cid = [guid]::NewGuid().ToString()

        $result = Invoke-SPTestSuite `
            -Campaigns     $campaigns `
            -Identities    $script:TestIdentities `
            -CorrelationID $cid

        $result            | Should -Not -BeNullOrEmpty
        $result.Results    | Should -Not -BeNullOrEmpty
        $result.Results.Count | Should -Be 3
        $result.PassCount  | Should -Be 3
        $result.FailCount  | Should -Be 0
        $result.SkipCount  | Should -Be 0
        $result.Success    | Should -Be $true
        $result.DurationSeconds | Should -BeGreaterOrEqual 0
    }

    It "Should call New-SPCampaign for each test case" {
        $campaigns = New-MockCampaigns -Count 2
        $cid = [guid]::NewGuid().ToString()

        Invoke-SPTestSuite -Campaigns $campaigns -Identities $script:TestIdentities -CorrelationID $cid

        # Each campaign calls New-SPCampaign once
        Should -Invoke New-SPCampaign -ModuleName SP.BatchRunner -Times 2 -Exactly
    }
}

# ---------------------------------------------------------------------------
# BATCH-002: Invoke-SPTestSuite stops on first failure when flag set
# ---------------------------------------------------------------------------
Describe "BATCH-002: Invoke-SPTestSuite stops on first failure when flag set" {
    It "Should skip remaining tests after first failure with -StopOnFirstFailure" {
        # Override New-SPCampaign to fail on TC-001
        Mock -ModuleName SP.BatchRunner -CommandName New-SPCampaign {
            param($Name, $Type, $CertifierIdentityId, $SourceId, $SearchFilter, $RoleId, $Description, $CorrelationID, $CampaignTestId)
            if ($CampaignTestId -eq 'TC-001') {
                return @{
                    Success = $false
                    Data    = $null
                    Error   = "Mock campaign creation failure"
                }
            }
            return @{
                Success = $true
                Data    = @{ id = "camp-ok"; name = $Name; type = $Type; status = 'STAGED' }
                Error   = $null
            }
        }

        $campaigns = New-MockCampaigns -Count 3
        $cid = [guid]::NewGuid().ToString()

        $result = Invoke-SPTestSuite `
            -Campaigns          $campaigns `
            -Identities         $script:TestIdentities `
            -CorrelationID      $cid `
            -StopOnFirstFailure

        $result.FailCount  | Should -Be 1
        $result.SkipCount  | Should -BeGreaterThan 0
        $result.Success    | Should -Be $false

        # Restore default mock
        Mock -ModuleName SP.BatchRunner -CommandName New-SPCampaign {
            param($Name, $Type, $CertifierIdentityId, $SourceId, $SearchFilter, $RoleId, $Description, $CorrelationID, $CampaignTestId)
            @{
                Success = $true
                Data    = @{ id = "camp-mock"; name = $Name; type = $Type; status = 'STAGED' }
                Error   = $null
            }
        }
    }
}

# ---------------------------------------------------------------------------
# BATCH-003: Invoke-SPSingleTest executes full 10-step flow (WhatIf mode)
# ---------------------------------------------------------------------------
Describe "BATCH-003: Invoke-SPSingleTest executes full 10-step flow in WhatIf mode" {
    It "Should record 10 steps in WhatIf mode without calling any API functions" {
        $testCase = [PSCustomObject]@{
            TestId                   = 'TC-WHATIF'
            TestName                 = 'WhatIf Full Flow Test'
            CampaignType             = 'SOURCE_OWNER'
            CampaignName             = 'UAT-WhatIf-001'
            CertifierIdentityId      = 'id-alice-001'
            ReassignTargetIdentityId = 'id-bob-002'
            SourceId                 = 'src-001'
            SearchFilter             = ''
            RoleId                   = ''
            DecisionToMake           = 'APPROVE'
            ReassignBeforeDecide     = $true
            ValidateRemediation      = $true
            ExpectCampaignStatus     = 'COMPLETED'
            Priority                 = 1
            Tags                     = 'smoke'
        }

        $cid = [guid]::NewGuid().ToString()
        $result = Invoke-SPSingleTest `
            -TestCase      $testCase `
            -Identities    $script:TestIdentities `
            -CorrelationID $cid `
            -EvidenceBase  $TestDrive `
            -WhatIf

        $result                | Should -Not -BeNullOrEmpty
        $result.TestId         | Should -Be 'TC-WHATIF'
        $result.Pass           | Should -Be $true
        $result.Steps.Count    | Should -Be 10
        $result.DurationSeconds | Should -BeGreaterOrEqual 0

        # Verify step actions
        $stepActions = $result.Steps | ForEach-Object { $_.Action }
        $stepActions | Should -Contain 'CreateCampaign'
        $stepActions | Should -Contain 'ActivateCampaign'
        $stepActions | Should -Contain 'PollStatus'
        $stepActions | Should -Contain 'GetCertifications'
        $stepActions | Should -Contain 'Reassign'
        $stepActions | Should -Contain 'GetReviewItems'
        $stepActions | Should -Contain 'BulkDecide'
        $stepActions | Should -Contain 'SignOff'
        $stepActions | Should -Contain 'AssertFinalStatus'
        $stepActions | Should -Contain 'ValidateRemediation'

        # WhatIf steps should have status INFO
        $infoSteps = $result.Steps | Where-Object { $_.Status -eq 'INFO' }
        $infoSteps.Count | Should -BeGreaterOrEqual 8

        # Verify no real API calls were made in WhatIf mode
        Should -Not -Invoke New-SPCampaign
        Should -Not -Invoke Start-SPCampaign
        Should -Not -Invoke Invoke-SPBulkDecide
    }

    It "Should record SKIP for optional steps when conditions are false" {
        $testCase = [PSCustomObject]@{
            TestId                   = 'TC-NOREASSIGN'
            TestName                 = 'No Reassign No Remediation'
            CampaignType             = 'MANAGER'
            CampaignName             = 'UAT-NoReassign'
            CertifierIdentityId      = 'id-bob-002'
            ReassignTargetIdentityId = ''
            SourceId                 = ''
            SearchFilter             = ''
            RoleId                   = ''
            DecisionToMake           = 'APPROVE'
            ReassignBeforeDecide     = $false
            ValidateRemediation      = $false
            ExpectCampaignStatus     = 'COMPLETED'
            Priority                 = 1
            Tags                     = 'smoke'
        }

        $cid = [guid]::NewGuid().ToString()
        $result = Invoke-SPSingleTest `
            -TestCase      $testCase `
            -Identities    $script:TestIdentities `
            -CorrelationID $cid `
            -EvidenceBase  $TestDrive `
            -WhatIf

        $result.Steps.Count | Should -Be 10

        $reassignStep    = $result.Steps | Where-Object { $_.Action -eq 'Reassign' }
        $remediationStep = $result.Steps | Where-Object { $_.Action -eq 'ValidateRemediation' }

        $reassignStep.Status    | Should -Be 'SKIP'
        $remediationStep.Status | Should -Be 'SKIP'
    }
}

# ---------------------------------------------------------------------------
# BATCH-004: Invoke-SPTestSuite respects MaxCampaignsPerRun safety limit
# ---------------------------------------------------------------------------
Describe "BATCH-004: Invoke-SPTestSuite respects MaxCampaignsPerRun safety limit" {
    It "Should cap execution at MaxCampaignsPerRun and mark excess as skipped" {
        # MaxCampaignsPerRun is mocked to 10 but we use a lower value here
        # by overriding the config mock
        Mock -ModuleName SP.BatchRunner -CommandName Get-SPConfig {
            [PSCustomObject]@{
                ISC     = [PSCustomObject]@{ TenantUrl = 'https://test.identitynow.com' }
                Global  = [PSCustomObject]@{ Environment = 'NonProd' }
                Testing = [PSCustomObject]@{
                    EvidencePath                      = $TestDrive
                    ReportsPath                       = $TestDrive
                    DecisionBatchSize                 = 250
                    DefaultDecision                   = 'APPROVE'
                    CampaignActivationTimeoutSeconds  = 30
                    CampaignCompleteTimeoutSeconds    = 60
                    WhatIfByDefault                   = $false
                }
                Safety  = [PSCustomObject]@{
                    MaxCampaignsPerRun      = 2   # Limit to 2
                    RequireWhatIfOnProd     = $false
                    AllowCompleteCampaign   = $true
                }
            }
        }

        $campaigns = New-MockCampaigns -Count 5  # Request 5 but limit is 2
        $cid = [guid]::NewGuid().ToString()

        $result = Invoke-SPTestSuite `
            -Campaigns     $campaigns `
            -Identities    $script:TestIdentities `
            -CorrelationID $cid `
            -WhatIf

        # 2 executed, 3 skipped
        ($result.PassCount + $result.FailCount) | Should -Be 2
        $result.SkipCount | Should -Be 3
        $result.Results.Count | Should -Be 5

        $skippedResults = $result.Results | Where-Object { $_.Skipped -eq $true }
        $skippedResults.Count | Should -Be 3
        $skippedResults[0].Error | Should -Match 'MaxCampaignsPerRun'

        # Restore config mock
        Mock -ModuleName SP.BatchRunner -CommandName Get-SPConfig {
            [PSCustomObject]@{
                ISC     = [PSCustomObject]@{ TenantUrl = 'https://test.identitynow.com' }
                Global  = [PSCustomObject]@{ Environment = 'NonProd' }
                Testing = [PSCustomObject]@{
                    EvidencePath                      = $TestDrive
                    ReportsPath                       = $TestDrive
                    DecisionBatchSize                 = 250
                    DefaultDecision                   = 'APPROVE'
                    CampaignActivationTimeoutSeconds  = 30
                    CampaignCompleteTimeoutSeconds    = 60
                    WhatIfByDefault                   = $false
                }
                Safety  = [PSCustomObject]@{
                    MaxCampaignsPerRun      = 10
                    RequireWhatIfOnProd     = $false
                    AllowCompleteCampaign   = $true
                }
            }
        }
    }
}
