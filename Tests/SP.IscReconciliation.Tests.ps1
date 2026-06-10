<#
.SYNOPSIS
    Unit tests for SP.IscReconciliation -- the ISC-side operand for the AD <-> ISC <-> HR
    reconciliation contract (docs/AD-Reconciliation-Contract-from-GroupEnumerator.md).
    REC-01  join-key ladder (employeeID > mail > upn) + confidence
    REC-02  manager / cert-reviewer employeeID resolution
    REC-03  governed-entitlement aggregation, sorting + privileged rollup
    REC-04  ISC-side pre-staged findings (JOINKEY_MISSING, MAIL_NE_UPN)
    REC-05  summary counts + coverage% INDEPENDENT of the JoinKeyAttribute name
    REC-06  determinism: identical input -> identical contentHash + stable order
    REC-07  Save: UTF-8 no-BOM JSON + SHA-256 sidecar + CSV twin round-trip
    REC-08  provenance: SourceSystem / RecordCount / as-of != generated / contentHash
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Reconciliation

    # 6 identities exercising every join-key tier and manager-resolution outcome.
    $script:identities = @(
        [PSCustomObject]@{ IscIdentityId = 'isc-1';        EmployeeId = 'E100'; DisplayName = 'Alice'; Email = 'alice@corp.com'; Upn = 'alice@corp.com';      LifecycleState = 'active';   Active = $true;  ManagerIscIdentityId = 'isc-mgr' }
        [PSCustomObject]@{ IscIdentityId = 'isc-mgr';      EmployeeId = 'E001'; DisplayName = 'Mgr';   Email = 'mgr@corp.com';   Upn = 'mgr@corp.com';        LifecycleState = 'active';   Active = $true;  ManagerIscIdentityId = '' }
        [PSCustomObject]@{ IscIdentityId = 'isc-2';        EmployeeId = '';     DisplayName = 'Bob';   Email = 'bob@corp.com';   Upn = 'bob.smith@corp.com';  LifecycleState = 'active';   Active = $true;  ManagerIscIdentityId = 'isc-ghost' }   # manager not in population
        [PSCustomObject]@{ IscIdentityId = 'isc-3';        EmployeeId = '';     DisplayName = 'Carol'; Email = '';               Upn = 'carol@corp.com';      LifecycleState = 'inactive'; Active = $false; ManagerIscIdentityId = 'isc-mgr' }
        [PSCustomObject]@{ IscIdentityId = 'isc-4';        EmployeeId = '';     DisplayName = 'Dan';   Email = '';               Upn = '';                    LifecycleState = 'active';   Active = $true;  ManagerIscIdentityId = 'isc-nomgrkey' } # manager in pop but no join key
        [PSCustomObject]@{ IscIdentityId = 'isc-nomgrkey'; EmployeeId = '';     DisplayName = 'NoKeyMgr'; Email = 'nk@corp.com'; Upn = 'nk@corp.com';         LifecycleState = 'active';   Active = $true;  ManagerIscIdentityId = '' }
    )
    $script:grants = @(
        [PSCustomObject]@{ IscIdentityId = 'isc-1'; Name = 'Finance-Reader'; Source = 'AD';   Type = 'ENTITLEMENT'; Privileged = $false }
        [PSCustomObject]@{ IscIdentityId = 'isc-1'; Name = 'Domain Admins';  Source = 'AD';   Type = 'ENTITLEMENT'; Privileged = $true }
        [PSCustomObject]@{ IscIdentityId = 'isc-2'; Name = 'VPN';            Source = 'Okta'; Type = 'ENTITLEMENT'; Privileged = $false }
    )
    $script:prov = @{
        SnapshotAsOfUtc = '2026-06-09T12:00:00Z'
        GeneratedAtUtc  = '2026-06-10T08:30:00Z'
        ExtractMethod   = 'campaign-audit-decisions'
        ToolVersion     = '1.0.0'
        TenantUrl       = 'https://tenant.api.identitynow.com'
        Environment     = 'test'
        ConfigHash      = 'cfg-abc'
    }

    $script:model = Build-SPIscReconciliationModel -Identities $script:identities -AccessGrants $script:grants -Provenance $script:prov
    # Index by ISC id for convenient per-identity assertions.
    $script:byId = @{}
    foreach ($i in $script:model.Identities) { $script:byId[[string]$i.IscIdentityId] = $i }
}

Describe "REC-01: join-key ladder + confidence" {
    It "employeeID present -> source employeeID, confidence High" {
        $script:byId['isc-1'].JoinKeyResolved.Source     | Should -Be 'employeeID'
        $script:byId['isc-1'].JoinKeyResolved.Value      | Should -Be 'E100'
        $script:byId['isc-1'].JoinKeyResolved.Confidence | Should -Be 'High'
    }
    It "no employeeID, mail present -> source mail, confidence Low" {
        $script:byId['isc-2'].JoinKeyResolved.Source     | Should -Be 'mail'
        $script:byId['isc-2'].JoinKeyResolved.Confidence | Should -Be 'Low'
    }
    It "no employeeID/mail, upn present -> source upn, confidence Low" {
        $script:byId['isc-3'].JoinKeyResolved.Source     | Should -Be 'upn'
        $script:byId['isc-3'].JoinKeyResolved.Confidence | Should -Be 'Low'
    }
    It "nothing to join on -> source none, confidence None" {
        $script:byId['isc-4'].JoinKeyResolved.Source     | Should -Be 'none'
        $script:byId['isc-4'].JoinKeyResolved.Confidence | Should -Be 'None'
    }
}

Describe "REC-02: manager / cert-reviewer employeeID resolution" {
    It "manager in population WITH a join key -> resolved + employeeID carried" {
        $script:byId['isc-1'].Manager.EmployeeId | Should -Be 'E001'
        $script:byId['isc-1'].Manager.Resolved   | Should -Be $true
    }
    It "manager NOT in population -> unresolved" {
        $script:byId['isc-2'].Manager.Resolved   | Should -Be $false
        $script:byId['isc-2'].Manager.EmployeeId | Should -Be ''
    }
    It "manager in population but WITHOUT a join key -> unresolved (cannot route by employeeID)" {
        $script:byId['isc-4'].Manager.IscIdentityId | Should -Be 'isc-nomgrkey'
        $script:byId['isc-4'].Manager.Resolved      | Should -Be $false
    }
}

Describe "REC-03: governed entitlements + privileged rollup" {
    It "aggregates an identity's grants, sorted by source then name" {
        $ents = @($script:byId['isc-1'].GovernedEntitlements)
        $ents.Count | Should -Be 2
        $ents[0].Name | Should -Be 'Domain Admins'   # AD/Domain Admins sorts before AD/Finance-Reader
        $ents[1].Name | Should -Be 'Finance-Reader'
    }
    It "flags the identity privileged when any grant is privileged" {
        $script:byId['isc-1'].Privileged | Should -Be $true
        $script:byId['isc-2'].Privileged | Should -Be $false
    }
    It "rolls up governed + privileged grant counts in the summary" {
        $script:model.Summary.GovernedEntitlementCount | Should -Be 3
        $script:model.Summary.PrivilegedGrantCount     | Should -Be 1
    }
}

Describe "REC-04: ISC-side pre-staged findings" {
    It "stages JOINKEY_MISSING for every identity lacking the join key" {
        $script:model.Summary.FindingCounts.JOINKEY_MISSING | Should -Be 4
        @($script:byId['isc-2'].Findings | Where-Object { $_.Code -eq 'JOINKEY_MISSING' }).Count | Should -Be 1
    }
    It "stages MAIL_NE_UPN only when mail and upn both present and differ" {
        $script:model.Summary.FindingCounts.MAIL_NE_UPN | Should -Be 1
        @($script:byId['isc-2'].Findings | Where-Object { $_.Code -eq 'MAIL_NE_UPN' }).Count | Should -Be 1
        @($script:byId['isc-1'].Findings | Where-Object { $_.Code -eq 'MAIL_NE_UPN' }).Count | Should -Be 0
    }
    It "does NOT invent merge-time finding codes (only the two ISC-determinable codes appear)" {
        $codes = @($script:model.Identities | ForEach-Object { $_.Findings } | ForEach-Object { [string]$_.Code } | Sort-Object -Unique)
        $codes | Should -Be @('JOINKEY_MISSING', 'MAIL_NE_UPN')
    }
}

Describe "REC-05: summary + coverage independent of JoinKeyAttribute" {
    It "counts identities, active, manager-resolved and join coverage" {
        $script:model.Summary.IdentityCount          | Should -Be 6
        $script:model.Summary.ActiveCount            | Should -Be 5
        $script:model.Summary.JoinKeyResolvedCount   | Should -Be 2
        $script:model.Summary.ManagerResolvedCount   | Should -Be 2
        $script:model.Summary.LowConfidenceJoinCount | Should -Be 3
        $script:model.Summary.JoinKeyCoveragePct     | Should -Be ([math]::Round(2 * 100.0 / 6, 1))
    }
    It "coverage% is identical for a custom JoinKeyAttribute (regression: AD side collapsed to 0)" {
        $num = Build-SPIscReconciliationModel -Identities $script:identities -AccessGrants $script:grants -Provenance $script:prov -JoinKeyAttribute 'employeeNumber'
        $ext = Build-SPIscReconciliationModel -Identities $script:identities -AccessGrants $script:grants -Provenance $script:prov -JoinKeyAttribute 'extensionAttribute7'
        $num.Summary.JoinKeyCoveragePct | Should -Be $script:model.Summary.JoinKeyCoveragePct
        $ext.Summary.JoinKeyCoveragePct | Should -Be $script:model.Summary.JoinKeyCoveragePct
        $ext.Generated.JoinKeyAttribute | Should -Be 'extensionAttribute7'
    }
}

Describe "REC-06: determinism + stable ordering" {
    It "identical input + injected timestamps -> identical contentHash" {
        $a = Build-SPIscReconciliationModel -Identities $script:identities -AccessGrants $script:grants -Provenance $script:prov
        $b = Build-SPIscReconciliationModel -Identities $script:identities -AccessGrants $script:grants -Provenance $script:prov
        $a.Generated.ContentHash | Should -Be $b.Generated.ContentHash
        $a.Generated.ContentHash | Should -Match '^[0-9a-f]{64}$'
    }
    It "orders identities with a join key first, missing-key rows last" {
        $script:model.Identities[0].EmployeeId | Should -Be 'E001'   # E001 < E100
        $script:model.Identities[1].EmployeeId | Should -Be 'E100'
        $script:model.Identities[-1].EmployeeId | Should -Be ''       # missing-key rows sort last
    }
}

Describe "REC-07: Save -> JSON (no-BOM) + sha256 sidecar + CSV twin" {
    BeforeAll {
        $script:outDir = Join-Path $TestDrive 'recon'
        $script:saved  = Save-SPIscReconciliationExport -Model $script:model -OutputDir $script:outDir
    }
    It "writes a stamped JSON file named from SnapshotAsOfUtc" {
        $script:saved.Success | Should -Be $true
        (Split-Path $script:saved.Data -Leaf) | Should -Be 'isc-recon-2026-06-09T120000.json'
        Test-Path $script:saved.Data | Should -Be $true
    }
    It "writes the JSON without a UTF-8 BOM" {
        $bytes = [System.IO.File]::ReadAllBytes($script:saved.Data)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
    }
    It "writes a SHA-256 sidecar matching the file bytes" {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($script:saved.Data)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $h | Should -Be $script:saved.Sha256
        (Get-Content "$($script:saved.Data).sha256" -Raw) | Should -BeLike "$h*"
    }
    It "writes a CSV twin with one row per identity" {
        Test-Path $script:saved.Csv | Should -Be $true
        @(Get-Content $script:saved.Csv).Count | Should -Be 7   # header + 6 identities
    }
    It "round-trips: reloaded JSON carries schemaVersion 1.0.0 and all identities" {
        $reload = Get-Content $script:saved.Data -Raw | ConvertFrom-Json
        $reload.SchemaVersion          | Should -Be '1.0.0'
        $reload.Generated.SourceSystem | Should -Be 'SailPointISC'
        @($reload.Identities).Count    | Should -Be 6
    }
}

Describe "REC-08: provenance contract fields" {
    It "stamps SourceSystem=SailPointISC and RecordCount" {
        $script:model.Generated.SourceSystem | Should -Be 'SailPointISC'
        $script:model.Generated.RecordCount  | Should -Be 6
    }
    It "keeps snapshotAsOfUtc distinct from generatedAtUtc (contract requirement)" {
        $script:model.Generated.SnapshotAsOfUtc | Should -Be '2026-06-09T12:00:00Z'
        $script:model.Generated.GeneratedAtUtc  | Should -Be '2026-06-10T08:30:00Z'
        $script:model.Generated.SnapshotAsOfUtc | Should -Not -Be $script:model.Generated.GeneratedAtUtc
    }
    It "embeds a 64-hex SHA-256 contentHash" {
        $script:model.Generated.ContentHash | Should -Match '^[0-9a-f]{64}$'
    }
}
