#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x resilience tests for SP.ApiClient (Invoke-SPApiRequest)
.DESCRIPTION
    T-04 -- PROVE that Invoke-SPApiRequest gracefully handles injected API
    failures during the daily attestation cadence: 429 rate limit with a
    honored Retry-After delay, exhausted 5xx, transient timeout/connection
    failures, and that on terminal failure it returns the standard
    @{Success;Data;StatusCode;Error} envelope with no unhandled exception and
    NO silent data loss (Data is null, never partial/garbled).

    Use case IDs: RES-001..RES-004.

    ADDITIVE ONLY -- mirrors Tests/SP.ApiClient.Tests.ps1 (mocked transport,
    no live server). Start-Sleep is ALWAYS mocked so Retry-After/backoff
    seconds never actually sleep -- every test is deterministic and fast.
    Does NOT modify SP.ApiClient.psm1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Helper: build a standard mock config object (copied from SP.ApiClient.Tests.ps1,
    # isolated to this file -- additive).
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

    # Helper: build a standard mock auth result (copied from SP.ApiClient.Tests.ps1).
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

    # NOTE on the 429 Retry-After honor proof (RES-001):
    # Constructing a real header-bearing WebException under PS5.1 is brittle --
    # HttpWebResponse cannot be given custom headers without an active socket,
    # and the bare [WebException]::new('(429) ...') used by API-004 has NO
    # Response, so the header branch in Get-SPRetryAfterMs is never exercised
    # there. The spec sanctions a least-brittle fallback that still proves the
    # honor WIRING: mock Get-SPRetryAfterMs to return the header-derived value
    # (Retry-After=2 -> 2000ms) and assert that Start-Sleep -Milliseconds 2000
    # is what actually fires on the 429 retry (NOT a backoff value), and that
    # Get-SPRetryAfterMs is the function consulted. RES-001 uses that approach.
}

Describe "RES-001: 429 with Retry-After is honored then the request succeeds" {
    # The toolkit honors Retry-After on 429 (Get-SPRetryAfterMs). The bare
    # WebException used by API-004 has no Response, so the honored-delay branch
    # is never run there. Here we PROVE the honor wiring by mocking
    # Get-SPRetryAfterMs to return the header-derived 2000ms and asserting that
    # Start-Sleep -Milliseconds 2000 is what actually fires on the 429 retry
    # (NOT a backoff value). This is the least-brittle approach under PS5.1 and
    # is the documented fallback in the spec; it exercises exactly the code path
    # Invoke-SPApiRequest takes for a header-bearing 429.
    Context "When a 429 carries Retry-After: 2 and the next call succeeds" {
        BeforeEach {
            $script:RecordedSleeps = [System.Collections.Generic.List[double]]::new()

            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 2 -RetryDelaySeconds 1 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            # Honor proof: the 429 path resolves the wait via Get-SPRetryAfterMs.
            # Force it to the header-derived value (Retry-After=2 -> 2000ms).
            Mock Get-SPRetryAfterMs -ModuleName SP.ApiClient { return 2000 }
            Mock Start-Sleep -ModuleName SP.ApiClient {
                param($Seconds, $Milliseconds)
                if ($PSBoundParameters.ContainsKey('Milliseconds')) {
                    $script:RecordedSleeps.Add([double]$Milliseconds)
                } else {
                    $script:RecordedSleeps.Add([double]$Seconds * 1000.0)
                }
            }

            $script:RlCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:RlCount++
                if ($script:RlCount -lt 2) {
                    throw [System.Net.WebException]::new('(429) Too Many Requests')
                }
                return [PSCustomObject]@{ id = 'camp-after-rate-limit'; status = 'ACTIVE' }
            }
        }

        It "Should retry after the 429 and return Success=true with Data populated and Error empty" {
            $script:RlCount = 0
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-001a'

            $result         | Should -Not -BeNullOrEmpty
            $result.Success | Should -Be $true
            $result.Data    | Should -Not -BeNullOrEmpty
            $result.Data.id | Should -Be 'camp-after-rate-limit'
            $result.Error   | Should -BeNullOrEmpty
        }

        It "Should honor the Retry-After delay (sleep 2000ms) on the 429 retry, not a backoff value" {
            $script:RlCount = 0
            $script:RecordedSleeps = [System.Collections.Generic.List[double]]::new()
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-001b'

            # Exactly one retry happened; the recorded sleep equals the
            # header-derived 2000ms (honor proof), NOT the 1s default backoff.
            $script:RecordedSleeps.Count | Should -Be 1
            $script:RecordedSleeps[0]    | Should -Be 2000
        }

        It "Should resolve the wait via Get-SPRetryAfterMs (honor wiring engaged)" {
            $script:RlCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-001c'

            Should -Invoke Get-SPRetryAfterMs -ModuleName SP.ApiClient -Times 1
        }
    }
}

Describe "RES-002: Repeated 500s exhaust retries and return a clear failure envelope" {
    Context "When the API always returns 500 (RetryCount=2 => 3 attempts)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 2 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(500) Internal Server Error')
            }
        }

        It "Should NOT throw an unhandled exception (no crash)" {
            { $script:r = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-002a' } |
                Should -Not -Throw
        }

        It "Should return Success=false, StatusCode 500, a clear Error, and null Data (no silent data loss)" {
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-002b'

            $result.Success    | Should -Be $false
            $result.StatusCode | Should -Be 500
            $result.Error      | Should -Not -BeNullOrEmpty
            $result.Error      | Should -Match 'Request failed after'
            # Crucial: no partial / garbled Data on terminal failure.
            $result.Data       | Should -BeNullOrEmpty
        }
    }
}

Describe "RES-003: Transient timeout / WebException retries per policy" {
    # A timeout WebException has no Response and no 3-digit code in the message,
    # so Get-SPStatusCodeFromException returns 0 => the connection-failure retry
    # path fires (mirrors API-007 status=0).
    Context "When a timeout occurs once then the call succeeds" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 2 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:CallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:CallCount++
                if ($script:CallCount -lt 2) {
                    throw [System.Net.WebException]::new('The operation has timed out')
                }
                return [PSCustomObject]@{ id = 'camp-after-timeout'; status = 'OK' }
            }
        }

        It "Should retry after the timeout and ultimately succeed (CallCount == failures+1)" {
            $script:CallCount = 0
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-003a'

            $result.Success   | Should -Be $true
            $result.Data      | Should -Not -BeNullOrEmpty
            $result.Data.id   | Should -Be 'camp-after-timeout'
            $script:CallCount | Should -Be 2
        }

        It "Should call Start-Sleep before the retry" {
            $script:CallCount = 0
            Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-003b'

            Should -Invoke Start-Sleep -ModuleName SP.ApiClient
        }
    }

    Context "When the timeout persists beyond RetryCount (RetryCount=2 => 3 attempts)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 2 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }

            $script:CallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                $script:CallCount++
                throw [System.Net.WebException]::new('The operation has timed out')
            }
        }

        It "Should stop after 3 attempts and return Success=false with a non-empty Error" {
            $script:CallCount = 0
            $result = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-003c'

            $result.Success   | Should -Be $false
            $result.Error     | Should -Not -BeNullOrEmpty
            $result.Data      | Should -BeNullOrEmpty
            $script:CallCount | Should -Be 3
        }
    }
}

Describe "RES-004: Terminal failure always returns the standard envelope shape" {
    # Consolidated assertion that on ANY terminal failure the return is the
    # standard hashtable with keys Success/Data/StatusCode/Error present, Data
    # null, Error a non-empty string -- the envelope is never partial.
    Context "When the API consistently fails (503)" {
        BeforeEach {
            Mock Write-SPLog     -ModuleName SP.ApiClient { }
            Mock Get-SPConfig    -ModuleName SP.ApiClient { New-MockSPConfig -RetryCount 1 }
            Mock Get-SPAuthToken -ModuleName SP.ApiClient { New-MockAuthResult }
            Mock Start-Sleep     -ModuleName SP.ApiClient { }
            Mock Invoke-RestMethod -ModuleName SP.ApiClient {
                throw [System.Net.WebException]::new('(503) Service Unavailable')
            }
        }

        It "Should return a complete @{Success;Data;StatusCode;Error} envelope with Data null and Error a non-empty string" {
            $script:res004 = $null
            { $script:res004 = Invoke-SPApiRequest -Method GET -Endpoint '/campaigns' -CorrelationID 'res-004a' } |
                Should -Not -Throw
            $result = $script:res004

            $result                 | Should -BeOfType [hashtable]
            $result.ContainsKey('Success')    | Should -Be $true
            $result.ContainsKey('Data')       | Should -Be $true
            $result.ContainsKey('StatusCode') | Should -Be $true
            $result.ContainsKey('Error')      | Should -Be $true

            $result.Success | Should -Be $false
            $result.Data    | Should -BeNullOrEmpty
            $result.Error   | Should -BeOfType [string]
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}
