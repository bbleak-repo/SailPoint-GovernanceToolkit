#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Phase 16 Data Quality & Operational Health features
.DESCRIPTION
    Tests: P16-T01 through P16-T07
    Covers:
        P16-T01: Get-SPOrphanAccounts           -- orphan classification, service account filter, API error
        P16-T02: Get-SPSourceAggregationHealth   -- health status classification, staleness, unknown sources
        P16-T03: Measure-SPIdentityDataQuality   -- attribute completeness, quality scoring, grade distribution
        P16-T04: Get-SPCampaignCoverageGaps      -- entitlement coverage, privileged severity, empty inventory
        P16-T05: Get-SPCampaignCompletionForecast -- velocity calculation, forecast status, empty input
        P16-T06: Save-SPGovernanceMetrics         -- JSONL persistence, metric extraction, retention
        P16-T07: Get-SPReviewerDelegations        -- reassignment detection, delegation patterns, empty input

    Mock scoping:
        P16-T01/T02/T03/T07 mock within SP.AuditQueries (Invoke-SPApiRequest, Get-SPConfig, Get-SPAuditSourceName).
        P16-T04/T05 mock within SP.AuditAnalytics (Write-SPLog).
        P16-T06 mocks within SP.AuditOperations (Write-SPLog, Get-SPConfig).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

# ---------------------------------------------------------------------------
#region P16-T01: Get-SPOrphanAccounts
# ---------------------------------------------------------------------------

Describe "P16-T01: Get-SPOrphanAccounts classifies orphan accounts by type" {

    Context "When source contains uncorrelated, terminated, and dangling accounts" {
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

            $script:orphanApiCalls = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:orphanApiCalls++

                # Accounts page (single page, 4 accounts)
                if ($Endpoint -eq '/v3/accounts') {
                    $items = @(
                        # Uncorrelated account (no identityId)
                        [PSCustomObject]@{
                            id                    = 'acct-001'
                            name                  = 'orphan.user'
                            nativeIdentity        = 'CN=orphan.user,OU=Users,DC=test'
                            identityId            = $null
                            disabled              = $false
                            entitlementAttributes = @(
                                [PSCustomObject]@{ name = 'memberOf'; value = 'CN=GroupA' }
                            )
                            created               = '2025-06-01T10:00:00Z'
                        },
                        # Terminated owner account
                        [PSCustomObject]@{
                            id                    = 'acct-002'
                            name                  = 'termed.user'
                            nativeIdentity        = 'CN=termed.user,OU=Users,DC=test'
                            identityId            = 'id-termed-001'
                            disabled              = $false
                            entitlementAttributes = @()
                            created               = '2025-03-15T08:00:00Z'
                        },
                        # Service account (should be excluded by default)
                        [PSCustomObject]@{
                            id                    = 'acct-003'
                            name                  = 'svc-backup'
                            nativeIdentity        = 'CN=svc-backup,OU=ServiceAccounts,DC=test'
                            identityId            = $null
                            disabled              = $false
                            entitlementAttributes = @()
                            created               = '2024-01-01T00:00:00Z'
                        },
                        # Normal correlated account (not orphan)
                        [PSCustomObject]@{
                            id                    = 'acct-004'
                            name                  = 'active.user'
                            nativeIdentity        = 'CN=active.user,OU=Users,DC=test'
                            identityId            = 'id-active-001'
                            disabled              = $false
                            entitlementAttributes = @()
                            created               = '2025-01-01T00:00:00Z'
                        }
                    )
                    return @{ Success = $true; Data = $items; Error = $null }
                }

                # Identity lifecycle lookups
                if ($Endpoint -match '/v3/public-identities/id-termed-001') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id             = 'id-termed-001'
                            name           = 'Termed User'
                            lifecycleState = 'TERMINATED'
                        }
                        Error   = $null
                    }
                }
                if ($Endpoint -match '/v3/public-identities/id-active-001') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id             = 'id-active-001'
                            name           = 'Active User'
                            lifecycleState = 'ACTIVE'
                        }
                        Error   = $null
                    }
                }

                return @{ Success = $true; Data = $null; Error = $null }
            }

            $script:orphanResult = Get-SPOrphanAccounts -SourceIds @('src-ad-001')
        }

        It "Should detect the uncorrelated orphan" {
            $uncorrelated = @($script:orphanResult.OrphanAccounts | Where-Object { $_['OrphanType'] -eq 'Uncorrelated' })
            $uncorrelated.Count | Should -Be 1
            $uncorrelated[0]['AccountName'] | Should -Be 'orphan.user'
        }

        It "Should detect the terminated-owner orphan" {
            $termed = @($script:orphanResult.OrphanAccounts | Where-Object { $_['OrphanType'] -eq 'TerminatedOwner' })
            $termed.Count | Should -Be 1
        }

        It "Should exclude service accounts by default" {
            $svc = @($script:orphanResult.OrphanAccounts | Where-Object { $_['AccountName'] -eq 'svc-backup' })
            $svc.Count | Should -Be 0
        }

        It "Should scan all 4 accounts" {
            $script:orphanResult.Summary.TotalAccountsScanned | Should -Be 4
        }

        It "Should track entitlement presence on orphans" {
            $withEnt = @($script:orphanResult.OrphanAccounts | Where-Object { $_['HasEntitlements'] -eq $true })
            $withEnt.Count | Should -BeGreaterOrEqual 1
        }

        It "Should include per-source breakdown" {
            $script:orphanResult.Summary.PerSource | Should -Not -BeNullOrEmpty
        }
    }

    Context "When -IncludeServiceAccounts includes svc- prefixed accounts" {
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
            Mock Get-SPAuditSourceName -ModuleName SP.AuditQueries { return 'AD Source' }

            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                if ($Endpoint -eq '/v3/accounts') {
                    return @{
                        Success = $true
                        Data    = @(
                            [PSCustomObject]@{
                                id = 'acct-svc-1'; name = 'svc-monitor'
                                nativeIdentity = 'CN=svc-monitor'; identityId = $null
                                disabled = $false; entitlementAttributes = @()
                                created = '2025-01-01T00:00:00Z'
                            }
                        )
                        Error = $null
                    }
                }
                return @{ Success = $true; Data = $null; Error = $null }
            }

            $script:svcResult = Get-SPOrphanAccounts -SourceIds @('src-001') -IncludeServiceAccounts
        }

        It "Should include the service account orphan" {
            $script:svcResult.OrphanAccounts.Count | Should -Be 1
            $script:svcResult.OrphanAccounts[0]['IsServiceAccount'] | Should -Be $true
        }

        It "Should count it in ServiceAccountOrphans" {
            $script:svcResult.Summary.ServiceAccountOrphans | Should -Be 1
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
            Mock Get-SPAuditSourceName -ModuleName SP.AuditQueries { return 'Failed Source' }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{ Success = $false; Data = $null; Error = 'API connection failed' }
            }

            $script:orphanErrResult = Get-SPOrphanAccounts -SourceIds @('src-err-001')
        }

        It "Should return empty orphan list on API failure" {
            $script:orphanErrResult.OrphanAccounts.Count | Should -Be 0
        }

        It "Should report zero accounts scanned" {
            $script:orphanErrResult.Summary.TotalAccountsScanned | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T02: Get-SPSourceAggregationHealth
# ---------------------------------------------------------------------------

Describe "P16-T02: Get-SPSourceAggregationHealth classifies source health status" {

    Context "When sources have mixed aggregation histories" {
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

            $script:aggApiCalls = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:aggApiCalls++

                # Individual source queries
                if ($Endpoint -match '/v3/sources/src-healthy') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id = 'src-healthy'; name = 'Healthy AD'
                            type = 'Active Directory'; healthy = $true
                            connectorAttributes = [PSCustomObject]@{ connectorName = 'active-directory' }
                        }
                        Error = $null
                    }
                }
                if ($Endpoint -match '/v3/sources/src-critical') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id = 'src-critical'; name = 'Critical SAP'
                            type = 'SAP'; healthy = $true
                            connectorAttributes = $null
                        }
                        Error = $null
                    }
                }
                if ($Endpoint -match '/v3/sources/src-unknown') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            id = 'src-unknown'; name = 'New Source'
                            type = 'JDBC'; healthy = $true
                            connectorAttributes = $null
                        }
                        Error = $null
                    }
                }

                # Aggregation history queries
                if ($Endpoint -eq '/v3/account-aggregations') {
                    $filter = $QueryParams['filters']

                    if ($filter -match 'src-healthy') {
                        $now = [datetime]::UtcNow
                        return @{
                            Success = $true
                            Data    = @(
                                [PSCustomObject]@{
                                    id       = 'agg-h-1'
                                    sourceId = 'src-healthy'
                                    status   = 'SUCCESS'
                                    started  = $now.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    completed = $now.AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    totalAccounts = 1500
                                    errorCount    = 0
                                },
                                [PSCustomObject]@{
                                    id       = 'agg-h-2'
                                    sourceId = 'src-healthy'
                                    status   = 'SUCCESS'
                                    started  = $now.AddHours(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    completed = $now.AddHours(-29).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    totalAccounts = 1490
                                    errorCount    = 0
                                }
                            )
                            Error = $null
                        }
                    }

                    if ($filter -match 'src-critical') {
                        $now = [datetime]::UtcNow
                        return @{
                            Success = $true
                            Data    = @(
                                [PSCustomObject]@{
                                    id       = 'agg-c-1'
                                    sourceId = 'src-critical'
                                    status   = 'ERROR'
                                    started  = $now.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    completed = $now.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    totalAccounts = 0
                                    errorCount    = 15
                                },
                                [PSCustomObject]@{
                                    id       = 'agg-c-2'
                                    sourceId = 'src-critical'
                                    status   = 'ERROR'
                                    started  = $now.AddHours(-26).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    completed = $now.AddHours(-26).ToString('yyyy-MM-ddTHH:mm:ssZ')
                                    totalAccounts = 0
                                    errorCount    = 10
                                }
                            )
                            Error = $null
                        }
                    }

                    if ($filter -match 'src-unknown') {
                        # No aggregation history
                        return @{ Success = $true; Data = @(); Error = $null }
                    }
                }

                return @{ Success = $true; Data = $null; Error = $null }
            }

            $script:healthResult = Get-SPSourceAggregationHealth `
                -SourceIds @('src-healthy', 'src-critical', 'src-unknown') `
                -MaxAcceptableStalenessHours 48
        }

        It "Should evaluate 3 sources" {
            $script:healthResult.Summary.TotalSources | Should -Be 3
        }

        It "Should classify the healthy source as Healthy" {
            $healthy = $script:healthResult.Sources | Where-Object { $_['SourceName'] -eq 'Healthy AD' }
            $healthy['HealthStatus'] | Should -Be 'Healthy'
        }

        It "Should classify the failing source as Critical (2 consecutive failures)" {
            $critical = $script:healthResult.Sources | Where-Object { $_['SourceName'] -eq 'Critical SAP' }
            $critical['HealthStatus'] | Should -Be 'Critical'
            $critical['ConsecutiveFailures'] | Should -BeGreaterOrEqual 2
        }

        It "Should classify the source with no history as Unknown" {
            $unknown = $script:healthResult.Sources | Where-Object { $_['SourceName'] -eq 'New Source' }
            $unknown['HealthStatus'] | Should -Be 'Unknown'
        }

        It "Should count health categories in summary" {
            $script:healthResult.Summary.Healthy | Should -Be 1
            $script:healthResult.Summary.Critical | Should -Be 1
            $script:healthResult.Summary.Unknown | Should -Be 1
        }

        It "Should track sources with failures" {
            $script:healthResult.Summary.SourcesWithFailures | Should -BeGreaterOrEqual 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T03: Measure-SPIdentityDataQuality
# ---------------------------------------------------------------------------

Describe "P16-T03: Measure-SPIdentityDataQuality scores identity attribute completeness" {

    Context "When identities have mixed attribute quality" {
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
                $items = @(
                    # Complete identity -- all required attributes present
                    [PSCustomObject]@{
                        id             = 'id-complete'
                        name           = 'Complete User'
                        lifecycleState = 'ACTIVE'
                        attributes     = [PSCustomObject]@{
                            manager    = 'id-mgr-001'
                            department = 'Engineering'
                            email      = 'complete@test.com'
                            title      = 'Engineer'
                            location   = 'NYC'
                        }
                        modified       = [datetime]::UtcNow.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    },
                    # Missing attributes -- no manager, no title
                    [PSCustomObject]@{
                        id             = 'id-partial'
                        name           = 'Partial User'
                        lifecycleState = 'ACTIVE'
                        attributes     = [PSCustomObject]@{
                            manager    = $null
                            department = 'Sales'
                            email      = 'partial@test.com'
                            title      = $null
                            location   = 'LAX'
                        }
                        modified       = [datetime]::UtcNow.AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    },
                    # Manager self-reference
                    [PSCustomObject]@{
                        id             = 'id-selfmgr'
                        name           = 'SelfMgr User'
                        lifecycleState = 'ACTIVE'
                        attributes     = [PSCustomObject]@{
                            manager    = 'id-selfmgr'
                            department = 'HR'
                            email      = 'selfmgr@test.com'
                            title      = 'Director'
                            location   = 'CHI'
                        }
                        modified       = [datetime]::UtcNow.AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                )
                return @{ Success = $true; Data = $items; Error = $null }
            }

            $script:qualityResult = Measure-SPIdentityDataQuality `
                -Limit 100 `
                -RequiredAttributes @('manager', 'department', 'email', 'title', 'location')
        }

        It "Should scan 3 identities" {
            $script:qualityResult.Summary.TotalIdentitiesScanned | Should -Be 3
        }

        It "Should produce a quality grade" {
            $script:qualityResult.Summary.OverallQualityGrade | Should -BeIn @('A', 'B', 'C', 'D', 'F')
        }

        It "Should compute a numeric overall score between 0 and 100" {
            $script:qualityResult.Summary.OverallQualityScore | Should -BeGreaterOrEqual 0
            $script:qualityResult.Summary.OverallQualityScore | Should -BeLessOrEqual 100
        }

        It "Should identify the worst attribute" {
            $script:qualityResult.Summary.WorstAttribute | Should -Not -BeNullOrEmpty
        }

        It "Should detect the manager self-reference issue" {
            $script:qualityResult.QualityIssues.ManagerSelfReference.Count | Should -BeGreaterOrEqual 1
        }

        It "Should track attribute completeness percentages" {
            $script:qualityResult.AttributeCompleteness.Keys.Count | Should -Be 5
        }

        It "Should flag identities with missing attributes" {
            $partial = $script:qualityResult.Identities | Where-Object { $_['IdentityId'] -eq 'id-partial' }
            $partial['MissingAttributes'].Count | Should -BeGreaterOrEqual 1
        }

        It "Should assign quality grade distribution" {
            $dist = $script:qualityResult.Summary.QualityGradeDistribution
            ($dist['A'] + $dist['B'] + $dist['C'] + $dist['D'] + $dist['F']) | Should -Be 3
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T04: Get-SPCampaignCoverageGaps
# ---------------------------------------------------------------------------

Describe "P16-T04: Get-SPCampaignCoverageGaps identifies unreviewed entitlements" {

    Context "When some entitlements have never been reviewed" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:gapAudits = @(
                @{
                    CampaignId   = 'camp-cov-001'
                    CampaignName = 'Q1 Review'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; SourceName = 'Active Directory'; AccessName = 'Finance-Group'; Decision = 'APPROVE' },
                            @{ IdentityId = 'id-002'; IdentityName = 'Bob';   SourceName = 'Active Directory'; AccessName = 'HR-Group';      Decision = 'APPROVE' }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            )

            $script:gapInventory = @{
                Sources = @{
                    'src-ad-001' = @{
                        SourceName        = 'Active Directory'
                        TotalEntitlements = 4
                        Entitlements      = @(
                            @{ Name = 'Finance-Group'; Privileged = $false },
                            @{ Name = 'HR-Group';      Privileged = $false },
                            @{ Name = 'Admin-Group';   Privileged = $true },
                            @{ Name = 'VPN-Access';    Privileged = $false }
                        )
                    }
                }
                Summary = @{ TotalEntitlements = 4 }
            }

            $script:gapResult = Get-SPCampaignCoverageGaps `
                -CampaignAudits $script:gapAudits `
                -EntitlementInventory $script:gapInventory
        }

        It "Should find 2 never-reviewed entitlements" {
            $script:gapResult.Summary.NeverReviewed | Should -Be 2
        }

        It "Should compute 50% coverage" {
            $script:gapResult.Summary.CoveragePct | Should -Be 50.0
        }

        It "Should classify privileged unreviewed as Critical severity" {
            $adminGap = $script:gapResult.Gaps | Where-Object { $_['EntitlementName'] -eq 'Admin-Group' }
            $adminGap | Should -Not -BeNullOrEmpty
            $adminGap['Severity'] | Should -Be 'Critical'
        }

        It "Should classify non-privileged unreviewed as High severity" {
            $vpnGap = $script:gapResult.Gaps | Where-Object { $_['EntitlementName'] -eq 'VPN-Access' }
            $vpnGap | Should -Not -BeNullOrEmpty
            $vpnGap['Severity'] | Should -Be 'High'
        }

        It "Should count privileged never-reviewed" {
            $script:gapResult.Summary.PrivilegedNeverReviewed | Should -Be 1
        }

        It "Should include per-source breakdown" {
            $adStats = $script:gapResult.Summary.PerSource['Active Directory']
            $adStats | Should -Not -BeNullOrEmpty
            $adStats['Total'] | Should -Be 4
            $adStats['Covered'] | Should -Be 2
        }
    }

    Context "When entitlement inventory is empty" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:emptyInvResult = Get-SPCampaignCoverageGaps `
                -CampaignAudits @(@{ CampaignId = 'camp-x'; Decisions = @{ Approved = @(); Revoked = @(); Pending = @() } }) `
                -EntitlementInventory @{ Sources = @{}; Summary = @{ TotalEntitlements = 0 } }
        }

        It "Should return 100% coverage for empty inventory" {
            $script:emptyInvResult.Summary.CoveragePct | Should -Be 100.0
        }

        It "Should return zero gaps" {
            $script:emptyInvResult.Gaps.Count | Should -Be 0
        }
    }

    Context "When campaign audits are empty but inventory has entitlements" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:noAuditResult = Get-SPCampaignCoverageGaps `
                -CampaignAudits @() `
                -EntitlementInventory @{
                    Sources = @{
                        'src-001' = @{
                            SourceName = 'Source1'
                            TotalEntitlements = 2
                            Entitlements = @(
                                @{ Name = 'Ent-A'; Privileged = $false },
                                @{ Name = 'Ent-B'; Privileged = $false }
                            )
                        }
                    }
                    Summary = @{ TotalEntitlements = 2 }
                }
        }

        It "Should return 0% coverage" {
            $script:noAuditResult.Summary.CoveragePct | Should -Be 0.0
        }

        It "Should flag all entitlements as NeverReviewed" {
            $script:noAuditResult.Summary.NeverReviewed | Should -Be 2
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T05: Get-SPCampaignCompletionForecast
# ---------------------------------------------------------------------------

Describe "P16-T05: Get-SPCampaignCompletionForecast projects campaign completion" {

    Context "When an active campaign has decision velocity" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $now = [datetime]::UtcNow
            $script:forecastAudits = @(
                @{
                    CampaignId   = 'camp-active-001'
                    CampaignName = 'Q2 Manager Review'
                    Status       = 'ACTIVE'
                    Created      = $now.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Deadline     = $now.AddDays(10).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-001'; IdentityName = 'Alice'; ReviewerName = 'Manager1'; DecisionDate = $now.AddDays(-4).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'APPROVE' },
                            @{ IdentityId = 'id-002'; IdentityName = 'Bob';   ReviewerName = 'Manager1'; DecisionDate = $now.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'APPROVE' },
                            @{ IdentityId = 'id-003'; IdentityName = 'Carol'; ReviewerName = 'Manager2'; DecisionDate = $now.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'APPROVE' },
                            @{ IdentityId = 'id-004'; IdentityName = 'Dave';  ReviewerName = 'Manager2'; DecisionDate = $now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'APPROVE' },
                            @{ IdentityId = 'id-005'; IdentityName = 'Eve';   ReviewerName = 'Manager1'; DecisionDate = $now.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'APPROVE' }
                        )
                        Revoked = @(
                            @{ IdentityId = 'id-006'; IdentityName = 'Frank'; ReviewerName = 'Manager1'; DecisionDate = $now.AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'); Decision = 'REVOKE' }
                        )
                        Pending = @(
                            @{ IdentityId = 'id-007'; IdentityName = 'Grace'; ReviewerName = 'Manager2' },
                            @{ IdentityId = 'id-008'; IdentityName = 'Hank';  ReviewerName = 'Manager2' },
                            @{ IdentityId = 'id-009'; IdentityName = 'Irene'; ReviewerName = 'Manager3' },
                            @{ IdentityId = 'id-010'; IdentityName = 'Jack';  ReviewerName = 'Manager3' }
                        )
                    }
                }
            )

            $script:forecastResult = Get-SPCampaignCompletionForecast `
                -CampaignAudits $script:forecastAudits `
                -VelocityWindowHours 48
        }

        It "Should produce 1 forecast for the active campaign" {
            $script:forecastResult.Forecasts.Count | Should -Be 1
        }

        It "Should count 10 total items (6 decided + 4 pending)" {
            $fc = $script:forecastResult.Forecasts[0]
            $fc['TotalItems'] | Should -Be 10
        }

        It "Should count 6 decided items" {
            $fc = $script:forecastResult.Forecasts[0]
            $fc['DecidedItems'] | Should -Be 6
        }

        It "Should compute completion percentage" {
            $fc = $script:forecastResult.Forecasts[0]
            $fc['CompletionPct'] | Should -BeGreaterOrEqual 50
        }

        It "Should assign a forecast status" {
            $fc = $script:forecastResult.Forecasts[0]
            $fc['ForecastStatus'] | Should -BeIn @('OnTrack', 'AtRisk', 'WillMiss')
        }

        It "Should assign a confidence level" {
            $fc = $script:forecastResult.Forecasts[0]
            $fc['Confidence'] | Should -BeIn @('Low', 'Medium', 'High')
        }

        It "Should report 1 active campaign in summary" {
            $script:forecastResult.Summary.ActiveCampaigns | Should -Be 1
        }
    }

    Context "When campaign audits are empty" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:emptyForecast = Get-SPCampaignCompletionForecast -CampaignAudits @()
        }

        It "Should return zero active campaigns" {
            $script:emptyForecast.Summary.ActiveCampaigns | Should -Be 0
        }

        It "Should return empty Forecasts array" {
            $script:emptyForecast.Forecasts.Count | Should -Be 0
        }

        It "Should return 0 AvgCompletionPct" {
            $script:emptyForecast.Summary.AvgCompletionPct | Should -Be 0.0
        }
    }

    Context "When campaign is COMPLETED it is excluded from forecasts" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }

            $script:completedAudit = @(
                @{
                    CampaignId   = 'camp-done-001'
                    CampaignName = 'Completed Campaign'
                    Status       = 'COMPLETED'
                    Created      = '2026-01-01T00:00:00Z'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-x'; DecisionDate = '2026-01-10T00:00:00Z'; Decision = 'APPROVE'; ReviewerName = 'Mgr' }
                        )
                        Revoked = @(); Pending = @()
                    }
                }
            )

            $script:doneResult = Get-SPCampaignCompletionForecast -CampaignAudits $script:completedAudit
        }

        It "Should return zero forecasts for completed campaigns" {
            $script:doneResult.Forecasts.Count | Should -Be 0
        }

        It "Should report 0 active campaigns" {
            $script:doneResult.Summary.ActiveCampaigns | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T06: Save-SPGovernanceMetrics
# ---------------------------------------------------------------------------

Describe "P16-T06: Save-SPGovernanceMetrics persists KPIs to JSONL" {

    Context "When called with analytics data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-test')
                        RetentionDays = 365
                    }
                }
            }

            $script:mockRisk = @{
                Summary = @{
                    HighRiskCount = 5
                    AvgRiskScore  = 42.3
                }
            }

            $script:mockMaturity = @{
                Data = @{
                    OverallScore = 72
                    OverallLevel = 'Managed'
                }
            }

            $script:saveResult = Save-SPGovernanceMetrics `
                -IdentityRisk $script:mockRisk `
                -GovernanceMaturity $script:mockMaturity `
                -Label 'test-run-001'
        }

        It "Should return Success true" {
            $script:saveResult.Success | Should -Be $true
        }

        It "Should report non-zero MetricCount" {
            $script:saveResult.Data.MetricCount | Should -BeGreaterOrEqual 1
        }

        It "Should create the JSONL file on disk" {
            Test-Path $script:saveResult.Data.FilePath | Should -Be $true
        }

        It "Should write valid JSON in the file" {
            $content = Get-Content $script:saveResult.Data.FilePath -Raw
            $content | Should -Not -BeNullOrEmpty
            $lines = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -BeGreaterOrEqual 1
            # Verify the last line is valid JSON
            { $lines[-1] | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should include the label in the record" {
            $content = Get-Content $script:saveResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.label | Should -Be 'test-run-001'
        }

        It "Should include identity risk metrics in the record" {
            $content = Get-Content $script:saveResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'identityRisk.highCount' | Should -Be 5
        }

        It "Should include a UTC timestamp" {
            $script:saveResult.Data.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }
    }

    Context "When called with no metric inputs" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-empty')
                        RetentionDays = 365
                    }
                }
            }

            $script:emptyMetrics = Save-SPGovernanceMetrics
        }

        It "Should return Success true even with no inputs" {
            $script:emptyMetrics.Success | Should -Be $true
        }

        It "Should report zero MetricCount" {
            $script:emptyMetrics.Data.MetricCount | Should -Be 0
        }
    }

    Context "When called with CampaignList for campaign throughput" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-campaign-throughput')
                        RetentionDays = 365
                    }
                }
            }

            $now = [datetime]::UtcNow
            $script:mockCampaignList = @(
                @{
                    id        = 'camp-001'
                    name      = 'Q2 Review'
                    status    = 'ACTIVE'
                    created   = $now.AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    deadline  = $now.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')
                },
                @{
                    id        = 'camp-002'
                    name      = 'Q1 Review'
                    status    = 'COMPLETED'
                    created   = $now.AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    completed = $now.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
                },
                @{
                    id        = 'camp-003'
                    name      = 'Overdue Review'
                    status    = 'ACTIVE'
                    created   = $now.AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    deadline  = $now.AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
            )

            $script:campResult = Save-SPGovernanceMetrics `
                -CampaignList $script:mockCampaignList `
                -Label 'test-campaign-throughput'
        }

        It "Should return Success true" {
            $script:campResult.Success | Should -Be $true
        }

        It "Should include campaigns.activeCount in record" {
            $content = Get-Content $script:campResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.activeCount' | Should -Be 2
        }

        It "Should include campaigns.completedCount in record" {
            $content = Get-Content $script:campResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.completedCount' | Should -Be 1
        }

        It "Should include campaigns.overdueCount in record" {
            $content = Get-Content $script:campResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.overdueCount' | Should -Be 1
        }

        It "Should compute campaigns.avgDaysToComplete as non-negative" {
            $content = Get-Content $script:campResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.avgDaysToComplete' | Should -BeGreaterOrEqual 0
        }

        It "Should have campaigns.avgDaysToComplete as null when no completed campaigns" {
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-no-completed')
                        RetentionDays = 365
                    }
                }
            }

            $activeOnly = @(
                @{ id = 'camp-a'; name = 'Active Only'; status = 'ACTIVE'; created = '2026-01-01T00:00:00Z'; deadline = '2027-01-01T00:00:00Z' }
            )
            $result = Save-SPGovernanceMetrics -CampaignList $activeOnly
            $content = Get-Content $result.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.avgDaysToComplete' | Should -BeNullOrEmpty
        }
    }

    Context "When called with CampaignAuditData for reviewer health" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-reviewer-health')
                        RetentionDays = 365
                    }
                }
            }

            $script:mockAuditData = @(
                @{
                    CampaignName    = 'Q2 Review'
                    CampaignId      = 'camp-001'
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            [PSCustomObject]@{
                                Name          = 'Alice'
                                DecisionsMade = 10
                                TotalItems    = 10
                            },
                            [PSCustomObject]@{
                                Name          = 'Bob'
                                DecisionsMade = 3
                                TotalItems    = 8
                            },
                            [PSCustomObject]@{
                                Name          = 'Carol'
                                DecisionsMade = 0
                                TotalItems    = 5
                            }
                        )
                    }
                }
            )

            $script:reviewerResult = Save-SPGovernanceMetrics `
                -CampaignAuditData $script:mockAuditData `
                -Label 'test-reviewer-health'
        }

        It "Should return Success true" {
            $script:reviewerResult.Success | Should -Be $true
        }

        It "Should include reviewers.totalActive as non-negative" {
            $content = Get-Content $script:reviewerResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'reviewers.totalActive' | Should -Be 3
        }

        It "Should include reviewers.completedCount" {
            $content = Get-Content $script:reviewerResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            # Alice completed all 10 of 10
            $record.metrics.'reviewers.completedCount' | Should -Be 1
        }

        It "Should include reviewers.notStartedCount" {
            $content = Get-Content $script:reviewerResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            # Carol has 0 decisions
            $record.metrics.'reviewers.notStartedCount' | Should -Be 1
        }

        It "Should include reviewers.avgCompletionPct between 0 and 100" {
            $content = Get-Content $script:reviewerResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'reviewers.avgCompletionPct' | Should -BeGreaterOrEqual 0
            $record.metrics.'reviewers.avgCompletionPct' | Should -BeLessOrEqual 100
        }
    }

    Context "When called with no CampaignList or CampaignAuditData" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Metrics = [PSCustomObject]@{
                        Path          = (Join-Path $TestDrive 'metrics-no-enrichment')
                        RetentionDays = 365
                    }
                }
            }

            $script:noEnrichResult = Save-SPGovernanceMetrics -Label 'test-no-enrichment'
        }

        It "Should include null campaign throughput fields" {
            $content = Get-Content $script:noEnrichResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'campaigns.activeCount'       | Should -BeNullOrEmpty
            $record.metrics.'campaigns.completedCount'    | Should -BeNullOrEmpty
            $record.metrics.'campaigns.overdueCount'      | Should -BeNullOrEmpty
            $record.metrics.'campaigns.avgDaysToComplete' | Should -BeNullOrEmpty
        }

        It "Should include null reviewer health fields" {
            $content = Get-Content $script:noEnrichResult.Data.FilePath -Raw
            $line = @($content.Trim().Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[-1]
            $record = $line | ConvertFrom-Json
            $record.metrics.'reviewers.totalActive'      | Should -BeNullOrEmpty
            $record.metrics.'reviewers.completedCount'   | Should -BeNullOrEmpty
            $record.metrics.'reviewers.notStartedCount'  | Should -BeNullOrEmpty
            $record.metrics.'reviewers.avgCompletionPct' | Should -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region P16-T07: Get-SPReviewerDelegations
# ---------------------------------------------------------------------------

Describe "P16-T07: Get-SPReviewerDelegations detects reassignment patterns" {

    Context "When campaign has items with reassignment data" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            $now = [datetime]::UtcNow
            $script:delegationAudits = @(
                @{
                    CampaignId   = 'camp-del-001'
                    CampaignName = 'Q2 Access Review'
                    Created      = $now.AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Deadline     = $now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Decisions    = @{
                        Approved = @(
                            # Normal decision (no reassignment)
                            @{
                                ItemId           = 'item-001'
                                IdentityName     = 'Alice'
                                EntitlementName  = 'Finance-Group'
                                ReviewerName     = 'Manager1'
                                Decision         = 'APPROVE'
                                DecisionDate     = $now.AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            },
                            # Reassigned item (OriginalReviewer differs from ReviewerName)
                            @{
                                ItemId             = 'item-002'
                                IdentityName       = 'Bob'
                                EntitlementName    = 'Admin-Group'
                                ReviewerName       = 'Manager2'
                                OriginalReviewer   = 'Manager1'
                                ReassignedFrom     = 'Manager1'
                                Decision           = 'APPROVE'
                                DecisionDate       = $now.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            },
                            # Another reassignment by Manager1 (making them a potential HighDelegator)
                            @{
                                ItemId             = 'item-003'
                                IdentityName       = 'Carol'
                                EntitlementName    = 'HR-Access'
                                ReviewerName       = 'Manager3'
                                OriginalReviewer   = 'Manager1'
                                ReassignedFrom     = 'Manager1'
                                Decision           = 'APPROVE'
                                DecisionDate       = $now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            )

            $script:delResult = Get-SPReviewerDelegations `
                -CampaignAudits $script:delegationAudits `
                -DeadlineProximityHours 48
        }

        It "Should detect reassigned items" {
            $script:delResult.Summary.TotalReassigned | Should -BeGreaterOrEqual 2
        }

        It "Should analyze all items" {
            $script:delResult.Summary.TotalItemsAnalyzed | Should -Be 3
        }

        It "Should compute overall reassignment rate" {
            $script:delResult.Summary.OverallReassignmentRate | Should -BeGreaterOrEqual 0
        }

        It "Should detect campaigns with delegations" {
            $script:delResult.Summary.CampaignsWithDelegations | Should -Be 1
        }

        It "Should produce reviewer-level metrics" {
            $script:delResult.ReviewerMetrics.Count | Should -BeGreaterOrEqual 1
        }

        It "Should populate PatternSummary keys" {
            $ps = $script:delResult.PatternSummary
            $ps.Keys | Should -Contain 'HighDelegators'
            $ps.Keys | Should -Contain 'DeadlineDelegations'
            $ps.Keys | Should -Contain 'CircularDelegations'
            $ps.Keys | Should -Contain 'DelegateToApprover'
        }
    }

    Context "When campaign audits are empty" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            $script:emptyDelResult = Get-SPReviewerDelegations -CampaignAudits @()
        }

        It "Should return zero delegations" {
            $script:emptyDelResult.Delegations.Count | Should -Be 0
        }

        It "Should return zeroed summary" {
            $script:emptyDelResult.Summary.TotalItemsAnalyzed | Should -Be 0
            $script:emptyDelResult.Summary.TotalReassigned | Should -Be 0
            $script:emptyDelResult.Summary.OverallReassignmentRate | Should -Be 0.0
        }

        It "Should return zeroed PatternSummary" {
            $script:emptyDelResult.PatternSummary.HighDelegators | Should -Be 0
            $script:emptyDelResult.PatternSummary.CircularDelegations | Should -Be 0
        }
    }

    Context "When decision items lack reassignment fields" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            $script:noReassignAudits = @(
                @{
                    CampaignId   = 'camp-no-reassign'
                    CampaignName = 'No Reassignment Data'
                    Created      = '2026-01-01T00:00:00Z'
                    Deadline     = '2026-01-31T00:00:00Z'
                    Decisions    = @{
                        Approved = @(
                            @{ ItemId = 'item-x1'; IdentityName = 'Alice'; EntitlementName = 'GroupA'; ReviewerName = 'Mgr1'; Decision = 'APPROVE'; DecisionDate = '2026-01-10T00:00:00Z' },
                            @{ ItemId = 'item-x2'; IdentityName = 'Bob';   EntitlementName = 'GroupB'; ReviewerName = 'Mgr2'; Decision = 'APPROVE'; DecisionDate = '2026-01-11T00:00:00Z' }
                        )
                        Revoked = @(); Pending = @()
                    }
                }
            )

            $script:noReassignResult = Get-SPReviewerDelegations `
                -CampaignAudits $script:noReassignAudits
        }

        It "Should report zero reassignments" {
            $script:noReassignResult.Summary.TotalReassigned | Should -Be 0
        }

        It "Should add a Note when reassignment data is unavailable" {
            $script:noReassignResult.Summary.Keys | Should -Contain 'Note'
        }
    }
}

#endregion
