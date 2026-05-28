#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.DisconnectedApps modules
.DESCRIPTION
    Tests: DA-001 through DA-011
    Covers:
        DA-001 to DA-002: Test-SPDisconnectedAppAccountFile  -- missing columns, duplicate IDs
        DA-003:           Test-SPDisconnectedAppCrossReference -- unmatched groups
        DA-004:           Save-SPDisconnectedAppSnapshot       -- date-stamped file creation
        DA-005:           Get-SPDisconnectedAppPreviousSnapshot -- correct file retrieval
        DA-006 to DA-008: Compare-SPDisconnectedAppFiles       -- added accounts, entitlement grants, first run
        DA-009:           Resolve-SPDisconnectedAppIdentities   -- email-to-ISC identity mapping (mocked)
        DA-010:           Export-SPDisconnectedAppDeltaHtml     -- valid HTML generation
        DA-011:           Invoke-SPDisconnectedAppCert.ps1      -- CLI script syntax validation

    Note on mock-scoping:
        DA-009 mocks cross-module calls (Invoke-SPApiRequest, Get-SPDeltaIdentityDetail) within
        SP.DisconnectedAppRunner. On PS 5.1 Desktop -ModuleName targets the top-level .psm1 loaded
        by Import-SPTestModules. On PS7 + Pester 5 strict scoping they may need adjustment.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -DeltaCert -DisconnectedApps

    # Paths to test data files shipped with the toolkit
    $script:TestDataDir       = Join-Path $PSScriptRoot 'TestData'
    $script:Day1Accounts      = Join-Path $script:TestDataDir 'disconnected-day1-accounts.csv'
    $script:Day2Accounts      = Join-Path $script:TestDataDir 'disconnected-day2-accounts.csv'
    $script:Entitlements      = Join-Path $script:TestDataDir 'disconnected-entitlements.csv'
    $script:InvalidAccounts   = Join-Path $script:TestDataDir 'disconnected-invalid-accounts.csv'
}

# ---------------------------------------------------------------------------
#region DA-001: Test-SPDisconnectedAppAccountFile detects missing required columns
# ---------------------------------------------------------------------------

Describe "DA-001: Test-SPDisconnectedAppAccountFile detects missing required columns" {

    Context "When the account file is missing the e-mail column" {
        It "Should return Success=false with an error mentioning the missing column" {
            $result = Test-SPDisconnectedAppAccountFile -FilePath $script:InvalidAccounts

            $result.Success | Should -Be $false
            $result.Data.Errors | Should -Not -BeNullOrEmpty
            ($result.Data.Errors -join '; ') | Should -Match 'e-mail'
        }
    }

    Context "When the account file is valid" {
        It "Should return Success=true for day1 accounts" {
            $result = Test-SPDisconnectedAppAccountFile -FilePath $script:Day1Accounts

            $result.Success        | Should -Be $true
            $result.Data.RowCount  | Should -Be 5
            $result.Data.ValidRows | Should -Be 5
            $result.Error          | Should -BeNullOrEmpty
        }
    }

    Context "When the file does not exist" {
        It "Should return Success=false with a file-not-found error" {
            $result = Test-SPDisconnectedAppAccountFile -FilePath (Join-Path $TestDrive 'nonexistent.csv')

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'not found'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-002: Test-SPDisconnectedAppAccountFile detects duplicate IDs
# ---------------------------------------------------------------------------

Describe "DA-002: Test-SPDisconnectedAppAccountFile detects duplicate IDs" {

    Context "When the account file contains duplicate id values" {
        It "Should return errors mentioning duplicate id" {
            $result = Test-SPDisconnectedAppAccountFile -FilePath $script:InvalidAccounts

            $result.Success | Should -Be $false
            # The invalid file has EMP20001 twice
            ($result.Data.Errors -join '; ') | Should -Match 'duplicate'
        }

        It "Should count invalid rows" {
            $result = Test-SPDisconnectedAppAccountFile -FilePath $script:InvalidAccounts

            $result.Data.InvalidRows | Should -BeGreaterThan 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-003: Test-SPDisconnectedAppCrossReference finds unmatched groups
# ---------------------------------------------------------------------------

Describe "DA-003: Test-SPDisconnectedAppCrossReference finds unmatched groups" {

    Context "When all account groups exist in the entitlement file" {
        It "Should return Success=true with no unmatched groups" {
            $result = Test-SPDisconnectedAppCrossReference `
                -AccountFilePath $script:Day1Accounts `
                -EntitlementFilePath $script:Entitlements

            $result.Success | Should -Be $true
            $result.Data.UnmatchedGroups.Count | Should -Be 0
        }
    }

    Context "When an account references a group not in the entitlement file" {
        BeforeAll {
            # Create a temporary account file with a phantom entitlement reference
            $script:TempAccountFile = Join-Path $TestDrive 'phantom-groups.csv'
            @(
                'id,name,givenName,familyName,e-mail,department,groups,IIQDisabled'
                'EMP30001,testuser,Test,User,test@corp.com,IT,"APP-ADMIN,APP-GHOST",false'
            ) | Set-Content -Path $script:TempAccountFile -Encoding UTF8
        }

        It "Should return Success=false with APP-GHOST in unmatched groups" {
            $result = Test-SPDisconnectedAppCrossReference `
                -AccountFilePath $script:TempAccountFile `
                -EntitlementFilePath $script:Entitlements

            $result.Success | Should -Be $false
            $result.Data.UnmatchedGroups.Count | Should -BeGreaterThan 0
            $result.Data.UnmatchedGroups[0].EntitlementId | Should -Be 'APP-GHOST'
        }
    }

    Context "When an entitlement is defined but not referenced by any account" {
        BeforeAll {
            # Create a small account file that only uses APP-ADMIN
            $script:TempSmallAccounts = Join-Path $TestDrive 'small-accounts.csv'
            @(
                'id,name,givenName,familyName,e-mail,department,groups,IIQDisabled'
                'EMP40001,onlyadmin,Only,Admin,only@corp.com,IT,APP-ADMIN,false'
            ) | Set-Content -Path $script:TempSmallAccounts -Encoding UTF8
        }

        It "Should flag orphaned entitlements" {
            $result = Test-SPDisconnectedAppCrossReference `
                -AccountFilePath $script:TempSmallAccounts `
                -EntitlementFilePath $script:Entitlements

            # APP-POWERUSER, APP-READONLY, APP-REPORTS are unreferenced
            $result.Data.OrphanedEntitlements.Count | Should -BeGreaterOrEqual 3
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-004: Save-SPDisconnectedAppSnapshot creates date-stamped file
# ---------------------------------------------------------------------------

Describe "DA-004: Save-SPDisconnectedAppSnapshot creates date-stamped file" {

    Context "When saving a valid account file" {
        It "Should create a date-stamped snapshot in the correct directory" {
            $snapshotDir = Join-Path $TestDrive 'Snapshots'

            $result = Save-SPDisconnectedAppSnapshot `
                -FilePath $script:Day1Accounts `
                -AppName 'TestApp' `
                -FileType 'accounts' `
                -SnapshotDir $snapshotDir

            $result.Success | Should -Be $true
            $result.Data    | Should -Not -BeNullOrEmpty
            Test-Path -Path $result.Data | Should -Be $true
            $result.Data | Should -Match '\d{4}-\d{2}-\d{2}-accounts\.csv$'
        }
    }

    Context "When the source file does not exist" {
        It "Should return Success=false" {
            $result = Save-SPDisconnectedAppSnapshot `
                -FilePath (Join-Path $TestDrive 'nope.csv') `
                -AppName 'TestApp' `
                -FileType 'accounts' `
                -SnapshotDir (Join-Path $TestDrive 'Snapshots')

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'not found'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-005: Get-SPDisconnectedAppPreviousSnapshot returns correct file
# ---------------------------------------------------------------------------

Describe "DA-005: Get-SPDisconnectedAppPreviousSnapshot returns correct file" {

    Context "When previous snapshots exist" {
        BeforeAll {
            # Set up a snapshot directory with two previous dates and today's
            $script:SnapshotDir005 = Join-Path $TestDrive 'snap005'
            $appDir = Join-Path $script:SnapshotDir005 'TestApp'
            New-Item -Path $appDir -ItemType Directory -Force | Out-Null

            $today     = (Get-Date).ToString('yyyy-MM-dd')
            $yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
            $twoDaysAgo = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd')

            # Create fake snapshot files
            'data' | Set-Content (Join-Path $appDir "${twoDaysAgo}-accounts.csv") -Encoding UTF8
            'data' | Set-Content (Join-Path $appDir "${yesterday}-accounts.csv")  -Encoding UTF8
            'data' | Set-Content (Join-Path $appDir "${today}-accounts.csv")      -Encoding UTF8
        }

        It "Should return yesterday's snapshot (not today's)" {
            $result = Get-SPDisconnectedAppPreviousSnapshot `
                -AppName 'TestApp' `
                -FileType 'accounts' `
                -SnapshotDir $script:SnapshotDir005

            $result.Success | Should -Be $true
            $result.Data    | Should -Not -BeNullOrEmpty

            $yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
            $result.Data | Should -Match "$yesterday-accounts\.csv$"
        }
    }

    Context "When no previous snapshots exist (first run)" {
        BeforeAll {
            $script:EmptySnapshotDir = Join-Path $TestDrive 'snap005-empty'
            # Don't create the directory at all -- simulates first run
        }

        It "Should return Success=true with null Data" {
            $result = Get-SPDisconnectedAppPreviousSnapshot `
                -AppName 'TestApp' `
                -FileType 'accounts' `
                -SnapshotDir $script:EmptySnapshotDir

            $result.Success | Should -Be $true
            $result.Data    | Should -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-006: Compare-SPDisconnectedAppFiles detects added accounts
# ---------------------------------------------------------------------------

Describe "DA-006: Compare-SPDisconnectedAppFiles detects added accounts" {

    Context "When day2 has a new account (EMP10006) compared to day1" {
        It "Should detect EMP10006 as added" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            $result.Success | Should -Be $true

            # Day2 adds EMP10006 (Bob Wilson)
            $addedIds = @($result.Data.Added | ForEach-Object { $_.Account.id })
            $addedIds | Should -Contain 'EMP10006'
        }

        It "Should detect EMP10002 as removed" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            # Day2 removes EMP10002 (Jane Doe)
            $removedIds = @($result.Data.Removed | ForEach-Object { $_.Account.id })
            $removedIds | Should -Contain 'EMP10002'
        }

        It "Should produce a correct summary" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            $result.Data.Summary.TotalCurrent  | Should -Be 5
            $result.Data.Summary.TotalPrevious | Should -Be 5
            $result.Data.Summary.Added         | Should -Be 1
            $result.Data.Summary.Removed       | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-007: Compare-SPDisconnectedAppFiles detects entitlement grants
# ---------------------------------------------------------------------------

Describe "DA-007: Compare-SPDisconnectedAppFiles detects entitlement grants" {

    Context "When day2 grants a new entitlement to an existing account" {
        It "Should detect APP-REPORTS granted to EMP10003" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            $result.Success | Should -Be $true

            # Day1: EMP10003 has APP-ADMIN,APP-POWERUSER
            # Day2: EMP10003 has APP-ADMIN,APP-POWERUSER,APP-REPORTS
            $grants = @($result.Data.GrantedEntitlements)
            $emp10003Grant = $grants | Where-Object { $_['AccountId'] -eq 'EMP10003' }

            $emp10003Grant | Should -Not -BeNullOrEmpty
            $emp10003Grant['Entitlements'] | Should -Contain 'APP-REPORTS'
        }

        It "Should report EntitlementsGranted count in summary" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            $result.Data.Summary.EntitlementsGranted | Should -BeGreaterOrEqual 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-008: Compare-SPDisconnectedAppFiles handles first run (no previous)
# ---------------------------------------------------------------------------

Describe "DA-008: Compare-SPDisconnectedAppFiles handles first run (no previous)" {

    Context "When PreviousFilePath is null (first run)" {
        It "Should treat all current accounts as Added" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day1Accounts `
                -PreviousFilePath $null

            $result.Success | Should -Be $true

            # Day1 has 5 accounts -- all should be Added on first run
            $result.Data.Added.Count           | Should -Be 5
            $result.Data.Removed.Count         | Should -Be 0
            $result.Data.Summary.TotalPrevious | Should -Be 0
        }
    }

    Context "When PreviousFilePath is empty string (first run)" {
        It "Should treat all current accounts as Added" {
            $result = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day1Accounts `
                -PreviousFilePath ''

            $result.Success | Should -Be $true
            $result.Data.Added.Count | Should -Be 5
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-009: Resolve-SPDisconnectedAppIdentities maps email to ISC identity
# ---------------------------------------------------------------------------

Describe "DA-009: Resolve-SPDisconnectedAppIdentities maps email to ISC identity (mocked)" {

    Context "When ISC search returns a matching identity" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }

            # Mock the API search -- returns one identity for any email query
            Mock Invoke-SPApiRequest -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @(
                        [PSCustomObject]@{
                            id          = 'isc-id-001'
                            displayName = 'Bob Wilson'
                            name        = 'bwilson'
                        }
                    )
                    Error      = $null
                }
            }

            # Mock manager detail resolution
            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DisconnectedAppRunner {
                return @{
                    IdentityId  = $IdentityId
                    DisplayName = 'Bob Wilson'
                    ManagerId   = 'mgr-001'
                    ManagerName = 'Sarah Manager'
                    IsActive    = $true
                }
            }

            # Clear the module-scope identity cache before each test
            & (Get-Module SP.DisconnectedAppRunner) { $script:EmailToIdentityCache = @{} }
        }

        It "Should resolve added accounts to ISC identities" {
            # Build a minimal delta result with one Added account
            $deltaResult = @{
                Added = @(
                    @{
                        Account   = [PSCustomObject]@{
                            id         = 'EMP10006'
                            name       = 'bwilson'
                            givenName  = 'Bob'
                            familyName = 'Wilson'
                            'e-mail'   = 'bob.wilson@corp.com'
                            department = 'HR'
                            groups     = 'APP-READONLY,APP-REPORTS'
                            IIQDisabled = 'false'
                        }
                        NewGroups = @('APP-READONLY', 'APP-REPORTS')
                    }
                )
                Enabled             = @()
                GrantedEntitlements = @()
            }

            $result = Resolve-SPDisconnectedAppIdentities -DeltaResult $deltaResult

            $result.Success | Should -Be $true
            $result.Data.Resolved.Count   | Should -Be 1
            $result.Data.Unresolved.Count | Should -Be 0
            $result.Data.Resolved[0]['IdentityId']  | Should -Be 'isc-id-001'
            $result.Data.Resolved[0]['ManagerId']   | Should -Be 'mgr-001'
            $result.Data.Resolved[0]['ManagerName'] | Should -Be 'Sarah Manager'
        }

        It "Should track unresolved accounts when ISC returns no results" {
            # Override the mock to return empty results
            Mock Invoke-SPApiRequest -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success    = $true
                    StatusCode = 200
                    Data       = @()
                    Error      = $null
                }
            }

            $deltaResult = @{
                Added = @(
                    @{
                        Account   = [PSCustomObject]@{
                            id         = 'EMP99999'
                            name       = 'nobody'
                            givenName  = 'No'
                            familyName = 'Body'
                            'e-mail'   = 'nobody@corp.com'
                            department = 'Unknown'
                            groups     = ''
                            IIQDisabled = 'false'
                        }
                        NewGroups = @()
                    }
                )
                Enabled             = @()
                GrantedEntitlements = @()
            }

            $result = Resolve-SPDisconnectedAppIdentities -DeltaResult $deltaResult

            $result.Success | Should -Be $true
            $result.Data.Resolved.Count   | Should -Be 0
            $result.Data.Unresolved.Count | Should -Be 1
            $result.Data.Unresolved[0]['AccountId'] | Should -Be 'EMP99999'
        }
    }

    Context "When no campaign-triggering changes exist" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should return empty resolved and unresolved arrays" {
            $deltaResult = @{
                Added               = @()
                Enabled             = @()
                GrantedEntitlements = @()
            }

            $result = Resolve-SPDisconnectedAppIdentities -DeltaResult $deltaResult

            $result.Success | Should -Be $true
            $result.Data.Resolved.Count   | Should -Be 0
            $result.Data.Unresolved.Count | Should -Be 0
            $result.Data.Summary.TotalAccounts | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-010: Export-SPDisconnectedAppDeltaHtml generates valid HTML
# ---------------------------------------------------------------------------

Describe "DA-010: Export-SPDisconnectedAppDeltaHtml generates valid HTML" {

    Context "When given a delta result with changes" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should create an HTML file with correct sections" {
            # Run actual delta detection on test data
            $delta = Compare-SPDisconnectedAppFiles `
                -CurrentFilePath $script:Day2Accounts `
                -PreviousFilePath $script:Day1Accounts

            $outputDir = Join-Path $TestDrive 'Reports'

            $result = Export-SPDisconnectedAppDeltaHtml `
                -DeltaResult $delta.Data `
                -AppName 'TestApp' `
                -OutputPath $outputDir `
                -ReportDate '2026-05-28'

            $result.Success | Should -Be $true
            $result.Data.FilePath | Should -Not -BeNullOrEmpty
            Test-Path -Path $result.Data.FilePath | Should -Be $true

            # Verify file path naming
            $result.Data.FilePath | Should -Match 'delta-2026-05-28\.html$'

            # Read and verify HTML content
            $htmlContent = Get-Content -Path $result.Data.FilePath -Raw

            # Should be valid HTML
            $htmlContent | Should -Match '<!DOCTYPE html>'
            $htmlContent | Should -Match '</html>'

            # Should contain the app name
            $htmlContent | Should -Match 'TestApp'

            # Should contain ADDED section (EMP10006 was added)
            $htmlContent | Should -Match 'ADDED'
            $htmlContent | Should -Match 'EMP10006'

            # Should contain REMOVED section (EMP10002 was removed)
            $htmlContent | Should -Match 'REMOVED'
            $htmlContent | Should -Match 'EMP10002'

            # Should contain entitlement changes (EMP10003 got APP-REPORTS)
            $htmlContent | Should -Match 'GRANTED'

            # Should contain footer with timestamp
            $htmlContent | Should -Match 'Generated by SailPoint Governance Toolkit'
        }
    }

    Context "When given a delta result with no changes" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should create an HTML file with a no-changes notice" {
            $emptyDelta = @{
                Added               = @()
                Removed             = @()
                Disabled            = @()
                Enabled             = @()
                GrantedEntitlements = @()
                RevokedEntitlements = @()
                AttributeChanges   = @()
                Unchanged           = 5
                Summary             = @{
                    TotalCurrent        = 5
                    TotalPrevious       = 5
                    Added               = 0
                    Removed             = 0
                    Disabled            = 0
                    Enabled             = 0
                    EntitlementsGranted = 0
                    EntitlementsRevoked = 0
                    AttributeChanges   = 0
                    Unchanged           = 5
                }
            }

            $outputDir = Join-Path $TestDrive 'ReportsEmpty'

            $result = Export-SPDisconnectedAppDeltaHtml `
                -DeltaResult $emptyDelta `
                -AppName 'NoChangesApp' `
                -OutputPath $outputDir `
                -ReportDate '2026-05-28'

            $result.Success | Should -Be $true

            $htmlContent = Get-Content -Path $result.Data.FilePath -Raw
            $htmlContent | Should -Match 'No changes detected'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-011: Invoke-SPDisconnectedAppCert.ps1 syntax validation
# ---------------------------------------------------------------------------

Describe "DA-011: Invoke-SPDisconnectedAppCert.ps1 syntax validation" {

    Context "Script file syntax" {
        BeforeAll {
            $script:CliScriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDisconnectedAppCert.ps1'
        }

        It "Should exist on disk" {
            Test-Path -Path $script:CliScriptPath | Should -Be $true
        }

        It "Should parse without syntax errors" {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $script:CliScriptPath).Path,
                [ref]$null,
                [ref]$parseErrors
            )

            $parseErrors.Count | Should -Be 0
        }
    }
}

#endregion
