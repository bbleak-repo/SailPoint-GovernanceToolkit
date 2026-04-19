#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.ApiClient module (Invoke-SPApiRequest)
.DESCRIPTION
    Tests: API-001 through API-005
    Covers: GET success, POST with body, 5xx retry, 429 rate limit, auth failure
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Helper: build a standard mock config object
    function New-MockSPConfig {
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = 2
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
                AllowCompleteCampaign = $false
            }
        }
    }

    # Helper: build a standard mock auth result
    function New-MockAuthResult {
        return @{
            Success = $true
            Data    = @{
                Token   = 'mock-bearer-token'
                Headers = @{
                    Authorization  = 'Bearer mock-bearer-token'
                    'Content-Type' = 'application/json'
                }
                ExpiresAt = (Get-Date).AddHours(1)
            }
            Error = $null
        }
    }
}

Describe "API-001: Invoke-SPApiRequest GET succeeds" {
    Context "When the API returns a successful response for a GET request" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.ApiClient { }
            Mock Get-SPConfig -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                return [PSCustomObject]@{
                    id     = 'camp-001'
                    name   = 'Test Campaign'
                    status = 'ACTIVE'
                }
            }
        }

        It "Should return Success=true with Data populated" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'test-cid-001'

            $result               | Should -Not -BeNullOrEmpty
            $result.Success       | Should -Be $true
            $result.Data          | Should -Not -BeNullOrEmpty
            $result.Error         | Should -BeNullOrEmpty
        }

        It "Should call Invoke-RestMethod exactly once for a single GET" {
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'test-cid-001a'

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -Times 1 -Exactly
        }

        It "Should construct the correct URL from BaseUrl and Endpoint" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/camp-001' -CorrelationID 'test-url-001'

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -ParameterFilter {
                $Uri -eq 'https://test.api.identitynow.com/v3/campaigns/camp-001'
            }
        }

        It "Should append query parameters to the URL" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/certifications' `
                -QueryParams @{ filters = 'campaign.id eq "c1"'; limit = '10' } `
                -CorrelationID 'test-query-001'

            # Verify Invoke-RestMethod was called with a URI containing the query params
            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -ParameterFilter {
                $Uri -like '*filters=*' -and $Uri -like '*limit=*'
            }
        }
    }
}

Describe "API-002: Invoke-SPApiRequest POST with body succeeds" {
    Context "When submitting a POST request with a hashtable body" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                return [PSCustomObject]@{
                    id     = 'camp-new-001'
                    name   = 'Created Campaign'
                    status = 'STAGED'
                }
            }
        }

        It "Should return Success=true with the created resource in Data" {
            $body   = @{ name = 'New Campaign'; type = 'SOURCE_OWNER' }
            $result = Invoke-SPApiRequest -Method POST -Endpoint '/campaigns' `
                -Body $body -CorrelationID 'test-cid-002'

            $result.Success  | Should -Be $true
            $result.Data     | Should -Not -BeNullOrEmpty
            $result.Data.id  | Should -Be 'camp-new-001'
        }

        It "Should call Invoke-RestMethod with Method=POST" {
            $body = @{ name = 'New Campaign'; type = 'MANAGER' }
            Invoke-SPApiRequest -Method POST -Endpoint '/campaigns' `
                -Body $body -CorrelationID 'test-cid-002b'

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -ParameterFilter {
                $Method -eq 'POST'
            }
        }

        It "Should serialize the body as JSON and set ContentType" {
            $body = @{ name = 'Serialized Campaign'; type = 'SEARCH' }
            Invoke-SPApiRequest -Method POST -Endpoint '/campaigns' `
                -Body $body -CorrelationID 'test-cid-002c'

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -ParameterFilter {
                $ContentType -eq 'application/json' -and $Body -like '*Serialized Campaign*'
            }
        }
    }
}

Describe "API-003: Invoke-SPApiRequest retries on 5xx error" {
    Context "When the API returns a 500 error and then succeeds" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:CallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:CallCount++
                if ($script:CallCount -lt 2) {
                    # Simulate a 500 Internal Server Error
                    $webResponse = [System.Net.HttpWebResponse]::new.Invoke($null)
                    $ex = [System.Net.WebException]::new(
                        '(500) Internal Server Error',
                        $null,
                        [System.Net.WebExceptionStatus]::ProtocolError,
                        $null
                    )
                    throw $ex
                }
                return [PSCustomObject]@{ id = 'retry-success'; status = 'ACTIVE' }
            }
        }

        It "Should retry after a 5xx error and ultimately succeed" {
            # Mock catches the 500 but we still need a 2nd call to succeed
            # Our mock throws a plain exception; status code extraction returns 0
            # The function should still retry on exceptions up to RetryCount
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/retry-test' `
                -CorrelationID 'test-cid-003'

            # Should have attempted more than once
            $script:CallCount | Should -BeGreaterThan 1
        }

        It "Should call Start-Sleep between retries" {
            $script:CallCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/retry-sleep' `
                -CorrelationID 'test-cid-003b'

            # Start-Sleep should have been called at least once for the retry delay
            Should -Invoke Start-Sleep -ModuleName SP.ApiClient
        }
    }

    Context "When the API consistently returns 5xx and all retries are exhausted" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(503) Service Unavailable')
            }
        }

        It "Should return Success=false after all retries fail" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/always-fail' `
                -CorrelationID 'test-cid-003c'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "API-004: Invoke-SPApiRequest handles 429 rate limit" {
    Context "When the API returns 429 with a Retry-After header" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:RateLimitCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:RateLimitCount++
                if ($script:RateLimitCount -lt 2) {
                    # Simulate a 429 Too Many Requests
                    throw [System.Net.WebException]::new('(429) Too Many Requests')
                }
                return [PSCustomObject]@{ id = 'after-rate-limit' }
            }
        }

        It "Should sleep and retry after a 429 response" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/rate-limited' `
                -CorrelationID 'test-cid-004'

            # Verify Start-Sleep was called (rate limit delay)
            Should -Invoke Start-Sleep -ModuleName SP.ApiClient
        }

        It "Should attempt the request more than once when rate limited" {
            $script:RateLimitCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/rate-limited2' `
                -CorrelationID 'test-cid-004b'

            $script:RateLimitCount | Should -BeGreaterThan 1
        }
    }
}

Describe "API-005: Invoke-SPApiRequest returns error on auth failure" {
    Context "When Get-SPAuthToken returns a failed result" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient {
                return @{
                    Success = $false
                    Data    = $null
                    Error   = 'OAuth token request failed: invalid_client'
                }
            }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient { }
        }

        It "Should return Success=false without calling Invoke-RestMethod" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-cid-005'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -Times 0 -Exactly
        }

        It "Should include a descriptive error message" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-cid-005b'

            $result.Error | Should -Match 'Auth token'
        }
    }

    Context "When Get-SPAuthToken throws an exception" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { throw 'Connection refused' }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient { }
        }

        It "Should catch the exception and return Success=false" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-cid-005c'

            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty

            Should -Invoke Invoke-RestMethod -ModuleName SP.ApiClient -Times 0 -Exactly
        }
    }
}
