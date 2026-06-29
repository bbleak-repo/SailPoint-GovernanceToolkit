#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    MacBook-validation fixes for SP.Shared:
      MF-CACHE  Export-SPCacheStore -Compress:$false now writes valid one-record-per-line
                JSONL that Import-SPCacheStore can read back (was multi-line -> silent loss).
      MF-IDENT  Get-SPIdentityDetail no longer sticky-caches a TRANSIENT API failure in the
                no-TTL store (a single blip used to un-resolve the identity for the session);
                a GENUINE not-found is cached with a short TTL.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Shared
}

Describe "MF-CACHE -- Export-SPCacheStore -Compress:`$false JSONL round-trip" {

    It "writes one-record-per-line JSONL that Import reads back (Compress off)" {
        New-SPCacheStore -Name 'MFCacheTest' -TtlMinutes 0 | Out-Null
        Clear-SPCacheStore -Store 'MFCacheTest'
        Set-SPCachedItem -Store 'MFCacheTest' -Key 'k1' -Value @{ a = 1; b = 'x' } -NoPersist
        Set-SPCachedItem -Store 'MFCacheTest' -Key 'k2' -Value @{ a = 2; b = 'y' } -NoPersist

        $f = Join-Path $TestDrive 'mf-compress-off.jsonl'
        Export-SPCacheStore -Store 'MFCacheTest' -Path $f -Compress:$false

        # JSONL invariant: exactly one non-blank line per record.
        $lines = @(Get-Content $f | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 2 -Because 'each record must be a single physical line'

        Clear-SPCacheStore -Store 'MFCacheTest'
        $res = Import-SPCacheStore -Store 'MFCacheTest' -Path $f
        $res.Loaded | Should -Be 2
        $res.Errors | Should -Be 0
        (Get-SPCachedItem -Store 'MFCacheTest' -Key 'k1').a | Should -Be 1
        (Get-SPCachedItem -Store 'MFCacheTest' -Key 'k2').b | Should -Be 'y'
    }
}

Describe "MF-IDENT -- transient identity failures are not sticky-cached" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
        Mock Write-SPLog -ModuleName SP.IdentityService {}
    }

    It "retries after a TRANSIENT failure (Success=`$false) -- negative not cached" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService { return @{ Success = $false; Data = $null } }
        (Get-SPIdentityDetail -IdentityId 'id-trans-001').Found | Should -Be $false
        (Get-SPIdentityDetail -IdentityId 'id-trans-001').Found | Should -Be $false
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 2 -Exactly `
            -Because 'a transient failure must not be cached; the second call retries'
    }

    It "retries after an EXCEPTION -- negative not cached" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService { throw 'API connection failed' }
        (Get-SPIdentityDetail -IdentityId 'id-exc-001').Found | Should -Be $false
        (Get-SPIdentityDetail -IdentityId 'id-exc-001').Found | Should -Be $false
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 2 -Exactly `
            -Because 'an exception is transient; it must not stick a negative for the session'
    }

    It "caches a GENUINE not-found (Success=`$true, empty data) -- not re-queried in the window" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService { return @{ Success = $true; Data = $null } }
        $null = Get-SPIdentityDetail -IdentityId 'id-nf-001'
        $null = Get-SPIdentityDetail -IdentityId 'id-nf-001'
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 1 -Exactly `
            -Because 'a genuine not-found is short-TTL cached and not re-queried within the window'
    }
}
