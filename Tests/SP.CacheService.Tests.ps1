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

# ===========================================================================
# JSONL Persistence Tests (Tier 1)
# ===========================================================================

Describe "CD -- JSONL Persistence Layer" {

    BeforeAll {
        $script:TestTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "SPCacheTests_$(Get-Random)"
        New-Item -Path $script:TestTempDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:TestTempDir) {
            Remove-Item $script:TestTempDir -Recurse -Force
        }
    }

    # -----------------------------------------------------------------------
    # CD-01: Export-SPCacheStore writes valid JSONL (round-trip parse check)
    # -----------------------------------------------------------------------
    Context "CD-01: Export-SPCacheStore writes valid JSONL" {

        It "writes one JSON line per item that round-trip parses" {
            $storeName = "CD01_$(Get-Random)"
            New-SPCacheStore -Name $storeName
            Set-SPCachedItem -Store $storeName -Key 'alpha' -Value @{ Name = 'Alice'; Score = 10 }
            Set-SPCachedItem -Store $storeName -Key 'beta'  -Value @{ Name = 'Bob';   Score = 20 }

            $file = Join-Path $script:TestTempDir "cd01.jsonl"
            Export-SPCacheStore -Store $storeName -Path $file

            $lines = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $lines.Count | Should -Be 2

            foreach ($ln in $lines) {
                $parsed = $ln | ConvertFrom-Json
                $parsed.Key      | Should -Not -BeNullOrEmpty
                $parsed.CachedAt | Should -Not -BeNullOrEmpty
                $parsed.Value    | Should -Not -BeNullOrEmpty
            }
        }
    }

    # -----------------------------------------------------------------------
    # CD-02: Export with -Filter only exports matching items
    # -----------------------------------------------------------------------
    Context "CD-02: Export with -Filter only exports matching items" {

        It "filters items based on scriptblock" {
            $storeName = "CD02_$(Get-Random)"
            New-SPCacheStore -Name $storeName
            Set-SPCachedItem -Store $storeName -Key 'found1'   -Value @{ Found = $true;  Name = 'A' }
            Set-SPCachedItem -Store $storeName -Key 'notfound' -Value @{ Found = $false; Name = 'B' }
            Set-SPCachedItem -Store $storeName -Key 'found2'   -Value @{ Found = $true;  Name = 'C' }

            $file = Join-Path $script:TestTempDir "cd02.jsonl"
            Export-SPCacheStore -Store $storeName -Path $file -Filter { $_.Found -eq $true }

            $lines = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $lines.Count | Should -Be 2

            $keys = $lines | ForEach-Object { ($_ | ConvertFrom-Json).Key }
            $keys | Should -Contain 'found1'
            $keys | Should -Contain 'found2'
            $keys | Should -Not -Contain 'notfound'
        }
    }

    # -----------------------------------------------------------------------
    # CD-03: Import-SPCacheStore loads JSONL with correct values
    # -----------------------------------------------------------------------
    Context "CD-03: Import-SPCacheStore loads JSONL into store" {

        It "populates the in-memory store with correct values" {
            $storeName = "CD03_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            # Manually create a JSONL file
            $file = Join-Path $script:TestTempDir "cd03.jsonl"
            $now  = (Get-Date).ToString('o')
            $line1 = @{ Key = 'k1'; Value = @{ Data = 'hello' }; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $line2 = @{ Key = 'k2'; Value = @{ Data = 'world' }; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line1`n$line2`n", $utf8)

            $result = Import-SPCacheStore -Store $storeName -Path $file
            $result.Loaded | Should -Be 2

            $v1 = Get-SPCachedItem -Store $storeName -Key 'k1'
            $v1.Data | Should -Be 'hello'

            $v2 = Get-SPCachedItem -Store $storeName -Key 'k2'
            $v2.Data | Should -Be 'world'
        }
    }

    # -----------------------------------------------------------------------
    # CD-04: Import deduplicates (keeps newest)
    # -----------------------------------------------------------------------
    Context "CD-04: Import deduplicates by key (keeps newest)" {

        It "keeps the record with the later CachedAt" {
            $storeName = "CD04_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            $file = Join-Path $script:TestTempDir "cd04.jsonl"
            $old  = [datetime]::new(2026, 1, 1, 10, 0, 0).ToString('o')
            $new  = [datetime]::new(2026, 1, 1, 12, 0, 0).ToString('o')

            $lineOld = @{ Key = 'dup'; Value = @{ Ver = 'old' }; CachedAt = $old; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $lineNew = @{ Key = 'dup'; Value = @{ Ver = 'new' }; CachedAt = $new; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$lineOld`n$lineNew`n", $utf8)

            $result = Import-SPCacheStore -Store $storeName -Path $file
            $result.Loaded | Should -Be 1
            $result.Pruned | Should -Be 1

            $val = Get-SPCachedItem -Store $storeName -Key 'dup'
            $val.Ver | Should -Be 'new'
        }
    }

    # -----------------------------------------------------------------------
    # CD-05: Import prunes expired when TtlMinutes given
    # -----------------------------------------------------------------------
    Context "CD-05: Import prunes expired entries" {

        It "prunes entries older than TtlMinutes" {
            $storeName = "CD05_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            $file = Join-Path $script:TestTempDir "cd05.jsonl"
            $ancient = [datetime]::new(2020, 1, 1, 0, 0, 0).ToString('o')
            $recent  = (Get-Date).ToString('o')

            $lineExpired = @{ Key = 'old'; Value = @{ X = 1 }; CachedAt = $ancient; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $lineFresh   = @{ Key = 'new'; Value = @{ X = 2 }; CachedAt = $recent;  TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$lineExpired`n$lineFresh`n", $utf8)

            $result = Import-SPCacheStore -Store $storeName -Path $file -TtlMinutes 60
            $result.Loaded | Should -Be 1
            $result.Pruned | Should -Be 1

            Get-SPCachedItem -Store $storeName -Key 'old' | Should -BeNullOrEmpty
            (Get-SPCachedItem -Store $storeName -Key 'new').X | Should -Be 2
        }
    }

    # -----------------------------------------------------------------------
    # CD-06: Import -Compact rewrites file
    # -----------------------------------------------------------------------
    Context "CD-06: Import -Compact rewrites file" {

        It "compacts the file after loading (fewer lines)" {
            $storeName = "CD06_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            $file = Join-Path $script:TestTempDir "cd06.jsonl"
            $t1 = [datetime]::new(2026, 3, 1, 10, 0, 0).ToString('o')
            $t2 = [datetime]::new(2026, 3, 1, 12, 0, 0).ToString('o')

            # Two records for same key -- file has 2 lines
            $line1 = @{ Key = 'x'; Value = @{ V = 1 }; CachedAt = $t1; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $line2 = @{ Key = 'x'; Value = @{ V = 2 }; CachedAt = $t2; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line1`n$line2`n", $utf8)

            Import-SPCacheStore -Store $storeName -Path $file -Compact | Out-Null

            # After compact, file should have 1 non-empty line
            [array]$compactedLines = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $compactedLines.Count | Should -Be 1

            $parsed = $compactedLines[0] | ConvertFrom-Json
            $parsed.Value.V | Should -Be 2
        }
    }

    # -----------------------------------------------------------------------
    # CD-07: Import skips blank/malformed lines
    # -----------------------------------------------------------------------
    Context "CD-07: Import skips blank/malformed lines" {

        It "does not crash on blank or invalid JSON lines" {
            $storeName = "CD07_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            $file = Join-Path $script:TestTempDir "cd07.jsonl"
            $now  = (Get-Date).ToString('o')
            $good = @{ Key = 'ok'; Value = @{ Z = 1 }; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "`n$good`n{not valid json`n`n", $utf8)

            $result = Import-SPCacheStore -Store $storeName -Path $file
            $result.Loaded | Should -Be 1
            $result.Errors | Should -Be 1
            (Get-SPCachedItem -Store $storeName -Key 'ok').Z | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CD-08: Import returns Loaded/Pruned/Errors counts
    # -----------------------------------------------------------------------
    Context "CD-08: Import returns correct counts" {

        It "returns a hashtable with Loaded, Pruned, Errors" {
            $storeName = "CD08_$(Get-Random)"
            New-SPCacheStore -Name $storeName

            $file = Join-Path $script:TestTempDir "cd08.jsonl"
            $now     = (Get-Date).ToString('o')
            $ancient = [datetime]::new(2020, 1, 1).ToString('o')

            $ok1     = @{ Key = 'a'; Value = 1; CachedAt = $now;     TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $ok2     = @{ Key = 'b'; Value = 2; CachedAt = $now;     TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $expired = @{ Key = 'c'; Value = 3; CachedAt = $ancient; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $bad     = 'this is not json'

            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$ok1`n$ok2`n$expired`n$bad`n", $utf8)

            $result = Import-SPCacheStore -Store $storeName -Path $file -TtlMinutes 60
            $result.Loaded | Should -Be 2
            $result.Pruned | Should -Be 1
            $result.Errors | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CD-09: Add-SPCacheStoreEntry appends single line
    # -----------------------------------------------------------------------
    Context "CD-09: Add-SPCacheStoreEntry appends single line" {

        It "appends exactly one JSONL line to the file" {
            $storeName = "CD09_$(Get-Random)"
            New-SPCacheStore -Name $storeName
            Set-SPCachedItem -Store $storeName -Key 'first'  -Value 'one' -NoPersist
            Set-SPCachedItem -Store $storeName -Key 'second' -Value 'two' -NoPersist

            $file = Join-Path $script:TestTempDir "cd09.jsonl"
            # Seed file with first entry
            Add-SPCacheStoreEntry -Store $storeName -Key 'first' -Path $file

            $linesBefore = (Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            $linesBefore | Should -Be 1

            # Append second entry
            Add-SPCacheStoreEntry -Store $storeName -Key 'second' -Path $file

            $linesAfter = (Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            $linesAfter | Should -Be 2

            # Verify content
            $parsed = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }
            ($parsed | Where-Object { $_.Key -eq 'second' }).Value | Should -Be 'two'
        }
    }

    # -----------------------------------------------------------------------
    # CD-10: Add-SPCacheStoreEntry creates file if missing
    # -----------------------------------------------------------------------
    Context "CD-10: Add-SPCacheStoreEntry creates file if missing" {

        It "creates the file and parent directories" {
            $storeName = "CD10_$(Get-Random)"
            New-SPCacheStore -Name $storeName
            Set-SPCachedItem -Store $storeName -Key 'item' -Value 'data' -NoPersist

            $subdir = Join-Path $script:TestTempDir "cd10_subdir_$(Get-Random)"
            $file   = Join-Path $subdir "cache.jsonl"

            Test-Path $file | Should -Be $false

            Add-SPCacheStoreEntry -Store $storeName -Key 'item' -Path $file

            Test-Path $file | Should -Be $true
            $lines = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $lines.Count | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CD-11: Compress removes duplicates and expired
    # -----------------------------------------------------------------------
    Context "CD-11: Compress removes duplicates and expired entries" {

        It "compacts to only non-expired in-memory entries" {
            $storeName = "CD11_$(Get-Random)"
            New-SPCacheStore -Name $storeName -TtlMinutes 5

            # Add items at a known time
            $baseTime = [datetime]::new(2026, 6, 1, 12, 0, 0)
            Mock Get-Date { return $baseTime } -ModuleName SP.CacheService

            Set-SPCachedItem -Store $storeName -Key 'fresh' -Value 'yes' -NoPersist

            # Add an item that will be expired
            $oldTime = $baseTime.AddMinutes(-10)
            Mock Get-Date { return $oldTime } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $storeName -Key 'stale' -Value 'no' -NoPersist

            # Set time back to "now" for the compress operation
            Mock Get-Date { return $baseTime } -ModuleName SP.CacheService

            # Seed a file with 5 lines (including dupes) to check Before count
            $file = Join-Path $script:TestTempDir "cd11.jsonl"
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $lines = @()
            for ($i = 0; $i -lt 5; $i++) {
                $lines += (@{ Key = "k$i"; Value = $i; CachedAt = $baseTime.ToString('o'); TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress)
            }
            [System.IO.File]::WriteAllText($file, ($lines -join "`n") + "`n", $utf8)

            $result = Compress-SPCacheStore -Store $storeName -Path $file
            $result.Before | Should -Be 5
            $result.After  | Should -Be 1   # only 'fresh' survives
            $result.Pruned | Should -Be 1   # 'stale' is pruned

            # Verify file has exactly 1 non-empty line
            $compacted = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $compacted.Count | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CD-12: New-SPCacheStore -DiskPath stores path
    # -----------------------------------------------------------------------
    Context "CD-12: New-SPCacheStore -DiskPath stores path in metadata" {

        It "sets DiskPath, DiskLoaded, and DiskAutoAppend" {
            $file = Join-Path $script:TestTempDir "cd12.jsonl"
            $store = New-SPCacheStore -Name "CD12_$(Get-Random)" -DiskPath $file

            $store.DiskPath       | Should -Be $file
            $store.DiskLoaded     | Should -Be $false
            $store.DiskAutoAppend | Should -Be $true
        }

        It "DiskAutoAppend is false when no DiskPath given" {
            $store = New-SPCacheStore -Name "CD12b_$(Get-Random)"
            $store.DiskAutoAppend | Should -Be $false
        }
    }

    # -----------------------------------------------------------------------
    # CD-13: Set-SPCachedItem auto-appends when DiskPath set
    # -----------------------------------------------------------------------
    Context "CD-13: Set-SPCachedItem auto-appends when DiskPath set" {

        It "creates a JSONL line on disk after Set" {
            $sn = "CD13_$(Get-Random)"
            $sf = Join-Path $script:TestTempDir "cd13_auto.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $sf

            Set-SPCachedItem -Store $sn -Key 'auto1' -Value 'persisted'

            Test-Path $sf | Should -Be $true
            [array]$lines = Get-Content $sf | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $lines.Count | Should -BeGreaterOrEqual 1
            $parsed = $lines[-1] | ConvertFrom-Json
            $parsed.Key   | Should -Be 'auto1'
            $parsed.Value | Should -Be 'persisted'
        }
    }

    # -----------------------------------------------------------------------
    # CD-14: Set-SPCachedItem -NoPersist skips append
    # -----------------------------------------------------------------------
    Context "CD-14: Set-SPCachedItem -NoPersist skips append" {

        It "does not write to disk when -NoPersist is specified" {
            $sn   = "CD14_$(Get-Random)"
            $file = Join-Path $script:TestTempDir "cd14.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            Set-SPCachedItem -Store $sn -Key 'silent' -Value 'notondisk' -NoPersist

            # File should not exist or be empty
            if (Test-Path $file) {
                $lines = Get-Content $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $lines.Count | Should -Be 0
            } else {
                $true | Should -Be $true  # file not created -- correct
            }

            # But in-memory should work
            Get-SPCachedItem -Store $sn -Key 'silent' | Should -Be 'notondisk'
        }
    }

    # -----------------------------------------------------------------------
    # CD-15: Get-SPCachedItem triggers lazy Import
    # -----------------------------------------------------------------------
    Context "CD-15: Get-SPCachedItem triggers lazy Import on first access" {

        It "loads from disk on first Get when DiskPath is set" {
            $sn   = "CD15_$(Get-Random)"
            $file = Join-Path $script:TestTempDir "cd15.jsonl"

            # Pre-create a JSONL file with data
            $now = (Get-Date).ToString('o')
            $line = @{ Key = 'lazy'; Value = @{ Source = 'disk' }; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line`n", $utf8)

            # Create store with DiskPath -- items are empty, DiskLoaded = false
            New-SPCacheStore -Name $sn -DiskPath $file

            # Get triggers lazy load
            $val = Get-SPCachedItem -Store $sn -Key 'lazy'
            $val.Source | Should -Be 'disk'
        }
    }

    # -----------------------------------------------------------------------
    # CD-16: Full round-trip: Set -> Export -> Clear -> Import -> Get
    # -----------------------------------------------------------------------
    Context "CD-16: Full round-trip Set -> Export -> Clear -> Import -> Get" {

        It "survives a full cycle" {
            $sn   = "CD16_$(Get-Random)"
            $file = Join-Path $script:TestTempDir "cd16.jsonl"
            New-SPCacheStore -Name $sn

            # Set items
            Set-SPCachedItem -Store $sn -Key 'user1' -Value @{ Name = 'Alice'; Active = $true }
            Set-SPCachedItem -Store $sn -Key 'user2' -Value @{ Name = 'Bob';   Active = $false }

            # Export
            Export-SPCacheStore -Store $sn -Path $file

            # Clear
            Clear-SPCacheStore -Store $sn
            Get-SPCachedItem -Store $sn -Key 'user1' | Should -BeNullOrEmpty

            # Import
            $result = Import-SPCacheStore -Store $sn -Path $file
            $result.Loaded | Should -Be 2

            # Get -- values restored
            $u1 = Get-SPCachedItem -Store $sn -Key 'user1'
            $u1.Name   | Should -Be 'Alice'
            $u1.Active | Should -Be $true

            $u2 = Get-SPCachedItem -Store $sn -Key 'user2'
            $u2.Name   | Should -Be 'Bob'
            $u2.Active | Should -Be $false
        }
    }

    # -----------------------------------------------------------------------
    # CD-17: PS 5.1 datetime handling (CachedAt survives round-trip)
    # -----------------------------------------------------------------------
    Context "CD-17: CachedAt datetime survives ConvertFrom-Json round-trip" {

        It "parses CachedAt correctly after JSON serialization" {
            $sn   = "CD17_$(Get-Random)"
            $file = Join-Path $script:TestTempDir "cd17.jsonl"

            # Use a specific known local time (avoids UTC-vs-local offset issues)
            $known = [datetime]::new(2026, 3, 15, 14, 30, 0)
            $isoStr = $known.ToString('o')

            $line = @{ Key = 'dt'; Value = 'test'; CachedAt = $isoStr; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line`n", $utf8)

            New-SPCacheStore -Name $sn
            Import-SPCacheStore -Store $sn -Path $file | Out-Null

            # Export back out
            $file2 = Join-Path $script:TestTempDir "cd17_rt.jsonl"
            Export-SPCacheStore -Store $sn -Path $file2

            [array]$rtLines = Get-Content $file2 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $rtRec = $rtLines[0] | ConvertFrom-Json

            # Parse the round-tripped CachedAt -- it should still be parseable
            # and match the original to within a few seconds
            $rtDt = [datetime]::Parse([string]$rtRec.CachedAt)
            [Math]::Abs(($rtDt - $known).TotalSeconds) | Should -BeLessThan 2
        }
    }
}

# ===========================================================================
# Inspection & Stats Tests (Tier 2)
# ===========================================================================

Describe "CI -- Inspection and Stats" {

    BeforeAll {
        $script:CITempDir = Join-Path ([System.IO.Path]::GetTempPath()) "SPCacheCI_$(Get-Random)"
        New-Item -Path $script:CITempDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:CITempDir) {
            Remove-Item $script:CITempDir -Recurse -Force
        }
    }

    # -----------------------------------------------------------------------
    # CI-01: Get-SPCacheStoreInfo returns correct ItemCount
    # -----------------------------------------------------------------------
    Context "CI-01: Get-SPCacheStoreInfo returns correct ItemCount" {

        It "reports the number of items in the store" {
            $sn = "CI01_$(Get-Random)"
            New-SPCacheStore -Name $sn
            Set-SPCachedItem -Store $sn -Key 'a' -Value 1
            Set-SPCachedItem -Store $sn -Key 'b' -Value 2
            Set-SPCachedItem -Store $sn -Key 'c' -Value 3

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.ItemCount | Should -Be 3
        }
    }

    # -----------------------------------------------------------------------
    # CI-02: Get-SPCacheStoreInfo returns OldestEntry/NewestEntry
    # -----------------------------------------------------------------------
    Context "CI-02: Get-SPCacheStoreInfo returns OldestEntry/NewestEntry" {

        It "returns correct oldest and newest timestamps" {
            $sn = "CI02_$(Get-Random)"
            New-SPCacheStore -Name $sn

            $t1 = [datetime]::new(2026, 1, 1, 10, 0, 0)
            $t2 = [datetime]::new(2026, 1, 1, 12, 0, 0)
            $t3 = [datetime]::new(2026, 1, 1, 14, 0, 0)

            Mock Get-Date { return $t1 } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $sn -Key 'early' -Value 'first'
            Mock Get-Date { return $t2 } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $sn -Key 'mid'   -Value 'second'
            Mock Get-Date { return $t3 } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $sn -Key 'late'  -Value 'third'

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.OldestEntry | Should -Be $t1
            $info.NewestEntry | Should -Be $t3
        }
    }

    # -----------------------------------------------------------------------
    # CI-03: Get-SPCacheStoreInfo returns ExpiredCount
    # -----------------------------------------------------------------------
    Context "CI-03: Get-SPCacheStoreInfo returns ExpiredCount" {

        It "counts expired items without evicting them" {
            $sn = "CI03_$(Get-Random)"
            New-SPCacheStore -Name $sn -TtlMinutes 10

            $baseTime = [datetime]::new(2026, 6, 1, 12, 0, 0)

            # Add fresh item
            Mock Get-Date { return $baseTime } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $sn -Key 'fresh' -Value 'good'

            # Add item that will be expired
            $oldTime = $baseTime.AddMinutes(-15)
            Mock Get-Date { return $oldTime } -ModuleName SP.CacheService
            Set-SPCachedItem -Store $sn -Key 'stale' -Value 'bad'

            # Set time to "now" for the info check
            Mock Get-Date { return $baseTime } -ModuleName SP.CacheService

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.ExpiredCount | Should -Be 1
            # The stale item should still be in Items (not evicted)
            $info.ItemCount | Should -Be 2
        }
    }

    # -----------------------------------------------------------------------
    # CI-04: Get-SPCacheStoreInfo returns DiskSizeBytes when DiskPath set
    # -----------------------------------------------------------------------
    Context "CI-04: Get-SPCacheStoreInfo returns DiskSizeBytes" {

        It "reports file size in bytes for a disk-backed store" {
            $sn   = "CI04_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci04.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            Set-SPCachedItem -Store $sn -Key 'item1' -Value @{ Name = 'Test' }
            Set-SPCachedItem -Store $sn -Key 'item2' -Value @{ Name = 'Test2' }

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.DiskSizeBytes | Should -BeGreaterThan 0
        }
    }

    # -----------------------------------------------------------------------
    # CI-05: Get-SPCacheStoreInfo returns DiskLineCount
    # -----------------------------------------------------------------------
    Context "CI-05: Get-SPCacheStoreInfo returns DiskLineCount" {

        It "reports the number of non-empty lines in the JSONL file" {
            $sn   = "CI05_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci05.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            Set-SPCachedItem -Store $sn -Key 'x1' -Value 'a'
            Set-SPCachedItem -Store $sn -Key 'x2' -Value 'b'
            Set-SPCachedItem -Store $sn -Key 'x3' -Value 'c'

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.DiskLineCount | Should -Be 3
        }
    }

    # -----------------------------------------------------------------------
    # CI-06: Get-SPCacheStoreSummary returns all registered stores
    # -----------------------------------------------------------------------
    Context "CI-06: Get-SPCacheStoreSummary returns all registered stores" {

        It "includes stores created in this test" {
            $sn1 = "CI06a_$(Get-Random)"
            $sn2 = "CI06b_$(Get-Random)"
            New-SPCacheStore -Name $sn1 -TtlMinutes 30
            New-SPCacheStore -Name $sn2 -TtlMinutes 60
            Set-SPCachedItem -Store $sn1 -Key 'k' -Value 'v'

            $summary = Get-SPCacheStoreSummary
            $names = $summary | ForEach-Object { $_.Name }
            $names | Should -Contain $sn1
            $names | Should -Contain $sn2

            $entry1 = $summary | Where-Object { $_.Name -eq $sn1 }
            $entry1.ItemCount  | Should -Be 1
            $entry1.TtlMinutes | Should -Be 30
        }
    }

    # -----------------------------------------------------------------------
    # CI-07: Test-SPCacheStoreIntegrity Ok=$true for clean store
    # -----------------------------------------------------------------------
    Context "CI-07: Test-SPCacheStoreIntegrity Ok for clean store" {

        It "returns Ok=true when JSONL is valid and clean" {
            $sn   = "CI07_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci07.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            Set-SPCachedItem -Store $sn -Key 'clean1' -Value @{ Data = 'ok' }
            Set-SPCachedItem -Store $sn -Key 'clean2' -Value @{ Data = 'fine' }

            $result = Test-SPCacheStoreIntegrity -Store $sn
            $result.Ok | Should -Be $true
        }
    }

    # -----------------------------------------------------------------------
    # CI-08: Test-SPCacheStoreIntegrity detects duplicate keys
    # -----------------------------------------------------------------------
    Context "CI-08: Test-SPCacheStoreIntegrity detects duplicate keys" {

        It "reports DEDUP_NEEDED for duplicate keys in JSONL" {
            $sn   = "CI08_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci08.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            # Write duplicate keys directly to the JSONL file
            $now  = (Get-Date).ToString('o')
            $line1 = @{ Key = 'dup'; Value = 'v1'; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $line2 = @{ Key = 'dup'; Value = 'v2'; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $line3 = @{ Key = 'unique'; Value = 'v3'; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line1`n$line2`n$line3`n", $utf8)

            $result = Test-SPCacheStoreIntegrity -Store $sn
            $dedupFinding = $result.Findings | Where-Object { $_.Code -eq 'DEDUP_NEEDED' }
            $dedupFinding | Should -Not -BeNullOrEmpty
            $dedupFinding.Severity | Should -Be 'Warn'
            $dedupFinding.Count | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CI-09: Test-SPCacheStoreIntegrity detects expired ratio
    # -----------------------------------------------------------------------
    Context "CI-09: Test-SPCacheStoreIntegrity detects expired ratio" {

        It "reports EXPIRED_RATIO when entries are past TTL" {
            $sn   = "CI09_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci09.jsonl"
            New-SPCacheStore -Name $sn -TtlMinutes 10 -DiskPath $file

            # Write entries: one ancient, one fresh
            $ancient = [datetime]::new(2020, 1, 1, 0, 0, 0).ToString('o')
            $now     = (Get-Date).ToString('o')
            $line1 = @{ Key = 'old'; Value = 1; CachedAt = $ancient; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $line2 = @{ Key = 'new'; Value = 2; CachedAt = $now;     TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$line1`n$line2`n", $utf8)

            $result = Test-SPCacheStoreIntegrity -Store $sn
            $expFinding = $result.Findings | Where-Object { $_.Code -eq 'EXPIRED_RATIO' }
            $expFinding | Should -Not -BeNullOrEmpty
            $expFinding.Severity | Should -Be 'Info'
            $expFinding.Count | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CI-10: Test-SPCacheStoreIntegrity detects malformed JSON lines
    # -----------------------------------------------------------------------
    Context "CI-10: Test-SPCacheStoreIntegrity detects malformed JSON" {

        It "reports INVALID_JSON for lines that fail to parse" {
            $sn   = "CI10_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci10.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            # Write a mix of valid and invalid lines
            $now = (Get-Date).ToString('o')
            $good = @{ Key = 'ok'; Value = 1; CachedAt = $now; TtlMinutes = $null } | ConvertTo-Json -Depth 6 -Compress
            $bad1 = '{this is not valid'
            $bad2 = 'totally broken'
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($file, "$good`n$bad1`n$bad2`n", $utf8)

            $result = Test-SPCacheStoreIntegrity -Store $sn
            $result.Ok | Should -Be $false

            $jsonFinding = $result.Findings | Where-Object { $_.Code -eq 'INVALID_JSON' }
            $jsonFinding | Should -Not -BeNullOrEmpty
            $jsonFinding.Severity | Should -Be 'Error'
            $jsonFinding.Count | Should -Be 2
        }
    }

    # -----------------------------------------------------------------------
    # CI-11: Hit/miss tracking increments on Get (TrackStats enabled)
    # -----------------------------------------------------------------------
    Context "CI-11: Hit/miss tracking increments on Get" {

        It "increments HitCount on successful Get and MissCount on miss" {
            $sn = "CI11_$(Get-Random)"
            New-SPCacheStore -Name $sn -TrackStats
            Set-SPCachedItem -Store $sn -Key 'exists' -Value 'data'

            # Hit
            Get-SPCachedItem -Store $sn -Key 'exists' | Out-Null
            Get-SPCachedItem -Store $sn -Key 'exists' | Out-Null

            # Miss
            Get-SPCachedItem -Store $sn -Key 'nope' | Out-Null

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.HitCount  | Should -Be 2
            $info.MissCount | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # CI-12: HitRate calculation is correct
    # -----------------------------------------------------------------------
    Context "CI-12: HitRate calculation is correct" {

        It "computes the correct hit percentage" {
            $sn = "CI12_$(Get-Random)"
            New-SPCacheStore -Name $sn -TrackStats
            Set-SPCachedItem -Store $sn -Key 'present' -Value 'yes'

            # 3 hits, 1 miss = 75.0%
            Get-SPCachedItem -Store $sn -Key 'present' | Out-Null
            Get-SPCachedItem -Store $sn -Key 'present' | Out-Null
            Get-SPCachedItem -Store $sn -Key 'present' | Out-Null
            Get-SPCachedItem -Store $sn -Key 'missing' | Out-Null

            $info = Get-SPCacheStoreInfo -Store $sn
            $info.HitRate | Should -Be '75.0%'
        }
    }

    # -----------------------------------------------------------------------
    # CI-13: Stats reset on Clear-SPCacheStore
    # -----------------------------------------------------------------------
    Context "CI-13: Stats reset on Clear-SPCacheStore" {

        It "resets HitCount and MissCount to 0 after Clear" {
            $sn = "CI13_$(Get-Random)"
            New-SPCacheStore -Name $sn -TrackStats
            Set-SPCachedItem -Store $sn -Key 'item' -Value 'val'

            Get-SPCachedItem -Store $sn -Key 'item' | Out-Null   # hit
            Get-SPCachedItem -Store $sn -Key 'nope' | Out-Null   # miss

            $infoBefore = Get-SPCacheStoreInfo -Store $sn
            $infoBefore.HitCount  | Should -Be 1
            $infoBefore.MissCount | Should -Be 1

            Clear-SPCacheStore -Store $sn

            $infoAfter = Get-SPCacheStoreInfo -Store $sn
            $infoAfter.HitCount  | Should -Be 0
            $infoAfter.MissCount | Should -Be 0
            $infoAfter.HitRate   | Should -Be '0.0%'
        }
    }

    # -----------------------------------------------------------------------
    # CI-14: Get-SPCacheStoreInfo returns null for unknown store
    # -----------------------------------------------------------------------
    Context "CI-14: Get-SPCacheStoreInfo returns null for unknown store" {

        It "returns null for a store name that does not exist" {
            $result = Get-SPCacheStoreInfo -Store "NoSuchStore_$(Get-Random)"
            $result | Should -BeNullOrEmpty
        }
    }

    # -----------------------------------------------------------------------
    # CI-15: Test-SPCacheStoreIntegrity returns Error for missing file
    # -----------------------------------------------------------------------
    Context "CI-15: Test-SPCacheStoreIntegrity returns Error for missing file" {

        It "returns Ok=false with FILE_NOT_FOUND for non-existent disk file" {
            $sn = "CI15_$(Get-Random)"
            $file = Join-Path $script:CITempDir "ci15_nonexistent.jsonl"
            New-SPCacheStore -Name $sn -DiskPath $file

            $result = Test-SPCacheStoreIntegrity -Store $sn
            $result.Ok | Should -Be $false

            $finding = $result.Findings | Where-Object { $_.Code -eq 'FILE_NOT_FOUND' }
            $finding | Should -Not -BeNullOrEmpty
            $finding.Severity | Should -Be 'Error'
        }
    }
}
