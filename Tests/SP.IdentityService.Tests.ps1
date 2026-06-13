<#
.SYNOPSIS
    Unit tests for SP.IdentityService -- shared identity resolution and caching.

    SI-01: Get-SPIdentityDetail        -- resolve identity by ID with API mock
    SI-02: Search-SPIdentityByEmail    -- search identity by email with API mock
    SI-03: Clear-SPIdentityCache       -- clear memory/disk caches
    SI-04: Caching behavior            -- verify second call returns cached result
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
        # Clear caches before each test so results are independent
        & (Get-Module SP.IdentityService) { $script:IdentityCache = @{}; $script:_IdentityDiskLoaded = $true; $script:_IdentityCachedAt = @{} }
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
        & (Get-Module SP.IdentityService) { $script:EmailToIdentityCache = @{} }
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
        & (Get-Module SP.IdentityService) {
            $script:IdentityCache = @{ 'id-1' = @{ Found = $true } }
            $script:_IdentityCachedAt = @{ 'id-1' = (Get-Date) }
            $script:EmailToIdentityCache = @{ 'e:test@x.com' = @{ Found = $true } }
            $script:_IdentityDiskLoaded = $true
        }
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
        & (Get-Module SP.IdentityService) {
            $script:IdentityCache = @{}
            $script:_IdentityDiskLoaded = $true
            $script:_IdentityCachedAt = @{}
            $script:EmailToIdentityCache = @{}
        }
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
