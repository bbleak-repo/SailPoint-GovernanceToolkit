#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.Sources module
.DESCRIPTION
    Tests: SRC-001 through SRC-008
    Covers:
        SRC-001: Get-SPSource                    -- single source retrieval, API error passthrough
        SRC-002: Get-SPSources                   -- name / prefix / connector filter syntax
        SRC-003: Get-SPSources                   -- offset/limit pagination across pages
        SRC-004: Get-SPEntitlements              -- combined source + name prefix filters
        SRC-005: Get-SPEntitlements              -- items-wrapped response unwrapping
        SRC-006: Start-SPAccountAggregation      -- endpoint, body, and -WhatIf suppression
        SRC-007: Start-SPEntitlementAggregation  -- endpoint, body, and -WhatIf suppression
        SRC-008: Get-SPProvisioningPolicies      -- policy list retrieval

    Note on mock-scoping:
        Import-SPTestModules imports each .psm1 flat (top-level), so Invoke-SPApiRequest
        is mocked with -ModuleName SP.Sources -- the module whose scope contains the
        call site. This is the Bug-1 flat-import rule and passes on both PS 5.1 and PS7.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Minimal mock config consumed by the pagination-ceiling helper
    function New-MockSourcesConfig {
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = 1
                RetryDelaySeconds          = 1
                RateLimitRequestsPerWindow = 95
                RateLimitWindowSeconds     = 10
                MaxPaginationPages         = 200
            }
        }
    }

    # Builds a minimal ISC entitlement object
    function New-MockEntitlement {
        param(
            [string]$Id       = 'ent-001',
            [string]$Name     = 'CLD-B2B-PartnerA-Users',
            [string]$SourceId = 'src-entra-001'
        )
        return [PSCustomObject]@{
            id     = $Id
            name   = $Name
            type   = 'ENTITLEMENT'
            source = [PSCustomObject]@{ id = $SourceId; name = 'Entra ID - CORP' }
        }
    }
}

Describe "SRC-001: Get-SPSource retrieves a single source" {
    Context "When the source exists" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        id        = 'src-entra-001'
                        name      = 'Entra ID - CORP'
                        connector = 'azure-active-directory'
                        owner     = [PSCustomObject]@{ id = 'ident-owner-1'; type = 'IDENTITY' }
                    }
                    Error = $null
                }
            }
        }

        It "Should return Success=true with the source object" {
            $result = Get-SPSource -SourceId 'src-entra-001' -CorrelationID 'src-cid-001'

            $result.Success            | Should -Be $true
            $result.Data.id            | Should -Be 'src-entra-001'
            $result.Data.connector     | Should -Be 'azure-active-directory'
            $result.Error              | Should -BeNullOrEmpty
        }

        It "Should GET /v3/sources/{id}" {
            Get-SPSource -SourceId 'src-entra-001' -CorrelationID 'src-cid-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/v3/sources/src-entra-001'
            }
        }
    }

    Context "When the API returns an error" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{ Success = $false; Data = $null; StatusCode = 404; Error = 'Source not found' }
            }
        }

        It "Should return Success=false with the API error" {
            $result = Get-SPSource -SourceId 'src-missing' -CorrelationID 'src-cid-001c'

            $result.Success | Should -Be $false
            $result.Data    | Should -BeNullOrEmpty
            $result.Error   | Should -Match 'not found'
        }
    }
}

Describe "SRC-002: Get-SPSources builds ISC filter syntax" {
    BeforeEach {
        Mock Write-SPLog  -ModuleName SP.Sources { }
        Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }
        Mock Invoke-SPApiRequest -ModuleName SP.Sources {
            return @{ Success = $true; StatusCode = 200; Data = [PSCustomObject]@{ items = @() }; Error = $null }
        }
    }

    It "Should use 'name eq' for an exact name match" {
        Get-SPSources -Name 'Entra ID - CORP' -CorrelationID 'src-cid-002a'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            $Endpoint -eq '/v3/sources' -and
            $QueryParams['filters'] -eq 'name eq "Entra ID - CORP"'
        }
    }

    It "Should use 'name sw' for a prefix match" {
        Get-SPSources -NamePrefix 'Entra' -CorrelationID 'src-cid-002b'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            $QueryParams['filters'] -eq 'name sw "Entra"'
        }
    }

    It "Should combine name and connector filters with 'and'" {
        Get-SPSources -Name 'Entra ID - CORP' -ConnectorType 'azure-active-directory' `
            -CorrelationID 'src-cid-002c'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            $QueryParams['filters'] -eq 'name eq "Entra ID - CORP" and connector eq "azure-active-directory"'
        }
    }

    It "Should omit the filters parameter entirely when no filter is supplied" {
        Get-SPSources -CorrelationID 'src-cid-002d'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            -not $QueryParams.ContainsKey('filters')
        }
    }
}

Describe "SRC-003: Get-SPSources paginates with offset/limit" {
    Context "When results span more than one page" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Sources { }
            Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }

            $script:SourcePageCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                $script:SourcePageCount++
                # First page full (250), second page short -> loop terminates
                $count = if ($script:SourcePageCount -eq 1) { 250 } else { 3 }
                $items = @(1..$count | ForEach-Object {
                    [PSCustomObject]@{ id = "src-$script:SourcePageCount-$_"; name = "Source $_" }
                })
                return @{ Success = $true; StatusCode = 200; Data = [PSCustomObject]@{ items = $items }; Error = $null }
            }
        }

        It "Should accumulate every page into a single Data array" {
            $result = Get-SPSources -CorrelationID 'src-cid-003a'

            $result.Success     | Should -Be $true
            $result.Data.Count  | Should -Be 253
        }

        It "Should advance the offset on the second request" {
            $script:SourcePageCount = 0
            Get-SPSources -CorrelationID 'src-cid-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $QueryParams['offset'] -eq '0' -and $QueryParams['limit'] -eq '250'
            }
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $QueryParams['offset'] -eq '250'
            }
        }
    }

    Context "When the API fails mid-pagination" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Sources { }
            Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{ Success = $false; Data = $null; StatusCode = 403; Error = 'Forbidden' }
            }
        }

        It "Should return Success=false rather than a partial array" {
            $result = Get-SPSources -CorrelationID 'src-cid-003c'

            $result.Success | Should -Be $false
            $result.Data    | Should -BeNullOrEmpty
            $result.Error   | Should -Match 'Forbidden'
        }
    }
}

Describe "SRC-004: Get-SPEntitlements applies source and name filters" {
    BeforeEach {
        Mock Write-SPLog  -ModuleName SP.Sources { }
        Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }
        Mock Invoke-SPApiRequest -ModuleName SP.Sources {
            return @{ Success = $true; StatusCode = 200; Data = [PSCustomObject]@{ items = @() }; Error = $null }
        }
    }

    It "Should combine 'source.id eq' with 'name sw'" {
        Get-SPEntitlements -SourceId 'src-entra-001' -NamePrefix 'CLD-B2B-PartnerA' `
            -CorrelationID 'src-cid-004a'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            $Endpoint -eq '/v3/entitlements' -and
            $QueryParams['filters'] -eq 'source.id eq "src-entra-001" and name sw "CLD-B2B-PartnerA"'
        }
    }

    It "Should use 'name eq' for an exact entitlement lookup" {
        Get-SPEntitlements -SourceId 'src-entra-001' -Name 'CLD-B2B-PartnerA-Users' `
            -CorrelationID 'src-cid-004b'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
            $QueryParams['filters'] -eq 'source.id eq "src-entra-001" and name eq "CLD-B2B-PartnerA-Users"'
        }
    }
}

Describe "SRC-005: Get-SPEntitlements unwraps the items envelope" {
    Context "When the API returns an items-wrapped page" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Sources { }
            Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{
                        items = @(
                            (New-MockEntitlement -Id 'ent-1' -Name 'CLD-B2B-PartnerA-Users'),
                            (New-MockEntitlement -Id 'ent-2' -Name 'CLD-B2B-PartnerA-Leadership')
                        )
                    }
                    Error = $null
                }
            }
        }

        It "Should return the entitlement objects, not the envelope" {
            $result = Get-SPEntitlements -SourceId 'src-entra-001' -CorrelationID 'src-cid-005a'

            $result.Success       | Should -Be $true
            $result.Data.Count    | Should -Be 2
            $result.Data[0].name  | Should -Be 'CLD-B2B-PartnerA-Users'
        }
    }

    Context "When the API returns a bare array" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.Sources { }
            Mock Get-SPConfig -ModuleName SP.Sources { New-MockSourcesConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @((New-MockEntitlement -Id 'ent-9' -Name 'CLD-B2B-PartnerB-Users'))
                    Error      = $null
                }
            }
        }

        It "Should still return the entitlement objects" {
            $result = Get-SPEntitlements -SourceId 'src-entra-001' -CorrelationID 'src-cid-005b'

            $result.Success      | Should -Be $true
            $result.Data.Count   | Should -Be 1
            $result.Data[0].id   | Should -Be 'ent-9'
        }
    }
}

Describe "SRC-006: Start-SPAccountAggregation triggers load-accounts" {
    Context "When the aggregation is confirmed" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ id = 'task-acct-001'; type = 'ACCOUNT_AGGREGATION' }
                    Error      = $null
                }
            }
        }

        It "Should POST to /v3/sources/{id}/load-accounts" {
            $result = Start-SPAccountAggregation -SourceId 'src-entra-001' -CorrelationID 'src-cid-006a'

            $result.Success | Should -Be $true
            $result.Data.id | Should -Be 'task-acct-001'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/v3/sources/src-entra-001/load-accounts'
            }
        }

        It "Should send disableOptimization=true when the switch is set" {
            Start-SPAccountAggregation -SourceId 'src-entra-001' -DisableOptimization `
                -CorrelationID 'src-cid-006b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Body['disableOptimization'] -eq $true
            }
        }

        It "Should send disableOptimization=false by default" {
            Start-SPAccountAggregation -SourceId 'src-entra-001' -CorrelationID 'src-cid-006c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Body['disableOptimization'] -eq $false
            }
        }
    }

    Context "When -WhatIf is supplied" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources { }
        }

        It "Should not call the API and should report the skip" {
            $result = Start-SPAccountAggregation -SourceId 'src-entra-001' `
                -CorrelationID 'src-cid-006d' -WhatIf

            $result.Success | Should -Be $true
            $result.Error   | Should -Match 'WhatIf'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -Times 0 -Exactly
        }
    }
}

Describe "SRC-007: Start-SPEntitlementAggregation triggers load-entitlements" {
    Context "When the aggregation is confirmed" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = [PSCustomObject]@{ id = 'task-ent-001'; type = 'ENTITLEMENT_AGGREGATION' }
                    Error      = $null
                }
            }
        }

        It "Should POST to /v3/sources/{id}/load-entitlements" {
            $result = Start-SPEntitlementAggregation -SourceId 'src-entra-001' -CorrelationID 'src-cid-007a'

            $result.Success | Should -Be $true

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/v3/sources/src-entra-001/load-entitlements'
            }
        }
    }

    Context "When the API rejects the request" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{ Success = $false; Data = $null; StatusCode = 403; Error = 'Forbidden' }
            }
        }

        It "Should return Success=false with the API error" {
            $result = Start-SPEntitlementAggregation -SourceId 'src-entra-001' -CorrelationID 'src-cid-007b'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'Forbidden'
        }
    }

    Context "When -WhatIf is supplied" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources { }
        }

        It "Should not call the API" {
            Start-SPEntitlementAggregation -SourceId 'src-entra-001' `
                -CorrelationID 'src-cid-007c' -WhatIf

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -Times 0 -Exactly
        }
    }
}

Describe "SRC-008: Get-SPProvisioningPolicies returns the policy list" {
    Context "When the source has provisioning policies" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{ name = 'Account Create'; usageType = 'CREATE' },
                        [PSCustomObject]@{ name = 'Add Entitlement'; usageType = 'ADD_ENTITLEMENT' },
                        [PSCustomObject]@{ name = 'Remove Entitlement'; usageType = 'REMOVE_ENTITLEMENT' }
                    )
                    Error = $null
                }
            }
        }

        It "Should GET /v3/sources/{id}/provisioning-policies" {
            $result = Get-SPProvisioningPolicies -SourceId 'src-entra-001' -CorrelationID 'src-cid-008a'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 3

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Sources -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/v3/sources/src-entra-001/provisioning-policies'
            }
        }

        It "Should expose usageType values for the entitlement policies" {
            $result = Get-SPProvisioningPolicies -SourceId 'src-entra-001' -CorrelationID 'src-cid-008b'

            $usageTypes = @($result.Data | ForEach-Object { $_.usageType })
            $usageTypes | Should -Contain 'ADD_ENTITLEMENT'
            $usageTypes | Should -Contain 'REMOVE_ENTITLEMENT'
        }
    }

    Context "When the source has no provisioning policies" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Sources { }
            Mock Invoke-SPApiRequest -ModuleName SP.Sources {
                return @{ Success = $true; StatusCode = 200; Data = @(); Error = $null }
            }
        }

        It "Should return Success=true with an empty array" {
            $result = Get-SPProvisioningPolicies -SourceId 'src-entra-001' -CorrelationID 'src-cid-008c'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}
