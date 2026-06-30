<#
.SYNOPSIS
    Source-assertion tests for the CACHE-COUNT-LABEL fix.

    The header status-line cache-provenance note previously counted CAMPAIGNS but
    labelled them ITEMS ("Items: 1 of 1 from cache" even with 8 items). The fix adds
    an item-from-cache accumulator ($itemsFromCacheCount) and relabels the note so the
    item count is honest while keeping the campaign measure as a correctly-labelled
    parenthetical. These tests assert the corrected source directly (no mock/API/shell
    out) -- mirroring the DV6-06 source-grep idiom.

    CCL-01: V4b parses, has the accumulator + item-accurate cacheNote, no buggy substring
    CCL-02: V4  parses, has the accumulator + item-accurate cacheNote, no buggy substring
#>
BeforeAll {
    $script:ToolkitRoot = Split-Path $PSScriptRoot -Parent
    $script:V4bPath = Join-Path $script:ToolkitRoot (Join-Path 'Scripts' 'Invoke-SPDailyEvidenceReportV4b.ps1')
    $script:V4Path = Join-Path $script:ToolkitRoot (Join-Path 'Scripts' 'Invoke-SPDailyEvidenceReportV4.ps1')
}

Describe "CCL-01: V4b cache-count label is item-accurate" {
    BeforeAll {
        $script:V4bSrc = Get-Content $script:V4bPath -Raw
    }

    It "parses with 0 errors" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:V4bPath, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It "initialises the item-from-cache accumulator" {
        $script:V4bSrc | Should -Match '\$itemsFromCacheCount\s*=\s*0'
    }

    It "increments the accumulator guarded by ItemsFromCache" {
        $script:V4bSrc | Should -Match "ItemsFromCache'\]\s*-eq\s*\`$true"
        $script:V4bSrc | Should -Match '\$itemsFromCacheCount\s*\+='
    }

    It "cacheNote numerator references the item count and aggregate total" {
        $script:V4bSrc | Should -Match '\$itemsFromCacheCount of \$aggTotal from cache'
    }

    It "no longer uses the buggy campaign-as-items numerator" {
        $script:V4bSrc | Should -Not -Match '\$\(\$cachedCampaigns\.Count\) of \$\(\$campaignAudits\.Count\) from cache'
    }
}

Describe "CCL-02: V4 cache-count label is item-accurate" {
    BeforeAll {
        $script:V4Src = Get-Content $script:V4Path -Raw
    }

    It "parses with 0 errors" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:V4Path, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It "initialises the item-from-cache accumulator" {
        $script:V4Src | Should -Match '\$itemsFromCacheCount\s*=\s*0'
    }

    It "increments the accumulator guarded by ItemsFromCache" {
        $script:V4Src | Should -Match "ItemsFromCache'\]\s*-eq\s*\`$true"
        $script:V4Src | Should -Match '\$itemsFromCacheCount\s*\+='
    }

    It "cacheNote numerator references the item count and aggregate total" {
        $script:V4Src | Should -Match '\$itemsFromCacheCount of \$aggTotal from cache'
    }

    It "no longer uses the buggy campaign-as-items numerator" {
        $script:V4Src | Should -Not -Match '\$\(\$cachedCampaigns\.Count\) of \$\(\$campaignAudits\.Count\) from cache'
    }
}
