<#
.SYNOPSIS
    Unit tests for Test-SPCampaignSnapshotIntegrity -- the HTML-free snapshot / items-cache
    data validator.
    CV-01: a clean snapshot round-trips to OK with no error findings
    CV-02: blank fields / invalid decision / blank key are flagged (Ok = false)
    CV-03: decided-with-no-date and KPI/count mismatches are flagged
    CV-04: an empty capture (0 items) is an error
    CV-05: items cache without a .meta.json is a PARTIAL (warn, not error)
    CV-06: a directory resolves to its newest snapshot
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("cv-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:dir -Force | Out-Null

    # ---- a clean snapshot, written via the real Save path ----
    $camp = [PSCustomObject]@{ id = 'cv-good'; name = 'Clean Campaign'; status = 'ACTIVE'; created = '2026-06-11T00:00:00Z' }
    $dec = @{ Approved = @(
            [PSCustomObject]@{ CertificationId = 'c1'; IdentityId = 'i1'; IdentityName = 'Alice'; AccessName = 'admin_xyz'; AccessId = 'ent-1'; AccessType = 'ENTITLEMENT'; SourceName = 'Corporate AD'; SourceId = 'src-ad'; Decision = 'APPROVE'; DecisionDate = '2026-06-11T09:00:00Z' }
        ); Revoked = @(
            [PSCustomObject]@{ CertificationId = 'c1'; IdentityId = 'i2'; IdentityName = 'Bob'; AccessName = 'legacy_app'; AccessId = 'ent-2'; AccessType = 'ENTITLEMENT'; SourceName = 'Corporate AD'; SourceId = 'src-ad'; Decision = 'REVOKE'; DecisionDate = '2026-06-11T09:05:00Z' }
        ); Pending = @() }
    $goodSnap = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions $dec
    $saved = Save-SPCampaignSnapshot -Snapshot $goodSnap -SnapshotDir $script:dir
    $script:goodPath = $saved.Data

    # ---- a hand-crafted BAD snapshot (blank key/id, invalid decision, KPI mismatch, no date) ----
    $script:badPath = Join-Path $script:dir 'bad-snapshot.json'
    $bad = [ordered]@{
        Meta  = [ordered]@{ SchemaVersion = 2; CampaignId = 'cv-bad'; CampaignName = 'Bad Run'; Status = 'ACTIVE'; CapturedAt = '2026-06-11T08:00:00Z'; ItemCount = 2 }
        Items = @(
            [ordered]@{ Key = 'i1|admin|AD'; IdentityId = 'i1'; AccessName = 'admin'; AccessId = 'e1'; SourceName = 'AD'; SourceId = 's1'; Decision = 'APPROVE'; DecisionDate = '' }
            [ordered]@{ Key = ''; IdentityId = ''; AccessName = ''; AccessId = ''; SourceName = ''; SourceId = ''; Decision = 'WEIRD'; DecisionDate = '' }
        )
        Kpi   = [ordered]@{ Total = 5; Approved = 1; Revoked = 0; Pending = 0 }
    }
    $bad | ConvertTo-Json -Depth 6 | Set-Content -Path $script:badPath -Encoding UTF8

    # ---- an empty capture ----
    $script:emptyPath = Join-Path $script:dir 'empty-snapshot.json'
    ([ordered]@{ Meta = [ordered]@{ CampaignId = 'cv-empty'; CampaignName = 'Empty'; Status = 'ACTIVE'; CapturedAt = '2026-06-11T08:00:00Z'; ItemCount = 0 }; Items = @(); Kpi = [ordered]@{ Total = 0; Approved = 0; Revoked = 0; Pending = 0 } } | ConvertTo-Json -Depth 6) | Set-Content -Path $script:emptyPath -Encoding UTF8

    # ---- a PARTIAL items cache (jsonl present, NO meta) ----
    $script:partialPath = Join-Path $script:dir 'items-cv-part.jsonl'
    $line = [PSCustomObject]@{ Item = [PSCustomObject]@{ id = 'x1' }; CertificationId = 'c'; CertificationName = 'C'; CampaignName = 'Camp' } | ConvertTo-Json -Depth 8 -Compress
    Set-Content -Path $script:partialPath -Value $line -Encoding UTF8
}

AfterAll {
    if ($script:dir -and (Test-Path $script:dir)) { Remove-Item -Recurse -Force $script:dir -ErrorAction SilentlyContinue }
}

Describe "CV-01: clean snapshot validates OK" {
    It "returns Ok with no error findings" {
        $r = Test-SPCampaignSnapshotIntegrity -Path $script:goodPath
        $r.Success | Should -Be $true
        $r.Data.Kind | Should -Be 'Snapshot'
        $r.Data.Ok | Should -Be $true
        @($r.Data.Findings | Where-Object { $_.Severity -eq 'Error' }).Count | Should -Be 0
    }
}

Describe "CV-02/03: bad snapshot is flagged" {
    BeforeAll { $script:rb = Test-SPCampaignSnapshotIntegrity -Path $script:badPath }
    It "is not Ok" { $script:rb.Data.Ok | Should -Be $false }
    It "flags the invalid decision and blank key as errors" {
        $codes = @($script:rb.Data.Findings | Where-Object { $_.Severity -eq 'Error' } | ForEach-Object { $_.Code })
        $codes | Should -Contain 'DECISION_INVALID'
        $codes | Should -Contain 'BLANK_KEY'
        $codes | Should -Contain 'BLANK_IDENTITYID'
    }
    It "warns on decided-with-no-date and KPI mismatch" {
        $codes = @($script:rb.Data.Findings | ForEach-Object { $_.Code })
        $codes | Should -Contain 'DECIDED_NO_DATE'
        $codes | Should -Contain 'KPI_TOTAL'
    }
}

Describe "CV-04: empty capture is an error" {
    It "flags EMPTY and is not Ok" {
        $r = Test-SPCampaignSnapshotIntegrity -Path $script:emptyPath
        $r.Data.Ok | Should -Be $false
        @($r.Data.Findings | ForEach-Object { $_.Code }) | Should -Contain 'EMPTY'
    }
}

Describe "CV-05: items cache without meta is a partial (warn, not error)" {
    It "detects the partial fetch and stays Ok" {
        $r = Test-SPCampaignSnapshotIntegrity -Path $script:partialPath
        $r.Data.Kind | Should -Be 'ItemsCache'
        $r.Data.Ok | Should -Be $true
        @($r.Data.Findings | ForEach-Object { $_.Code }) | Should -Contain 'CACHE_PARTIAL'
    }
}

Describe "CV-06: directory resolves to newest snapshot" {
    It "validates a snapshot when handed the directory" {
        $r = Test-SPCampaignSnapshotIntegrity -Path $script:dir
        $r.Success | Should -Be $true
        $r.Data.Kind | Should -Be 'Snapshot'
    }
}
