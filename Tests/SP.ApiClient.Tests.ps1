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
        param(
            [int]$RetryCount            = 2,
            [int]$RetryDelaySeconds     = 1,
            [int]$MaxRetryDelaySeconds  = 60
        )
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = $RetryCount
                RetryDelaySeconds          = $RetryDelaySeconds
                MaxRetryDelaySeconds       = $MaxRetryDelaySeconds
                RateLimitRequestsPerWindow = 9999
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

# H2: 401 mid-run should evict the cached OAuth token and retry once with a
# fresh one. Prior to this fix, an expired token caused every subsequent
# call to reuse the stale cache and fail, killing long-running audits.
Describe "API-006: Invoke-SPApiRequest refreshes token on 401" {
    Context "When the first call returns 401 and token refresh succeeds" {
        BeforeEach {
            Mock Write-SPLog         -ModuleName SP.ApiClient { }
            Mock Get-SPConfig        -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Clear-SPAuthToken   -ModuleName SP.ApiClient { }
            Mock Start-Sleep         -ModuleName SP.ApiClient { }

            $script:AuthCallCount = 0
            Mock Get-SPAuthToken -ModuleName SP.ApiClient {
                $script:AuthCallCount++
                return @{
                    Success = $true
                    Data    = @{
                        Token   = "token-v$script:AuthCallCount"
                        Headers = @{ 'Authorization' = "Bearer token-v$script:AuthCallCount"; 'Content-Type' = 'application/json' }
                    }
                    Error   = $null
                }
            }

            $script:RestCallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:RestCallCount++
                if ($script:RestCallCount -eq 1) {
                    throw [System.Net.WebException]::new('(401) Unauthorized')
                }
                return [PSCustomObject]@{ id = 'camp-after-refresh' }
            }
        }

        It "Should retry once and ultimately succeed" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/x' `
                -CorrelationID 'h2-cid-001'

            $result.Success | Should -Be $true
            $result.Data.id | Should -Be 'camp-after-refresh'
        }

        It "Should call Clear-SPAuthToken exactly once" {
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/y' `
                -CorrelationID 'h2-cid-002'

            Should -Invoke Clear-SPAuthToken -ModuleName SP.ApiClient -Times 1 -Exactly
        }

        It "Should call Get-SPAuthToken twice (initial + forced refresh)" {
            $script:AuthCallCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/z' `
                -CorrelationID 'h2-cid-003'

            $script:AuthCallCount | Should -Be 2
        }
    }

    Context "When the 401 persists after token refresh" {
        BeforeEach {
            Mock Write-SPLog         -ModuleName SP.ApiClient { }
            Mock Get-SPConfig        -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Clear-SPAuthToken   -ModuleName SP.ApiClient { }
            Mock Start-Sleep         -ModuleName SP.ApiClient { }
            Mock Get-SPAuthToken     -ModuleName SP.ApiClient {
                return @{
                    Success = $true
                    Data    = @{
                        Token   = 'token-bad'
                        Headers = @{ 'Authorization' = 'Bearer token-bad'; 'Content-Type' = 'application/json' }
                    }
                    Error   = $null
                }
            }
            $script:RestCallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:RestCallCount++
                throw [System.Net.WebException]::new('(401) Unauthorized')
            }
        }

        It "Should not retry more than once on 401 (no infinite loop)" {
            $script:RestCallCount = 0
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/bad' `
                -CorrelationID 'h2-cid-004'

            $result.Success       | Should -Be $false
            # Exactly 2 attempts: initial + one retry after token refresh.
            $script:RestCallCount | Should -Be 2
        }
    }

    Context "When token refresh itself fails" {
        BeforeEach {
            Mock Write-SPLog         -ModuleName SP.ApiClient { }
            Mock Get-SPConfig        -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Clear-SPAuthToken   -ModuleName SP.ApiClient { }
            Mock Start-Sleep         -ModuleName SP.ApiClient { }

            $script:AuthCallCount = 0
            Mock Get-SPAuthToken -ModuleName SP.ApiClient {
                $script:AuthCallCount++
                if ($script:AuthCallCount -eq 1) {
                    return @{
                        Success = $true
                        Data    = @{
                            Token   = 'token-initial'
                            Headers = @{ 'Authorization' = 'Bearer token-initial'; 'Content-Type' = 'application/json' }
                        }
                        Error   = $null
                    }
                }
                return @{ Success = $false; Data = $null; Error = 'ClientSecret expired' }
            }

            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(401) Unauthorized')
            }
        }

        It "Should return Success=false with a refresh-failure message" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns/bad' `
                -CorrelationID 'h2-cid-005'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'Token refresh after 401 failed'
        }
    }
}

# H3: Connection-level failures (WebException with no Response, no HTTP
# status in the message) should be retried the same way 5xx is. Prior
# behavior: any transient network hiccup (DNS blip, TLS handshake, reset)
# produced an immediate non-resumable failure, which killed long-running
# audits on flaky corporate VPNs.
Describe "API-007: Invoke-SPApiRequest retries on connection failure (status=0)" {
    Context "When the first call throws a WebException with no Response and no HTTP status in the message" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:ConnCallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:ConnCallCount++
                if ($script:ConnCallCount -lt 2) {
                    # No 3-digit number anywhere in the message so the regex
                    # fallback in Get-SPStatusCodeFromException returns 0.
                    throw [System.Net.WebException]::new(
                        'The remote name could not be resolved: test.api.identitynow.com'
                    )
                }
                return [PSCustomObject]@{ id = 'after-retry'; status = 'OK' }
            }
        }

        It "Should retry after a connection failure and ultimately succeed" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'h3-cid-001'

            $result.Success        | Should -Be $true
            $result.Data.id        | Should -Be 'after-retry'
            $script:ConnCallCount  | Should -Be 2
        }

        It "Should call Start-Sleep before the retry" {
            $script:ConnCallCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'h3-cid-002'

            Should -Invoke Start-Sleep -ModuleName SP.ApiClient
        }
    }

    Context "When connection failures persist beyond RetryCount" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:ConnCallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:ConnCallCount++
                throw [System.Net.WebException]::new(
                    'Unable to connect to the remote server'
                )
            }
        }

        It "Should stop after RetryCount+1 total attempts and return Success=false" {
            # Mock config has RetryCount=2, so we expect 3 attempts total.
            $script:ConnCallCount = 0
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'h3-cid-003'

            $result.Success       | Should -Be $false
            $result.Error         | Should -Not -BeNullOrEmpty
            $script:ConnCallCount | Should -Be 3
        }
    }
}

Describe "API-008: status-code regex tightening (L1) + exponential backoff (L2)" {

    Context "L1 - port number in error message must NOT be treated as status" {
        # A DNS failure has no HTTP response at all. The exception message may
        # contain 443 (the port). The old greedy regex would extract 443 and
        # return statusCode=443, which is not a retryable code.  The tightened
        # regex must leave statusCode=0 so the connection-failure retry path fires.
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 1 -RetryDelaySeconds 1 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new(
                    'The remote name could not be resolved on port 443'
                )
            }
        }

        It "Should retry (Start-Sleep called) because status stays 0, not 443" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-l1-port-001'

            # Connection-level failure: retried and ultimately fails
            $result.Success | Should -Be $false

            # The retry path calls Start-Sleep; if status were misread as 443
            # (non-retryable) the function would return immediately without sleeping
            Should -Invoke Start-Sleep -ModuleName SP.ApiClient -Times 1 -Exactly
        }
    }

    Context "L1 - actual HTTP 503 in message DOES still match and triggers retry" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 1 -RetryDelaySeconds 1 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(503) Service Unavailable')
            }
        }

        It "Should extract 503 from the message and retry" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-l1-503-001'

            $result.Success    | Should -Be $false
            $result.StatusCode | Should -Be 503

            Should -Invoke Start-Sleep -ModuleName SP.ApiClient -Times 1 -Exactly
        }
    }

    Context "L2 - backoff doubles between attempts" {
        # RetryCount=3, RetryDelaySeconds=1, MaxRetryDelaySeconds=10
        # Expected delays: attempt 0 -> 1*2^0=1s, attempt 1 -> 1*2^1=2s, attempt 2 -> 1*2^2=4s
        BeforeEach {
            $script:RecordedSleeps = [System.Collections.Generic.List[double]]::new()

            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient {
                New-MockSPConfig -RetryCount 3 -RetryDelaySeconds 1 -MaxRetryDelaySeconds 10
            }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Get-SPRateLimitWaitMs -ModuleName SP.ApiClient { return 0 }
            Mock Start-Sleep -ModuleName SP.ApiClient {
                param($Seconds, $Milliseconds)
                if ($PSBoundParameters.ContainsKey('Milliseconds')) {
                    $script:RecordedSleeps.Add([double]$Milliseconds / 1000.0)
                } else {
                    $script:RecordedSleeps.Add([double]$Seconds)
                }
            }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(500) Internal Server Error')
            }
        }

        It "Should record exponentially growing delays of 1, 2, 4 seconds" {
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-l2-backoff-001'

            # Three retries should produce three sleep calls (attempts 0, 1, 2)
            $script:RecordedSleeps.Count | Should -Be 3

            $script:RecordedSleeps[0] | Should -Be 1
            $script:RecordedSleeps[1] | Should -Be 2
            $script:RecordedSleeps[2] | Should -Be 4
        }
    }

    Context "L2 - backoff caps at MaxRetryDelaySeconds" {
        # RetryCount=10, RetryDelaySeconds=5, MaxRetryDelaySeconds=20
        # Uncapped: 5, 10, 20, 40, 80 ... but all above 20 should clamp to 20
        BeforeEach {
            $script:RecordedSleepsCap = [System.Collections.Generic.List[double]]::new()

            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient {
                New-MockSPConfig -RetryCount 10 -RetryDelaySeconds 5 -MaxRetryDelaySeconds 20
            }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Get-SPRateLimitWaitMs -ModuleName SP.ApiClient { return 0 }
            Mock Start-Sleep -ModuleName SP.ApiClient {
                param($Seconds, $Milliseconds)
                if ($PSBoundParameters.ContainsKey('Milliseconds')) {
                    $script:RecordedSleepsCap.Add([double]$Milliseconds / 1000.0)
                } else {
                    $script:RecordedSleepsCap.Add([double]$Seconds)
                }
            }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(500) Internal Server Error')
            }
        }

        It "Should not exceed MaxRetryDelaySeconds on any attempt" {
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' `
                -CorrelationID 'test-l2-cap-001'

            # 10 retries means 10 sleep calls
            $script:RecordedSleepsCap.Count | Should -Be 10

            foreach ($delay in $script:RecordedSleepsCap) {
                $delay | Should -BeLessOrEqual 20
            }

            # First three before cap: 5, 10, 20
            $script:RecordedSleepsCap[0] | Should -Be 5
            $script:RecordedSleepsCap[1] | Should -Be 10
            $script:RecordedSleepsCap[2] | Should -Be 20
            # Remaining should all be capped at 20
            $script:RecordedSleepsCap[3] | Should -Be 20
            $script:RecordedSleepsCap[9] | Should -Be 20
        }
    }
}
