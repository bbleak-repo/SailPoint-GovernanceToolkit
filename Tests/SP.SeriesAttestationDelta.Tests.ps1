<#
.SYNOPSIS
    Tests for SP.CampaignSeries V4c engine Get-SPSeriesAttestationDelta -- the pure
    cross-instance decision-transition walk that flags the FIRST genuine reviewer approval
    in a recurring-series window (the honest "newly attested" headline), plus
    already-attested-earlier, newly-in-scope, decision-changed, and persistently-undecided.

    The fixtures are authored INLINE: each "series instance" carries DIFFERENT campaign/cert/item
    ids but the SAME (identityId, access) pairs, so the engine can prove the cross-instance join
    and the chronological first-genuine-approval logic.

    SAD-01: module imports + command exported
    SAD-02: headline NewlyAttested -- Undecided in older instances then genuine APPROVE in newest
    SAD-03: AlreadyAttestedEarlier -- a genuine prior approval excludes it from NewlyAttested
    SAD-04: CRITICAL honesty guard -- prior COMPLETED idNowAutoApproved APPROVE does NOT mask a real first-time approval
    SAD-05: NewlyInScope -- identity+access absent from all priors, present in newest
    SAD-06: DecisionChanged -- approve in one instance, revoke in another
    SAD-07: PersistentlyUndecided -- never genuinely decided across the window
    SAD-08: NewlyAttestedByReviewer + PersistentlyUndecidedByReviewer rollups attribute via Roster + sort
    SAD-09: Unverified provenance propagates into the item record and Data.Unverified
    SAD-10: empty Instances -> Success with zero Counts, no throw
    SAD-11: pre-resolved ItemStates path == raw Items path classification
    SAD-12: blank-ItemKey items are skipped
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Audit

    # --- Inline item factory (mirrors SP.SeriesItemState.Tests.ps1 New-SISItem) ----------------
    function New-SADItem {
        param(
            [string]$ItemId, [string]$IdentityId, [string]$IdentityName,
            [string]$AccessId, [string]$AccessName, [string]$AccessType,
            [string]$NativeIdentity, [string]$SourceId, [string]$SourceName,
            $Decision, [string]$Comment, $ReviewedBy, [string]$DecisionDate
        )
        $access = [PSCustomObject]@{
            id     = $AccessId
            name   = $AccessName
            type   = $AccessType
            source = [PSCustomObject]@{ id = $SourceId; name = $SourceName }
        }
        [PSCustomObject]@{
            id              = $ItemId
            identitySummary = [PSCustomObject]@{ identityId = $IdentityId; name = $IdentityName }
            access          = $access
            account         = [PSCustomObject]@{ nativeIdentity = $NativeIdentity; sourceId = $SourceId }
            decision        = $Decision
            comment         = $Comment
            reviewedBy      = $ReviewedBy
            decisionDate    = $DecisionDate
        }
    }

    # Wrap raw items + roster into a series instance hashtable (raw Items path).
    function New-SADInstance {
        param(
            [int]$OrderIndex, [string]$CampaignId, [string]$CampaignName,
            [string]$Status = 'COMPLETED', [bool]$Unverified = $false,
            [object[]]$Items = @(), [object[]]$Roster = @()
        )
        @{
            OrderIndex   = $OrderIndex
            CampaignId   = $CampaignId
            CampaignName = $CampaignName
            Status       = $Status
            Unverified   = $Unverified
            Items        = $Items
            Roster       = $Roster
        }
    }

    # A standard entitlement item for identity id-jdoe / Finance-RW on src-ad, parameterized decision.
    function New-JdoeItem {
        param([string]$ItemId, $Decision, [string]$Comment = '', $ReviewedBy = $null, [string]$DecisionDate = '')
        New-SADItem -ItemId $ItemId -IdentityId 'id-jdoe' -IdentityName 'Jane Doe' `
            -AccessId 'ent-9001' -AccessName 'Finance-RW' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=jdoe' -SourceId 'src-ad' -SourceName 'Active Directory' `
            -Decision $Decision -Comment $Comment -ReviewedBy $ReviewedBy -DecisionDate $DecisionDate
    }

    $script:JdoeKey = 'id-jdoe|ent-9001|src-ad'
    $script:Bob = [PSCustomObject]@{ name = 'Bob Boss'; id = 'rv-bob'; email = 'bob@x.io' }
}

Describe 'SAD-01 module + command' {
    It 'exports Get-SPSeriesAttestationDelta' {
        (Get-Command Get-SPSeriesAttestationDelta -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
    }
}

Describe 'SAD-02 headline NewlyAttested' {
    It 'flags an item undecided in older instances then genuinely APPROVED in the newest' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'Access Review - 2026-06-28' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'Access Review - 2026-06-29' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision $null)
        )
        $i3 = New-SADInstance -OrderIndex 3 -CampaignId 'c3' -CampaignName 'Access Review - 2026-06-30' -Items @(
            (New-JdoeItem -ItemId 'a3' -Decision 'APPROVE' -Comment 'verified' -ReviewedBy $script:Bob -DecisionDate '2026-06-30')
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2, $i3)
        $r.Success | Should -BeTrue
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec | Should -Not -BeNullOrEmpty
        $rec.Classification                 | Should -Be 'NewlyAttested'
        $rec.IsNewlyAttested                | Should -BeTrue
        $rec.IsAlreadyAttestedEarlier       | Should -BeFalse
        $rec.FirstGenuineApprovalOrderIndex | Should -Be 3
        $rec.CurrentIsGenuineApproval       | Should -BeTrue
        $r.Data.Counts.NewlyAttested        | Should -Be 1
    }

    It 'sorts instances by OrderIndex regardless of input order (newest wins as current)' {
        # Pass newest first to prove the engine sorts by OrderIndex, not input order.
        $i3 = New-SADInstance -OrderIndex 3 -CampaignId 'c3' -CampaignName 'C-2026-06-30' -Items @(
            (New-JdoeItem -ItemId 'a3' -Decision 'APPROVE' -Comment 'ok' -ReviewedBy $script:Bob)
        )
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-2026-06-28' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i3, $i1)
        $r.Data.NewestCampaignId | Should -Be 'c3'
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.Classification | Should -Be 'NewlyAttested'
    }
}

Describe 'SAD-03 AlreadyAttestedEarlier' {
    It 'excludes from NewlyAttested when a prior instance had a genuine approval' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision 'APPROVE' -Comment 'reviewed' -ReviewedBy $script:Bob)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -Comment 'reviewed again' -ReviewedBy $script:Bob)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.IsAlreadyAttestedEarlier | Should -BeTrue
        $rec.IsNewlyAttested          | Should -BeFalse
        $rec.Classification           | Should -Be 'AlreadyAttestedEarlier'
        $r.Data.Counts.NewlyAttested  | Should -Be 0
    }
}

Describe 'SAD-04 CRITICAL honesty guard (auto-approved-at-close prior)' {
    It 'does NOT let a prior idNowAutoApproved approval mask the genuine first-time approval' {
        # Prior instance COMPLETED with an auto-approved-at-close APPROVE (no real reviewer).
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Status 'COMPLETED' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision 'APPROVE' -Comment 'idNowAutoApproved' -ReviewedBy $null)
        )
        # Newest: a genuine reviewer APPROVE.
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Status 'ACTIVE' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -Comment 'really reviewed' -ReviewedBy $script:Bob)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.IsAlreadyAttestedEarlier | Should -BeFalse
        $rec.IsNewlyAttested          | Should -BeTrue
        $rec.PriorAutoApprovedMasked  | Should -BeTrue
        $rec.Classification           | Should -Be 'NewlyAttested'
    }
}

Describe 'SAD-05 NewlyInScope' {
    It 'flags an identity+access absent from all priors and present in the newest' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision 'APPROVE' -ReviewedBy $script:Bob)
        )
        # Newest adds a brand-new identity+access not present before.
        $newItem = New-SADItem -ItemId 'b1' -IdentityId 'id-new' -IdentityName 'New Hire' `
            -AccessId 'ent-7777' -AccessName 'HR-Read' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=new' -SourceId 'src-ad' -SourceName 'Active Directory' -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -ReviewedBy $script:Bob),
            $newItem
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq 'id-new|ent-7777|src-ad' }
        $rec | Should -Not -BeNullOrEmpty
        $rec.IsNewlyInScope | Should -BeTrue
        $rec.Classification | Should -Be 'NewlyInScope'
        $r.Data.Counts.NewlyInScope | Should -Be 1
    }
}

Describe 'SAD-06 DecisionChanged' {
    It 'flags approve in one instance and revoke in another' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision 'APPROVE' -Comment 'ok' -ReviewedBy $script:Bob)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'REVOKE' -Comment 'pull it' -ReviewedBy $script:Bob)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.IsDecisionChanged | Should -BeTrue
        $rec.Classification    | Should -Be 'DecisionChanged'
        $r.Data.Counts.DecisionChanged | Should -Be 1
    }
}

Describe 'SAD-07 PersistentlyUndecided' {
    It 'flags an item never genuinely decided across the window' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -Comment 'idNowAutoApproved' -ReviewedBy $null)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.IsPersistentlyUndecided | Should -BeTrue
        $rec.IsNewlyAttested         | Should -BeFalse
        $rec.Classification          | Should -Be 'PersistentlyUndecided'
        $r.Data.Counts.PersistentlyUndecided | Should -Be 1
    }
}

Describe 'SAD-08 reviewer rollups (roster attribution + deterministic sort)' {
    It 'groups NewlyAttested + PersistentlyUndecided by the cert-ASSIGNED roster reviewer' {
        # Newest cert certNew has an assigned roster reviewer (Carol). The cert-assigned reviewer
        # WINS over item.reviewedBy (the only correct attribution for an undecided null-reviewedBy
        # item, and consistently applied to the decided item too). So both the newly-attested and
        # persistently-undecided items in the newest instance attribute to Carol via the Roster.
        $roster = @(
            [PSCustomObject]@{ CertificationId = 'certNew'; ReviewerName = 'Carol Cert'; ReviewerId = 'rv-carol'; ReviewerEmail = 'carol@x.io' }
        )
        # Identity 1: undecided prior -> genuine approve newest (NewlyAttested).
        $p1a = New-JdoeItem -ItemId 'p1a' -Decision $null
        $p1b = New-JdoeItem -ItemId 'p1b' -Decision 'APPROVE' -Comment 'reviewed' -ReviewedBy $script:Bob
        # Identity 2: undecided across the window, null reviewedBy -> roster reviewer (Carol).
        $u2a = New-SADItem -ItemId 'u2a' -IdentityId 'id-2' -IdentityName 'Two' -AccessId 'ent-2' -AccessName 'G2' -AccessType 'ENTITLEMENT' -NativeIdentity 'CN=2' -SourceId 'src-ad' -SourceName 'AD' -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''
        $u2b = New-SADItem -ItemId 'u2b' -IdentityId 'id-2' -IdentityName 'Two' -AccessId 'ent-2' -AccessName 'G2' -AccessType 'ENTITLEMENT' -NativeIdentity 'CN=2' -SourceId 'src-ad' -SourceName 'AD' -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''

        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'certOld' -CampaignName 'C-1' -Items @($p1a, $u2a) -Roster @(
            [PSCustomObject]@{ CertificationId = 'certOld'; ReviewerName = 'Old Rev'; ReviewerId = 'rv-old'; ReviewerEmail = 'old@x.io' }
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'certNew' -CampaignName 'C-2' -Items @($p1b, $u2b) -Roster $roster

        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $r.Success | Should -BeTrue

        $na = @($r.Data.NewlyAttestedByReviewer)
        $na.Count | Should -Be 1
        $na[0].ReviewerName | Should -Be 'Carol Cert'
        $na[0].ReviewerId   | Should -Be 'rv-carol'
        $na[0].Count        | Should -Be 1
        @($na[0].Items)[0].ItemKey | Should -Be $script:JdoeKey

        $pu = @($r.Data.PersistentlyUndecidedByReviewer)
        $pu.Count | Should -Be 1
        $pu[0].ReviewerName | Should -Be 'Carol Cert'
        $pu[0].ReviewerId   | Should -Be 'rv-carol'
        $pu[0].Count        | Should -Be 1
        @($pu[0].Items)[0].ItemKey | Should -Be 'id-2|ent-2|src-ad'
    }

    It 'sorts reviewer clusters by ReviewerName then ReviewerId' {
        # Two persistently-undecided identities under two different newest-cert reviewers.
        $rosterZ = @([PSCustomObject]@{ CertificationId = 'cz'; ReviewerName = 'Zeb'; ReviewerId = 'rv-z'; ReviewerEmail = 'z@x.io' })
        $rosterA = @([PSCustomObject]@{ CertificationId = 'ca'; ReviewerName = 'Amy'; ReviewerId = 'rv-a'; ReviewerEmail = 'a@x.io' })
        $xa1 = New-SADItem -ItemId 'xa1' -IdentityId 'id-x' -IdentityName 'X' -AccessId 'ent-x' -AccessName 'GX' -AccessType 'ENTITLEMENT' -NativeIdentity 'CN=x' -SourceId 'src-ad' -SourceName 'AD' -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''
        $ya1 = New-SADItem -ItemId 'ya1' -IdentityId 'id-y' -IdentityName 'Y' -AccessId 'ent-y' -AccessName 'GY' -AccessType 'ENTITLEMENT' -NativeIdentity 'CN=y' -SourceId 'src-ad' -SourceName 'AD' -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''
        # Prior instance present for both (so they are not newly-in-scope).
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'cprev' -CampaignName 'C-prev' -Items @($xa1, $ya1) -Roster @()
        # Newest: identity-x under Zeb cert, identity-y under Amy cert -- but one instance can carry one
        # roster; so simulate via two separate newest certs is not possible in a single instance. Instead
        # attribute both via one newest roster carrying both certs is also not possible (cert is per-item).
        # Simplify: use pre-resolved ItemStates to set the current reviewer directly.
        $sx = [PSCustomObject]@{ ItemKey = 'id-x|ent-x|src-ad'; IdentityId='id-x'; IdentityName='X'; AccessId='ent-x'; AccessName='GX'; AccessType='ENTITLEMENT'; SourceId='src-ad'; SourceName='AD'; CertificationId='cz'; RawDecision=''; HonestDecision='Undecided'; IsGenuineApproval=$false; IsGenuineDecision=$false; IsAutoApproved=$false; DecisionDate=''; ReviewerId='rv-z'; ReviewerName='Zeb'; ReviewerEmail='z@x.io'; ReviewerSource='roster'; Unverified=$false }
        $sy = [PSCustomObject]@{ ItemKey = 'id-y|ent-y|src-ad'; IdentityId='id-y'; IdentityName='Y'; AccessId='ent-y'; AccessName='GY'; AccessType='ENTITLEMENT'; SourceId='src-ad'; SourceName='AD'; CertificationId='ca'; RawDecision=''; HonestDecision='Undecided'; IsGenuineApproval=$false; IsGenuineDecision=$false; IsAutoApproved=$false; DecisionDate=''; ReviewerId='rv-a'; ReviewerName='Amy'; ReviewerEmail='a@x.io'; ReviewerSource='roster'; Unverified=$false }
        $i2 = @{ OrderIndex = 2; CampaignId = 'cnew'; CampaignName = 'C-new'; Status = 'COMPLETED'; Unverified = $false; ItemStates = @($sx, $sy) }
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $pu = @($r.Data.PersistentlyUndecidedByReviewer)
        $pu.Count | Should -Be 2
        $pu[0].ReviewerName | Should -Be 'Amy'
        $pu[1].ReviewerName | Should -Be 'Zeb'
    }
}

Describe 'SAD-09 Unverified provenance' {
    It 'propagates Unverified into the item record and Data.Unverified' {
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Unverified $true -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Unverified $false -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -ReviewedBy $script:Bob)
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $r.Data.Unverified              | Should -BeTrue
        $r.Data.UnverifiedInstanceCount | Should -Be 1
        $rec = @($r.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }
        $rec.Unverified | Should -BeTrue
    }
}

Describe 'SAD-10 empty instances' {
    It 'returns Success with zero counts and no throw' {
        $r = Get-SPSeriesAttestationDelta -Instances @()
        $r.Success | Should -BeTrue
        $r.Data.InstanceCount     | Should -Be 0
        $r.Data.Counts.Total      | Should -Be 0
        @($r.Data.Items).Count    | Should -Be 0
        $r.Data.NewestCampaignId  | Should -Be ''
    }
}

Describe 'SAD-11 pre-resolved ItemStates path == raw path' {
    It 'yields the same classification from pre-resolved ItemStates as from raw Items' {
        # Raw path.
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null)
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -Comment 'ok' -ReviewedBy $script:Bob)
        )
        $rawResult = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        $rawRec = @($rawResult.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }

        # Pre-resolved path: resolve the same items up front and feed ItemStates.
        $s1 = Resolve-SPSeriesItemState -Item (New-JdoeItem -ItemId 'a1' -Decision $null) -CertificationId 'c1'
        $s2 = Resolve-SPSeriesItemState -Item (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -Comment 'ok' -ReviewedBy $script:Bob) -CertificationId 'c2'
        $p1 = @{ OrderIndex = 1; CampaignId = 'c1'; CampaignName = 'C-1'; Status = 'COMPLETED'; Unverified = $false; ItemStates = @($s1) }
        $p2 = @{ OrderIndex = 2; CampaignId = 'c2'; CampaignName = 'C-2'; Status = 'COMPLETED'; Unverified = $false; ItemStates = @($s2) }
        $preResult = Get-SPSeriesAttestationDelta -Instances @($p1, $p2)
        $preRec = @($preResult.Data.Items) | Where-Object { $_.ItemKey -eq $script:JdoeKey }

        $preRec.Classification | Should -Be $rawRec.Classification
        $preRec.Classification | Should -Be 'NewlyAttested'
    }
}

Describe 'SAD-12 blank ItemKey skipped' {
    It 'skips items whose every discriminator is blank' {
        $blank = [PSCustomObject]@{
            id              = 'itmEmpty'
            identitySummary = [PSCustomObject]@{ identityId = ''; name = '' }
            access          = [PSCustomObject]@{ id = ''; name = ''; type = '' }
            account         = [PSCustomObject]@{ nativeIdentity = ''; sourceId = '' }
            decision        = $null
        }
        $i1 = New-SADInstance -OrderIndex 1 -CampaignId 'c1' -CampaignName 'C-1' -Items @(
            (New-JdoeItem -ItemId 'a1' -Decision $null), $blank
        )
        $i2 = New-SADInstance -OrderIndex 2 -CampaignId 'c2' -CampaignName 'C-2' -Items @(
            (New-JdoeItem -ItemId 'a2' -Decision 'APPROVE' -ReviewedBy $script:Bob), $blank
        )
        $r = Get-SPSeriesAttestationDelta -Instances @($i1, $i2)
        # Only the JdoeKey survives; the blank-key item is skipped.
        @($r.Data.Items).Count | Should -Be 1
        @($r.Data.Items)[0].ItemKey | Should -Be $script:JdoeKey
    }
}
