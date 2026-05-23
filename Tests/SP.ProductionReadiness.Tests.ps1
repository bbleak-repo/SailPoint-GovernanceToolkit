#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Phase 11 Production Readiness features
.DESCRIPTION
    Tests: P11-T01 through P11-T14
    Covers: configuration validation, audit trail consolidation, CSV export,
    remediation verification, campaign health monitoring, campaign trend analytics,
    entitlement inventory, reviewer reputation, and daily orchestrator syntax.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

#region P11-T01: Test-SPConfiguration returns error for empty TenantUrl

Describe "P11-T01: Test-SPConfiguration returns error for empty TenantUrl" {

    Context "When TenantUrl is empty in configuration" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Config { }
            Mock Test-SPConfigFirstRun -ModuleName SP.Config { return $false }
            Mock Get-SPConfigDefaults -ModuleName SP.Config {
                return @{
                    Authentication = @{}
                    Api            = @{}
                    DeltaCert      = @{}
                    Audit          = @{}
                    Logging        = @{}
                    Safety         = @{}
                    Vault          = @{}
                }
            }
            Mock Get-SPConfig -ModuleName SP.Config {
                return [PSCustomObject]@{
                    Authentication = [PSCustomObject]@{
                        Mode       = 'OAuth'
                        ConfigFile = [PSCustomObject]@{
                            TenantUrl      = ''
                            OAuthTokenUrl  = 'https://tenant.api.identitynow.com/oauth/token'
                            ClientId       = 'test-client-id'
                            ClientSecret   = 'test-secret'
                        }
                    }
                    Api       = [PSCustomObject]@{
                        BaseUrl                    = 'https://tenant.api.identitynow.com'
                        TimeoutSeconds             = 30
                        RateLimitRequestsPerWindow = 50
                    }
                    DeltaCert = [PSCustomObject]@{
                        OutputPath       = (Join-Path $TestDrive 'DeltaCert')
                        DefaultHoursBack = 24
                    }
                    Audit     = [PSCustomObject]@{
                        OutputPath = (Join-Path $TestDrive 'Audit')
                    }
                    Logging   = [PSCustomObject]@{
                        Path = (Join-Path $TestDrive 'Logs')
                    }
                    Safety    = [PSCustomObject]@{
                        MaxCampaignsPerRun = 10
                    }
                    Vault     = [PSCustomObject]@{}
                }
            }
        }

        It "Should return Valid = false" {
            $result = Test-SPConfiguration
            $result.Valid | Should -Be $false
        }

        It "Should include an error mentioning TenantUrl" {
            $result = Test-SPConfiguration
            $hasError = $result.Errors | Where-Object { $_ -match 'TenantUrl' -and $_ -match 'empty' }
            $hasError | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

#region P11-T02: Test-SPConfiguration returns warning for unknown config key

Describe "P11-T02: Test-SPConfiguration returns warning for unknown config key" {

    Context "When configuration has an unknown top-level key" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Config { }
            Mock Test-SPConfigFirstRun -ModuleName SP.Config { return $false }
            Mock Get-SPConfigDefaults -ModuleName SP.Config {
                return @{
                    Authentication = @{}
                    Api            = @{}
                    DeltaCert      = @{}
                    Audit          = @{}
                    Logging        = @{}
                    Safety         = @{}
                    Vault          = @{}
                }
            }
            Mock Get-SPConfig -ModuleName SP.Config {
                return [PSCustomObject]@{
                    Authentication = [PSCustomObject]@{
                        Mode       = 'OAuth'
                        ConfigFile = [PSCustomObject]@{
                            TenantUrl      = 'https://tenant.api.identitynow.com'
                            OAuthTokenUrl  = 'https://tenant.api.identitynow.com/oauth/token'
                            ClientId       = 'test-client-id'
                            ClientSecret   = 'test-secret'
                        }
                    }
                    Api           = [PSCustomObject]@{
                        BaseUrl                    = 'https://tenant.api.identitynow.com'
                        TimeoutSeconds             = 30
                        RateLimitRequestsPerWindow = 50
                    }
                    DeltaCert     = [PSCustomObject]@{
                        OutputPath       = (Join-Path $TestDrive 'DeltaCert')
                        DefaultHoursBack = 24
                    }
                    Audit         = [PSCustomObject]@{
                        OutputPath = (Join-Path $TestDrive 'Audit')
                    }
                    Logging       = [PSCustomObject]@{
                        Path = (Join-Path $TestDrive 'Logs')
                    }
                    Safety        = [PSCustomObject]@{
                        MaxCampaignsPerRun = 10
                    }
                    Vault         = [PSCustomObject]@{}
                    CustomField   = 'some-unexpected-value'
                }
            }
        }

        It "Should include a warning about the unknown key" {
            $result = Test-SPConfiguration
            $hasWarning = $result.Warnings | Where-Object { $_ -match 'CustomField' }
            $hasWarning | Should -Not -BeNullOrEmpty
        }

        It "Should NOT include CustomField in errors" {
            $result = Test-SPConfiguration
            $inErrors = $result.Errors | Where-Object { $_ -match 'CustomField' }
            $inErrors | Should -BeNullOrEmpty
        }
    }
}

#endregion

#region P11-T03: Get-SPAuditTrail reads and merges JSONL files from multiple directories

Describe "P11-T03: Get-SPAuditTrail reads and merges JSONL from multiple directories" {

    Context "When JSONL files exist in audit and deltacert directories" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:auditDir    = Join-Path $TestDrive 'trail-t03-audit'
            $script:deltaCertDir = Join-Path $TestDrive 'trail-t03-dc'
            $null = New-Item -ItemType Directory -Path $script:auditDir -Force
            $null = New-Item -ItemType Directory -Path $script:deltaCertDir -Force

            # Campaign audit JSONL
            $auditLine = '{"Timestamp":"2026-05-20T10:00:00Z","Action":"CampaignAudit","CorrelationID":"corr-t03","CampaignName":"Test Campaign"}'
            $auditFile = Join-Path $script:auditDir 'audit-2026-05-20.jsonl'
            [System.IO.File]::WriteAllText($auditFile, $auditLine)

            # Delta cert audit JSONL
            $dcLine = '{"Timestamp":"2026-05-21T10:00:00Z","Action":"DeltaCertRun","CampaignsCreated":3,"IdentitiesProcessed":12,"SourceIds":["src-ad-001"]}'
            $dcFile = Join-Path $script:deltaCertDir 'deltacert-audit.jsonl'
            [System.IO.File]::WriteAllText($dcFile, $dcLine)

            # Escalation JSONL
            $escLine = '{"Timestamp":"2026-05-22T10:00:00Z","Action":"Escalation","Escalated":2}'
            $escFile = Join-Path $script:deltaCertDir 'deltacert-escalation.jsonl'
            [System.IO.File]::WriteAllText($escFile, $escLine)

            $script:trailResult = Get-SPAuditTrail -AuditOutputPath $script:auditDir `
                -DeltaCertOutputPath $script:deltaCertDir
        }

        It "Should return events from all three JSONL sources" {
            @($script:trailResult).Count | Should -Be 3
        }

        It "Should include CampaignAudit event type" {
            $types = @($script:trailResult | ForEach-Object { $_.EventType })
            $types | Should -Contain 'CampaignAudit'
        }

        It "Should include DeltaCertRun event type" {
            $types = @($script:trailResult | ForEach-Object { $_.EventType })
            $types | Should -Contain 'DeltaCertRun'
        }

        It "Should include Escalation event type" {
            $types = @($script:trailResult | ForEach-Object { $_.EventType })
            $types | Should -Contain 'Escalation'
        }

        It "Should sort events by timestamp descending (newest first)" {
            $first = @($script:trailResult)[0]
            $first.EventType | Should -Be 'Escalation'
        }
    }
}

#endregion

#region P11-T04: Get-SPAuditTrail filters by date range correctly

Describe "P11-T04: Get-SPAuditTrail filters by date range correctly" {

    Context "When filtering with -After and -Before" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:auditDir2    = Join-Path $TestDrive 'trail-t04-audit'
            $script:deltaCertDir2 = Join-Path $TestDrive 'trail-t04-dc'
            $null = New-Item -ItemType Directory -Path $script:auditDir2 -Force
            $null = New-Item -ItemType Directory -Path $script:deltaCertDir2 -Force

            # Three events on different days
            $lines = @(
                '{"Timestamp":"2026-05-18T10:00:00Z","Action":"CampaignAudit","CampaignName":"Old"}',
                '{"Timestamp":"2026-05-20T10:00:00Z","Action":"CampaignAudit","CampaignName":"InRange"}',
                '{"Timestamp":"2026-05-25T10:00:00Z","Action":"CampaignAudit","CampaignName":"Future"}'
            )
            $auditFile = Join-Path $script:auditDir2 'audit-range.jsonl'
            [System.IO.File]::WriteAllText($auditFile, ($lines -join "`n"))

            $script:filteredResult = Get-SPAuditTrail `
                -AuditOutputPath $script:auditDir2 `
                -DeltaCertOutputPath $script:deltaCertDir2 `
                -After ([datetime]'2026-05-19') `
                -Before ([datetime]'2026-05-22')
        }

        It "Should return only the event within the date range" {
            @($script:filteredResult).Count | Should -Be 1
        }

        It "Should return the InRange event" {
            $script:filteredResult[0].Action | Should -Be 'CampaignAudit'
        }
    }
}

#endregion

#region P11-T05: Export-SPAuditCsv produces valid CSV with correct column headers

Describe "P11-T05: Export-SPAuditCsv produces valid CSV with correct headers" {

    Context "When given a well-formed CampaignAudit" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:csvTestDir = Join-Path $TestDrive 'csv-t05'
            $null = New-Item -ItemType Directory -Path $script:csvTestDir -Force

            $campaignAudit = @{
                CampaignName   = 'Q2 2026 Review'
                CampaignId     = 'camp-csv-001'
                CampaignType   = 'MANAGER'
                Status         = 'COMPLETED'
                Created        = '2026-04-01T08:00:00Z'
                Deadline       = '2026-04-30T23:59:59Z'
                Completed      = '2026-04-28T17:00:00Z'
                Decisions      = @{
                    Approved = @(
                        [PSCustomObject]@{
                            IdentityName      = 'Alice'
                            IdentityId        = 'id-001'
                            AccountName       = 'alice.j'
                            SourceName        = 'AD'
                            EntitlementName   = 'AD_Users'
                            AccessName        = 'AD_Users'
                            AccessType        = 'Entitlement'
                            DecisionDate      = '2026-04-15'
                            ReviewerName      = 'Bob Manager'
                            ReviewerEmail     = 'bob@corp.com'
                            Justification     = 'Approved by manager'
                            RemediationStatus = ''
                            RemediationDate   = ''
                            RiskFlags         = @()
                        }
                    )
                    Revoked = @(
                        [PSCustomObject]@{
                            IdentityName      = 'Carol'
                            IdentityId        = 'id-002'
                            AccountName       = 'carol.d'
                            SourceName        = 'AD'
                            EntitlementName   = 'AD_Admins'
                            AccessName        = 'AD_Admins'
                            AccessType        = 'Entitlement'
                            DecisionDate      = '2026-04-16'
                            ReviewerName      = 'Bob Manager'
                            ReviewerEmail     = 'bob@corp.com'
                            Justification     = 'No longer needed'
                            RemediationStatus = 'Provisioned'
                            RemediationDate   = '2026-04-16T15:00:00Z'
                            RiskFlags         = @('HighPrivilege')
                        }
                    )
                    Pending = @()
                }
                ReviewerMetrics = @{
                    ReviewerMetrics = @(
                        @{
                            Name             = 'Bob Manager'
                            ReviewerIdentityId = 'id-mgr-001'
                            ItemsReviewed    = 2
                            AvgHours         = 4.5
                            MinHours         = 2.0
                            MaxHours         = 7.0
                            CompletionRate   = 100.0
                        }
                    )
                }
                RubberStampRisk = @{
                    ReviewerRisks = @()
                }
            }

            $script:csvResult = Export-SPAuditCsv `
                -CampaignAudits @($campaignAudit) `
                -OutputPath $script:csvTestDir `
                -Sheets 'Decisions' `
                -CorrelationID 'csv-t05-corr'
        }

        It "Should create a decisions CSV file" {
            $csvFiles = Get-ChildItem -Path $script:csvTestDir -Filter 'decisions-*.csv'
            $csvFiles.Count | Should -BeGreaterThan 0
        }

        It "Should have correct column headers" {
            $csvFiles = Get-ChildItem -Path $script:csvTestDir -Filter 'decisions-*.csv'
            $header = (Get-Content -Path $csvFiles[0].FullName -TotalCount 1)
            $header | Should -Match 'CampaignName'
            $header | Should -Match 'IdentityName'
            $header | Should -Match 'Decision'
        }

        It "Should contain data rows" {
            $csvFiles = Get-ChildItem -Path $script:csvTestDir -Filter 'decisions-*.csv'
            $content = Import-Csv -Path $csvFiles[0].FullName
            @($content).Count | Should -BeGreaterOrEqual 2
        }

        It "Should have ISO 8601 compatible date formats" {
            $csvFiles = Get-ChildItem -Path $script:csvTestDir -Filter 'decisions-*.csv'
            $content = Import-Csv -Path $csvFiles[0].FullName
            foreach ($row in $content) {
                if (-not [string]::IsNullOrWhiteSpace($row.DecisionDate)) {
                    $row.DecisionDate | Should -Match '^\d{4}-\d{2}-\d{2}'
                }
            }
        }
    }
}

#endregion

#region P11-T06: Get-SPRemediationStatus classifies Provisioned when matching event exists

Describe "P11-T06: Get-SPRemediationStatus classifies Provisioned with matching event" {

    Context "When a REVOKE_ACCESS event matches the revocation decision" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{ MaxPaginationPages = 200 }
                }
            }
            Mock Get-SPAuditIdentityEvents -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id      = 'evt-revoke-1'
                            action  = 'REVOKE_ACCESS'
                            created = '2026-05-20T15:00:00Z'
                            status  = 'COMPLETED'
                            ResolvedSourceNames = @{ 'src-001' = 'Active Directory' }
                            items   = @(
                                [PSCustomObject]@{
                                    sourceName     = 'Active Directory'
                                    name           = 'SG-Finance'
                                    entitlementName = 'SG-Finance'
                                }
                            )
                        }
                    )
                }
            }
        }

        It "Should classify the revocation as Provisioned" {
            $revocations = @(
                [PSCustomObject]@{
                    IdentityId      = 'id-alice-001'
                    IdentityName    = 'Alice Johnson'
                    SourceName      = 'Active Directory'
                    EntitlementName = 'SG-Finance'
                    DecisionDate    = '2026-05-20T14:30:00Z'
                }
            )
            $result = Get-SPRemediationStatus -RevocationDecisions $revocations -SlaHours 48
            $result.Success | Should -Be $true
            $result.Data.Items[0].Status | Should -Be 'Provisioned'
        }

        It "Should calculate DaysToRemediate" {
            $revocations = @(
                [PSCustomObject]@{
                    IdentityId      = 'id-alice-001'
                    IdentityName    = 'Alice Johnson'
                    SourceName      = 'Active Directory'
                    EntitlementName = 'SG-Finance'
                    DecisionDate    = '2026-05-20T14:30:00Z'
                }
            )
            $result = Get-SPRemediationStatus -RevocationDecisions $revocations -SlaHours 48
            $result.Data.Items[0].DaysToRemediate | Should -Not -BeNullOrEmpty
            $result.Data.Summary.Provisioned | Should -Be 1
        }
    }
}

#endregion

#region P11-T07: Get-SPRemediationStatus classifies Overdue when past SLA with no event

Describe "P11-T07: Get-SPRemediationStatus classifies Overdue when past SLA" {

    Context "When no matching provisioning event exists and SLA has expired" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{ MaxPaginationPages = 200 }
                }
            }
            Mock Get-SPAuditIdentityEvents -ModuleName SP.AuditQueries {
                return @{
                    Success = $true
                    Data    = @()
                }
            }
        }

        It "Should classify the revocation as Overdue" {
            $oldDate = (Get-Date).AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $revocations = @(
                [PSCustomObject]@{
                    IdentityId      = 'id-bob-001'
                    IdentityName    = 'Bob Smith'
                    SourceName      = 'Active Directory'
                    EntitlementName = 'SG-Admin'
                    DecisionDate    = $oldDate
                }
            )
            $result = Get-SPRemediationStatus -RevocationDecisions $revocations -SlaHours 48
            $result.Success | Should -Be $true
            $result.Data.Items[0].Status | Should -Be 'Overdue'
            $result.Data.Summary.Overdue | Should -Be 1
        }
    }
}

#endregion

#region P11-T08: Get-SPCampaignHealth returns Red for overdue campaign

Describe "P11-T08: Get-SPCampaignHealth returns Red for overdue campaign" {

    Context "When a campaign has Overdue deadline status" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Campaigns { }
            Mock Get-SPCampaignDeadlineStatus -ModuleName SP.Campaigns {
                $overdueCampaign = [PSCustomObject]@{
                    id             = 'camp-overdue-001'
                    name           = 'Overdue Review'
                    created        = (Get-Date).AddDays(-14).ToString('o')
                    deadline       = (Get-Date).AddDays(-2).ToString('o')
                    totalItems     = 50
                    completedItems = 20
                    DeadlineStatus = 'Overdue'
                    DeadlineUtc    = (Get-Date).AddDays(-2).ToUniversalTime()
                }
                return @{
                    Success = $true
                    Data    = @{
                        Overdue    = @($overdueCampaign)
                        Critical   = @()
                        Warning    = @()
                        OnTrack    = @()
                        NoDeadline = @()
                        Completed  = @()
                        Summary    = @{ Overdue = 1; Critical = 0; Warning = 0; OnTrack = 0; Completed = 0; NoDeadline = 0 }
                    }
                    Error   = $null
                }
            }
            Mock Get-SPAuditCertifications -ModuleName SP.Campaigns {
                return @{ Success = $true; Data = @() }
            }
        }

        It "Should classify the campaign as Red" {
            $result = Get-SPCampaignHealth
            $result.Success | Should -Be $true
            $result.Data.Campaigns[0].OverallHealth | Should -Be 'Red'
        }

        It "Should report 1 Red in summary" {
            $result = Get-SPCampaignHealth
            $result.Data.Summary.Red | Should -Be 1
        }
    }
}

#endregion

#region P11-T09: Get-SPCampaignHealth returns Green for on-track campaign

Describe "P11-T09: Get-SPCampaignHealth returns Green for on-track campaign" {

    Context "When a campaign is on-track with healthy metrics" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.Campaigns { }
            Mock Get-SPCampaignDeadlineStatus -ModuleName SP.Campaigns {
                $onTrackCampaign = [PSCustomObject]@{
                    id             = 'camp-green-001'
                    name           = 'On-Track Review'
                    created        = (Get-Date).AddDays(-3).ToString('o')
                    deadline       = (Get-Date).AddDays(10).ToString('o')
                    totalItems     = 100
                    completedItems = 70
                    DeadlineStatus = 'OnTrack'
                    DeadlineUtc    = (Get-Date).AddDays(10).ToUniversalTime()
                }
                return @{
                    Success = $true
                    Data    = @{
                        Overdue    = @()
                        Critical   = @()
                        Warning    = @()
                        OnTrack    = @($onTrackCampaign)
                        NoDeadline = @()
                        Completed  = @()
                        Summary    = @{ Overdue = 0; Critical = 0; Warning = 0; OnTrack = 1; Completed = 0; NoDeadline = 0 }
                    }
                    Error   = $null
                }
            }
            Mock Get-SPAuditCertifications -ModuleName SP.Campaigns {
                # Return one signed-off cert (not stale)
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id       = 'cert-001'
                            created  = (Get-Date).AddDays(-2).ToString('o')
                            signed   = $true
                            reviewer = [PSCustomObject]@{ name = 'Good Reviewer'; id = 'rev-001' }
                        }
                    )
                }
            }
        }

        It "Should classify the campaign as Green" {
            $result = Get-SPCampaignHealth
            $result.Success | Should -Be $true
            $result.Data.Campaigns[0].OverallHealth | Should -Be 'Green'
        }

        It "Should report 1 Green in summary" {
            $result = Get-SPCampaignHealth
            $result.Data.Summary.Green | Should -Be 1
            $result.Data.Summary.Red | Should -Be 0
        }
    }
}

#endregion

#region P11-T10: Measure-SPCampaignTrends calculates correct deltas between periods

Describe "P11-T10: Measure-SPCampaignTrends calculates correct deltas" {

    Context "When given metrics across three months" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should calculate period-over-period deltas correctly" {
            $metrics = @(
                [PSCustomObject]@{
                    CampaignCreated      = '2026-01-15T00:00:00Z'
                    ApprovedCount        = 80
                    RevokedCount         = 10
                    TotalItems           = 100
                    AvgResponseTimeHours = 20.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-02-15T00:00:00Z'
                    ApprovedCount        = 85
                    RevokedCount         = 10
                    TotalItems           = 100
                    AvgResponseTimeHours = 16.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-03-15T00:00:00Z'
                    ApprovedCount        = 90
                    RevokedCount         = 8
                    TotalItems           = 100
                    AvgResponseTimeHours = 12.0
                    ReviewerCount        = 5
                }
            )

            $result = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Month'

            $result.Periods.Count | Should -Be 3

            # Second period should have deltas vs first
            $period2 = $result.Periods | Where-Object { $_.Label -eq '2026-02' }
            $period2.Deltas | Should -Not -BeNullOrEmpty

            # Third period should have deltas vs second
            $period3 = $result.Periods | Where-Object { $_.Label -eq '2026-03' }
            $period3.Deltas | Should -Not -BeNullOrEmpty
        }

        It "Should have no deltas for the first period (baseline)" {
            $metrics = @(
                [PSCustomObject]@{
                    CampaignCreated      = '2026-01-15T00:00:00Z'
                    ApprovedCount        = 80
                    RevokedCount         = 10
                    TotalItems           = 100
                    AvgResponseTimeHours = 20.0
                    ReviewerCount        = 5
                }
            )
            $result = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Month'
            $result.Periods[0].Deltas.Count | Should -Be 0
        }
    }
}

#endregion

#region P11-T11: Measure-SPCampaignTrends identifies Improving trend

Describe "P11-T11: Measure-SPCampaignTrends identifies Improving trend" {

    Context "When approval rate improves across 4 consecutive months" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should classify ApprovalRate trend as Improving" {
            $metrics = @(
                [PSCustomObject]@{
                    CampaignCreated      = '2026-01-10T00:00:00Z'
                    ApprovedCount        = 70
                    RevokedCount         = 20
                    TotalItems           = 100
                    AvgResponseTimeHours = 24.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-02-10T00:00:00Z'
                    ApprovedCount        = 75
                    RevokedCount         = 18
                    TotalItems           = 100
                    AvgResponseTimeHours = 20.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-03-10T00:00:00Z'
                    ApprovedCount        = 82
                    RevokedCount         = 12
                    TotalItems           = 100
                    AvgResponseTimeHours = 16.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-04-10T00:00:00Z'
                    ApprovedCount        = 90
                    RevokedCount         = 8
                    TotalItems           = 100
                    AvgResponseTimeHours = 12.0
                    ReviewerCount        = 5
                }
            )

            $result = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Month'
            $result.Trends.ApprovalRate | Should -Be 'Improving'
        }

        It "Should report Insufficient Data for fewer than 3 periods" {
            $metrics = @(
                [PSCustomObject]@{
                    CampaignCreated      = '2026-01-10T00:00:00Z'
                    ApprovedCount        = 70
                    RevokedCount         = 20
                    TotalItems           = 100
                    AvgResponseTimeHours = 24.0
                    ReviewerCount        = 5
                },
                [PSCustomObject]@{
                    CampaignCreated      = '2026-02-10T00:00:00Z'
                    ApprovedCount        = 80
                    RevokedCount         = 15
                    TotalItems           = 100
                    AvgResponseTimeHours = 20.0
                    ReviewerCount        = 5
                }
            )

            $result = Measure-SPCampaignTrends -CampaignMetrics $metrics -GroupBy 'Month'
            $result.Trends.ApprovalRate | Should -Be 'Insufficient Data'
        }
    }
}

#endregion

#region P11-T12: Get-SPEntitlementInventory handles paginated entitlement responses

Describe "P11-T12: Get-SPEntitlementInventory handles paginated responses" {

    Context "When entitlements span multiple API pages" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{ MaxPaginationPages = 200 }
                }
            }
            Mock Get-SPAuditSourceName -ModuleName SP.AuditQueries {
                return 'Test Source'
            }

            # Return 250 items on first page, 3 on second page = 253 total
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $offsetVal = 0
                if ($null -ne $QueryParams -and $QueryParams.ContainsKey('offset')) {
                    $offsetVal = [int]$QueryParams['offset']
                }

                if ($offsetVal -eq 0) {
                    $items = @(1..250 | ForEach-Object {
                        [PSCustomObject]@{
                            id          = "ent-$_"
                            name        = "Entitlement-$_"
                            displayName = "Entitlement $_"
                            type        = 'GROUP'
                            attribute   = 'memberOf'
                            source      = [PSCustomObject]@{ id = 'src-test-001'; name = 'Test Source' }
                            owner       = [PSCustomObject]@{ name = 'Owner' }
                            privileged  = ($_ -le 3)
                        }
                    })
                    return @{ Success = $true; Data = $items }
                }
                else {
                    $items = @(251..253 | ForEach-Object {
                        [PSCustomObject]@{
                            id          = "ent-$_"
                            name        = "Entitlement-$_"
                            displayName = "Entitlement $_"
                            type        = 'GROUP'
                            attribute   = 'memberOf'
                            source      = [PSCustomObject]@{ id = 'src-test-001'; name = 'Test Source' }
                            owner       = [PSCustomObject]@{ name = 'Owner' }
                            privileged  = $false
                        }
                    })
                    return @{ Success = $true; Data = $items }
                }
            }
        }

        It "Should collect all 253 entitlements across 2 pages" {
            $result = Get-SPEntitlementInventory -SourceIds 'src-test-001'
            $result.Success | Should -Be $true
            $result.Data.Summary.TotalEntitlements | Should -Be 253
        }

        It "Should correctly count privileged entitlements" {
            $result = Get-SPEntitlementInventory -SourceIds 'src-test-001'
            $result.Data.Summary.TotalPrivileged | Should -Be 3
        }
    }
}

#endregion

#region P11-T13: Measure-SPReviewerReputation excludes reviewers below MinCampaigns

Describe "P11-T13: Measure-SPReviewerReputation excludes low-campaign reviewers" {

    Context "When a reviewer has fewer campaigns than MinCampaigns threshold" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should exclude the reviewer with only 1 campaign" {
            # Build campaign audits: Reviewer A appears in 3 campaigns, Reviewer B in only 1
            $campaigns = @(
                @{
                    CampaignName   = 'Campaign 1'
                    Created        = '2026-01-15T00:00:00Z'
                    Decisions      = @{
                        Approved = @(
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User1'; AccessName = 'Ent1' },
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User2'; AccessName = 'Ent2' }
                        )
                        Revoked = @(
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User3'; AccessName = 'Ent3' }
                        )
                        Pending = @()
                    }
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            @{ Name = 'Reviewer A'; AvgHours = 6.0; MinHours = 2.0; MaxHours = 10.0 }
                        )
                    }
                    RubberStampRisk = @{ ReviewerRisks = @() }
                },
                @{
                    CampaignName   = 'Campaign 2'
                    Created        = '2026-02-15T00:00:00Z'
                    Decisions      = @{
                        Approved = @(
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User4'; AccessName = 'Ent4' },
                            [PSCustomObject]@{ ReviewerName = 'Reviewer B'; IdentityName = 'User5'; AccessName = 'Ent5' }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            @{ Name = 'Reviewer A'; AvgHours = 5.0; MinHours = 1.0; MaxHours = 9.0 },
                            @{ Name = 'Reviewer B'; AvgHours = 8.0; MinHours = 8.0; MaxHours = 8.0 }
                        )
                    }
                    RubberStampRisk = @{ ReviewerRisks = @() }
                },
                @{
                    CampaignName   = 'Campaign 3'
                    Created        = '2026-03-15T00:00:00Z'
                    Decisions      = @{
                        Approved = @(
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User6'; AccessName = 'Ent6' }
                        )
                        Revoked = @(
                            [PSCustomObject]@{ ReviewerName = 'Reviewer A'; IdentityName = 'User7'; AccessName = 'Ent7' }
                        )
                        Pending = @()
                    }
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            @{ Name = 'Reviewer A'; AvgHours = 4.0; MinHours = 1.0; MaxHours = 7.0 }
                        )
                    }
                    RubberStampRisk = @{ ReviewerRisks = @() }
                }
            )

            $result = Measure-SPReviewerReputation -CampaignAudits $campaigns -MinCampaigns 2

            # Reviewer A (3 campaigns) should be included
            $reviewerA = $result.Reviewers | Where-Object { $_.ReviewerName -eq 'Reviewer A' }
            $reviewerA | Should -Not -BeNullOrEmpty

            # Reviewer B (1 campaign) should be excluded
            $reviewerB = $result.Reviewers | Where-Object { $_.ReviewerName -eq 'Reviewer B' }
            $reviewerB | Should -BeNullOrEmpty
        }

        It "Should calculate ReputationScore between 0 and 100" {
            $campaigns = @(
                @{
                    CampaignName   = 'Campaign 1'
                    Created        = '2026-01-15T00:00:00Z'
                    Decisions      = @{
                        Approved = @(
                            [PSCustomObject]@{ ReviewerName = 'Test Reviewer'; IdentityName = 'U1'; AccessName = 'E1' },
                            [PSCustomObject]@{ ReviewerName = 'Test Reviewer'; IdentityName = 'U2'; AccessName = 'E2' }
                        )
                        Revoked = @(
                            [PSCustomObject]@{ ReviewerName = 'Test Reviewer'; IdentityName = 'U3'; AccessName = 'E3' }
                        )
                        Pending = @()
                    }
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            @{ Name = 'Test Reviewer'; AvgHours = 8.0; MinHours = 2.0; MaxHours = 14.0 }
                        )
                    }
                    RubberStampRisk = @{ ReviewerRisks = @() }
                },
                @{
                    CampaignName   = 'Campaign 2'
                    Created        = '2026-02-15T00:00:00Z'
                    Decisions      = @{
                        Approved = @(
                            [PSCustomObject]@{ ReviewerName = 'Test Reviewer'; IdentityName = 'U4'; AccessName = 'E4' }
                        )
                        Revoked = @(
                            [PSCustomObject]@{ ReviewerName = 'Test Reviewer'; IdentityName = 'U5'; AccessName = 'E5' }
                        )
                        Pending = @()
                    }
                    ReviewerMetrics = @{
                        ReviewerMetrics = @(
                            @{ Name = 'Test Reviewer'; AvgHours = 6.0; MinHours = 2.0; MaxHours = 10.0 }
                        )
                    }
                    RubberStampRisk = @{ ReviewerRisks = @() }
                }
            )

            $result = Measure-SPReviewerReputation -CampaignAudits $campaigns -MinCampaigns 2
            $score = $result.Reviewers[0].ReputationScore
            $score | Should -BeGreaterOrEqual 0
            $score | Should -BeLessOrEqual 100
        }
    }
}

#endregion

#region P11-T14: Invoke-SPDailyOrchestrator.ps1 syntax validation

Describe "P11-T14: Invoke-SPDailyOrchestrator.ps1 syntax validation" {

    Context "When parsing the orchestrator script with the PowerShell AST parser" {
        It "Should have no parse errors" {
            $scriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDailyOrchestrator.ps1'
            $scriptPath | Should -Exist

            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$tokens, [ref]$parseErrors
            )

            $parseErrors | Should -BeNullOrEmpty
        }

        It "Should define a param block" {
            $scriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDailyOrchestrator.ps1'
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$tokens, [ref]$parseErrors
            )

            $paramBlock = $ast.ParamBlock
            $paramBlock | Should -Not -BeNullOrEmpty
        }

        It "Should define expected parameters" {
            $scriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDailyOrchestrator.ps1'
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$tokens, [ref]$parseErrors
            )

            $paramNames = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
            $paramNames | Should -Contain 'SourceId'
            $paramNames | Should -Contain 'SkipValidation'
            $paramNames | Should -Contain 'SkipDeltaCert'
            $paramNames | Should -Contain 'OutputMode'
        }
    }
}

#endregion
