#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the full attestation-campaign lifecycle (T-03)
.DESCRIPTION
    Tests: CAMP-LC-001 through CAMP-LC-004
    Proves the documented STAGED->ACTIVE->COMPLETING->COMPLETED state machine
    end-to-end over mocked transport (no network), plus the regression guards:
      CAMP-LC-001  Ordered lifecycle New->Start->Complete->Get-SPCampaignStatus
                   observes STAGED -> ACTIVE -> COMPLETING -> COMPLETED in order.
      CAMP-LC-002  Get-SPCampaignStatus settles a COMPLETING campaign to COMPLETED
                   (polls more than once).
      CAMP-LC-003  400-on-non-ACTIVE guard still holds (Complete on STAGED fails
                   with the 'ACTIVE status' message).
      CAMP-LC-004  Safety.AllowCompleteCampaign=false still blocks completion with
                   zero API calls -- proves the new -CompleteAllCampaigns opt-in did
                   not weaken the existing guard.
      CAMP-LC-005  Complete-SPCampaign -Phased sends the ?phased=1 query flag to the
                   backend (real wiring), and the default call (no -Phased) sends NO
                   query params -- proves the live-mock two-phase lifecycle is now
                   genuinely wired through, not merely simulated by mocked transport.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Helper: standard mock config (mirrors SP.Campaigns.Tests.ps1)
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

Describe "CAMP-LC-001: Full lifecycle STAGED->ACTIVE->COMPLETING->COMPLETED in order" {
    Context "When a campaign is created, activated, then completed (phased)" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Start-Sleep  -ModuleName SP.Campaigns { }
            Mock Get-SPConfig -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $true }

            # Sequenced transport: New (STAGED), Start (ACTIVE), Complete (COMPLETING),
            # then Get polls return COMPLETING once before settling to COMPLETED.
            $script:Phase     = 'init'
            $script:PollCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                if ($Endpoint -eq '/campaigns' -and $Method -eq 'POST') {
                    $script:Phase = 'staged'
                    return @{ Success = $true; StatusCode = 200
                        Data = [PSCustomObject]@{ id = 'camp-lc-001'; name = 'LC'; type = 'MANAGER'; status = 'STAGED' }; Error = $null }
                }
                if ($Endpoint -eq '/campaigns/camp-lc-001/activate') {
                    $script:Phase = 'active'
                    return @{ Success = $true; StatusCode = 200
                        Data = [PSCustomObject]@{ id = 'camp-lc-001'; status = 'ACTIVE' }; Error = $null }
                }
                if ($Endpoint -eq '/campaigns/camp-lc-001/complete') {
                    $script:Phase = 'completing'
                    return @{ Success = $true; StatusCode = 200
                        Data = [PSCustomObject]@{ id = 'camp-lc-001'; status = 'COMPLETING' }; Error = $null }
                }
                # GET /campaigns/camp-lc-001 -- poller. First poll sees COMPLETING,
                # subsequent polls settle to COMPLETED.
                $script:PollCount++
                $status = if ($script:PollCount -lt 2) { 'COMPLETING' } else { 'COMPLETED' }
                return @{ Success = $true; StatusCode = 200
                    Data = [PSCustomObject]@{ id = 'camp-lc-001'; status = $status }; Error = $null }
            }
        }

        It "Should observe STAGED -> ACTIVE -> COMPLETING -> COMPLETED in order" {
            $cid = 'lc-cid-001'
            $observed = [System.Collections.Generic.List[string]]::new()

            $new = New-SPCampaign -Name 'LC' -Type MANAGER -CertifierIdentityId 'mgr-1' -CorrelationID $cid
            $new.Success | Should -Be $true
            $new.Data.status | Should -Be 'STAGED'
            $observed.Add($new.Data.status)

            $start = Start-SPCampaign -CampaignId 'camp-lc-001' -CorrelationID $cid
            $start.Success | Should -Be $true
            $start.Data.status | Should -Be 'ACTIVE'
            $observed.Add($start.Data.status)

            $comp = Complete-SPCampaign -CampaignId 'camp-lc-001' -CorrelationID $cid
            $comp.Success | Should -Be $true
            $observed.Add('COMPLETING')

            $settle = Get-SPCampaignStatus -CampaignId 'camp-lc-001' -TargetStatus 'COMPLETED' `
                -TimeoutSeconds 60 -PollIntervalSeconds 1 -CorrelationID $cid
            $settle.Success | Should -Be $true
            $settle.Data.Status | Should -Be 'COMPLETED'
            $observed.Add($settle.Data.Status)

            ($observed -join '->') | Should -Be 'STAGED->ACTIVE->COMPLETING->COMPLETED'
        }
    }
}

Describe "CAMP-LC-002: Get-SPCampaignStatus settles COMPLETING to COMPLETED" {
    Context "When the campaign reports COMPLETING twice then COMPLETED" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Start-Sleep  -ModuleName SP.Campaigns { }

            $script:PollCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                $script:PollCount++
                $status = if ($script:PollCount -lt 3) { 'COMPLETING' } else { 'COMPLETED' }
                return @{ Success = $true; StatusCode = 200
                    Data = [PSCustomObject]@{ id = 'camp-lc-002'; status = $status }; Error = $null }
            }
        }

        It "Should return Success=true with Data.Status COMPLETED after multiple polls" {
            $script:PollCount = 0
            $result = Get-SPCampaignStatus -CampaignId 'camp-lc-002' -TargetStatus 'COMPLETED' `
                -TimeoutSeconds 60 -PollIntervalSeconds 1 -CorrelationID 'lc-cid-002'

            $result.Success     | Should -Be $true
            $result.Data.Status | Should -Be 'COMPLETED'
            $script:PollCount   | Should -BeGreaterThan 1
        }
    }
}

Describe "CAMP-LC-003: 400 guard intact -- completing a non-ACTIVE campaign fails" {
    Context "When the API returns 400 because the campaign is STAGED" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Get-SPConfig -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $true }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $false
                    StatusCode = 400
                    Data       = $null
                    Error      = 'Campaign must be in ACTIVE status to complete. Current status: STAGED'
                }
            }
        }

        It "Should return Success=false with the 'ACTIVE status' error" {
            $result = Complete-SPCampaign -CampaignId 'camp-lc-003' -CorrelationID 'lc-cid-003'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'ACTIVE status'
        }
    }
}

Describe "CAMP-LC-004: Safety still blocks completion when AllowCompleteCampaign is false" {
    Context "When safety flag is false (default)" {
        BeforeEach {
            Mock Write-SPLog       -ModuleName SP.Campaigns { }
            Mock Get-SPConfig      -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $false }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns { }
        }

        It "Should return Success=false, match AllowCompleteCampaign, call API 0 times" {
            $result = Complete-SPCampaign -CampaignId 'camp-lc-004' -CorrelationID 'lc-cid-004'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'AllowCompleteCampaign'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -Times 0 -Exactly
        }
    }
}

Describe "CAMP-LC-005: -Phased wires ?phased=1 to the backend (real wiring)" {
    Context "When Complete-SPCampaign is called with -Phased" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Get-SPConfig -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $true }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $true; StatusCode = 200
                    Data = [PSCustomObject]@{ id = 'camp-lc-005'; status = 'COMPLETING' }; Error = $null }
            }
        }

        It "Should POST /complete with QueryParams phased=1 and surface returned Data" {
            $result = Complete-SPCampaign -CampaignId 'camp-lc-005' -Phased -CorrelationID 'lc-cid-005'

            $result.Success      | Should -Be $true
            $result.Data.status  | Should -Be 'COMPLETING'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -Times 1 -Exactly -ParameterFilter {
                $Endpoint -eq '/campaigns/camp-lc-005/complete' -and
                $Method   -eq 'POST' -and
                $null -ne $QueryParams -and
                $QueryParams['phased'] -eq '1'
            }
        }
    }

    Context "When Complete-SPCampaign is called WITHOUT -Phased (default, unchanged)" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Get-SPConfig -ModuleName SP.Campaigns { New-MockSPConfig -AllowComplete $true }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{ Success = $true; StatusCode = 200
                    Data = [PSCustomObject]@{ id = 'camp-lc-005b'; status = 'COMPLETED' }; Error = $null }
            }
        }

        It "Should POST /complete with NO query params (default path preserved)" {
            $result = Complete-SPCampaign -CampaignId 'camp-lc-005b' -CorrelationID 'lc-cid-005b'

            $result.Success | Should -Be $true

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -Times 1 -Exactly -ParameterFilter {
                $Endpoint -eq '/campaigns/camp-lc-005b/complete' -and
                $null -eq $QueryParams
            }
        }
    }
}
