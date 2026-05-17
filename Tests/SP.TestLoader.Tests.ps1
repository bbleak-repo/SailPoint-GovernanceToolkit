#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.TestLoader module.
.DESCRIPTION
    Tests CSV ingestion, column validation, tag filtering,
    identity cross-reference validation, and duplicate detection.
    Test IDs: LOAD-001 through LOAD-005.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Testing

    # Helper: build a minimal valid identities CSV in TestDrive
    function New-TestIdentitiesCsv {
        param([string]$Path)
        @"
IdentityId,DisplayName,Email,Role,CertifierFor,IsReassignTarget
id-alice-001,Alice Johnson,alice.johnson@lab.local,CertificationOwner,SOURCE_OWNER,false
id-bob-002,Bob Smith,bob.smith@lab.local,Manager,MANAGER,true
id-carol-003,Carol White,carol.white@lab.local,Certifier,SEARCH,false
"@ | Set-Content -Path $Path -Encoding UTF8
    }

    # Helper: build a minimal valid campaigns CSV in TestDrive
    function New-TestCampaignsCsv {
        param([string]$Path)
        @"
TestId,TestName,CampaignType,CampaignName,CertifierIdentityId,ReassignTargetIdentityId,SourceId,SearchFilter,RoleId,DecisionToMake,ReassignBeforeDecide,ValidateRemediation,ExpectCampaignStatus,Priority,Tags
TC-001,Source Owner Approve All,SOURCE_OWNER,UAT-SourceOwner-001,id-alice-001,,src-ad-001,,,APPROVE,false,false,COMPLETED,1,smoke
TC-002,Manager Revoke Subset,MANAGER,UAT-Manager-001,id-bob-002,id-carol-003,,,,REVOKE,true,false,ACTIVE,2,regression
TC-003,Search Campaign Sign-Off,SEARCH,UAT-Search-001,id-alice-001,,,,, APPROVE,false,false,COMPLETED,1,smoke,regression
"@ | Set-Content -Path $Path -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# LOAD-001: Import-SPTestIdentities loads valid CSV
# ---------------------------------------------------------------------------
Describe "LOAD-001: Import-SPTestIdentities loads valid CSV" {
    It "Should return Success=true and a hashtable keyed by IdentityId" {
        $csvPath = Join-Path $TestDrive "identities.csv"
        New-TestIdentitiesCsv -Path $csvPath

        $result = Import-SPTestIdentities -CsvPath $csvPath

        $result.Success | Should -Be $true
        $result.Error   | Should -BeNullOrEmpty
        $result.Data    | Should -BeOfType [hashtable]
        $result.Data.Count | Should -Be 3
        $result.Data.ContainsKey('id-alice-001') | Should -Be $true
        $result.Data['id-alice-001'].DisplayName | Should -Be 'Alice Johnson'
        $result.Data['id-alice-001'].IsReassignTarget | Should -Be $false
        $result.Data['id-bob-002'].IsReassignTarget   | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# LOAD-002: Import-SPTestIdentities fails on missing columns
# ---------------------------------------------------------------------------
Describe "LOAD-002: Import-SPTestIdentities fails on missing required columns" {
    It "Should return Success=false when required columns are absent" {
        $csvPath = Join-Path $TestDrive "bad-identities.csv"
        # Missing IsReassignTarget column
        @"
IdentityId,DisplayName,Email,Role,CertifierFor
id-alice-001,Alice,alice@lab.local,Owner,SOURCE_OWNER
"@ | Set-Content -Path $csvPath -Encoding UTF8

        $result = Import-SPTestIdentities -CsvPath $csvPath

        $result.Success | Should -Be $false
        $result.Error   | Should -Match 'IsReassignTarget'
    }

    It "Should return Success=false when the file does not exist" {
        $result = Import-SPTestIdentities -CsvPath (Join-Path $TestDrive "nonexistent.csv")

        $result.Success | Should -Be $false
        $result.Error   | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# LOAD-003: Import-SPTestCampaigns loads and filters by tags
# ---------------------------------------------------------------------------
Describe "LOAD-003: Import-SPTestCampaigns loads and filters by tags" {
    BeforeAll {
        $script:IdPath = Join-Path $TestDrive "ids.csv"
        New-TestIdentitiesCsv -Path $script:IdPath

        $script:CampPath = Join-Path $TestDrive "campaigns.csv"
        New-TestCampaignsCsv -Path $script:CampPath

        $idResult = Import-SPTestIdentities -CsvPath $script:IdPath
        $script:Identities = $idResult.Data
    }

    It "Should load all campaigns when no tag filter is provided" {
        $result = Import-SPTestCampaigns -CsvPath $script:CampPath -Identities $script:Identities

        $result.Success       | Should -Be $true
        $result.Data.Count    | Should -Be 3
    }

    It "Should filter to smoke-tagged campaigns only" {
        $result = Import-SPTestCampaigns -CsvPath $script:CampPath -Identities $script:Identities -Tags @('smoke')

        $result.Success | Should -Be $true
        # TC-001 has 'smoke', TC-003 has 'smoke,regression'
        $result.Data.Count | Should -BeGreaterOrEqual 2
        $testIds = $result.Data | ForEach-Object { $_.TestId }
        $testIds | Should -Contain 'TC-001'
        $testIds | Should -Not -Contain 'TC-002'  # TC-002 has only 'regression'
    }

    It "Should filter to regression-tagged campaigns only" {
        $result = Import-SPTestCampaigns -CsvPath $script:CampPath -Identities $script:Identities -Tags @('regression')

        $result.Success | Should -Be $true
        $testIds = $result.Data | ForEach-Object { $_.TestId }
        $testIds | Should -Contain 'TC-002'
        $testIds | Should -Not -Contain 'TC-001'  # TC-001 has only 'smoke'
    }

    It "Should sort campaigns by Priority ascending" {
        $result = Import-SPTestCampaigns -CsvPath $script:CampPath -Identities $script:Identities

        $result.Success | Should -Be $true
        $priorities = $result.Data | ForEach-Object { $_.Priority }
        for ($i = 1; $i -lt $priorities.Count; $i++) {
            $priorities[$i] | Should -BeGreaterOrEqual $priorities[$i - 1]
        }
    }

    It "Should return an empty array (not failure) when no tags match" {
        $result = Import-SPTestCampaigns -CsvPath $script:CampPath -Identities $script:Identities -Tags @('nonexistent-tag')

        $result.Success    | Should -Be $true
        $result.Data.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# LOAD-004: Import-SPTestCampaigns validates identity references
# ---------------------------------------------------------------------------
Describe "LOAD-004: Import-SPTestCampaigns validates identity references" {
    BeforeAll {
        $script:IdPath2 = Join-Path $TestDrive "ids2.csv"
        New-TestIdentitiesCsv -Path $script:IdPath2

        $idResult2 = Import-SPTestIdentities -CsvPath $script:IdPath2
        $script:Identities2 = $idResult2.Data
    }

    It "Should still load campaigns when CertifierIdentityId is invalid (warning, not error)" {
        # The loader logs warnings but still returns campaigns;
        # Test-SPTestData is the gate for hard errors.
        $campPath = Join-Path $TestDrive "bad-campaigns.csv"
        @"
TestId,TestName,CampaignType,CampaignName,CertifierIdentityId,ReassignTargetIdentityId,SourceId,SearchFilter,RoleId,DecisionToMake,ReassignBeforeDecide,ValidateRemediation,ExpectCampaignStatus,Priority,Tags
TC-BAD,Bad Certifier,SOURCE_OWNER,UAT-Bad-001,id-nonexistent,,src-001,,,APPROVE,false,false,COMPLETED,1,smoke
"@ | Set-Content -Path $campPath -Encoding UTF8

        $result = Import-SPTestCampaigns -CsvPath $campPath -Identities $script:Identities2

        # Should still return Success=true (loading succeeded, validation warnings tracked)
        $result.Success    | Should -Be $true
        $result.Data.Count | Should -Be 1
    }

    It "Should flag error when ReassignBeforeDecide=true but ReassignTargetIdentityId is missing" {
        $campPath = Join-Path $TestDrive "reassign-bad.csv"
        @"
TestId,TestName,CampaignType,CampaignName,CertifierIdentityId,ReassignTargetIdentityId,SourceId,SearchFilter,RoleId,DecisionToMake,ReassignBeforeDecide,ValidateRemediation,ExpectCampaignStatus,Priority,Tags
TC-R01,Reassign No Target,MANAGER,UAT-R01,id-alice-001,,,,, REVOKE,true,false,ACTIVE,1,regression
"@ | Set-Content -Path $campPath -Encoding UTF8

        # Test-SPTestData is where the hard validation is assessed;
        # Import should still load the record, Test-SPTestData flags it.
        $result = Import-SPTestCampaigns -CsvPath $campPath -Identities $script:Identities2

        $result.Success    | Should -Be $true
        $result.Data.Count | Should -Be 1

        # Now run Test-SPTestData - it should report an error
        $validResult = Test-SPTestData -Campaigns $result.Data -Identities $script:Identities2
        $validResult.Success         | Should -Be $false
        $validResult.ValidationErrors.Count | Should -BeGreaterThan 0
    }
}

# ---------------------------------------------------------------------------
# LOAD-005: Test-SPTestData catches duplicate TestIds
# ---------------------------------------------------------------------------
Describe "LOAD-005: Test-SPTestData catches duplicate TestIds" {
    BeforeAll {
        $script:IdPath3 = Join-Path $TestDrive "ids3.csv"
        New-TestIdentitiesCsv -Path $script:IdPath3
        $idResult3 = Import-SPTestIdentities -CsvPath $script:IdPath3
        $script:Identities3 = $idResult3.Data
    }

    It "Should return Success=false when duplicate TestIds exist" {
        # Manually create campaigns array with duplicate TestId
        $campaigns = @(
            [PSCustomObject]@{
                TestId                   = 'TC-DUP'
                TestName                 = 'Duplicate A'
                CampaignType             = 'SOURCE_OWNER'
                CampaignName             = 'UAT-Dup-A'
                CertifierIdentityId      = 'id-alice-001'
                ReassignTargetIdentityId = ''
                SourceId                 = 'src-001'
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = 1
                Tags                     = 'smoke'
            },
            [PSCustomObject]@{
                TestId                   = 'TC-DUP'
                TestName                 = 'Duplicate B'
                CampaignType             = 'SOURCE_OWNER'
                CampaignName             = 'UAT-Dup-B'
                CertifierIdentityId      = 'id-alice-001'
                ReassignTargetIdentityId = ''
                SourceId                 = 'src-002'
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = 2
                Tags                     = 'smoke'
            }
        )

        $result = Test-SPTestData -Campaigns $campaigns -Identities $script:Identities3

        $result.Success         | Should -Be $false
        $result.ValidationErrors | Should -Not -BeNullOrEmpty
        $result.ValidationErrors | Where-Object { $_ -match 'Duplicate' } | Should -Not -BeNullOrEmpty
    }

    It "Should return Success=true for valid, non-duplicate campaigns" {
        $campaigns = @(
            [PSCustomObject]@{
                TestId                   = 'TC-V01'
                TestName                 = 'Valid A'
                CampaignType             = 'SOURCE_OWNER'
                CampaignName             = 'UAT-V01'
                CertifierIdentityId      = 'id-alice-001'
                ReassignTargetIdentityId = ''
                SourceId                 = 'src-001'
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = 1
                Tags                     = 'smoke'
            },
            [PSCustomObject]@{
                TestId                   = 'TC-V02'
                TestName                 = 'Valid B'
                CampaignType             = 'MANAGER'
                CampaignName             = 'UAT-V02'
                CertifierIdentityId      = 'id-bob-002'
                ReassignTargetIdentityId = ''
                SourceId                 = ''
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = 2
                Tags                     = 'regression'
            }
        )

        $result = Test-SPTestData -Campaigns $campaigns -Identities $script:Identities3

        $result.Success              | Should -Be $true
        $result.ValidationErrors.Count | Should -Be 0
    }

    It "Should warn when no smoke-tagged tests are present" {
        $campaigns = @(
            [PSCustomObject]@{
                TestId                   = 'TC-W01'
                TestName                 = 'No Smoke Tag'
                CampaignType             = 'MANAGER'
                CampaignName             = 'UAT-W01'
                CertifierIdentityId      = 'id-bob-002'
                ReassignTargetIdentityId = ''
                SourceId                 = ''
                SearchFilter             = ''
                RoleId                   = ''
                DecisionToMake           = 'APPROVE'
                ReassignBeforeDecide     = $false
                ValidateRemediation      = $false
                ExpectCampaignStatus     = 'COMPLETED'
                Priority                 = 1
                Tags                     = 'full'
            }
        )

        $result = Test-SPTestData -Campaigns $campaigns -Identities $script:Identities3

        $result.Warnings | Should -Not -BeNullOrEmpty
        $result.Warnings | Where-Object { $_ -match 'smoke' } | Should -Not -BeNullOrEmpty
    }
}
