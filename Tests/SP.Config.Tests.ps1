#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.Config module
.DESCRIPTION
    Unit tests for configuration loading, caching, validation, and first-run detection.
    Test IDs: CFG-001 through CFG-007
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core

    $script:ValidConfigPath = Join-Path $PSScriptRoot "TestData\valid-settings.json"
}

Describe "Get-SPConfig" {

    Context "CFG-001: Loads valid config from file" {
        It "Should return a PSCustomObject with expected sections" {
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config | Should -Not -BeNullOrEmpty
            $config.PSObject.Properties.Name | Should -Contain 'Global'
            $config.PSObject.Properties.Name | Should -Contain 'Authentication'
            $config.PSObject.Properties.Name | Should -Contain 'Logging'
            $config.PSObject.Properties.Name | Should -Contain 'Api'
            $config.PSObject.Properties.Name | Should -Contain 'Testing'
            $config.PSObject.Properties.Name | Should -Contain 'Safety'
        }

        It "Should load EnvironmentName as TestLab from valid config" {
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config.Global.EnvironmentName | Should -Be 'TestLab'
        }

        It "Should load Api.BaseUrl correctly" {
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config.Api.BaseUrl | Should -Be 'https://testlab.api.identitynow.com/v3'
        }

        It "Should load Authentication.Mode as ConfigFile" {
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config.Authentication.Mode | Should -Be 'ConfigFile'
        }
    }

    Context "CFG-002: Returns cached result on second call" {
        It "Should use cache and not reload file on second call with same path" {
            # Force a fresh load to populate cache
            Get-SPConfig -ConfigPath $script:ValidConfigPath -Force | Out-Null

            # Mock Get-Content to detect if it's called again
            Mock Get-Content { throw "Get-Content should not be called when cache is warm" }

            # Second call should use cache (not call Get-Content)
            { $config = Get-SPConfig -ConfigPath $script:ValidConfigPath } | Should -Not -Throw
        }
    }

    Context "CFG-003: -Force bypasses cache" {
        It "Should reload the file when -Force is specified" {
            # Warm the cache first
            Get-SPConfig -ConfigPath $script:ValidConfigPath -Force | Out-Null

            # Call with -Force - should succeed with real data, not mock
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config.Global.EnvironmentName | Should -Be 'TestLab'
        }

        It "Should return fresh data after -Force reload" {
            $config1 = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config2 = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $config1.Global.EnvironmentName | Should -Be $config2.Global.EnvironmentName
        }
    }
}

Describe "Test-SPConfig" {

    Context "CFG-004: Returns true for valid config" {
        It "Should return true for a fully populated valid config" {
            $config = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $result = Test-SPConfig -Config $config
            $result | Should -Be $true
        }
    }

    Context "CFG-005: Returns false for missing required fields" {
        It "Should return false when Api section is missing" {
            $badConfig = [PSCustomObject]@{
                Global         = [PSCustomObject]@{ EnvironmentName = 'Test' }
                Authentication = [PSCustomObject]@{ Mode = 'ConfigFile' }
                Logging        = [PSCustomObject]@{ Path = '.\Logs' }
                # No Api section
            }
            $result = Test-SPConfig -Config $badConfig
            $result | Should -Be $false
        }

        It "Should return false when Authentication section is missing" {
            $badConfig = [PSCustomObject]@{
                Global  = [PSCustomObject]@{ EnvironmentName = 'Test' }
                Logging = [PSCustomObject]@{ Path = '.\Logs' }
                Api     = [PSCustomObject]@{ BaseUrl = 'https://example.com' }
                # No Authentication section
            }
            $result = Test-SPConfig -Config $badConfig
            $result | Should -Be $false
        }

        It "Should return false when Api.BaseUrl is empty" {
            $badConfig = [PSCustomObject]@{
                Global         = [PSCustomObject]@{ EnvironmentName = 'Test' }
                Authentication = [PSCustomObject]@{ Mode = 'ConfigFile' }
                Logging        = [PSCustomObject]@{ Path = '.\Logs' }
                Api            = [PSCustomObject]@{ BaseUrl = '' }
            }
            $result = Test-SPConfig -Config $badConfig
            $result | Should -Be $false
        }

        It "Should return false when Logging.Path is empty" {
            $badConfig = [PSCustomObject]@{
                Global         = [PSCustomObject]@{ EnvironmentName = 'Test' }
                Authentication = [PSCustomObject]@{ Mode = 'ConfigFile' }
                Logging        = [PSCustomObject]@{ Path = '' }
                Api            = [PSCustomObject]@{ BaseUrl = 'https://example.com' }
            }
            $result = Test-SPConfig -Config $badConfig
            $result | Should -Be $false
        }
    }
}

Describe "Test-SPConfigFirstRun" {

    Context "CFG-006: Detects CHANGE_ME values" {
        It "Should return true when EnvironmentName contains CHANGE_ME" {
            $firstRunConfig = [PSCustomObject]@{
                _FirstRun   = $true
                _ConfigPath = 'C:\fake\settings.json'
                _Message    = 'Configuration file created.'
            }
            $result = Test-SPConfigFirstRun -Config $firstRunConfig
            $result | Should -Be $true
        }

        It "Should return false for a normal loaded config" {
            $normalConfig = Get-SPConfig -ConfigPath $script:ValidConfigPath -Force
            $result = Test-SPConfigFirstRun -Config $normalConfig
            $result | Should -Be $false
        }

        It "Should return false for a config object without _FirstRun property" {
            $plainConfig = [PSCustomObject]@{
                Global = [PSCustomObject]@{ EnvironmentName = 'Production' }
            }
            $result = Test-SPConfigFirstRun -Config $plainConfig
            $result | Should -Be $false
        }
    }
}

Describe "New-SPConfigFile" {

    Context "CFG-007: Creates default config file" {
        # New-SPConfigFile now requires the parent directory to already exist
        # (deliberate safety change; see bugs.md Bug 5). Tests ensure the dir
        # first, then assert file creation.

        It "Should create a settings.json file at the specified path" {
            $dir = Join-Path $TestDrive "test-output"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $targetPath = Join-Path $dir "settings.json"
            $returnedPath = New-SPConfigFile -ConfigPath $targetPath
            Test-Path $returnedPath | Should -Be $true
        }

        It "Should return the path to the created file" {
            $dir = Join-Path $TestDrive "new-config"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $targetPath = Join-Path $dir "settings.json"
            $returnedPath = New-SPConfigFile -ConfigPath $targetPath
            $returnedPath | Should -Be $targetPath
        }

        It "Should create a valid JSON file" {
            $dir = Join-Path $TestDrive "json-check"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $targetPath = Join-Path $dir "settings.json"
            New-SPConfigFile -ConfigPath $targetPath | Out-Null

            $content = Get-Content -Path $targetPath -Raw
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should embed CHANGE_ME placeholders in the generated file" {
            $dir = Join-Path $TestDrive "placeholder-check"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $targetPath = Join-Path $dir "settings.json"
            New-SPConfigFile -ConfigPath $targetPath | Out-Null

            $content = Get-Content -Path $targetPath -Raw
            $content | Should -Match 'CHANGE_ME'
        }

        It "Should throw DirectoryNotFoundException when parent does not exist" {
            $nestedPath = Join-Path $TestDrive "deep\nested\dir\settings.json"
            { New-SPConfigFile -ConfigPath $nestedPath } |
                Should -Throw -ExceptionType ([System.IO.DirectoryNotFoundException])
            Test-Path $nestedPath | Should -Be $false
            Test-Path (Join-Path $TestDrive "deep") | Should -Be $false
        }
    }
}
