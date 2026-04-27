#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.AuditQueries module
.DESCRIPTION
    Tests: AQ-001 through AQ-007
    Covers: campaign retrieval with name/date filters, certification retrieval with
    reviewer classification, pagination of certification items, campaign report API
    fallback handling, local CSV import, and identity event filtering.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    # Helper: build a minimal mock config with Audit section
    function New-MockAuditConfig {
        return [PSCustomObject]@{
            Api = [PSCustomObject]@{
                BaseUrl                    = 'https://test.api.identitynow.com/v3'
                TimeoutSeconds             = 30
                RetryCount                 = 1
                RetryDelaySeconds          = 1
                RateLimitRequestsPerWindow = 95
                RateLimitWindowSeconds     = 10
            }
            Audit = [PSCustomObject]@{
                DefaultDaysBack          = 30
                DefaultIdentityEventDays = 2
                DefaultStatuses          = @('COMPLETED', 'ACTIVE')
                IncludeCampaignReports   = $true
                IncludeIdentityEvents    = $true
            }
        }
    }
}

#region AQ-001: Get-SPAuditCampaigns filters by exact name

Describe "AQ-001: Get-SPAuditCampaigns filters campaigns by name" {

    Context "When filtering by exact campaign name" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries { New-MockAuditConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{
                            id      = 'camp-1'
                            name    = 'Q1 Review'
                            status  = 'COMPLETED'
                            created = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with matching campaigns" {
            $result = Get-SPAuditCampaigns -CampaignName 'Q1 Review' -DaysBack 30

            $result.Success        | Should -Be $true
            $result.Data.Count    | Should -Be 1
            $result.Data[0].name  | Should -Be 'Q1 Review'
        }

        It "Should call the /campaigns API endpoint with GET" {
            Get-SPAuditCampaigns -CampaignName 'Q1 Review'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.AuditQueries -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/campaigns'
            }
        }

        It "Should return Success=false when the API fails" {
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{ Success = $false; Data = $null; StatusCode = 503; Error = 'Service unavailable' }
            }

            $result = Get-SPAuditCampaigns -CampaignName 'Q1 Review'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'unavailable'
        }
    }
}

#endregion

#region AQ-002: Get-SPAuditCampaigns filters out old campaigns by DaysBack

Describe "AQ-002: Get-SPAuditCampaigns respects DaysBack cutoff" {

    Context "When the API returns a mix of recent and old campaigns" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries { New-MockAuditConfig }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{
                            id      = 'camp-recent'
                            name    = 'Recent Campaign'
                            status  = 'COMPLETED'
                            created = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        },
                        [PSCustomObject]@{
                            id      = 'camp-old'
                            name    = 'Old Campaign'
                            status  = 'COMPLETED'
                            created = (Get-Date).AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return only campaigns within the DaysBack window" {
            $result = Get-SPAuditCampaigns -Status @('COMPLETED') -DaysBack 30

            $result.Success | Should -Be $true
            $result.Data | Where-Object { $_.id -eq 'camp-recent' } | Should -Not -BeNullOrEmpty
        }

        It "Should exclude campaigns older than DaysBack" {
            $result = Get-SPAuditCampaigns -Status @('COMPLETED') -DaysBack 30

            $oldCamps = $result.Data | Where-Object { $_.id -eq 'camp-old' }
            $oldCamps | Should -BeNullOrEmpty
        }

        It "Should return empty data when all campaigns fall outside the window" {
            $result = Get-SPAuditCampaigns -Status @('COMPLETED') -DaysBack 2

            $result.Success    | Should -Be $true
            $result.Data.Count | Should -Be 0
        }
    }
}

#endregion

#region AQ-003: Get-SPAuditCertifications retrieves certs with reviewer classification

Describe "AQ-003: Get-SPAuditCertifications adds ReviewerClassification" {

    Context "When certifications have a mix of primary and reassigned reviewers" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{
                            id              = 'cert-primary'
                            name            = 'Alice Johnson'
                            campaignRef     = [PSCustomObject]@{ id = 'camp-1' }
                            reassignment    = $null
                        },
                        [PSCustomObject]@{
                            id              = 'cert-reassigned'
                            name            = 'Bob Smith'
                            campaignRef     = [PSCustomObject]@{ id = 'camp-1' }
                            reassignment    = [PSCustomObject]@{ from = [PSCustomObject]@{ id = 'cert-primary' } }
                        }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return Success=true with certifications" {
            $result = Get-SPAuditCertifications -CampaignId 'camp-1'

            $result.Success        | Should -Be $true
            $result.Data.Count    | Should -Be 2
        }

        It "Should classify certifications without reassignment as Primary" {
            $result = Get-SPAuditCertifications -CampaignId 'camp-1'

            $primary = $result.Data | Where-Object { $_.id -eq 'cert-primary' }
            $primary.ReviewerClassification | Should -Be 'Primary'
        }

        It "Should classify certifications with reassignment as Reassigned" {
            $result = Get-SPAuditCertifications -CampaignId 'camp-1'

            $reassigned = $result.Data | Where-Object { $_.id -eq 'cert-reassigned' }
            $reassigned.ReviewerClassification | Should -Be 'Reassigned'
        }

        It "Should call GET /certifications with the campaign id filter" {
            Get-SPAuditCertifications -CampaignId 'camp-1'

            Should -Invoke Invoke-SPApiRequest -ModuleName SP.AuditQueries -ParameterFilter {
                $Method -eq 'GET'
            }
        }
    }
}

#endregion

#region AQ-004: Get-SPAuditCertificationItems paginates correctly

Describe "AQ-004: Get-SPAuditCertificationItems auto-paginates" {

    Context "When the API returns a full page followed by a partial page" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            $script:AQPageCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:AQPageCallCount++

                if ($script:AQPageCallCount -eq 1) {
                    # First page: full page of 250
                    $items = 1..250 | ForEach-Object {
                        [PSCustomObject]@{ id = "item-p1-$_"; decision = 'APPROVE' }
                    }
                    return @{ Success = $true; StatusCode = 200; Data = $items; Error = $null }
                }
                else {
                    # Second page: 50 remaining items
                    $items = 1..50 | ForEach-Object {
                        [PSCustomObject]@{ id = "item-p2-$_"; decision = 'REVOKE' }
                    }
                    return @{ Success = $true; StatusCode = 200; Data = $items; Error = $null }
                }
            }
        }

        It "Should return all 300 items across both pages" {
            $result = Get-SPAuditCertificationItems -CertificationId 'cert-paginate-001'

            $result.Success        | Should -Be $true
            $result.Data.Count    | Should -Be 300
        }

        It "Should call the API at least twice (pagination)" {
            $script:AQPageCallCount = 0
            Get-SPAuditCertificationItems -CertificationId 'cert-paginate-001'

            $script:AQPageCallCount | Should -BeGreaterThan 1
        }

        It "Should include items from both pages in the result" {
            $result = Get-SPAuditCertificationItems -CertificationId 'cert-paginate-001'

            $firstPageItem  = $result.Data | Where-Object { $_.id -eq 'item-p1-1' }
            $secondPageItem = $result.Data | Where-Object { $_.id -eq 'item-p2-1' }

            $firstPageItem  | Should -Not -BeNullOrEmpty
            $secondPageItem | Should -Not -BeNullOrEmpty
        }
    }

    Context "When the API returns a single partial page" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $items = 1..15 | ForEach-Object { [PSCustomObject]@{ id = "item-$_" } }
                return @{ Success = $true; StatusCode = 200; Data = $items; Error = $null }
            }
        }

        It "Should return all items without extra API calls" {
            $result = Get-SPAuditCertificationItems -CertificationId 'cert-small'

            $result.Success        | Should -Be $true
            $result.Data.Count    | Should -Be 15
        }
    }

    # M2: pagination ceiling regression test for the audit-side paginator.
    # Cross-module coverage: SP.Certifications.Tests.ps1 covers the Cert
    # paginator; this covers SP.AuditQueries to verify the same pattern
    # applies in the audit module's Get-SPConfig resolution scope.
    Context "M2: When the audit-items API would return full pages indefinitely" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl                    = 'https://test.api.identitynow.com/v3'
                        MaxPaginationPages         = 4
                        TimeoutSeconds             = 30
                        RetryCount                 = 1
                        RetryDelaySeconds          = 1
                        RateLimitRequestsPerWindow = 95
                        RateLimitWindowSeconds     = 10
                    }
                }
            }

            $script:RunawayCallCount = 0
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                $script:RunawayCallCount++
                # Always return a full page (250) so the paginator would
                # otherwise loop forever.
                $items = 1..250 | ForEach-Object {
                    [PSCustomObject]@{ id = "runaway-p$($script:RunawayCallCount)-$_" }
                }
                return @{ Success = $true; StatusCode = 200; Data = $items; Error = $null }
            }
        }

        It "Should abort after MaxPaginationPages with a ceiling error" {
            $script:RunawayCallCount = 0
            $result = Get-SPAuditCertificationItems -CertificationId 'cert-runaway'

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'Pagination ceiling reached'
            $script:RunawayCallCount | Should -Be 4
        }
    }
}

#endregion

#region AQ-005: Get-SPAuditCampaignReport handles legacy API unavailability

Describe "AQ-005: Get-SPAuditCampaignReport handles unavailable report API" {

    Context "When the reports endpoint returns a task ID" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{ BaseUrl = 'https://test.api.identitynow.com/v3' }
                    Authentication = [PSCustomObject]@{
                        ConfigFile = [PSCustomObject]@{ TenantUrl = 'https://test.api.identitynow.com' }
                    }
                }
            }
            Mock Get-SPAuthToken -ModuleName SP.AuditQueries {
                return @{ Success = $true; Data = @{ Token = 'mock-token' }; Error = $null }
            }
            Mock Invoke-RestMethod -ModuleName SP.AuditQueries {
                throw [System.Net.WebException]::new('404 Not Found')
            }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                if ($Endpoint -like '*/reports*') {
                    return @{
                        Success    = $true
                        StatusCode = 200
                        Data       = @([PSCustomObject]@{ type = 'CAMPAIGN_STATUS_REPORT'; taskResultId = 'task-abc-123'; status = 'SUCCESS' })
                        Error      = $null
                    }
                }
                return @{ Success = $false; StatusCode = 404; Data = $null; Error = 'Not Found' }
            }
        }

        It "Should return a result indicating the report was not available" {
            $result = Get-SPAuditCampaignReport -CampaignId 'camp-report-001' -ReportType 'CAMPAIGN_STATUS_REPORT'
            $result | Should -Not -BeNullOrEmpty
            $result.Success | Should -Be $false
        }

        It "Should not throw a terminating exception on 404" {
            { Get-SPAuditCampaignReport -CampaignId 'camp-report-001' -ReportType 'CAMPAIGN_STATUS_REPORT' } | Should -Not -Throw
        }
    }

    Context "When the reports endpoint is completely unavailable (503)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Get-SPConfig -ModuleName SP.AuditQueries {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{ BaseUrl = 'https://test.api.identitynow.com/v3' }
                    Authentication = [PSCustomObject]@{
                        ConfigFile = [PSCustomObject]@{ TenantUrl = 'https://test.api.identitynow.com' }
                    }
                }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                return @{ Success = $false; StatusCode = 503; Data = $null; Error = 'Service Unavailable' }
            }
        }

        It "Should return Success=false with an appropriate error message" {
            $result = Get-SPAuditCampaignReport -CampaignId 'camp-down' -ReportType 'CAMPAIGN_STATUS_REPORT'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

#region AQ-006: Import-SPAuditCampaignReport reads local CSV files

Describe "AQ-006: Import-SPAuditCampaignReport reads and parses local CSV" {

    Context "When a valid campaign report CSV exists" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }

            $script:AQTestDir = Join-Path $TestDrive 'aq-006'
            $null = New-Item -ItemType Directory -Path $script:AQTestDir -Force

            # Write status report CSV with a filename matching the *Status*Report*.csv pattern
            $statusCsv = @"
Reviewer,Reviewee,Access Item,Access Type,Decision,Comments,Completed
Alice Johnson,Bob Smith,AD_Users,Entitlement,APPROVE,Reviewed and approved,2026-02-10T10:00:00Z
Carol Davis,Dave Lee,AD_Admins,Entitlement,REVOKE,Excessive access,2026-02-10T10:05:00Z
"@
            [System.IO.File]::WriteAllText((Join-Path $script:AQTestDir 'CampaignStatusReport.csv'), $statusCsv, [System.Text.Encoding]::UTF8)
        }

        It "Should return Success=true" {
            $result = Import-SPAuditCampaignReport -CsvDirectoryPath $script:AQTestDir
            $result.Success | Should -Be $true
        }

        It "Should return data with StatusReport" {
            $result = Import-SPAuditCampaignReport -CsvDirectoryPath $script:AQTestDir
            $result.Data.StatusReport | Should -Not -BeNullOrEmpty
        }

        It "Should parse the Decision column correctly" {
            $result = Import-SPAuditCampaignReport -CsvDirectoryPath $script:AQTestDir
            $approveRow = @($result.Data.StatusReport) | Where-Object { $_.Decision -eq 'APPROVE' }
            $revokeRow  = @($result.Data.StatusReport) | Where-Object { $_.Decision -eq 'REVOKE' }
            $approveRow | Should -Not -BeNullOrEmpty
            $revokeRow  | Should -Not -BeNullOrEmpty
        }

        It "Should return Success=false when the directory does not exist" {
            $result = Import-SPAuditCampaignReport -CsvDirectoryPath (Join-Path $script:AQTestDir 'nonexistent-dir')
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

#region AQ-007: Get-SPAuditIdentityEvents filters by date and resolves source names

Describe "AQ-007: Get-SPAuditIdentityEvents filters events and resolves source names" {

    Context "When identity events are returned with source IDs" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
            Mock Invoke-SPApiRequest -ModuleName SP.AuditQueries {
                if ($Endpoint -like '*/sources/*') {
                    # Source name resolution call
                    return @{
                        Success    = $true
                        StatusCode = 200
                        Data       = [PSCustomObject]@{ id = 'src-001'; name = 'Active Directory' }
                        Error      = $null
                    }
                }

                # Identity event search
                $recentDate  = (Get-Date).AddHours(-12).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $oldDate     = (Get-Date).AddDays(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{
                            id        = 'evt-recent'
                            operation = 'REMOVE'
                            created   = $recentDate
                            sourceId  = 'src-001'
                            items     = @(
                                [PSCustomObject]@{ sourceId = 'src-001'; operation = 'REMOVE' }
                            )
                        },
                        [PSCustomObject]@{
                            id        = 'evt-old'
                            operation = 'REMOVE'
                            created   = $oldDate
                            sourceId  = 'src-001'
                            items     = @(
                                [PSCustomObject]@{ sourceId = 'src-001'; operation = 'REMOVE' }
                            )
                        }
                    )
                    Error      = $null
                }
            }
        }

        It "Should return Success=true" {
            $result = Get-SPAuditIdentityEvents `
                -IdentityId 'id-alice-001' `
                -DaysBack 2

            $result.Success | Should -Be $true
        }

        It "Should filter out events older than DaysBack" {
            $result = Get-SPAuditIdentityEvents `
                -IdentityId 'id-alice-001' `
                -DaysBack 2

            $oldEvt = $result.Data | Where-Object { $_.id -eq 'evt-old' }
            $oldEvt | Should -BeNullOrEmpty
        }

        It "Should include recent events within DaysBack" {
            $result = Get-SPAuditIdentityEvents `
                -IdentityId 'id-alice-001' `
                -DaysBack 2

            $recentEvt = $result.Data | Where-Object { $_.id -eq 'evt-recent' }
            $recentEvt | Should -Not -BeNullOrEmpty
        }

        It "Should resolve source names from source IDs" {
            $result = Get-SPAuditIdentityEvents `
                -IdentityId 'id-alice-001' `
                -DaysBack 2

            if ($result.Data.Count -gt 0) {
                $evt = $result.Data[0]
                $evt.ResolvedSourceNames | Should -Not -BeNullOrEmpty
            }
        }
    }
}

#endregion
