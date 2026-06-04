#Requires -Version 5.1
#Requires -Module Pester

<#
.SYNOPSIS
    Pester tests for SP.SdkApprovals module.
.DESCRIPTION
    Validates access request approval query and action functions.
    Covers pending/completed listing, summary, approve, deny, and forward.
    Test IDs: SDK-APPR-001 through SDK-APPR-008.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Sdk
}

Describe 'SP.SdkApprovals - Access Request Approval Management' {

    Context 'SDK-APPR-001: Get-SPSdkPendingApprovals lists pending approvals' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'appr-001'; status = 'PENDING' },
                        [PSCustomObject]@{ id = 'appr-002'; status = 'PENDING' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with pending approval list' {
            $result = Get-SPSdkPendingApprovals -CorrelationID 'sdk-appr-001a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Error      | Should -BeNullOrEmpty
        }

        It 'calls GET /access-request-approvals/pending' {
            Get-SPSdkPendingApprovals -CorrelationID 'sdk-appr-001b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/access-request-approvals/pending'
            }
        }

        It 'passes owner-id as query param' {
            Get-SPSdkPendingApprovals -OwnerId 'owner-abc' -CorrelationID 'sdk-appr-001c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $QueryParams['owner-id'] -eq 'owner-abc'
            }
        }

        It 'passes filters and sorters as query params' {
            Get-SPSdkPendingApprovals -Filters 'requestedFor.id eq "u1"' -Sorters 'created' `
                -CorrelationID 'sdk-appr-001d'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $QueryParams['filters'] -eq 'requestedFor.id eq "u1"' -and $QueryParams['sorters'] -eq 'created'
            }
        }

        It 'passes limit and offset as query params' {
            Get-SPSdkPendingApprovals -Limit 50 -Offset 10 -CorrelationID 'sdk-appr-001e'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $QueryParams['limit'] -eq '50' -and $QueryParams['offset'] -eq '10'
            }
        }
    }

    Context 'SDK-APPR-002: Get-SPSdkAllPendingApprovals auto-paginates' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPSdkPaginatedGet -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'appr-001' },
                        [PSCustomObject]@{ id = 'appr-002' },
                        [PSCustomObject]@{ id = 'appr-003' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns all paginated pending approvals' {
            $result = Get-SPSdkAllPendingApprovals -CorrelationID 'sdk-appr-002a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 3
        }

        It 'calls paginator with correct endpoint' {
            Get-SPSdkAllPendingApprovals -CorrelationID 'sdk-appr-002b'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkApprovals -ParameterFilter {
                $Endpoint -eq '/access-request-approvals/pending'
            }
        }

        It 'passes owner-id to paginator query params' {
            Get-SPSdkAllPendingApprovals -OwnerId 'owner-xyz' -CorrelationID 'sdk-appr-002c'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkApprovals -ParameterFilter {
                $QueryParams['owner-id'] -eq 'owner-xyz'
            }
        }
    }

    Context 'SDK-APPR-003: Get-SPSdkCompletedApprovals lists completed approvals' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'appr-c01'; status = 'APPROVED' },
                        [PSCustomObject]@{ id = 'appr-c02'; status = 'REJECTED' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns Success=true with completed approval list' {
            $result = Get-SPSdkCompletedApprovals -CorrelationID 'sdk-appr-003a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls GET /access-request-approvals/completed' {
            Get-SPSdkCompletedApprovals -CorrelationID 'sdk-appr-003b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/access-request-approvals/completed'
            }
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{ Success = $false; Data = $null; Error = 'Service unavailable' }
            }

            $result = Get-SPSdkCompletedApprovals -CorrelationID 'sdk-appr-003c'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SDK-APPR-004: Get-SPSdkAllCompletedApprovals auto-paginates' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPSdkPaginatedGet -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'appr-c01' },
                        [PSCustomObject]@{ id = 'appr-c02' }
                    )
                    Error   = $null
                }
            }
        }

        It 'returns all paginated completed approvals' {
            $result = Get-SPSdkAllCompletedApprovals -CorrelationID 'sdk-appr-004a'
            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It 'calls paginator with correct endpoint' {
            Get-SPSdkAllCompletedApprovals -CorrelationID 'sdk-appr-004b'

            Should -Invoke Invoke-SPSdkPaginatedGet -ModuleName SP.SdkApprovals -ParameterFilter {
                $Endpoint -eq '/access-request-approvals/completed'
            }
        }
    }

    Context 'SDK-APPR-005: Get-SPSdkApprovalSummary gets summary counts' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{
                        pending  = 5
                        approved = 42
                        rejected = 3
                    }
                    Error   = $null
                }
            }
        }

        It 'returns approval summary data' {
            $result = Get-SPSdkApprovalSummary -CorrelationID 'sdk-appr-005a'
            $result.Success        | Should -Be $true
            $result.Data.pending   | Should -Be 5
            $result.Data.approved  | Should -Be 42
            $result.Data.rejected  | Should -Be 3
        }

        It 'calls GET /access-request-approvals/approval-summary' {
            Get-SPSdkApprovalSummary -CorrelationID 'sdk-appr-005b'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/access-request-approvals/approval-summary'
            }
        }

        It 'passes owner-id and from-date as query params' {
            Get-SPSdkApprovalSummary -OwnerId 'owner-1' -FromDate '2026-01-01T00:00:00Z' `
                -CorrelationID 'sdk-appr-005c'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $QueryParams['owner-id'] -eq 'owner-1' -and $QueryParams['from-date'] -eq '2026-01-01T00:00:00Z'
            }
        }
    }

    Context 'SDK-APPR-006: Approve-SPSdkAccessRequest approves a pending request' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'appr-001'; status = 'APPROVED' }
                    Error   = $null
                }
            }
        }

        It 'calls POST /access-request-approvals/{id}/approve' {
            Approve-SPSdkAccessRequest -ApprovalId 'appr-001' -CorrelationID 'sdk-appr-006a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/access-request-approvals/appr-001/approve'
            }
        }

        It 'includes comment in request body when provided' {
            Approve-SPSdkAccessRequest -ApprovalId 'appr-001' -Comment 'Looks good' `
                -CorrelationID 'sdk-appr-006b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Body.comment -eq 'Looks good'
            }
        }

        It 'sends null body when no comment is provided' {
            Approve-SPSdkAccessRequest -ApprovalId 'appr-001' -CorrelationID 'sdk-appr-006c' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $null -eq $Body
            }
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Approve-SPSdkAccessRequest -ApprovalId 'appr-001' -WhatIf -CorrelationID 'sdk-appr-006d'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -Times 0 -Exactly
        }
    }

    Context 'SDK-APPR-007: Deny-SPSdkAccessRequest rejects a pending request' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'appr-001'; status = 'REJECTED' }
                    Error   = $null
                }
            }
        }

        It 'calls POST /access-request-approvals/{id}/reject' {
            Deny-SPSdkAccessRequest -ApprovalId 'appr-001' -Comment 'Access not justified' `
                -CorrelationID 'sdk-appr-007a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/access-request-approvals/appr-001/reject'
            }
        }

        It 'includes mandatory comment in request body' {
            Deny-SPSdkAccessRequest -ApprovalId 'appr-001' -Comment 'Policy violation' `
                -CorrelationID 'sdk-appr-007b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Body.comment -eq 'Policy violation'
            }
        }

        It 'returns Success=true with rejected approval data' {
            $result = Deny-SPSdkAccessRequest -ApprovalId 'appr-001' -Comment 'Rejected' `
                -CorrelationID 'sdk-appr-007c' -Confirm:$false
            $result.Success     | Should -Be $true
            $result.Data.status | Should -Be 'REJECTED'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Deny-SPSdkAccessRequest -ApprovalId 'appr-001' -Comment 'Test' `
                -WhatIf -CorrelationID 'sdk-appr-007d'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -Times 0 -Exactly
        }
    }

    Context 'SDK-APPR-008: Forward-SPSdkAccessRequest forwards to new owner' {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.SdkApprovals { }
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{
                    Success = $true
                    Data    = [PSCustomObject]@{ id = 'appr-001'; status = 'FORWARDED' }
                    Error   = $null
                }
            }
        }

        It 'calls POST /access-request-approvals/{id}/forward' {
            Forward-SPSdkAccessRequest -ApprovalId 'appr-001' -NewOwnerId 'owner-new' `
                -Comment 'Reassigning to backup' -CorrelationID 'sdk-appr-008a' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Method -eq 'POST' -and $Endpoint -eq '/access-request-approvals/appr-001/forward'
            }
        }

        It 'includes newOwnerId and comment in request body' {
            Forward-SPSdkAccessRequest -ApprovalId 'appr-001' -NewOwnerId 'owner-backup' `
                -Comment 'OOO reassignment' -CorrelationID 'sdk-appr-008b' -Confirm:$false

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -ParameterFilter {
                $Body.newOwnerId -eq 'owner-backup' -and $Body.comment -eq 'OOO reassignment'
            }
        }

        It 'returns Success=true with forwarded data' {
            $result = Forward-SPSdkAccessRequest -ApprovalId 'appr-001' -NewOwnerId 'owner-new' `
                -Comment 'Forwarding' -CorrelationID 'sdk-appr-008c' -Confirm:$false
            $result.Success     | Should -Be $true
            $result.Data.status | Should -Be 'FORWARDED'
        }

        It 'respects ShouldProcess (WhatIf skips API call)' {
            $result = Forward-SPSdkAccessRequest -ApprovalId 'appr-001' -NewOwnerId 'owner-new' `
                -Comment 'Test' -WhatIf -CorrelationID 'sdk-appr-008d'
            $result.Error | Should -Be 'Skipped (WhatIf)'
            Should -Invoke Invoke-SPApiRequest -ModuleName SP.SdkApprovals -Times 0 -Exactly
        }

        It 'returns Success=false on API failure' {
            Mock Invoke-SPApiRequest -ModuleName SP.SdkApprovals {
                return @{ Success = $false; Data = $null; Error = 'Target owner not found' }
            }

            $result = Forward-SPSdkAccessRequest -ApprovalId 'appr-001' -NewOwnerId 'bad-owner' `
                -Comment 'Forward' -CorrelationID 'sdk-appr-008e' -Confirm:$false
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}
