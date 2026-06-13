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
