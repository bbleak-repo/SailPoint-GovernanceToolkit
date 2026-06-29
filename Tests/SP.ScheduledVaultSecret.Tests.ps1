#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    MacBook-validation HIGH fix: the ScheduledVault machine-derived key is no longer derivable
    from public machine/user/domain values -- it mixes in a per-install random secret, stored under
    a chosen protection mode (self-describing file: 'SVK1' + mode byte):
      Dpapi   (default/recommended) -- secret is DPAPI-protected (CurrentUser); not off-box decryptable.
      AclFile (EDR-quiet)           -- raw secret in an NTFS-ACL-locked file; no DPAPI.

    SV-01 Dpapi mode: DPAPI-protected, self-describing, round-trips, payload != raw secret.
    SV-04 AclFile mode: raw secret (no DPAPI overhead) after a self-describing header, round-trips.
    SV-05 read-back is self-describing -- mode comes from the FILE, not the -KeyProtection arg.
    SV-02 passphrase is 64-hex, stable per secret, and CHANGES with the secret.
    SV-03 the hardened key differs from the OLD public-only derivation.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core
}

Describe "SV -- ScheduledVault per-install secret strengthens the machine-derived key" {

    It "SV-01 Dpapi mode: DPAPI-protected, self-describing file that round-trips" {
        $p  = Join-Path $TestDrive 'sv1.secret'
        $s1 = Get-SPScheduledVaultSecret -SecretPath $p -KeyProtection Dpapi
        Test-Path -LiteralPath $p | Should -BeTrue
        ([Convert]::FromBase64String($s1)).Length | Should -Be 32           # 256-bit secret
        (Get-SPScheduledVaultSecret -SecretPath $p) | Should -Be $s1        # read-back (mode from file)

        $raw = [System.IO.File]::ReadAllBytes($p)
        [System.Text.Encoding]::ASCII.GetString($raw, 0, 4) | Should -Be 'SVK1'
        [char]$raw[4] | Should -Be 'D'
        # The payload after the header is the DPAPI blob -- NOT the raw secret, and larger than 32B.
        $payload = New-Object byte[] ($raw.Length - 5); [Array]::Copy($raw, 5, $payload, 0, $payload.Length)
        [Convert]::ToBase64String($payload) | Should -Not -Be $s1
        $payload.Length | Should -BeGreaterThan 32
    }

    It "SV-04 AclFile mode: raw secret (no DPAPI) in a self-describing, ACL-locked file" {
        $p  = Join-Path $TestDrive 'sv4.secret'
        $s4 = Get-SPScheduledVaultSecret -SecretPath $p -KeyProtection AclFile
        ([Convert]::FromBase64String($s4)).Length | Should -Be 32
        (Get-SPScheduledVaultSecret -SecretPath $p) | Should -Be $s4        # read-back (mode from file)

        $raw = [System.IO.File]::ReadAllBytes($p)
        [System.Text.Encoding]::ASCII.GetString($raw, 0, 4) | Should -Be 'SVK1'
        [char]$raw[4] | Should -Be 'A'
        $raw.Length | Should -Be 37                                          # 5-byte header + 32 raw bytes (no DPAPI overhead)
        $payload = New-Object byte[] 32; [Array]::Copy($raw, 5, $payload, 0, 32)
        [Convert]::ToBase64String($payload) | Should -Be $s4                 # the raw secret IS the payload
    }

    It "SV-05 read-back is self-describing -- mode comes from the file, not the arg" {
        $p  = Join-Path $TestDrive 'sv5.secret'
        $s5 = Get-SPScheduledVaultSecret -SecretPath $p -KeyProtection AclFile   # created AclFile
        # Reading with a DIFFERENT -KeyProtection still returns the same secret (the file knows its mode).
        (Get-SPScheduledVaultSecret -SecretPath $p -KeyProtection Dpapi) | Should -Be $s5
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

        $combined = '{0}|{1}|{2}|SailPoint-GovernanceToolkit-ScheduledVault-v1' -f `
            [Environment]::MachineName, [Environment]::UserName, [Environment]::UserDomainName
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined)) } finally { $sha.Dispose() }
        $legacy = ($h | ForEach-Object { $_.ToString('x2') }) -join ''

        $hardened | Should -Not -Be $legacy -Because 'the secret must participate -- the key is no longer publicly derivable'
    }
}
