#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for SP.DisconnectedApps modules
.DESCRIPTION
    Tests: DA-001 through DA-011, DA-12-T through DA-20-T, DA-21-T through DA-29-T
    Covers:
        DA-001 to DA-002: Test-SPDisconnectedAppAccountFile  -- missing columns, duplicate IDs
        DA-003:           Test-SPDisconnectedAppCrossReference -- unmatched groups
        DA-004:           Save-SPDisconnectedAppSnapshot       -- date-stamped file creation
        DA-005:           Get-SPDisconnectedAppPreviousSnapshot -- correct file retrieval
        DA-006 to DA-008: Compare-SPDisconnectedAppFiles       -- added accounts, entitlement grants, first run
        DA-009:           Resolve-SPDisconnectedAppIdentities   -- email-to-ISC identity mapping (mocked)
        DA-010:           Export-SPDisconnectedAppDeltaHtml     -- valid HTML generation
        DA-011:           Invoke-SPDisconnectedAppCert.ps1      -- CLI script syntax validation
        DA-12-T:          Get-SPRegisteredApps                  -- enabled filter + default merge
        DA-13-T:          App registration config manipulation  -- adds to Applications array
        DA-14-T:          Test-SPDisconnectedAppDeletionThreshold -- blocks at 50% removal
        DA-14-T2:         Threshold first-run + too-few-accounts -- always allowed
        DA-15-T:          Invoke-SPDisconnectedAppBatch.ps1     -- CLI script syntax validation
        DA-16-T:          Get-SPDisconnectedAppDeliveryStatus   -- Delivered vs Missing vs Disabled
        DA-17-T:          Get-SPDisconnectedAppIdentityRisk     -- cross-app risk classification
        DA-18-T:          Get-SPDisconnectedAppEntitlementCatalog -- multi-app aggregation
        DA-19-T:          Export-SPDisconnectedAppBatchHtml      -- valid HTML with mixed statuses
        DA-20-T:          Get-SPDisconnectedAppSlaStatus         -- delivery rate from snapshots
        DA-21-T:          Get-SPDisconnectedAppCampaignDecisions -- decision harvest from ISC (mocked)
        DA-22-T:          New-SPRemediationRecord                -- PENDING record creation
        DA-22-T2:         Update-SPRemediationStatus             -- CONFIRMED on entitlement absence
        DA-22-T3:         Update-SPRemediationStatus             -- OVERDUE after threshold days
        DA-23-T:          Invoke-SPDailyOrchestrator.ps1         -- disconnected app steps (7,8,9)
        DA-24-T:          Push-SPDisconnectedAppToISC            -- API upload + FileDrop (mocked)
        DA-25-T:          Send-SPDisconnectedAppAlert            -- threshold block alert
        DA-26-T:          Invoke-SPDisconnectedAppCleanup        -- past-due campaign completion
        DA-28-T:          Invoke-SPDisconnectedAppEscalation     -- prefix-filtered escalation
        DA-29-T:          Export-SPDisconnectedAppTeamDashboard   -- HTML dashboard with delivery status

    Note on mock-scoping:
        DA-009 mocks cross-module calls (Invoke-SPApiRequest, Get-SPDeltaIdentityDetail) within
        SP.DisconnectedAppRunner. On PS 5.1 Desktop -ModuleName targets the top-level .psm1 loaded
        by Import-SPTestModules. On PS7 + Pester 5 strict scoping they may need adjustment.
        DA-12-T through DA-20-T mock Get-SPConfig and Get-SPRegisteredApps within
        SP.DisconnectedAppRunner for the same reason.
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
            Mock Write-SPLog -ModuleName SP.DisconnectedAppReports { }
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
            Mock Write-SPLog -ModuleName SP.DisconnectedAppReports { }
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

# ---------------------------------------------------------------------------
#region DA-12-T: Get-SPRegisteredApps returns only enabled apps
# ---------------------------------------------------------------------------

Describe "DA-12-T: Get-SPRegisteredApps returns only enabled apps" {

    Context "When config has enabled and disabled apps" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
            Mock Get-SPConfig -ModuleName SP.DisconnectedAppRunner {
                return [PSCustomObject]@{
                    DisconnectedApps = [PSCustomObject]@{
                        ImportBasePath              = (Join-Path $TestDrive 'Imports')
                        SnapshotPath                = (Join-Path $TestDrive 'Snapshots')
                        ReportPath                  = (Join-Path $TestDrive 'Reports')
                        DefaultCampaignNamePrefix   = 'DA Cert'
                        DefaultDeadlineDays         = 2
                        CorrelationAttribute        = 'e-mail'
                        AccountDeletionThresholdPct = 20
                        Applications = @(
                            [PSCustomObject]@{ Name = 'AppA'; AccountFilePath = '\\srv\a.csv'; Enabled = $true },
                            [PSCustomObject]@{ Name = 'AppB'; AccountFilePath = '\\srv\b.csv'; Enabled = $false },
                            [PSCustomObject]@{ Name = 'AppC'; AccountFilePath = '\\srv\c.csv'; Enabled = $true }
                        )
                    }
                }
            }
        }

        It "Should return 2 enabled apps and exclude the disabled one" {
            $result = Get-SPRegisteredApps
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 2
            $names = @($result.Data | ForEach-Object { $_.Name })
            $names | Should -Contain 'AppA'
            $names | Should -Contain 'AppC'
            $names | Should -Not -Contain 'AppB'
        }

        It "Should return all 3 apps when IncludeDisabled is set" {
            $result = Get-SPRegisteredApps -IncludeDisabled
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 3
        }

        It "Should merge per-app fields with global defaults" {
            $result = Get-SPRegisteredApps
            $result.Data[0].CampaignNamePrefix          | Should -Be 'DA Cert'
            $result.Data[0].DeadlineDays                | Should -Be 2
            $result.Data[0].AccountDeletionThresholdPct | Should -Be 20
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-13-T: App registration adds to Applications array
# ---------------------------------------------------------------------------

Describe "DA-13-T: App registration adds to Applications array" {

    Context "When adding a new app entry to settings.json" {
        BeforeAll {
            $script:TempConfigPath13 = Join-Path $TestDrive 'settings-da13.json'
            $configObj = @{
                DisconnectedApps = @{
                    ImportBasePath              = (Join-Path $TestDrive 'Imports')
                    SnapshotPath                = (Join-Path $TestDrive 'Snapshots')
                    ReportPath                  = (Join-Path $TestDrive 'Reports')
                    DefaultCampaignNamePrefix   = 'Test Cert'
                    DefaultDeadlineDays         = 2
                    AccountDeletionThresholdPct = 20
                    Applications = @(
                        @{
                            Name            = 'ExistingApp'
                            AccountFilePath = '\\srv\existing.csv'
                            Enabled         = $true
                        }
                    )
                }
            }
            $json = $configObj | ConvertTo-Json -Depth 10
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($script:TempConfigPath13, $json, $utf8NoBom)
        }

        It "Should persist a new app entry into the config file" {
            # Simulate registration (same logic as CLI script)
            $rawConfig = Get-Content -Path $script:TempConfigPath13 -Raw | ConvertFrom-Json
            $apps = @($rawConfig.DisconnectedApps.Applications)

            $newApp = [PSCustomObject]@{
                Name                 = 'NewApp'
                AccountFilePath      = '\\srv\new.csv'
                EntitlementFilePath  = ''
                ISCSourceId          = ''
                CorrelationAttribute = 'e-mail'
                CampaignNamePrefix   = 'New Cert'
                DeadlineDays         = 3
                SlaDays              = 1
                Enabled              = $true
            }

            $updatedApps = [System.Collections.Generic.List[object]]::new()
            foreach ($a in $apps) { if ($null -ne $a) { $updatedApps.Add($a) } }
            $updatedApps.Add($newApp)
            $rawConfig.DisconnectedApps | Add-Member -NotePropertyName 'Applications' `
                -NotePropertyValue $updatedApps.ToArray() -Force

            $json = $rawConfig | ConvertTo-Json -Depth 10
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($script:TempConfigPath13, $json, $utf8NoBom)

            # Read back and verify
            $verify = Get-Content -Path $script:TempConfigPath13 -Raw | ConvertFrom-Json
            $verifyApps = @($verify.DisconnectedApps.Applications)
            $verifyApps.Count | Should -Be 2
            $verifyApps[1].Name | Should -Be 'NewApp'
            $verifyApps[1].DeadlineDays | Should -Be 3
        }

        It "Registry CLI script should parse without syntax errors" {
            $registryScript = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDisconnectedAppRegistry.ps1'
            Test-Path -Path $registryScript | Should -Be $true

            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $registryScript).Path,
                [ref]$null,
                [ref]$parseErrors
            )
            $parseErrors.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-14-T: Test-SPDisconnectedAppDeletionThreshold blocks at 50% removal
# ---------------------------------------------------------------------------

Describe "DA-14-T: Test-SPDisconnectedAppDeletionThreshold blocks at 50% removal" {

    Context "When 50% of accounts are removed (exceeds 20% threshold)" {
        It "Should block processing with ThresholdExceeded reason" {
            $deltaSummary = @{
                TotalPrevious = 10
                TotalCurrent  = 5
                Removed       = 5
                Added         = 0
            }

            $result = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary -ThresholdPct 20

            $result.Allowed      | Should -Be $false
            $result.Reason       | Should -Be 'ThresholdExceeded'
            $result.RemovedPct   | Should -Be 50.0
            $result.RemovedCount | Should -Be 5
            $result.ThresholdPct | Should -Be 20
        }
    }

    Context "When removal is within threshold" {
        It "Should allow processing with OK reason" {
            $deltaSummary = @{
                TotalPrevious = 10
                TotalCurrent  = 9
                Removed       = 1
                Added         = 0
            }

            $result = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary -ThresholdPct 20

            $result.Allowed    | Should -Be $true
            $result.Reason     | Should -Be 'OK'
            $result.RemovedPct | Should -Be 10.0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-14-T2: Threshold allows first run and too-few-accounts
# ---------------------------------------------------------------------------

Describe "DA-14-T2: Threshold allows first run and too-few-accounts" {

    Context "When TotalPrevious is 0 (first run)" {
        It "Should allow processing with FirstRun reason" {
            $deltaSummary = @{
                TotalPrevious = 0
                TotalCurrent  = 10
                Removed       = 0
                Added         = 10
            }

            $result = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary

            $result.Allowed | Should -Be $true
            $result.Reason  | Should -Be 'FirstRun'
        }
    }

    Context "When TotalPrevious is less than 5 (too few for percentage)" {
        It "Should allow processing with TooFewAccounts reason" {
            $deltaSummary = @{
                TotalPrevious = 3
                TotalCurrent  = 0
                Removed       = 3
                Added         = 0
            }

            $result = Test-SPDisconnectedAppDeletionThreshold -DeltaSummary $deltaSummary

            $result.Allowed | Should -Be $true
            $result.Reason  | Should -Be 'TooFewAccounts'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-15-T: Batch orchestrator CLI syntax validation
# ---------------------------------------------------------------------------

Describe "DA-15-T: Batch orchestrator script syntax validation" {

    Context "Invoke-SPDisconnectedAppBatch.ps1" {
        BeforeAll {
            $script:BatchScriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDisconnectedAppBatch.ps1'
        }

        It "Should exist on disk" {
            Test-Path -Path $script:BatchScriptPath | Should -Be $true
        }

        It "Should parse without syntax errors" {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $script:BatchScriptPath).Path,
                [ref]$null,
                [ref]$parseErrors
            )
            $parseErrors.Count | Should -Be 0
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-16-T: Get-SPDisconnectedAppDeliveryStatus classifies Delivered vs Missing
# ---------------------------------------------------------------------------

Describe "DA-16-T: Get-SPDisconnectedAppDeliveryStatus classifies Delivered vs Missing" {

    Context "When apps have fresh, missing, and disabled file statuses" {
        BeforeAll {
            # Create a test account file that will be classified as Delivered
            $script:DeliveredFile = Join-Path $TestDrive 'delivered-accounts.csv'
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'E1,user1,Test,User,test@corp.com,GRP-A,false'
                'E2,user2,Test,User2,test2@corp.com,GRP-B,false'
            ) | Set-Content -Path $script:DeliveredFile -Encoding UTF8

            # Touch the file so it is fresh
            (Get-Item $script:DeliveredFile).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        @{ Name = 'FreshApp';    AccountFilePath = $script:DeliveredFile;                     Enabled = $true },
                        @{ Name = 'MissingApp';  AccountFilePath = (Join-Path $TestDrive 'nonexistent.csv');  Enabled = $true },
                        @{ Name = 'DisabledApp'; AccountFilePath = '\\srv\disabled.csv';                     Enabled = $false }
                    )
                    Error   = $null
                }
            }
        }

        It "Should classify FreshApp as Delivered with row count" {
            $result = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24

            $result.Success | Should -Be $true
            $freshApp = $result.Data.Apps | Where-Object { $_.Name -eq 'FreshApp' }
            $freshApp.Status   | Should -Be 'Delivered'
            $freshApp.RowCount | Should -Be 2
        }

        It "Should classify MissingApp as Missing" {
            $result = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24

            $missingApp = $result.Data.Apps | Where-Object { $_.Name -eq 'MissingApp' }
            $missingApp.Status | Should -Be 'Missing'
        }

        It "Should classify DisabledApp as Disabled" {
            $result = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24

            $disabledApp = $result.Data.Apps | Where-Object { $_.Name -eq 'DisabledApp' }
            $disabledApp.Status | Should -Be 'Disabled'
        }

        It "Should produce correct summary counts" {
            $result = Get-SPDisconnectedAppDeliveryStatus -StaleHours 24

            $result.Data.Summary.Total     | Should -Be 3
            $result.Data.Summary.Delivered | Should -Be 1
            $result.Data.Summary.Missing   | Should -Be 1
            $result.Data.Summary.Disabled  | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-17-T: Cross-app identity risk flags 3+ app identities as High
# ---------------------------------------------------------------------------

Describe "DA-17-T: Cross-app identity risk flags 3+ app identities as High" {

    Context "When identities appear across multiple apps" {
        BeforeAll {
            $script:RiskSnapshotDir = Join-Path $TestDrive 'risk-snapshots'
            $today = (Get-Date).ToString('yyyy-MM-dd')

            # AppAlpha: user1, user2, user3
            $alphaDir = Join-Path $script:RiskSnapshotDir 'AppAlpha'
            New-Item -Path $alphaDir -ItemType Directory -Force | Out-Null
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'A1,user1,Alice,Alpha,user1@corp.com,GRP-A,false'
                'A2,user2,Bob,Alpha,user2@corp.com,GRP-A,false'
                'A3,user3,Carol,Alpha,user3@corp.com,GRP-A,false'
            ) | Set-Content -Path (Join-Path $alphaDir "${today}-accounts.csv") -Encoding UTF8

            # AppBeta: user1, user2
            $betaDir = Join-Path $script:RiskSnapshotDir 'AppBeta'
            New-Item -Path $betaDir -ItemType Directory -Force | Out-Null
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'B1,user1b,Alice,Beta,user1@corp.com,GRP-B,false'
                'B2,user2b,Bob,Beta,user2@corp.com,GRP-B,false'
            ) | Set-Content -Path (Join-Path $betaDir "${today}-accounts.csv") -Encoding UTF8

            # AppGamma: user1 only
            $gammaDir = Join-Path $script:RiskSnapshotDir 'AppGamma'
            New-Item -Path $gammaDir -ItemType Directory -Force | Out-Null
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'G1,user1g,Alice,Gamma,user1@corp.com,GRP-G,false'
            ) | Set-Content -Path (Join-Path $gammaDir "${today}-accounts.csv") -Encoding UTF8
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        @{ Name = 'AppAlpha' },
                        @{ Name = 'AppBeta' },
                        @{ Name = 'AppGamma' }
                    )
                    Error   = $null
                }
            }
        }

        It "Should flag user1 (3 apps) as High risk" {
            $result = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskSnapshotDir

            $result.Success | Should -Be $true
            $user1 = $result.Data.Identities | Where-Object { $_.Email -eq 'user1@corp.com' }
            $user1 | Should -Not -BeNullOrEmpty
            $user1.AppCount | Should -Be 3
            $user1.Risk     | Should -Be 'High'
        }

        It "Should flag user2 (2 apps) as Elevated risk" {
            $result = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskSnapshotDir

            $user2 = $result.Data.Identities | Where-Object { $_.Email -eq 'user2@corp.com' }
            $user2 | Should -Not -BeNullOrEmpty
            $user2.AppCount | Should -Be 2
            $user2.Risk     | Should -Be 'Elevated'
        }

        It "Should flag user3 (1 app) as Normal risk" {
            $result = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskSnapshotDir

            $user3 = $result.Data.Identities | Where-Object { $_.Email -eq 'user3@corp.com' }
            $user3 | Should -Not -BeNullOrEmpty
            $user3.AppCount | Should -Be 1
            $user3.Risk     | Should -Be 'Normal'
        }

        It "Should sort identities by app count descending" {
            $result = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskSnapshotDir

            $ids = $result.Data.Identities
            $ids[0].AppCount | Should -BeGreaterOrEqual $ids[$ids.Count - 1].AppCount
        }

        It "Should produce correct summary counts" {
            $result = Get-SPDisconnectedAppIdentityRisk -SnapshotDir $script:RiskSnapshotDir

            $result.Data.Summary.TotalIdentities | Should -Be 3
            $result.Data.Summary.SingleApp       | Should -Be 1
            $result.Data.Summary.HighRisk        | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-18-T: Entitlement catalog aggregates across multiple apps
# ---------------------------------------------------------------------------

Describe "DA-18-T: Entitlement catalog aggregates across multiple apps" {

    Context "When multiple apps have entitlement and account snapshots" {
        BeforeAll {
            $script:CatalogSnapshotDir = Join-Path $TestDrive 'catalog-snapshots'
            $today = (Get-Date).ToString('yyyy-MM-dd')

            # AppAlpha: 2 entitlements, 3 accounts referencing them
            $alphaDir = Join-Path $script:CatalogSnapshotDir 'AppAlpha'
            New-Item -Path $alphaDir -ItemType Directory -Force | Out-Null
            @(
                'id,name,displayName,description'
                'ENT-A1,ENT-A1,Alpha Admin,Admin access to AppAlpha'
                'ENT-A2,ENT-A2,Alpha Viewer,Read-only access to AppAlpha'
            ) | Set-Content -Path (Join-Path $alphaDir "${today}-entitlements.csv") -Encoding UTF8
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'A1,u1,User,One,u1@corp.com,ENT-A1,false'
                'A2,u2,User,Two,u2@corp.com,"ENT-A1,ENT-A2",false'
                'A3,u3,User,Three,u3@corp.com,ENT-A2,false'
            ) | Set-Content -Path (Join-Path $alphaDir "${today}-accounts.csv") -Encoding UTF8

            # AppBeta: 1 entitlement, 1 account
            $betaDir = Join-Path $script:CatalogSnapshotDir 'AppBeta'
            New-Item -Path $betaDir -ItemType Directory -Force | Out-Null
            @(
                'id,name,displayName,description'
                'ENT-B1,ENT-B1,Beta Admin,Admin access to AppBeta'
            ) | Set-Content -Path (Join-Path $betaDir "${today}-entitlements.csv") -Encoding UTF8
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'B1,ub1,Beta,User,bu1@corp.com,ENT-B1,false'
            ) | Set-Content -Path (Join-Path $betaDir "${today}-accounts.csv") -Encoding UTF8
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        @{ Name = 'AppAlpha' },
                        @{ Name = 'AppBeta' }
                    )
                    Error   = $null
                }
            }
        }

        It "Should aggregate 3 entitlements from 2 apps" {
            $result = Get-SPDisconnectedAppEntitlementCatalog -SnapshotDir $script:CatalogSnapshotDir

            $result.Success                | Should -Be $true
            $result.Data.Catalog.Count     | Should -Be 3
            $result.Data.Summary.TotalApps | Should -Be 2
        }

        It "Should compute correct AssignedCount for each entitlement" {
            $result = Get-SPDisconnectedAppEntitlementCatalog -SnapshotDir $script:CatalogSnapshotDir

            # ENT-A1: assigned to A1 and A2 = 2
            $entA1 = $result.Data.Catalog | Where-Object { $_.EntitlementId -eq 'ENT-A1' }
            $entA1.AssignedCount | Should -Be 2

            # ENT-A2: assigned to A2 and A3 = 2
            $entA2 = $result.Data.Catalog | Where-Object { $_.EntitlementId -eq 'ENT-A2' }
            $entA2.AssignedCount | Should -Be 2

            # ENT-B1: assigned to B1 = 1
            $entB1 = $result.Data.Catalog | Where-Object { $_.EntitlementId -eq 'ENT-B1' }
            $entB1.AssignedCount | Should -Be 1
        }

        It "Should include the source app name for each entitlement" {
            $result = Get-SPDisconnectedAppEntitlementCatalog -SnapshotDir $script:CatalogSnapshotDir

            $alphaEnts = @($result.Data.Catalog | Where-Object { $_.AppName -eq 'AppAlpha' })
            $alphaEnts.Count | Should -Be 2

            $betaEnts = @($result.Data.Catalog | Where-Object { $_.AppName -eq 'AppBeta' })
            $betaEnts.Count | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-19-T: Export-SPDisconnectedAppBatchHtml generates valid HTML
# ---------------------------------------------------------------------------

Describe "DA-19-T: Export-SPDisconnectedAppBatchHtml generates valid HTML" {

    Context "When given batch results with mixed statuses" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppReports { }
        }

        It "Should generate a valid HTML report with all sections" {
            $batchResults = @(
                @{
                    App              = 'AppA'
                    Status           = 'Success'
                    CorrelationID    = 'corr-001'
                    StartedAt        = '2026-05-28T10:00:00Z'
                    CompletedAt      = '2026-05-28T10:00:15Z'
                    DurationSeconds  = 15
                    CampaignsCreated = 1
                    CampaignIds      = @('camp-001')
                    IdentityCount    = 5
                    DeltaSummary     = @{ Added = 2; Removed = 0; Enabled = 1; Granted = 1 }
                    ReportPath       = '.\Reports\AppA'
                    Error            = $null
                    Reason           = $null
                },
                @{
                    App              = 'AppB'
                    Status           = 'Error'
                    CorrelationID    = 'corr-002'
                    StartedAt        = '2026-05-28T10:00:16Z'
                    CompletedAt      = '2026-05-28T10:00:18Z'
                    DurationSeconds  = 2
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    DeltaSummary     = @{ Added = 0; Removed = 0; Enabled = 0; Granted = 0 }
                    ReportPath       = $null
                    Error            = 'CSV validation failed: missing column e-mail'
                    Reason           = 'ValidationError'
                },
                @{
                    App              = 'AppC'
                    Status           = 'NoChanges'
                    CorrelationID    = 'corr-003'
                    StartedAt        = '2026-05-28T10:00:19Z'
                    CompletedAt      = '2026-05-28T10:00:20Z'
                    DurationSeconds  = 1
                    CampaignsCreated = 0
                    CampaignIds      = @()
                    IdentityCount    = 0
                    DeltaSummary     = @{ Added = 0; Removed = 0; Enabled = 0; Granted = 0 }
                    ReportPath       = $null
                    Error            = $null
                    Reason           = $null
                }
            )

            $outputDir = Join-Path $TestDrive 'BatchReports'

            $result = Export-SPDisconnectedAppBatchHtml `
                -BatchResults $batchResults `
                -CorrelationID 'batch-corr-001' `
                -StartedAt '2026-05-28T10:00:00Z' `
                -CompletedAt '2026-05-28T10:00:20Z' `
                -DurationSeconds 20 `
                -OutputPath $outputDir `
                -ReportDate '2026-05-28'

            $result.Success | Should -Be $true
            $result.Data.FilePath | Should -Not -BeNullOrEmpty
            Test-Path -Path $result.Data.FilePath | Should -Be $true

            # Verify HTML structure
            $htmlContent = Get-Content -Path $result.Data.FilePath -Raw

            $htmlContent | Should -Match '<!DOCTYPE html>'
            $htmlContent | Should -Match '</html>'

            # Executive Summary with PARTIAL badge (mixed results)
            $htmlContent | Should -Match 'Executive Summary'
            $htmlContent | Should -Match 'PARTIAL'

            # Per-app status rows
            $htmlContent | Should -Match 'AppA'
            $htmlContent | Should -Match 'SUCCESS'
            $htmlContent | Should -Match 'AppB'
            $htmlContent | Should -Match 'ERROR'
            $htmlContent | Should -Match 'AppC'
            $htmlContent | Should -Match 'NO CHANGES'

            # Error details section with expandable details
            $htmlContent | Should -Match 'Error Details'
            $htmlContent | Should -Match 'CSV validation failed'

            # Footer with toolkit branding
            $htmlContent | Should -Match 'Generated by SailPoint Governance Toolkit'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-20-T: SLA tracking calculates delivery rate from snapshot filenames
# ---------------------------------------------------------------------------

Describe "DA-20-T: SLA tracking calculates delivery rate from snapshot filenames" {

    Context "When apps have varying snapshot histories" {
        BeforeAll {
            $script:SlaSnapshotDir = Join-Path $TestDrive 'sla-snapshots'
            $today = (Get-Date).Date

            # FullApp: delivered every day for the last 30 days
            $fullDir = Join-Path $script:SlaSnapshotDir 'FullApp'
            New-Item -Path $fullDir -ItemType Directory -Force | Out-Null
            for ($d = 0; $d -lt 30; $d++) {
                $dateStr = $today.AddDays(-$d).ToString('yyyy-MM-dd')
                'data' | Set-Content (Join-Path $fullDir "${dateStr}-accounts.csv") -Encoding UTF8
            }

            # GappyApp: 10-day gap (missing days 5 through 14 ago)
            $gappyDir = Join-Path $script:SlaSnapshotDir 'GappyApp'
            New-Item -Path $gappyDir -ItemType Directory -Force | Out-Null
            for ($d = 0; $d -lt 30; $d++) {
                if ($d -ge 5 -and $d -lt 15) { continue }  # skip 10 days
                $dateStr = $today.AddDays(-$d).ToString('yyyy-MM-dd')
                'data' | Set-Content (Join-Path $gappyDir "${dateStr}-accounts.csv") -Encoding UTF8
            }
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }
            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        @{ Name = 'FullApp';  SlaDays = 1 },
                        @{ Name = 'GappyApp'; SlaDays = 1 }
                    )
                    Error   = $null
                }
            }
        }

        It "Should calculate 100% delivery rate for FullApp" {
            $result = Get-SPDisconnectedAppSlaStatus -DaysBack 30 -SnapshotDir $script:SlaSnapshotDir

            $result.Success | Should -Be $true
            $fullApp = $result.Data.Apps | Where-Object { $_.AppName -eq 'FullApp' }
            $fullApp.DeliveryRate  | Should -Be 100.0
            $fullApp.SlaCompliant  | Should -Be $true
            $fullApp.LongestGapDays | Should -Be 0
        }

        It "Should detect the 10-day gap in GappyApp and flag non-compliant" {
            $result = Get-SPDisconnectedAppSlaStatus -DaysBack 30 -SnapshotDir $script:SlaSnapshotDir

            $gappyApp = $result.Data.Apps | Where-Object { $_.AppName -eq 'GappyApp' }
            $gappyApp.DeliveryRate    | Should -BeLessThan 100
            $gappyApp.SlaCompliant    | Should -Be $false
            $gappyApp.LongestGapDays  | Should -BeGreaterOrEqual 10
            $gappyApp.DaysMissing.Count | Should -Be 10
        }

        It "Should produce correct summary" {
            $result = Get-SPDisconnectedAppSlaStatus -DaysBack 30 -SnapshotDir $script:SlaSnapshotDir

            $result.Data.Summary.TotalApps    | Should -Be 2
            $result.Data.Summary.Compliant    | Should -Be 1
            $result.Data.Summary.NonCompliant | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-21-T: Decision collection retrieves campaign decisions from ISC
# ---------------------------------------------------------------------------

Describe "DA-21-T: Decision collection retrieves campaign decisions from ISC (mocked)" {

    Context "When audit trail has campaign IDs and ISC returns completed campaigns" {
        BeforeAll {
            # Set up per-app output directory with JSONL audit trail
            $script:DA21OutputPath = Join-Path $TestDrive 'DA21-Reports'
            $script:DA21AppDir    = Join-Path $script:DA21OutputPath 'TestApp21'
            New-Item -Path $script:DA21AppDir -ItemType Directory -Force | Out-Null

            $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $auditEvent = @{
                Timestamp   = $timestamp
                Action      = 'DisconnectedAppCertRun'
                CampaignIds = @('camp-aaa', 'camp-bbb')
            } | ConvertTo-Json -Compress

            $auditPath = Join-Path $script:DA21AppDir 'disconnected-app-audit.jsonl'
            $auditEvent | Set-Content -Path $auditPath -Encoding UTF8
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppAnalytics { }

            # Mock Get-SPCampaign: camp-aaa completed, camp-bbb active
            Mock Get-SPCampaign -ModuleName SP.DisconnectedAppAnalytics {
                if ($CampaignId -eq 'camp-aaa') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{ id = 'camp-aaa'; status = 'COMPLETED'; name = 'TestApp21 Delta Cert 2026-05-28' }
                        Error   = $null
                    }
                }
                elseif ($CampaignId -eq 'camp-bbb') {
                    return @{
                        Success = $true
                        Data    = [PSCustomObject]@{ id = 'camp-bbb'; status = 'ACTIVE'; name = 'TestApp21 Delta Cert 2026-05-29' }
                        Error   = $null
                    }
                }
                return @{ Success = $false; Data = $null; Error = '404 Not Found' }
            }

            # Mock Get-SPAuditCertifications: one certification per completed campaign
            Mock Get-SPAuditCertifications -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                = 'cert-001'
                            EffectiveReviewer = [PSCustomObject]@{ displayName = 'Manager Smith' }
                        }
                    )
                    Error   = $null
                }
            }

            # Mock Get-SPAuditCertificationItems: 2 approved, 1 revoked
            Mock Get-SPAuditCertificationItems -ModuleName SP.DisconnectedAppAnalytics {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            decision        = 'APPROVE'
                            identitySummary = [PSCustomObject]@{ name = 'Alice' }
                            accountId       = 'EMP001'
                            accessSummary   = [PSCustomObject]@{
                                entitlement = [PSCustomObject]@{ name = 'APP-ADMIN' }
                            }
                            completed       = '2026-05-28T12:00:00Z'
                        },
                        [PSCustomObject]@{
                            decision        = 'APPROVE'
                            identitySummary = [PSCustomObject]@{ name = 'Bob' }
                            accountId       = 'EMP002'
                            accessSummary   = [PSCustomObject]@{
                                entitlement = [PSCustomObject]@{ name = 'APP-VIEWER' }
                            }
                            completed       = '2026-05-28T12:01:00Z'
                        },
                        [PSCustomObject]@{
                            decision        = 'REVOKE'
                            identitySummary = [PSCustomObject]@{ name = 'Carol' }
                            accountId       = 'EMP003'
                            accessSummary   = [PSCustomObject]@{
                                entitlement = [PSCustomObject]@{ name = 'APP-POWERUSER' }
                            }
                            completed       = '2026-05-28T12:02:00Z'
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should return correct decision counts" {
            $result = Get-SPDisconnectedAppCampaignDecisions `
                -AppName 'TestApp21' `
                -OutputPath $script:DA21OutputPath `
                -DaysBack 7

            $result.Success                | Should -Be $true
            $result.Data.CampaignsChecked  | Should -Be 2
            $result.Data.Completed         | Should -Be 1
            $result.Data.Active            | Should -Be 1
            $result.Data.Decisions.Approved | Should -Be 2
            $result.Data.Decisions.Revoked  | Should -Be 1
        }

        It "Should capture revocation details for remediation follow-up" {
            $result = Get-SPDisconnectedAppCampaignDecisions `
                -AppName 'TestApp21' `
                -OutputPath $script:DA21OutputPath `
                -DaysBack 7

            $result.Data.RevocationDetails.Count | Should -Be 1
            $result.Data.RevocationDetails[0].IdentityName | Should -Be 'Carol'
            $result.Data.RevocationDetails[0].AccountId    | Should -Be 'EMP003'
            $result.Data.RevocationDetails[0].Entitlement  | Should -Be 'APP-POWERUSER'
            $result.Data.RevocationDetails[0].ReviewerName | Should -Be 'Manager Smith'
        }

        It "Should return empty data when no audit trail exists" {
            $result = Get-SPDisconnectedAppCampaignDecisions `
                -AppName 'NonexistentApp' `
                -OutputPath $script:DA21OutputPath `
                -DaysBack 7

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'No audit trail found'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-22-T: Remediation tracker creates PENDING record for REVOKE decisions
# ---------------------------------------------------------------------------

Describe "DA-22-T: Remediation tracker creates PENDING record for REVOKE decisions" {

    Context "When revocation details are provided" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should create a PENDING remediation record in tracker JSON" {
            $outputPath = Join-Path $TestDrive 'DA22-Reports'

            $revocations = @(
                @{
                    AppName         = 'TestApp22'
                    CampaignId      = 'camp-111'
                    CertificationId = 'cert-111'
                    IdentityName    = 'Carol'
                    AccountId       = 'EMP003'
                    Entitlement     = 'APP-POWERUSER'
                    ReviewerName    = 'Manager Smith'
                    DecisionDate    = '2026-05-28T12:02:00Z'
                }
            )

            $result = New-SPRemediationRecord `
                -RevocationDetails $revocations `
                -AppName 'TestApp22' `
                -OutputPath $outputPath

            $result.Success      | Should -Be $true
            $result.Data.Created | Should -Be 1
            $result.Data.Skipped | Should -Be 0
            $result.Data.Total   | Should -Be 1

            # Verify file on disk
            $trackerPath = Join-Path $outputPath 'TestApp22\remediation-tracker.json'
            Test-Path -Path $trackerPath | Should -Be $true

            $tracker = Get-Content -Path $trackerPath -Raw | ConvertFrom-Json
            $tracker = @($tracker)
            $tracker.Count          | Should -Be 1
            $tracker[0].Status      | Should -Be 'PENDING'
            $tracker[0].AccountId   | Should -Be 'EMP003'
            $tracker[0].Entitlement | Should -Be 'APP-POWERUSER'
        }

        It "Should skip duplicate records on re-run" {
            $outputPath = Join-Path $TestDrive 'DA22-Dupes'

            $revocations = @(
                @{
                    AppName    = 'TestApp22'
                    CampaignId = 'camp-222'
                    AccountId  = 'EMP004'
                    Entitlement = 'APP-ADMIN'
                    IdentityName = 'Dave'
                    ReviewerName = 'Manager Jones'
                    DecisionDate = '2026-05-28T14:00:00Z'
                }
            )

            # First call creates the record
            New-SPRemediationRecord -RevocationDetails $revocations -AppName 'TestApp22' -OutputPath $outputPath

            # Second call should skip (duplicate)
            $result = New-SPRemediationRecord -RevocationDetails $revocations -AppName 'TestApp22' -OutputPath $outputPath

            $result.Data.Created | Should -Be 0
            $result.Data.Skipped | Should -Be 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-22-T2: Remediation confirmed when entitlement absent from next-day CSV
# ---------------------------------------------------------------------------

Describe "DA-22-T2: Remediation confirmed when entitlement absent from next-day CSV" {

    Context "When the revoked entitlement is no longer in today's CSV" {
        BeforeAll {
            $script:DA22T2OutputPath = Join-Path $TestDrive 'DA22T2-Reports'
            $script:DA22T2AppDir     = Join-Path $script:DA22T2OutputPath 'TestApp22T2'
            New-Item -Path $script:DA22T2AppDir -ItemType Directory -Force | Out-Null

            # Pre-create a tracker with one PENDING record
            $tracker = @(
                [ordered]@{
                    RecordId       = 'rec-001'
                    AppName        = 'TestApp22T2'
                    AccountId      = 'EMP003'
                    Entitlement    = 'APP-POWERUSER'
                    IdentityName   = 'Carol'
                    ReviewerName   = 'Manager Smith'
                    CampaignId     = 'camp-111'
                    CertificationId = 'cert-111'
                    DecisionDate   = '2026-05-28T12:02:00Z'
                    Status         = 'PENDING'
                    CreatedAt      = '2026-05-28T12:05:00Z'
                    ConfirmedAt    = $null
                    DaysOverdue    = 0
                    EscalatedAt    = $null
                    CorrelationID  = 'corr-001'
                }
            )
            $trackerJson = $tracker | ConvertTo-Json -Depth 5
            $trackerJson = "[$trackerJson]"
            $trackerPath = Join-Path $script:DA22T2AppDir 'remediation-tracker.json'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trackerPath, $trackerJson, $utf8NoBom)

            # Create an account CSV WITHOUT EMP003's APP-POWERUSER entitlement
            $script:DA22T2AccountFile = Join-Path $TestDrive 'da22t2-accounts.csv'
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'EMP001,alice,Alice,Alpha,alice@corp.com,APP-ADMIN,false'
                'EMP003,carol,Carol,Gamma,carol@corp.com,APP-VIEWER,false'
            ) | Set-Content -Path $script:DA22T2AccountFile -Encoding UTF8
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should mark remediation as CONFIRMED when entitlement is absent" {
            $result = Update-SPRemediationStatus `
                -AppName 'TestApp22T2' `
                -AccountFilePath $script:DA22T2AccountFile `
                -OutputPath $script:DA22T2OutputPath `
                -OverdueDays 3

            $result.Success        | Should -Be $true
            $result.Data.Confirmed | Should -Be 1
            $result.Data.Overdue   | Should -Be 0
            $result.Data.Pending   | Should -Be 0

            # Verify tracker file updated
            $trackerPath = Join-Path $script:DA22T2AppDir 'remediation-tracker.json'
            $updated = @(Get-Content -Path $trackerPath -Raw | ConvertFrom-Json)
            $updated[0].Status      | Should -Be 'CONFIRMED'
            $updated[0].ConfirmedAt | Should -Not -BeNullOrEmpty
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-22-T3: Remediation marked OVERDUE after threshold days
# ---------------------------------------------------------------------------

Describe "DA-22-T3: Remediation marked OVERDUE after threshold days" {

    Context "When the entitlement is still present and decision is older than threshold" {
        BeforeAll {
            $script:DA22T3OutputPath = Join-Path $TestDrive 'DA22T3-Reports'
            $script:DA22T3AppDir     = Join-Path $script:DA22T3OutputPath 'TestApp22T3'
            New-Item -Path $script:DA22T3AppDir -ItemType Directory -Force | Out-Null

            # Create a tracker with PENDING record from 5 days ago
            $oldDate = (Get-Date).ToUniversalTime().AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $tracker = @(
                [ordered]@{
                    RecordId       = 'rec-002'
                    AppName        = 'TestApp22T3'
                    AccountId      = 'EMP005'
                    Entitlement    = 'APP-ADMIN'
                    IdentityName   = 'Eve'
                    ReviewerName   = 'Manager Clark'
                    CampaignId     = 'camp-333'
                    CertificationId = 'cert-333'
                    DecisionDate   = $oldDate
                    Status         = 'PENDING'
                    CreatedAt      = $oldDate
                    ConfirmedAt    = $null
                    DaysOverdue    = 0
                    EscalatedAt    = $null
                    CorrelationID  = 'corr-003'
                }
            )
            $trackerJson = $tracker | ConvertTo-Json -Depth 5
            $trackerJson = "[$trackerJson]"
            $trackerPath = Join-Path $script:DA22T3AppDir 'remediation-tracker.json'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($trackerPath, $trackerJson, $utf8NoBom)

            # Account CSV still contains EMP005 with APP-ADMIN
            $script:DA22T3AccountFile = Join-Path $TestDrive 'da22t3-accounts.csv'
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'EMP005,eve,Eve,Echo,eve@corp.com,APP-ADMIN,false'
            ) | Set-Content -Path $script:DA22T3AccountFile -Encoding UTF8
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should mark remediation as OVERDUE with correct DaysOverdue" {
            $result = Update-SPRemediationStatus `
                -AppName 'TestApp22T3' `
                -AccountFilePath $script:DA22T3AccountFile `
                -OutputPath $script:DA22T3OutputPath `
                -OverdueDays 3

            $result.Success       | Should -Be $true
            $result.Data.Overdue  | Should -Be 1
            $result.Data.Confirmed | Should -Be 0

            # Verify tracker file
            $trackerPath = Join-Path $script:DA22T3AppDir 'remediation-tracker.json'
            $updated = @(Get-Content -Path $trackerPath -Raw | ConvertFrom-Json)
            $updated[0].Status      | Should -Be 'OVERDUE'
            $updated[0].DaysOverdue | Should -BeGreaterOrEqual 5
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-23-T: Unified orchestrator has disconnected app pipeline steps
# ---------------------------------------------------------------------------

Describe "DA-23-T: Unified orchestrator supports disconnected app pipeline" {

    Context "Invoke-SPDailyOrchestrator.ps1 integration" {
        BeforeAll {
            $script:OrchestratorPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPDailyOrchestrator.ps1'
        }

        It "Should parse without syntax errors" {
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $script:OrchestratorPath).Path,
                [ref]$null,
                [ref]$parseErrors
            )
            $parseErrors.Count | Should -Be 0
        }

        It "Should have the SkipDisconnectedApps parameter" {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Resolve-Path $script:OrchestratorPath).Path,
                [ref]$tokens,
                [ref]$parseErrors
            )

            $paramBlock = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) |
                Select-Object -First 1

            $paramNames = @($paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $paramNames | Should -Contain 'SkipDisconnectedApps'
        }

        It "Should contain disconnected app step references (Step 7, 8, 9)" {
            $content = Get-Content -Path (Resolve-Path $script:OrchestratorPath).Path -Raw
            $content | Should -Match 'Step 7.*Disconnected App'
            $content | Should -Match 'Step 8.*Decision Collection'
            $content | Should -Match 'Step 9.*Remediation'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-24-T: Push-SPDisconnectedAppToISC calls API upload endpoint (mocked)
# ---------------------------------------------------------------------------

Describe "DA-24-T: Push-SPDisconnectedAppToISC calls API upload endpoint (mocked)" {

    Context "When ISCSourceId is empty (not configured)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should skip gracefully with Reason=NoISCSourceId" {
            $result = Push-SPDisconnectedAppToISC `
                -AppName 'TestApp24' `
                -AccountFilePath $script:Day1Accounts `
                -ISCSourceId ''

            $result.Success            | Should -Be $true
            $result.Data.Method        | Should -Be 'Skipped'
            $result.Data.Reason        | Should -Be 'NoISCSourceId'
        }
    }

    Context "When using FileDrop upload method" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
        }

        It "Should copy CSV to the file drop path" {
            $dropDir = Join-Path $TestDrive 'VA-Drop'

            $result = Push-SPDisconnectedAppToISC `
                -AppName 'TestApp24' `
                -AccountFilePath $script:Day1Accounts `
                -ISCSourceId 'src-abc-123' `
                -UploadMethod 'FileDrop' `
                -FileDropPath $dropDir

            $result.Success     | Should -Be $true
            $result.Data.Method | Should -Be 'FileDrop'
            $result.Data.AggregationStatus | Should -Be 'FileDropped'

            # Verify the file was actually copied
            $copiedFile = Join-Path $dropDir 'TestApp24\accounts.csv'
            Test-Path -Path $copiedFile | Should -Be $true
        }
    }

    Context "When using API upload method (mocked)" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }

            Mock Get-SPAuthToken -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @{
                        Headers = @{ 'Authorization' = 'Bearer mock-token' }
                    }
                    Error   = $null
                }
            }

            Mock Get-SPConfig -ModuleName SP.DisconnectedAppRunner {
                return [PSCustomObject]@{
                    Api = [PSCustomObject]@{
                        BaseUrl        = 'https://test.api.identitynow.com'
                        TimeoutSeconds = 30
                    }
                }
            }

            Mock Invoke-RestMethod -ModuleName SP.DisconnectedAppRunner {
                return [PSCustomObject]@{
                    task = [PSCustomObject]@{ id = 'task-xyz-999' }
                }
            }
        }

        It "Should call the API and return the task ID" {
            $result = Push-SPDisconnectedAppToISC `
                -AppName 'TestApp24' `
                -AccountFilePath $script:Day1Accounts `
                -ISCSourceId 'src-abc-123' `
                -UploadMethod 'API'

            $result.Success     | Should -Be $true
            $result.Data.Method | Should -Be 'API'
            $result.Data.TaskId | Should -Be 'task-xyz-999'

            # Verify Invoke-RestMethod was called
            Should -Invoke Invoke-RestMethod -ModuleName SP.DisconnectedAppRunner -Times 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-25-T: Alert triggered on threshold block
# ---------------------------------------------------------------------------

Describe "DA-25-T: Alert triggered on threshold block" {

    Context "When a ThresholdBlocked alert is sent" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }

            # Mock Send-SPNotification as unavailable to test log-only fallback
            Mock Get-Command -ModuleName SP.DisconnectedAppRunner {
                if ($Name -eq 'Send-SPNotification') { return $null }
                # Default: delegate to real Get-Command
                Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
            }
        }

        It "Should return Success with correct alert metadata" {
            $result = Send-SPDisconnectedAppAlert `
                -AlertType 'ThresholdBlocked' `
                -Severity 'CRITICAL' `
                -AppName 'TestApp25' `
                -Message '42% accounts removed (threshold: 20%)' `
                -Details @{ RemovedPct = 42; ThresholdPct = 20 }

            $result.Success           | Should -Be $true
            $result.Data.AlertType    | Should -Be 'ThresholdBlocked'
            $result.Data.Severity     | Should -Be 'CRITICAL'
            $result.Data.Subject      | Should -Match 'ThresholdBlocked'
            $result.Data.Subject      | Should -Match 'CRITICAL'
            $result.Data.Subject      | Should -Match 'TestApp25'
        }

        It "Should fall back to LogOnly when Send-SPNotification is unavailable" {
            $result = Send-SPDisconnectedAppAlert `
                -AlertType 'BatchAllFailed' `
                -Severity 'CRITICAL' `
                -Message 'All apps failed'

            $result.Data.Backend | Should -Be 'LogOnly'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-26-T: Cleanup completes past-due disconnected app campaigns
# ---------------------------------------------------------------------------

Describe "DA-26-T: Cleanup completes past-due disconnected app campaigns" {

    Context "When AllowCompleteCampaign is false" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }
            Mock Get-SPConfig -ModuleName SP.DisconnectedAppRunner {
                return [PSCustomObject]@{
                    Safety = [PSCustomObject]@{ AllowCompleteCampaign = $false }
                }
            }
        }

        It "Should block cleanup with a clear error message" {
            $result = Invoke-SPDisconnectedAppCleanup

            $result.Success | Should -Be $false
            $result.Error   | Should -Match 'AllowCompleteCampaign'
        }
    }

    Context "When AllowCompleteCampaign is true and stale campaigns exist" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }

            Mock Get-SPConfig -ModuleName SP.DisconnectedAppRunner {
                return [PSCustomObject]@{
                    Safety = [PSCustomObject]@{ AllowCompleteCampaign = $true }
                }
            }

            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            Name               = 'CleanupApp'
                            CampaignNamePrefix = 'CleanupApp Delta Cert'
                        }
                    )
                    Error   = $null
                }
            }

            # Return one stale campaign (created 5 days ago, past deadline)
            $staleDeadline = (Get-Date).ToUniversalTime().AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $staleCreated  = (Get-Date).ToUniversalTime().AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')

            Mock Search-SPCampaigns -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id       = 'camp-stale-001'
                            name     = 'CleanupApp Delta Cert 2026-05-24'
                            status   = 'ACTIVE'
                            deadline = $staleDeadline
                            created  = $staleCreated
                        }
                    )
                    Error   = $null
                }
            }

            Mock Complete-SPCampaign -ModuleName SP.DisconnectedAppRunner {
                return @{ Success = $true; Data = @{ id = $CampaignId }; Error = $null }
            }
        }

        It "Should complete the past-due campaign" {
            $result = Invoke-SPDisconnectedAppCleanup -DaysStale 3

            $result.Success              | Should -Be $true
            $result.Data.TotalCompleted  | Should -Be 1
            $result.Data.AppsChecked     | Should -Be 1

            # Verify Complete-SPCampaign was called
            Should -Invoke Complete-SPCampaign -ModuleName SP.DisconnectedAppRunner -Times 1
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-28-T: Escalation filters to disconnected app campaigns only
# ---------------------------------------------------------------------------

Describe "DA-28-T: Escalation filters to disconnected app campaigns only" {

    Context "When stale certifications exist for a disconnected app" {
        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppRunner { }

            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            Name                  = 'EscApp'
                            CampaignNamePrefix    = 'EscApp Delta Cert'
                            EscalationStaleHours  = 12
                        }
                    )
                    Error   = $null
                }
            }

            # Return one stale certification
            Mock Get-SPDeltaCertStaleCertifications -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @(
                        @{
                            CertificationId = 'cert-stale-001'
                            CampaignId      = 'camp-esc-001'
                            ReviewerId      = 'rev-001'
                            ReviewerName    = 'Slow Reviewer'
                            HoursStale      = 36
                        }
                    )
                    Error   = $null
                }
            }

            Mock Invoke-SPDeltaCertEscalate -ModuleName SP.DisconnectedAppRunner {
                return @{
                    Success = $true
                    Data    = @{
                        Escalated = @(@{ CertificationId = 'cert-stale-001'; NewReviewerId = 'mgr-001' })
                        Skipped   = @()
                        Errors    = @()
                    }
                    Error   = $null
                }
            }
        }

        It "Should detect stale certs using the app's CampaignNamePrefix and StaleHours" {
            $reportPath = Join-Path $TestDrive 'DA28-Reports'

            $result = Invoke-SPDisconnectedAppEscalation -ReportPath $reportPath

            $result.Success             | Should -Be $true
            $result.Data.AppsChecked    | Should -Be 1
            $result.Data.TotalStaleCerts | Should -Be 1
            $result.Data.TotalEscalated | Should -Be 1

            # Verify Get-SPDeltaCertStaleCertifications was called with correct prefix
            Should -Invoke Get-SPDeltaCertStaleCertifications -ModuleName SP.DisconnectedAppRunner `
                -ParameterFilter { $CampaignNamePrefix -eq 'EscApp Delta Cert' -and $StaleHours -eq 12 } `
                -Times 1
        }

        It "Should write escalation audit event to per-app JSONL" {
            $reportPath = Join-Path $TestDrive 'DA28-Audit'

            Invoke-SPDisconnectedAppEscalation -ReportPath $reportPath

            $auditFile = Join-Path $reportPath 'EscApp\disconnected-app-escalation.jsonl'
            Test-Path -Path $auditFile | Should -Be $true

            $auditContent = Get-Content -Path $auditFile -Raw
            $auditContent | Should -Match 'DisconnectedAppEscalation'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region DA-29-T: Team dashboard HTML generated with delivery status section
# ---------------------------------------------------------------------------

Describe "DA-29-T: Team dashboard HTML generated with delivery status section" {

    Context "When app data exists for dashboard generation" {
        BeforeAll {
            $script:DA29OutputPath  = Join-Path $TestDrive 'DA29-Reports'
            $script:DA29SnapshotDir = Join-Path $TestDrive 'DA29-Snapshots'
            $script:DA29AppDir      = Join-Path $script:DA29OutputPath 'DashApp'
            New-Item -Path $script:DA29AppDir -ItemType Directory -Force | Out-Null

            # Create snapshot directory for SLA calendar
            $appSnapDir = Join-Path $script:DA29SnapshotDir 'DashApp'
            New-Item -Path $appSnapDir -ItemType Directory -Force | Out-Null
            $today = (Get-Date).ToString('yyyy-MM-dd')
            'data' | Set-Content (Join-Path $appSnapDir "${today}-accounts.csv") -Encoding UTF8

            # Create a minimal audit trail
            $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $auditEvent = @{
                Timestamp       = $timestamp
                Action          = 'DisconnectedAppCertRun'
                CampaignsCreated = 1
                CampaignIds     = @('camp-dash-001')
                DeltaSummary    = @{
                    Added               = 2
                    Removed             = 1
                    Enabled             = 0
                    EntitlementsGranted = 1
                    EntitlementsRevoked = 0
                }
            } | ConvertTo-Json -Compress

            $auditPath = Join-Path $script:DA29AppDir 'disconnected-app-audit.jsonl'
            $auditEvent | Set-Content -Path $auditPath -Encoding UTF8

            # Create a test account file for delivery status
            $script:DA29AccountFile = Join-Path $TestDrive 'dashapp-accounts.csv'
            @(
                'id,name,givenName,familyName,e-mail,groups,IIQDisabled'
                'D1,dashuser1,Dash,User1,d1@corp.com,GRP-A,false'
                'D2,dashuser2,Dash,User2,d2@corp.com,GRP-B,false'
            ) | Set-Content -Path $script:DA29AccountFile -Encoding UTF8
            (Get-Item $script:DA29AccountFile).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
        }

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.DisconnectedAppReports { }

            Mock Get-SPRegisteredApps -ModuleName SP.DisconnectedAppReports {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            Name            = 'DashApp'
                            AccountFilePath = $script:DA29AccountFile
                            Enabled         = $true
                        }
                    )
                    Error   = $null
                }
            }
        }

        It "Should generate a self-contained HTML dashboard file" {
            $result = Export-SPDisconnectedAppTeamDashboard `
                -AppName 'DashApp' `
                -OutputPath $script:DA29OutputPath `
                -SnapshotDir $script:DA29SnapshotDir

            $result.Success         | Should -Be $true
            $result.Data.FilePath   | Should -Not -BeNullOrEmpty
            Test-Path -Path $result.Data.FilePath | Should -Be $true
        }

        It "Should contain delivery status and delta summary sections" {
            $result = Export-SPDisconnectedAppTeamDashboard `
                -AppName 'DashApp' `
                -OutputPath $script:DA29OutputPath `
                -SnapshotDir $script:DA29SnapshotDir

            $htmlContent = Get-Content -Path $result.Data.FilePath -Raw

            # Valid HTML structure
            $htmlContent | Should -Match '<!DOCTYPE html>'
            $htmlContent | Should -Match '</html>'

            # Delivery status section
            $htmlContent | Should -Match 'Delivery Status'
            $htmlContent | Should -Match 'Delivered|Missing|Stale'

            # App name present
            $htmlContent | Should -Match 'DashApp'

            # Footer with toolkit branding
            $htmlContent | Should -Match 'SailPoint Governance Toolkit'
        }
    }
}

#endregion
