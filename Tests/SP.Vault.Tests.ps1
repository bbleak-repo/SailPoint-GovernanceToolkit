#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for SP.Vault module
.DESCRIPTION
    Unit tests for encrypted credential vault - initialization, round-trip storage,
    wrong-passphrase handling, existence check, removal, and multi-credential storage.
    Test IDs: VLT-001 through VLT-006
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot "..\Modules\SP.Core\SP.Core.psd1"
    Import-Module $modulePath -Force

    # Helper to create a SecureString from plain text
    function New-TestPassphrase {
        param([string]$Value = 'TestPassphrase123!')
        return ConvertTo-SecureString $Value -AsPlainText -Force
    }
}

Describe "Initialize-SPVault" {

    Context "VLT-001: Creates vault file" {
        It "Should create an encrypted vault file at the specified path" {
            $vaultPath = Join-Path $TestDrive "vlt001\sp-vault.enc"
            $passphrase = New-TestPassphrase

            $result = Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase
            $result.Success | Should -Be $true
            $result.Error   | Should -BeNullOrEmpty
            Test-Path $vaultPath | Should -Be $true
        }

        It "Should create a non-zero byte file" {
            $vaultPath = Join-Path $TestDrive "vlt001b\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null
            (Get-Item $vaultPath).Length | Should -BeGreaterThan 0
        }

        It "Should create parent directories automatically" {
            $vaultPath = Join-Path $TestDrive "deep\nested\vault\sp-vault.enc"
            $passphrase = New-TestPassphrase

            $result = Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase
            $result.Success | Should -Be $true
            Test-Path $vaultPath | Should -Be $true
        }

        It "Should return failure if vault already exists" {
            $vaultPath = Join-Path $TestDrive "vlt001c\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            # Second init attempt should fail gracefully
            $result = Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Set-SPVaultCredential and Get-SPVaultCredential" {

    Context "VLT-002: Set/Get credential round-trip succeeds" {
        It "Should store and retrieve ClientId and ClientSecret correctly" {
            $vaultPath  = Join-Path $TestDrive "vlt002\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            $setResult = Set-SPVaultCredential `
                -VaultPath    $vaultPath `
                -Passphrase   $passphrase `
                -Key          'sailpoint-isc' `
                -ClientId     'my-client-id' `
                -ClientSecret 'my-client-secret-XYZ'

            $setResult.Success | Should -Be $true

            $getResult = Get-SPVaultCredential `
                -VaultPath  $vaultPath `
                -Passphrase $passphrase `
                -Key        'sailpoint-isc'

            $getResult.Success          | Should -Be $true
            $getResult.Data.ClientId    | Should -Be 'my-client-id'
            $getResult.Data.ClientSecret | Should -Be 'my-client-secret-XYZ'
        }

        It "Should overwrite an existing key on Set" {
            $vaultPath  = Join-Path $TestDrive "vlt002b\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'my-key' -ClientId 'id-v1' -ClientSecret 'secret-v1' | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'my-key' -ClientId 'id-v2' -ClientSecret 'secret-v2' | Out-Null

            $getResult = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'my-key'
            $getResult.Success          | Should -Be $true
            $getResult.Data.ClientId    | Should -Be 'id-v2'
            $getResult.Data.ClientSecret | Should -Be 'secret-v2'
        }
    }

    Context "VLT-003: Get with wrong passphrase fails gracefully" {
        It "Should return Success=false and non-empty Error with wrong passphrase" {
            $vaultPath     = Join-Path $TestDrive "vlt003\sp-vault.enc"
            $correctPass   = New-TestPassphrase 'CorrectPassphrase!'
            $wrongPass     = New-TestPassphrase 'WrongPassphrase!'

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $correctPass | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $correctPass `
                -Key 'test-key' -ClientId 'test-id' -ClientSecret 'test-secret' | Out-Null

            $result = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $wrongPass -Key 'test-key'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }

        It "Should not throw when wrong passphrase is provided" {
            $vaultPath   = Join-Path $TestDrive "vlt003b\sp-vault.enc"
            $correctPass = New-TestPassphrase 'CorrectPassphrase!'
            $wrongPass   = New-TestPassphrase 'WrongPassphrase!'

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $correctPass | Out-Null

            { Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $wrongPass -Key 'any-key' } |
                Should -Not -Throw
        }
    }
}

Describe "Test-SPVaultExists" {

    Context "VLT-004: Returns correct boolean" {
        It "Should return false when vault file does not exist" {
            $nonExistentPath = Join-Path $TestDrive "vlt004\does-not-exist.enc"
            Test-SPVaultExists -VaultPath $nonExistentPath | Should -Be $false
        }

        It "Should return true after Initialize-SPVault creates the file" {
            $vaultPath  = Join-Path $TestDrive "vlt004\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Test-SPVaultExists -VaultPath $vaultPath | Should -Be $false

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            Test-SPVaultExists -VaultPath $vaultPath | Should -Be $true
        }
    }
}

Describe "Remove-SPVaultCredential" {

    Context "VLT-005: Remove credential then Get fails" {
        It "Should return Success=false on Get after Remove" {
            $vaultPath  = Join-Path $TestDrive "vlt005\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'to-remove' -ClientId 'cid' -ClientSecret 'csec' | Out-Null

            # Verify it exists first
            $before = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'to-remove'
            $before.Success | Should -Be $true

            # Remove it
            $removeResult = Remove-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'to-remove'
            $removeResult.Success | Should -Be $true

            # Get should now fail
            $after = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'to-remove'
            $after.Success | Should -Be $false
            $after.Error   | Should -Not -BeNullOrEmpty
        }

        It "Should return failure when trying to remove a non-existent key" {
            $vaultPath  = Join-Path $TestDrive "vlt005b\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            $result = Remove-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'nonexistent'
            $result.Success | Should -Be $false
            $result.Error   | Should -Not -BeNullOrEmpty
        }

        It "Should not throw when removing a non-existent key" {
            $vaultPath  = Join-Path $TestDrive "vlt005c\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            { Remove-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'ghost-key' } |
                Should -Not -Throw
        }
    }
}

Describe "Multiple credentials in same vault" {

    Context "VLT-006: Multiple credentials coexist" {
        It "Should store and retrieve multiple credentials independently" {
            $vaultPath  = Join-Path $TestDrive "vlt006\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            # Store three separate credentials
            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'sailpoint-isc' -ClientId 'sp-client' -ClientSecret 'sp-secret' | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'sailpoint-sandbox' -ClientId 'sandbox-client' -ClientSecret 'sandbox-secret' | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'other-system' -ClientId 'other-client' -ClientSecret 'other-secret' | Out-Null

            # Retrieve and verify each independently
            $r1 = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'sailpoint-isc'
            $r1.Success          | Should -Be $true
            $r1.Data.ClientId    | Should -Be 'sp-client'
            $r1.Data.ClientSecret | Should -Be 'sp-secret'

            $r2 = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'sailpoint-sandbox'
            $r2.Success          | Should -Be $true
            $r2.Data.ClientId    | Should -Be 'sandbox-client'
            $r2.Data.ClientSecret | Should -Be 'sandbox-secret'

            $r3 = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'other-system'
            $r3.Success          | Should -Be $true
            $r3.Data.ClientId    | Should -Be 'other-client'
            $r3.Data.ClientSecret | Should -Be 'other-secret'
        }

        It "Should leave remaining credentials intact after removing one" {
            $vaultPath  = Join-Path $TestDrive "vlt006b\sp-vault.enc"
            $passphrase = New-TestPassphrase

            Initialize-SPVault -VaultPath $vaultPath -Passphrase $passphrase | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'keep-me' -ClientId 'keep-id' -ClientSecret 'keep-secret' | Out-Null

            Set-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase `
                -Key 'remove-me' -ClientId 'remove-id' -ClientSecret 'remove-secret' | Out-Null

            # Remove one
            Remove-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'remove-me' | Out-Null

            # The other should still be retrievable
            $keepResult = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'keep-me'
            $keepResult.Success          | Should -Be $true
            $keepResult.Data.ClientId    | Should -Be 'keep-id'
            $keepResult.Data.ClientSecret | Should -Be 'keep-secret'

            # The removed one should be gone
            $removedResult = Get-SPVaultCredential -VaultPath $vaultPath -Passphrase $passphrase -Key 'remove-me'
            $removedResult.Success | Should -Be $false
        }
    }
}
