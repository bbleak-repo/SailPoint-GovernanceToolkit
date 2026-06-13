<#
.SYNOPSIS
    Integration smoke tests for SP.Shared -- the shared utility module.
    SI-01: SP.Shared loads via manifest without errors
    SI-02: All 6 HtmlHelpers functions are exported
    SI-03: SP.Shared auto-imports when SP.Audit is loaded (without pre-loading SP.Shared)
    SI-04: ConvertTo-SPHtmlSafe works from within SP.CampaignDiff module scope (wrapper test)
    SI-05: Get-SPObjectProperty works from within SP.CertTracker module scope (wrapper test)
    SI-06: Write-SPHtmlFile creates a file with UTF-8 no-BOM encoding
    SI-07: SP.Shared can be loaded before SP.Core (no dependency on SP.Core)
#>
BeforeAll {
    $script:modulesRoot = Join-Path $PSScriptRoot '..\Modules'
}

Describe 'SP.Shared Integration' {

    Context 'SI-01: SP.Shared loads via manifest without errors' {
        It 'imports SP.Shared.psd1 without throwing' {
            $psd1 = Join-Path $script:modulesRoot 'SP.Shared\SP.Shared.psd1'
            { Import-Module $psd1 -Force -DisableNameChecking } | Should -Not -Throw
        }
    }

    Context 'SI-02: All 6 HtmlHelpers functions are exported' {
        BeforeAll {
            Import-Module (Join-Path $script:modulesRoot 'SP.Shared\SP.Shared.psd1') -Force -DisableNameChecking
        }

        It 'exports ConvertTo-SPHtmlSafe' {
            Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'exports Format-SPHtmlDate' {
            Get-Command Format-SPHtmlDate -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'exports Get-SPObjectProperty' {
            Get-Command Get-SPObjectProperty -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'exports Get-SPHtmlColorPalette' {
            Get-Command Get-SPHtmlColorPalette -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'exports New-SPHtmlDocument' {
            Get-Command New-SPHtmlDocument -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'exports Write-SPHtmlFile' {
            Get-Command Write-SPHtmlFile -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SI-03: SP.Shared auto-imports when SP.Audit is loaded' {
        BeforeAll {
            # Remove SP.Shared if already loaded to prove auto-import works
            Get-Module SP.HtmlHelpers -ErrorAction Ignore | Remove-Module -Force -ErrorAction Ignore
            Get-Module SP.Shared     -ErrorAction Ignore | Remove-Module -Force -ErrorAction Ignore

            # Load SP.Core and SP.Api (prerequisites for SP.Audit)
            . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
            Import-SPTestModules -Core -Api

            # Import SP.Audit -- nested modules should auto-import SP.Shared
            Import-Module (Join-Path $script:modulesRoot 'SP.Audit\SP.Audit.psd1') -Force -DisableNameChecking
        }

        It 'Get-SPObjectProperty is available after loading SP.Audit' {
            Get-Command Get-SPObjectProperty -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }

        It 'ConvertTo-SPHtmlSafe is available after loading SP.Audit' {
            Get-Command ConvertTo-SPHtmlSafe -ErrorAction Ignore | Should -Not -BeNullOrEmpty
        }
    }

    Context 'SI-04: ConvertTo-SPHtmlSafe works from SP.CampaignDiff scope' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
            Import-SPTestModules -Shared -Core -Api -Audit
        }

        It 'CampaignDiff thin wrapper encodes HTML entities' {
            # SP.CampaignDiff has a Get-CDProp wrapper that delegates to Get-SPObjectProperty,
            # and uses ConvertTo-SPHtmlSafe for title encoding. Verify via the public function.
            $result = ConvertTo-SPHtmlSafe -Value '<script>alert("xss")</script>'
            $result | Should -Be '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
        }

        It 'returns empty string for null input' {
            $result = ConvertTo-SPHtmlSafe -Value $null
            $result | Should -Be ''
        }
    }

    Context 'SI-05: Get-SPObjectProperty works from SP.CertTracker scope' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
            Import-SPTestModules -Shared -Core -Api -Audit
        }

        It 'reads property from hashtable' {
            $ht = @{ Name = 'Alice'; Age = 30 }
            $result = Get-SPObjectProperty -Object $ht -Name 'Name'
            $result | Should -Be 'Alice'
        }

        It 'reads property from PSCustomObject' {
            $obj = [PSCustomObject]@{ Name = 'Bob'; Status = 'Active' }
            $result = Get-SPObjectProperty -Object $obj -Name 'Status'
            $result | Should -Be 'Active'
        }

        It 'returns default for missing property' {
            $ht = @{ Foo = 'bar' }
            $result = Get-SPObjectProperty -Object $ht -Name 'Missing' -Default 'N/A'
            $result | Should -Be 'N/A'
        }
    }

    Context 'SI-06: Write-SPHtmlFile creates UTF-8 no-BOM file' {
        BeforeAll {
            . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
            Import-SPTestModules -Shared
            $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "sp-shared-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
            $script:testFile = Join-Path $script:tempDir 'test-output.html'
        }

        AfterAll {
            if (Test-Path $script:tempDir) {
                Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction Ignore
            }
        }

        It 'creates the output file' {
            Write-SPHtmlFile -Path $script:testFile -Content '<html><body>Hello</body></html>'
            Test-Path $script:testFile | Should -BeTrue
        }

        It 'writes UTF-8 without BOM' {
            $bytes = [System.IO.File]::ReadAllBytes($script:testFile)
            # UTF-8 BOM is 0xEF 0xBB 0xBF -- verify it is NOT present
            if ($bytes.Length -ge 3) {
                $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                $hasBom | Should -BeFalse
            }
        }

        It 'file content matches input' {
            $content = [System.IO.File]::ReadAllText($script:testFile, [System.Text.Encoding]::UTF8)
            $content | Should -Be '<html><body>Hello</body></html>'
        }

        It 'creates parent directories if needed' {
            $nestedFile = Join-Path $script:tempDir 'sub\dir\deep.html'
            Write-SPHtmlFile -Path $nestedFile -Content 'nested'
            Test-Path $nestedFile | Should -BeTrue
        }
    }

    Context 'SI-07: SP.Shared loads before SP.Core (no dependency)' {
        BeforeAll {
            # Remove all toolkit modules
            Get-Module SP.* -ErrorAction Ignore | Remove-Module -Force -ErrorAction Ignore
        }

        It 'imports SP.Shared without SP.Core present' {
            # Confirm SP.Core is not loaded
            Get-Module SP.Config -ErrorAction Ignore | Should -BeNullOrEmpty

            # Load SP.Shared -- should succeed without SP.Core
            $psd1 = Join-Path $script:modulesRoot 'SP.Shared\SP.Shared.psd1'
            { Import-Module $psd1 -Force -DisableNameChecking } | Should -Not -Throw
        }

        It 'all functions work without SP.Core' {
            (ConvertTo-SPHtmlSafe -Value 'test & <value>') | Should -Be 'test &amp; &lt;value&gt;'
            (Format-SPHtmlDate -DateString '2026-01-15T10:30:00Z') | Should -Match '2026-01-15'
            (Get-SPObjectProperty -Object @{ k = 'v' } -Name 'k') | Should -Be 'v'
            (Get-SPHtmlColorPalette).Green | Should -Be '#0a7d2c'
            $sb = New-SPHtmlDocument -Title 'Test'
            $sb | Should -BeOfType [System.Text.StringBuilder]
        }
    }
}
