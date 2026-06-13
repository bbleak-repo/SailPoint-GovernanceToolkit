<#
.SYNOPSIS
    Unit tests for SP.IdentityService -- shared identity resolution and caching.

    SI-01: Get-SPIdentityDetail        -- resolve identity by ID with API mock
    SI-02: Search-SPIdentityByEmail    -- search identity by email with API mock
    SI-03: Clear-SPIdentityCache       -- clear memory/disk caches
    SI-04: Caching behavior            -- verify second call returns cached result
    CM-01..CM-07: SP.CacheService migration tests (Tier 3)
#>
#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    # Import Core + Api stubs so Write-SPLog and Invoke-SPApiRequest exist as
    # mockable commands. Then import SP.IdentityService flat.
    Import-SPTestModules -Core -Api -Shared
}

# ---------------------------------------------------------------------------
# SI-01: Get-SPIdentityDetail
# ---------------------------------------------------------------------------

Describe "SI-01: Get-SPIdentityDetail" {

    BeforeEach {
        # Clear caches before each test so results are independent.
        # Use Clear-SPCacheStore to clear in-place (preserves alias wiring).
        # Ensure the store exists first, then mark disk as loaded to skip I/O.
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "returns resolved identity on successful API response" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    displayName = 'Alice Smith'
                    email       = 'alice@example.com'
                    manager     = [PSCustomObject]@{
                        id          = 'mgr-001'
                        displayName = 'Bob Manager'
                    }
                    attributes  = [PSCustomObject]@{
                        cloudLifecycleState = 'active'
                        jobLevel            = 'L5'
                    }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-alice-001'

        $result.Found       | Should -Be $true
        $result.DisplayName | Should -Be 'Alice Smith'
        $result.Email       | Should -Be 'alice@example.com'
        $result.ManagerId   | Should -Be 'mgr-001'
        $result.ManagerName | Should -Be 'Bob Manager'
        $result.IsActive    | Should -Be $true
        $result.JobLevel    | Should -Be 'L5'
        $result.IdentityId  | Should -Be 'id-alice-001'
    }

    It "returns empty result on failed API response" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{ Success = $false; Data = $null }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-missing-001'

        $result.Found       | Should -Be $false
        $result.DisplayName | Should -Be ''
        $result.IdentityId  | Should -Be 'id-missing-001'
    }

    It "marks terminated identities as inactive" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    displayName = 'Terminated User'
                    attributes  = [PSCustomObject]@{
                        cloudLifecycleState = 'terminated'
                    }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-term-001'

        $result.Found    | Should -Be $true
        $result.IsActive | Should -Be $false
        $result.CloudLifecycleState | Should -Be 'terminated'
    }

    It "extracts email from attributes bag as fallback" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    displayName = 'Attr Email User'
                    attributes  = [PSCustomObject]@{
                        email               = 'attr@example.com'
                        cloudLifecycleState = 'active'
                    }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-attr-001'

        $result.Email | Should -Be 'attr@example.com'
    }

    It "falls back to 'name' property when 'displayName' is missing" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    name       = 'Fallback Name'
                    attributes = [PSCustomObject]@{
                        cloudLifecycleState = 'active'
                    }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-fallback-001'

        $result.DisplayName | Should -Be 'Fallback Name'
    }

    It "handles API exception gracefully" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            throw "API connection failed"
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Get-SPIdentityDetail -IdentityId 'id-err-001'

        $result.Found      | Should -Be $false
        $result.IdentityId | Should -Be 'id-err-001'
    }
}

# ---------------------------------------------------------------------------
# SI-02: Search-SPIdentityByEmail
# ---------------------------------------------------------------------------

Describe "SI-02: Search-SPIdentityByEmail" {

    BeforeEach {
        # Clear SPEmailLookup store in-place (preserves alias wiring)
        & (Get-Module SP.IdentityService) { _EnsureSPIdentityStore }
        Clear-SPCacheStore -Store 'SPEmailLookup'
    }

    It "returns resolved identity on successful search" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{
                        id          = 'id-search-001'
                        displayName = 'Searched User'
                    }
                )
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'user@example.com'

        $result.Found       | Should -Be $true
        $result.IdentityId  | Should -Be 'id-search-001'
        $result.DisplayName | Should -Be 'Searched User'
    }

    It "returns empty result when no hits" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{ Success = $true; Data = @() }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'nobody@example.com'

        $result.Found      | Should -Be $false
        $result.IdentityId | Should -Be ''
    }

    It "returns empty result on failed API response" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{ Success = $false; Data = $null }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'fail@example.com'

        $result.Found | Should -Be $false
    }

    It "uses custom AttributeField when specified" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{
                        id   = 'id-custom-001'
                        name = 'Custom Field User'
                    }
                )
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'jsmith' `
            -AttributeField 'name'

        $result.Found       | Should -Be $true
        $result.IdentityId  | Should -Be 'id-custom-001'
        $result.DisplayName | Should -Be 'Custom Field User'
    }

    It "handles API exception gracefully" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            throw "Search API failed"
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'err@example.com'

        $result.Found | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# SI-03: Clear-SPIdentityCache
# ---------------------------------------------------------------------------

Describe "SI-03: Clear-SPIdentityCache" {

    BeforeEach {
        # Ensure stores exist, then seed data via SP.CacheService
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Set-SPCachedItem -Store 'SPIdentity' -Key 'id-1' -Value @{ Found = $true } -NoPersist
        Set-SPCachedItem -Store 'SPEmailLookup' -Key 'e:test@x.com' -Value @{ Found = $true }
    }

    It "clears all in-memory caches with no switches" {
        Mock Get-SPConfig -ModuleName SP.IdentityService {
            return [PSCustomObject]@{ Audit = [PSCustomObject]@{ OutputPath = 'C:\fake' } }
        }

        Clear-SPIdentityCache

        $cache = & (Get-Module SP.IdentityService) { $script:IdentityCache }
        $cache.Count | Should -Be 0

        $emailCache = & (Get-Module SP.IdentityService) { $script:EmailToIdentityCache }
        $emailCache.Count | Should -Be 0
    }

    It "clears only memory with -MemoryOnly" {
        Clear-SPIdentityCache -MemoryOnly

        $cache = & (Get-Module SP.IdentityService) { $script:IdentityCache }
        $cache.Count | Should -Be 0
    }

    It "does not clear memory with -DiskOnly" {
        Mock Get-SPConfig -ModuleName SP.IdentityService {
            return [PSCustomObject]@{ Audit = [PSCustomObject]@{ OutputPath = 'C:\fake' } }
        }

        Clear-SPIdentityCache -DiskOnly

        $cache = & (Get-Module SP.IdentityService) { $script:IdentityCache }
        $cache.Count | Should -Be 1
    }

    It "resets _IdentityDiskLoaded flag when memory is cleared" {
        Clear-SPIdentityCache -MemoryOnly

        $diskLoaded = & (Get-Module SP.IdentityService) { $script:_IdentityDiskLoaded }
        $diskLoaded | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# SI-04: Caching behavior
# ---------------------------------------------------------------------------

Describe "SI-04: Caching behavior" {

    BeforeEach {
        # Clear all stores in-place, mark disk loaded to skip I/O
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
        Clear-SPCacheStore -Store 'SPEmailLookup'
    }

    It "Get-SPIdentityDetail returns cached result on second call (no API call)" {
        $callCount = 0
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            $callCount++
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    displayName = 'Cached User'
                    attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}
        Mock Save-SPIdentityCacheEntry -ModuleName SP.IdentityService {}

        $first  = Get-SPIdentityDetail -IdentityId 'id-cache-001'
        $second = Get-SPIdentityDetail -IdentityId 'id-cache-001'

        $first.DisplayName  | Should -Be 'Cached User'
        $second.DisplayName | Should -Be 'Cached User'

        # API should only have been called once
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 1
    }

    It "Search-SPIdentityByEmail returns cached result on second call (no API call)" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{
                        id          = 'id-emailcache-001'
                        displayName = 'Email Cached'
                    }
                )
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $first  = Search-SPIdentityByEmail -AttributeValue 'cached@example.com'
        $second = Search-SPIdentityByEmail -AttributeValue 'cached@example.com'

        $first.IdentityId  | Should -Be 'id-emailcache-001'
        $second.IdentityId | Should -Be 'id-emailcache-001'

        # API should only have been called once
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 1
    }

    It "Search-SPIdentityByEmail cache is case-insensitive on attribute value" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{
                        id          = 'id-cicase-001'
                        displayName = 'Case User'
                    }
                )
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $first  = Search-SPIdentityByEmail -AttributeValue 'User@Example.COM'
        $second = Search-SPIdentityByEmail -AttributeValue 'user@example.com'

        $second.Found | Should -Be $true
        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 1
    }
}

# ===========================================================================
# CM: SP.CacheService Migration Tests (Tier 3)
# ===========================================================================

Describe "CM-01: Identity detail round-trip through SP.CacheService" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "stores and retrieves identity detail via SP.CacheService" {
        $detail = @{
            IdentityId          = 'cm01-id'
            DisplayName         = 'CM01 User'
            ManagerId           = 'cm01-mgr'
            ManagerName         = 'CM01 Manager'
            IsActive            = $true
            Found               = $true
            CloudLifecycleState = 'active'
            Email               = 'cm01@example.com'
            JobLevel            = 'L4'
        }

        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm01-id' -Value $detail -NoPersist

        $retrieved = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm01-id'
        $retrieved | Should -Not -BeNullOrEmpty
        $retrieved.DisplayName | Should -Be 'CM01 User'
        $retrieved.Email       | Should -Be 'cm01@example.com'
        $retrieved.Found       | Should -Be $true
    }
}

Describe "CM-02: Cache hit returns stored value without API call" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "Get-SPIdentityDetail returns cached value on second call (no API)" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = [PSCustomObject]@{
                    displayName = 'CM02 Cached'
                    attributes  = [PSCustomObject]@{ cloudLifecycleState = 'active' }
                }
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}
        Mock Save-SPIdentityCacheEntry -ModuleName SP.IdentityService {}

        $first  = Get-SPIdentityDetail -IdentityId 'cm02-id'
        $second = Get-SPIdentityDetail -IdentityId 'cm02-id'

        $first.DisplayName  | Should -Be 'CM02 Cached'
        $second.DisplayName | Should -Be 'CM02 Cached'

        # Verify the value is in SP.CacheService
        $cached = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm02-id'
        $cached.DisplayName | Should -Be 'CM02 Cached'

        Should -Invoke Invoke-SPApiRequest -ModuleName SP.IdentityService -Times 1
    }
}

Describe "CM-03: Clear-SPIdentityCache clears the SP.CacheService store" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm03-id' -Value @{ Found = $true; DisplayName = 'CM03' } -NoPersist
    }

    It "clears the SPIdentity store on Clear-SPIdentityCache" {
        # Verify item exists before clearing
        $before = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm03-id'
        $before | Should -Not -BeNullOrEmpty

        Clear-SPIdentityCache -MemoryOnly

        $after = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm03-id'
        $after | Should -BeNullOrEmpty
    }
}

Describe "CM-04: Get-SPIdentityCacheEntry delegates to SP.CacheService" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "returns value from SPIdentity store" {
        $detail = @{
            IdentityId  = 'cm04-id'
            DisplayName = 'CM04 User'
            Found       = $true
        }
        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm04-id' -Value $detail -NoPersist

        $result = Get-SPIdentityCacheEntry -IdentityId 'cm04-id'
        $result | Should -Not -BeNullOrEmpty
        $result.DisplayName | Should -Be 'CM04 User'
    }

    It "returns null for missing identity" {
        $result = Get-SPIdentityCacheEntry -IdentityId 'cm04-missing'
        $result | Should -BeNullOrEmpty
    }
}

Describe "CM-05: Set-SPIdentityCacheEntry delegates to SP.CacheService" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "stores value in SPIdentity store via Set-SPIdentityCacheEntry" {
        Mock Save-SPIdentityCacheEntry -ModuleName SP.IdentityService {}

        $detail = @{
            IdentityId  = 'cm05-id'
            DisplayName = 'CM05 User'
            Found       = $true
        }
        Set-SPIdentityCacheEntry -IdentityId 'cm05-id' -Detail $detail

        $cached = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm05-id'
        $cached | Should -Not -BeNullOrEmpty
        $cached.DisplayName | Should -Be 'CM05 User'
    }
}

Describe "CM-06: Email search uses separate SPEmailLookup store" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPEmailLookup'
    }

    It "stores email search results in SPEmailLookup, not SPIdentity" {
        Mock Invoke-SPApiRequest -ModuleName SP.IdentityService {
            return @{
                Success = $true
                Data    = @(
                    [PSCustomObject]@{
                        id          = 'cm06-id'
                        displayName = 'CM06 Email User'
                    }
                )
            }
        }
        Mock Write-SPLog -ModuleName SP.IdentityService {}

        $result = Search-SPIdentityByEmail -AttributeValue 'cm06@example.com'
        $result.Found | Should -Be $true

        # Check the SPEmailLookup store has the entry
        $cached = Get-SPCachedItem -Store 'SPEmailLookup' -Key 'attributes.email:cm06@example.com'
        $cached | Should -Not -BeNullOrEmpty
        $cached.IdentityId | Should -Be 'cm06-id'

        # SPIdentity store should NOT have this entry (email search does not populate it)
        $idCached = Get-SPCachedItem -Store 'SPIdentity' -Key 'cm06-id'
        $idCached | Should -BeNullOrEmpty
    }
}

Describe "CM-07: Get-SPCacheStoreInfo returns identity cache metrics" {

    BeforeEach {
        & (Get-Module SP.IdentityService) {
            _EnsureSPIdentityStore
            $script:_IdentityDiskLoaded = $true
        }
        Clear-SPCacheStore -Store 'SPIdentity'
    }

    It "reports ItemCount and stats for the SPIdentity store" {
        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm07-a' -Value @{ Found = $true } -NoPersist
        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm07-b' -Value @{ Found = $true } -NoPersist

        $info = Get-SPCacheStoreInfo -Store 'SPIdentity'
        $info | Should -Not -BeNullOrEmpty
        $info.Name      | Should -Be 'SPIdentity'
        $info.ItemCount | Should -Be 2
    }

    It "tracks hits and misses when TrackStats is enabled" {
        Set-SPCachedItem -Store 'SPIdentity' -Key 'cm07-hit' -Value @{ Found = $true } -NoPersist

        # Generate hits and misses
        Get-SPCachedItem -Store 'SPIdentity' -Key 'cm07-hit'  | Out-Null  # hit
        Get-SPCachedItem -Store 'SPIdentity' -Key 'cm07-miss' | Out-Null  # miss

        $info = Get-SPCacheStoreInfo -Store 'SPIdentity'
        $info.HitCount  | Should -BeGreaterOrEqual 1
        $info.MissCount | Should -BeGreaterOrEqual 1
    }
}
