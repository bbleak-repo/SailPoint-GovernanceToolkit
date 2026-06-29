#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    MacBook-validation HIGH fix: the ScheduledVault machine-derived key is no longer derivable
    from public machine/user/domain values -- it now mixes in a per-install random secret that
    is DPAPI-protected (CurrentUser), so an exfiltrated key file cannot be decrypted off-box.

    SV-01 Get-SPScheduledVaultSecret: creates a DPAPI-protected file, round-trips, file != raw secret.
    SV-02 Get-SPMachineDerivedPassphrase: 64-hex, stable per secret, CHANGES with the secret.
    SV-03 the hardened key differs from the OLD public-only derivation (the secret genuinely participates).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core
}

Describe "SV -- ScheduledVault per-install secret strengthens the machine-derived key" {

    It "SV-01 Get-SPScheduledVaultSecret creates a DPAPI-protected file and round-trips" {
        $p  = Join-Path $TestDrive 'sv1.secret'
        $s1 = Get-SPScheduledVaultSecret -SecretPath $p
        Test-Path -LiteralPath $p | Should -BeTrue
        ([Convert]::FromBase64String($s1)).Length | Should -Be 32          # 256-bit secret
        (Get-SPScheduledVaultSecret -SecretPath $p) | Should -Be $s1        # reads back identical
        # The on-disk bytes are DPAPI-protected -- NOT the raw secret.
        $fileBytes = [System.IO.File]::ReadAllBytes($p)
        [Convert]::ToBase64String($fileBytes) | Should -Not -Be $s1
        $fileBytes.Length | Should -BeGreaterThan 32
    }

    It "SV-02 passphrase is 64-hex, stable for a given secret, and CHANGES with the secret" {
        $pa  = Join-Path $TestDrive 'sva.secret'
        $pb  = Join-Path $TestDrive 'svb.secret'
        $ppa = Get-SPMachineDerivedPassphrase -SecretPath $pa
        $ppb = Get-SPMachineDerivedPassphrase -SecretPath $pb
        $ppa | Should -Match '^[0-9a-f]{64}$'
        $ppa | Should -Not -Be $ppb -Because 'a different per-install secret must yield a different key'
        (Get-SPMachineDerivedPassphrase -SecretPath $pa) | Should -Be $ppa -Because 'same secret -> stable key'
    }

    It "SV-03 the hardened key differs from the OLD public-only derivation" {
        $p        = Join-Path $TestDrive 'svc.secret'
        $hardened = Get-SPMachineDerivedPassphrase -SecretPath $p

        # Reconstruct the legacy derivation (public machine|user|domain|static-salt, no secret).
        $combined = '{0}|{1}|{2}|SailPoint-GovernanceToolkit-ScheduledVault-v1' -f `
            [Environment]::MachineName, [Environment]::UserName, [Environment]::UserDomainName
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined)) } finally { $sha.Dispose() }
        $legacy = ($h | ForEach-Object { $_.ToString('x2') }) -join ''

        $hardened | Should -Not -Be $legacy -Because 'the secret must participate -- the key is no longer publicly derivable'
    }
}
