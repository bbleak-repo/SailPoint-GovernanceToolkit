<#
.SYNOPSIS
    Unit tests for SP.IscReconciliationSource -- ISC fetch converters + the NON-EXPIRING cache.
    RECS-01  ConvertTo-SPIscIdentityRecord (identity doc -> record; employeeID join key)
    RECS-02  Expand-SPIscEntitlementMembers (entitlement members[] -> per-member grants)
    RECS-03  Save/Get cache round-trip, UTF-8 no-BOM, and that the cache NEVER expires
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Reconciliation

    # Mirrors the real mock /v3/search/identities document shape.
    $script:docActive = [PSCustomObject]@{
        id = 'id-gen-002'; name = 'mary.johnson'; displayName = 'Mary Johnson'
        attributes = [PSCustomObject]@{ cloudLifecycleState = 'active'; email = 'mary.johnson@corp.test'; employeeNumber = 'E0002'; title = 'Sysadmin' }
        manager = [PSCustomObject]@{ type = 'IDENTITY'; id = 'id-gen-001'; name = 'James Smith' }
    }
    $script:docInactiveNoKey = [PSCustomObject]@{
        id = 'id-gen-050'; name = 'no.key'; displayName = 'No Key'
        attributes = [PSCustomObject]@{ cloudLifecycleState = 'inactive'; email = 'no.key@corp.test' }  # no employeeNumber
        manager = $null
    }
    # Mirrors the real mock /v3/entitlements shape.
    $script:ent = [PSCustomObject]@{
        id = 'ent-001'; name = 'AD-SG-Finance-1'; type = 'ENTITLEMENT'
        sourceId = 'src-ad-001'; sourceName = 'Corporate AD'; privileged = $true
        members = @('id-gen-059', 'id-gen-028', 'id-gen-014')
        source = [PSCustomObject]@{ id = 'src-ad-001'; name = 'Corporate AD' }
    }
}

Describe "RECS-01: ConvertTo-SPIscIdentityRecord" {
    It "maps id, employeeNumber join key, manager id, email, active" {
        $r = ConvertTo-SPIscIdentityRecord -IdentityDoc $script:docActive
        $r.IscIdentityId        | Should -Be 'id-gen-002'
        $r.EmployeeId           | Should -Be 'E0002'
        $r.DisplayName          | Should -Be 'Mary Johnson'
        $r.Email                | Should -Be 'mary.johnson@corp.test'
        $r.ManagerIscIdentityId | Should -Be 'id-gen-001'
        $r.LifecycleState       | Should -Be 'active'
        $r.Active               | Should -Be $true
    }
    It "treats inactive lifecycle as not active and missing join key as empty" {
        $r = ConvertTo-SPIscIdentityRecord -IdentityDoc $script:docInactiveNoKey
        $r.Active               | Should -Be $false
        $r.EmployeeId           | Should -Be ''
        $r.ManagerIscIdentityId | Should -Be ''
    }
    It "honors a custom JoinKeyAttribute" {
        $doc = [PSCustomObject]@{ id = 'x'; displayName = 'X'; attributes = [PSCustomObject]@{ cloudLifecycleState = 'active'; extensionAttribute7 = 'CUST-9' } }
        (ConvertTo-SPIscIdentityRecord -IdentityDoc $doc -JoinKeyAttribute 'extensionAttribute7').EmployeeId | Should -Be 'CUST-9'
    }
}

Describe "RECS-02: Expand-SPIscEntitlementMembers" {
    It "emits one grant per member, carrying source, type and privileged" {
        $grants = @(Expand-SPIscEntitlementMembers -Entitlement $script:ent)
        $grants.Count | Should -Be 3
        $grants[0].IscIdentityId | Should -Be 'id-gen-059'
        $grants[0].Name          | Should -Be 'AD-SG-Finance-1'
        $grants[0].Source        | Should -Be 'Corporate AD'
        $grants[0].Type          | Should -Be 'ENTITLEMENT'
        $grants[0].Privileged    | Should -Be $true
    }
    It "returns nothing for an entitlement with no members" {
        $bare = [PSCustomObject]@{ id = 'ent-x'; name = 'Empty'; sourceName = 'AD'; privileged = $false; members = @() }
        @(Expand-SPIscEntitlementMembers -Entitlement $bare).Count | Should -Be 0
    }
}

Describe "RECS-03: non-expiring cache round-trip" {
    It "saves and reloads identities + grants" {
        $dir = Join-Path $TestDrive 'cache'
        $data = @{
            FetchedAtUtc = '2026-06-10T08:00:00.0000000Z'
            Identities   = @((ConvertTo-SPIscIdentityRecord -IdentityDoc $script:docActive))
            AccessGrants = @(Expand-SPIscEntitlementMembers -Entitlement $script:ent)
        }
        $sv = Save-SPIscReconCache -Data $data -CacheDir $dir
        $sv.Success | Should -Be $true
        Test-Path $sv.Data | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($sv.Data)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false   # no BOM

        $got = Get-SPIscReconCache -CacheDir $dir
        $got.Success | Should -Be $true
        @($got.Data.Identities).Count   | Should -Be 1
        @($got.Data.AccessGrants).Count | Should -Be 3
        $got.Data.FetchedAtUtc          | Should -Be '2026-06-10T08:00:00.0000000Z'
    }
    It "NEVER expires -- a cache fetched years ago still loads (no TTL/age check)" {
        $dir = Join-Path $TestDrive 'cache-old'
        $data = @{ FetchedAtUtc = '2020-01-01T00:00:00.0000000Z'; Identities = @((ConvertTo-SPIscIdentityRecord -IdentityDoc $script:docActive)); AccessGrants = @() }
        $null = Save-SPIscReconCache -Data $data -CacheDir $dir
        $got = Get-SPIscReconCache -CacheDir $dir
        $got.Success           | Should -Be $true
        $got.Data.FetchedAtUtc | Should -Be '2020-01-01T00:00:00.0000000Z'
    }
    It "reports a miss cleanly when no cache exists" {
        (Get-SPIscReconCache -CacheDir (Join-Path $TestDrive 'nope')).Success | Should -Be $false
    }
}
