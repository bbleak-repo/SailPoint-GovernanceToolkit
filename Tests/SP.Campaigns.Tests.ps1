#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.Campaigns module
.DESCRIPTION
    Tests: CAMP-001 through CAMP-005
    Covers: Create SOURCE_OWNER campaign, activate, retrieve with -Full, poll until ACTIVE, Complete blocked by safety flag
#>

BeforeAll {
    # Import SP.Core first (SP.Api depends on it)
    $corePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    if (Test-Path $corePath) { Import-Module $corePath -Force }

    $apiPath = Join-Path $PSScriptRoot "..\Modules\SP.Api\SP.Api.psd1"
    Import-Module $apiPath -Force

    # Helper: standard mock config
    function New-MockSPConfig {
        param([bool]$AllowComplete = $false)
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = 1
                RetryDelaySeconds          = 1
                RateLimitRequestsPerWindow = 95
                RateLimitWindowSeconds     = 10
            }
            Testing = [PSCustomObject]@{
                DecisionBatchSize  = 250
                ReassignSyncMax    = 50
                ReassignAsyncMax   = 500
            }
            Safety = [PSCustomObject]@{
                AllowCompleteCampaign = $AllowComplete
            }
        }
    }
}

Describe "CAMP-001: New-SPCampaign creates SOURCE_OWNER campaign" {
    Context "When a valid SOURCE_OWNER campaign is created" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Get-SPConfig      -ModuleName SP.Campaigns { New-MockSPConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id     = 'camp-src-001'
                        name   = 'Source Owner Q1'
                        type   = 'SOURCE_OWNER'
                        status = 'STAGED'
                    }
                    Error = $null
                }
            }
        }

        It "Should return Success=true with the campaign object" {
            $result = New-SPCampaign -Name 'Source Owner Q1' -Type SOURCE_OWNER `
                -SourceId 'src-abc' -CorrelationID 'camp-cid-001' -CampaignTestId 'CAMP-001'

            $result.Success    | Should -Be $true
            $result.Data       | Should -Not -BeNullOrEmpty
            $result.Data.id    | Should -Be 'camp-src-001'
            $result.Error      | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with POST method and /campaigns endpoint" {
            New-SPCampaign -Name 'Source Owner Q1' -Type SOURCE_OWNER `
                -SourceId 'src-abc' -CorrelationID 'camp-cid-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaigns'
            }
        }

        It "Should pass the campaign name and type in the body" {
            $script:CapturedBody = $null
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                $script:CapturedBody = $Body
                return @{ Success = $true; Data = [PSCustomObject]@{ id = 'c1' }; StatusCode = 200; Error = $null }
            }

            New-SPCampaign -Name 'My Source Review' -Type SOURCE_OWNER `
                -SourceId 'src-999' -CorrelationID 'camp-cid-001c'

            $script:CapturedBody.name | Should -Be 'My Source Review'
            $script:CapturedBody.type | Should -Be 'SOURCE_OWNER'
        }
    }

    Context "When the API returns an error" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Get-SPConfig      -ModuleName SP.Campaigns { New-MockSPConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $false; Data = $null; StatusCode = 400; Error = 'Bad Request: missing name' }
            }
        }

        It "Should return Success=false with the error message" {
            $result = New-SPCampaign -Name 'Bad Campaign' -Type MANAGER -CorrelationID 'camp-cid-001d'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'Bad Request'
        }
    }
}

Describe "CAMP-002: Start-SPCampaign activates campaign" {
    Context "When activating a staged campaign" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ id = 'camp-002'; status = 'ACTIVATING' }
                    Error      = $null
                }
            }
        }

        It "Should return Success=true" {
            $result = Start-SPCampaign -CampaignId 'camp-002' -CorrelationID 'camp-cid-002'

            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with POST to /campaigns/{id}/activate" {
            Start-SPCampaign -CampaignId 'camp-002' -CorrelationID 'camp-cid-002b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaigns/camp-002/activate'
            }
        }
    }

    Context "When the API rejects the activation" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $false; Data = $null; StatusCode = 409; Error = 'Campaign not in STAGED status' }
            }
        }

        It "Should return Success=false with the API error" {
            $result = Start-SPCampaign -CampaignId 'camp-already-active' -CorrelationID 'camp-cid-002c'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "CAMP-003: Get-SPCampaign retrieves campaign with -Full detail" {
    Context "When retrieving a campaign with -Full switch" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id          = 'camp-003'
                        name        = 'Full Detail Campaign'
                        status      = 'ACTIVE'
                        totalItems  = 500
                        completedItems = 125
                    }
                    Error = $null
                }
            }
        }

        It "Should return Success=true with campaign data" {
            $result = Get-SPCampaign -CampaignId 'camp-003' -Full -CorrelationID 'camp-cid-003'

            $result.Success        | Should -Be $true
            $result.Data.id        | Should -Be 'camp-003'
            $result.Data.status    | Should -Be 'ACTIVE'
        }

        It "Should call Invoke-SPApiRequest with detail=FULL query parameter" {
            Get-SPCampaign -CampaignId 'camp-003' -Full -CorrelationID 'camp-cid-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Endpoint -eq '/campaigns/camp-003' -and
                $QueryParams -ne $null -and
                $QueryParams['detail'] -eq 'FULL'
            }
        }

        It "Should NOT send query params when -Full is not specified" {
            Get-SPCampaign -CampaignId 'camp-003' -CorrelationID 'camp-cid-003c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Endpoint -eq '/campaigns/camp-003' -and $QueryParams -eq $null
            }
        }
    }
}

Describe "CAMP-004: Get-SPCampaignStatus polls until ACTIVE" {
    Context "When the campaign transitions from ACTIVATING to ACTIVE" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Start-Sleep  -ModuleName SP.Campaigns { }

            $script:PollCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                $script:PollCount++
                $status = if ($script:PollCount -lt 3) { 'ACTIVATING' } else { 'ACTIVE' }
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ id = 'camp-004'; status = $status }
                    Error      = $null
                }
            }
        }

        It "Should eventually return Success=true with TargetStatus ACTIVE" {
            $result = Get-SPCampaignStatus -CampaignId 'camp-004' `
                -TargetStatus 'ACTIVE' -TimeoutSeconds 60 -PollIntervalSeconds 1 `
                -CorrelationID 'camp-cid-004'

            $result.Success          | Should -Be $true
            $result.Data.Status      | Should -Be 'ACTIVE'
            $result.Data.Campaign    | Should -Not -BeNullOrEmpty
        }

        It "Should poll multiple times before finding the target status" {
            $script:PollCount = 0
            Get-SPCampaignStatus -CampaignId 'camp-004' `
                -TargetStatus 'ACTIVE' -TimeoutSeconds 60 -PollIntervalSeconds 1 `
                -CorrelationID 'camp-cid-004b'

            $script:PollCount | Should -BeGreaterThan 1
        }

        It "Should call Start-Sleep between polls" {
            $script:PollCount = 0
            Get-SPCampaignStatus -CampaignId 'camp-004' `
                -TargetStatus 'ACTIVE' -TimeoutSeconds 60 -PollIntervalSeconds 1 `
                -CorrelationID 'camp-cid-004c'

            Should -Invoke Start-Sleep -ModuleName SP.Campaigns
        }
    }

    Context "When the campaign does not reach target status within timeout" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Start-Sleep  -ModuleName SP.Campaigns { }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success = $true; StatusCode = 200
                    Data    = [PSCustomObject]@{ id = 'camp-stuck'; status = 'ACTIVATING' }
                    Error   = $null
                }
            }
        }

        It "Should return Success=false with a timeout error message" {
            # Use very short timeout (1 second) to force timeout quickly
            $result = Get-SPCampaignStatus -CampaignId 'camp-stuck' `
                -TargetStatus 'ACTIVE' -TimeoutSeconds 1 -PollIntervalSeconds 1 `
                -CorrelationID 'camp-cid-004d'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'Timeout'
        }
    }
}

Describe "CAMP-005: Complete-SPCampaign blocked when Safety.AllowCompleteCampaign is false" {
    Context "When safety flag is false (default)" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Get-SPConfig      -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $false }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns { }
        }

        It "Should return Success=false without calling the API" {
            $result = Complete-SPCampaign -CampaignId 'camp-005' -CorrelationID 'camp-cid-005'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
            $result.Error   | Should -Match 'AllowCompleteCampaign'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -Times 0 -Exactly
        }
    }

    Context "When safety flag is true (explicitly enabled)" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Get-SPConfig      -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $true }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ id = 'camp-005'; status = 'COMPLETED' }
                    Error      = $null
                }
            }
        }

        It "Should call the API and return Success=true when allowed" {
            $result = Complete-SPCampaign -CampaignId 'camp-005' -CorrelationID 'camp-cid-005b'

            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaigns/camp-005/complete'
            }
        }
    }
}
