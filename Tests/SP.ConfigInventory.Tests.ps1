#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Integration tests for Invoke-SPConfigInventory.ps1 against the committed node mock
    ISC API (Tests/Tools/mock-isc-inventory.js).

.DESCRIPTION
    CI-01: script parses cleanly
    CI-02: -PermissionCheck matrix classifies 200 / 403 / 404 and writes the JSON matrix
    CI-03: full run pages an oversized collection completely (600 roles over 3 pages)
    CI-04: entitlement sampling respects -EntitlementSampleSize exactly (100, not a page)
    CI-05: denied (403) and absent (404) sections are recorded, run still succeeds
    CI-06: HTML document renders with permission matrix + KPI tiles; JSON meta carries
           the identity count from the X-Total-Count search header

    The whole file SKIPS when node is unavailable (the mock is a node HTTP server).
    Port 8767 is used to avoid colliding with anything on 8765/8766.
#>

$script:ciNode = $null
try { $script:ciNode = (Get-Command node -ErrorAction Ignore).Source } catch { }
$script:ciSkip = [string]::IsNullOrWhiteSpace($script:ciNode)

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPConfigInventory.ps1'
    $script:MockJs     = Join-Path $PSScriptRoot 'Tools\mock-isc-inventory.js'
    $script:OutDir     = Join-Path $TestDrive 'inv-out'
    New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null

    # Re-resolve node HERE: the top-of-file assignment runs during Pester DISCOVERY,
    # whose variables are not visible in the run phase -- BeforeAll saw $null and
    # Start-Process threw, failing the whole container.
    $script:ciNode = $null
    try { $script:ciNode = (Get-Command node -ErrorAction Ignore).Source } catch { }
    $script:ciSkip = [string]::IsNullOrWhiteSpace($script:ciNode)

    if (-not $script:ciSkip) {
        # Kill any stray mock left by an aborted earlier run (port 8767 must be free,
        # or this run silently talks to a stale server).
        try {
            $stray = @(Get-Process node -ErrorAction Ignore | Where-Object {
                try { ($_.CommandLine -match 'mock-isc-8767') } catch { $false } })
            foreach ($p in $stray) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        } catch { }
        # The committed mock binds 8765; rewrite to 8767 for test isolation.
        $js = Get-Content $script:MockJs -Raw
        $script:MockCopy = Join-Path $TestDrive 'mock-isc-8767.js'
        Set-Content -Path $script:MockCopy -Value ($js -replace '8765', '8767') -Encoding UTF8
        # No -WindowStyle: it is Windows-only and THROWS on Linux/macOS Start-Process.
        $script:MockProc = Start-Process -FilePath $script:ciNode -ArgumentList $script:MockCopy -PassThru
        # Wait for the listener instead of a blind sleep (up to ~5s).
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            try {
                $c = [System.Net.Sockets.TcpClient]::new()
                $c.Connect('127.0.0.1', 8767); $c.Close(); break
            } catch { Start-Sleep -Milliseconds 250 }
        }
    }
}

AfterAll {
    if ($null -ne $script:MockProc -and -not $script:MockProc.HasExited) {
        Stop-Process -Id $script:MockProc.Id -Force -ErrorAction SilentlyContinue
    }
}

Describe 'CI-01: Invoke-SPConfigInventory parses cleanly' {
    It 'has no parser errors' {
        $t = $null; $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$t, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
}

Describe 'CI-02: -PermissionCheck classifies endpoint access' {
    BeforeAll {
        # *>&1: the script narrates via Write-Host (information stream); 2>&1 alone
        # captures nothing and the console assertions see an empty string.
        $script:pcOut = & $script:ScriptPath -BaseUrl 'http://127.0.0.1:8767' -Token 'mock' `
            -PermissionCheck -OutputPath $script:OutDir *>&1 | Out-String
        $mx = Get-ChildItem $script:OutDir -Filter 'Config-Inventory-PermissionCheck-*.json' | Select-Object -First 1
        $script:matrix = if ($mx) { Get-Content $mx.FullName -Raw | ConvertFrom-Json } else { $null }
    }

    It 'writes the matrix JSON' -Skip:$script:ciSkip {
        $script:matrix | Should -Not -BeNullOrEmpty
    }
    It 'classifies readable endpoints as 200' -Skip:$script:ciSkip {
        @($script:matrix | Where-Object { $_.Section -eq 'Sources' })[0].HttpStatus | Should -Be 200
    }
    It 'classifies the denied endpoint as 403 with its required level' -Skip:$script:ciSkip {
        $sod = @($script:matrix | Where-Object { $_.Section -eq 'SoD Policies' })[0]
        $sod.HttpStatus | Should -Be 403
        $sod.RequiredLevel | Should -Match 'SOD_ADMIN'
    }
    It 'classifies absent endpoints as 404' -Skip:$script:ciSkip {
        @($script:matrix | Where-Object { $_.Section -eq 'Workflows' })[0].HttpStatus | Should -Be 404
    }
    It 'names the denied section in the console summary' -Skip:$script:ciSkip {
        $script:pcOut | Should -Match 'SoD Policies: needs'
    }
}

Describe 'CI-03/04/05/06: full inventory run' {
    BeforeAll {
        $script:fullOut = & $script:ScriptPath -BaseUrl 'http://127.0.0.1:8767' -Token 'mock' `
            -OutputPath $script:OutDir -OutputMode All *>&1 | Out-String
        $jf = Get-ChildItem $script:OutDir -Filter 'Config-Inventory-2*.json' | Sort-Object Name | Select-Object -Last 1
        $script:json = if ($jf) { Get-Content $jf.FullName -Raw | ConvertFrom-Json } else { $null }
        $hf = Get-ChildItem $script:OutDir -Filter 'Config-Inventory-2*.html' | Sort-Object Name | Select-Object -Last 1
        $script:html = if ($hf) { Get-Content $hf.FullName -Raw } else { '' }
    }

    It 'CI-03 pages the 600-role collection completely (3 pages), untruncated' -Skip:$script:ciSkip {
        $script:json.Sections.roles.Count | Should -Be 600
        $script:json.Sections.roles.Truncated | Should -BeFalse
        @($script:json.Sections.roles.Items | Where-Object { $_.name -eq 'Role-599' }).Count | Should -Be 1
    }
    It 'CI-04 samples entitlements at exactly the sample size' -Skip:$script:ciSkip {
        $script:json.Sections.entitlements.Count | Should -Be 100
        $script:json.Sections.entitlements.Truncated | Should -BeTrue
    }
    It 'CI-05 records 403/404 sections without failing the run' -Skip:$script:ciSkip {
        $script:json.Sections.sodPolicies.HttpStatus | Should -Be 403
        $script:json.Sections.workflows.HttpStatus | Should -Be 404
        $script:json.Sections.sources.Count | Should -Be 3
    }
    It 'CI-06 renders HTML with permission matrix and KPI tiles' -Skip:$script:ciSkip {
        $script:html | Should -Match 'Permission Matrix'
        $script:html | Should -Match "class='kpi'"
    }
    It 'CI-06 JSON meta carries the identity count from X-Total-Count' -Skip:$script:ciSkip {
        $script:json.Meta.IdentityCount | Should -Be 1234
    }
    It 'CI-07 governance findings detect the seeded posture problems' -Skip:$script:ciSkip {
        $f = @($script:json.Findings)
        $f.Count | Should -BeGreaterThan 0
        @($f | Where-Object { $_.Finding -match 'unhealthy' -and $_.Object -eq 'Source-2' }).Count | Should -Be 1
        @($f | Where-Object { $_.Finding -match 'no owner' -and $_.Object -eq 'Source-2' }).Count | Should -Be 1
        @($f | Where-Object { $_.Finding -match 'past its deadline' }).Count | Should -Be 1
        @($f | Where-Object { $_.Finding -match 'Privileged entitlement is requestable' }).Count | Should -BeGreaterThan 0
        $script:html | Should -Match 'Governance Posture Findings'
    }
}

Describe 'CI-08: CSV export' {
    It 'writes per-section CSVs plus findings when -IncludeCsv is set' -Skip:$script:ciSkip {
        $csvDir = Join-Path $TestDrive 'inv-csv'
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
        & $script:ScriptPath -BaseUrl 'http://127.0.0.1:8767' -Token 'mock' `
            -OutputPath $csvDir -OutputMode JSON -IncludeCsv *>&1 | Out-Null
        $csvs = @(Get-ChildItem $csvDir -Filter 'Config-Inventory-*-*.csv')
        $csvs.Count | Should -BeGreaterThan 5
        $roles = @(Get-ChildItem $csvDir -Filter '*-roles.csv')[0]
        @(Import-Csv $roles.FullName).Count | Should -Be 600
        @(Get-ChildItem $csvDir -Filter '*-findings.csv').Count | Should -Be 1
    }
}
