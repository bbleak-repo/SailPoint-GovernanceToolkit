#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.Evidence module.
.DESCRIPTION
    Tests JSONL evidence trail writing, HTML report generation,
    schema validation, and suite-level report generation.
    Test IDs: EVD-001 through EVD-005.
#>

BeforeAll {
    $corePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    if (Test-Path $corePath) { Import-Module $corePath -Force }

    $apiPath = Join-Path $PSScriptRoot "..\Modules\SP.Api\SP.Api.psd1"
    if (Test-Path $apiPath) { Import-Module $apiPath -Force }

    $testingPath = Join-Path $PSScriptRoot "..\Modules\SP.Testing\SP.Testing.psd1"
    Import-Module $testingPath -Force

    # Suppress SP.Core log calls
    Mock -CommandName Write-SPLog { }
}

# ---------------------------------------------------------------------------
# EVD-001: New-SPCampaignEvidencePath creates directory
# ---------------------------------------------------------------------------
Describe "EVD-001: New-SPCampaignEvidencePath creates directory" {
    It "Should create the Evidence/TestId directory under BasePath and return the path" {
        $basePath = Join-Path $TestDrive "EVD001"
        New-Item -Path $basePath -ItemType Directory -Force | Out-Null

        $result = New-SPCampaignEvidencePath -TestId 'TC-EVD001' -BasePath $basePath

        $result | Should -Not -BeNullOrEmpty
        Test-Path -Path $result -PathType Container | Should -Be $true
        $result | Should -Match 'TC-EVD001'
        $result | Should -Match 'Evidence'
    }

    It "Should return an existing path without error if directory already exists" {
        $basePath = Join-Path $TestDrive "EVD001-exists"
        New-Item -Path $basePath -ItemType Directory -Force | Out-Null

        # Create once
        $path1 = New-SPCampaignEvidencePath -TestId 'TC-EXIST' -BasePath $basePath
        # Create again - should not throw
        { $path2 = New-SPCampaignEvidencePath -TestId 'TC-EXIST' -BasePath $basePath } | Should -Not -Throw
    }

    It "Should sanitise special characters in TestId to produce a valid directory name" {
        $basePath = Join-Path $TestDrive "EVD001-sanitise"
        New-Item -Path $basePath -ItemType Directory -Force | Out-Null

        $result = New-SPCampaignEvidencePath -TestId 'TC:001/BAD*NAME' -BasePath $basePath

        Test-Path -Path $result -PathType Container | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# EVD-002: Write-SPEvidenceEvent appends valid JSONL
# ---------------------------------------------------------------------------
Describe "EVD-002: Write-SPEvidenceEvent appends valid JSONL" {
    It "Should create audit.jsonl and append a valid JSON line" {
        $evidencePath = Join-Path $TestDrive "EVD002\TC-001"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        Write-SPEvidenceEvent `
            -EvidencePath  $evidencePath `
            -TestId        'TC-001' `
            -Step          1 `
            -Action        'CreateCampaign' `
            -Status        'PASS' `
            -Message       'Campaign created successfully' `
            -CorrelationID 'corr-abc-123' `
            -Data          @{ CampaignId = 'camp-xyz-001' }

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        Test-Path $auditFile | Should -Be $true

        $lines = @(Get-Content $auditFile -Encoding UTF8)
        $lines.Count | Should -Be 1

        # Should be parseable JSON
        $parsed = $lines[0] | ConvertFrom-Json
        $parsed | Should -Not -BeNullOrEmpty
        $parsed.TestId     | Should -Be 'TC-001'
        $parsed.Step       | Should -Be 1
        $parsed.Action     | Should -Be 'CreateCampaign'
        $parsed.Status     | Should -Be 'PASS'
        $parsed.Message    | Should -Be 'Campaign created successfully'
        $parsed.CorrelationID | Should -Be 'corr-abc-123'
    }

    It "Should append multiple events to the same file" {
        $evidencePath = Join-Path $TestDrive "EVD002\TC-002"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        foreach ($i in 1..3) {
            Write-SPEvidenceEvent `
                -EvidencePath  $evidencePath `
                -TestId        'TC-002' `
                -Step          $i `
                -Action        "Step$i" `
                -Status        'INFO' `
                -Message       "Step $i event" `
                -CorrelationID 'corr-xyz'
        }

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        $lines = Get-Content $auditFile -Encoding UTF8
        $lines.Count | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
# EVD-003: Export-SPCampaignReport generates valid HTML
# ---------------------------------------------------------------------------
Describe "EVD-003: Export-SPCampaignReport generates valid HTML" {
    It "Should create summary.html in the evidence directory" {
        $evidencePath = Join-Path $TestDrive "EVD003\TC-001"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        # Seed some JSONL events
        $events = @(
            @{ TestId='TC-001'; Step=1; Action='CreateCampaign'; Status='PASS'; Message='Campaign created'; CorrelationID='corr-001'; Data=@{ CampaignId='camp-001' } },
            @{ TestId='TC-001'; Step=2; Action='ActivateCampaign'; Status='PASS'; Message='Activation accepted'; CorrelationID='corr-001'; Data=$null },
            @{ TestId='TC-001'; Step=3; Action='PollStatus'; Status='FAIL'; Message='Timeout waiting for ACTIVE'; CorrelationID='corr-001'; Data=$null }
        )

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        foreach ($ev in $events) {
            ($ev | ConvertTo-Json -Compress) | Add-Content -Path $auditFile -Encoding UTF8
        }

        $testResult = @{
            Pass            = $false
            Error           = 'Timeout waiting for ACTIVE'
            Steps           = @()
            DurationSeconds = 45.2
        }

        Export-SPCampaignReport `
            -EvidencePath $evidencePath `
            -TestId       'TC-001' `
            -TestName     'Source Owner Approve All' `
            -TestResult   $testResult

        $htmlFile = Join-Path $evidencePath 'summary.html'
        Test-Path $htmlFile | Should -Be $true

        $content = Get-Content $htmlFile -Raw -Encoding UTF8

        # Structural HTML checks
        $content | Should -Match '<!DOCTYPE html>'
        $content | Should -Match '<html'
        $content | Should -Match '</html>'
        $content | Should -Match 'TC-001'
        $content | Should -Match 'Source Owner Approve All'
        $content | Should -Match 'FAIL'

        # Should contain step table rows
        $content | Should -Match 'CreateCampaign'
        $content | Should -Match 'ActivateCampaign'
        $content | Should -Match 'PollStatus'

        # Should contain correlation ID
        $content | Should -Match 'corr-001'

        # Should have embedded CSS (no external dependencies)
        $content | Should -Match '<style>'
        $content | Should -Not -Match '<link rel="stylesheet"'
    }

    It "Should render a PASS badge for successful tests" {
        $evidencePath = Join-Path $TestDrive "EVD003\TC-PASS"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        @{TestId='TC-PASS'; Step=1; Action='CreateCampaign'; Status='PASS'; Message='OK'; CorrelationID='corr-pass'; Data=$null} |
            ConvertTo-Json -Compress | Add-Content -Path $auditFile -Encoding UTF8

        $testResult = @{ Pass = $true; Error = ''; Steps = @(); DurationSeconds = 12.3 }

        Export-SPCampaignReport `
            -EvidencePath $evidencePath `
            -TestId       'TC-PASS' `
            -TestName     'Passing Test' `
            -TestResult   $testResult

        $htmlFile = Join-Path $evidencePath 'summary.html'
        $content  = Get-Content $htmlFile -Raw -Encoding UTF8

        # Badge with PASS text and green color
        $content | Should -Match 'PASS'
        $content | Should -Match '#339933'
    }
}

# ---------------------------------------------------------------------------
# EVD-004: Export-SPSuiteReport generates valid HTML with all sections
# ---------------------------------------------------------------------------
Describe "EVD-004: Export-SPSuiteReport generates valid HTML with all sections" {
    It "Should create GovernanceRun HTML with summary stats and test rows" {
        $outputPath = Join-Path $TestDrive "EVD004-Reports"
        New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

        $suiteResult = @{
            Results = @(
                @{
                    TestId          = 'TC-001'
                    TestName        = 'Source Owner Approve All'
                    CampaignType    = 'SOURCE_OWNER'
                    Pass            = $true
                    Skipped         = $false
                    Steps           = @()
                    Error           = ''
                    DurationSeconds = 30.1
                },
                @{
                    TestId          = 'TC-002'
                    TestName        = 'Manager Revoke Subset'
                    CampaignType    = 'MANAGER'
                    Pass            = $false
                    Skipped         = $false
                    Steps           = @(
                        @{ Step=1; Action='CreateCampaign'; Status='PASS'; Message='OK' }
                        @{ Step=2; Action='ActivateCampaign'; Status='FAIL'; Message='API error 500' }
                    )
                    Error           = 'API error 500'
                    DurationSeconds = 5.7
                },
                @{
                    TestId          = 'TC-003'
                    TestName        = 'Skipped Test'
                    CampaignType    = 'SEARCH'
                    Pass            = $false
                    Skipped         = $true
                    Steps           = @()
                    Error           = 'Skipped: StopOnFirstFailure'
                    DurationSeconds = 0
                }
            )
            PassCount       = 1
            FailCount       = 1
            SkipCount       = 1
            DurationSeconds = 36.8
            TenantUrl       = 'https://test.identitynow.com'
            Environment     = 'NonProd'
            CorrelationID   = 'suite-corr-xyz'
        }

        Export-SPSuiteReport `
            -SuiteResult   $suiteResult `
            -OutputPath    $outputPath `
            -RunTimestamp  '20260218-143022'

        $htmlFile = Join-Path $outputPath 'GovernanceRun_20260218-143022.html'
        Test-Path $htmlFile | Should -Be $true

        $content = Get-Content $htmlFile -Raw -Encoding UTF8

        # Structural checks
        $content | Should -Match '<!DOCTYPE html>'
        $content | Should -Match 'GovernanceRun\|20260218-143022|20260218\-143022'

        # Executive summary counts
        $content | Should -Match '1'  # PassCount
        $content | Should -Match 'TC-001'
        $content | Should -Match 'TC-002'
        $content | Should -Match 'Source Owner Approve All'
        $content | Should -Match 'Manager Revoke Subset'

        # Environment metadata
        $content | Should -Match 'test\.identitynow\.com'
        $content | Should -Match 'NonProd'
        $content | Should -Match 'suite-corr-xyz'

        # Failed tests detail section should exist
        $content | Should -Match 'Failed Tests'
        $content | Should -Match 'API error 500'

        # Embedded CSS
        $content | Should -Match '<style>'
    }

    It "Should show PASS badge when all tests passed" {
        $outputPath = Join-Path $TestDrive "EVD004-AllPass"
        New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

        $suiteResult = @{
            Results         = @(
                @{ TestId='TC-001'; TestName='Test A'; CampaignType='SOURCE_OWNER'; Pass=$true; Skipped=$false; Steps=@(); Error=''; DurationSeconds=10 }
            )
            PassCount       = 1
            FailCount       = 0
            SkipCount       = 0
            DurationSeconds = 10
            TenantUrl       = 'https://test.identitynow.com'
            Environment     = 'NonProd'
            CorrelationID   = 'pass-corr'
        }

        Export-SPSuiteReport `
            -SuiteResult  $suiteResult `
            -OutputPath   $outputPath `
            -RunTimestamp '20260218-100000'

        $htmlFile = Join-Path $outputPath 'GovernanceRun_20260218-100000.html'
        $content  = Get-Content $htmlFile -Raw -Encoding UTF8

        $content | Should -Match 'PASS'
        $content | Should -Match '#339933'
    }
}

# ---------------------------------------------------------------------------
# EVD-005: JSONL evidence events have correct schema fields
# ---------------------------------------------------------------------------
Describe "EVD-005: JSONL evidence events have correct schema fields" {
    It "Should produce events with all required schema fields" {
        $evidencePath = Join-Path $TestDrive "EVD005\TC-SCHEMA"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        Write-SPEvidenceEvent `
            -EvidencePath  $evidencePath `
            -TestId        'TC-SCHEMA' `
            -Step          3 `
            -Action        'PollStatus' `
            -Status        'PASS' `
            -Message       'Campaign reached ACTIVE' `
            -CorrelationID 'schema-corr-xyz' `
            -Data          @{ CampaignId = 'camp-schema-001'; Status = 'ACTIVE' }

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        $lines     = @(Get-Content $auditFile -Encoding UTF8)
        $parsed    = $lines[0] | ConvertFrom-Json

        # All required schema fields must be present
        $parsed.PSObject.Properties.Name | Should -Contain 'Timestamp'
        $parsed.PSObject.Properties.Name | Should -Contain 'TestId'
        $parsed.PSObject.Properties.Name | Should -Contain 'Step'
        $parsed.PSObject.Properties.Name | Should -Contain 'Action'
        $parsed.PSObject.Properties.Name | Should -Contain 'Status'
        $parsed.PSObject.Properties.Name | Should -Contain 'Message'
        $parsed.PSObject.Properties.Name | Should -Contain 'CorrelationID'
        $parsed.PSObject.Properties.Name | Should -Contain 'Data'

        # Validate specific values
        # PS7 ConvertFrom-Json auto-converts ISO 8601 strings to DateTime; PS 5.1 keeps strings
        $ts = $parsed.Timestamp
        if ($ts -is [datetime]) { $ts = $ts.ToString('o') }
        $ts | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $parsed.TestId       | Should -Be 'TC-SCHEMA'
        $parsed.Step         | Should -Be 3
        $parsed.Action       | Should -Be 'PollStatus'
        $parsed.Status       | Should -Be 'PASS'
        $parsed.CorrelationID | Should -Be 'schema-corr-xyz'
    }

    It "Should record all valid Status values without error" {
        $evidencePath = Join-Path $TestDrive "EVD005\TC-STATUSES"
        New-Item -Path $evidencePath -ItemType Directory -Force | Out-Null

        $validStatuses = @('PASS', 'FAIL', 'INFO', 'SKIP', 'WARN')
        foreach ($status in $validStatuses) {
            {
                Write-SPEvidenceEvent `
                    -EvidencePath  $evidencePath `
                    -TestId        'TC-STATUSES' `
                    -Step          1 `
                    -Action        "TestAction" `
                    -Status        $status `
                    -Message       "Testing status: $status" `
                    -CorrelationID 'corr-statuses'
            } | Should -Not -Throw
        }

        $auditFile = Join-Path $evidencePath 'audit.jsonl'
        $lines = Get-Content $auditFile -Encoding UTF8
        $lines.Count | Should -Be $validStatuses.Count

        $parsedStatuses = $lines | ForEach-Object { ($_ | ConvertFrom-Json).Status }
        foreach ($expected in $validStatuses) {
            $parsedStatuses | Should -Contain $expected
        }
    }

    It "Should not throw even when EvidencePath does not exist yet" {
        $nonExistentPath = Join-Path $TestDrive "EVD005\NonExistent\TC-NEW"
        # Directory does NOT exist yet

        {
            Write-SPEvidenceEvent `
                -EvidencePath  $nonExistentPath `
                -TestId        'TC-NEW' `
                -Step          1 `
                -Action        'CreateCampaign' `
                -Status        'INFO' `
                -Message       'Auto-created directory' `
                -CorrelationID 'corr-auto'
        } | Should -Not -Throw
    }
}
