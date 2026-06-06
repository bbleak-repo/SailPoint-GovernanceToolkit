#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Phase 12 Operational Intelligence features
.DESCRIPTION
    Tests: P12-T01 through P12-T16
    Covers: compliance evidence packaging, identity risk scoring, source governance
    scorecard, stale access detection, campaign completion reports, notification
    dispatch, orchestrator history, weekly digest syntax, and log retention.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit
}

#region P12-T01: Export-SPCompliancePackage creates ZIP with manifest.json containing artifact hashes

Describe "P12-T01: Export-SPCompliancePackage creates ZIP with manifest.json containing artifact hashes" {

    Context "When audit and deltacert directories contain artifacts" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Audit     = [PSCustomObject]@{ OutputPath = (Join-Path $TestDrive 'pkg-audit') }
                    DeltaCert = [PSCustomObject]@{ OutputPath = (Join-Path $TestDrive 'pkg-dc') }
                    Global    = [PSCustomObject]@{ ToolkitVersion = '1.0.0-test' }
                }
            }

            # Create test directories and artifacts
            $script:auditDir = Join-Path $TestDrive 'pkg-audit'
            $script:dcDir    = Join-Path $TestDrive 'pkg-dc'
            $script:outDir   = Join-Path $TestDrive 'pkg-out'
            $null = New-Item -ItemType Directory -Path $script:auditDir -Force
            $null = New-Item -ItemType Directory -Path $script:dcDir -Force
            $null = New-Item -ItemType Directory -Path $script:outDir -Force

            # Leadership subdirectory
            $script:leaderDir = Join-Path $script:auditDir 'leadership'
            $null = New-Item -ItemType Directory -Path $script:leaderDir -Force

            # Audit artifacts
            [System.IO.File]::WriteAllText((Join-Path $script:auditDir 'report.html'), '<html>audit report</html>')
            [System.IO.File]::WriteAllText((Join-Path $script:auditDir 'export.csv'), 'col1,col2')
            [System.IO.File]::WriteAllText((Join-Path $script:auditDir 'trail.jsonl'), '{"action":"test"}')
            [System.IO.File]::WriteAllText((Join-Path $script:leaderDir 'leader.html'), '<html>leadership</html>')

            # DeltaCert artifacts
            [System.IO.File]::WriteAllText((Join-Path $script:dcDir 'delta.html'), '<html>delta</html>')
            [System.IO.File]::WriteAllText((Join-Path $script:dcDir 'delta.jsonl'), '{"action":"delta"}')

            Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

            $script:result = Export-SPCompliancePackage `
                -AuditOutputPath $script:auditDir `
                -DeltaCertOutputPath $script:dcDir `
                -OutputPath $script:outDir `
                -PackageName 'test-evidence'
        }

        It "Should return Success true" {
            $script:result.Success | Should -Be $true
        }

        It "Should create a ZIP file" {
            Test-Path $script:result.Data.PackagePath | Should -Be $true
            $script:result.Data.PackagePath | Should -BeLike '*.zip'
        }

        It "Should include a PackageId GUID" {
            $script:result.Data.PackageId | Should -Not -BeNullOrEmpty
            { [guid]::Parse($script:result.Data.PackageId) } | Should -Not -Throw
        }

        It "Should count all artifacts" {
            $script:result.Data.ArtifactCount | Should -BeGreaterOrEqual 5
        }

        It "Should contain manifest.json with SHA256 hashes" {
            $zipPath = $script:result.Data.PackagePath
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $manifestEntry = $zip.Entries | Where-Object { $_.Name -eq 'manifest.json' }
                $manifestEntry | Should -Not -BeNullOrEmpty

                $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
                $manifestJson = $reader.ReadToEnd()
                $reader.Close()

                $manifest = $manifestJson | ConvertFrom-Json
                $manifest.PackageId | Should -Not -BeNullOrEmpty
                $manifest.Artifacts | Should -Not -BeNullOrEmpty
                $manifest.Artifacts[0].SHA256 | Should -Not -BeNullOrEmpty
            } finally {
                $zip.Dispose()
            }
        }
    }
}

#endregion

#region P12-T02: Export-SPCompliancePackage -Scope AuditOnly excludes DeltaCert artifacts

Describe "P12-T02: Export-SPCompliancePackage -Scope AuditOnly excludes DeltaCert artifacts" {

    Context "When Scope is AuditOnly" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Audit     = [PSCustomObject]@{ OutputPath = (Join-Path $TestDrive 'scope-audit') }
                    DeltaCert = [PSCustomObject]@{ OutputPath = (Join-Path $TestDrive 'scope-dc') }
                    Global    = [PSCustomObject]@{ ToolkitVersion = '1.0.0-test' }
                }
            }

            $script:auditDir2 = Join-Path $TestDrive 'scope-audit'
            $script:dcDir2    = Join-Path $TestDrive 'scope-dc'
            $script:outDir2   = Join-Path $TestDrive 'scope-out'
            $null = New-Item -ItemType Directory -Path $script:auditDir2 -Force
            $null = New-Item -ItemType Directory -Path $script:dcDir2 -Force
            $null = New-Item -ItemType Directory -Path $script:outDir2 -Force

            [System.IO.File]::WriteAllText((Join-Path $script:auditDir2 'audit-only.html'), '<html>audit</html>')
            [System.IO.File]::WriteAllText((Join-Path $script:dcDir2 'delta-excluded.html'), '<html>delta</html>')

            Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

            $script:scopeResult = Export-SPCompliancePackage `
                -AuditOutputPath $script:auditDir2 `
                -DeltaCertOutputPath $script:dcDir2 `
                -OutputPath $script:outDir2 `
                -PackageName 'audit-only-test' `
                -Scope AuditOnly
        }

        It "Should return Success true" {
            $script:scopeResult.Success | Should -Be $true
        }

        It "Should not contain DeltaCert artifacts in the ZIP" {
            $zipPath = $script:scopeResult.Data.PackagePath
            $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $dcEntries = $zip.Entries | Where-Object { $_.FullName -like 'deltacert/*' }
                $dcEntries | Should -BeNullOrEmpty

                # Also check manifest for DeltaCert category
                $manifestEntry = $zip.Entries | Where-Object { $_.Name -eq 'manifest.json' }
                $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
                $manifest = ($reader.ReadToEnd()) | ConvertFrom-Json
                $reader.Close()

                $dcArtifacts = $manifest.Artifacts | Where-Object { $_.Category -eq 'DeltaCert' }
                $dcArtifacts | Should -BeNullOrEmpty
            } finally {
                $zip.Dispose()
            }
        }
    }
}

#endregion

#region P12-T03: Measure-SPIdentityRisk scores identity with 2 privileged + 3 stale higher than 1 each

Describe "P12-T03: Measure-SPIdentityRisk scores identity with 2 privileged + 3 stale higher than 1 each" {

    Context "When comparing two identities with different risk profiles" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
        }

        It "Should score the identity with more risk signals higher" {
            # Identity A: 2 privileged + 3 stale items
            # Identity B: 1 privileged + 1 stale item
            $campaignAudit = @{
                CampaignId   = 'camp-risk-001'
                CampaignName = 'Risk Test Campaign'
                Decisions    = @{
                    Approved = @(
                        # Identity A: 2 privileged + 3 stale
                        @{ IdentityId = 'id-A'; IdentityName = 'Alice High'; AccessName = 'PrivRole1'; AccessType = 'role'; ReviewerName = 'Rev1'; DecisionDate = '2026-05-01'; RiskFlags = @('PRIVILEGED', 'STALE') }
                        @{ IdentityId = 'id-A'; IdentityName = 'Alice High'; AccessName = 'PrivRole2'; AccessType = 'role'; ReviewerName = 'Rev1'; DecisionDate = '2026-05-01'; RiskFlags = @('PRIVILEGED', 'STALE') }
                        @{ IdentityId = 'id-A'; IdentityName = 'Alice High'; AccessName = 'StaleApp';  AccessType = 'entitlement'; ReviewerName = 'Rev1'; DecisionDate = '2026-05-01'; RiskFlags = @('STALE') }
                        # Identity B: 1 privileged + 1 stale
                        @{ IdentityId = 'id-B'; IdentityName = 'Bob Low'; AccessName = 'PrivRole3'; AccessType = 'role'; ReviewerName = 'Rev2'; DecisionDate = '2026-05-01'; RiskFlags = @('PRIVILEGED') }
                        @{ IdentityId = 'id-B'; IdentityName = 'Bob Low'; AccessName = 'StaleItem'; AccessType = 'entitlement'; ReviewerName = 'Rev2'; DecisionDate = '2026-05-01'; RiskFlags = @('STALE') }
                    )
                    Revoked  = @()
                    Pending  = @()
                }
                ReviewerMetrics   = @{}
                RubberStampRisk   = @{ Reviewers = @() }
                RemediationStatus = @{}
            }

            $result = Measure-SPIdentityRisk -CampaignAudits @($campaignAudit)

            $identityA = $result.Identities | Where-Object { $_.IdentityId -eq 'id-A' }
            $identityB = $result.Identities | Where-Object { $_.IdentityId -eq 'id-B' }

            $identityA | Should -Not -BeNullOrEmpty
            $identityB | Should -Not -BeNullOrEmpty

            # A has 2 priv (+30) + 3 stale (+20 capped) = higher than B with 1 priv (+15) + 1 stale (+10)
            $identityA.RiskScore | Should -BeGreaterThan $identityB.RiskScore
            $identityA.PrivilegedAccessCount | Should -Be 2
            $identityA.StaleAccessCount | Should -Be 3
            $identityB.PrivilegedAccessCount | Should -Be 1
            $identityB.StaleAccessCount | Should -Be 1
        }
    }
}

#endregion

#region P12-T04: Measure-SPIdentityRisk returns empty summary for empty campaign input

Describe "P12-T04: Measure-SPIdentityRisk returns empty summary for empty campaign input" {

    Context "When no campaigns are provided" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
        }

        It "Should return empty identities array" {
            $result = Measure-SPIdentityRisk -CampaignAudits @()
            $result.Identities | Should -BeNullOrEmpty
        }

        It "Should return summary with all zeros" {
            $result = Measure-SPIdentityRisk -CampaignAudits @()
            $result.Summary.TotalIdentities | Should -Be 0
            $result.Summary.High | Should -Be 0
            $result.Summary.Medium | Should -Be 0
            $result.Summary.Low | Should -Be 0
        }
    }
}

#endregion

#region P12-T05: Measure-SPSourceGovernance assigns Grade A to source with 100% coverage and recent review

Describe "P12-T05: Measure-SPSourceGovernance assigns Grade A to source with 100% coverage and recent review" {

    Context "When source has full coverage, recent review, and multiple campaigns" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
        }

        It "Should assign Grade A" {
            $recentDate = (Get-Date).AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')

            # Build campaigns that cover all entitlements across 4 campaigns
            $campaigns = @()
            for ($i = 1; $i -le 4; $i++) {
                $campaigns += @{
                    CampaignId   = "camp-gov-00$i"
                    CampaignName = "Gov Campaign $i"
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-1'; IdentityName = 'User1'; AccessName = 'Ent-A'; AccessType = 'entitlement'; SourceId = 'src-gradeA'; SourceName = 'Perfect Source'; ReviewerName = 'Rev1'; DecisionDate = $recentDate; RiskFlags = @() }
                            @{ IdentityId = 'id-2'; IdentityName = 'User2'; AccessName = 'Ent-B'; AccessType = 'entitlement'; SourceId = 'src-gradeA'; SourceName = 'Perfect Source'; ReviewerName = 'Rev1'; DecisionDate = $recentDate; RiskFlags = @('PRIVILEGED') }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            }

            # Inventory shape must match what Get-SPEntitlementInventory actually emits:
            # both the integer counts (TotalEntitlements, Privileged) and the detail array.
            # Measure-SPSourceGovernance reads the counts, not the array.
            $inventory = @{
                Sources = @{
                    'src-gradeA' = @{
                        SourceId          = 'src-gradeA'
                        SourceName        = 'Perfect Source'
                        TotalEntitlements = 2
                        Privileged        = 1
                        Entitlements      = @(
                            @{ Name = 'Ent-A'; Privileged = $false }
                            @{ Name = 'Ent-B'; Privileged = $true }
                        )
                    }
                }
            }

            $result = Measure-SPSourceGovernance -CampaignAudits $campaigns -EntitlementInventory $inventory

            $source = $result.Sources | Where-Object { $_.SourceId -eq 'src-gradeA' }
            $source | Should -Not -BeNullOrEmpty
            $source.GovernanceGrade | Should -Be 'A'
            $source.EntitlementCoveragePct | Should -Be 100.0
            $source.PrivilegedReviewedPct | Should -Be 100.0
        }
    }
}

#endregion

#region P12-T06: Measure-SPSourceGovernance assigns Grade F to source with 0 campaigns

Describe "P12-T06: Measure-SPSourceGovernance assigns Grade F to source with 0 campaigns" {

    Context "When source is in inventory but has never been reviewed" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditAnalytics { }
        }

        It "Should assign Grade F" {
            # Campaign that reviews a different source
            $campaigns = @(
                @{
                    CampaignId   = 'camp-other'
                    CampaignName = 'Other Campaign'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-1'; IdentityName = 'User1'; AccessName = 'Ent-X'; AccessType = 'entitlement'; SourceId = 'src-other'; SourceName = 'Other Source'; ReviewerName = 'Rev1'; DecisionDate = '2026-05-01'; RiskFlags = @() }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            )

            # Same canonical shape as P12-T05: include integer counts that
            # Measure-SPSourceGovernance actually reads (test passes today by
            # luck because Grade F is the all-zeros fallback either way).
            $inventory = @{
                Sources = @{
                    'src-never' = @{
                        SourceId          = 'src-never'
                        SourceName        = 'Never Reviewed Source'
                        TotalEntitlements = 2
                        Privileged        = 1
                        Entitlements      = @(
                            @{ Name = 'Ent-1'; Privileged = $false }
                            @{ Name = 'Ent-2'; Privileged = $true }
                        )
                    }
                }
            }

            $result = Measure-SPSourceGovernance -CampaignAudits $campaigns -EntitlementInventory $inventory

            $source = $result.Sources | Where-Object { $_.SourceId -eq 'src-never' }
            $source | Should -Not -BeNullOrEmpty
            $source.GovernanceGrade | Should -Be 'F'
            $source.CampaignCount | Should -Be 0
            $source.GovernanceScore | Should -BeLessThan 40
        }
    }
}

#endregion

#region P12-T07: Get-SPStaleAccess classifies entitlement in inventory but not in campaigns as NeverReviewed

Describe "P12-T07: Get-SPStaleAccess classifies inventory-only entitlement as NeverReviewed" {

    Context "When entitlement exists in inventory but has no campaign decisions" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
        }

        It "Should classify as NeverReviewed" {
            $campaigns = @(
                @{
                    CampaignId   = 'camp-stale-001'
                    CampaignName = 'Stale Test Campaign'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-1'; IdentityName = 'User1'; AccessName = 'Ent-Reviewed'; AccessType = 'entitlement'; SourceId = 'src-s1'; SourceName = 'Source One'; ReviewerName = 'Rev1'; DecisionDate = '2026-05-01'; RiskFlags = @() }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            )

            $inventory = @{
                Sources = @{
                    'src-s1' = @{
                        SourceId     = 'src-s1'
                        SourceName   = 'Source One'
                        Entitlements = @(
                            @{ Name = 'Ent-Reviewed'; Privileged = $false }
                            @{ Name = 'Ent-Orphan';   Privileged = $false }
                        )
                    }
                }
            }

            $result = Get-SPStaleAccess -CampaignAudits $campaigns -EntitlementInventory $inventory

            $neverReviewed = $result.StaleItems | Where-Object {
                $_.EntitlementName -eq 'Ent-Orphan' -and $_.Classification -eq 'NeverReviewed'
            }
            $neverReviewed | Should -Not -BeNullOrEmpty
            $neverReviewed.LastReviewDate | Should -BeNullOrEmpty
            $result.Summary.NeverReviewed | Should -BeGreaterOrEqual 1
        }
    }
}

#endregion

#region P12-T08: Get-SPStaleAccess classifies entitlement reviewed 200 days ago as Expired (StaleDays=180)

Describe "P12-T08: Get-SPStaleAccess classifies entitlement reviewed 200 days ago as Expired" {

    Context "When last review was 200 days ago and StaleDays is 180" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditQueries { }
        }

        It "Should classify as Expired" {
            $oldDate = (Get-Date).AddDays(-200).ToString('yyyy-MM-ddTHH:mm:ssZ')

            $campaigns = @(
                @{
                    CampaignId   = 'camp-expired-001'
                    CampaignName = 'Old Campaign'
                    Decisions    = @{
                        Approved = @(
                            @{ IdentityId = 'id-1'; IdentityName = 'User1'; AccessName = 'Ent-Old'; AccessType = 'entitlement'; SourceId = 'src-exp'; SourceName = 'Expiry Source'; ReviewerName = 'Rev1'; DecisionDate = $oldDate; RiskFlags = @() }
                        )
                        Revoked = @()
                        Pending = @()
                    }
                }
            )

            $result = Get-SPStaleAccess -CampaignAudits $campaigns -StaleDays 180

            $expired = $result.StaleItems | Where-Object {
                $_.EntitlementName -eq 'Ent-Old' -and $_.Classification -eq 'Expired'
            }
            $expired | Should -Not -BeNullOrEmpty
            $expired.DaysSinceReview | Should -BeGreaterOrEqual 200
            $result.Summary.Expired | Should -BeGreaterOrEqual 1
        }
    }
}

#endregion

#region P12-T09: Export-SPCampaignCompletionReport generates HTML with all 6 sections

Describe "P12-T09: Export-SPCampaignCompletionReport generates HTML with all 6 sections" {

    Context "When given a full campaign audit with remediation and prior cycle" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReportHtml { }

            $script:completionDir = Join-Path $TestDrive 'completion-t09'
            $null = New-Item -ItemType Directory -Path $script:completionDir -Force

            $campaignAudit = @{
                CampaignId   = 'camp-comp-001'
                CampaignName = 'Q2 Access Review'
                CampaignType = 'MANAGER'
                Status       = 'COMPLETED'
                Created      = '2026-04-01T00:00:00Z'
                Completed    = '2026-05-01T00:00:00Z'
                Deadline     = '2026-05-15T00:00:00Z'
                Decisions    = @{
                    Approved = @(
                        @{ IdentityId = 'id-1'; IdentityName = 'User1'; AccessName = 'App1'; AccessType = 'entitlement'; ReviewerName = 'Manager1'; DecisionDate = '2026-04-15T10:00:00Z'; RiskFlags = @('PRIVILEGED') }
                        @{ IdentityId = 'id-2'; IdentityName = 'User2'; AccessName = 'App2'; AccessType = 'entitlement'; ReviewerName = 'Manager1'; DecisionDate = '2026-04-16T14:00:00Z'; RiskFlags = @() }
                    )
                    Revoked = @(
                        @{ IdentityId = 'id-3'; IdentityName = 'User3'; AccessName = 'OldApp'; AccessType = 'entitlement'; ReviewerName = 'Manager2'; DecisionDate = '2026-04-17T08:00:00Z'; RiskFlags = @('STALE') }
                    )
                    Pending = @()
                }
                # Shape must match what Measure-SPAuditReviewerMetrics emits:
                # outer key is ReviewerMetrics (not Reviewers); inner fields are
                # Name / TotalItems / DecisionsMade / AvgHours.
                ReviewerMetrics = @{
                    CampaignAvgHours = 18.5
                    ReviewerMetrics  = @(
                        @{ Name = 'Manager1'; TotalItems = 2; DecisionsMade = 2; AvgHours = 12.0 }
                        @{ Name = 'Manager2'; TotalItems = 1; DecisionsMade = 1; AvgHours = 24.0 }
                    )
                }
                # Rubber-stamp outer key is ReviewerRisks (not Reviewers).
                RubberStampRisk = @{
                    ReviewerRisks = @(
                        @{ Name = 'Manager1'; Severity = 'Low'; Score = 0.2 }
                    )
                }
                RiskFlags = @{
                    PRIVILEGED = 1
                    STALE      = 1
                }
            }

            $remediationStatus = @{
                Items = @(
                    @{ AccessName = 'OldApp'; Status = 'Provisioned'; DaysToRemediate = 3 }
                )
                SLACompliancePct = 100.0
                AvgDaysToRemediate = 3.0
            }

            $script:compResult = Export-SPCampaignCompletionReport `
                -CampaignAudit $campaignAudit `
                -RemediationStatus $remediationStatus `
                -OutputPath $script:completionDir
        }

        It "Should return Success true" {
            $script:compResult.Success | Should -Be $true
        }

        It "Should create an HTML file" {
            $script:compResult.Data.ReportPath | Should -Not -BeNullOrEmpty
            Test-Path $script:compResult.Data.ReportPath | Should -Be $true
        }

        It "Should contain all 6 sections in the HTML" {
            $html = Get-Content -Path $script:compResult.Data.ReportPath -Raw

            # Section 1: Campaign overview
            $html | Should -Match 'Q2 Access Review'

            # Section 2: KPI dashboard
            $html | Should -Match '(?i)completion.*rate|KPI'

            # Section 3: Cycle comparison (should mention no prior cycle or comparison)
            # When no PreviousCycleAudit, shows "no prior cycle" or comparison section header
            $html | Should -Match '(?i)compar|prior|cycle'

            # Section 4: Reviewer scorecard
            $html | Should -Match 'Manager1'
            $html | Should -Match 'Manager2'

            # Section 5: Remediation tracking
            $html | Should -Match '(?i)remediat'

            # Section 6: Risk summary
            $html | Should -Match '(?i)PRIVILEGED|risk'
        }

        It "Should calculate correct KPIs" {
            $script:compResult.Data.CampaignName | Should -Be 'Q2 Access Review'
            $script:compResult.Data.KPIs.OnTimeCompletion | Should -Be $true
        }
    }
}

#endregion

#region P12-T10: Send-SPNotification with Backends=['Log'] only logs, no HTTP calls

Describe "P12-T10: Send-SPNotification with Backends=['Log'] only logs, no HTTP calls" {

    Context "When only Log backend is configured" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Notification = [PSCustomObject]@{
                        Backends = @('Log')
                        Smtp     = [PSCustomObject]@{
                            Server = ''
                            Port   = 587
                            From   = ''
                            UseSsl = $true
                        }
                        Webhook  = [PSCustomObject]@{
                            Url            = ''
                            Method         = 'POST'
                            Headers        = @{}
                            IncludePayload = $true
                        }
                    }
                }
            }
            Mock Send-MailMessage -ModuleName SP.AuditOperations { }
            Mock Invoke-RestMethod -ModuleName SP.AuditOperations { }
        }

        It "Should return Success true with Log backend sent" {
            $result = Send-SPNotification -Subject 'Test Alert' -Body 'Test body'
            $result.Success | Should -Be $true

            $logBackend = $result.Data.Backends | Where-Object { $_.Backend -eq 'Log' }
            $logBackend | Should -Not -BeNullOrEmpty
            $logBackend.Status | Should -Be 'Sent'
        }

        It "Should NOT call Send-MailMessage" {
            Send-SPNotification -Subject 'Test Alert' -Body 'Test body'
            Should -Invoke Send-MailMessage -ModuleName SP.AuditOperations -Times 0 -Exactly
        }

        It "Should NOT call Invoke-RestMethod" {
            Send-SPNotification -Subject 'Test Alert' -Body 'Test body'
            Should -Invoke Invoke-RestMethod -ModuleName SP.AuditOperations -Times 0 -Exactly
        }
    }
}

#endregion

#region P12-T11: Send-SPWebhook sends JSON POST and returns status code

Describe "P12-T11: Send-SPWebhook sends JSON POST and returns status code" {

    Context "When sending a webhook payload" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Invoke-RestMethod -ModuleName SP.AuditOperations {
                return @{ ok = $true }
            }
        }

        It "Should return Success true" {
            $result = Send-SPWebhook -Url 'https://hooks.example.com/test' `
                -Payload @{ text = 'Hello'; severity = 'Info' }

            $result.Success | Should -Be $true
        }

        It "Should call Invoke-RestMethod with JSON content type" {
            Send-SPWebhook -Url 'https://hooks.example.com/test' `
                -Payload @{ text = 'Hello' }

            Should -Invoke Invoke-RestMethod -ModuleName SP.AuditOperations -Times 1 -Exactly `
                -ParameterFilter {
                    $Uri -eq 'https://hooks.example.com/test' -and
                    $Method -eq 'POST' -and
                    $ContentType -eq 'application/json'
                }
        }

        It "Should return the response object" {
            $result = Send-SPWebhook -Url 'https://hooks.example.com/test' `
                -Payload @{ text = 'Hello' }

            $result.Response | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

#region P12-T12: Get-SPOrchestratorHistory parses JSONL and calculates correct SuccessRate

Describe "P12-T12: Get-SPOrchestratorHistory parses JSONL and calculates correct SuccessRate" {

    Context "When JSONL contains mixed exit codes" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        OutputPath = (Join-Path $TestDrive 'orch-t12')
                    }
                }
            }

            $script:orchDir = Join-Path $TestDrive 'orch-t12'
            $null = New-Item -ItemType Directory -Path $script:orchDir -Force

            # Build 10 runs: 7 success (exit 0), 2 warnings (exit 1), 1 critical (exit 5)
            $lines = @()
            for ($i = 0; $i -lt 10; $i++) {
                $ts = (Get-Date).AddDays(-$i).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $exitCode = if ($i -lt 7) { 0 } elseif ($i -lt 9) { 1 } else { 5 }
                $entry = @{
                    Timestamp = $ts
                    Action    = 'OrchestratorRun'
                    Data      = @{
                        ExitCode        = $exitCode
                        DurationSeconds = 120 + ($i * 5)
                        WhatIf          = $false
                        Steps           = @{
                            Validation = @{ Status = 'Success' }
                            Cleanup    = @{ Status = 'Success' }
                            DeltaCert  = @{ Status = if ($exitCode -eq 0) { 'Success' } else { 'Failed' } }
                            DeltaReport = @{ Status = 'Success' }
                            Escalation  = @{ Status = 'Success' }
                            HealthCheck = @{ Status = 'Success' }
                        }
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $lines += $entry
            }

            $journalPath = Join-Path $script:orchDir 'orchestrator-audit.jsonl'
            [System.IO.File]::WriteAllText($journalPath, ($lines -join "`n"))

            $script:orchResult = Get-SPOrchestratorHistory -JournalPath $journalPath -DaysBack 30
        }

        It "Should parse all 10 runs" {
            $script:orchResult.Metrics.RunCount | Should -Be 10
        }

        It "Should calculate SuccessRate as 70.0" {
            # 7 out of 10 runs had exit code 0
            $script:orchResult.Metrics.SuccessRate | Should -Be 70.0
        }

        It "Should track failure breakdown" {
            $script:orchResult.Metrics.FailureBreakdown | Should -Not -BeNullOrEmpty
        }

        It "Should report consecutive failures as 0 (most recent runs are success)" {
            $script:orchResult.Metrics.ConsecutiveFailures | Should -Be 0
        }
    }
}

#endregion

#region P12-T13: Get-SPOrchestratorHistory returns empty metrics for missing JSONL file

Describe "P12-T13: Get-SPOrchestratorHistory returns empty metrics for missing JSONL file" {

    Context "When JSONL file does not exist" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    DeltaCert = [PSCustomObject]@{
                        OutputPath = (Join-Path $TestDrive 'orch-missing')
                    }
                }
            }
        }

        It "Should return RunCount 0" {
            $result = Get-SPOrchestratorHistory -JournalPath (Join-Path $TestDrive 'nonexistent.jsonl')
            $result.Metrics.RunCount | Should -Be 0
        }

        It "Should return SuccessRate 0" {
            $result = Get-SPOrchestratorHistory -JournalPath (Join-Path $TestDrive 'nonexistent.jsonl')
            $result.Metrics.SuccessRate | Should -Be 0
        }

        It "Should return empty Runs array" {
            $result = Get-SPOrchestratorHistory -JournalPath (Join-Path $TestDrive 'nonexistent.jsonl')
            $result.Runs.Count | Should -Be 0
        }
    }
}

#endregion

#region P12-T14: Invoke-SPWeeklyDigest.ps1 syntax validation (PS AST parser)

Describe "P12-T14: Invoke-SPWeeklyDigest.ps1 syntax validation" {

    Context "When parsing the script with the PowerShell AST" {
        BeforeAll {
            $script:digestScript = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPWeeklyDigest.ps1'
        }

        It "Should exist on disk" {
            Test-Path $script:digestScript | Should -Be $true
        }

        It "Should parse without syntax errors" {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:digestScript, [ref]$tokens, [ref]$errors
            )
            $errors.Count | Should -Be 0
        }

        It "Should define expected parameters and support -WhatIf via SupportsShouldProcess" {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:digestScript, [ref]$null, [ref]$null
            )
            $params = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath

            $params | Should -Contain 'DaysBack'
            $params | Should -Contain 'OutputMode'
            $params | Should -Contain 'SendNotification'
            $params | Should -Contain 'Help'

            # -WhatIf is provided automatically by [CmdletBinding(SupportsShouldProcess)].
            # Declaring an explicit [switch]$WhatIf alongside it collides ("parameter
            # defined multiple times"), so the mutating report scripts rely on
            # SupportsShouldProcess for -WhatIf (see CLI-003/CLI-005).
            $cmdletBinding = $ast.ParamBlock.Attributes |
                Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
            $cmdletBinding | Should -Not -BeNullOrEmpty
            ($cmdletBinding.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) |
                Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

#region P12-T15: Invoke-SPLogRetention with Enabled=false returns no-op

Describe "P12-T15: Invoke-SPLogRetention with Enabled=false returns no-op" {

    Context "When Retention.Enabled is false in config" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }
            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Retention = [PSCustomObject]@{
                        Enabled     = $false
                        ArchiveDays = 30
                        DeleteDays  = 90
                        ArchivePath = '.\Archive'
                        Paths       = @('Audit', 'DeltaCert', 'Logs')
                    }
                }
            }
        }

        It "Should return Success true with zero counts" {
            $result = Invoke-SPLogRetention
            $result.Success | Should -Be $true
            $result.Data.Archived.FileCount | Should -Be 0
            $result.Data.Deleted.FileCount  | Should -Be 0
        }

        It "Should not delete or archive anything" {
            $result = Invoke-SPLogRetention
            $result.Data.Archived.Archives | Should -BeNullOrEmpty
            $result.Data.Deleted.Files     | Should -BeNullOrEmpty
        }
    }
}

#endregion

#region P12-T16: Invoke-SPLogRetention with WhatIf describes actions without performing them

Describe "P12-T16: Invoke-SPLogRetention with WhatIf describes actions without performing them" {

    Context "When WhatIf is set with old files present" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditOperations { }

            $script:retDir   = Join-Path $TestDrive 'retention-t16'
            $script:auditRet = Join-Path $script:retDir 'Audit'
            $script:archRet  = Join-Path $script:retDir 'Archive'
            $null = New-Item -ItemType Directory -Path $script:auditRet -Force

            # Create files with old timestamps (45 days ago)
            $oldDate = (Get-Date).AddDays(-45)
            $file1 = Join-Path $script:auditRet 'old-report.html'
            $file2 = Join-Path $script:auditRet 'old-trail.jsonl'
            [System.IO.File]::WriteAllText($file1, '<html>old report</html>')
            [System.IO.File]::WriteAllText($file2, '{"action":"old"}')
            (Get-Item $file1).LastWriteTime = $oldDate
            (Get-Item $file2).LastWriteTime = $oldDate

            # Also create a recent file (should NOT be archived)
            $file3 = Join-Path $script:auditRet 'new-report.html'
            [System.IO.File]::WriteAllText($file3, '<html>new</html>')

            Mock Get-SPConfig -ModuleName SP.AuditOperations {
                return [PSCustomObject]@{
                    Retention = [PSCustomObject]@{
                        Enabled     = $true
                        ArchiveDays = 30
                        DeleteDays  = 90
                        ArchivePath = $script:archRet
                        Paths       = @($script:auditRet)
                    }
                }
            }

            $script:whatIfResult = Invoke-SPLogRetention `
                -ArchiveDays 30 -DeleteDays 90 `
                -ArchivePath $script:archRet `
                -Paths @($script:auditRet) `
                -WhatIf
        }

        It "Should report files that would be archived" {
            $script:whatIfResult.Data.Archived.FileCount | Should -BeGreaterOrEqual 2
        }

        It "Should NOT actually create an archive directory or ZIP" {
            Test-Path $script:archRet | Should -Be $false
        }

        It "Should NOT delete the source files" {
            Test-Path (Join-Path $script:auditRet 'old-report.html') | Should -Be $true
            Test-Path (Join-Path $script:auditRet 'old-trail.jsonl') | Should -Be $true
        }

        It "Should preserve the recent file untouched" {
            Test-Path (Join-Path $script:auditRet 'new-report.html') | Should -Be $true
        }
    }
}

#endregion
