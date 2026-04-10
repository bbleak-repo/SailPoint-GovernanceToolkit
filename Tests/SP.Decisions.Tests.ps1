#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.Decisions module
.DESCRIPTION
    Tests: DEC-001 through DEC-004
    Covers: Bulk decide batching at 250 items, sync reassign 50-item limit,
            async reassign up to 500 items, sign-off success
#>

BeforeAll {
    # Import SP.Core first (SP.Api depends on it)
    $corePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    if (Test-Path $corePath) { Import-Module $corePath -Force }

    $apiPath = Join-Path $PSScriptRoot "..\Modules\SP.Api\SP.Api.psd1"
    Import-Module $apiPath -Force

    # Helper: build a standard mock config
    function New-MockSPConfig {
        param(
            [int]$DecisionBatchSize  = 250,
            [int]$ReassignSyncMax    = 50,
            [int]$ReassignAsyncMax   = 500
        )
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
                DecisionBatchSize = $DecisionBatchSize
                ReassignSyncMax   = $ReassignSyncMax
                ReassignAsyncMax  = $ReassignAsyncMax
            }
            Safety = [PSCustomObject]@{
                AllowCompleteCampaign = $false
            }
        }
    }

    # Helper: build an array of N unique item IDs
    function New-ItemIdArray {
        param([int]$Count)
        $ids = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -le $Count; $i++) {
            $ids.Add("item-$('{0:D4}' -f $i)")
        }
        return $ids.ToArray()
    }
}

Describe "DEC-001: Invoke-SPBulkDecide batches at 250 items" {
    Context "When reviewing items exceed the batch size (250)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig -DecisionBatchSize 250 }

            $script:ApiCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                $script:ApiCallCount++
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ status = 'COMPLETED' }
                    Error      = $null
                }
            }
        }

        It "Should split 500 items into exactly 2 API calls (250 per batch)" {
            $items  = New-ItemIdArray -Count 500
            $result = Invoke-SPBulkDecide -CertificationId 'cert-dec-001' `
                -ReviewItemIds $items -Decision 'APPROVE' `
                -CorrelationID 'dec-cid-001'

            $result.Success                 | Should -Be $true
            $result.Data.TotalDecided        | Should -Be 500
            $script:ApiCallCount            | Should -Be 2
        }

        It "Should split 251 items into 2 batches (250 + 1)" {
            $script:ApiCallCount = 0
            $items  = New-ItemIdArray -Count 251
            $result = Invoke-SPBulkDecide -CertificationId 'cert-dec-001b' `
                -ReviewItemIds $items -Decision 'REVOKE' `
                -CorrelationID 'dec-cid-001b'

            $script:ApiCallCount         | Should -Be 2
            $result.Data.TotalDecided    | Should -Be 251
        }

        It "Should handle exactly 250 items in a single batch" {
            $script:ApiCallCount = 0
            $items  = New-ItemIdArray -Count 250
            $result = Invoke-SPBulkDecide -CertificationId 'cert-dec-001c' `
                -ReviewItemIds $items -Decision 'APPROVE' `
                -CorrelationID 'dec-cid-001c'

            $script:ApiCallCount         | Should -Be 1
            $result.Data.TotalDecided    | Should -Be 250
        }

        It "Should call Invoke-SPApiRequest with the correct endpoint for each batch" {
            $script:ApiCallCount = 0
            $items = New-ItemIdArray -Count 50
            Invoke-SPBulkDecide -CertificationId 'cert-dec-endpoint' `
                -ReviewItemIds $items -Decision 'APPROVE' `
                -CorrelationID 'dec-cid-001d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/certifications/cert-dec-endpoint/decide'
            }
        }
    }

    Context "When the API fails on a batch" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                return @{ Success = $false; Data = $null; StatusCode = 500; Error = 'Internal error' }
            }
        }

        It "Should return Success=false immediately on first batch failure" {
            $items  = New-ItemIdArray -Count 100
            $result = Invoke-SPBulkDecide -CertificationId 'cert-fail' `
                -ReviewItemIds $items -Decision 'APPROVE' `
                -CorrelationID 'dec-cid-001e'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context "When comments are provided" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig }

            $script:CapturedBody = $null
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                $script:CapturedBody = $Body
                return @{ Success = $true; StatusCode = 200; Data = [PSCustomObject]@{}; Error = $null }
            }
        }

        It "Should include comments in the decision body" {
            $items = New-ItemIdArray -Count 5
            Invoke-SPBulkDecide -CertificationId 'cert-comments' `
                -ReviewItemIds $items -Decision 'APPROVE' `
                -Comments 'Verified by UAT script' `
                -CorrelationID 'dec-cid-001f'

            $script:CapturedBody.items[0].comments | Should -Be 'Verified by UAT script'
        }
    }
}

Describe "DEC-002: Invoke-SPReassign respects 50-item sync limit" {
    Context "When the item count is within the sync limit (<=50)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig -ReassignSyncMax 50 }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ reassigned = $true }
                    Error      = $null
                }
            }
        }

        It "Should succeed when exactly 50 items are provided" {
            $items  = New-ItemIdArray -Count 50
            $result = Invoke-SPReassign -CertificationId 'cert-reassign-sync' `
                -NewCertifierIdentityId 'id-new-reviewer' `
                -ReviewItemIds $items -Reason 'Reviewer on leave' `
                -CorrelationID 'dec-cid-002'

            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with /reassign (not reassign-async) endpoint" {
            $items = New-ItemIdArray -Count 10
            Invoke-SPReassign -CertificationId 'cert-reassign-sync' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Test' `
                -CorrelationID 'dec-cid-002b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/certifications/cert-reassign-sync/reassign'
            }
        }
    }

    Context "When the item count exceeds the sync limit (>50)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig -ReassignSyncMax 50 }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions { }
        }

        It "Should return Success=false without calling the API" {
            $items  = New-ItemIdArray -Count 51
            $result = Invoke-SPReassign -CertificationId 'cert-too-many' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Test' `
                -CorrelationID 'dec-cid-002c'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'exceeds the synchronous limit'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -Times 0 -Exactly
        }

        It "Should suggest using the async variant in the error message" {
            $items  = New-ItemIdArray -Count 100
            $result = Invoke-SPReassign -CertificationId 'cert-too-many' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Test' `
                -CorrelationID 'dec-cid-002d'

            $result.Error | Should -Match 'Invoke-SPReassignAsync'
        }
    }
}

Describe "DEC-003: Invoke-SPReassignAsync handles up to 500 items" {
    Context "When the item count is within the async limit (<=500)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig -ReassignAsyncMax 500 }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                return @{
                    Success    = $true
                    StatusCode = 202
                    Data       = [PSCustomObject]@{ id = 'task-async-001' }
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with a TaskId for 500 items" {
            $items  = New-ItemIdArray -Count 500
            $result = Invoke-SPReassignAsync -CertificationId 'cert-async' `
                -NewCertifierIdentityId 'id-async-reviewer' `
                -ReviewItemIds $items -Reason 'Bulk reassign for Q1' `
                -CorrelationID 'dec-cid-003'

            $result.Success        | Should -Be $true
            $result.Data           | Should -Not -BeNullOrEmpty
            $result.Data.TaskId    | Should -Be 'task-async-001'
            $result.Error          | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with /reassign-async endpoint" {
            $items = New-ItemIdArray -Count 200
            Invoke-SPReassignAsync -CertificationId 'cert-async-ep' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Test async' `
                -CorrelationID 'dec-cid-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/certifications/cert-async-ep/reassign-async'
            }
        }

        It "Should handle exactly 51 items (above sync limit, within async)" {
            $items  = New-ItemIdArray -Count 51
            $result = Invoke-SPReassignAsync -CertificationId 'cert-async-51' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Just over sync limit' `
                -CorrelationID 'dec-cid-003c'

            $result.Success | Should -Be $true
        }
    }

    Context "When the item count exceeds the async limit (>500)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Get-SPConfig    -ModuleName SP.Decisions { New-MockSPConfig -ReassignAsyncMax 500 }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions { }
        }

        It "Should return Success=false for 501 items" {
            $items  = New-ItemIdArray -Count 501
            $result = Invoke-SPReassignAsync -CertificationId 'cert-too-many-async' `
                -NewCertifierIdentityId 'id-reviewer' `
                -ReviewItemIds $items -Reason 'Too many' `
                -CorrelationID 'dec-cid-003d'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'exceeds the async limit'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -Times 0 -Exactly
        }
    }
}

Describe "DEC-004: Invoke-SPSignOff succeeds" {
    Context "When signing off a certification with all items decided" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ signedOff = $true }
                    Error      = $null
                }
            }
        }

        It "Should return Success=true" {
            $result = Invoke-SPSignOff -CertificationId 'cert-signoff-001' `
                -CorrelationID 'dec-cid-004'

            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
        }

        It "Should call Invoke-SPApiRequest with POST to /sign-off endpoint" {
            Invoke-SPSignOff -CertificationId 'cert-signoff-001' -CorrelationID 'dec-cid-004b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/certifications/cert-signoff-001/sign-off'
            }
        }

        It "Should pass CampaignTestId through to the API call for correlation" {
            Invoke-SPSignOff -CertificationId 'cert-signoff-001' `
                -CorrelationID 'dec-cid-004c' -CampaignTestId 'DEC-004'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Decisions -ParameterFilter {
                $CampaignTestId -eq 'DEC-004'
            }
        }
    }

    Context "When the API returns an error on sign-off" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.Decisions { }
            Mock Invoke-SPApiRequest -ModuleName SP.Decisions {
                return @{
                    Success    = $false
                    StatusCode = 409
                    Data       = $null
                    Error      = 'Certification has undecided items'
                }
            }
        }

        It "Should return Success=false with the API error message" {
            $result = Invoke-SPSignOff -CertificationId 'cert-signoff-fail' `
                -CorrelationID 'dec-cid-004d'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}
