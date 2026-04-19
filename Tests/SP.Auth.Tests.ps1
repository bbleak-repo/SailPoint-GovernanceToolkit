#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.Auth module
.DESCRIPTION
    Unit tests for OAuth 2.0 client_credentials authentication, token caching,
    force-refresh, error handling, and token clearing.
    Test IDs: AUTH-001 through AUTH-005
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    Import-Module $modulePath -Force

    $script:ValidConfigPath = Join-Path $PSScriptRoot "TestData\valid-settings.json"

    # Shared mock config used by most auth tests
    $script:MockConfig = [PSCustomObject]@{
        Global = [PSCustomObject]@{
            EnvironmentName = 'TestLab'
            DebugMode       = $false
            ToolkitVersion  = '1.0.0'
        }
        Authentication = [PSCustomObject]@{
            Mode       = 'ConfigFile'
            ConfigFile = [PSCustomObject]@{
                TenantUrl     = 'https://testlab.api.identitynow.com'
                OAuthTokenUrl = 'https://testlab.api.identitynow.com/oauth/token'
                ClientId      = 'test-client-id'
                ClientSecret  = 'test-client-secret'
            }
            Vault = [PSCustomObject]@{
                VaultPath        = '.\Data\sp-vault.enc'
                Pbkdf2Iterations = 600000
                CredentialKey    = 'sailpoint-isc'
            }
        }
        Logging = [PSCustomObject]@{
            Path            = 'TestDrive:\Logs'
            FilePrefix      = 'GovernanceToolkit'
            MinimumSeverity = 'DEBUG'
            RetentionDays   = 30
        }
        Api = [PSCustomObject]@{
            BaseUrl        = 'https://testlab.api.identitynow.com/v3'
            TimeoutSeconds = 60
        }
        Testing = [PSCustomObject]@{
            DefaultDecision = 'APPROVE'
            WhatIfByDefault = $false
        }
        Safety = [PSCustomObject]@{
            MaxCampaignsPerRun    = 10
            RequireWhatIfOnProd   = $false
            AllowCompleteCampaign = $false
        }
    }
}

Describe "Get-SPAuthToken" {

    Context "AUTH-001: Succeeds with valid credentials" {
        It "Should return Success=true with valid mock credentials" {
            # Suppress actual logging during tests
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            Mock Invoke-RestMethod -ModuleName SP.Auth {
                [PSCustomObject]@{
                    access_token = 'mock-bearer-token-abc123'
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            # Clear any stale cached token from previous tests
            Clear-SPAuthToken

            $result = Get-SPAuthToken -CorrelationID 'AUTH-001'
            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
        }

        It "Should return correct token data structure" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            Mock Invoke-RestMethod -ModuleName SP.Auth {
                [PSCustomObject]@{
                    access_token = 'mock-bearer-token-structure-test'
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            Clear-SPAuthToken

            $result = Get-SPAuthToken -Force -CorrelationID 'AUTH-001b'
            $result.Success                    | Should -Be $true
            $result.Data.Token                 | Should -Be 'mock-bearer-token-structure-test'
            $result.Data.Mode                  | Should -Be 'ConfigFile'
            $result.Data.Headers.'Authorization' | Should -Be 'Bearer mock-bearer-token-structure-test'
            $result.Data.Headers.'Content-Type'  | Should -Be 'application/json'
            $result.Data.ExpiresAt             | Should -BeOfType [datetime]
        }

        AfterEach {
            Clear-SPAuthToken
        }
    }

    Context "AUTH-002: Returns cached token on second call" {
        It "Should not call Invoke-RestMethod a second time when token is cached" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            $script:callCount = 0
            Mock Invoke-RestMethod -ModuleName SP.Auth {
                $script:callCount++
                [PSCustomObject]@{
                    access_token = 'mock-cached-token'
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            Clear-SPAuthToken

            # First call: should hit Invoke-RestMethod
            $result1 = Get-SPAuthToken -Force -CorrelationID 'AUTH-002-first'
            $result1.Success | Should -Be $true
            $script:callCount | Should -Be 1

            # Second call: should use cache, not call Invoke-RestMethod again
            $result2 = Get-SPAuthToken -CorrelationID 'AUTH-002-second'
            $result2.Success | Should -Be $true
            $script:callCount | Should -Be 1   # still 1 - no new REST call

            # Tokens should match
            $result2.Data.Token | Should -Be 'mock-cached-token'
        }

        AfterEach {
            Clear-SPAuthToken
        }
    }

    Context "AUTH-003: -Force gets fresh token" {
        It "Should call Invoke-RestMethod again when -Force is specified" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            $script:callCount2 = 0
            Mock Invoke-RestMethod -ModuleName SP.Auth {
                $script:callCount2++
                [PSCustomObject]@{
                    access_token = "forced-token-call-$script:callCount2"
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            Clear-SPAuthToken

            # First call
            $result1 = Get-SPAuthToken -CorrelationID 'AUTH-003-first'
            $result1.Success | Should -Be $true
            $script:callCount2 | Should -Be 1

            # Force refresh
            $result2 = Get-SPAuthToken -Force -CorrelationID 'AUTH-003-force'
            $result2.Success | Should -Be $true
            $script:callCount2 | Should -Be 2   # second REST call made

            $result2.Data.Token | Should -Be 'forced-token-call-2'
        }

        AfterEach {
            Clear-SPAuthToken
        }
    }

    Context "AUTH-004: Handles API error gracefully" {
        It "Should return Success=false and non-empty Error when Invoke-RestMethod throws" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            Mock Invoke-RestMethod -ModuleName SP.Auth {
                throw [System.Net.WebException]::new('401 Unauthorized - invalid_client')
            }

            Clear-SPAuthToken

            $result = Get-SPAuthToken -Force -CorrelationID 'AUTH-004'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
            $result.Data    | Should -BeNullOrEmpty
        }

        It "Should not throw an exception - returns error hashtable instead" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            Mock Invoke-RestMethod -ModuleName SP.Auth {
                throw 'Network connection refused'
            }

            Clear-SPAuthToken

            { Get-SPAuthToken -Force -CorrelationID 'AUTH-004-nothrow' } | Should -Not -Throw
        }

        AfterEach {
            Clear-SPAuthToken
        }
    }

    Context "AUTH-005: Clear-SPAuthToken clears cached token" {
        It "Should cause the next Get-SPAuthToken call to re-authenticate" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            $script:authCallCount = 0
            Mock Invoke-RestMethod -ModuleName SP.Auth {
                $script:authCallCount++
                [PSCustomObject]@{
                    access_token = "cleartest-token-$script:authCallCount"
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            Clear-SPAuthToken

            # Authenticate
            $result1 = Get-SPAuthToken -CorrelationID 'AUTH-005-first'
            $result1.Success | Should -Be $true
            $script:authCallCount | Should -Be 1

            # Clear
            Clear-SPAuthToken

            # Re-authenticate - must call Invoke-RestMethod again
            $result2 = Get-SPAuthToken -CorrelationID 'AUTH-005-after-clear'
            $result2.Success | Should -Be $true
            $script:authCallCount | Should -Be 2
            $result2.Data.Token | Should -Be 'cleartest-token-2'
        }

        It "Should not throw when no token is cached" {
            # Clear any state first
            Clear-SPAuthToken
            { Clear-SPAuthToken } | Should -Not -Throw
        }

        It "Should set token to null after clearing" {
            Mock Write-SPLog { } -ModuleName SP.Auth
            Mock Get-SPConfig { $script:MockConfig } -ModuleName SP.Auth

            Mock Invoke-RestMethod -ModuleName SP.Auth {
                [PSCustomObject]@{
                    access_token = 'token-to-be-cleared'
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            Clear-SPAuthToken
            Get-SPAuthToken -Force | Out-Null
            Clear-SPAuthToken

            # After clear, next call must not return the old cached token
            Mock Invoke-RestMethod -ModuleName SP.Auth {
                [PSCustomObject]@{
                    access_token = 'new-token-after-clear'
                    token_type   = 'bearer'
                    expires_in   = 749
                }
            }

            $result = Get-SPAuthToken
            $result.Data.Token | Should -Be 'new-token-after-clear'
        }

        AfterEach {
            Clear-SPAuthToken
        }
    }
}
