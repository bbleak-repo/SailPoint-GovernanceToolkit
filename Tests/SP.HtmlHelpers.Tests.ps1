<#
.SYNOPSIS
    Unit tests for SP.HtmlHelpers -- shared HTML encoding, date formatting,
    property access, color palette, document scaffolding, and file writing.

    SH-01: ConvertTo-SPHtmlSafe   -- HTML encoding
    SH-02: Format-SPHtmlDate      -- date formatting
    SH-03: Get-SPObjectProperty   -- polymorphic property reader
    SH-04: Get-SPHtmlColorPalette -- color palette
    SH-05: New-SPHtmlDocument     -- StringBuilder factory
    SH-06: Write-SPHtmlFile       -- UTF-8 no-BOM writer
#>
#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared
}

# ---------------------------------------------------------------------------
# SH-01: ConvertTo-SPHtmlSafe
# ---------------------------------------------------------------------------

Describe "SH-01: ConvertTo-SPHtmlSafe" {

    It "encodes angle brackets" {
        ConvertTo-SPHtmlSafe '<script>' | Should -Be '&lt;script&gt;'
    }

    It "encodes ampersand" {
        ConvertTo-SPHtmlSafe 'foo & bar' | Should -Be 'foo &amp; bar'
    }

    It "returns empty string for null" {
        ConvertTo-SPHtmlSafe $null | Should -Be ''
    }

    It "returns empty string for empty string" {
        ConvertTo-SPHtmlSafe '' | Should -Be ''
    }

    It "returns empty string for whitespace-only string" {
        ConvertTo-SPHtmlSafe '   ' | Should -Be ''
    }

    It "handles numeric input by casting to string and encoding" {
        $result = ConvertTo-SPHtmlSafe 42
        $result | Should -Be '42'
    }
}

# ---------------------------------------------------------------------------
# SH-02: Format-SPHtmlDate
# ---------------------------------------------------------------------------

Describe "SH-02: Format-SPHtmlDate" {

    It "formats a valid ISO 8601 date to 'yyyy-MM-dd HH:mm'" {
        # Use a local-time literal so the test is not affected by the runner's timezone offset.
        $localInput = '2026-06-11T09:30:00'
        $expected = [datetime]::Parse($localInput).ToString('yyyy-MM-dd HH:mm')
        Format-SPHtmlDate $localInput | Should -Be $expected
    }

    It "returns the raw string on unparseable input" {
        Format-SPHtmlDate 'not-a-date' | Should -Be 'not-a-date'
    }

    It "returns empty string for null" {
        Format-SPHtmlDate $null | Should -Be ''
    }

    It "returns empty string for empty string" {
        Format-SPHtmlDate '' | Should -Be ''
    }

    It "-AsDateTime returns a [datetime] for valid input" {
        $result = Format-SPHtmlDate '2026-06-11T09:30:00Z' -AsDateTime
        $result | Should -BeOfType [datetime]
    }

    It "-AsDateTime returns null for invalid input" {
        $result = Format-SPHtmlDate 'not-a-date' -AsDateTime
        $result | Should -BeNullOrEmpty
    }

    It "-AsDateTime returns null for empty string" {
        $result = Format-SPHtmlDate '' -AsDateTime
        $result | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# SH-03: Get-SPObjectProperty
# ---------------------------------------------------------------------------

Describe "SH-03: Get-SPObjectProperty" {

    It "reads a value from a hashtable" {
        $ht = @{ Name = 'Alice' }
        Get-SPObjectProperty -Object $ht -Name 'Name' | Should -Be 'Alice'
    }

    It "reads a value from an ordered dictionary" {
        $od = [ordered]@{ Status = 'Active' }
        Get-SPObjectProperty -Object $od -Name 'Status' | Should -Be 'Active'
    }

    It "reads a value from a PSCustomObject" {
        $obj = [PSCustomObject]@{ Score = 99 }
        Get-SPObjectProperty -Object $obj -Name 'Score' | Should -Be 99
    }

    It "returns the default for a missing key" {
        $ht = @{ Present = 'yes' }
        Get-SPObjectProperty -Object $ht -Name 'Missing' | Should -BeNullOrEmpty
    }

    It "returns the default when the stored value is null" {
        $ht = @{ NullKey = $null }
        Get-SPObjectProperty -Object $ht -Name 'NullKey' | Should -BeNullOrEmpty
    }

    It "returns the default for a null object" {
        Get-SPObjectProperty -Object $null -Name 'Anything' | Should -BeNullOrEmpty
    }

    It "returns a custom default value when specified" {
        $ht = @{}
        Get-SPObjectProperty -Object $ht -Name 'Missing' -Default 'fallback' | Should -Be 'fallback'
    }
}

# ---------------------------------------------------------------------------
# SH-04: Get-SPHtmlColorPalette
# ---------------------------------------------------------------------------

Describe "SH-04: Get-SPHtmlColorPalette" {

    BeforeAll {
        $script:palette = Get-SPHtmlColorPalette
    }

    It "returns a hashtable" {
        $script:palette | Should -BeOfType [hashtable]
    }

    It "contains a Green key" {
        $script:palette.ContainsKey('Green') | Should -Be $true
    }

    It "contains a Red key" {
        $script:palette.ContainsKey('Red') | Should -Be $true
    }

    It "contains an Amber key" {
        $script:palette.ContainsKey('Amber') | Should -Be $true
    }

    It "contains a Blue key" {
        $script:palette.ContainsKey('Blue') | Should -Be $true
    }

    It "contains a Dark key" {
        $script:palette.ContainsKey('Dark') | Should -Be $true
    }

    It "contains a Gray key" {
        $script:palette.ContainsKey('Gray') | Should -Be $true
    }

    It "Green is '#0a7d2c'" {
        $script:palette['Green'] | Should -Be '#0a7d2c'
    }

    It "all values match the '#' + hex pattern" {
        foreach ($key in $script:palette.Keys) {
            $script:palette[$key] | Should -Match '^#[0-9a-fA-F]{3,6}$'
        }
    }
}

# ---------------------------------------------------------------------------
# SH-05: New-SPHtmlDocument
# ---------------------------------------------------------------------------

Describe "SH-05: New-SPHtmlDocument" {

    It "returns a System.Text.StringBuilder" {
        $sb = New-SPHtmlDocument -Title 'Test Report'
        $sb | Should -BeOfType [System.Text.StringBuilder]
    }

    It "contains DOCTYPE declaration" {
        $sb = New-SPHtmlDocument -Title 'Test Report'
        $sb.ToString() | Should -Match '<!DOCTYPE html>'
    }

    It "contains charset meta tag" {
        $sb = New-SPHtmlDocument -Title 'Test Report'
        $sb.ToString() | Should -Match "charset='utf-8'"
    }

    It "HTML-encodes the title in the output" {
        $sb = New-SPHtmlDocument -Title '<My Report & More>'
        $sb.ToString() | Should -Match '&lt;My Report &amp; More&gt;'
    }

    It "embeds custom CSS when provided" {
        $css = 'body{color:red;}'
        $sb = New-SPHtmlDocument -Title 'Styled' -Css $css
        $sb.ToString() | Should -Match 'body\{color:red;\}'
    }
}

# ---------------------------------------------------------------------------
# SH-06: Write-SPHtmlFile
# ---------------------------------------------------------------------------

Describe "SH-06: Write-SPHtmlFile" {

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sh06-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }

    AfterAll {
        if ($script:tempDir -and (Test-Path $script:tempDir)) {
            Remove-Item -Recurse -Force $script:tempDir -ErrorAction SilentlyContinue
        }
    }

    It "creates a file at the specified path" {
        $path = Join-Path $script:tempDir 'out1.html'
        Write-SPHtmlFile -Path $path -Content '<html></html>'
        Test-Path $path | Should -Be $true
    }

    It "file content matches the input string" {
        $path = Join-Path $script:tempDir 'out2.html'
        $content = '<!DOCTYPE html><html><body>Hello</body></html>'
        Write-SPHtmlFile -Path $path -Content $content
        [System.IO.File]::ReadAllText($path) | Should -Be $content
    }

    It "file is UTF-8 without BOM (first 3 bytes are not EF BB BF)" {
        $path = Join-Path $script:tempDir 'out3.html'
        Write-SPHtmlFile -Path $path -Content '<html>test</html>'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # A UTF-8 BOM starts with 0xEF 0xBB 0xBF -- assert the file does NOT start with all three
        $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
        $hasBom | Should -Be $false
    }

    It "creates parent directories if they do not exist" {
        $nested = Join-Path $script:tempDir 'sub\nested\deep'
        $path = Join-Path $nested 'report.html'
        Write-SPHtmlFile -Path $path -Content '<html></html>'
        Test-Path $path | Should -Be $true
    }

    It "overwrites an existing file" {
        $path = Join-Path $script:tempDir 'out4.html'
        Write-SPHtmlFile -Path $path -Content 'original'
        Write-SPHtmlFile -Path $path -Content 'replaced'
        [System.IO.File]::ReadAllText($path) | Should -Be 'replaced'
    }
}
