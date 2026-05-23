#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Campaign Search features (S-01 through S-09)
.DESCRIPTION
    Tests: CS-001 through CS-009
    Covers:
        CS-001: Search-SPCampaigns with -Type filter (SP.Campaigns)
        CS-002: Get-SPAuditCampaigns with -CreatedAfter/-CreatedBefore (SP.AuditQueries)
        CS-003: Get-SPCampaignDeadlineStatus classifications (SP.Campaigns)
        CS-004: Get-SPReviewerWorkload item counts (SP.AuditQueries)
        CS-005: Get-SPIdentityDecisionHistory across campaigns (SP.AuditQueries)
        CS-006: Measure-SPCampaignMetrics zero-decision handling (SP.AuditReport)
        CS-007: Get-SPSourceCampaignCoverage uncovered sources (SP.AuditQueries)
        CS-008: Compare-SPCampaigns side-by-side metrics (SP.AuditReport)
        CS-009: Invoke-SPCampaignSearch.ps1 syntax validation

    Mock-scoping notes:
        - CS-001, CS-003 mock within SP.Campaigns
        - CS-002, CS-004, CS-005, CS-007 mock within SP.AuditQueries
        - CS-006, CS-008 mock within SP.AuditReport (cross-module calls to
          SP.AuditQueries functions that are imported at module scope)
        - CS-009 is a standalone script syntax check, no mocks needed
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    # Minimal mock config reused across tests
    function New-MockSearchConfig {
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
            Safety = [PSCustomObject]@{
                AllowCompleteCampaign = $false
            }
        }
    }
}

# ---------------------------------------------------------------------------
#region CS-001: Search-SPCampaigns with -Type filter returns only matching type
# ---------------------------------------------------------------------------

Describe "CS-001: Search-SPCampaigns with -Type filter returns only matching type" {

    Context "When -Type MANAGER is specified alongside -Keyword" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.Campaigns { }
            Mock Get-SPConfig       -ModuleName SP.Campaigns { New-MockSearchConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{ id = 'camp-mgr-001'; name = 'Q1 Review Mgr'; type = 'MANAGER'; status = 'COMPLETED' }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with matching campaigns" {
            $result = Search-SPCampaigns -Keyword 'Q1' -Type 'MANAGER'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].type | Should -Be 'MANAGER'
        }

        It "Should include type eq filter in the API request" {
            Search-SPCampaigns -Keyword 'Q1' -Type 'MANAGER'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $QueryParams -is [hashtable] -and
                $QueryParams['filters'] -match 'type eq "MANAGER"'
            }
        }

        It "Should also include the name co filter" {
            Search-SPCampaigns -Keyword 'Q1' -Type 'MANAGER'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $QueryParams -is [hashtable] -and
                $QueryParams['filters'] -match 'name co "Q1"'
            }
        }
    }

    Context "When -Type is omitted" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.Campaigns { }
            Mock Get-SPConfig       -ModuleName SP.Campaigns { New-MockSearchConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{ id = 'camp-001'; name = 'Q1 Review'; type = 'MANAGER'; status = 'COMPLETED' },
                        [PSCustomObject]@{ id = 'camp-002'; name = 'Q1 Source'; type = 'SOURCE_OWNER'; status = 'COMPLETED' }
                    )
                    Error      = $null
                }
            }
        }

        It "Should NOT include type filter in the API request (backwards compatible)" {
            Search-SPCampaigns -Keyword 'Q1'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.Campaigns -ParameterFilter {
                $QueryParams -is [hashtable] -and
                $QueryParams['filters'] -notmatch 'type eq'
            }
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-002: Get-SPAuditCampaigns with -CreatedAfter/-CreatedBefore date range
# ---------------------------------------------------------------------------

Describe "CS-002: Get-SPAuditCampaigns with -CreatedAfter/-CreatedBefore date range" {

    Context "When -CreatedAfter and -CreatedBefore define a Q1 range" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig       -ModuleName SP.AuditQueries { New-MockSearchConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        # Q1 campaign (within range)
                        [PSCustomObject]@{ id = 'camp-q1'; name = 'Q1 Review'; status = 'COMPLETED'; type = 'MANAGER'; created = '2026-02-15T10:00:00Z' },
                        # Q2 campaign (outside range)
                        [PSCustomObject]@{ id = 'camp-q2'; name = 'Q2 Review'; status = 'COMPLETED'; type = 'MANAGER'; created = '2026-04-15T10:00:00Z' },
                        # Dec 2025 campaign (before range)
                        [PSCustomObject]@{ id = 'camp-dec'; name = 'Dec Review'; status = 'COMPLETED'; type = 'MANAGER'; created = '2025-12-10T10:00:00Z' }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return only the Q1 campaign" {
            $result = Get-SPAuditCampaigns -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].id | Should -Be 'camp-q1'
        }
    }

    Context "When -CreatedAfter is specified with -DaysBack (CreatedAfter wins)" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig       -ModuleName SP.AuditQueries { New-MockSearchConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{ id = 'camp-recent'; name = 'Recent Review'; status = 'COMPLETED'; type = 'MANAGER'; created = '2026-05-01T10:00:00Z' },
                        [PSCustomObject]@{ id = 'camp-old'; name = 'Old Review'; status = 'COMPLETED'; type = 'MANAGER'; created = '2025-01-01T10:00:00Z' }
                    )
                    Error      = $null
                }
            }
        }

        It "Should use CreatedAfter, ignoring DaysBack" {
            $result = Get-SPAuditCampaigns -CreatedAfter '2026-04-01' -DaysBack 30

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].id | Should -Be 'camp-recent'
        }
    }

    Context "When -DaysBack is used alone (backwards compatible)" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig       -ModuleName SP.AuditQueries { New-MockSearchConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{ id = 'camp-new'; name = 'New'; status = 'COMPLETED'; type = 'MANAGER'; created = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ') },
                        [PSCustomObject]@{ id = 'camp-old'; name = 'Old'; status = 'COMPLETED'; type = 'MANAGER'; created = (Get-Date).AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    )
                    Error      = $null
                }
            }
        }

        It "Should filter by DaysBack and return only recent campaigns" {
            $result = Get-SPAuditCampaigns -DaysBack 30

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].id | Should -Be 'camp-new'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-003: Get-SPCampaignDeadlineStatus classifies campaigns correctly
# ---------------------------------------------------------------------------

Describe "CS-003: Get-SPCampaignDeadlineStatus classifies Overdue/Critical/Warning/OnTrack" {

    Context "When campaigns have various deadline positions relative to now" {
        BeforeEach {
            Mock Write-SPLog        -ModuleName SP.Campaigns { }
            Mock Get-SPConfig       -ModuleName SP.Campaigns { New-MockSearchConfig }

            $nowUtc = (Get-Date).ToUniversalTime()
            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        # Overdue: deadline is in the past, status ACTIVE
                        [PSCustomObject]@{
                            id       = 'camp-overdue'
                            name     = 'Overdue Campaign'
                            status   = 'ACTIVE'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddHours(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        # Critical: deadline within 24 hours, status ACTIVE
                        [PSCustomObject]@{
                            id       = 'camp-critical'
                            name     = 'Critical Campaign'
                            status   = 'ACTIVE'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddHours(12).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        # Warning: deadline within 72 hours but > 24h, status ACTIVE
                        [PSCustomObject]@{
                            id       = 'camp-warning'
                            name     = 'Warning Campaign'
                            status   = 'ACTIVE'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddHours(48).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        # OnTrack: deadline > 72 hours away, status ACTIVE
                        [PSCustomObject]@{
                            id       = 'camp-ontrack'
                            name     = 'OnTrack Campaign'
                            status   = 'ACTIVE'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddDays(14).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        # Completed: status COMPLETED, deadline irrelevant
                        [PSCustomObject]@{
                            id       = 'camp-completed'
                            name     = 'Completed Campaign'
                            status   = 'COMPLETED'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = (Get-Date).AddDays(-20).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        # NoDeadline: no deadline set, status ACTIVE
                        [PSCustomObject]@{
                            id       = 'camp-nodeadline'
                            name     = 'No Deadline Campaign'
                            status   = 'ACTIVE'
                            type     = 'MANAGER'
                            created  = (Get-Date).AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            deadline = $null
                        }
                    )
                    Error      = $null
                }
            }
        }

        It "Should classify the overdue campaign as Overdue" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Success | Should -Be $true
            $result.Data.Overdue.Count | Should -Be 1
            $result.Data.Overdue[0].id | Should -Be 'camp-overdue'
        }

        It "Should classify the critical campaign as Critical (within 24h)" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.Critical.Count | Should -Be 1
            $result.Data.Critical[0].id | Should -Be 'camp-critical'
        }

        It "Should classify the warning campaign as Warning (within 72h)" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.Warning.Count | Should -Be 1
            $result.Data.Warning[0].id | Should -Be 'camp-warning'
        }

        It "Should classify the on-track campaign as OnTrack (>72h)" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.OnTrack.Count | Should -Be 1
            $result.Data.OnTrack[0].id | Should -Be 'camp-ontrack'
        }

        It "Should classify the completed campaign as Completed regardless of deadline" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.Completed.Count | Should -Be 1
            $result.Data.Completed[0].id | Should -Be 'camp-completed'
        }

        It "Should classify the no-deadline campaign as NoDeadline" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.NoDeadline.Count | Should -Be 1
            $result.Data.NoDeadline[0].id | Should -Be 'camp-nodeadline'
        }

        It "Should produce a correct Summary hashtable" {
            $result = Get-SPCampaignDeadlineStatus -Status 'ACTIVE','COMPLETED' -DaysBack 365

            $result.Data.Summary.Overdue    | Should -Be 1
            $result.Data.Summary.Critical   | Should -Be 1
            $result.Data.Summary.Warning    | Should -Be 1
            $result.Data.Summary.OnTrack    | Should -Be 1
            $result.Data.Summary.Completed  | Should -Be 1
            $result.Data.Summary.NoDeadline | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-004: Get-SPReviewerWorkload returns correct item counts per campaign
# ---------------------------------------------------------------------------

Describe "CS-004: Get-SPReviewerWorkload returns correct item counts per campaign" {

    Context "When reviewer has certifications in two campaigns" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            Mock Get-SPAuditCampaigns -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'camp-001'; name = 'Q1 Review'; status = 'ACTIVE' },
                        [PSCustomObject]@{ id = 'camp-002'; name = 'Q2 Review'; status = 'ACTIVE' }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditQueries {
                param($CampaignId)
                if ($CampaignId -eq 'camp-001') {
                    return @{
                        Success = $true
                        Data    = @(
                            [PSCustomObject]@{
                                id                = 'cert-001'
                                EffectiveReviewer = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Bob Manager' }
                                decisionsTotal    = 10
                                decisionsMade     = 7
                            }
                        )
                        Error   = $null
                    }
                }
                elseif ($CampaignId -eq 'camp-002') {
                    return @{
                        Success = $true
                        Data    = @(
                            [PSCustomObject]@{
                                id                = 'cert-002'
                                EffectiveReviewer = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Bob Manager' }
                                decisionsTotal    = 5
                                decisionsMade     = 5
                            },
                            # Different reviewer -- should be excluded
                            [PSCustomObject]@{
                                id                = 'cert-003'
                                EffectiveReviewer = [PSCustomObject]@{ id = 'mgr-999'; displayName = 'Other Reviewer' }
                                decisionsTotal    = 20
                                decisionsMade     = 10
                            }
                        )
                        Error   = $null
                    }
                }
            }
        }

        It "Should return correct totals for the target reviewer" {
            $result = Get-SPReviewerWorkload -ReviewerIdentityId 'mgr-001'

            $result.Success             | Should -Be $true
            $result.Data.ReviewerId     | Should -Be 'mgr-001'
            $result.Data.ReviewerName   | Should -Be 'Bob Manager'
            $result.Data.TotalCampaigns | Should -Be 2
            $result.Data.TotalItems     | Should -Be 15    # 10 + 5
            $result.Data.TotalPending   | Should -Be 3     # (10-7) + (5-5)
        }

        It "Should return per-campaign workload entries" {
            $result = Get-SPReviewerWorkload -ReviewerIdentityId 'mgr-001'

            $result.Data.Campaigns.Count | Should -Be 2
            $result.Data.Campaigns[0].ItemsAssigned | Should -Be 10
            $result.Data.Campaigns[0].ItemsPending  | Should -Be 3
            $result.Data.Campaigns[1].ItemsAssigned | Should -Be 5
            $result.Data.Campaigns[1].ItemsPending  | Should -Be 0
        }
    }

    Context "When reviewer has no certifications in any campaign" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            Mock Get-SPAuditCampaigns -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'camp-001'; name = 'Q1 Review'; status = 'ACTIVE' }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                = 'cert-other'
                            EffectiveReviewer = [PSCustomObject]@{ id = 'mgr-999'; displayName = 'Other' }
                            decisionsTotal    = 10
                            decisionsMade     = 5
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return TotalCampaigns=0 and empty Campaigns array" {
            $result = Get-SPReviewerWorkload -ReviewerIdentityId 'mgr-nonexistent'

            $result.Success             | Should -Be $true
            $result.Data.TotalCampaigns | Should -Be 0
            $result.Data.Campaigns.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-005: Get-SPIdentityDecisionHistory returns decisions across campaigns
# ---------------------------------------------------------------------------

Describe "CS-005: Get-SPIdentityDecisionHistory returns decisions across campaigns" {

    Context "When the identity has decisions in two campaigns" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            Mock Get-SPAuditCampaigns -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ id = 'camp-001'; name = 'Q1 Review'; status = 'COMPLETED'; created = '2026-01-15T10:00:00Z' },
                        [PSCustomObject]@{ id = 'camp-002'; name = 'Q2 Review'; status = 'COMPLETED'; created = '2026-04-15T10:00:00Z' }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                = 'cert-001'
                            EffectiveReviewer = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Reviewer One' }
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            identitySummary = [PSCustomObject]@{ id = 'id-target'; name = 'Alice Johnson' }
                            access          = [PSCustomObject]@{ name = 'AD Group A' }
                            decision        = 'APPROVE'
                            reviewer        = [PSCustomObject]@{ name = 'Reviewer One' }
                            completed       = '2026-01-20T14:00:00Z'
                        },
                        # Different identity -- should be excluded
                        [PSCustomObject]@{
                            identitySummary = [PSCustomObject]@{ id = 'id-other'; name = 'Bob Smith' }
                            access          = [PSCustomObject]@{ name = 'VPN Access' }
                            decision        = 'REVOKE'
                            reviewer        = [PSCustomObject]@{ name = 'Reviewer One' }
                            completed       = '2026-01-20T15:00:00Z'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return decisions only for the target identity" {
            $result = Get-SPIdentityDecisionHistory -IdentityId 'id-target' -DaysBack 365

            $result.Success                | Should -Be $true
            $result.Data.IdentityId        | Should -Be 'id-target'
            $result.Data.IdentityName      | Should -Be 'Alice Johnson'
            $result.Data.TotalDecisions    | Should -Be 2   # one per campaign (same mock for both)
        }

        It "Should include campaign context with each decision group" {
            $result = Get-SPIdentityDecisionHistory -IdentityId 'id-target' -DaysBack 365

            $result.Data.Campaigns.Count | Should -Be 2
            # Sorted newest first
            $result.Data.Campaigns[0].CampaignName | Should -Be 'Q2 Review'
            $result.Data.Campaigns[1].CampaignName | Should -Be 'Q1 Review'
        }

        It "Should include decision details (AccessName, Decision, ReviewerName)" {
            $result = Get-SPIdentityDecisionHistory -IdentityId 'id-target' -DaysBack 365

            $firstDecision = $result.Data.Campaigns[0].Decisions[0]
            $firstDecision.AccessName   | Should -Be 'AD Group A'
            $firstDecision.Decision     | Should -Be 'APPROVE'
            $firstDecision.ReviewerName | Should -Be 'Reviewer One'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-006: Measure-SPCampaignMetrics handles zero-decision campaigns
# ---------------------------------------------------------------------------

Describe "CS-006: Measure-SPCampaignMetrics handles zero-decision campaigns" {

    Context "When a campaign has certifications but no access review items" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditReport {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                     = 'cert-empty'
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Bob Manager' }
                            ReviewerClassification = 'Primary'
                            created                = '2026-05-01T10:00:00Z'
                            signed                 = $null
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditReport {
                return @{
                    Success = $true
                    Data    = @()
                    Error   = $null
                }
            }

            Mock Measure-SPAuditReviewerMetrics -ModuleName SP.AuditReport {
                return @{
                    ReviewerMetrics     = @()
                    CampaignMinHours    = $null
                    CampaignMaxHours    = $null
                    CampaignAvgHours    = $null
                    CampaignMedianHours = $null
                }
            }
        }

        It "Should return 0% rates without divide-by-zero errors" {
            $campaign = [PSCustomObject]@{
                id       = 'camp-empty'
                name     = 'Empty Campaign'
                type     = 'MANAGER'
                status   = 'ACTIVE'
                created  = '2026-05-01T10:00:00Z'
            }

            $result = Measure-SPCampaignMetrics -Campaigns @($campaign)

            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 1
            $result.Data[0].TotalItems      | Should -Be 0
            $result.Data[0].ApprovalRate    | Should -Be 0.0
            $result.Data[0].RevocationRate  | Should -Be 0.0
            $result.Data[0].CompletionRate  | Should -Be 0.0
        }
    }

    Context "When a campaign has items with decisions" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditReport {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                     = 'cert-001'
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'mgr-001'; displayName = 'Bob Manager' }
                            ReviewerClassification = 'Primary'
                            created                = '2026-05-01T10:00:00Z'
                            signed                 = '2026-05-02T08:00:00Z'
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditReport {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{ decision = 'APPROVE' },
                        [PSCustomObject]@{ decision = 'APPROVE' },
                        [PSCustomObject]@{ decision = 'REVOKE' },
                        [PSCustomObject]@{ decision = $null }
                    )
                    Error   = $null
                }
            }

            Mock Measure-SPAuditReviewerMetrics -ModuleName SP.AuditReport {
                return @{
                    ReviewerMetrics     = @(
                        [PSCustomObject]@{ Name = 'Bob Manager'; AvgHours = 22.0 }
                    )
                    CampaignMinHours    = 22.0
                    CampaignMaxHours    = 22.0
                    CampaignAvgHours    = 22.0
                    CampaignMedianHours = 22.0
                }
            }
        }

        It "Should calculate correct approval and revocation rates" {
            $campaign = [PSCustomObject]@{
                id       = 'camp-metrics'
                name     = 'Metrics Campaign'
                type     = 'MANAGER'
                status   = 'COMPLETED'
                created  = '2026-05-01T10:00:00Z'
            }

            $result = Measure-SPCampaignMetrics -Campaigns @($campaign)

            $result.Success | Should -Be $true
            $result.Data[0].TotalItems     | Should -Be 4
            $result.Data[0].ApprovedCount  | Should -Be 2
            $result.Data[0].RevokedCount   | Should -Be 1
            $result.Data[0].PendingCount   | Should -Be 1
            $result.Data[0].ApprovalRate   | Should -Be 50.0
            $result.Data[0].RevocationRate | Should -Be 25.0
            $result.Data[0].CompletionRate | Should -Be 75.0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-007: Get-SPSourceCampaignCoverage identifies uncovered sources
# ---------------------------------------------------------------------------

Describe "CS-007: Get-SPSourceCampaignCoverage identifies uncovered sources" {

    Context "When two sources exist but only one is covered by campaigns" {
        BeforeEach {
            Mock Write-SPLog  -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries { New-MockSearchConfig }

            # First call: GET /sources returns 2 sources
            # Subsequent calls: campaigns with SOURCE_OWNER covering only src-001
            $script:sourceApiCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:sourceApiCallCount++
                if ($Endpoint -eq '/sources') {
                    return @{
                        Success    = $true
                        StatusCode = 200
                        Data       = @(
                            [PSCustomObject]@{ id = 'src-001'; name = 'Active Directory' },
                            [PSCustomObject]@{ id = 'src-002'; name = 'Workday HR' }
                        )
                        Error      = $null
                    }
                }
                # Other endpoints return empty
                return @{ Success = $true; StatusCode = 200; Data = @(); Error = $null }
            }

            Mock Get-SPAuditCampaigns -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id        = 'camp-so-001'
                            name      = 'AD Source Review'
                            type      = 'SOURCE_OWNER'
                            status    = 'COMPLETED'
                            created   = '2026-03-01T10:00:00Z'
                            sourceIds = @('src-001')
                        }
                    )
                    Error   = $null
                }
            }

            # SOURCE_OWNER campaigns use sourceIds directly, no cert drilling needed
            Mock Get-SPAuditCertifications      -ModuleName SP.AuditQueries {
                return @{ Success = $true; Data = @(); Error = $null }
            }
            Mock Get-SPAuditCertificationItems  -ModuleName SP.AuditQueries {
                return @{ Success = $true; Data = @(); Error = $null }
            }
        }

        It "Should identify src-002 as uncovered" {
            $result = Get-SPSourceCampaignCoverage -DaysBack 365

            $result.Success | Should -Be $true
            $result.Data.Uncovered.Count | Should -BeGreaterOrEqual 1

            $uncoveredIds = @($result.Data.Uncovered | ForEach-Object { $_.SourceId })
            $uncoveredIds | Should -Contain 'src-002'
        }

        It "Should identify src-001 as covered" {
            $result = Get-SPSourceCampaignCoverage -DaysBack 365

            $coveredIds = @($result.Data.Covered | ForEach-Object { $_.SourceId })
            $coveredIds | Should -Contain 'src-001'
        }

        It "Should calculate correct CoverageRate in Summary" {
            $result = Get-SPSourceCampaignCoverage -DaysBack 365

            $result.Data.Summary.TotalSources | Should -Be 2
            $result.Data.Summary.Covered      | Should -Be 1
            $result.Data.Summary.Uncovered    | Should -Be 1
            $result.Data.Summary.CoverageRate | Should -Be 50
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-008: Compare-SPCampaigns produces side-by-side metrics
# ---------------------------------------------------------------------------

Describe "CS-008: Compare-SPCampaigns produces side-by-side metrics" {

    Context "When two campaign objects are provided for comparison" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            Mock Get-SPAuditCampaigns -ModuleName SP.AuditReport {
                return @{ Success = $true; Data = @(); Error = $null }
            }

            Mock Measure-SPCampaignMetrics -ModuleName SP.AuditReport {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            CampaignId              = 'camp-A'
                            CampaignName            = 'Campaign A'
                            CampaignType            = 'MANAGER'
                            CampaignStatus          = 'COMPLETED'
                            CampaignCreated         = '2026-01-01'
                            CampaignDeadline        = '2026-02-01'
                            TotalItems              = 100
                            ApprovedCount           = 80
                            RevokedCount            = 15
                            PendingCount            = 5
                            ApprovalRate            = 80.0
                            RevocationRate          = 15.0
                            CompletionRate          = 95.0
                            ReviewerCount           = 5
                            ReassignmentCount       = 2
                            AvgResponseTimeHours    = 12.5
                            MinResponseTimeHours    = 1.0
                            MaxResponseTimeHours    = 48.0
                            MedianResponseTimeHours = 10.0
                            FastestReviewer         = 'Fast Fred'
                            SlowestReviewer         = 'Slow Sam'
                            ItemsPerReviewer        = @{ 'Fast Fred' = 20; 'Slow Sam' = 30 }
                            DeadlineStatus          = 'OnTime'
                        },
                        [PSCustomObject]@{
                            CampaignId              = 'camp-B'
                            CampaignName            = 'Campaign B'
                            CampaignType            = 'SOURCE_OWNER'
                            CampaignStatus          = 'COMPLETED'
                            CampaignCreated         = '2026-04-01'
                            CampaignDeadline        = '2026-05-01'
                            TotalItems              = 50
                            ApprovedCount           = 45
                            RevokedCount            = 5
                            PendingCount            = 0
                            ApprovalRate            = 90.0
                            RevocationRate          = 10.0
                            CompletionRate          = 100.0
                            ReviewerCount           = 3
                            ReassignmentCount       = 0
                            AvgResponseTimeHours    = 8.0
                            MinResponseTimeHours    = 2.0
                            MaxResponseTimeHours    = 20.0
                            MedianResponseTimeHours = 6.0
                            FastestReviewer         = 'Quick Quinn'
                            SlowestReviewer         = 'Tardy Tom'
                            ItemsPerReviewer        = @{ 'Quick Quinn' = 15; 'Tardy Tom' = 25 }
                            DeadlineStatus          = 'OnTime'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return a ComparisonTable with metric rows" {
            $campA = [PSCustomObject]@{ id = 'camp-A'; name = 'Campaign A'; type = 'MANAGER'; status = 'COMPLETED' }
            $campB = [PSCustomObject]@{ id = 'camp-B'; name = 'Campaign B'; type = 'SOURCE_OWNER'; status = 'COMPLETED' }

            $result = Compare-SPCampaigns -Campaigns @($campA, $campB)

            $result.Success | Should -Be $true
            $result.Data.ComparisonTable.Count | Should -BeGreaterThan 0

            # Check that the first row is Campaign Name
            $nameRow = $result.Data.ComparisonTable | Where-Object { $_.Metric -eq 'Campaign Name' }
            $nameRow | Should -Not -BeNullOrEmpty
            $nameRow.Campaign_1 | Should -Be 'Campaign A'
            $nameRow.Campaign_2 | Should -Be 'Campaign B'
        }

        It "Should include Delta_1v2 column for numeric metrics" {
            $campA = [PSCustomObject]@{ id = 'camp-A'; name = 'Campaign A'; type = 'MANAGER'; status = 'COMPLETED' }
            $campB = [PSCustomObject]@{ id = 'camp-B'; name = 'Campaign B'; type = 'SOURCE_OWNER'; status = 'COMPLETED' }

            $result = Compare-SPCampaigns -Campaigns @($campA, $campB)

            $totalItemsRow = $result.Data.ComparisonTable | Where-Object { $_.Metric -eq 'Total Items' }
            $totalItemsRow | Should -Not -BeNullOrEmpty
            # Delta: 50 - 100 = -50
            $totalItemsRow.Delta_1v2 | Should -Be '-50'
        }

        It "Should return both campaign metric objects in Metrics array" {
            $campA = [PSCustomObject]@{ id = 'camp-A'; name = 'Campaign A'; type = 'MANAGER'; status = 'COMPLETED' }
            $campB = [PSCustomObject]@{ id = 'camp-B'; name = 'Campaign B'; type = 'SOURCE_OWNER'; status = 'COMPLETED' }

            $result = Compare-SPCampaigns -Campaigns @($campA, $campB)

            $result.Data.Metrics.Count | Should -Be 2
            $result.Data.Metrics[0].CampaignId | Should -Be 'camp-A'
            $result.Data.Metrics[1].CampaignId | Should -Be 'camp-B'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CS-009: Invoke-SPCampaignSearch.ps1 syntax validation
# ---------------------------------------------------------------------------

Describe "CS-009: Invoke-SPCampaignSearch.ps1 syntax validation" {

    Context "Script file parses without syntax errors" {
        It "Should parse successfully with Get-Command" {
            $scriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPCampaignSearch.ps1'
            $scriptPath = (Resolve-Path $scriptPath).Path

            $scriptPath | Should -Exist

            # Parse the script -- this throws on syntax errors
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$tokens, [ref]$errors
            ) | Out-Null

            $errors.Count | Should -Be 0
        }

        It "Should define expected parameters" {
            $scriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPCampaignSearch.ps1'
            $scriptPath = (Resolve-Path $scriptPath).Path

            $cmd = Get-Command $scriptPath -ErrorAction Stop
            $paramNames = $cmd.Parameters.Keys

            # Verify key filter parameters exist
            $paramNames | Should -Contain 'Keyword'
            $paramNames | Should -Contain 'Type'
            $paramNames | Should -Contain 'Status'
            $paramNames | Should -Contain 'CreatedAfter'
            $paramNames | Should -Contain 'CreatedBefore'
            $paramNames | Should -Contain 'DaysBack'

            # Verify analysis mode parameters exist
            $paramNames | Should -Contain 'ShowDeadlines'
            $paramNames | Should -Contain 'ShowMetrics'
            $paramNames | Should -Contain 'ReviewerIdentityId'
            $paramNames | Should -Contain 'IdentityId'
            $paramNames | Should -Contain 'SourceCoverage'
            $paramNames | Should -Contain 'CompareIds'

            # Verify output parameters exist
            $paramNames | Should -Contain 'OutputMode'
            $paramNames | Should -Contain 'OutputPath'
            $paramNames | Should -Contain 'Token'
        }
    }
}

#endregion
