#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkCampaignFilters module.
.DESCRIPTION
    Validates campaign filter CRUD functions.
    Test IDs: SDK-FILT-001 through SDK-FILT-005.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Sdk
}

Describe 'SP.SdkCampaignFilters - Campaign Filter Management' {

    Context 'SDK-FILT-001: Get-SPSdkCampaignFilters lists filters' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Get-SPConfig -ModuleName SP.SdkCommon {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                    Sdk = [PSCustomObject]@{ OutputPath = '.\SdkReports' }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        items = @(
                            [PSCustomObject]@{ id = 'filt-001'; name = 'Exclude Service Accounts'; mode = 'EXCLUSION' },
                            [PSCustomObject]@{ id = 'filt-002'; name = 'Include IT Only'; mode = 'INCLUSION' }
                        )
                        count = 2
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with filter list' {
            $result = Get-SPSdkCampaignFilters -CorrelationID 'sdk-filt-001a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Error      | Should -BeNullOrEmpty
        }

        It 'calls Invoke-SPApiRequest with GET /campaign-filters' {
            Get-SPSdkCampaignFilters -CorrelationID 'sdk-filt-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaign-filters'
            }
        }

        It 'passes limit and start as query params' {
            Get-SPSdkCampaignFilters -Limit 50 -Offset 10 -CorrelationID 'sdk-filt-001c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $QueryParams['limit'] -eq '50' -and $QueryParams['start'] -eq '10'
            }
        }

        It 'passes includeSystemFilters=false when disabled' {
            Get-SPSdkCampaignFilters -IncludeSystemFilters $false -CorrelationID 'sdk-filt-001d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $QueryParams['includeSystemFilters'] -eq 'false'
            }
        }
    }

    Context 'SDK-FILT-001b: Get-SPSdkCampaignFilters handles API failure' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{ Success = $false; Data = $null; Error = 'API connection failed' }
            }
        }

        It 'returns Success=false with error on API failure' {
            $result = Get-SPSdkCampaignFilters -CorrelationID 'sdk-filt-001e'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-FILT-002: Get-SPSdkCampaignFilter gets single filter' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id          = 'filt-001'
                        name        = 'Exclude Service Accounts'
                        description = 'Excludes all service accounts from campaigns'
                        mode        = 'EXCLUSION'
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with filter data' {
            $result = Get-SPSdkCampaignFilter -FilterId 'filt-001' -CorrelationID 'sdk-filt-002a'
            $result.Success   | Should -Be $true
            $result.Data.id   | Should -Be 'filt-001'
            $result.Data.name | Should -Be 'Exclude Service Accounts'
        }

        It 'calls the correct endpoint with filter ID' {
            Get-SPSdkCampaignFilter -FilterId 'filt-001' -CorrelationID 'sdk-filt-002b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaign-filters/filt-001'
            }
        }
    }

    Context 'SDK-FILT-003: New-SPSdkCampaignFilter creates a filter' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id   = 'filt-new-001'
                        name = 'New Campaign Filter'
                        mode = 'INCLUSION'
                    }
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with created filter' {
            $filter = @{
                name         = 'New Campaign Filter'
                description  = 'A new filter'
                mode         = 'INCLUSION'
                criteriaList = @(@{ type = 'IDENTITY_ATTRIBUTE'; property = 'department'; value = 'IT'; operation = 'EQUALS' })
            }
            $result = New-SPSdkCampaignFilter -Filter $filter -CorrelationID 'sdk-filt-003a' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.id   | Should -Be 'filt-new-001'
        }

        It 'calls POST /campaign-filters with the filter body' {
            $filter = @{
                name         = 'New Campaign Filter'
                description  = 'A new filter'
                mode         = 'INCLUSION'
                criteriaList = @(@{ type = 'IDENTITY_ATTRIBUTE'; property = 'department'; value = 'IT'; operation = 'EQUALS' })
            }
            New-SPSdkCampaignFilter -Filter $filter -CorrelationID 'sdk-filt-003b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaign-filters' -and $Body.name -eq 'New Campaign Filter'
            }
        }

        It 'respects ShouldProcess (WhatIf returns skip message)' {
            $filter = @{ name = 'WhatIf Test'; mode = 'EXCLUSION'; criteriaList = @() }
            $result = New-SPSdkCampaignFilter -Filter $filter -WhatIf -CorrelationID 'sdk-filt-003c'
            $result.Error | Should -Be 'Skipped (WhatIf)'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -Times 0 -Exactly
        }
    }

    Context 'SDK-FILT-004: Update-SPSdkCampaignFilter updates a filter' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'filt-001'; name = 'Updated Filter'; mode = 'INCLUSION' }
                    Error   = $null
                }
            }
        }

        It 'calls POST /campaign-filters/{id} with full filter body' {
            $filter = @{
                name         = 'Updated Filter'
                mode         = 'INCLUSION'
                criteriaList = @(@{ type = 'IDENTITY_ATTRIBUTE'; property = 'department'; value = 'HR'; operation = 'EQUALS' })
            }
            Update-SPSdkCampaignFilter -FilterId 'filt-001' -Filter $filter `
                -CorrelationID 'sdk-filt-004a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'POST' -and
                $Endpoint -eq '/campaign-filters/filt-001' -and
                $Body.name -eq 'Updated Filter'
            }
        }

        It 'returns Success=true with updated filter' {
            $filter = @{
                name         = 'Updated Filter'
                mode         = 'INCLUSION'
                criteriaList = @(@{ type = 'IDENTITY_ATTRIBUTE'; property = 'department'; value = 'HR'; operation = 'EQUALS' })
            }
            $result = Update-SPSdkCampaignFilter -FilterId 'filt-001' -Filter $filter `
                -CorrelationID 'sdk-filt-004b' -Confirm:$false
            $result.Success   | Should -Be $true
            $result.Data.name | Should -Be 'Updated Filter'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $filter = @{ name = 'WhatIf'; mode = 'EXCLUSION'; criteriaList = @() }
            $result = Update-SPSdkCampaignFilter -FilterId 'filt-001' -Filter $filter `
                -WhatIf -CorrelationID 'sdk-filt-004c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -Times 0 -Exactly
        }
    }

    Context 'SDK-FILT-005: Remove-SPSdkCampaignFilter deletes filter(s)' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCampaignFilters { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{ Success = $true; Data = $null; Error = $null }
            }
        }

        It 'calls POST /campaign-filters/delete with filter ID array' {
            Remove-SPSdkCampaignFilter -FilterId 'filt-001' -CorrelationID 'sdk-filt-005a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaign-filters/delete'
            }
        }

        It 'returns Success=true with null Data after delete' {
            $result = Remove-SPSdkCampaignFilter -FilterId 'filt-001' -CorrelationID 'sdk-filt-005b' -Confirm:$false
            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Remove-SPSdkCampaignFilter -FilterId 'filt-001' -WhatIf -CorrelationID 'sdk-filt-005c'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -Times 0 -Exactly
        }

        It 'accepts multiple filter IDs for bulk delete' {
            Remove-SPSdkCampaignFilter -FilterId @('filt-001', 'filt-002') -CorrelationID 'sdk-filt-005d' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/campaign-filters/delete' -and $Body.Count -eq 2
            }
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCampaignFilters {
                return @{ Success = $false; Data = $null; Error = 'Server Error' }
            }

            $result = Remove-SPSdkCampaignFilter -FilterId 'filt-err' -CorrelationID 'sdk-filt-005e' -Confirm:$false
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}
