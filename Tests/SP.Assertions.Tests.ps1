#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.Assertions module.
.DESCRIPTION
    Tests pass/fail evaluation functions for campaign status,
    certification count, and decision acceptance assertions.
    Test IDs: ASRT-001 through ASRT-003.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Testing

    # Mock supporting SP.Core functions
    Mock -ModuleName SP.Assertions -CommandName Write-SPLog { }
}

# ---------------------------------------------------------------------------
# ASRT-001: Assert-SPCampaignStatus passes when status matches
# ---------------------------------------------------------------------------
Describe "ASRT-001: Assert-SPCampaignStatus passes when status matches" {
    BeforeAll {
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            param($CampaignId, $Full, $CorrelationID, $CampaignTestId)
            @{
                Success = $true
                Data    = [PSCustomObject]@{
                    id     = $CampaignId
                    status = 'ACTIVE'
                    name   = 'UAT-Mock-001'
                }
                Error   = $null
            }
        }
    }

    It "Should return Pass=true when actual status matches expected" {
        $result = Assert-SPCampaignStatus `
            -CampaignId      'camp-123' `
            -ExpectedStatus  'ACTIVE' `
            -CorrelationID   'test-corr-001' `
            -CampaignTestId  'TC-001'

        $result.Pass     | Should -Be $true
        $result.Actual   | Should -Be 'ACTIVE'
        $result.Expected | Should -Be 'ACTIVE'
        $result.Message  | Should -Match 'matches'
    }

    It "Should be case-insensitive in status comparison" {
        $result = Assert-SPCampaignStatus `
            -CampaignId     'camp-123' `
            -ExpectedStatus 'active'

        $result.Pass | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# ASRT-002: Assert-SPCampaignStatus fails when status mismatches
# ---------------------------------------------------------------------------
Describe "ASRT-002: Assert-SPCampaignStatus fails when status mismatches" {
    BeforeAll {
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            param($CampaignId, $Full, $CorrelationID, $CampaignTestId)
            @{
                Success = $true
                Data    = [PSCustomObject]@{
                    id     = $CampaignId
                    status = 'ACTIVE'
                    name   = 'UAT-Mock-002'
                }
                Error   = $null
            }
        }
    }

    It "Should return Pass=false when actual status does not match expected" {
        $result = Assert-SPCampaignStatus `
            -CampaignId     'camp-456' `
            -ExpectedStatus 'COMPLETED'

        $result.Pass     | Should -Be $false
        $result.Actual   | Should -Be 'ACTIVE'
        $result.Expected | Should -Be 'COMPLETED'
        $result.Message  | Should -Match 'mismatch'
    }

    It "Should return Pass=false when Get-SPCampaign fails" {
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            @{
                Success = $false
                Data    = $null
                Error   = "API unavailable"
            }
        }

        $result = Assert-SPCampaignStatus `
            -CampaignId     'camp-789' `
            -ExpectedStatus 'COMPLETED'

        $result.Pass    | Should -Be $false
        $result.Message | Should -Match 'API unavailable'

        # Restore mock
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            param($CampaignId)
            @{
                Success = $true
                Data    = [PSCustomObject]@{ id = $CampaignId; status = 'ACTIVE'; name = 'UAT' }
                Error   = $null
            }
        }
    }

    It "Should handle missing Get-SPCampaign function gracefully" {
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            throw "Mock forced error"
        }

        $result = Assert-SPCampaignStatus `
            -CampaignId     'camp-err' `
            -ExpectedStatus 'COMPLETED'

        $result.Pass | Should -Be $false
        $result.Message | Should -Not -BeNullOrEmpty

        # Restore
        Mock -ModuleName SP.Assertions -CommandName Get-SPCampaign {
            param($CampaignId)
            @{
                Success = $true
                Data    = [PSCustomObject]@{ id = $CampaignId; status = 'ACTIVE'; name = 'UAT' }
                Error   = $null
            }
        }
    }
}

# ---------------------------------------------------------------------------
# ASRT-003: Assert-SPDecisionAccepted validates total count
# ---------------------------------------------------------------------------
Describe "ASRT-003: Assert-SPDecisionAccepted validates total count" {
    It "Should return Pass=true when TotalDecided matches ExpectedTotal" {
        $bulkDecideResult = @{
            Success = $true
            Data    = [PSCustomObject]@{
                BatchResults = @()
                TotalDecided = 25
            }
            Error   = $null
        }

        $result = Assert-SPDecisionAccepted `
            -BulkDecideResult $bulkDecideResult `
            -ExpectedTotal     25

        $result.Pass   | Should -Be $true
        $result.Actual | Should -Be 25
        $result.Message | Should -Match '25'
    }

    It "Should return Pass=false when TotalDecided does not match ExpectedTotal" {
        $bulkDecideResult = @{
            Success = $true
            Data    = [PSCustomObject]@{
                BatchResults = @()
                TotalDecided = 20
            }
            Error   = $null
        }

        $result = Assert-SPDecisionAccepted `
            -BulkDecideResult $bulkDecideResult `
            -ExpectedTotal     25

        $result.Pass   | Should -Be $false
        $result.Actual | Should -Be 20
        $result.Message | Should -Match 'expected 25'
    }

    It "Should return Pass=false when BulkDecideResult is not successful" {
        $bulkDecideResult = @{
            Success = $false
            Data    = $null
            Error   = "Rate limit exceeded"
        }

        $result = Assert-SPDecisionAccepted `
            -BulkDecideResult $bulkDecideResult `
            -ExpectedTotal     10

        $result.Pass   | Should -Be $false
        $result.Actual | Should -Be 0
        $result.Message | Should -Match 'Rate limit'
    }

    It "Should handle TotalDecided of zero correctly" {
        $bulkDecideResult = @{
            Success = $true
            Data    = [PSCustomObject]@{
                BatchResults = @()
                TotalDecided = 0
            }
            Error   = $null
        }

        $result = Assert-SPDecisionAccepted `
            -BulkDecideResult $bulkDecideResult `
            -ExpectedTotal     0

        $result.Pass   | Should -Be $true
        $result.Actual | Should -Be 0
    }

    It "Should work with hashtable-based Data field" {
        $bulkDecideResult = @{
            Success = $true
            Data    = @{
                BatchResults = @()
                TotalDecided = 15
            }
            Error   = $null
        }

        $result = Assert-SPDecisionAccepted `
            -BulkDecideResult $bulkDecideResult `
            -ExpectedTotal     15

        $result.Pass   | Should -Be $true
        $result.Actual | Should -Be 15
    }
}
