<#
.SYNOPSIS
    Tests for SP.CampaignSeries V4c per-item helpers Get-SPSeriesItemKey +
    Resolve-SPSeriesItemState -- the stable cross-instance item key + honest per-item
    decision + cert-assigned reviewer attribution layer.

    The fixtures are authored INLINE on purpose: two 'series instances' carry DIFFERENT
    campaign/cert/item ids but the SAME (identityId, access.name/id) pairs, so the suite
    can prove the key JOINS across instances. (The CacheHonesty mock-fixtures.json embeds
    the cert id inside identitySummary.identityId, which would be instance-specific and
    could NOT prove cross-instance joining.)

    SIS-01: module imports + both commands exist
    SIS-02: same identity+access pairs across two instances -> EQUAL keys (cross-instance join)
    SIS-03: account-level vs entitlement-level discrimination
    SIS-04: cache wrapper (.Item) and raw item yield the same key
    SIS-05: name-derived fallbacks lower-cased; id components verbatim; rename-stable
    SIS-06: blank discriminators -> '' (never throws)
    SIS-07: clean reviewer APPROVE -> Approved / genuine approval
    SIS-08: idNowAutoApproved APPROVE -> Undecided / not genuine / auto-approved
    SIS-09: null decision -> Undecided
    SIS-10: undecided + no reviewedBy + matching roster -> reviewer from roster
    SIS-11: undecided + empty roster -> (Unassigned) / source 'none' (reviewedBy never fabricated)
    SIS-12: decided item, no roster -> reviewedBy attribution (source 'item')
    SIS-13: Unverified $true propagates
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Audit

    # --- Inline cross-instance fixtures ---------------------------------------
    # Two recurring instances of the SAME daily series: DIFFERENT cert/item ids, SAME
    # (identityId, access) pairs. An ENTITLEMENT-level item (access.id present) and an
    # ACCOUNT-level item (access.type ACCOUNT, no access.id).
    function New-SISItem {
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

    # Instance A (cert certA / campaign 2026-06-29)
    $script:entA = New-SISItem -ItemId 'itmA1' -IdentityId 'id-jdoe' -IdentityName 'Jane Doe' `
        -AccessId 'ent-9001' -AccessName 'Finance-RW' -AccessType 'ENTITLEMENT' `
        -NativeIdentity 'CN=jdoe' -SourceId 'src-ad' -SourceName 'Active Directory' `
        -Decision 'APPROVE' -Comment 'looks good' `
        -ReviewedBy ([PSCustomObject]@{ name = 'Bob Boss'; id = 'rv-bob'; email = 'bob@x.io' }) -DecisionDate '2026-06-29'

    # Instance B (cert certB / campaign 2026-06-30): DIFFERENT item id, SAME identity+access
    $script:entB = New-SISItem -ItemId 'itmB1' -IdentityId 'id-jdoe' -IdentityName 'Jane Doe' `
        -AccessId 'ent-9001' -AccessName 'Finance-RW' -AccessType 'ENTITLEMENT' `
        -NativeIdentity 'CN=jdoe' -SourceId 'src-ad' -SourceName 'Active Directory' `
        -Decision $null -Comment '' -ReviewedBy $null -DecisionDate ''
}

Describe 'SIS-01 module + commands' {
    It 'exports Get-SPSeriesItemKey and Resolve-SPSeriesItemState' {
        (Get-Command Get-SPSeriesItemKey      -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
        (Get-Command Resolve-SPSeriesItemState -ErrorAction Ignore) | Should -Not -BeNullOrEmpty
    }
}

Describe 'SIS-02 cross-instance key join' {
    It 'returns EQUAL keys for the same identity+access across two instances with different item ids' {
        $ka = Get-SPSeriesItemKey -Item $script:entA
        $kb = Get-SPSeriesItemKey -Item $script:entB
        $ka | Should -Not -BeNullOrEmpty
        $ka | Should -Be $kb
        # keyed on identity + access NAME (lowercased) + source id -- the name wins over
        # the churn-prone AccessId so reviewer reassignment does not change the key
        $ka | Should -Be 'id-jdoe|finance-rw|src-ad'
    }
}

Describe 'SIS-03 account vs entitlement discrimination' {
    It 'discriminates an account-level item from an entitlement-level item for the same identity' {
        $ent = New-SISItem -ItemId 'e' -IdentityId 'id-x' -IdentityName 'X' `
            -AccessId 'ent-1' -AccessName 'Grp' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=x' -SourceId 'src-1' -SourceName 'AD' -Decision 'APPROVE' -Comment '' -ReviewedBy $null -DecisionDate ''
        $acct = New-SISItem -ItemId 'a' -IdentityId 'id-x' -IdentityName 'X' `
            -AccessId '' -AccessName '' -AccessType 'ACCOUNT' `
            -NativeIdentity 'CN=x' -SourceId 'src-1' -SourceName 'AD' -Decision 'APPROVE' -Comment '' -ReviewedBy $null -DecisionDate ''
        $ke = Get-SPSeriesItemKey -Item $ent
        $ka = Get-SPSeriesItemKey -Item $acct
        $ke | Should -Not -Be $ka
        $ka | Should -Be 'id-x|account:cn=x|src-1'
    }
}

Describe 'SIS-04 wrapper vs raw' {
    It 'unwraps a cache wrapper (.Item) to the same key as the raw item' {
        $wrapper = [PSCustomObject]@{
            Item              = $script:entA
            CertificationId   = 'certA'
            CertificationName = 'Daily Cert'
            CampaignName      = 'Access Review - 2026-06-29'
        }
        $kraw  = Get-SPSeriesItemKey -Item $script:entA
        $kwrap = Get-SPSeriesItemKey -Item $wrapper
        $kwrap | Should -Be $kraw
    }
}

Describe 'SIS-05 name casing + reassignment stability' {
    It 'lower-cases name-derived parts but leaves id parts verbatim, and is reassignment-stable' {
        # Access NAME is the primary discriminator (lower-cased); source id verbatim.
        $named = New-SISItem -ItemId 'n1' -IdentityId 'ID-Mixed' -IdentityName 'M' `
            -AccessId '' -AccessName 'Payroll-Admin' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=M' -SourceId 'src-AD' -SourceName 'Active Directory' -Decision 'APPROVE' -Comment '' -ReviewedBy $null -DecisionDate ''
        $k = Get-SPSeriesItemKey -Item $named
        # identity id verbatim (case preserved), access name lower-cased, source id verbatim
        $k | Should -Be 'ID-Mixed|payroll-admin|src-AD'

        # REASSIGNMENT stability: ISC regenerates the AccessId when a certification is
        # reassigned to a new reviewer. Same identity + name + source with DIFFERENT
        # access ids must produce the SAME key, or the grant diffs as newly-in-scope /
        # newly approved on every reassignment.
        $reassignedA = New-SISItem -ItemId 'n2' -IdentityId 'id-r' -IdentityName 'R' `
            -AccessId 'ent-5' -AccessName 'Finance-RW' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=R' -SourceId 'src-5' -SourceName 'Active Directory' -Decision 'APPROVE' -Comment '' -ReviewedBy $null -DecisionDate ''
        $reassignedB = New-SISItem -ItemId 'n3' -IdentityId 'id-r' -IdentityName 'R' `
            -AccessId 'ent-5-REGENERATED' -AccessName 'Finance-RW' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=R' -SourceId 'src-5' -SourceName 'Active Directory' -Decision 'APPROVE' -Comment '' -ReviewedBy $null -DecisionDate ''
        (Get-SPSeriesItemKey -Item $reassignedA) | Should -Be (Get-SPSeriesItemKey -Item $reassignedB)
    }
}

Describe 'SIS-06 blank discriminators' {
    It 'returns empty string (never throws) when identity and all access discriminators are blank' {
        $blank = [PSCustomObject]@{
            id              = 'itmEmpty'
            identitySummary = [PSCustomObject]@{ identityId = ''; name = '' }
            access          = [PSCustomObject]@{ id = ''; name = ''; type = '' }
            account         = [PSCustomObject]@{ nativeIdentity = ''; sourceId = '' }
            decision        = $null
        }
        $k = Get-SPSeriesItemKey -Item $blank
        $k | Should -Be ''
    }
}

Describe 'SIS-07 honest clean approve' {
    It 'classifies a genuine reviewer APPROVE as Approved / genuine approval' {
        $s = Resolve-SPSeriesItemState -Item $script:entA -CertificationId 'certA'
        $s.HonestDecision    | Should -Be 'Approved'
        $s.IsGenuineApproval | Should -BeTrue
        $s.IsGenuineDecision | Should -BeTrue
        $s.IsAutoApproved    | Should -BeFalse
        $s.RawDecision       | Should -Be 'APPROVE'
        $s.ItemKey           | Should -Be 'id-jdoe|finance-rw|src-ad'
    }
}

Describe 'SIS-08 auto-approved-at-close inflation' {
    It 'demotes an idNowAutoApproved APPROVE to Undecided / not genuine / auto-approved' {
        $auto = New-SISItem -ItemId 'auto1' -IdentityId 'id-a' -IdentityName 'A' `
            -AccessId 'ent-2' -AccessName 'Grp2' -AccessType 'ENTITLEMENT' `
            -NativeIdentity 'CN=a' -SourceId 'src-2' -SourceName 'AD' `
            -Decision 'APPROVE' -Comment 'idNowAutoApproved' -ReviewedBy $null -DecisionDate '2026-06-30'
        $s = Resolve-SPSeriesItemState -Item $auto
        $s.HonestDecision    | Should -Be 'Undecided'
        $s.IsGenuineApproval | Should -BeFalse
        $s.IsGenuineDecision | Should -BeFalse
        $s.IsAutoApproved    | Should -BeTrue
    }
}

Describe 'SIS-09 null decision' {
    It 'classifies a null-decision item as Undecided' {
        $s = Resolve-SPSeriesItemState -Item $script:entB
        $s.HonestDecision    | Should -Be 'Undecided'
        $s.IsGenuineApproval | Should -BeFalse
        $s.IsGenuineDecision | Should -BeFalse
        $s.IsAutoApproved    | Should -BeFalse
    }
}

Describe 'SIS-10 roster attribution for undecided item' {
    It 'attributes an undecided item with null reviewedBy to the cert-ASSIGNED roster reviewer' {
        $roster = @(
            [PSCustomObject]@{ CertificationId = 'certB'; ReviewerName = 'Carol Cert'; ReviewerId = 'rv-carol'; ReviewerEmail = 'carol@x.io' }
        )
        $s = Resolve-SPSeriesItemState -Item $script:entB -CertificationId 'certB' -Roster $roster
        $s.HonestDecision  | Should -Be 'Undecided'
        $s.ReviewerName     | Should -Be 'Carol Cert'
        $s.ReviewerId       | Should -Be 'rv-carol'
        $s.ReviewerEmail    | Should -Be 'carol@x.io'
        $s.ReviewerSource   | Should -Be 'roster'
    }
    It 'derives CertificationId from the wrapper when -CertificationId is omitted' {
        $wrapper = [PSCustomObject]@{ Item = $script:entB; CertificationId = 'certB'; CertificationName = 'C'; CampaignName = 'X' }
        $roster = @([PSCustomObject]@{ CertificationId = 'certB'; ReviewerName = 'Carol Cert'; ReviewerId = 'rv-carol'; ReviewerEmail = 'carol@x.io' })
        $s = Resolve-SPSeriesItemState -Item $wrapper -Roster $roster
        $s.CertificationId | Should -Be 'certB'
        $s.ReviewerSource  | Should -Be 'roster'
    }
}

Describe 'SIS-11 unassigned when no roster and no reviewedBy' {
    It 'returns (Unassigned)/source none and never fabricates a reviewer for an undecided null-reviewedBy item' {
        $s = Resolve-SPSeriesItemState -Item $script:entB -CertificationId 'certB' -Roster @()
        $s.ReviewerName   | Should -Be '(Unassigned)'
        $s.ReviewerSource | Should -Be 'none'
        $s.ReviewerId     | Should -Be ''
        $s.ReviewerEmail  | Should -Be ''
        # confirm the fixture genuinely has a null reviewedBy (so nothing could have been read)
        $script:entB.reviewedBy | Should -BeNullOrEmpty
    }
}

Describe 'SIS-12 item reviewedBy fallback for a decided item' {
    It 'falls back to item.reviewedBy when present and no roster entry matches' {
        $s = Resolve-SPSeriesItemState -Item $script:entA -CertificationId 'certA' -Roster @()
        $s.ReviewerName   | Should -Be 'Bob Boss'
        $s.ReviewerId     | Should -Be 'rv-bob'
        $s.ReviewerEmail  | Should -Be 'bob@x.io'
        $s.ReviewerSource | Should -Be 'item'
    }
}

Describe 'SIS-13 Unverified provenance' {
    It 'propagates Unverified $true to the output' {
        $s = Resolve-SPSeriesItemState -Item $script:entA -CertificationId 'certA' -Unverified $true
        $s.Unverified | Should -BeTrue
    }
    It 'defaults Unverified to $false' {
        $s = Resolve-SPSeriesItemState -Item $script:entA -CertificationId 'certA'
        $s.Unverified | Should -BeFalse
    }
}
