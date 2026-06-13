<#
.SYNOPSIS
    Unit tests for SP.CacheService -- generic in-memory cache with TTL.

    CS-01: New-SPCacheStore creates a store with default TTL
    CS-02: New-SPCacheStore creates a store with custom TTL
    CS-03: Set/Get round-trip works
    CS-04: Get returns $null for expired item
    CS-05: Test-SPCacheValid returns $true/$false correctly
    CS-06: Clear-SPCacheStore flushes all items
    CS-07: Auto-create store on Set if it doesn't exist
    CS-08: Get returns $null for missing key
#>
#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared
}

# ---------------------------------------------------------------------------
# CS-01: New-SPCacheStore -- default TTL
# ---------------------------------------------------------------------------

Describe "CS-01: New-SPCacheStore creates a store with default TTL" {

    It "returns a hashtable with the store Name" {
        $store = New-SPCacheStore -Name 'Test01'
        $store.Name | Should -Be 'Test01'
    }

    It "default TtlMinutes is 0 (no expiry)" {
        $store = New-SPCacheStore -Name 'Test01Default'
        $store.TtlMinutes | Should -Be 0
    }

    It "Items is an empty hashtable" {
        $store = New-SPCacheStore -Name 'Test01Items'
        $store.Items | Should -BeOfType [hashtable]
        $store.Items.Count | Should -Be 0
    }

    It "Timestamps is an empty hashtable" {
        $store = New-SPCacheStore -Name 'Test01Ts'
        $store.Timestamps | Should -BeOfType [hashtable]
        $store.Timestamps.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# CS-02: New-SPCacheStore -- custom TTL
# ---------------------------------------------------------------------------

Describe "CS-02: New-SPCacheStore creates a store with custom TTL" {

    It "sets TtlMinutes to the specified value" {
        $store = New-SPCacheStore -Name 'Test02' -TtlMinutes 60
        $store.TtlMinutes | Should -Be 60
    }

    It "re-creating a store replaces the previous one" {
        New-SPCacheStore -Name 'Test02Replace' -TtlMinutes 10
        Set-SPCachedItem -Store 'Test02Replace' -Key 'k' -Value 'v'
        $store = New-SPCacheStore -Name 'Test02Replace' -TtlMinutes 20
        $store.TtlMinutes | Should -Be 20
        $store.Items.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# CS-03: Set/Get round-trip
# ---------------------------------------------------------------------------

Describe "CS-03: Set/Get round-trip works" {

    BeforeEach {
        New-SPCacheStore -Name 'RoundTrip'
    }

    It "string value round-trips" {
        Set-SPCachedItem -Store 'RoundTrip' -Key 'greeting' -Value 'hello'
        Get-SPCachedItem -Store 'RoundTrip' -Key 'greeting' | Should -Be 'hello'
    }

    It "integer value round-trips" {
        Set-SPCachedItem -Store 'RoundTrip' -Key 'count' -Value 42
        Get-SPCachedItem -Store 'RoundTrip' -Key 'count' | Should -Be 42
    }

    It "hashtable value round-trips" {
        $ht = @{ A = 1; B = 2 }
        Set-SPCachedItem -Store 'RoundTrip' -Key 'data' -Value $ht
        $result = Get-SPCachedItem -Store 'RoundTrip' -Key 'data'
        $result.A | Should -Be 1
        $result.B | Should -Be 2
    }

    It "overwriting a key replaces the value" {
        Set-SPCachedItem -Store 'RoundTrip' -Key 'x' -Value 'first'
        Set-SPCachedItem -Store 'RoundTrip' -Key 'x' -Value 'second'
        Get-SPCachedItem -Store 'RoundTrip' -Key 'x' | Should -Be 'second'
    }
}

# ---------------------------------------------------------------------------
# CS-04: Get returns $null for expired item
# ---------------------------------------------------------------------------

Describe "CS-04: Get returns `$null for expired item" {

    It "returns null when TTL has elapsed (mocked Get-Date)" {
        New-SPCacheStore -Name 'Expiry' -TtlMinutes 5

        # Store an item at a fixed "now"
        $baseTime = [datetime]::new(2026, 1, 1, 12, 0, 0)

        # Mock Get-Date to return the base time during Set
        Mock Get-Date { return $baseTime } -ModuleName SP.CacheService
        Set-SPCachedItem -Store 'Expiry' -Key 'item1' -Value 'data'

        # Move clock forward past TTL
        $expiredTime = $baseTime.AddMinutes(6)
        Mock Get-Date { return $expiredTime } -ModuleName SP.CacheService
        $result = Get-SPCachedItem -Store 'Expiry' -Key 'item1'
        $result | Should -BeNullOrEmpty
    }

    It "returns the value when TTL has NOT elapsed (mocked Get-Date)" {
        New-SPCacheStore -Name 'NoExpiry' -TtlMinutes 10

        $baseTime = [datetime]::new(2026, 1, 1, 12, 0, 0)
        Mock Get-Date { return $baseTime } -ModuleName SP.CacheService
        Set-SPCachedItem -Store 'NoExpiry' -Key 'item2' -Value 'stillgood'

        $laterTime = $baseTime.AddMinutes(5)
        Mock Get-Date { return $laterTime } -ModuleName SP.CacheService
        Get-SPCachedItem -Store 'NoExpiry' -Key 'item2' | Should -Be 'stillgood'
    }
}

# ---------------------------------------------------------------------------
# CS-05: Test-SPCacheValid
# ---------------------------------------------------------------------------

Describe "CS-05: Test-SPCacheValid returns correct validity" {

    It "returns true for a valid (non-expired) item" {
        New-SPCacheStore -Name 'ValidTest'
        Set-SPCachedItem -Store 'ValidTest' -Key 'ok' -Value 1
        Test-SPCacheValid -Store 'ValidTest' -Key 'ok' | Should -Be $true
    }

    It "returns false for a missing key" {
        New-SPCacheStore -Name 'ValidTest2'
        Test-SPCacheValid -Store 'ValidTest2' -Key 'nope' | Should -Be $false
    }

    It "returns false for an expired item (mocked Get-Date)" {
        New-SPCacheStore -Name 'ValidExpired' -TtlMinutes 3

        $baseTime = [datetime]::new(2026, 6, 1, 8, 0, 0)
        Mock Get-Date { return $baseTime } -ModuleName SP.CacheService
        Set-SPCachedItem -Store 'ValidExpired' -Key 'old' -Value 'stale'

        $futureTime = $baseTime.AddMinutes(5)
        Mock Get-Date { return $futureTime } -ModuleName SP.CacheService
        Test-SPCacheValid -Store 'ValidExpired' -Key 'old' | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# CS-06: Clear-SPCacheStore
# ---------------------------------------------------------------------------

Describe "CS-06: Clear-SPCacheStore flushes all items" {

    It "removes all items from the store" {
        New-SPCacheStore -Name 'ClearMe'
        Set-SPCachedItem -Store 'ClearMe' -Key 'a' -Value 1
        Set-SPCachedItem -Store 'ClearMe' -Key 'b' -Value 2
        Clear-SPCacheStore -Store 'ClearMe'
        Get-SPCachedItem -Store 'ClearMe' -Key 'a' | Should -BeNullOrEmpty
        Get-SPCachedItem -Store 'ClearMe' -Key 'b' | Should -BeNullOrEmpty
    }

    It "store still exists after clearing (can add items again)" {
        New-SPCacheStore -Name 'ClearReuse' -TtlMinutes 30
        Set-SPCachedItem -Store 'ClearReuse' -Key 'x' -Value 'old'
        Clear-SPCacheStore -Store 'ClearReuse'
        Set-SPCachedItem -Store 'ClearReuse' -Key 'x' -Value 'new'
        Get-SPCachedItem -Store 'ClearReuse' -Key 'x' | Should -Be 'new'
    }

    It "is a no-op for a non-existent store" {
        { Clear-SPCacheStore -Store 'NeverCreated' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# CS-07: Auto-create store on Set
# ---------------------------------------------------------------------------

Describe "CS-07: Auto-create store on Set if it doesn't exist" {

    It "Set-SPCachedItem auto-creates the store with TtlMinutes=0" {
        # Use a unique name unlikely to have been created elsewhere
        $storeName = "AutoCreate_$(Get-Random)"
        Set-SPCachedItem -Store $storeName -Key 'auto' -Value 'magic'
        Get-SPCachedItem -Store $storeName -Key 'auto' | Should -Be 'magic'
    }

    It "auto-created store has TtlMinutes=0 so items never expire" {
        $storeName = "AutoNoExpiry_$(Get-Random)"
        $baseTime = [datetime]::new(2026, 1, 1, 0, 0, 0)
        Mock Get-Date { return $baseTime } -ModuleName SP.CacheService
        Set-SPCachedItem -Store $storeName -Key 'forever' -Value 'permanent'

        $farFuture = $baseTime.AddMinutes(999999)
        Mock Get-Date { return $farFuture } -ModuleName SP.CacheService
        Get-SPCachedItem -Store $storeName -Key 'forever' | Should -Be 'permanent'
    }
}

# ---------------------------------------------------------------------------
# CS-08: Get returns $null for missing key
# ---------------------------------------------------------------------------

Describe "CS-08: Get returns `$null for missing key" {

    It "returns null for a key that was never set" {
        New-SPCacheStore -Name 'MissingKey'
        Get-SPCachedItem -Store 'MissingKey' -Key 'nonexistent' | Should -BeNullOrEmpty
    }

    It "returns null from an auto-created store for a missing key" {
        $storeName = "AutoMissing_$(Get-Random)"
        Get-SPCachedItem -Store $storeName -Key 'ghost' | Should -BeNullOrEmpty
    }
}
