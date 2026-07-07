#Requires -Version 5.1
<#
.SYNOPSIS
    Deterministic generator for the V4c series-attestation END-TO-END fixture:
    an 11-instance "Daily Attestation Manager Campaign - <date>" recurring series.
.DESCRIPTION
    Emits 33 rich-cache files (items-<id>.meta.json + items-<id>.jsonl +
    roster-<id>.json for each of dam-01..dam-11) into -OutputDir, mirroring the
    cache-writing shape of New-CSCacheInstance in SP.CachedCampaignSeries.Tests.ps1:
      - meta is written -Encoding UTF8 (UTF-8 BOM) ON PURPOSE so the reader's
        BOM-safe path is exercised end-to-end;
      - items.jsonl is one wrapped item per line (ConvertTo-Json -Compress -Depth 8);
      - roster.json carries the sealed Entries (cert-ASSIGNED reviewer attribution),
        keyed by the CAMPAIGN id (NOT "<id>-cert") because the V4c CLI passes the
        instance CampaignId as the cert id into Resolve-SPSeriesItemState.

    INTENTIONAL NAME VARIANCES across the 11 instances (spaced hyphen, no-space
    hyphen, en-dash, double-spaced hyphen) MUST still collapse to ONE normalized
    series stem 'daily attestation manager campaign' -- this proves the
    variance-tolerant auto-derivation.

    Chronology: daily dates 2026-06-20 (OrderIndex 0, OLDEST) .. 2026-06-30
    (OrderIndex 10, NEWEST); the reader orders ascending by the ISO date PeriodToken.
    "instance 1" in the item-spec countdown = the NEWEST = OrderIndex 10.

    FOUR static scenario items (present in ALL 11 instances => NewlyInScope = 0):
      1. id-alice + ent-fin-rw : PENDING OI0..9, GENUINE APPROVE (no marker) OI10
         -> NewlyAttested (FirstGenuineApprovalOrderIndex 10).
      2. id-bob   + ent-hr-ro  : PENDING OI0..3, GENUINE APPROVE OI4..10
         -> AlreadyAttestedEarlier (NOT newly attested).
      3. id-carol + ent-vpn    : OI1 APPROVE w/ 'idNowAutoApproved' (auto-approved-
         at-close), PENDING OI0 + OI2..9, GENUINE APPROVE OI10
         -> NewlyAttested + PriorAutoApprovedMasked (the OI1 auto-approve must NOT
            mask the OI10 genuine first approval).
      4. id-dave  + ent-admin  : PENDING in ALL 11 -> PersistentlyUndecided.

    PURE deterministic: same inputs -> byte-identical files (no timestamps beyond
    the fixed dates), so the cache can be committed and re-generated identically.
.PARAMETER OutputDir
    Target cache directory. Created if absent.
#>
param(
    [Parameter(Mandatory)]
    [string]$OutputDir
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# --- Item factory (shape per spec: identitySummary / access{source} / account / decision) --------
function New-SAFItem {
    param(
        [string]$IdentityId, [string]$IdentityName,
        [string]$AccessId, [string]$AccessName,
        [string]$Decision, [string]$Comment, [string]$DecisionDate
    )
    [PSCustomObject]@{
        identitySummary = [PSCustomObject]@{ identityId = $IdentityId; name = $IdentityName }
        access          = [PSCustomObject]@{
            id     = $AccessId
            type   = 'ENTITLEMENT'
            name   = $AccessName
            source = [PSCustomObject]@{ id = 'src-ad'; name = 'Active Directory' }
        }
        account         = [PSCustomObject]@{ nativeIdentity = "CN=$IdentityId"; sourceId = 'src-ad' }
        decision        = $Decision
        comment         = $Comment
        decisionDate    = $DecisionDate
    }
}

# --- Cache writer (mirrors New-CSCacheInstance EXACTLY) ------------------------------------------
function Write-SAFInstance {
    param(
        [string]$Dir, [string]$CampId, [string]$CampName, [string]$Status,
        [string]$CachedAt, [object[]]$Items, [object[]]$RosterEntries
    )
    $safe = $CampId -replace '[^A-Za-z0-9_\-]', '_'
    $meta = [ordered]@{
        CampaignId          = $CampId
        CampaignName        = $CampName
        Status              = $Status
        CachedAt            = $CachedAt
        IsPermanent         = $true
        CapturedWhileActive = $true
        Unverified          = $false
        ItemCount           = @($Items).Count
        CertCount           = @($RosterEntries).Count
    }
    # -Encoding UTF8 writes the UTF-8 BOM on purpose (proves BOM-safe read).
    $meta | ConvertTo-Json | Set-Content (Join-Path $Dir "items-$safe.meta.json") -Encoding UTF8

    $itemsPath = Join-Path $Dir "items-$safe.jsonl"
    $lines = foreach ($it in @($Items)) {
        @{ Item = $it; CertificationId = "$CampId-cert"; CertificationName = "$CampName Cert"; CampaignName = $CampName } | ConvertTo-Json -Compress -Depth 8
    }
    Set-Content -Path $itemsPath -Value $lines -Encoding UTF8

    # Roster CertificationId == CampaignId (the CLI passes instance CampaignId as cert id).
    $roster = [ordered]@{ CampaignId = $CampId; CapturedWhileActive = $true; Entries = @($RosterEntries) }
    $roster | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Dir "roster-$safe.json") -Encoding UTF8
}

# --- Per-OrderIndex name with INTENTIONAL spacing/separator variances ----------------------------
function Get-SAFName {
    param([int]$Oi, [string]$Date)
    $base = 'Daily Attestation Manager Campaign'
    $en = [string][char]0x2013   # en-dash (PS 5.1: match/emit by code point, no backtick-u escape)
    if ($Oi -eq 3) {
        # en-dash variant (stress: en-dash -> hyphen normalization).
        return "$base $en $Date"
    }
    elseif ($Oi -eq 7) {
        # double-spaced hyphen variant (stress: run-of-dash+space -> ' - ').
        return "$base  -  $Date"
    }
    elseif ($Oi % 2 -eq 0) {
        return "$base - $Date"      # even OI: spaced hyphen
    }
    else {
        return "$base -$Date"       # odd OI: NO leading space
    }
}

# --- Per-scenario decision at a given OrderIndex -------------------------------------------------
function Get-SAFDecision {
    param([string]$Scenario, [int]$Oi)
    switch ($Scenario) {
        'alice' { if ($Oi -eq 10) { return @{ D = 'APPROVE'; C = '' } } else { return @{ D = 'PENDING'; C = '' } } }
        'bob'   { if ($Oi -ge 4)  { return @{ D = 'APPROVE'; C = 'reviewed by manager' } } else { return @{ D = 'PENDING'; C = '' } } }
        'carol' {
            if ($Oi -eq 1)  { return @{ D = 'APPROVE'; C = 'idNowAutoApproved' } }   # auto-approved-at-close
            elseif ($Oi -eq 10) { return @{ D = 'APPROVE'; C = '' } }                # genuine first approval
            else { return @{ D = 'PENDING'; C = '' } }
        }
        'dave'  { return @{ D = 'PENDING'; C = '' } }
    }
    return @{ D = 'PENDING'; C = '' }
}

$roster = @(
    [PSCustomObject]@{ ReviewerName = 'Mona Manager'; ReviewerId = 'rv-mona'; ReviewerEmail = 'mona@test.com' }
)

for ($oi = 0; $oi -le 10; $oi++) {
    $day = '{0:D2}' -f (20 + $oi)
    $date = "2026-06-$day"
    $campId = 'dam-{0:D2}' -f ($oi + 1)
    $campName = Get-SAFName -Oi $oi -Date $date
    $cachedAt = "${date}T08:00:00.0000000+00:00"
    $decDate = "${date}T10:00:00Z"

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($s in @(
            @{ K = 'alice'; Id = 'id-alice'; Nm = 'Alice Anders'; Acc = 'ent-fin-rw'; AccNm = 'Finance-RW' },
            @{ K = 'bob';   Id = 'id-bob';   Nm = 'Bob Brown';    Acc = 'ent-hr-ro';  AccNm = 'HR-ReadOnly' },
            @{ K = 'carol'; Id = 'id-carol'; Nm = 'Carol Clark';  Acc = 'ent-vpn';    AccNm = 'VPN-Access' },
            @{ K = 'dave';  Id = 'id-dave';  Nm = 'Dave Davis';   Acc = 'ent-admin';  AccNm = 'Admin-Console' }
        )) {
        $d = Get-SAFDecision -Scenario $s.K -Oi $oi
        $dd = if ($d.D -eq 'APPROVE') { $decDate } else { '' }
        $items.Add((New-SAFItem -IdentityId $s.Id -IdentityName $s.Nm -AccessId $s.Acc -AccessName $s.AccNm `
                    -Decision $d.D -Comment $d.C -DecisionDate $dd))
    }

    # Roster entry CertificationId MUST equal the CampaignId for cert-assigned attribution.
    $rosterEntries = @($roster | ForEach-Object {
            [PSCustomObject]@{
                CertificationId = $campId
                ReviewerName    = $_.ReviewerName
                ReviewerId      = $_.ReviewerId
                ReviewerEmail   = $_.ReviewerEmail
            }
        })

    Write-SAFInstance -Dir $OutputDir -CampId $campId -CampName $campName -Status 'COMPLETED' `
        -CachedAt $cachedAt -Items @($items.ToArray()) -RosterEntries $rosterEntries
}

Write-Host "Series-attestation fixture written: 11 instances (33 files) -> $OutputDir"
