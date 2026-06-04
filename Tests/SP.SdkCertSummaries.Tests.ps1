#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkCertSummaries module.
.DESCRIPTION
    Validates certification summary query functions including single-page,
    auto-paginated, and decision summary endpoints.
    Test IDs: SDK-CERT-001 through SDK-CERT-006.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Sdk
}

Describe 'SP.SdkCertSummaries - Certification Summary Queries' {

    Context 'SDK-CERT-001: Get-SPSdkIdentitySummaries lists identity summaries' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'is-001'; name = 'John Smith'; decision = 'APPROVE' },
                        [PSCustomObject]@{ id = 'is-002'; name = 'Jane Doe'; decision = 'REVOKE' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with identity summaries' {
            $result = Get-SPSdkIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-001a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Error      | Should -BeNullOrEmpty
        }

        It 'calls the correct endpoint with certification ID' {
            Get-SPSdkIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/certifications/cert-001/identity-summaries'
            }
        }

        It 'passes filters and sorters as query params' {
            Get-SPSdkIdentitySummaries -CertificationId 'cert-001' `
                -Filters 'name co "smith"' -Sorters 'name' -CorrelationID 'sdk-cert-001c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['filters'] -eq 'name co "smith"' -and $QueryParams['sorters'] -eq 'name'
            }
        }

        It 'passes limit and offset as query params' {
            Get-SPSdkIdentitySummaries -CertificationId 'cert-001' `
                -Limit 100 -Offset 50 -CorrelationID 'sdk-cert-001d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['limit'] -eq '100' -and $QueryParams['offset'] -eq '50'
            }
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{ Success = $false; Data = $null; Error = 'API timeout' }
            }

            $result = Get-SPSdkIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-001e'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-CERT-002: Get-SPSdkAllIdentitySummaries auto-paginates' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'is-001'; name = 'User 1' },
                        [PSCustomObject]@{ id = 'is-002'; name = 'User 2' },
                        [PSCustomObject]@{ id = 'is-003'; name = 'User 3' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns all paginated identity summaries' {
            $result = Get-SPSdkAllIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-002a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 3
        }

        It 'calls Invoke-SPSdkPaginatedGet with correct endpoint' {
            Get-SPSdkAllIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-002b'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Endpoint -eq '/certifications/cert-001/identity-summaries'
            }
        }

        It 'passes filters to the paginator' {
            Get-SPSdkAllIdentitySummaries -CertificationId 'cert-001' `
                -Filters 'decision eq "APPROVE"' -CorrelationID 'sdk-cert-002c'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['filters'] -eq 'decision eq "APPROVE"'
            }
        }

        It 'returns Success=false on paginator failure' {
            Mock Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries {
                return @{ Success = $false; Data = $null; Error = 'Pagination ceiling reached' }
            }

            $result = Get-SPSdkAllIdentitySummaries -CertificationId 'cert-001' -CorrelationID 'sdk-cert-002d'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-CERT-003: Get-SPSdkIdentitySummary gets single identity summary' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        id       = 'is-001'
                        name     = 'John Smith'
                        decision = 'APPROVE'
                    }
                    Error   = $null
                }
            }
        }

        It 'returns the identity summary data' {
            $result = Get-SPSdkIdentitySummary -CertificationId 'cert-001' `
                -IdentitySummaryId 'is-001' -CorrelationID 'sdk-cert-003a'
            $result.Success     | Should -Be $true
            $result.Data.id     | Should -Be 'is-001'
            $result.Data.name   | Should -Be 'John Smith'
        }

        It 'calls the correct nested endpoint' {
            Get-SPSdkIdentitySummary -CertificationId 'cert-001' `
                -IdentitySummaryId 'is-001' -CorrelationID 'sdk-cert-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Method -eq 'GET' -and
                $Endpoint -eq '/certifications/cert-001/identity-summaries/is-001'
            }
        }
    }

    Context 'SDK-CERT-004: Get-SPSdkAccessSummaries lists access summaries by type' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'as-001'; name = 'Admin Role'; type = 'ROLE' },
                        [PSCustomObject]@{ id = 'as-002'; name = 'Reader Role'; type = 'ROLE' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns access summaries for the specified type' {
            $result = Get-SPSdkAccessSummaries -CertificationId 'cert-001' -Type 'ROLE' `
                -CorrelationID 'sdk-cert-004a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls the correct type-specific endpoint' {
            Get-SPSdkAccessSummaries -CertificationId 'cert-001' -Type 'ENTITLEMENT' `
                -CorrelationID 'sdk-cert-004b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Method -eq 'GET' -and
                $Endpoint -eq '/certifications/cert-001/access-summaries/ENTITLEMENT'
            }
        }

        It 'accepts ACCESS_PROFILE as a valid type' {
            Get-SPSdkAccessSummaries -CertificationId 'cert-001' -Type 'ACCESS_PROFILE' `
                -CorrelationID 'sdk-cert-004c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Endpoint -eq '/certifications/cert-001/access-summaries/ACCESS_PROFILE'
            }
        }

        It 'passes limit and offset as query params' {
            Get-SPSdkAccessSummaries -CertificationId 'cert-001' -Type 'ROLE' `
                -Limit 25 -Offset 5 -CorrelationID 'sdk-cert-004d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['limit'] -eq '25' -and $QueryParams['offset'] -eq '5'
            }
        }
    }

    Context 'SDK-CERT-005: Get-SPSdkAllAccessSummaries auto-paginates access summaries' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'as-001'; name = 'Role 1' },
                        [PSCustomObject]@{ id = 'as-002'; name = 'Role 2' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns all paginated access summaries' {
            $result = Get-SPSdkAllAccessSummaries -CertificationId 'cert-001' -Type 'ROLE' `
                -CorrelationID 'sdk-cert-005a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls paginator with type-specific endpoint' {
            Get-SPSdkAllAccessSummaries -CertificationId 'cert-001' -Type 'ENTITLEMENT' `
                -CorrelationID 'sdk-cert-005b'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Endpoint -eq '/certifications/cert-001/access-summaries/ENTITLEMENT'
            }
        }

        It 'passes filters to the paginator' {
            Get-SPSdkAllAccessSummaries -CertificationId 'cert-001' -Type 'ROLE' `
                -Filters 'name co "admin"' -CorrelationID 'sdk-cert-005c'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['filters'] -eq 'name co "admin"'
            }
        }
    }

    Context 'SDK-CERT-006: Get-SPSdkDecisionSummary gets decision counts' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkCertSummaries { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        approvedCount      = 15
                        revokedCount       = 3
                        noDecisionCount    = 2
                        certificationCount = 20
                    }
                    Error   = $null
                }
            }
        }

        It 'returns decision summary data' {
            $result = Get-SPSdkDecisionSummary -CertificationId 'cert-001' -CorrelationID 'sdk-cert-006a'
            $result.Success              | Should -Be $true
            $result.Data.approvedCount   | Should -Be 15
            $result.Data.revokedCount    | Should -Be 3
        }

        It 'calls the correct decision-summary endpoint' {
            Get-SPSdkDecisionSummary -CertificationId 'cert-001' -CorrelationID 'sdk-cert-006b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $Method -eq 'GET' -and
                $Endpoint -eq '/certifications/cert-001/decision-summary'
            }
        }

        It 'passes filters as query params' {
            Get-SPSdkDecisionSummary -CertificationId 'cert-001' `
                -Filters 'completed eq true' -CorrelationID 'sdk-cert-006c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries -ParameterFilter {
                $QueryParams['filters'] -eq 'completed eq true'
            }
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkCertSummaries {
                return @{ Success = $false; Data = $null; Error = 'Forbidden' }
            }

            $result = Get-SPSdkDecisionSummary -CertificationId 'cert-001' -CorrelationID 'sdk-cert-006d'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}
