#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.AccessGovernance module
.DESCRIPTION
    Tests: AG-001 through AG-009
    Covers:
        AG-001: New-SPAccessProfile  -- POST body shape (source, owner, entitlements, requestable)
        AG-002: New-SPAccessProfile  -- -WhatIf suppresses the API call
        AG-003: Get-SPAccessProfiles -- name / prefix / source filter syntax and pagination
        AG-004: New-SPRole           -- criteria shipped verbatim under membership
        AG-005: New-SPRole           -- nested OR criteria (leadership titles) survive intact
        AG-006: New-SPRole           -- -WhatIf suppresses the API call
        AG-007: New-SPTransform      -- POST body shape for a lookup chain
        AG-008: Set-SPTransform      -- PUT to /v3/transforms/{id} with a full replacement body
        AG-009: Get-SPTransforms     -- exact-name filter and list retrieval

    No saved-search tests: Step 7 of the B2B setup reuses New-SPCampaign -Type SEARCH
    with an inline filter, so no saved search object is created by this module.

    Note on mock-scoping:
        Import-SPTestModules imports each .psm1 flat (top-level), so Invoke-SPApiRequest
        is mocked with -ModuleName SP.AccessGovernance -- the module whose scope contains
        the call site. This is the Bug-1 flat-import rule and passes on both PS 5.1 and PS7.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api

    # Minimal mock config consumed by the pagination-ceiling helper
    function New-MockAccessGovConfig {
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

    # Baseline B2B role criteria: Guest AND email contains the partner domain
    function New-MockBaselineCriteria {
        param([string]$Domain = 'partnera.com')
        return @{
            operation = 'AND'
            children  = @(
                @{
                    operation = 'EQUALS'
                    key       = @{ type = 'IDENTITY'; property = 'attribute.userType' }
                    value     = 'Guest'
                }
                @{
                    operation = 'CONTAINS'
                    key       = @{ type = 'IDENTITY'; property = 'attribute.email' }
                    value     = $Domain
                }
            )
        }
    }
}

Describe "AG-001: New-SPAccessProfile constructs the correct POST body" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        $script:AgCapturedBody = $null
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            $script:AgCapturedBody = $Body
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{ id = 'ap-001'; name = 'B2B PartnerA - Users Access' }
                Error      = $null
            }
        }
    }

    It "Should POST to /v3/access-profiles and return the created profile" {
        $result = New-SPAccessProfile -Name 'B2B PartnerA - Users Access' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-users' -CorrelationID 'ag-cid-001a'

        $result.Success | Should -Be $true
        $result.Data.id | Should -Be 'ap-001'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/v3/access-profiles'
        }
    }

    It "Should carry the source, owner, and entitlement references" {
        New-SPAccessProfile -Name 'B2B PartnerA - Users Access' `
            -SourceId 'src-entra-001' -SourceName 'Entra ID - CORP' `
            -OwnerIdentityId 'ident-iam-admin' -EntitlementId 'ent-users' `
            -CorrelationID 'ag-cid-001b'

        $script:AgCapturedBody.name                 | Should -Be 'B2B PartnerA - Users Access'
        $script:AgCapturedBody.source.id            | Should -Be 'src-entra-001'
        $script:AgCapturedBody.source.type          | Should -Be 'SOURCE'
        $script:AgCapturedBody.source.name          | Should -Be 'Entra ID - CORP'
        $script:AgCapturedBody.owner.id             | Should -Be 'ident-iam-admin'
        $script:AgCapturedBody.owner.type           | Should -Be 'IDENTITY'
        $script:AgCapturedBody.entitlements.Count   | Should -Be 1
        $script:AgCapturedBody.entitlements[0].id   | Should -Be 'ent-users'
        $script:AgCapturedBody.entitlements[0].type | Should -Be 'ENTITLEMENT'
    }

    It "Should default requestable=false and enabled=true for baseline access" {
        New-SPAccessProfile -Name 'B2B PartnerA - Users Access' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-users' -CorrelationID 'ag-cid-001c'

        $script:AgCapturedBody.requestable | Should -Be $false
        $script:AgCapturedBody.enabled     | Should -Be $true
    }

    It "Should set requestable=true for a tier 2 profile" {
        New-SPAccessProfile -Name 'B2B PartnerA - SvcNow-Admin Access' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-svcnow-admin' -Requestable -CorrelationID 'ag-cid-001d'

        $script:AgCapturedBody.requestable | Should -Be $true
    }

    It "Should bundle multiple entitlements when supplied" {
        New-SPAccessProfile -Name 'B2B PartnerA - Combined' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-a', 'ent-b' -CorrelationID 'ag-cid-001e'

        $script:AgCapturedBody.entitlements.Count | Should -Be 2
    }
}

Describe "AG-002: New-SPAccessProfile respects -WhatIf" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance { }
    }

    It "Should not call the API and should report the skip" {
        $result = New-SPAccessProfile -Name 'B2B PartnerA - Users Access' `
            -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
            -EntitlementId 'ent-users' -CorrelationID 'ag-cid-002a' -WhatIf

        $result.Success | Should -Be $true
        $result.Data    | Should -BeNullOrEmpty
        $result.Error   | Should -Match 'WhatIf'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -Times 0 -Exactly
    }
}

Describe "AG-003: Get-SPAccessProfiles applies filters" {
    BeforeEach {
        Mock Write-SPLog  -ModuleName SP.AccessGovernance { }
        Mock Get-SPConfig -ModuleName SP.AccessGovernance { New-MockAccessGovConfig }
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            return @{ Success = $true; StatusCode = 200; Data = [PSCustomObject]@{ items = @() }; Error = $null }
        }
    }

    It "Should use 'name eq' for the idempotency lookup" {
        Get-SPAccessProfiles -Name 'B2B PartnerA - Users Access' -CorrelationID 'ag-cid-003a'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Endpoint -eq '/v3/access-profiles' -and
            $QueryParams['filters'] -eq 'name eq "B2B PartnerA - Users Access"'
        }
    }

    It "Should combine 'name sw' with 'source.id eq'" {
        Get-SPAccessProfiles -NamePrefix 'B2B PartnerA' -SourceId 'src-entra-001' `
            -CorrelationID 'ag-cid-003b'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $QueryParams['filters'] -eq 'name sw "B2B PartnerA" and source.id eq "src-entra-001"'
        }
    }

    It "Should omit the filters parameter when no filter is supplied" {
        Get-SPAccessProfiles -CorrelationID 'ag-cid-003c'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            -not $QueryParams.ContainsKey('filters')
        }
    }

    It "Should return an empty array when nothing matches" {
        $result = Get-SPAccessProfiles -Name 'Does Not Exist' -CorrelationID 'ag-cid-003d'

        $result.Success    | Should -Be $true
        $result.Data.Count | Should -Be 0
    }
}

Describe "AG-004: New-SPRole constructs criteria structure correctly" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        $script:AgCapturedBody = $null
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            $script:AgCapturedBody = $Body
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{ id = 'role-001'; name = 'B2B-PartnerA-User' }
                Error      = $null
            }
        }
    }

    It "Should POST to /v3/roles and return the created role" {
        $result = New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -Criteria (New-MockBaselineCriteria) `
            -CorrelationID 'ag-cid-004a'

        $result.Success | Should -Be $true
        $result.Data.id | Should -Be 'role-001'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/v3/roles'
        }
    }

    It "Should wrap the criteria under membership with type CRITERIA" {
        New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -Criteria (New-MockBaselineCriteria) `
            -CorrelationID 'ag-cid-004b'

        $script:AgCapturedBody.membership.type                 | Should -Be 'CRITERIA'
        $script:AgCapturedBody.membership.criteria.operation   | Should -Be 'AND'
        $script:AgCapturedBody.membership.criteria.children.Count | Should -Be 2
    }

    It "Should ship the criteria attribute property names verbatim" {
        New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -Criteria (New-MockBaselineCriteria -Domain 'partnera.com') `
            -CorrelationID 'ag-cid-004c'

        $children = $script:AgCapturedBody.membership.criteria.children
        $children[0].key.property | Should -Be 'attribute.userType'
        $children[0].value        | Should -Be 'Guest'
        $children[1].key.property | Should -Be 'attribute.email'
        $children[1].value        | Should -Be 'partnera.com'
    }

    It "Should not rewrite a non-default attribute property name" {
        $custom = @{
            operation = 'AND'
            children  = @(
                @{ operation = 'EQUALS'; key = @{ type = 'IDENTITY'; property = 'attribute.isc_userType' }; value = 'Guest' }
            )
        }
        New-SPRole -Name 'B2B-Custom-Attr' -OwnerIdentityId 'ident-iam-admin' `
            -Criteria $custom -CorrelationID 'ag-cid-004d'

        $script:AgCapturedBody.membership.criteria.children[0].key.property |
            Should -Be 'attribute.isc_userType'
    }

    It "Should link the access profiles by reference" {
        New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -Criteria (New-MockBaselineCriteria) `
            -CorrelationID 'ag-cid-004e'

        $script:AgCapturedBody.accessProfiles.Count   | Should -Be 1
        $script:AgCapturedBody.accessProfiles[0].id   | Should -Be 'ap-001'
        $script:AgCapturedBody.accessProfiles[0].type | Should -Be 'ACCESS_PROFILE'
    }

    It "Should omit the membership block entirely when no criteria are supplied" {
        New-SPRole -Name 'B2B-Manual-Role' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -CorrelationID 'ag-cid-004f'

        $script:AgCapturedBody.ContainsKey('membership') | Should -Be $false
    }
}

Describe "AG-005: New-SPRole with nested OR criteria (leadership titles)" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        $script:AgCapturedBody = $null
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            $script:AgCapturedBody = $Body
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{ id = 'role-lead-001'; name = 'B2B-PartnerA-Leadership' }
                Error      = $null
            }
        }
    }

    It "Should preserve the nested OR branch and all of its title children" {
        $criteria = @{
            operation = 'AND'
            children  = @(
                @{ operation = 'EQUALS'; key = @{ type = 'IDENTITY'; property = 'attribute.userType' }; value = 'Guest' }
                @{ operation = 'CONTAINS'; key = @{ type = 'IDENTITY'; property = 'attribute.email' }; value = 'partnera.com' }
                @{
                    operation = 'OR'
                    children  = @(
                        @{ operation = 'CONTAINS'; key = @{ type = 'IDENTITY'; property = 'attribute.jobTitle' }; value = 'Director' }
                        @{ operation = 'CONTAINS'; key = @{ type = 'IDENTITY'; property = 'attribute.jobTitle' }; value = 'VP' }
                        @{ operation = 'CONTAINS'; key = @{ type = 'IDENTITY'; property = 'attribute.jobTitle' }; value = 'Chief' }
                    )
                }
            )
        }

        New-SPRole -Name 'B2B-PartnerA-Leadership' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-lead-001' -Criteria $criteria -CorrelationID 'ag-cid-005a'

        $root = $script:AgCapturedBody.membership.criteria
        $root.operation          | Should -Be 'AND'
        $root.children.Count     | Should -Be 3

        $orBranch = $root.children[2]
        $orBranch.operation      | Should -Be 'OR'
        $orBranch.children.Count | Should -Be 3

        $titles = @($orBranch.children | ForEach-Object { $_.value })
        $titles | Should -Contain 'Director'
        $titles | Should -Contain 'VP'
        $titles | Should -Contain 'Chief'
    }
}

Describe "AG-006: New-SPRole respects -WhatIf" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance { }
    }

    It "Should not call the API and should report the skip" {
        $result = New-SPRole -Name 'B2B-PartnerA-User' -OwnerIdentityId 'ident-iam-admin' `
            -AccessProfileId 'ap-001' -Criteria (New-MockBaselineCriteria) `
            -CorrelationID 'ag-cid-006a' -WhatIf

        $result.Success | Should -Be $true
        $result.Error   | Should -Match 'WhatIf'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -Times 0 -Exactly
    }
}

Describe "AG-007: New-SPTransform constructs the correct payload" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        $script:AgCapturedBody = $null
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            $script:AgCapturedBody = $Body
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{ id = 'tf-001'; name = 'B2B Partner Group Resolver' }
                Error      = $null
            }
        }
    }

    It "Should POST to /v3/transforms with name, type, and attributes" {
        $attrs = @{
            input   = @{ type = 'lower'; attributes = @{ input = @{ type = 'split'; attributes = @{ delimiter = '@'; index = 1 } } } }
            table   = @{ 'partnera.com' = 'CLD-B2B-PartnerA-Users' }
            default = 'CLD-B2B-Unknown-Review'
        }

        $result = New-SPTransform -Name 'B2B Partner Group Resolver' -Type 'lookup' `
            -Attributes $attrs -CorrelationID 'ag-cid-007a'

        $result.Success | Should -Be $true
        $result.Data.id | Should -Be 'tf-001'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/v3/transforms'
        }

        $script:AgCapturedBody.name                 | Should -Be 'B2B Partner Group Resolver'
        $script:AgCapturedBody.type                 | Should -Be 'lookup'
        $script:AgCapturedBody.attributes.default   | Should -Be 'CLD-B2B-Unknown-Review'
        $script:AgCapturedBody.attributes.table['partnera.com'] | Should -Be 'CLD-B2B-PartnerA-Users'
    }

    It "Should ship the attributes block verbatim, preserving the split chain" {
        $attrs = @{
            input = @{
                type       = 'lower'
                attributes = @{
                    input = @{ type = 'split'; attributes = @{ delimiter = '@'; index = 1 } }
                }
            }
            table   = @{}
            default = 'CLD-B2B-Unknown-Review'
        }

        New-SPTransform -Name 'B2B Partner Group Resolver' -Type 'lookup' `
            -Attributes $attrs -CorrelationID 'ag-cid-007b'

        $script:AgCapturedBody.attributes.input.type                       | Should -Be 'lower'
        $script:AgCapturedBody.attributes.input.attributes.input.type      | Should -Be 'split'
        $script:AgCapturedBody.attributes.input.attributes.input.attributes.delimiter | Should -Be '@'
        $script:AgCapturedBody.attributes.input.attributes.input.attributes.index     | Should -Be 1
    }

    It "Should respect -WhatIf" {
        New-SPTransform -Name 'B2B Partner Group Resolver' -Type 'lookup' `
            -Attributes @{ table = @{} } -CorrelationID 'ag-cid-007c' -WhatIf

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -Times 0 -Exactly
    }
}

Describe "AG-008: Set-SPTransform updates an existing transform" {
    BeforeEach {
        Mock Write-SPLog -ModuleName SP.AccessGovernance { }
        $script:AgCapturedBody = $null
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            $script:AgCapturedBody = $Body
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{ id = 'tf-001'; name = 'B2B Partner Group Resolver' }
                Error      = $null
            }
        }
    }

    It "Should PUT to /v3/transforms/{id} with the full replacement body" {
        $attrs = @{
            table   = @{ 'partnera.com' = 'CLD-B2B-PartnerA-Users'; 'partnerb.com' = 'CLD-B2B-PartnerB-Users' }
            default = 'CLD-B2B-Unknown-Review'
        }

        $result = Set-SPTransform -TransformId 'tf-001' -Name 'B2B Partner Group Resolver' `
            -Type 'lookup' -Attributes $attrs -CorrelationID 'ag-cid-008a'

        $result.Success | Should -Be $true

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -eq '/v3/transforms/tf-001'
        }

        $script:AgCapturedBody.attributes.table.Count | Should -Be 2
    }

    It "Should respect -WhatIf" {
        Set-SPTransform -TransformId 'tf-001' -Name 'B2B Partner Group Resolver' `
            -Type 'lookup' -Attributes @{ table = @{} } -CorrelationID 'ag-cid-008b' -WhatIf

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -Times 0 -Exactly
    }

    It "Should return Success=false when the API rejects the update" {
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            return @{ Success = $false; Data = $null; StatusCode = 400; Error = 'Invalid transform definition' }
        }

        $result = Set-SPTransform -TransformId 'tf-001' -Name 'B2B Partner Group Resolver' `
            -Type 'lookup' -Attributes @{ table = @{} } -CorrelationID 'ag-cid-008c'

        $result.Success | Should -Be $false
        $result.Error   | Should -Match 'Invalid transform definition'
    }
}

Describe "AG-009: Get-SPTransforms returns the transform list" {
    BeforeEach {
        Mock Write-SPLog  -ModuleName SP.AccessGovernance { }
        Mock Get-SPConfig -ModuleName SP.AccessGovernance { New-MockAccessGovConfig }
        Mock Invoke-SPApiRequest -ModuleName SP.AccessGovernance {
            return @{
                Success    = $true
                StatusCode = 200
                Data       = [PSCustomObject]@{
                    items = @(
                        [PSCustomObject]@{ id = 'tf-001'; name = 'B2B Partner Group Resolver'; type = 'lookup' }
                    )
                }
                Error = $null
            }
        }
    }

    It "Should GET /v3/transforms with an exact-name filter" {
        $result = Get-SPTransforms -Name 'B2B Partner Group Resolver' -CorrelationID 'ag-cid-009a'

        $result.Success      | Should -Be $true
        $result.Data.Count   | Should -Be 1
        $result.Data[0].id   | Should -Be 'tf-001'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/v3/transforms' -and
            $QueryParams['filters'] -eq 'name eq "B2B Partner Group Resolver"'
        }
    }

    It "Should omit the filters parameter when no name is supplied" {
        Get-SPTransforms -CorrelationID 'ag-cid-009b'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.AccessGovernance -ParameterFilter {
            -not $QueryParams.ContainsKey('filters')
        }
    }
}
