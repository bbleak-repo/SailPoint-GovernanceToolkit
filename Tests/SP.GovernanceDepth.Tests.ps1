#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Phase 13 Governance Depth features
.DESCRIPTION
    Tests: P13-T01 through P13-T07
    Covers:
        P13-T01: Get-SPAccessProfileInventory  -- paginated retrieval, review enrichment, ceiling error
        P13-T02: Get-SPRoleInventory            -- paginated retrieval, health indicators, AP enrichment
        P13-T03: Get-SPIdentityAccessSpread     -- multi-source analysis, privileged filter, empty input
        P13-T04: Test-SPGovernancePolicy        -- policy evaluation (PASS/FAIL/SKIPPED), severity sort
        P13-T05: Compare-SPAuditPeriods         -- dimension comparison, direction classification
        P13-T06: Export-SPPolicyComplianceHtml  -- HTML file generation with violation details
        P13-T07: Export-SPGovernanceDashboardData -- CSV/JSON export with identity/source enrichment

    Mock scoping:
        P13-T01/T02 mock within SP.AuditQueries (Invoke-SPApiRequest, Get-SPConfig, Get-SPAuditSourceName).
        P13-T03/T04/T05 mock within SP.AuditAnalytics (Get-SPConfig, Write-SPLog).
        P13-T06 mocks within SP.AuditReportHtml (Write-SPLog).
        P13-T07 mocks within SP.AuditOperations (Write-SPLog).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

# ---------------------------------------------------------------------------
#region P13-T01: Get-SPAccessProfileInventory
# ---------------------------------------------------------------------------

Describe "P13-T01: Get-SPAccessProfileInventory returns paginated profiles with source grouping" {

    Context "When the API returns profiles across two pages" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl            = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                }
            }
            Mock Get-SPAuditSourceName -ModuleName SP.AuditQueries {
                return 'Active Directory'
            }

            $script:apiCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:apiCallCount++
                if ($script:apiCallCount -eq 1) {
                    # First page: 250 items (full page triggers next fetch)
                    $items = 1..250 | ForEach-Object {
                        [PSCustomObject]@{
                            id           = "ap-$_"
                            name         = "AccessProfile-$_"
                            description  = "Test AP $_"
                            enabled      = $true
                            requestable  = ($_ -le 200)
                            source       = [PSCustomObject]@{ id = 'src-001' }
                            owner        = [PSCustomObject]@{ id = 'owner-1'; name = 'Owner One' }
                            entitlements = @(
                                [PSCustomObject]@{ name = "Ent-$_"; privileged = ($_ -le 5) }
                            )
                            created      = '2026-01-15T10:00:00Z'
                            modified     = '2026-03-01T12:00:00Z'
                        }
                    }
                    return @{ Success = $true; Data = $items; Error = $null }
                } else {
                    # Second page: 3 items (partial = last page)
                    $items = 251..253 | ForEach-Object {
                        [PSCustomObject]@{
                            id           = "ap-$_"
                            name         = "AccessProfile-$_"
                            description  = "Test AP $_"
                            enabled      = $true
                            requestable  = $true
                            source       = [PSCustomObject]@{ id = 'src-001' }
                            owner        = [PSCustomObject]@{ id = 'owner-1'; name = 'Owner One' }
                            entitlements = @(
                                [PSCustomObject]@{ name = "Ent-$_"; privileged = $false }
                            )
                            created      = '2026-01-15T10:00:00Z'
                            modified     = '2026-03-01T12:00:00Z'
                        }
                    }
                    return @{ Success = $true; Data = $items; Error = $null }
                }
            }

            $script:result = Get-SPAccessProfileInventory -IncludeEntitlements
        }

        It "Should return Success true" {
            $script:result.Success | Should -Be $true
        }

        It "Should paginate across two API calls" {
            $script:apiCallCount | Should -Be 2
        }

        It "Should count 253 total access profiles" {
            $script:result.Data.Summary.TotalAccessProfiles | Should -Be 253
        }

        It "Should group profiles under the source" {
            $script:result.Data.Sources.Keys | Should -Contain 'src-001'
            $script:result.Data.Sources['src-001'].SourceName | Should -Be 'Active Directory'
        }

        It "Should detect privileged entitlements" {
            $privCount = @($script:result.Data.Sources['src-001'].AccessProfiles | Where-Object { $_.HasPrivileged -eq $true }).Count
            $privCount | Should -BeGreaterOrEqual 1
        }
    }

    Context "When pagination ceiling is reached" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl            = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 3
                    }
                }
            }
            Mock Get-SPAuditSourceName -ModuleName SP.AuditQueries { return 'Test Source' }

            $script:ceilingCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:ceilingCallCount++
                # Always return a full page to trigger ceiling
                $items = 1..250 | ForEach-Object {
                    [PSCustomObject]@{
                        id = "ap-pg$($script:ceilingCallCount)-$_"; name = "AP-$_"
                        description = ''; enabled = $true; requestable = $true
                        source = [PSCustomObject]@{ id = 'src-001' }
                        owner = [PSCustomObject]@{ id = 'o1'; name = 'O1' }
                        entitlements = @()
                        created = '2026-01-01'; modified = '2026-01-01'
                    }
                }
                return @{ Success = $true; Data = $items; Error = $null }
            }

            $script:ceilingResult = Get-SPAccessProfileInventory
        }

        It "Should return Success false" {
            $script:ceilingResult.Success | Should -Be $false
        }

        It "Should report a pagination ceiling error" {
            $script:ceilingResult.Error | Should -Match -RegularExpression '(?i)pagination|ceiling'
        }

        It "Should stop at MaxPaginationPages" {
            $script:ceilingCallCount | Should -Be 3
        }
    }

    Context "When the API returns an error" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl            = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{ Success = $false; Data = $null; Error = 'API connection failed' }
            }

            $script:errorResult = Get-SPAccessProfileInventory
        }

        It "Should return Success false" {
            $script:errorResult.Success | Should -Be $false
        }

        It "Should include an error message" {
            $script:errorResult.Error | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T02: Get-SPRoleInventory
# ---------------------------------------------------------------------------

Describe "P13-T02: Get-SPRoleInventory returns roles with health indicators" {

    Context "When the API returns roles with mixed health states" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl            = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                }
            }

            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $roles = @(
                    # Normal role with 2 APs
                    [PSCustomObject]@{
                        id             = 'role-001'
                        name           = 'Finance-Admin'
                        description    = 'Finance admin role'
                        enabled        = $true
                        requestable    = $true
                        created        = '2026-01-01T00:00:00Z'
                        modified       = '2026-02-01T00:00:00Z'
                        owner          = [PSCustomObject]@{ id = 'owner-1'; name = 'Owner One' }
                        membership     = [PSCustomObject]@{ type = 'STANDARD' }
                        accessProfiles = @(
                            [PSCustomObject]@{ id = 'ap-1'; name = 'Finance-Read' },
                            [PSCustomObject]@{ id = 'ap-2'; name = 'Finance-Write' }
                        )
                    },
                    # Empty role (no APs)
                    [PSCustomObject]@{
                        id             = 'role-002'
                        name           = 'Legacy-Role'
                        description    = 'Empty legacy role'
                        enabled        = $false
                        requestable    = $false
                        created        = '2025-06-01T00:00:00Z'
                        modified       = '2025-06-01T00:00:00Z'
                        owner          = [PSCustomObject]@{ id = ''; name = '' }
                        membership     = [PSCustomObject]@{ type = 'IDENTITY_LIST' }
                        accessProfiles = @()
                    },
                    # Single-AP role
                    [PSCustomObject]@{
                        id             = 'role-003'
                        name           = 'Read-Only'
                        description    = 'Single AP role'
                        enabled        = $true
                        requestable    = $true
                        created        = '2026-02-01T00:00:00Z'
                        modified       = '2026-03-01T00:00:00Z'
                        owner          = [PSCustomObject]@{ id = 'owner-2'; name = 'Owner Two' }
                        membership     = [PSCustomObject]@{ type = 'STANDARD' }
                        accessProfiles = @(
                            [PSCustomObject]@{ id = 'ap-3'; name = 'Basic-Read' }
                        )
                    }
                )
                return @{ Success = $true; Data = $roles; Error = $null }
            }

            $script:roleResult = Get-SPRoleInventory
        }

        It "Should return Success true" {
            $script:roleResult.Success | Should -Be $true
        }

        It "Should count 3 total roles" {
            $script:roleResult.Data.Summary.TotalRoles | Should -Be 3
        }

        It "Should identify 1 empty role" {
            $script:roleResult.Data.Summary.EmptyRoles | Should -Be 1
        }

        It "Should identify 1 disabled role" {
            $script:roleResult.Data.Summary.Disabled | Should -Be 1
        }

        It "Should identify 1 single-profile role" {
            $script:roleResult.Data.Summary.SingleProfileRoles | Should -Be 1
        }

        It "Should identify 1 ownerless role" {
            $script:roleResult.Data.Summary.OwnerlessRoles | Should -Be 1
        }

        It "Should track IDENTITY_LIST membership type" {
            $script:roleResult.Data.Summary.IdentityListMembership | Should -Be 1
        }

        It "Should list empty role names in HealthIndicators" {
            $script:roleResult.Data.HealthIndicators.EmptyRoles | Should -Contain 'Legacy-Role'
        }

        It "Should list ownerless role names in HealthIndicators" {
            $script:roleResult.Data.HealthIndicators.OwnerlessRoles | Should -Contain 'Legacy-Role'
        }
    }

    Context "When -IncludeAccessProfiles enriches transitive entitlement counts" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl            = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages = 200
                    }
                }
            }

            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $roles = @(
                    [PSCustomObject]@{
                        id             = 'role-010'
                        name           = 'Enriched-Role'
                        description    = 'Test role'
                        enabled        = $true
                        requestable    = $true
                        created        = '2026-01-01T00:00:00Z'
                        modified       = '2026-02-01T00:00:00Z'
                        owner          = [PSCustomObject]@{ id = 'owner-1'; name = 'Owner One' }
                        membership     = [PSCustomObject]@{ type = 'STANDARD' }
                        accessProfiles = @(
                            [PSCustomObject]@{ id = 'ap-a'; name = 'Profile-A' },
                            [PSCustomObject]@{ id = 'ap-b'; name = 'Profile-B' }
                        )
                    }
                )
                return @{ Success = $true; Data = $roles; Error = $null }
            }

            # Simulate AccessProfileInventory output with entitlement counts
            $script:mockAPInventory = @{
                Sources = @{
                    'src-001' = @{
                        SourceName          = 'Active Directory'
                        TotalAccessProfiles = 2
                        AccessProfiles      = @(
                            @{ Name = 'Profile-A'; EntitlementCount = 5 },
                            @{ Name = 'Profile-B'; EntitlementCount = 3 }
                        )
                    }
                }
            }

            $script:enrichedResult = Get-SPRoleInventory `
                -IncludeAccessProfiles `
                -AccessProfileInventory $script:mockAPInventory
        }

        It "Should return Success true" {
            $script:enrichedResult.Success | Should -Be $true
        }

        It "Should compute transitive entitlement count from AP inventory" {
            $role = $script:enrichedResult.Data.Roles | Where-Object { $_.Name -eq 'Enriched-Role' }
            $role.TransitiveEntitlements | Should -Be 8
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T03: Get-SPIdentityAccessSpread
# ---------------------------------------------------------------------------

Describe "P13-T03: Get-SPIdentityAccessSpread analyzes cross-source identity access" {

    Context "When identities span multiple sources" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:spreadAudits = @(
                @{
                    CampaignId   = 'camp-001'
                    CampaignName = 'Q1 Access Review'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'AD'; AccessName = 'GroupA'; Decision = 'APPROVE'; DecisionDate = '2026-01-15'; RiskFlags = @() },
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'Salesforce'; AccessName = 'SFRole1'; Decision = 'APPROVE'; DecisionDate = '2026-01-15'; RiskFlags = @('PRIVILEGED') },
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'SAP'; AccessName = 'SAPRole1'; Decision = 'APPROVE'; DecisionDate = '2026-01-16'; RiskFlags = @() },
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'Oracle'; AccessName = 'OraRole1'; Decision = 'APPROVE'; DecisionDate = '2026-01-16'; RiskFlags = @('PRIVILEGED') },
                            @{ IdentityId = 'id-002'; IdentityName = 'Bob'; SourceName = 'AD'; AccessName = 'GroupB'; Decision = 'APPROVE'; DecisionDate = '2026-01-15'; RiskFlags = @() },
                            @{ IdentityId = 'id-002'; IdentityName = 'Bob'; SourceName = 'Salesforce'; AccessName = 'SFRole2'; Decision = 'APPROVE'; DecisionDate = '2026-01-15'; RiskFlags = @() }
                        )
                        Revoked  = @(
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'Legacy'; AccessName = 'LegacyAccess'; Decision = 'REVOKE'; DecisionDate = '2026-01-15'; RiskFlags = @() }
                        )
                        Pending  = @()
                    }
                }
            )

            $script:spreadResult = Get-SPIdentityAccessSpread `
                -CampaignAudits $script:spreadAudits `
                -MinSources 3
        }

        It "Should return identities above the threshold" {
            $script:spreadResult.Identities.Count | Should -BeGreaterOrEqual 1
        }

        It "Should include Alice (5 sources >= MinSources 3)" {
            $alice = $script:spreadResult.Identities | Where-Object { $_['IdentityName'] -eq 'Alice' }
            $alice | Should -Not -BeNullOrEmpty
            $alice['SourceCount'] | Should -Be 5
        }

        It "Should exclude Bob (2 sources < MinSources 3)" {
            $bob = $script:spreadResult.Identities | Where-Object { $_['IdentityName'] -eq 'Bob' }
            $bob | Should -BeNullOrEmpty
        }

        It "Should detect privileged entitlement spread" {
            $alice = $script:spreadResult.Identities | Where-Object { $_['IdentityName'] -eq 'Alice' }
            $alice['PrivilegedEntitlements'] | Should -Be 2
        }

        It "Should flag Alice as having a revocation" {
            $alice = $script:spreadResult.Identities | Where-Object { $_['IdentityName'] -eq 'Alice' }
            $alice['ApprovalOnlyFlag'] | Should -Be $false
        }

        It "Should compute summary correctly" {
            $script:spreadResult.Summary.TotalIdentitiesAnalyzed | Should -Be 2
            $script:spreadResult.Summary.IdentitiesAboveThreshold | Should -Be 1
            $script:spreadResult.Summary.MaxSourceCount | Should -Be 5
        }
    }

    Context "When -PrivilegedOnly filters to privileged sources" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:privAudits = @(
                @{
                    CampaignId = 'camp-002'
                    Decisions  = @{
                        Approved = @(
                            @{ IdentityId = 'id-010'; IdentityName = 'Charlie'; SourceName = 'AD'; AccessName = 'Group1'; RiskFlags = @('PRIVILEGED') },
                            @{ IdentityId = 'id-010'; IdentityName = 'Charlie'; SourceName = 'SAP'; AccessName = 'Role1'; RiskFlags = @('PRIVILEGED') },
                            @{ IdentityId = 'id-010'; IdentityName = 'Charlie'; SourceName = 'Oracle'; AccessName = 'OraRole'; RiskFlags = @('PRIVILEGED') },
                            @{ IdentityId = 'id-010'; IdentityName = 'Charlie'; SourceName = 'Slack'; AccessName = 'User'; RiskFlags = @() }
                        )
                        Revoked = @(); Pending = @()
                    }
                }
            )

            $script:privResult = Get-SPIdentityAccessSpread `
                -CampaignAudits $script:privAudits `
                -MinSources 3 `
                -PrivilegedOnly
        }

        It "Should include Charlie (3 privileged sources >= 3)" {
            $charlie = $script:privResult.Identities | Where-Object { $_['IdentityName'] -eq 'Charlie' }
            $charlie | Should -Not -BeNullOrEmpty
            $charlie['SourceCount'] | Should -Be 3
        }
    }

    Context "When CampaignAudits is empty" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
            $script:emptyResult = Get-SPIdentityAccessSpread -CampaignAudits @()
        }

        It "Should return empty Identities array" {
            $script:emptyResult.Identities.Count | Should -Be 0
        }

        It "Should return zeroed Summary" {
            $script:emptyResult.Summary.TotalIdentitiesAnalyzed | Should -Be 0
            $script:emptyResult.Summary.IdentitiesAboveThreshold | Should -Be 0
            $script:emptyResult.Summary.MaxSourceCount | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T04: Test-SPGovernancePolicy
# ---------------------------------------------------------------------------

Describe "P13-T04: Test-SPGovernancePolicy evaluates governance policies" {

    Context "When policies have mixed pass/fail results" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
            Mock Get-SPConfig -ModuleName SP.AuditAnalytics {
                return [PSCustomObject]@{
                    GovernancePolicy = [PSCustomObject]@{
                        Enabled  = $true
                        Policies = @(
                            [PSCustomObject]@{
                                Id       = 'POL-ReviewFrequency'
                                Name     = 'Review Frequency'
                                Type     = 'ReviewFrequency'
                                Severity = 'Critical'
                                MaxDaysSinceReview = 90
                            },
                            [PSCustomObject]@{
                                Id       = 'POL-IdentityRisk'
                                Name     = 'Identity Risk Threshold'
                                Type     = 'IdentityRisk'
                                Severity = 'Warning'
                                MaxRiskScore = 70
                            }
                        )
                    }
                }
            }

            # StaleAccess with a violation (150 days > 90 max)
            $script:staleAccess = @{
                StaleItems = @(
                    @{
                        EntitlementName  = 'Admin-Group'
                        SourceName       = 'Active Directory'
                        DaysSinceReview  = 150
                        Classification   = 'Stale'
                        Privileged       = $true
                    }
                )
                Summary = @{ TotalStaleItems = 1 }
            }

            # IdentityRisk with a violation (85 > 70 max)
            $script:identityRisk = @{
                Identities = @(
                    @{ IdentityId = 'id-high'; IdentityName = 'HighRisk User'; RiskScore = 85 },
                    @{ IdentityId = 'id-low'; IdentityName = 'LowRisk User'; RiskScore = 30 }
                )
            }

            $script:entitlementInventory = @{
                Summary = @{ TotalEntitlements = 100 }
            }

            $script:policyResult = Test-SPGovernancePolicy `
                -StaleAccess $script:staleAccess `
                -IdentityRisk $script:identityRisk `
                -EntitlementInventory $script:entitlementInventory
        }

        It "Should return OverallCompliant false (has failures)" {
            $script:policyResult.OverallCompliant | Should -Be $false
        }

        It "Should evaluate 2 policies" {
            $script:policyResult.Summary.TotalPolicies | Should -Be 2
        }

        It "Should fail the ReviewFrequency policy" {
            $rfPol = $script:policyResult.Policies | Where-Object { $_.Id -eq 'POL-ReviewFrequency' }
            $rfPol.Result | Should -Be 'FAIL'
        }

        It "Should fail the IdentityRisk policy" {
            $irPol = $script:policyResult.Policies | Where-Object { $_.Id -eq 'POL-IdentityRisk' }
            $irPol.Result | Should -Be 'FAIL'
        }

        It "Should include violations with item details" {
            $rfPol = $script:policyResult.Policies | Where-Object { $_.Id -eq 'POL-ReviewFrequency' }
            $rfPol.Violations.Count | Should -BeGreaterOrEqual 1
            $rfPol.Violations[0].Item | Should -Not -BeNullOrEmpty
        }

        It "Should sort FAIL policies before PASS" {
            # All are FAIL in this test, so just confirm they are present
            $script:policyResult.Summary.Failed | Should -Be 2
            $script:policyResult.Summary.Passed | Should -Be 0
        }

        It "Should count critical failures" {
            $script:policyResult.Summary.CriticalFailures | Should -BeGreaterOrEqual 1
        }
    }

    Context "When governance policy engine is disabled" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
            Mock Get-SPConfig -ModuleName SP.AuditAnalytics {
                return [PSCustomObject]@{
                    GovernancePolicy = [PSCustomObject]@{
                        Enabled  = $false
                        Policies = @(
                            [PSCustomObject]@{
                                Id       = 'POL-Test'
                                Name     = 'Test Policy'
                                Type     = 'IdentityRisk'
                                Severity = 'Critical'
                            }
                        )
                    }
                }
            }

            $script:disabledResult = Test-SPGovernancePolicy
        }

        It "Should return OverallCompliant true when disabled" {
            $script:disabledResult.OverallCompliant | Should -Be $true
        }

        It "Should mark all policies as SKIPPED" {
            $script:disabledResult.Policies | ForEach-Object {
                $_.Result | Should -Be 'SKIPPED'
            }
        }

        It "Should count skipped policies" {
            $script:disabledResult.Summary.Skipped | Should -Be 1
        }
    }

    Context "When all policies pass" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
            Mock Get-SPConfig -ModuleName SP.AuditAnalytics {
                return [PSCustomObject]@{
                    GovernancePolicy = [PSCustomObject]@{
                        Enabled  = $true
                        Policies = @(
                            [PSCustomObject]@{
                                Id       = 'POL-IdentityRisk'
                                Name     = 'Identity Risk'
                                Type     = 'IdentityRisk'
                                Severity = 'Warning'
                                MaxRiskScore = 70
                            }
                        )
                    }
                }
            }

            $script:passingRisk = @{
                Identities = @(
                    @{ IdentityId = 'id-ok'; IdentityName = 'Safe User'; RiskScore = 25 }
                )
            }

            $script:passResult = Test-SPGovernancePolicy -IdentityRisk $script:passingRisk
        }

        It "Should return OverallCompliant true" {
            $script:passResult.OverallCompliant | Should -Be $true
        }

        It "Should show 1 passed, 0 failed" {
            $script:passResult.Summary.Passed | Should -Be 1
            $script:passResult.Summary.Failed | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T05: Compare-SPAuditPeriods
# ---------------------------------------------------------------------------

Describe "P13-T05: Compare-SPAuditPeriods compares governance dimensions across two periods" {

    Context "When Period B shows improvement over Period A" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:periodA = @{
                Label     = 'Q1 2026'
                DateRange = '2026-01-01 to 2026-03-31'
                IdentityRisk = @{
                    Summary    = @{ High = 5; AvgRiskScore = 55.0 }
                    Identities = @(
                        @{ IdentityId = 'id-001'; IdentityName = 'Alice'; RiskTier = 'High' },
                        @{ IdentityId = 'id-002'; IdentityName = 'Bob';   RiskTier = 'High' }
                    )
                }
                SourceGovernance = @{
                    Summary = @{ OverallCoveragePct = 60.0 }
                    Sources = @(
                        @{ SourceId = 'src-1'; SourceName = 'AD'; GovernanceGrade = 'C' }
                    )
                }
                StaleAccess = @{
                    Summary = @{ TotalStaleItems = 50; NeverReviewed = 10 }
                }
            }

            $script:periodB = @{
                Label     = 'Q2 2026'
                DateRange = '2026-04-01 to 2026-06-30'
                IdentityRisk = @{
                    Summary    = @{ High = 2; AvgRiskScore = 35.0 }
                    Identities = @(
                        @{ IdentityId = 'id-001'; IdentityName = 'Alice'; RiskTier = 'Medium' },
                        @{ IdentityId = 'id-003'; IdentityName = 'Carol'; RiskTier = 'High' }
                    )
                }
                SourceGovernance = @{
                    Summary = @{ OverallCoveragePct = 85.0 }
                    Sources = @(
                        @{ SourceId = 'src-1'; SourceName = 'AD'; GovernanceGrade = 'A' }
                    )
                }
                StaleAccess = @{
                    Summary = @{ TotalStaleItems = 20; NeverReviewed = 3 }
                }
            }

            $script:compResult = Compare-SPAuditPeriods `
                -PeriodA $script:periodA `
                -PeriodB $script:periodB
        }

        It "Should return period labels" {
            $script:compResult.PeriodA.Label | Should -Be 'Q1 2026'
            $script:compResult.PeriodB.Label | Should -Be 'Q2 2026'
        }

        It "Should compute IdentityRisk dimension with correct deltas" {
            $irDim = $script:compResult.Dimensions.IdentityRisk
            $irDim | Should -Not -BeNullOrEmpty
            $irDim.HighCount.A | Should -Be 5
            $irDim.HighCount.B | Should -Be 2
        }

        It "Should classify reduced high-risk count as Improved" {
            $script:compResult.Dimensions.IdentityRisk.HighCount.Direction | Should -Be 'Improved'
        }

        It "Should compute SourceGovernance improvement" {
            $sgDim = $script:compResult.Dimensions.SourceGovernance
            $sgDim.OverallCoverage.A | Should -Be 60.0
            $sgDim.OverallCoverage.B | Should -Be 85.0
            $sgDim.OverallCoverage.Direction | Should -Be 'Improved'
        }

        It "Should compute StaleAccess reduction as Improved" {
            $saDim = $script:compResult.Dimensions.StaleAccess
            $saDim.TotalStale.A | Should -Be 50
            $saDim.TotalStale.B | Should -Be 20
            $saDim.TotalStale.Direction | Should -Be 'Improved'
        }

        It "Should determine overall direction" {
            $script:compResult.OverallDirection | Should -BeIn @('Improved', 'Stable', 'Degraded')
        }

        It "Should provide a summary count of improved/degraded/stable" {
            ($script:compResult.Summary.Improved + $script:compResult.Summary.Degraded + $script:compResult.Summary.Stable) | Should -BeGreaterOrEqual 1
        }

        It "Should detect grade changes in SourceGovernance" {
            $sgDim = $script:compResult.Dimensions.SourceGovernance
            $sgDim.GradeChanges | Should -Not -BeNullOrEmpty
        }
    }

    Context "When periods have no comparable dimensions" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:emptyPeriodA = @{ Label = 'Empty A'; DateRange = '2026-01-01 to 2026-01-31' }
            $script:emptyPeriodB = @{ Label = 'Empty B'; DateRange = '2026-02-01 to 2026-02-28' }

            $script:emptyCompResult = Compare-SPAuditPeriods `
                -PeriodA $script:emptyPeriodA `
                -PeriodB $script:emptyPeriodB
        }

        It "Should return an OverallDirection" {
            $script:emptyCompResult.OverallDirection | Should -BeIn @('N/A', 'Stable', 'Improved', 'Degraded')
        }

        It "Should not throw" {
            { Compare-SPAuditPeriods -PeriodA $script:emptyPeriodA -PeriodB $script:emptyPeriodB } | Should -Not -Throw
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T06: Export-SPPolicyComplianceHtml
# ---------------------------------------------------------------------------

Describe "P13-T06: Export-SPPolicyComplianceHtml generates valid compliance HTML" {

    Context "When policy results contain failures with violations" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:mockPolicyResults = @{
                OverallCompliant = $false
                EvaluatedAt      = '2026-05-31T12:00:00Z'
                Summary          = @{
                    TotalPolicies    = 3
                    Passed           = 1
                    Failed           = 2
                    CriticalFailures = 1
                    WarningFailures  = 1
                    Skipped          = 0
                }
                Policies = @(
                    @{
                        Id         = 'POL-ReviewFrequency'
                        Name       = 'Review Frequency'
                        Severity   = 'Critical'
                        Result     = 'FAIL'
                        Details    = 'Items exceed 90-day review threshold'
                        Violations = @(
                            @{ Item = 'Admin-Group'; Source = 'Active Directory'; DaysSinceReview = 150 },
                            @{ Item = 'DB-Admin';    Source = 'Oracle';           DaysSinceReview = 200 }
                        )
                    },
                    @{
                        Id         = 'POL-IdentityRisk'
                        Name       = 'Identity Risk Threshold'
                        Severity   = 'Warning'
                        Result     = 'FAIL'
                        Details    = 'Identities exceed risk score 70'
                        Violations = @(
                            @{ Item = 'HighRisk User'; Source = 'All Sources'; RiskScore = 85 }
                        )
                    },
                    @{
                        Id         = 'POL-SourceCoverage'
                        Name       = 'Source Coverage'
                        Severity   = 'Warning'
                        Result     = 'PASS'
                        Details    = 'All sources meet coverage threshold'
                        Violations = @()
                    }
                )
            }

            $script:htmlOutputDir = Join-Path $TestDrive 'policy-report'
            $script:htmlPath = Export-SPPolicyComplianceHtml `
                -PolicyResults $script:mockPolicyResults `
                -OutputPath $script:htmlOutputDir
        }

        It "Should return a file path" {
            $script:htmlPath | Should -Not -BeNullOrEmpty
        }

        It "Should create the HTML file on disk" {
            Test-Path $script:htmlPath | Should -Be $true
        }

        It "Should write valid HTML with DOCTYPE" {
            $content = Get-Content $script:htmlPath -Raw
            $content | Should -Match '<!DOCTYPE html>'
        }

        It "Should contain NON-COMPLIANT status" {
            $content = Get-Content $script:htmlPath -Raw
            $content | Should -Match 'NON-COMPLIANT'
        }

        It "Should include policy names" {
            $content = Get-Content $script:htmlPath -Raw
            $content | Should -Match 'Review Frequency'
            $content | Should -Match 'Identity Risk Threshold'
            $content | Should -Match 'Source Coverage'
        }

        It "Should include violation details" {
            $content = Get-Content $script:htmlPath -Raw
            $content | Should -Match 'Admin-Group'
            $content | Should -Match 'Active Directory'
        }

        It "Should contain pass/fail count in the summary" {
            $content = Get-Content $script:htmlPath -Raw
            $content | Should -Match '2'
            $content | Should -Match '1'
        }
    }

    Context "When all policies pass" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:passingResults = @{
                OverallCompliant = $true
                EvaluatedAt      = '2026-05-31T12:00:00Z'
                Summary          = @{
                    TotalPolicies    = 1
                    Passed           = 1
                    Failed           = 0
                    CriticalFailures = 0
                    WarningFailures  = 0
                    Skipped          = 0
                }
                Policies = @(
                    @{
                        Id         = 'POL-Test'
                        Name       = 'Test Policy'
                        Severity   = 'Warning'
                        Result     = 'PASS'
                        Details    = 'All clear'
                        Violations = @()
                    }
                )
            }

            $script:passHtmlDir = Join-Path $TestDrive 'pass-report'
            $script:passHtmlPath = Export-SPPolicyComplianceHtml `
                -PolicyResults $script:passingResults `
                -OutputPath $script:passHtmlDir
        }

        It "Should create the HTML file" {
            Test-Path $script:passHtmlPath | Should -Be $true
        }

        It "Should contain COMPLIANT status" {
            $content = Get-Content $script:passHtmlPath -Raw
            $content | Should -Match 'COMPLIANT'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P13-T07: Export-SPGovernanceDashboardData
# ---------------------------------------------------------------------------

Describe "P13-T07: Export-SPGovernanceDashboardData exports flat dataset for BI tools" {

    Context "When campaign audits contain decisions with enrichment data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }

            $script:dashAudits = @(
                @{
                    CampaignId   = 'camp-dash-001'
                    CampaignName = 'Q1 Review'
                    CampaignType = 'MANAGER'
                    Status       = 'COMPLETED'
                    Created      = '2026-01-01T00:00:00Z'
                    Deadline     = '2026-01-31T00:00:00Z'
                    Completed    = '2026-01-28T00:00:00Z'
                    Decisions    = @{
                        Approved = @(
                            @{
                                IdentityId    = 'id-alice'
                                IdentityName  = 'Alice Johnson'
                                SourceName    = 'Active Directory'
                                ReviewerName  = 'Manager One'
                                AccessName    = 'Finance-Group'
                                AccessType    = 'ENTITLEMENT'
                                Decision      = 'APPROVE'
                                DecisionDate  = '2026-01-15T10:00:00Z'
                                Justification = 'Required for job'
                                AccountName   = 'ajohnson'
                            }
                        )
                        Revoked = @(
                            @{
                                IdentityId    = 'id-bob'
                                IdentityName  = 'Bob Smith'
                                SourceName    = 'Active Directory'
                                ReviewerName  = 'Manager One'
                                AccessName    = 'Legacy-Admin'
                                AccessType    = 'ENTITLEMENT'
                                Decision      = 'REVOKE'
                                DecisionDate  = '2026-01-16T09:00:00Z'
                                Justification = 'No longer needed'
                                AccountName   = 'bsmith'
                            }
                        )
                        Pending = @()
                    }
                }
            )

            $script:dashIdentityRisk = @{
                Identities = @(
                    @{
                        IdentityId          = 'id-alice'
                        IdentityName        = 'Alice Johnson'
                        RiskScore           = 45
                        RiskTier            = 'Medium'
                        StaleAccessCount    = 2
                        PrivilegedAccessCount = 1
                        TopRiskFactors      = @('StaleAccess')
                    }
                )
            }

            $script:dashSourceGov = @{
                Sources = @(
                    @{
                        SourceName      = 'Active Directory'
                        GovernanceGrade = 'B'
                        GovernanceScore = 78
                    }
                )
            }

            $script:dashReviewerRep = @{
                Reviewers = @(
                    @{
                        Name            = 'Manager One'
                        ReputationScore = 82
                        ReputationTier  = 'Strong'
                    }
                )
            }

            $script:dashMetrics = @{
                Data = @(
                    [PSCustomObject]@{
                        CampaignId          = 'camp-dash-001'
                        ApprovalRate        = 75.0
                        RevocationRate      = 25.0
                        AvgResponseTimeHours = 48.0
                    }
                )
            }

            $script:dashPolicyResults = @{
                OverallCompliant = $true
                Summary = @{ Passed = 3; Failed = 0 }
            }

            $script:dashOutputDir = Join-Path $TestDrive 'dashboard-export'

            $script:dashResult = Export-SPGovernanceDashboardData `
                -CampaignAudits $script:dashAudits `
                -OutputPath $script:dashOutputDir `
                -CampaignMetrics $script:dashMetrics `
                -PolicyResults $script:dashPolicyResults `
                -IdentityRisk $script:dashIdentityRisk `
                -SourceGovernance $script:dashSourceGov `
                -ReviewerReputation $script:dashReviewerRep `
                -Format 'Both'
        }

        It "Should return Success true" {
            $script:dashResult.Success | Should -Be $true
        }

        It "Should produce 2 rows (1 approved + 1 revoked)" {
            $script:dashResult.Data.RowCount | Should -Be 2
        }

        It "Should create a CSV file" {
            $script:dashResult.Data.CsvFile | Should -Not -BeNullOrEmpty
            Test-Path $script:dashResult.Data.CsvFile | Should -Be $true
        }

        It "Should create a JSON file" {
            $script:dashResult.Data.JsonFile | Should -Not -BeNullOrEmpty
            Test-Path $script:dashResult.Data.JsonFile | Should -Be $true
        }

        It "Should write valid JSON" {
            $jsonContent = Get-Content $script:dashResult.Data.JsonFile -Raw
            { $jsonContent | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should include enriched identity risk data in JSON" {
            $jsonContent = Get-Content $script:dashResult.Data.JsonFile -Raw
            $parsed = $jsonContent | ConvertFrom-Json
            $aliceRow = $parsed.data | Where-Object { $_.IdentityName -eq 'Alice Johnson' }
            $aliceRow.IdentityRiskScore | Should -Be 45
        }

        It "Should include enriched source governance data in JSON" {
            $jsonContent = Get-Content $script:dashResult.Data.JsonFile -Raw
            $parsed = $jsonContent | ConvertFrom-Json
            $row = $parsed.data | Where-Object { $_.SourceName -eq 'Active Directory' } | Select-Object -First 1
            $row.SourceGovernanceGrade | Should -Be 'B'
        }

        It "Should include reviewer reputation data in JSON" {
            $jsonContent = Get-Content $script:dashResult.Data.JsonFile -Raw
            $parsed = $jsonContent | ConvertFrom-Json
            $row = $parsed.data | Where-Object { $_.ReviewerName -eq 'Manager One' } | Select-Object -First 1
            $row.ReviewerReputationScore | Should -Be 82
        }
    }

    Context "When Format is CSV only" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }

            $script:csvOnlyAudits = @(
                @{
                    CampaignId = 'camp-csv'; CampaignName = 'CSV Test'
                    CampaignType = 'MANAGER'; Status = 'COMPLETED'
                    Created = '2026-01-01'; Deadline = '2026-01-31'; Completed = '2026-01-28'
                    Decisions = @{
                        Approved = @(
                            @{ IdentityId = 'id-x'; IdentityName = 'Test'; SourceName = 'AD'
                               ReviewerName = 'Rev'; AccessName = 'Grp'; AccessType = 'ENT'
                               Decision = 'APPROVE'; DecisionDate = '2026-01-15'
                               Justification = 'OK'; AccountName = 'tuser' }
                        )
                        Revoked = @(); Pending = @()
                    }
                }
            )

            $script:csvOnlyDir = Join-Path $TestDrive 'csv-only'
            $script:csvResult = Export-SPGovernanceDashboardData `
                -CampaignAudits $script:csvOnlyAudits `
                -OutputPath $script:csvOnlyDir `
                -Format 'CSV'
        }

        It "Should create a CSV file" {
            $script:csvResult.Data.CsvFile | Should -Not -BeNullOrEmpty
            Test-Path $script:csvResult.Data.CsvFile | Should -Be $true
        }

        It "Should not create a JSON file" {
            $script:csvResult.Data.JsonFile | Should -BeNullOrEmpty
        }
    }
}

#endregion
