#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.AuditReport module
.DESCRIPTION
    Tests: AR-001 through AR-006
    Covers: decision grouping by outcome, reviewer action separation by primary vs
    reassigned, identity event grouping by operation, HTML report generation with all
    required sections, text report generation, and JSONL audit trail output.
#>

BeforeAll {
    $corePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    if (Test-Path $corePath) { Import-Module $corePath -Force }

    $apiPath = Join-Path $PSScriptRoot "..\Modules\SP.Api\SP.Api.psd1"
    if (Test-Path $apiPath) { Import-Module $apiPath -Force }

    $auditPath = Join-Path $PSScriptRoot "..\Modules\SP.Audit\SP.Audit.psd1"
    Import-Module $auditPath -Force

    # Helper: build sample review items for decision grouping tests
    function New-SampleReviewItems {
        # Group-SPAuditDecisions expects wrapper hashtables with an 'Item' key
        # pointing to the raw API item (identitySummary, access, decision, etc.)
        return @(
            @{
                Item = [PSCustomObject]@{
                    id              = 'item-approve-1'
                    decision        = 'APPROVE'
                    identitySummary = [PSCustomObject]@{ name = 'Alice Johnson' }
                    access          = [PSCustomObject]@{ name = 'AD_Users'; type = 'Entitlement' }
                    reviewedBy      = [PSCustomObject]@{ name = 'Manager1' }
                    decisionDate    = '2026-02-10T10:00:00Z'
                }
                CertificationId   = 'cert-001'
                CertificationName = 'Test Cert'
                CampaignName      = 'Test Campaign'
            },
            @{
                Item = [PSCustomObject]@{
                    id              = 'item-approve-2'
                    decision        = 'APPROVE'
                    identitySummary = [PSCustomObject]@{ name = 'Bob Smith' }
                    access          = [PSCustomObject]@{ name = 'AD_ReadOnly'; type = 'Entitlement' }
                    reviewedBy      = [PSCustomObject]@{ name = 'Manager1' }
                    decisionDate    = '2026-02-10T10:05:00Z'
                }
                CertificationId   = 'cert-001'
                CertificationName = 'Test Cert'
                CampaignName      = 'Test Campaign'
            },
            @{
                Item = [PSCustomObject]@{
                    id              = 'item-revoke-1'
                    decision        = 'REVOKE'
                    identitySummary = [PSCustomObject]@{ name = 'Carol Davis' }
                    access          = [PSCustomObject]@{ name = 'AD_Admins'; type = 'Entitlement' }
                    reviewedBy      = [PSCustomObject]@{ name = 'Manager1' }
                    decisionDate    = '2026-02-10T10:10:00Z'
                }
                CertificationId   = 'cert-002'
                CertificationName = 'Test Cert 2'
                CampaignName      = 'Test Campaign'
            },
            @{
                Item = [PSCustomObject]@{
                    id              = 'item-pending-1'
                    decision        = $null
                    identitySummary = [PSCustomObject]@{ name = 'Dave Lee' }
                    access          = [PSCustomObject]@{ name = 'VPN_Access'; type = 'Entitlement' }
                    reviewedBy      = $null
                    decisionDate    = $null
                }
                CertificationId   = 'cert-003'
                CertificationName = 'Test Cert 3'
                CampaignName      = 'Test Campaign'
            }
        )
    }

    # Helper: build sample certifications for reviewer action tests
    function New-SampleCertifications {
        return @(
            [PSCustomObject]@{
                id                      = 'cert-primary-1'
                name                    = 'Alice Johnson Review'
                reviewer                = [PSCustomObject]@{ name = 'Alice Johnson'; email = 'alice@corp.com' }
                signed                  = $true
                signedDate              = '2026-02-10T14:00:00Z'
                decisionsMade           = 10
                phase                   = 'SIGNED'
                ReviewerClassification  = 'Primary'
                reassignment            = $null
            },
            [PSCustomObject]@{
                id                      = 'cert-reassigned-1'
                name                    = 'Bob Smith Review'
                reviewer                = [PSCustomObject]@{ name = 'Bob Smith'; email = 'bob@corp.com' }
                signed                  = $true
                signedDate              = '2026-02-10T15:30:00Z'
                decisionsMade           = 5
                phase                   = 'SIGNED'
                ReviewerClassification  = 'Reassigned'
                reassignment            = [PSCustomObject]@{
                    from = [PSCustomObject]@{ id = 'cert-primary-1'; reviewer = [PSCustomObject]@{ name = 'Alice Johnson' } }
                }
            },
            [PSCustomObject]@{
                id                      = 'cert-primary-2'
                name                    = 'Carol Davis Review'
                reviewer                = [PSCustomObject]@{ name = 'Carol Davis'; email = 'carol@corp.com' }
                signed                  = $false
                signedDate              = $null
                decisionsMade           = 0
                phase                   = 'ACTIVE'
                ReviewerClassification  = 'Primary'
                reassignment            = $null
            }
        )
    }

    # Helper: build sample identity events
    function New-SampleIdentityEvents {
        return @(
            [PSCustomObject]@{
                id         = 'evt-remove-1'
                operation  = 'REMOVE'
                created    = '2026-02-10T16:00:00Z'
                sourceName = 'Active Directory'
                accessName = 'AD_Admins'
            },
            [PSCustomObject]@{
                id         = 'evt-remove-2'
                operation  = 'REMOVE'
                created    = '2026-02-10T16:05:00Z'
                sourceName = 'Active Directory'
                accessName = 'AD_ReadOnly'
            },
            [PSCustomObject]@{
                id         = 'evt-add-1'
                operation  = 'ADD'
                created    = '2026-02-10T16:10:00Z'
                sourceName = 'Active Directory'
                accessName = 'AD_BaseAccess'
            },
            [PSCustomObject]@{
                id         = 'evt-delete-1'
                operation  = 'DELETE'
                created    = '2026-02-10T16:15:00Z'
                sourceName = 'Sailpoint'
                accessName = 'IdentityNow Access'
            }
        )
    }

    # Helper: build a full CampaignAudit hashtable for report generation tests.
    # Export-SPAuditHtml and Export-SPAuditText call .ContainsKey() so this MUST
    # be a hashtable, not a PSCustomObject.
    function New-SampleCampaignAudit {
        param([string]$CorrelationID = 'test-corr-001')

        return @{
            CampaignName             = 'Q1 2026 Access Review'
            CampaignId               = 'camp-sample-001'
            Status                   = 'COMPLETED'
            Created                  = '2026-01-15T08:00:00Z'
            Completed                = '2026-02-10T17:00:00Z'
            TotalCertifications      = 3
            Decisions                = @{
                Approved = @(
                    [PSCustomObject]@{ IdentityName = 'Alice'; AccessName = 'AD_Users';    AccessType = 'Entitlement'; ReviewerName = 'Manager1'; DecisionDate = '2026-02-10' }
                    [PSCustomObject]@{ IdentityName = 'Bob';   AccessName = 'AD_ReadOnly'; AccessType = 'Entitlement'; ReviewerName = 'Manager1'; DecisionDate = '2026-02-10' }
                )
                Revoked = @(
                    [PSCustomObject]@{ IdentityName = 'Carol'; AccessName = 'AD_Admins';  AccessType = 'Entitlement'; ReviewerName = 'Manager1'; DecisionDate = '2026-02-10' }
                )
                Pending = @(
                    [PSCustomObject]@{ IdentityName = 'Dave';  AccessName = 'VPN_Access'; AccessType = 'Entitlement'; ReviewerName = 'N/A';      DecisionDate = '' }
                )
            }
            Reviewers                = @{
                Primary = @(
                    [PSCustomObject]@{ Name = 'Alice Johnson'; Email = 'alice@corp.com'; CertsAssigned = 2; DecisionsMade = 10; SignOffDate = '2026-02-10'; Phase = 'SIGNED' }
                )
                Reassigned = @(
                    [PSCustomObject]@{ Name = 'Bob Smith'; Email = 'bob@corp.com'; ReassignedFrom = 'Alice Johnson'; DecisionsMade = 5; SignOffDate = '2026-02-10'; Phase = 'SIGNED'; ProofOfAction = $true }
                )
            }
            Events                   = @{
                Revoked = @(
                    [PSCustomObject]@{ TargetName = 'Carol'; Actor = 'System'; SourceName = 'AD'; Operation = 'REMOVE'; Date = '2026-02-10'; Status = 'SUCCESS' }
                )
                Granted = @()
            }
            CampaignReports          = $null
            CampaignReportsAvailable = $false
        }
    }
}

#region AR-001: Group-SPAuditDecisions categorizes items correctly

Describe "AR-001: Group-SPAuditDecisions categorizes review items" {

    Context "When items have a mix of APPROVE, REVOKE, and null decisions" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should return a grouping object with Approved, Revoked, and Pending properties" {
            $items  = New-SampleReviewItems
            $result = Group-SPAuditDecisions -Items $items
            $result.Approved | Should -Not -BeNullOrEmpty
            $result.Revoked  | Should -Not -BeNullOrEmpty
            $result.Pending  | Should -Not -BeNullOrEmpty
        }

        It "Should count APPROVE decisions correctly" {
            $items  = New-SampleReviewItems
            $result = Group-SPAuditDecisions -Items $items
            @($result.Approved).Count | Should -Be 2
        }

        It "Should count REVOKE decisions correctly" {
            $items  = New-SampleReviewItems
            $result = Group-SPAuditDecisions -Items $items
            @($result.Revoked).Count | Should -Be 1
        }

        It "Should count null (Pending) decisions correctly" {
            $items  = New-SampleReviewItems
            $result = Group-SPAuditDecisions -Items $items
            @($result.Pending).Count | Should -Be 1
        }

        It "Should report the correct total item count" {
            $items  = New-SampleReviewItems
            $result = Group-SPAuditDecisions -Items $items
            $total = @($result.Approved).Count + @($result.Revoked).Count + @($result.Pending).Count
            $total | Should -Be 4
        }

        It "Should handle an empty item array without error" {
            $result = Group-SPAuditDecisions -Items @()
            @($result.Approved).Count | Should -Be 0
            @($result.Revoked).Count  | Should -Be 0
            @($result.Pending).Count  | Should -Be 0
        }
    }
}

#endregion

#region AR-002: Group-SPReviewerActions separates primary from reassigned

Describe "AR-002: Group-SPReviewerActions separates primary and reassigned reviewers" {

    Context "When certifications have a mix of primary and reassigned reviewers" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should place certifications in the Primary collection" {
            $certs  = New-SampleCertifications
            $result = Group-SPReviewerActions -Certifications $certs
            @($result.Primary).Count | Should -BeGreaterThan 0
        }

        It "Should place one certification in the Reassigned collection" {
            $certs  = New-SampleCertifications
            $result = Group-SPReviewerActions -Certifications $certs
            @($result.Reassigned).Count | Should -Be 1
        }

        It "Should include ProofOfAction on reassigned entries" {
            $certs  = New-SampleCertifications
            $result = Group-SPReviewerActions -Certifications $certs
            $reassigned = @($result.Reassigned)
            if ($reassigned.Count -gt 0) {
                $reassigned[0].PSObject.Properties.Name | Should -Contain 'ProofOfAction'
            }
        }

        It "Should handle certifications with no reassignments" {
            $primaryOnly = @(New-SampleCertifications | Where-Object { $_.ReviewerClassification -eq 'Primary' })
            $result      = Group-SPReviewerActions -Certifications $primaryOnly
            @($result.Reassigned).Count | Should -Be 0
        }
    }
}

#endregion

#region AR-003: Group-SPAuditIdentityEvents groups by operation type

Describe "AR-003: Group-SPAuditIdentityEvents groups events by operation" {

    Context "When events include REMOVE, ADD, and DELETE operations" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReport { }
        }

        It "Should return Revoked and Granted collections" {
            $events = New-SampleIdentityEvents
            $result = Group-SPAuditIdentityEvents -Events $events

            $result.Revoked | Should -Not -BeNullOrEmpty
            $result.Granted | Should -Not -BeNullOrEmpty
        }

        It "Should place REMOVE events in the Revoked collection" {
            $events = New-SampleIdentityEvents
            $result = Group-SPAuditIdentityEvents -Events $events

            $removeEvts = @($result.Revoked | Where-Object { $_.operation -eq 'REMOVE' })
            $removeEvts.Count | Should -Be 2
        }

        It "Should place ADD events in the Granted collection" {
            $events = New-SampleIdentityEvents
            $result = Group-SPAuditIdentityEvents -Events $events

            $addEvts = @($result.Granted | Where-Object { $_.operation -eq 'ADD' })
            $addEvts.Count | Should -Be 1
        }

        It "Should treat DELETE operations as Revoked" {
            $events = New-SampleIdentityEvents
            $result = Group-SPAuditIdentityEvents -Events $events

            $deleteEvts = @($result.Revoked | Where-Object { $_.operation -eq 'DELETE' })
            $deleteEvts.Count | Should -Be 1
        }

        It "Should handle an empty event list without error" {
            $result = Group-SPAuditIdentityEvents -Events @()

            @($result.Revoked).Count | Should -Be 0
            @($result.Granted).Count | Should -Be 0
        }
    }
}

#endregion

#region AR-004: Export-SPAuditHtml generates valid HTML with all sections

Describe "AR-004: Export-SPAuditHtml generates a valid HTML report" {

    Context "When given a well-formed CampaignAudit object" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:ARHtmlTestDir = Join-Path $TestDrive 'ar-004-html'
            $null = New-Item -ItemType Directory -Path $script:ARHtmlTestDir -Force

            $campaignAudit = New-SampleCampaignAudit -CorrelationID 'ar-004-corr'
            Export-SPAuditHtml `
                -CampaignAudits @($campaignAudit) `
                -OutputPath $script:ARHtmlTestDir `
                -CorrelationID 'ar-004-corr'

            # Locate the generated HTML file
            $htmlFiles = Get-ChildItem -Path $script:ARHtmlTestDir -Filter '*.html'
            if ($htmlFiles) {
                $script:ARHtmlContent = Get-Content -Path $htmlFiles[0].FullName -Raw
            }
            else {
                $script:ARHtmlContent = ''
            }
        }

        It "Should create at least one HTML file in the output directory" {
            $files = Get-ChildItem -Path $script:ARHtmlTestDir -Filter '*.html'
            $files.Count | Should -BeGreaterThan 0
        }

        It "Should generate non-empty HTML content" {
            $script:ARHtmlContent | Should -Not -BeNullOrEmpty
            $script:ARHtmlContent.Length | Should -BeGreaterThan 100
        }

        It "Should include the campaign name in the HTML" {
            $script:ARHtmlContent | Should -Match 'Q1 2026 Access Review'
        }

        It "Should include a table or section for decisions" {
            # Look for common table/section markers
            ($script:ARHtmlContent -match '<table' -or $script:ARHtmlContent -match 'decision') | Should -Be $true
        }

        It "Should include the correlation ID in the HTML" {
            $script:ARHtmlContent | Should -Match 'ar-004-corr'
        }

        It "Should be valid enough to contain opening and closing html tags" {
            $script:ARHtmlContent | Should -Match '<html'
            $script:ARHtmlContent | Should -Match '</html>'
        }
    }
}

#endregion

#region AR-005: Export-SPAuditText generates formatted text summary

Describe "AR-005: Export-SPAuditText generates a formatted text report" {

    Context "When given a well-formed CampaignAudit object" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:ARTextTestDir = Join-Path $TestDrive 'ar-005-text'
            $null = New-Item -ItemType Directory -Path $script:ARTextTestDir -Force

            $campaignAudit = New-SampleCampaignAudit -CorrelationID 'ar-005-corr'
            Export-SPAuditText `
                -CampaignAudits @($campaignAudit) `
                -OutputPath $script:ARTextTestDir `
                -CorrelationID 'ar-005-corr'

            $textFiles = Get-ChildItem -Path $script:ARTextTestDir -Filter '*.txt'
            if ($textFiles) {
                $script:ARTextContent = Get-Content -Path $textFiles[0].FullName -Raw
            }
            else {
                $script:ARTextContent = ''
            }
        }

        It "Should create at least one text file in the output directory" {
            $files = Get-ChildItem -Path $script:ARTextTestDir -Filter '*.txt'
            $files.Count | Should -BeGreaterThan 0
        }

        It "Should generate non-empty text content" {
            $script:ARTextContent | Should -Not -BeNullOrEmpty
        }

        It "Should include the campaign name" {
            $script:ARTextContent | Should -Match 'Q1 2026 Access Review'
        }

        It "Should include a decisions summary section" {
            ($script:ARTextContent -match 'Decision' -or $script:ARTextContent -match 'Approve' -or $script:ARTextContent -match 'Revoke') | Should -Be $true
        }

        It "Should include the correlation ID" {
            $script:ARTextContent | Should -Match 'ar-005-corr'
        }
    }
}

#endregion

#region AR-006: Export-SPAuditJsonl writes valid JSONL

Describe "AR-006: Export-SPAuditJsonl writes a valid JSONL audit trail" {

    Context "When given one or more CampaignAudit objects" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:ARJsonlTestDir = Join-Path $TestDrive 'ar-006-jsonl'
            $null = New-Item -ItemType Directory -Path $script:ARJsonlTestDir -Force

            $events = @(
                @{
                    Action       = 'CampaignAudit'
                    CampaignName = 'Q1 2026 Access Review'
                    CampaignId   = 'camp-sample-001'
                    Status       = 'COMPLETED'
                    ApproveCount = 2
                    RevokeCount  = 1
                }
            )
            Export-SPAuditJsonl `
                -Events $events `
                -OutputPath $script:ARJsonlTestDir `
                -CorrelationID 'ar-006-corr'

            $jsonlFiles = Get-ChildItem -Path $script:ARJsonlTestDir -Filter '*.jsonl'
            if ($jsonlFiles) {
                $script:ARJsonlLines = @(Get-Content -Path $jsonlFiles[0].FullName)
            }
            else {
                $script:ARJsonlLines = @()
            }
        }

        It "Should create at least one JSONL file" {
            $files = Get-ChildItem -Path $script:ARJsonlTestDir -Filter '*.jsonl'
            $files.Count | Should -BeGreaterThan 0
        }

        It "Should write at least one line to the JSONL file" {
            $script:ARJsonlLines.Count | Should -BeGreaterThan 0
        }

        It "Each line should be valid JSON" {
            foreach ($line in $script:ARJsonlLines) {
                if ($line.Trim()) {
                    { $null = $line | ConvertFrom-Json } | Should -Not -Throw
                }
            }
        }

        It "Should include the correlation ID in at least one line" {
            $hasCorr = $script:ARJsonlLines | Where-Object { $_ -match 'ar-006-corr' }
            $hasCorr | Should -Not -BeNullOrEmpty
        }

        It "Should include the campaign name in at least one line" {
            $hasCamp = $script:ARJsonlLines | Where-Object { $_ -match 'Q1 2026 Access Review' }
            $hasCamp | Should -Not -BeNullOrEmpty
        }
    }

    Context "When given an empty events array" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.AuditReport { }

            $script:ARJsonlEmptyDir = Join-Path $TestDrive 'ar-006-empty'
            $null = New-Item -ItemType Directory -Path $script:ARJsonlEmptyDir -Force
        }

        It "Should not throw an error" {
            { Export-SPAuditJsonl -Events @() -OutputPath $script:ARJsonlEmptyDir -CorrelationID 'ar-006-empty' } |
                Should -Not -Throw
        }
    }
}

#endregion
