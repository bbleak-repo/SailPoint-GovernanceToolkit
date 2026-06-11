<#
.SYNOPSIS
    Unit tests for source-aware revocation disposition -- a completed REVOKE is only counted
    as "Deprovisioned" on a connected Active Directory source; on any other source it is
    "Queued for removal" (recorded, not confirmed). Covers the classifier, the two data
    producers (Group-SPAuditDecisions / Group-SPAuditRemediationProof), the snapshot KPI
    split, and the evidence-pack render.

    SAR-01: Get-SPRevocationDisposition + Test-SPConnectedADSource
    SAR-02: Group-SPAuditDecisions stamps SourceType + RemediationDisposition
    SAR-03: Group-SPAuditRemediationProof splits removed vs queued counts
    SAR-04: Build-SPCampaignSnapshotData KPI RemediationRemoved/Queued split
    SAR-05: Attestation evidence pack renders Deprovisioned vs Queued for removal
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Core -Api -Audit -DeltaCert

    # A wrapped raw-ISC revoke item (the shape Group-SPAuditDecisions/Proof consume).
    function New-SARRevoke {
        param([string]$Id, [string]$Name, [string]$SourceName, [string]$SourceType, [bool]$Completed)
        @{
            CertificationId = 'c1'; CertificationName = 'C'; CampaignName = 'Camp'
            Item = [PSCustomObject]@{
                id              = $Id
                decision        = 'REVOKE'
                completed       = $Completed
                modified        = '2026-06-10T14:30:00Z'
                sourceName      = $SourceName
                sourceType      = $SourceType
                identitySummary = [PSCustomObject]@{ id = $Id; identityId = $Id; name = $Name }
                accessSummary   = [PSCustomObject]@{ access = [PSCustomObject]@{ id = "e-$Id"; type = 'ENTITLEMENT'; name = 'AD-DomainAdmins' } }
            }
        }
    }
}

Describe "SAR-01: revocation-disposition classifier" {
    It "treats a completed revoke on connected AD as Deprovisioned (removed)" {
        $d = Get-SPRevocationDisposition -Decision 'REVOKE' -Completed $true -SourceType 'Active Directory - Direct' -SourceName 'Prod AD'
        $d.Disposition  | Should -Be 'Removed'
        $d.Label        | Should -Be 'Deprovisioned'
        $d.IsRemoved    | Should -Be $true
    }
    It "treats a completed revoke on a non-AD source as Queued for removal" {
        $d = Get-SPRevocationDisposition -Decision 'REVOKE' -Completed $true -SourceType 'Web Services - Disconnected' -SourceName 'LegacyApp'
        $d.Disposition | Should -Be 'Queued'
        $d.Label       | Should -Be 'Queued for removal'
        $d.IsQueued    | Should -Be $true
    }
    It "treats a not-completed revoke as Pending removal regardless of source" {
        (Get-SPRevocationDisposition -Decision 'REVOKE' -Completed $false -SourceType 'Active Directory' -SourceName 'AD').Disposition | Should -Be 'Pending'
    }
    It "returns NA for a non-revoke decision" {
        (Get-SPRevocationDisposition -Decision 'APPROVE' -Completed $true -SourceType 'Active Directory' -SourceName 'AD').Disposition | Should -Be 'NA'
    }
    It "falls back to the source NAME only when sourceType is absent" {
        Test-SPConnectedADSource -SourceType '' -SourceName 'Corp Active Directory' | Should -Be $true
        Test-SPConnectedADSource -SourceType '' -SourceName 'ServiceNow'            | Should -Be $false
    }
    It "trusts sourceType over a misleading name (non-AD type wins even if name says AD)" {
        Test-SPConnectedADSource -SourceType 'ServiceNow' -SourceName 'SNOW Active Directory bridge' | Should -Be $false
    }
}

Describe "SAR-02: Group-SPAuditDecisions stamps SourceType + disposition" {
    BeforeEach { Mock Write-SPLog -ModuleName SP.AuditReportCore { } }

    It "stamps Deprovisioned for a completed AD revoke" {
        $res = Group-SPAuditDecisions -Items @(New-SARRevoke -Id 'i1' -Name 'U1' -SourceName 'Prod AD' -SourceType 'Active Directory - Direct' -Completed $true)
        $d = @($res.Revoked)[0]
        $d.SourceType             | Should -Be 'Active Directory - Direct'
        $d.RemediationDisposition | Should -Be 'Removed'
        $d.RemediationLabel       | Should -Be 'Deprovisioned'
    }
    It "stamps Queued for a completed disconnected revoke" {
        $res = Group-SPAuditDecisions -Items @(New-SARRevoke -Id 'i2' -Name 'U2' -SourceName 'LegacyApp' -SourceType 'Web Services - Disconnected' -Completed $true)
        $d = @($res.Revoked)[0]
        $d.RemediationDisposition | Should -Be 'Queued'
        $d.RemediationLabel       | Should -Be 'Queued for removal'
    }
    It "stamps Pending for a not-completed AD revoke" {
        $res = Group-SPAuditDecisions -Items @(New-SARRevoke -Id 'i3' -Name 'U3' -SourceName 'Prod AD' -SourceType 'Active Directory - Direct' -Completed $false)
        $d = @($res.Revoked)[0]
        $d.RemediationDisposition | Should -Be 'Pending'
    }
}

Describe "SAR-03: Group-SPAuditRemediationProof splits removed vs queued" {
    BeforeEach { Mock Write-SPLog -ModuleName SP.AuditReportCore { } }

    It "counts only connected-AD completed revokes as removed; non-AD completed as queued" {
        $items = @(
            (New-SARRevoke -Id 'a' -Name 'A' -SourceName 'Prod AD'  -SourceType 'Active Directory - Direct'   -Completed $true)
            (New-SARRevoke -Id 'b' -Name 'B' -SourceName 'LegacyApp' -SourceType 'Web Services - Disconnected' -Completed $true)
            (New-SARRevoke -Id 'c' -Name 'C' -SourceName 'Prod AD'  -SourceType 'Active Directory - Direct'   -Completed $false)
        )
        $proof = Group-SPAuditRemediationProof -Items $items -Certifications @()
        $proof.TotalRevoked             | Should -Be 3
        $proof.RemediationRemovedCount  | Should -Be 1
        $proof.RemediationQueuedCount   | Should -Be 1
        $proof.RemediationPendingCount  | Should -Be 1
        # back-compat: "complete" still counts every finalised revoke (removed + queued)
        $proof.RemediationCompleteCount | Should -Be 2
    }
}

Describe "SAR-04: snapshot KPI splits RemediationRemoved / RemediationQueued" {
    It "buckets completed revokes by source on the campaign snapshot" {
        $camp = [PSCustomObject]@{ id = 'c1'; name = 'Q'; status = 'ACTIVE'; created = '2026-06-10T10:00:00Z' }
        $dec = @{ Approved = @(); Pending = @(); Revoked = @(
            [PSCustomObject]@{ IdentityId = 'i1'; IdentityName = 'A'; AccessName = 'admin'; AccessId = 'a1'; SourceName = 'Prod AD';  SourceId = 's1'; SourceType = 'Active Directory - Direct';   Decision = 'REVOKE'; RemediationStatus = 'Provisioned'; DecisionDate = '2026-06-10T10:00:00Z' }
            [PSCustomObject]@{ IdentityId = 'i2'; IdentityName = 'B'; AccessName = 'legacy'; AccessId = 'a2'; SourceName = 'LegacyApp'; SourceId = 's2'; SourceType = 'Web Services - Disconnected'; Decision = 'REVOKE'; RemediationStatus = 'Provisioned'; DecisionDate = '2026-06-10T10:00:00Z' }
            [PSCustomObject]@{ IdentityId = 'i3'; IdentityName = 'C'; AccessName = 'vpn';   AccessId = 'a3'; SourceName = 'Prod AD';  SourceId = 's1'; SourceType = 'Active Directory - Direct';   Decision = 'REVOKE'; RemediationStatus = 'Pending';     DecisionDate = '' }
        ) }
        $snap = Build-SPCampaignSnapshotData -Campaign $camp -Certifications @() -Decisions $dec
        $snap.Kpi.RemediationRemoved | Should -Be 1
        $snap.Kpi.RemediationQueued  | Should -Be 1
        $snap.Kpi.RemediationPending | Should -Be 1
        @($snap.Items | Where-Object { $_.IdentityId -eq 'i1' })[0].SourceType | Should -Be 'Active Directory - Direct'
    }
}

Describe "SAR-05: attestation evidence pack renders Deprovisioned vs Queued" {
    It "labels an AD removal Deprovisioned and a disconnected removal Queued for removal" {
        $meta = @{ Id = 'c1'; Name = 'Camp'; Status = 'ACTIVE'; StartDate = '2026-06-09'; DueDate = '2026-06-12'; CapturedAt = '2026-06-10'; ReviewersSigned = 1; ReviewersTotal = 1 }
        $decisions = @{
            Approved = @()
            Pending  = @()
            Revoked  = @(
                [PSCustomObject]@{ IdentityName = 'A'; AccessName = 'admin'; SourceName = 'Prod AD';  SourceType = 'Active Directory - Direct';   ReviewerName = 'Mgr'; Decision = 'REVOKE'; DecisionDate = '2026-06-10T10:00:00Z'; RemediationStatus = 'Provisioned'; RemediationDisposition = 'Removed'; RemediationLabel = 'Deprovisioned'; Privileged = $true }
                [PSCustomObject]@{ IdentityName = 'B'; AccessName = 'legacy'; SourceName = 'LegacyApp'; SourceType = 'Web Services - Disconnected'; ReviewerName = 'Mgr'; Decision = 'REVOKE'; DecisionDate = '2026-06-10T10:00:00Z'; RemediationStatus = 'Provisioned'; RemediationDisposition = 'Queued'; RemediationLabel = 'Queued for removal'; Privileged = $false }
            )
        }
        $out = Join-Path $TestDrive 'sar05-evidence.html'
        $res = Export-SPAttestationEvidenceHtml -CampaignMeta $meta -Decisions $decisions -OutputPath $out
        $res.Success | Should -Be $true
        $html = Get-Content $out -Raw
        $html | Should -Match 'Deprovisioned'
        $html | Should -Match 'Queued for removal'
        $html | Should -Match '1 deprovisioned, 1 queued'
    }
}
