#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for completion-definition consistency (WI-6 / G4).
.DESCRIPTION
    Proves the two completion paths agree on a force-completed campaign:
        PATH A (honest)  - Group-SPAuditDecisions  (decided vs pending buckets)
        PATH B (metrics) - Measure-SPCampaignMetrics (ApprovedCount / RevokedCount /
                           PendingCount / CompletionRate)

    Before WI-6, Measure-SPCampaignMetrics used a divergent inline switch that:
      - counted ISC force-sign 'idNowAutoApproved' APPROVEs as COMPLETE (should be pending),
      - lumped CERTIFY (a real approve) into pending,
      - lumped DENY / REJECT / EXCEPTION (real revokes) into pending.
    Both paths now share ConvertTo-SPCanonicalDecision, so they must agree item-for-item.

    Decision-set / expected (honest) classification:
        APPROVE                         -> Approved
        CERTIFY                         -> Approved
        REVOKE                          -> Revoked
        DENY                            -> Revoked
        EXCEPTION                       -> Revoked
        APPROVE + 'idNowAutoApproved'   -> Pending  (force-sign lie)
        null                            -> Pending
      => decided = 5, pending = 2, total = 7

    Assertions are derived from the LIVE honest counts ($g) so the test stays robust
    if the shared set changes.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit

    # ONE shared force-completed raw-item set covering every divergent case.
    $script:RawItems = @(
        [PSCustomObject]@{ decision = 'APPROVE' }
        [PSCustomObject]@{ decision = 'CERTIFY' }
        [PSCustomObject]@{ decision = 'REVOKE' }
        [PSCustomObject]@{ decision = 'DENY' }
        [PSCustomObject]@{ decision = 'EXCEPTION' }
        [PSCustomObject]@{ decision = 'APPROVE'; comment = 'idNowAutoApproved' }
        [PSCustomObject]@{ decision = $null }
    )
}

# ---------------------------------------------------------------------------
#region CC-001: Honest path vs metrics path agree on a force-completed campaign
# ---------------------------------------------------------------------------

Describe "CC-001: Completion-definition consistency (WI-6 / G4)" {

    Context "When a force-completed campaign mixes APPROVE/CERTIFY/REVOKE/DENY/EXCEPTION/auto-approve/null" {

        BeforeEach {
            Mock Write-SPLog -ModuleName SP.AuditReportCore { }

            Mock Measure-SPAuditReviewerMetrics -ModuleName SP.AuditReportCore {
                return @{
                    ReviewerMetrics     = @()
                    CampaignMinHours    = $null
                    CampaignMaxHours    = $null
                    CampaignAvgHours    = $null
                    CampaignMedianHours = $null
                }
            }

            Mock Get-SPAuditCertifications -ModuleName SP.AuditReportCore {
                return @{
                    Success = $true
                    Data    = @(
                        [PSCustomObject]@{
                            id                     = 'cert-1'
                            EffectiveReviewer      = [PSCustomObject]@{ id = 'm1'; displayName = 'M' }
                            ReviewerClassification = 'Primary'
                            created                = '2026-05-01T10:00:00Z'
                            signed                 = '2026-05-02T08:00:00Z'
                        }
                    )
                    Error   = $null
                }
            }

            Mock Get-SPAuditCertificationItems -ModuleName SP.AuditReportCore {
                return @{
                    Success = $true
                    Data    = $script:RawItems
                    Error   = $null
                }
            }
        }

        It "Both paths agree on decided / pending / completion-rate" {
            # PATH A (honest): wrap each raw item in the shape Group-SPAuditDecisions consumes.
            $wrapped = foreach ($raw in $script:RawItems) {
                [PSCustomObject]@{
                    Item              = $raw
                    CertificationId   = 'cert-1'
                    CertificationName = 'c'
                    CampaignName      = 'camp'
                }
            }
            $g = Group-SPAuditDecisions -Items $wrapped

            $honestDecided = $g.Approved.Count + $g.Revoked.Count
            $honestPending = $g.Pending.Count
            $total         = $script:RawItems.Count

            # Sanity on the honest path itself (derived, not hard-coded beyond the documented set).
            $honestDecided | Should -Be 5
            $honestPending | Should -Be 2
            $total         | Should -Be 7

            # PATH B (metrics): same raw items via the public Measure path.
            $campaign = [PSCustomObject]@{
                id      = 'camp'
                name    = 'c'
                type    = 'MANAGER'
                status  = 'COMPLETED'
                created = '2026-05-01T10:00:00Z'
            }
            $m = Measure-SPCampaignMetrics -Campaigns @($campaign)

            $m.Success         | Should -Be $true
            $m.Data.Count      | Should -Be 1
            $m.Data[0].TotalItems | Should -Be $total

            # Core of the item: the two paths AGREE.
            ($m.Data[0].ApprovedCount + $m.Data[0].RevokedCount) | Should -Be $honestDecided
            $m.Data[0].PendingCount | Should -Be $honestPending

            $expectedRate = [Math]::Round(($honestDecided / $total) * 100, 1)
            $m.Data[0].CompletionRate | Should -Be $expectedRate
        }

        It "Counts the idNowAutoApproved force-sign item as PENDING in BOTH paths" {
            $wrapped = foreach ($raw in $script:RawItems) {
                [PSCustomObject]@{
                    Item              = $raw
                    CertificationId   = 'cert-1'
                    CertificationName = 'c'
                    CampaignName      = 'camp'
                }
            }
            $g = Group-SPAuditDecisions -Items $wrapped

            # Honest path: the two pending items are the auto-approve lie + the null decision.
            $g.Pending.Count | Should -Be 2

            $campaign = [PSCustomObject]@{
                id      = 'camp'
                name    = 'c'
                type    = 'MANAGER'
                status  = 'COMPLETED'
                created = '2026-05-01T10:00:00Z'
            }
            $m = Measure-SPCampaignMetrics -Campaigns @($campaign)

            # Metrics path: PendingCount includes the force-sign lie + null, NOT CERTIFY/DENY/EXCEPTION.
            $m.Data[0].PendingCount  | Should -Be 2
            # CERTIFY counts as a real approve; DENY/EXCEPTION as real revokes => decided = 5.
            ($m.Data[0].ApprovedCount + $m.Data[0].RevokedCount) | Should -Be 5
        }

        It "Stamps the metrics output as the HonestClassifier number of record" {
            $campaign = [PSCustomObject]@{
                id      = 'camp'
                name    = 'c'
                type    = 'MANAGER'
                status  = 'COMPLETED'
                created = '2026-05-01T10:00:00Z'
            }
            $m = Measure-SPCampaignMetrics -Campaigns @($campaign)
            $m.Data[0].CompletionBasis | Should -Be 'HonestClassifier'
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CC-002: ConvertTo-SPCanonicalDecision direct unit coverage
# ---------------------------------------------------------------------------

Describe "CC-002: ConvertTo-SPCanonicalDecision shared classifier" {

    It "Maps '<Decision>' (justification '<Justification>') to '<Expected>'" -ForEach @(
        @{ Decision = 'APPROVE';   Justification = '';                  Expected = 'Approved' }
        @{ Decision = 'APPROVED';  Justification = '';                  Expected = 'Approved' }
        @{ Decision = 'CERTIFY';   Justification = '';                  Expected = 'Approved' }
        @{ Decision = 'approve';   Justification = '';                  Expected = 'Approved' }
        @{ Decision = 'APPROVE';   Justification = 'idNowAutoApproved'; Expected = 'Pending'  }
        @{ Decision = 'REVOKE';    Justification = '';                  Expected = 'Revoked'  }
        @{ Decision = 'REVOKED';   Justification = '';                  Expected = 'Revoked'  }
        @{ Decision = 'DENY';      Justification = '';                  Expected = 'Revoked'  }
        @{ Decision = 'REJECT';    Justification = '';                  Expected = 'Revoked'  }
        @{ Decision = 'EXCEPTION'; Justification = '';                  Expected = 'Revoked'  }
        @{ Decision = '';          Justification = '';                  Expected = 'Pending'  }
        @{ Decision = $null;       Justification = '';                  Expected = 'Pending'  }
        @{ Decision = 'UNDECIDED'; Justification = '';                  Expected = 'Pending'  }
    ) {
        ConvertTo-SPCanonicalDecision -Decision $Decision -Justification $Justification | Should -Be $Expected
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CC-003: Get-SPClosedIncompleteQualifier honest closed-incomplete signal
# ---------------------------------------------------------------------------

Describe "CC-003: Get-SPClosedIncompleteQualifier (closed-incomplete signal)" {

    It "COMPLETED 2/3 signed + 4 undecided => closed-incomplete with exact caption" {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 2 -ReviewersTotal 3 -UndecidedCount 4
        $q.IsClosedIncomplete | Should -Be $true
        $q.Caption | Should -Be 'Closed with incomplete work - 2 of 3 reviewers signed off, 4 items never manually decided'
    }

    It "COMPLETED 3/3 signed + 0 undecided => clean (not closed-incomplete, empty caption)" {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 3 -ReviewersTotal 3 -UndecidedCount 0
        $q.IsClosedIncomplete | Should -Be $false
        $q.Caption | Should -Be ''
    }

    It "COMPLETING 3/3 signed + 1 undecided => closed-incomplete (items-only)" {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETING' -ReviewersSigned 3 -ReviewersTotal 3 -UndecidedCount 1
        $q.IsClosedIncomplete | Should -Be $true
    }

    It "COMPLETED 1/3 signed + 0 undecided => closed-incomplete (reviewer-only)" {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 1 -ReviewersTotal 3 -UndecidedCount 0
        $q.IsClosedIncomplete | Should -Be $true
    }

    It "ACTIVE 0/3 signed + 5 undecided => NOT closed-incomplete (campaign still open)" {
        $q = Get-SPClosedIncompleteQualifier -Status 'ACTIVE' -ReviewersSigned 0 -ReviewersTotal 3 -UndecidedCount 5
        $q.IsClosedIncomplete | Should -Be $false
        $q.Caption | Should -Be ''
    }

    It "COMPLETED with 0 reviewers total + 0 undecided => NOT closed-incomplete" {
        $q = Get-SPClosedIncompleteQualifier -Status 'COMPLETED' -ReviewersSigned 0 -ReviewersTotal 0 -UndecidedCount 0
        $q.IsClosedIncomplete | Should -Be $false
    }
}

#endregion

# ---------------------------------------------------------------------------
#region CC-004: Get-SPReviewerCompletion canonical reviewer-completion figure/format
# ---------------------------------------------------------------------------

Describe "CC-004: Get-SPReviewerCompletion canonical reviewer-completion figure/format" {

    It "Signed 0 / Total 2 => Pct 0 and the three surface labels are consistent (no '-')" {
        $r = Get-SPReviewerCompletion -Signed 0 -Total 2
        $r.Pct           | Should -Be 0
        $r.HasReviewers  | Should -Be $true
        $r.PercentLabel  | Should -Be '0%'
        $r.FractionLabel | Should -Be '0 / 2'
        $r.CombinedLabel | Should -Be '0% (0/2)'
        $r.CombinedLabel | Should -Not -Be '-'
    }

    It "Cross-surface agreement: Section A combined label embeds the KPI % and the exec fraction" {
        $r = Get-SPReviewerCompletion -Signed 0 -Total 2
        # KPI '0%' is the prefix of Section A '0% (0/2)'.
        $r.CombinedLabel.StartsWith($r.PercentLabel) | Should -Be $true
        # Exact form ties KPI/exec/Section A together so they cannot disagree.
        $r.CombinedLabel | Should -Be '0% (0/2)'
    }

    It "Signed 2 / Total 2 => 100% green, exact labels" {
        $r = Get-SPReviewerCompletion -Signed 2 -Total 2
        $r.Pct           | Should -Be 100
        $r.SeverityClass | Should -Be 'green'
        $r.PercentLabel  | Should -Be '100%'
        $r.CombinedLabel | Should -Be '100% (2/2)'
    }

    It "Signed 1 / Total 2 => 50% amber" {
        $r = Get-SPReviewerCompletion -Signed 1 -Total 2
        $r.Pct           | Should -Be 50
        $r.SeverityClass | Should -Be 'amber'
    }

    It "Total 0 => no reviewers, Pct 0, severity 'none' (no divide-by-zero)" {
        $r = Get-SPReviewerCompletion -Signed 0 -Total 0
        $r.HasReviewers  | Should -Be $false
        $r.Pct           | Should -Be 0
        $r.SeverityClass | Should -Be 'none'
    }
}

#endregion

#region CC-005: Get-SPForceSignedReviewerCount excludes admin force-close from genuine sign-off
# ---------------------------------------------------------------------------

Describe "CC-005: Get-SPForceSignedReviewerCount (genuine sign-off vs admin force-close)" {

    It "Counts a force-signed reviewer (signedBy.id != reviewer.id) as NOT a genuine sign-off" {
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-ch-rv-011'; ReviewerName = 'Quinn ForceSigned'; SignedById = 'id-ch-admin-001' }
            [pscustomobject]@{ ReviewerId = 'id-ch-rv-012'; ReviewerName = 'Rita Undecided';    SignedById = 'id-ch-admin-001' }
        )
        Get-SPForceSignedReviewerCount -Roster $roster | Should -Be 2
    }

    It "The faithful force-close render: Phase-based signed (2) minus force-signed (2) => genuine 0/2 (0%)" {
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-ch-rv-011'; ReviewerName = 'Quinn ForceSigned'; SignedById = 'id-ch-admin-001' }
            [pscustomobject]@{ ReviewerId = 'id-ch-rv-012'; ReviewerName = 'Rita Undecided';    SignedById = 'id-ch-admin-001' }
        )
        $signedPhase = 2   # both certs read Phase=SIGNED (the ISC force-sign lie)
        $force = Get-SPForceSignedReviewerCount -Roster $roster
        $genuine = [math]::Max(0, $signedPhase - $force)
        $rvc = Get-SPReviewerCompletion -Signed $genuine -Total 2
        $rvc.FractionLabel | Should -Be '0 / 2'
        $rvc.PercentLabel  | Should -Be '0%'
        $rvc.CombinedLabel | Should -Be '0% (0/2)'
        $rvc.SeverityClass | Should -Be 'red'
    }

    It "A genuine manual sign-off (signedBy.id == reviewer.id) is NOT counted as force-signed" {
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-rv-1'; ReviewerName = 'Alice'; SignedById = 'id-rv-1' }
            [pscustomobject]@{ ReviewerId = 'id-rv-2'; ReviewerName = 'Bob';   SignedById = 'id-rv-2' }
        )
        Get-SPForceSignedReviewerCount -Roster $roster | Should -Be 0
    }

    It "An indeterminate roster (empty SignedById) is NOT positive force-close evidence => 0" {
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-rv-1'; ReviewerName = 'Alice'; SignedById = '' }
            [pscustomobject]@{ ReviewerId = 'id-rv-2'; ReviewerName = 'Bob' }
        )
        Get-SPForceSignedReviewerCount -Roster $roster | Should -Be 0
    }

    It "A reviewer with several force-signed certs is counted ONCE (distinct by ReviewerId)" {
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-rv-1'; ReviewerName = 'Alice'; SignedById = 'id-admin' }
            [pscustomobject]@{ ReviewerId = 'id-rv-1'; ReviewerName = 'Alice'; SignedById = 'id-admin' }
        )
        Get-SPForceSignedReviewerCount -Roster $roster | Should -Be 1
    }

    It "Null / empty roster => 0 (no throw)" {
        Get-SPForceSignedReviewerCount -Roster $null | Should -Be 0
        Get-SPForceSignedReviewerCount -Roster @()   | Should -Be 0
    }
}

#endregion

#region CC-006: Sealed-while-active force-close -- provenance enrichment un-defeats the correction
# ---------------------------------------------------------------------------

Describe "CC-006: Resolve-SPRosterSignOffProvenance (sealed force-close gap)" {

    BeforeAll {
        $script:ChDir6    = Join-Path (Join-Path $PSScriptRoot 'TestData') 'CacheHonesty'
        $script:Fixtures6 = Get-Content (Join-Path $ChDir6 'mock-fixtures.json') -Raw | ConvertFrom-Json

        # The two LIVE (post-close) force-signed certs for camp-ch-forceclose-001: both read
        # phase SIGNED with signedBy = the admin (id != reviewer.id).
        $script:LiveCerts6 = @($Fixtures6.certifications | Where-Object { $_.campaign.id -eq 'camp-ch-forceclose-001' })

        # A faithful ACTIVE-state SEAL: same certs, but captured BEFORE sign-off, so SignedById
        # is '' (indeterminate) -- exactly the roster Get-SPCachedCampaignRoster prefers.
        $script:SealedRoster6 = foreach ($c in $LiveCerts6) {
            [pscustomobject]@{
                CertificationId   = $c.id
                CertificationName = $c.name
                ReviewerName      = $c.reviewer.name
                ReviewerId        = $c.reviewer.id
                ReviewerEmail     = ''
                Classification    = 'Primary'
                SignedById        = ''   # captured while ACTIVE -> no sign-off yet
                SignedByName      = ''
            }
        }
        $script:SealedRoster6 = @($SealedRoster6)
    }

    It "Reproduces the gap: the raw SEALED roster (SignedById='') yields force-signed 0 (correction inert)" {
        Get-SPForceSignedReviewerCount -Roster $SealedRoster6 | Should -Be 0
    }

    It "Enrichment stamps the live admin signedBy onto the sealed entries, keeping the ASSIGNED reviewer" {
        $enriched = Resolve-SPRosterSignOffProvenance -Roster $SealedRoster6 -Certifications $LiveCerts6
        @($enriched).Count | Should -Be 2
        foreach ($e in $enriched) {
            $e.SignedById   | Should -Be 'id-ch-admin-001'
            $e.SignedByName | Should -Be 'System ForceClose'
        }
        # ASSIGNED reviewer is preserved from the seal (NOT overwritten by the admin).
        @($enriched | Where-Object { $_.ReviewerId -eq 'id-ch-rv-011' }).Count | Should -Be 1
        @($enriched | Where-Object { $_.ReviewerId -eq 'id-ch-rv-012' }).Count | Should -Be 1
    }

    It "After enrichment the genuine-sign-off correction works on the sealed path: force-signed 2 => genuine 0/2" {
        $enriched = Resolve-SPRosterSignOffProvenance -Roster $SealedRoster6 -Certifications $LiveCerts6
        $force    = Get-SPForceSignedReviewerCount -Roster $enriched
        $force | Should -Be 2
        $genuine = [math]::Max(0, 2 - $force)   # Phase-based SIGNED tally is 2 (ISC force-sign lie)
        $rvc = Get-SPReviewerCompletion -Signed $genuine -Total 2
        $rvc.CombinedLabel | Should -Be '0% (0/2)'
        $rvc.SeverityClass | Should -Be 'red'
    }

    It "End-to-end via Get-SPCachedCampaignRoster: a SEALED roster file on disk + enrichment corrects the count" {
        # Write a faithful sealed roster file (lacking signedBy) into an isolated cache dir.
        $sealFile = Join-Path $TestDrive 'roster-camp-ch-forceclose-001.json'
        ([pscustomobject]@{ CapturedWhileActive = $true; Entries = $SealedRoster6 } |
            ConvertTo-Json -Depth 6) | Set-Content $sealFile -Encoding UTF8

        $camp = $Fixtures6.campaigns | Where-Object { $_.id -eq 'camp-ch-forceclose-001' }
        $res  = Get-SPCachedCampaignRoster -Campaign $camp -Certifications $LiveCerts6 -CachePath $TestDrive
        $res.Success | Should -BeTrue
        $res.Sealed  | Should -BeTrue -Because "the on-disk seal must be preferred over live certs"

        # Sealed roster as-read is indeterminate -> the correction would be inert...
        Get-SPForceSignedReviewerCount -Roster @($res.Data) | Should -Be 0
        # ...until we stamp provenance from the live certs (exactly what V4/V4b now do).
        $enriched = Resolve-SPRosterSignOffProvenance -Roster @($res.Data) -Certifications $LiveCerts6
        Get-SPForceSignedReviewerCount -Roster $enriched | Should -Be 2
    }

    It "A genuine manual sign-off survives enrichment as NOT force-signed (signedBy.id == reviewer.id)" {
        $genuineCert = [pscustomobject]@{
            id       = 'cert-genuine-1'
            reviewer = [pscustomobject]@{ id = 'id-rv-genuine'; name = 'Grace Genuine' }
            signedBy = [pscustomobject]@{ id = 'id-rv-genuine'; name = 'Grace Genuine' }
        }
        $sealed = @([pscustomobject]@{ CertificationId = 'cert-genuine-1'; ReviewerId = 'id-rv-genuine'; ReviewerName = 'Grace Genuine'; SignedById = '' })
        $enriched = Resolve-SPRosterSignOffProvenance -Roster $sealed -Certifications @($genuineCert)
        $enriched[0].SignedById | Should -Be 'id-rv-genuine'
        Get-SPForceSignedReviewerCount -Roster $enriched | Should -Be 0
    }

    It "Does NOT override provenance already present, and does not mutate the input roster" {
        $live   = @([pscustomobject]@{ id = 'cert-x'; signedBy = [pscustomobject]@{ id = 'id-admin'; name = 'Admin' } })
        $sealed = @([pscustomobject]@{ CertificationId = 'cert-x'; ReviewerId = 'id-rv-x'; ReviewerName = 'X'; SignedById = 'id-rv-x'; SignedByName = 'X' })
        $enriched = Resolve-SPRosterSignOffProvenance -Roster $sealed -Certifications $live
        $enriched[0].SignedById | Should -Be 'id-rv-x' -Because "existing provenance must be preserved, not overwritten"
        $sealed[0].SignedById   | Should -Be 'id-rv-x' -Because "the input roster must not be mutated"
    }

    It "No live certs / no match => roster returned unchanged (still indeterminate, no false positive)" {
        (Resolve-SPRosterSignOffProvenance -Roster $SealedRoster6 -Certifications @()).Count | Should -Be 2
        Get-SPForceSignedReviewerCount -Roster (Resolve-SPRosterSignOffProvenance -Roster $SealedRoster6 -Certifications @()) | Should -Be 0
        Resolve-SPRosterSignOffProvenance -Roster $null -Certifications $LiveCerts6 | Should -BeNullOrEmpty
    }
}

#endregion

#region CC-007: Get-SPDistinctReviewerSignOff -- multi-cert reassigned reviewer over-statement
# ---------------------------------------------------------------------------

Describe "CC-007: Get-SPDistinctReviewerSignOff (per-cert reassigned over-statement)" {

    It "Counts a delegate holding 2 force-signed REASSIGNED certs ONCE (distinct), not per-cert" {
        # Group-SPReviewerActions emits ONE Reassigned entry PER CERT, so the same delegate
        # appears twice (both Phase=SIGNED at a force-close).
        $allRevw = @(
            [pscustomobject]@{ Name = 'Dana Delegate'; Email = 'dana@x'; Phase = 'SIGNED' }
            [pscustomobject]@{ Name = 'Dana Delegate'; Email = 'dana@x'; Phase = 'SIGNED' }
        )
        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $so.Total  | Should -Be 1
        $so.Signed | Should -Be 1
    }

    It "End-to-end honesty: 2 force-signed reassigned certs => genuine 0/1 (0%), NOT the old 50%" {
        # The render: Phase-based distinct signed = 1, force-signed (distinct by ReviewerId) = 1.
        $allRevw = @(
            [pscustomobject]@{ Name = 'Dana Delegate'; Email = 'dana@x'; Phase = 'SIGNED' }
            [pscustomobject]@{ Name = 'Dana Delegate'; Email = 'dana@x'; Phase = 'SIGNED' }
        )
        $roster = @(
            [pscustomobject]@{ ReviewerId = 'id-dana'; ReviewerName = 'Dana Delegate'; SignedById = 'id-admin'; CertificationId = 'cert-a' }
            [pscustomobject]@{ ReviewerId = 'id-dana'; ReviewerName = 'Dana Delegate'; SignedById = 'id-admin'; CertificationId = 'cert-b' }
        )
        $so    = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $force = Get-SPForceSignedReviewerCount -Roster $roster
        $force | Should -Be 1
        $genuine = [math]::Max(0, $so.Signed - $force)
        $rvc = Get-SPReviewerCompletion -Signed $genuine -Total $so.Total
        $rvc.CombinedLabel | Should -Be '0% (0/1)'
        $rvc.PercentLabel  | Should -Be '0%'
        $rvc.SeverityClass | Should -Be 'red'
    }

    It "Regression guard: the OLD per-cert tally would have over-stated this to 50%" {
        # Documents the defect this fix closes: raw per-cert signed = 2, force-signed distinct = 1,
        # corrected = 1 over per-cert total = 2 => 50%, while the distinct path honestly reads 0%.
        $allRevw = @(
            [pscustomobject]@{ Name = 'Dana Delegate'; Phase = 'SIGNED' }
            [pscustomobject]@{ Name = 'Dana Delegate'; Phase = 'SIGNED' }
        )
        $perCertSigned = @($allRevw | Where-Object { $_.Phase -eq 'SIGNED' }).Count
        $perCertTotal  = @($allRevw).Count
        $force = 1
        $oldPct = [math]::Round([math]::Max(0, $perCertSigned - $force) / $perCertTotal * 100, 0)
        $oldPct | Should -Be 50 -Because "this is the over-statement being eliminated"

        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $newPct = (Get-SPReviewerCompletion -Signed ([math]::Max(0, $so.Signed - $force)) -Total $so.Total).Pct
        $newPct | Should -Be 0 -Because "the distinct-by-reviewer basis is honest"
    }

    It "A genuinely-signed primary reviewer is preserved (distinct signed 1 / total 1)" {
        $allRevw = @( [pscustomobject]@{ Name = 'Pat Primary'; Phase = 'SIGNED' } )
        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $so.Signed | Should -Be 1
        $so.Total  | Should -Be 1
    }

    It "Two DISTINCT reviewers are not merged; only the SIGNED one counts as signed" {
        $allRevw = @(
            [pscustomobject]@{ Name = 'Alice'; Phase = 'SIGNED' }
            [pscustomobject]@{ Name = 'Bob';   Phase = 'REVIEW' }
        )
        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $so.Total  | Should -Be 2
        $so.Signed | Should -Be 1
    }

    It "camp-ch-forceclose-001 shape (two Primary, single cert each) is byte-for-byte unchanged" {
        # Primary reviewers are already name-aggregated (one entry each) => distinct == per-cert.
        $allRevw = @(
            [pscustomobject]@{ Name = 'Quinn ForceSigned'; Phase = 'SIGNED' }
            [pscustomobject]@{ Name = 'Rita Undecided';    Phase = 'SIGNED' }
        )
        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $so.Signed | Should -Be (@($allRevw | Where-Object { $_.Phase -eq 'SIGNED' }).Count)
        $so.Total  | Should -Be (@($allRevw).Count)
    }

    It "ReviewerId (when present) trumps a shared display Name -- two same-named people stay distinct" {
        $allRevw = @(
            [pscustomobject]@{ ReviewerId = 'id-1'; Name = 'Sam Smith'; Phase = 'SIGNED' }
            [pscustomobject]@{ ReviewerId = 'id-2'; Name = 'Sam Smith'; Phase = 'REVIEW' }
        )
        $so = Get-SPDistinctReviewerSignOff -Reviewers $allRevw
        $so.Total  | Should -Be 2
        $so.Signed | Should -Be 1
    }

    It "Null / empty list => Signed 0 / Total 0 (no throw)" {
        $a = Get-SPDistinctReviewerSignOff -Reviewers $null
        $a.Signed | Should -Be 0
        $a.Total  | Should -Be 0
        $b = Get-SPDistinctReviewerSignOff -Reviewers @()
        $b.Signed | Should -Be 0
        $b.Total  | Should -Be 0
    }
}

#endregion
