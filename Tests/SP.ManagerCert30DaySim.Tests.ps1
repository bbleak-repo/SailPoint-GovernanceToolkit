#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x VALIDATION suite for the 30-day manager-certification simulation (T-05).
.DESCRIPTION
    Headlessly asserts the governance truth of the 30-day manager-cert exercise against a
    FROZEN snapshot of the mock dataset (Tests/TestData/ManagerCert30DaySim.State.json,
    seed 20260606). NO live mock server is required; the suite is fully deterministic.

    Two layers (mirrors the architecture in round-05-t-05-spec.md):
      Layer A -- pure DATA-TRUTH assertions on the frozen fixture (removal detection,
                 7d-vs-30d deltas, privileged-role reports, manager accountability).
      Layer B -- REAL toolkit functions with mocked transport (org/leadership rollup,
                 SMTP-WhatIf = Logged / no real send, campaign write round-trip).

    Test areas (all 7 present):
      MC-01  Manager cert ORG + MANAGER reports correct (Build-SPOrgTree /
             Resolve-SPIdentityBand / Group-SPAuditByLeadership), grounded in REAL
             fixture identity chain id-gen-011 -> id-gen-006 -> id-gen-003 -> id-gen-001.
      MC-02  SMTP-WhatIf logs (Action='Logged'), NO real send (Send-MailMessage 0 calls).
      MC-03  REMOVED users detected/shown in BOTH 7d and 30d (changelog window + the
             Get-SPDeltaRevokeEvents toolkit path).
      MC-04  Campaign WRITE path round-trips: 10 MANAGER campaigns (one per tracked
             privileged role) submit + activate + are found by Search/Get.
      MC-05  7-day vs 30-day views show expected deltas/trends (strict subset + real delta).
      MC-06  Privileged-role reports: 10 fixed roles, current members, day-over-day churn.
      MC-07  Manager accountability: per-day status + monotone rollup across 7d/30d windows.

    Pester-5 scoping: the fixture is loaded and the named expected facts computed at
    DISCOVERY time (top-level BeforeDiscovery -> $script: vars) so -ForEach data is
    available; the same fixture is re-loaded in BeforeAll for run-time use.

    Window anchor: a FIXED anchor derived from the fixture (the newest daily-campaign
    'created' = 2026-06-05T12:16:28Z), NOT Get-Date, so the static fixture never drifts.
    The window comparison replicates the mock changelog handler's
    [datetime]$_.date >= bound semantics (MembershipChangelogHandlers.ps1).

    Mirrors: SP.LeadershipAttribution.Tests.ps1 (org tree + band + leadership rollup),
             SP.DeltaCert.Tests.ps1 (REVOKE activity mock -> Get-SPDeltaRevokeEvents),
             SP.Campaigns.Tests.ps1 (New/Start/Get/Search-SPCampaign mock + return shape).

    PS 5.1 ONLY: 2-arg Join-Path, .Contains() on dictionaries, no ternary/??/?.
#>

# ---------------------------------------------------------------------------
#region Shared fixture loader (used at BOTH discovery and run time)
# ---------------------------------------------------------------------------
function Get-MC30FixturePath {
    return (Join-Path $PSScriptRoot (Join-Path 'TestData' 'ManagerCert30DaySim.State.json'))
}

function Import-MC30Fixture {
    # Loads the frozen State JSON and projects the governance facts the suite asserts.
    $path = Get-MC30FixturePath
    if (-not (Test-Path $path)) {
        throw "MC30 fixture not found at '$path' -- copy State/SailPointData.json into Tests/TestData."
    }
    $json = Get-Content -Path $path -Raw | ConvertFrom-Json

    $changelog = @($json.membershipChangelog)
    $campaigns = @($json.campaigns)
    $daily     = @($campaigns | Where-Object { $_.id -like 'camp-daily-priv-*' })

    # FIXED anchor: newest daily-campaign 'created' (the spec's 2026-06-05T12:16:28Z).
    # Falls back to newest changelog date only if no daily campaigns exist.
    $anchor = $null
    if ($daily.Count -gt 0) {
        $anchor = ($daily | ForEach-Object { [datetime]$_.created } | Sort-Object | Select-Object -Last 1)
    }
    else {
        $anchor = ($changelog | ForEach-Object { [datetime]$_.date } | Sort-Object | Select-Object -Last 1)
    }

    return [PSCustomObject]@{
        Json          = $json
        Identities    = @($json.identities)
        Entitlements  = @($json.entitlements)
        TrackedRoles  = @($json.trackedPrivilegedRoles)
        Changelog     = $changelog
        Campaigns     = $campaigns
        DailyCamps    = $daily
        Anchor        = $anchor
        Bound7        = $anchor.AddDays(-7)
        Bound30       = $anchor.AddDays(-30)
    }
}

# Replicates the mock changelog handler from-date semantics: [datetime]$_.date >= bound.
function Select-MC30ChangelogInWindow {
    param(
        [object[]]$Changelog,
        [datetime]$Bound,
        [string]$Operation,
        [string[]]$GroupIds
    )
    $out = @()
    foreach ($row in $Changelog) {
        if ($Operation -and $row.operation -ne $Operation) { continue }
        if ($GroupIds -and ($GroupIds -notcontains $row.groupId)) { continue }
        $d = $null
        try { $d = [datetime]$row.date } catch { continue }
        if ($d -ge $Bound) { $out += $row }
    }
    return @($out)
}
#endregion

# ---------------------------------------------------------------------------
#region DISCOVERY-time facts (so -ForEach / named anchors exist at discovery)
# ---------------------------------------------------------------------------
# The helper functions above are defined in this file's top-level scope, which Pester
# dot-sources during discovery, so they are available here at DISCOVERY time.
$script:DiscFx = Import-MC30Fixture

# The 10 tracked privileged role ids (drives -ForEach in MC-06).
$script:DiscTrackedRoleIds = @($script:DiscFx.TrackedRoles | ForEach-Object { $_.id })

# Per-tracked-role test cases for MC-06 (privileged flag + member-list-present).
$script:DiscTrackedRoleCases = @()
foreach ($tr in $script:DiscFx.TrackedRoles) {
    $script:DiscTrackedRoleCases += @{ RoleId = $tr.id; RoleName = $tr.name; ManagerId = $tr.responsibleManagerId }
}
# ---------------------------------------------------------------------------
#endregion

# ---------------------------------------------------------------------------
#region RUN-time setup
# ---------------------------------------------------------------------------
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # The top-of-file helper functions are visible at DISCOVERY time but NOT inside this
    # run-time BeforeAll scope under Pester 5, so re-define the fixture loaders here.
    function Get-MC30FixturePath {
        return (Join-Path $PSScriptRoot (Join-Path 'TestData' 'ManagerCert30DaySim.State.json'))
    }
    function Import-MC30Fixture {
        $path = Get-MC30FixturePath
        if (-not (Test-Path $path)) {
            throw "MC30 fixture not found at '$path' -- copy State/SailPointData.json into Tests/TestData."
        }
        $json = Get-Content -Path $path -Raw | ConvertFrom-Json
        $changelog = @($json.membershipChangelog)
        $campaigns = @($json.campaigns)
        $daily     = @($campaigns | Where-Object { $_.id -like 'camp-daily-priv-*' })
        $anchor = $null
        if ($daily.Count -gt 0) {
            $anchor = ($daily | ForEach-Object { [datetime]$_.created } | Sort-Object | Select-Object -Last 1)
        }
        else {
            $anchor = ($changelog | ForEach-Object { [datetime]$_.date } | Sort-Object | Select-Object -Last 1)
        }
        return [PSCustomObject]@{
            Json         = $json
            Identities   = @($json.identities)
            Entitlements = @($json.entitlements)
            TrackedRoles = @($json.trackedPrivilegedRoles)
            Changelog    = $changelog
            Campaigns    = $campaigns
            DailyCamps   = $daily
            Anchor       = $anchor
            Bound7       = $anchor.AddDays(-7)
            Bound30      = $anchor.AddDays(-30)
        }
    }

    $script:Fx       = Import-MC30Fixture
    $script:Anchor   = $script:Fx.Anchor
    $script:Bound7   = $script:Fx.Bound7
    $script:Bound30  = $script:Fx.Bound30
    $script:Tracked  = $script:Fx.TrackedRoles
    $script:TrackedIds = @($script:Tracked | ForEach-Object { $_.id })
    $script:Changelog = $script:Fx.Changelog
    $script:Daily     = $script:Fx.DailyCamps

    # ---- Fail-fast: confirm the named seed anchors still exist in the frozen
    #      fixture; if the seed changed, this surfaces a clear message early. ----
    $script:Removal7d = @($script:Changelog | Where-Object {
        $_.operation -eq 'REMOVE' -and $_.identityId -eq 'id-gen-043' -and $_.groupId -eq 'ent-009'
    })
    if ($script:Removal7d.Count -eq 0) {
        throw "Seed drift: expected REMOVE id-gen-043 from ent-009 not found in fixture."
    }
    $script:RemovalPriv = @($script:Changelog | Where-Object {
        $_.operation -eq 'REMOVE' -and $_.identityId -eq 'id-gen-006' -and $_.groupId -eq 'ent-003'
    })
    if ($script:RemovalPriv.Count -eq 0) {
        throw "Seed drift: expected REMOVE id-gen-006 from ent-003 not found in fixture."
    }

    # ---- Window-filter helpers re-defined for run scope ----
    function Select-MC30ChangelogInWindow {
        param([object[]]$Changelog,[datetime]$Bound,[string]$Operation,[string[]]$GroupIds)
        $out = @()
        foreach ($row in $Changelog) {
            if ($Operation -and $row.operation -ne $Operation) { continue }
            if ($GroupIds -and ($GroupIds -notcontains $row.groupId)) { continue }
            $d = $null
            try { $d = [datetime]$row.date } catch { continue }
            if ($d -ge $Bound) { $out += $row }
        }
        return @($out)
    }

    # ---- Manager-accountability rollup (counts per status for a manager in a window) ----
    function Get-MC30AccountabilityRollup {
        param([object[]]$DailyCamps,[datetime]$Bound,[string]$ManagerId)
        $att = 0; $ov = 0; $mi = 0; $n = 0
        foreach ($c in $DailyCamps) {
            $cd = $null
            try { $cd = [datetime]$c.created } catch { continue }
            if ($cd -lt $Bound) { continue }
            $a = $c.managerAttestation | Where-Object { $_.managerId -eq $ManagerId } | Select-Object -First 1
            if ($null -eq $a) { continue }
            $n++
            switch ($a.status) {
                'attested' { $att++ }
                'overdue'  { $ov++ }
                'missed'   { $mi++ }
            }
        }
        return [PSCustomObject]@{ Total = $n; Attested = $att; Overdue = $ov; Missed = $mi }
    }

    # ---- Mock-identity-detail helper (mirrors SP.LeadershipAttribution.Tests.ps1) ----
    function New-MockIdentityDetail {
        param([string]$IdentityId,[string]$DisplayName,[string]$ManagerId = '',[string]$ManagerName = '',[bool]$Found = $true)
        return @{
            IdentityId          = $IdentityId
            DisplayName         = $DisplayName
            ManagerId           = $ManagerId
            ManagerName         = $ManagerName
            IsActive            = $true
            Found               = $Found
            CloudLifecycleState = 'active'
        }
    }
}
#endregion

# ===========================================================================
#region MC-01 (Layer B) -- Manager cert ORG + MANAGER reports correct
# ===========================================================================
Describe "MC-01: Manager cert ORG + MANAGER reports attribute the real fixture chain to correct bands and leaders" {

    Context "When the org tree is built from the REAL fixture chain id-gen-011 -> id-gen-006 -> id-gen-003 -> id-gen-001" {
        BeforeAll {
            Mock Write-SPLog -ModuleName SP.DeltaCertQueries { }

            # Real 4-rung manager chain present in the 30-day fixture:
            #   id-gen-011 (IC) -> id-gen-006 (mgr) -> id-gen-003 (dir) -> id-gen-001 (top, no mgr)
            $script:mc01Details = @{
                'id-gen-011' = New-MockIdentityDetail -IdentityId 'id-gen-011' -DisplayName 'William Brown'    -ManagerId 'id-gen-006' -ManagerName 'Jennifer Garcia'
                'id-gen-006' = New-MockIdentityDetail -IdentityId 'id-gen-006' -DisplayName 'Jennifer Garcia'  -ManagerId 'id-gen-003' -ManagerName 'Robert Williams'
                'id-gen-003' = New-MockIdentityDetail -IdentityId 'id-gen-003' -DisplayName 'Robert Williams'  -ManagerId 'id-gen-001' -ManagerName 'James Smith'
                'id-gen-001' = New-MockIdentityDetail -IdentityId 'id-gen-001' -DisplayName 'James Smith'      -ManagerId ''            -ManagerName ''
            }
            Mock Get-SPDeltaIdentityDetail -ModuleName SP.DeltaCertQueries {
                param($IdentityId)
                if ($script:mc01Details.ContainsKey($IdentityId)) { return $script:mc01Details[$IdentityId] }
                return New-MockIdentityDetail -IdentityId $IdentityId -DisplayName 'Unknown' -Found $false
            }

            $script:mc01Tree = Build-SPOrgTree -IdentityIds @('id-gen-011') -MaxDepth 4
            $script:mc01Band = Resolve-SPIdentityBand -OrgTree $script:mc01Tree.Data

            # ---- Leadership rollup: a manager (certifier) approves/revokes for ICs ----
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }
            $script:mc01OrgTree = @{
                Nodes = @{
                    'id-gen-011' = @{ Identity = @{ Id='id-gen-011'; Name='William Brown';   ManagerId='id-gen-006'; ManagerName='Jennifer Garcia'; Found=$true }; ManagerId='id-gen-006'; Level=0; Children=@() }
                    'id-ic-2'    = @{ Identity = @{ Id='id-ic-2';    Name='Second IC';       ManagerId='id-gen-006'; ManagerName='Jennifer Garcia'; Found=$true }; ManagerId='id-gen-006'; Level=0; Children=@() }
                    'id-gen-006' = @{ Identity = @{ Id='id-gen-006'; Name='Jennifer Garcia'; ManagerId='id-gen-003'; ManagerName='Robert Williams'; Found=$true }; ManagerId='id-gen-003'; Level=1; Children=@('id-gen-011','id-ic-2') }
                    'id-gen-003' = @{ Identity = @{ Id='id-gen-003'; Name='Robert Williams'; ManagerId='id-gen-001'; ManagerName='James Smith';     Found=$true }; ManagerId='id-gen-001'; Level=2; Children=@('id-gen-006') }
                    'id-gen-001' = @{ Identity = @{ Id='id-gen-001'; Name='James Smith';     ManagerId='';           ManagerName='';                Found=$true }; ManagerId='';           Level=3; Children=@('id-gen-003') }
                }
                TopLeaders  = @('id-gen-001')
                Directors   = @('id-gen-003')
                Managers    = @('id-gen-006')
                LeafCount   = 2
                MaxDepthHit = $false
            }
            # Certifier = the manager (Jennifer Garcia / id-gen-006).
            $script:mc01Decisions = @{
                Approved = @(
                    [PSCustomObject]@{ IdentityName='William Brown'; AccessName='AD-SG-Admins-3'; ReviewerName='Jennifer Garcia'; DecisionDate='2026-06-05T10:00:00Z' }
                )
                Revoked = @(
                    [PSCustomObject]@{ IdentityName='Second IC';     AccessName='AD-SG-Admins-3'; ReviewerName='Jennifer Garcia'; DecisionDate='2026-06-05T10:05:00Z' }
                )
                Pending = @()
            }
            $script:mc01Roll = Group-SPAuditByLeadership -Decisions $script:mc01Decisions -OrgTree $script:mc01OrgTree
        }

        It "Should build the 4-rung org tree from the real fixture chain (Success + 4 nodes)" {
            $script:mc01Tree.Success | Should -Be $true
            $script:mc01Tree.Data.Nodes.Count | Should -Be 4
        }

        It "Should assign correct depth levels along the real chain" {
            $n = $script:mc01Tree.Data.Nodes
            $n['id-gen-011'].Level | Should -Be 0
            $n['id-gen-006'].Level | Should -Be 1
            $n['id-gen-003'].Level | Should -Be 2
            $n['id-gen-001'].Level | Should -Be 3
        }

        It "Should resolve depth-derived bands E..B along the chain (top = James Smith)" {
            $b = $script:mc01Band.Data.Bands
            $b['id-gen-011'] | Should -Be 'E'
            $b['id-gen-006'] | Should -Be 'D'
            $b['id-gen-003'] | Should -Be 'C'
            $b['id-gen-001'] | Should -Be 'B'
        }

        It "Should attribute the manager's (certifier) decisions to the right director and VP without double-count" {
            $dir = $script:mc01Roll['Directors']['id-gen-003']
            $dir | Should -Not -BeNullOrEmpty
            $dir.TotalItems | Should -Be 2
            $dir.Approved   | Should -Be 1
            $dir.Revoked    | Should -Be 1
            ($dir.Approved + $dir.Revoked + $dir.Pending) | Should -Be $dir.TotalItems
        }

        It "Should roll the manager subtree up to the top leader (James Smith) counted once" {
            $vp = $script:mc01Roll['Executive']['id-gen-001']
            $vp | Should -Not -BeNullOrEmpty
            $vp.Name       | Should -Be 'James Smith'
            $vp.TotalItems | Should -Be 2
            ($vp.Approved + $vp.Revoked + $vp.Pending) | Should -Be $vp.TotalItems
        }

        It "Should attribute the certifying manager (id-gen-006) under the correct director (no cross-attribution)" {
            $dir = $script:mc01Roll['Directors']['id-gen-003']
            @($dir.Managers.Keys) | Should -Contain 'id-gen-006'
        }
    }
}
#endregion

# ===========================================================================
#region MC-02 (Layer B) -- SMTP-WhatIf logs (Action='Logged'), NO real send
# ===========================================================================
Describe "MC-02: SMTP-WhatIf logs each leader email as Action='Logged' and never sends a real email" {

    Context "When Audit.Smtp.Enabled is false (simulate / WhatIf) and Send-SPReport is called per leader" {
        BeforeAll {
            Mock Write-SPLog       -ModuleName SP.AuditOperations { }
            Mock Send-MailMessage  -ModuleName SP.AuditOperations { throw 'REAL SMTP send attempted -- WhatIf contract violated' }
            Mock Get-SPConfig      -ModuleName SP.AuditOperations {
                [PSCustomObject]@{
                    Audit = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{ Enabled = $false; SubjectPrefix = '[SailPoint Audit]' }
                    }
                    Notification = [PSCustomObject]@{
                        Smtp = [PSCustomObject]@{ Server=''; Port=587; From=''; UseSsl=$true }
                    }
                }
            }

            $script:mc02Leaders = @(
                @{ Email='james.smith@corp.test';   Name='James Smith';      Report='C:\Audit\leadership\james-smith.html' }
                @{ Email='robert.williams@corp.test'; Name='Robert Williams'; Report='C:\Audit\leadership\robert-williams.html' }
            )
            $script:mc02Results = @()
            foreach ($l in $script:mc02Leaders) {
                $script:mc02Results += (Send-SPReport -ReportPath $l.Report -RecipientEmail $l.Email -RecipientName $l.Name -CorrelationID 'mc02')
            }
        }

        It "Should return Success=true with Action='Logged' for every leader (nothing sent)" {
            $script:mc02Results.Count | Should -Be 2
            foreach ($r in $script:mc02Results) {
                $r.Success      | Should -Be $true
                $r.Data.Action  | Should -Be 'Logged'
            }
        }

        It "Should record the correct recipient + report path in each logged entry" {
            $byEmail = @{}
            foreach ($r in $script:mc02Results) { $byEmail[$r.Data.Recipient] = $r }
            $byEmail['james.smith@corp.test'].Data.File   | Should -Be 'C:\Audit\leadership\james-smith.html'
            $byEmail['robert.williams@corp.test'].Data.File | Should -Be 'C:\Audit\leadership\robert-williams.html'
        }

        It "Should NEVER invoke Send-MailMessage (no real email)" {
            Should -Invoke Send-MailMessage -ModuleName SP.AuditOperations -Times 0 -Exactly
        }
    }
}
#endregion

# ===========================================================================
#region MC-03 -- REMOVED users detected/shown in BOTH 7d and 30d
# ===========================================================================
Describe "MC-03: REMOVED users are detected and surface in BOTH 7d and 30d (data truth + toolkit path)" {

    Context "Layer A: changelog window filtering surfaces the named removals" {
        BeforeAll {
            $script:mc03Rem7  = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound7  -Operation 'REMOVE'
            $script:mc03Rem30 = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'REMOVE'
        }

        It "Should surface the named 7-day removal (id-gen-043 from ent-009 AD-SG-HR-9) in BOTH windows" {
            $in7  = @($script:mc03Rem7  | Where-Object { $_.identityId -eq 'id-gen-043' -and $_.groupId -eq 'ent-009' })
            $in30 = @($script:mc03Rem30 | Where-Object { $_.identityId -eq 'id-gen-043' -and $_.groupId -eq 'ent-009' })
            $in7.Count  | Should -BeGreaterThan 0
            $in30.Count | Should -BeGreaterThan 0
            $in7[0].groupName | Should -Be 'AD-SG-HR-9'
        }

        It "Should surface the privileged-role removal (id-gen-006 from ent-003) in 30d ONLY (window really filters)" {
            $in7  = @($script:mc03Rem7  | Where-Object { $_.identityId -eq 'id-gen-006' -and $_.groupId -eq 'ent-003' })
            $in30 = @($script:mc03Rem30 | Where-Object { $_.identityId -eq 'id-gen-006' -and $_.groupId -eq 'ent-003' })
            $in7.Count  | Should -Be 0
            $in30.Count | Should -BeGreaterThan 0
        }

        It "Should have 30d REMOVE count >= 7d REMOVE count and both > 0" {
            $script:mc03Rem7.Count  | Should -BeGreaterThan 0
            $script:mc03Rem30.Count | Should -BeGreaterThan $script:mc03Rem7.Count
        }
    }

    Context "Layer B: Get-SPDeltaRevokeEvents returns the removed identity for a 7d vs 30d window" {
        # Get-SPDeltaRevokeEvents is an internal (non-exported) function of
        # SP.DeltaCertReport, so it is invoked + mocked inside InModuleScope (the
        # canonical Pester way to exercise an unexported function). The mocked
        # transport returns a slice modelled on the fixture's tracked-role REMOVE
        # events as REVOKE_ACCESS account-activities; the function's client-side
        # HoursBack filter then drops the older (~20d) event from the 7d window.
        BeforeAll {
            Mock Write-SPLog  -ModuleName SP.DeltaCertReport { }
            Mock Get-SPConfig -ModuleName SP.DeltaCertReport {
                [PSCustomObject]@{ Api = [PSCustomObject]@{ MaxPaginationPages = 200 } }
            }
            Mock Invoke-SPApiRequest -ModuleName SP.DeltaCertReport {
                $recent = [PSCustomObject]@{
                    id           = 'act-id-gen-043'
                    type         = 'REVOKE_ACCESS'
                    created      = (Get-Date).AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ')   # ~1 day -> 7d & 30d
                    requestedFor = @([PSCustomObject]@{ id = 'id-gen-043'; name = 'William Brown' })
                    items        = @([PSCustomObject]@{ operation='REMOVE'; type='ENTITLEMENT'; sourceId='src-ad-001'; value='CN=AD-SG-HR-9'; name='AD-SG-HR-9' })
                }
                $older = [PSCustomObject]@{
                    id           = 'act-id-gen-006'
                    type         = 'REVOKE_ACCESS'
                    created      = (Get-Date).AddHours(-480).ToString('yyyy-MM-ddTHH:mm:ssZ')   # ~20 days -> 30d only
                    requestedFor = @([PSCustomObject]@{ id = 'id-gen-006'; name = 'Jennifer Garcia' })
                    items        = @([PSCustomObject]@{ operation='REMOVE'; type='ENTITLEMENT'; sourceId='src-ad-001'; value='CN=AD-SG-Admins-3'; name='AD-SG-Admins-3' })
                }
                return @{ Success = $true; StatusCode = 200; Data = @($recent, $older); Error = $null }
            }

            $script:mc03Rev7 = InModuleScope SP.DeltaCertReport {
                Get-SPDeltaRevokeEvents -SourceIds @('src-ad-001') -HoursBack 168 -CorrelationID 'mc03-7'
            }
            $script:mc03Rev30 = InModuleScope SP.DeltaCertReport {
                Get-SPDeltaRevokeEvents -SourceIds @('src-ad-001') -HoursBack 720 -CorrelationID 'mc03-30'
            }
        }

        It "Should query the REVOKE_ACCESS account-activities endpoint" {
            # The call was made inside InModuleScope, so assert the invocation in the
            # same scope (Pester attributes InModuleScope calls to the module's scope).
            InModuleScope SP.DeltaCertReport {
                Should -Invoke Invoke-SPApiRequest -Scope Context -ParameterFilter {
                    $Method -eq 'GET' -and $Endpoint -eq '/account-activities'
                }
            }
        }

        It "Should return the recently-removed identity (id-gen-043) in the 7d window" {
            $script:mc03Rev7.Success | Should -Be $true
            @($script:mc03Rev7.Data | Where-Object { $_.IdentityId -eq 'id-gen-043' }).Count | Should -BeGreaterThan 0
        }

        It "Should return a superset (>=) of events for 30d vs 7d, including the older priv removal (id-gen-006)" {
            $script:mc03Rev30.Success | Should -Be $true
            @($script:mc03Rev30.Data).Count | Should -BeGreaterOrEqual @($script:mc03Rev7.Data).Count
            @($script:mc03Rev30.Data | Where-Object { $_.IdentityId -eq 'id-gen-006' }).Count | Should -BeGreaterThan 0
        }
    }
}
#endregion

# ===========================================================================
#region MC-04 (Layer B) -- Campaign WRITE path round-trips (10 manager campaigns)
# ===========================================================================
Describe "MC-04: Campaign WRITE path round-trips -- 10 MANAGER campaigns (one per tracked priv role) submit, activate, and are found" {

    Context "When submitting one MANAGER campaign per tracked privileged role via New/Start-SPCampaign" {
        BeforeAll {
            Mock Write-SPLog  -ModuleName SP.Campaigns { }
            Mock Get-SPConfig -ModuleName SP.Campaigns {
                [PSCustomObject]@{ Api = [PSCustomObject]@{ MaxPaginationPages = 200 } }
            }

            # In-memory store emulating POST /campaigns + POST /:id/activate + GET search/get.
            $script:mc04Store = @{}
            $script:mc04Seq   = 0

            Mock Invoke-SPApiRequest -ModuleName SP.Campaigns {
                # POST /campaigns -> create
                if ($Method -eq 'POST' -and $Endpoint -eq '/campaigns') {
                    $script:mc04Seq++
                    $id = ('camp-mc04-{0:D2}' -f $script:mc04Seq)
                    # MANAGER campaign body carries the certifier as body.certifiers[0].id
                    # (see Build-SPCampaignBody). Surface it as a flat certifierId on the record.
                    $certId = ''
                    if ($null -ne $Body -and $Body.Contains('certifiers') -and @($Body['certifiers']).Count -gt 0) {
                        $certId = [string]@($Body['certifiers'])[0].id
                    }
                    $rec = [PSCustomObject]@{ id=$id; name=$Body.name; type=$Body.type; status='STAGED'; certifierId=$certId }
                    $script:mc04Store[$id] = $rec
                    return @{ Success=$true; StatusCode=200; Data=$rec; Error=$null }
                }
                # POST /campaigns/{id}/activate -> ACTIVE
                if ($Method -eq 'POST' -and $Endpoint -match '/campaigns/(.+)/activate') {
                    $id = $Matches[1]
                    if ($script:mc04Store.ContainsKey($id)) { $script:mc04Store[$id].status = 'ACTIVE' }
                    return @{ Success=$true; StatusCode=200; Data=[PSCustomObject]@{ id=$id; status='ACTIVATING' }; Error=$null }
                }
                # GET /campaigns/{id} -> get by id
                if ($Method -eq 'GET' -and $Endpoint -match '^/campaigns/([^/]+)$') {
                    $id = $Matches[1]
                    if ($script:mc04Store.ContainsKey($id)) {
                        return @{ Success=$true; StatusCode=200; Data=$script:mc04Store[$id]; Error=$null }
                    }
                    return @{ Success=$false; StatusCode=404; Data=$null; Error='Not found' }
                }
                # GET /campaigns -> search (return all stored matching name fragment)
                if ($Method -eq 'GET' -and $Endpoint -eq '/campaigns') {
                    $all = @($script:mc04Store.Values)
                    return @{ Success=$true; StatusCode=200; Data=$all; Error=$null }
                }
                return @{ Success=$false; StatusCode=400; Data=$null; Error="Unhandled $Method $Endpoint" }
            }

            $script:mc04Created = @()
            $i = 0
            foreach ($tr in $script:Tracked) {
                $i++
                $nm = "Daily Privileged Role Attestation - $($tr.name)"
                $res = New-SPCampaign -Name $nm -Type MANAGER -CertifierIdentityId $tr.responsibleManagerId -CorrelationID ("mc04-new-$i")
                $script:mc04Created += [PSCustomObject]@{ Result=$res; ExpectedMgr=$tr.responsibleManagerId }
            }
            $script:mc04StartOk = $true
            foreach ($c in $script:mc04Created) {
                if (-not $c.Result.Success) { $script:mc04StartOk = $false; continue }
                $sr = Start-SPCampaign -CampaignId $c.Result.Data.id -CorrelationID 'mc04-start'
                if (-not $sr.Success) { $script:mc04StartOk = $false }
            }
            $script:mc04Search = Search-SPCampaigns -Keyword 'Daily Privileged Role Attestation' -CorrelationID 'mc04-search'
        }

        It "Should create all 10 MANAGER campaigns with Success=true and an assigned id" {
            $script:mc04Created.Count | Should -Be 10
            foreach ($c in $script:mc04Created) {
                $c.Result.Success | Should -Be $true
                $c.Result.Data.id | Should -Not -BeNullOrEmpty
            }
        }

        It "Should activate all 10 campaigns successfully" {
            $script:mc04StartOk | Should -Be $true
        }

        It "Should carry the correct responsible manager (certifier) on each created campaign" {
            foreach ($c in $script:mc04Created) {
                $c.Result.Data.certifierId | Should -Be $c.ExpectedMgr
            }
        }

        It "Should round-trip: Search-SPCampaigns finds all 10 submitted campaigns" {
            $script:mc04Search.Success | Should -Be $true
            @($script:mc04Search.Data).Count | Should -Be 10
        }

        It "Should round-trip: Get-SPCampaign returns each campaign by id" {
            foreach ($c in $script:mc04Created) {
                $got = Get-SPCampaign -CampaignId $c.Result.Data.id -CorrelationID 'mc04-get'
                $got.Success    | Should -Be $true
                $got.Data.id    | Should -Be $c.Result.Data.id
                $got.Data.status | Should -Be 'ACTIVE'
            }
        }
    }
}
#endregion

# ===========================================================================
#region MC-05 (Layer A) -- 7-day vs 30-day views show expected deltas/trends
# ===========================================================================
Describe "MC-05: 7-day vs 30-day views show expected deltas/trends (strict subset + real delta)" {

    Context "When aggregating changelog and daily campaigns over both windows" {
        BeforeAll {
            $script:mc05Add7   = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound7  -Operation 'ADD'
            $script:mc05Add30  = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'ADD'
            $script:mc05Rem7   = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound7  -Operation 'REMOVE'
            $script:mc05Rem30  = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'REMOVE'
            $script:mc05Camp7  = @($script:Daily | Where-Object { [datetime]$_.created -ge $script:Bound7 })
            $script:mc05Camp30 = @($script:Daily | Where-Object { [datetime]$_.created -ge $script:Bound30 })
        }

        It "Should have 30d ADD/REMOVE counts >= 7d counts, with 7d > 0" {
            $script:mc05Add7.Count  | Should -BeGreaterThan 0
            $script:mc05Rem7.Count  | Should -BeGreaterThan 0
            $script:mc05Add30.Count | Should -BeGreaterOrEqual $script:mc05Add7.Count
            $script:mc05Rem30.Count | Should -BeGreaterOrEqual $script:mc05Rem7.Count
        }

        It "Should have strictly MORE changelog events in 30d than 7d (a real delta, not equal)" {
            ($script:mc05Add30.Count + $script:mc05Rem30.Count) |
                Should -BeGreaterThan ($script:mc05Add7.Count + $script:mc05Rem7.Count)
        }

        It "Should have ~30 daily campaigns in 30d and ~7-8 in 7d (30d > 7d)" {
            $script:mc05Camp30.Count | Should -Be 30
            $script:mc05Camp7.Count  | Should -BeGreaterThan 0
            $script:mc05Camp30.Count | Should -BeGreaterThan $script:mc05Camp7.Count
        }

        It "Should be a strict subset: every daily campaign in the 7d set is also in the 30d set" {
            $set30 = @{}
            foreach ($c in $script:mc05Camp30) { $set30[$c.id] = $true }
            foreach ($c in $script:mc05Camp7) {
                $set30.ContainsKey($c.id) | Should -Be $true
            }
        }
    }
}
#endregion

# ===========================================================================
#region MC-06 (Layer A) -- Privileged-role reports: roles, members, day-over-day churn
# ===========================================================================
Describe "MC-06: Privileged-role reports -- fixed roles, current members, day-over-day adds/removes" {

    It "Should track exactly 10 privileged roles including ent-003 and ent-017" {
        $script:TrackedIds.Count | Should -Be 10
        $script:TrackedIds | Should -Contain 'ent-003'
        $script:TrackedIds | Should -Contain 'ent-017'
    }

    It "Should flag every tracked role's entitlement as privileged (attributes.privileged=true)" -ForEach $script:DiscTrackedRoleCases {
        $ent = $script:Fx.Entitlements | Where-Object { $_.id -eq $RoleId } | Select-Object -First 1
        $ent | Should -Not -BeNullOrEmpty
        $ent.attributes.privileged | Should -Be $true
    }

    It "Should report the exact current member set for ent-003 (id-gen-069, id-gen-035, id-gen-050)" {
        $ent = $script:Fx.Entitlements | Where-Object { $_.id -eq 'ent-003' } | Select-Object -First 1
        $members = @($ent.members)
        $members.Count | Should -Be 3
        $members | Should -Contain 'id-gen-069'
        $members | Should -Contain 'id-gen-035'
        $members | Should -Contain 'id-gen-050'
    }

    It "Should surface the named privileged-role REMOVE (id-gen-006 from ent-003) in the day-over-day churn" {
        $trackedRem = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'REMOVE' -GroupIds $script:TrackedIds
        $trackedRem.Count | Should -BeGreaterThan 0
        @($trackedRem | Where-Object { $_.identityId -eq 'id-gen-006' -and $_.groupId -eq 'ent-003' }).Count | Should -BeGreaterThan 0
    }

    It "Should show membership CHANGED on at least one tracked role (both an ADD and a REMOVE over 30 days)" {
        $trackedAdd = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'ADD'    -GroupIds $script:TrackedIds
        $trackedRem = Select-MC30ChangelogInWindow -Changelog $script:Changelog -Bound $script:Bound30 -Operation 'REMOVE' -GroupIds $script:TrackedIds
        $addGroups = @($trackedAdd | ForEach-Object { $_.groupId } | Sort-Object -Unique)
        $remGroups = @($trackedRem | ForEach-Object { $_.groupId } | Sort-Object -Unique)
        $both = @($addGroups | Where-Object { $remGroups -contains $_ })
        $both.Count | Should -BeGreaterThan 0
    }
}
#endregion

# ===========================================================================
#region MC-07 (Layer A) -- Manager accountability: per-day status + window rollup
# ===========================================================================
Describe "MC-07: Manager accountability -- per-day attestation status and monotone rollup across 7d/30d windows" {

    Context "Per-day status in camp-daily-priv-01 (dated 2026-06-05)" {
        BeforeAll {
            $script:mc07c01 = $script:Daily | Where-Object { $_.id -eq 'camp-daily-priv-01' } | Select-Object -First 1
            $script:mc07Att = @($script:mc07c01.managerAttestation)
        }

        It "Should carry a 10-entry managerAttestation array with valid statuses and decisionsMade<=Total" {
            $script:mc07Att.Count | Should -Be 10
            foreach ($a in $script:mc07Att) {
                $a.status | Should -BeIn @('attested','overdue','missed')
                $a.decisionsMade | Should -BeLessOrEqual $a.decisionsTotal
            }
        }

        It "Should record id-gen-002 (Mary Johnson) as MISSED with 3/4 decisions" {
            $a = $script:mc07Att | Where-Object { $_.managerId -eq 'id-gen-002' } | Select-Object -First 1
            $a            | Should -Not -BeNullOrEmpty
            $a.status     | Should -Be 'missed'
            $a.decisionsMade  | Should -Be 3
            $a.decisionsTotal | Should -Be 4
        }

        It "Should record id-gen-007 (Michael Miller) as OVERDUE and id-gen-001 (James Smith) as ATTESTED" {
            $ov = $script:mc07Att | Where-Object { $_.managerId -eq 'id-gen-007' } | Select-Object -First 1
            $at = $script:mc07Att | Where-Object { $_.managerId -eq 'id-gen-001' } | Select-Object -First 1
            $ov.status | Should -Be 'overdue'
            $at.status | Should -Be 'attested'
        }
    }

    Context "Rollup across the 7d and 30d windows for id-gen-002" {
        BeforeAll {
            $script:mc07Roll7  = Get-MC30AccountabilityRollup -DailyCamps $script:Daily -Bound $script:Bound7  -ManagerId 'id-gen-002'
            $script:mc07Roll30 = Get-MC30AccountabilityRollup -DailyCamps $script:Daily -Bound $script:Bound30 -ManagerId 'id-gen-002'
        }

        It "Should sum each window's per-status counts to the number of daily campaigns in that window" {
            ($script:mc07Roll7.Attested  + $script:mc07Roll7.Overdue  + $script:mc07Roll7.Missed)  | Should -Be $script:mc07Roll7.Total
            ($script:mc07Roll30.Attested + $script:mc07Roll30.Overdue + $script:mc07Roll30.Missed) | Should -Be $script:mc07Roll30.Total
        }

        It "Should have a monotone rollup: 30d totals/missed/overdue >= 7d (window superset)" {
            $script:mc07Roll30.Total   | Should -BeGreaterOrEqual $script:mc07Roll7.Total
            $script:mc07Roll30.Missed  | Should -BeGreaterOrEqual $script:mc07Roll7.Missed
            $script:mc07Roll30.Overdue | Should -BeGreaterOrEqual $script:mc07Roll7.Overdue
        }

        It "Should show 30d strictly covers more daily campaigns than 7d (the trend window grows)" {
            $script:mc07Roll30.Total | Should -BeGreaterThan $script:mc07Roll7.Total
            $script:mc07Roll30.Total | Should -Be 30
        }
    }

    Context "The accountability signal is present somewhere in 30d" {
        BeforeAll {
            $script:mc07AnySignal = $false
            $mgrIds = @($script:Daily[0].managerAttestation | ForEach-Object { $_.managerId })
            foreach ($mid in $mgrIds) {
                $r = Get-MC30AccountabilityRollup -DailyCamps $script:Daily -Bound $script:Bound30 -ManagerId $mid
                if (($r.Overdue + $r.Missed) -gt 0) { $script:mc07AnySignal = $true }
            }
        }

        It "Should have at least one manager with a non-zero overdue or missed count over 30 days" {
            $script:mc07AnySignal | Should -Be $true
        }
    }
}
#endregion
