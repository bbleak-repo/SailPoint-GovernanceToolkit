<#
.SYNOPSIS
    SP.CampaignSeries -- recurring-campaign SERIES derivation (the V4c grouping layer).

.DESCRIPTION
    A pure, deterministic helper layer that recognises when several campaigns are
    really the SAME recurring series captured at different points in time (e.g. a
    daily "Access Review - 2026-06-29" / "Access Review - 2026-06-30", or a
    quarterly "Finance Cert - Q1 2026" / "Finance Cert - Q2 2026").

    Get-SPCampaignSeriesKey strips the variable TEMPORAL token from a campaign name
    (ISO date/datetime, quarter, month-year, year-month, week, or a bare trailing
    year) and returns a normalized grouping stem that is ROBUST to the spacing /
    separator / case variances a coworker introduces when naming campaigns by hand.
    So "Campaign - 2026-06-30", "Campaign -2026-06-30", "Campaign-  2026-06-30" and
    "Campaign  -  2026-06-30" ALL collapse to the same series.

    Group-SPCampaignSeries clusters a list of campaign objects by that stem. By
    DEFAULT the grouping is exact-match only -- deterministic and explainable, so it
    can stand as audit evidence. An OPT-IN -SimilarityThreshold enables a second
    consolidation pass that merges near-identical stems (Levenshtein edit distance)
    to absorb genuine typos; it is OFF by default on purpose.

    PURE: no API/IO, no live calls, no GUI. Read-only describe-only layer, mirroring
    the SP.CampaignDiff helper style (Get-SPObjectProperty wrapper, return envelope
    @{ Success; Data; Error }). Returned Data for the key function is the 5-field
    hashtable @{ SeriesStem; NormalizedStem; PeriodToken; PeriodType; Confidence };
    the @{Success;Data;Error} envelope wraps it per the repo convention.

    Version: 1.0.0
#>

Set-StrictMode -Version 1

# Ensure SP.Shared is loaded (provides Get-SPObjectProperty). Guarded so the module
# does not hard-depend on it being pre-imported, and never re-imports if present.
$_spSharedPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'SP.Shared\SP.Shared.psd1'
if ((Test-Path $_spSharedPsd1) -and -not (Get-Command Get-SPObjectProperty -ErrorAction Ignore)) {
    Import-Module $_spSharedPsd1 -Global -ErrorAction SilentlyContinue -DisableNameChecking
}

#region Internal helpers

function Get-SPSeriesProp {
    # Thin wrapper -- canonical implementation is Get-SPObjectProperty (SP.HtmlHelpers).
    # Reads a property off either a PSCustomObject or a hashtable.
    param([object]$Object, [string]$Name, $Default = $null)
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

# Ordered temporal-token ladder: MOST-SPECIFIC first, FIRST match wins. Each entry's
# Pattern is matched case-insensitively against the campaign name; the matched substring
# is stripped to form the raw stem and reported as PeriodToken.
$script:SPSeriesTemporalLadder = @(
    # a. ISO date / datetime: 2026-06-30 and 2026-06-30T23:29:02Z (and fractional seconds).
    @{ Pattern = '\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?Z?)?'; Type = 'Daily';     Confidence = 'High' }
    # b. Quarter -- all coworker variants: 1Q2026, Q1 2026, Q1-2026, 2026 Q1.
    @{ Pattern = '([1-4]Q\s?\d{4})|(Q[1-4][\s-]?\d{4})|(\d{4}\s?Q[1-4])';                Type = 'Quarterly'; Confidence = 'High' }
    # c. Month-name + year: 'Jun 2026' and 'June 2026'.
    @{ Pattern = '(Jan(uary)?|Feb(ruary)?|Mar(ch)?|Apr(il)?|May|Jun(e)?|Jul(y)?|Aug(ust)?|Sep(t)?(ember)?|Oct(ober)?|Nov(ember)?|Dec(ember)?)\s+\d{4}'; Type = 'Monthly'; Confidence = 'High' }
    # d. Numeric year-month: 2026-06 (reached only AFTER ISO failed, so never eats a full date).
    @{ Pattern = '\d{4}-\d{2}';                                                          Type = 'Monthly';   Confidence = 'Medium' }
    # e. Week: W23 or 'Week 23'.
    @{ Pattern = '(Week\s?|W)\d{1,2}\b';                                                 Type = 'Weekly';    Confidence = 'High' }
    # f. Bare TRAILING year (end-anchored to limit false positives): ...2026.
    @{ Pattern = '\d{4}\s*$';                                                            Type = 'Annual';    Confidence = 'Medium' }
)

function ConvertTo-SPSeriesNormalForm {
    <#
        Normalize a stem so human spacing / separator / case variances collapse to one
        canonical grouping form. PS 5.1 safe: unicode dashes are matched by code point
        (no backtick-u escape). Casing is PRESERVED here (the caller lower-cases for the
        grouping key); this returns the human-readable display stem.

        i.   en-dash  (U+2013) -> ASCII hyphen
        ii.  em-dash  (U+2014) -> ASCII hyphen
        iii. ':' and '|' separators -> ASCII hyphen
        iv.  any run of dashes + surrounding spaces (>=1 dash) -> a single ' - '
        v.   collapse remaining whitespace runs -> single space
        vi.  trim leading/trailing whitespace AND hyphens
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $en = [string][char]0x2013
    $em = [string][char]0x2014
    $s = $s -replace ([regex]::Escape($en)), '-'   # i.
    $s = $s -replace ([regex]::Escape($em)), '-'   # ii.
    $s = $s -replace ':', '-'                       # iii.
    $s = $s -replace '\|', '-'                      # iii.
    $s = $s -replace '\s*-[-\s]*', ' - '            # iv.
    $s = $s -replace '\s+', ' '                     # v.
    $s = $s -replace '^[\s-]+', ''                  # vi.
    $s = $s -replace '[\s-]+$', ''                  # vi.
    return $s
}

function Get-SPLevenshteinDistance {
    <#
        Classic dynamic-programming Levenshtein edit distance (deterministic). Used ONLY
        by the opt-in -SimilarityThreshold near-match pass in Group-SPCampaignSeries to
        absorb genuine typos; the distance is the number of single-character insertions,
        deletions, or substitutions to turn $A into $B.
    #>
    param([string]$A, [string]$B)
    if ($null -eq $A) { $A = '' }
    if ($null -eq $B) { $B = '' }
    $n = $A.Length; $m = $B.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $curr = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $curr[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $min = $del
            if ($ins -lt $min) { $min = $ins }
            if ($sub -lt $min) { $min = $sub }
            $curr[$j] = $min
        }
        $tmp = $prev; $prev = $curr; $curr = $tmp
    }
    return $prev[$m]
}

#endregion

#region Public: series key

function Get-SPCampaignSeriesKey {
    <#
    .SYNOPSIS
        Derive a recurring-series grouping key from a campaign name by stripping its
        variable temporal token. PURE / deterministic / hot-path-safe (no IO, no log).
    .DESCRIPTION
        Tries an ordered, most-specific-first ladder of temporal patterns (ISO date /
        datetime, quarter, month-year, year-month, week, trailing year) and strips the
        FIRST match to form the stem. The stem is then normalized so spacing / separator
        / case variances collapse (see ConvertTo-SPSeriesNormalForm), giving a
        NormalizedStem grouping key robust to hand-naming differences.

        A name with no temporal token becomes its own series (NormalizedStem = the
        normalized whole name, PeriodType 'Unknown').
    .PARAMETER Name
        The campaign name. Empty is allowed (yields an empty stem / Unknown).
    .PARAMETER SeriesPattern
        OVERRIDE GUARD: a user-supplied temporal regex used INSTEAD of the built-in
        ladder. Its first (case-insensitive) match is stripped. A bad regex returns an
        Error envelope. PeriodType is reported 'Unknown' (caller-asserted), Confidence 'High'.
    .PARAMETER SeriesStem
        OVERRIDE GUARD: an explicit stem. Derivation is skipped entirely; SeriesStem is
        the normalized provided value, PeriodToken the name remainder, Confidence 'High'.
        Use this when auto-derivation would mis-split a particular family of names.
    .OUTPUTS
        [hashtable] @{ Success; Data; Error } where Data =
        @{ SeriesStem; NormalizedStem; PeriodToken; PeriodType; Confidence }.
        PeriodType in Daily/Weekly/Monthly/Quarterly/Annual/Unknown; Confidence in
        High/Medium/Low/None.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [string]$SeriesPattern,
        [string]$SeriesStem
    )
    try {
        $name = [string]$Name

        # Override guard 1: explicit stem provided -> skip the temporal ladder entirely.
        if ($PSBoundParameters.ContainsKey('SeriesStem') -and -not [string]::IsNullOrEmpty($SeriesStem)) {
            $stemDisp = ConvertTo-SPSeriesNormalForm $SeriesStem
            $remainder = ''
            try { $remainder = ([regex]::Replace($name, [regex]::Escape($SeriesStem), '', 'IgnoreCase')).Trim() } catch { $remainder = '' }
            return @{ Success = $true; Error = $null; Data = @{
                    SeriesStem     = $stemDisp
                    NormalizedStem = $stemDisp.ToLowerInvariant()
                    PeriodToken    = $remainder
                    PeriodType     = 'Unknown'
                    Confidence     = 'High'
                }
            }
        }

        $token = ''
        $periodType = 'Unknown'
        $confidence = 'None'
        $rawStem = $name

        if ($PSBoundParameters.ContainsKey('SeriesPattern') -and -not [string]::IsNullOrEmpty($SeriesPattern)) {
            # Override guard 2: user-supplied temporal regex replaces the built-in ladder.
            $mm = [regex]::Match($name, $SeriesPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($mm.Success -and $mm.Length -gt 0) {
                $token = $mm.Value
                $rawStem = $name.Remove($mm.Index, $mm.Length)
                $periodType = 'Unknown'
                $confidence = 'High'
            }
            else {
                $rawStem = $name
                $confidence = 'None'
            }
        }
        else {
            # Built-in ordered ladder: most-specific first, FIRST match wins.
            foreach ($p in $script:SPSeriesTemporalLadder) {
                $mm = [regex]::Match($name, $p.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($mm.Success -and $mm.Length -gt 0) {
                    $token = $mm.Value
                    $rawStem = $name.Remove($mm.Index, $mm.Length)
                    $periodType = $p.Type
                    $confidence = $p.Confidence
                    break
                }
            }
        }

        $stemDisp = ConvertTo-SPSeriesNormalForm $rawStem
        return @{ Success = $true; Error = $null; Data = @{
                SeriesStem     = $stemDisp
                NormalizedStem = $stemDisp.ToLowerInvariant()
                PeriodToken    = $token
                PeriodType     = $periodType
                Confidence     = $confidence
            }
        }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Get-SPCampaignSeriesKey failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: series grouping

function Group-SPCampaignSeries {
    <#
    .SYNOPSIS
        Cluster campaign objects into recurring series by normalized stem.
    .DESCRIPTION
        Calls Get-SPCampaignSeriesKey per campaign (threading any -SeriesStem /
        -SeriesPattern override through) and buckets by NormalizedStem. Output is
        DETERMINISTIC: clusters are emitted sorted by NormalizedStem, members within a
        cluster sorted by Id then Name -- so two runs over the same input are identical.

        -SimilarityThreshold (OPT-IN, default 0 = OFF -> pure exact match): when > 0 a
        SECOND pass merges two exact clusters when their normalized Levenshtein distance
        ratio (editDistance / max(len)) <= threshold, folding a later stem into the
        earliest matching one. The edit distance is LEVENSHTEIN; this is for genuine
        typos only and is OFF by default to keep grouping explainable / audit-evidence.
    .PARAMETER Campaigns
        The campaign objects (PSCustomObject or hashtable). Empty collection allowed.
    .PARAMETER SeriesStem
        Threaded to Get-SPCampaignSeriesKey as an explicit-stem override for every campaign.
    .PARAMETER SeriesPattern
        Threaded to Get-SPCampaignSeriesKey as a temporal-regex override for every campaign.
    .PARAMETER SimilarityThreshold
        0..1. 0 = OFF (exact match only). > 0 enables Levenshtein near-match merging.
    .PARAMETER NameProperty
        Property name to read the campaign name from (default 'Name').
    .PARAMETER IdProperty
        Property name to read the campaign id from (default 'id').
    .OUTPUTS
        [hashtable] @{ Success; Data; Error } where Data is an array of cluster
        hashtables @{ SeriesStem; NormalizedStem; PeriodType; Members; Count }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Campaigns,
        [string]$SeriesStem,
        [string]$SeriesPattern,
        [ValidateRange(0, 1)][double]$SimilarityThreshold = 0,
        [string]$NameProperty = 'Name',
        [string]$IdProperty = 'id'
    )
    try {
        $buckets = @{}
        foreach ($c in @($Campaigns)) {
            if ($null -eq $c) { continue }
            $nm = [string](Get-SPSeriesProp $c $NameProperty '')
            $keyArgs = @{ Name = $nm }
            if ($PSBoundParameters.ContainsKey('SeriesStem')) { $keyArgs['SeriesStem'] = $SeriesStem }
            if ($PSBoundParameters.ContainsKey('SeriesPattern')) { $keyArgs['SeriesPattern'] = $SeriesPattern }
            $kr = Get-SPCampaignSeriesKey @keyArgs
            if (-not $kr.Success) { return @{ Success = $false; Data = $null; Error = "Series key derivation failed for '$nm': $($kr.Error)" } }
            $nstem = [string]$kr.Data.NormalizedStem
            if (-not $buckets.ContainsKey($nstem)) {
                $buckets[$nstem] = @{
                    SeriesStem     = [string]$kr.Data.SeriesStem
                    NormalizedStem = $nstem
                    PeriodType     = [string]$kr.Data.PeriodType
                    Members        = (New-Object System.Collections.Generic.List[object])
                }
            }
            $buckets[$nstem].Members.Add($c)
        }

        # Opt-in near-match consolidation (default OFF). Process exact clusters in
        # NormalizedStem order, folding a later cluster into the EARLIEST one within
        # the Levenshtein ratio; the earliest cluster keeps its Stem / PeriodType.
        if ($SimilarityThreshold -gt 0 -and $buckets.Count -gt 1) {
            $sortedKeys = @($buckets.Keys | Sort-Object)
            $kept = New-Object System.Collections.Generic.List[string]
            foreach ($key in $sortedKeys) {
                $mergedInto = $null
                foreach ($kk in $kept) {
                    $dist = Get-SPLevenshteinDistance -A $key -B $kk
                    $maxLen = [math]::Max($key.Length, $kk.Length)
                    $ratio = if ($maxLen -eq 0) { 0 } else { [double]$dist / [double]$maxLen }
                    if ($ratio -le $SimilarityThreshold) { $mergedInto = $kk; break }
                }
                if ($null -ne $mergedInto) {
                    foreach ($mem in $buckets[$key].Members.ToArray()) { $buckets[$mergedInto].Members.Add($mem) }
                    $buckets.Remove($key)
                }
                else { $kept.Add($key) }
            }
        }

        $clusters = New-Object System.Collections.Generic.List[object]
        foreach ($k in (@($buckets.Keys) | Sort-Object)) {
            $b = $buckets[$k]
            # Single composite-key sort (Id then Name) -- deterministic, and avoids the PS 5.1
            # multi-key Sort-Object "Argument types do not match" quirk on object collections.
            $members = $b.Members.ToArray() | Sort-Object -Property @{ Expression = {
                    '{0}|{1}' -f ([string](Get-SPSeriesProp $_ $IdProperty '')), ([string](Get-SPSeriesProp $_ $NameProperty ''))
                } }
            $clusters.Add([ordered]@{
                    SeriesStem     = $b.SeriesStem
                    NormalizedStem = $b.NormalizedStem
                    PeriodType     = $b.PeriodType
                    Members        = @($members)
                    Count          = @($members).Count
                })
        }

        # Optional summary log -- only when SP.Core's Write-SPLog is present (no hard dep).
        if (Get-Command Write-SPLog -ErrorAction Ignore) {
            Write-SPLog -Message "Grouped $(@($Campaigns).Count) campaign(s) into $($clusters.Count) series" -Severity 'Info' -Component 'SP.CampaignSeries' -Action 'Group-SPCampaignSeries'
        }
        return @{ Success = $true; Data = $clusters.ToArray(); Error = $null }
    }
    catch { return @{ Success = $false; Data = $null; Error = "Group-SPCampaignSeries failed: $($_.Exception.Message)" } }
}

#endregion

#region Public: per-item key + honest state (V4c)

function Get-SPSeriesUnwrapItem {
    # Accept EITHER a cache wrapper (carries .Item, plus CertificationId/Name/CampaignName per
    # the jsonl shape written at SP.AuditQueries.psm1:7346-7351) OR a raw ISC item. If the passed
    # object carries a non-null 'Item' property, unwrap it; otherwise return it verbatim. Pure.
    param([object]$Object)
    if ($null -eq $Object) { return $null }
    $inner = Get-SPSeriesProp $Object 'Item'
    if ($null -ne $inner) { return $inner }
    return $Object
}

function Get-SPSeriesItemFacts {
    <#
        Internal field extractor shared by Get-SPSeriesItemKey and Resolve-SPSeriesItemState.
        Mirrors the raw-item field extraction in Group-SPAuditDecisions
        (SP.AuditReportCore.psm1 lines 769-889): identity id, access node (accessSummary.access
        else flat .access), access id/type/name, account (nativeIdentity + sourceId), and the
        source id/name precedence chain (account -> entitlement/accessProfile/role -> access.source).
        Returns a plain hashtable of extracted facts plus the composed cross-instance ItemKey.
        $Item is assumed ALREADY UNWRAPPED. Null-safe throughout (PS 5.1 / StrictMode 1).
    #>
    param([object]$Item, [string]$IdentityProperty)
    $facts = @{
        IdentityId     = ''
        IdentityName   = ''
        AccessId       = ''
        AccessName     = ''
        AccessType     = ''
        SourceId       = ''
        SourceName     = ''
        NativeIdentity = ''
        ItemKey        = ''
    }
    if ($null -eq $Item) { return $facts }

    # Identity id: identitySummary.identityId else identitySummary.id (caller may override the
    # primary property name via -IdentityProperty). Name for display only (never in the key).
    $idSummary = Get-SPSeriesProp $Item 'identitySummary'
    $identityId = ''
    if ($null -ne $idSummary) {
        $idProps = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($IdentityProperty)) { $idProps.Add($IdentityProperty) }
        $idProps.Add('identityId'); $idProps.Add('id')
        foreach ($p in $idProps) {
            $v = [string](Get-SPSeriesProp $idSummary $p '')
            if (-not [string]::IsNullOrWhiteSpace($v)) { $identityId = $v; break }
        }
        $facts.IdentityName = [string](Get-SPSeriesProp $idSummary 'name' '')
    }
    $facts.IdentityId = $identityId.Trim()

    # Access node: real ISC nests it under accessSummary.access; the simplified/mock shape uses
    # a flat .access. Read whichever is present.
    $accessSummary = Get-SPSeriesProp $Item 'accessSummary'
    $accessObj = $null
    if ($null -ne $accessSummary) { $accessObj = Get-SPSeriesProp $accessSummary 'access' }
    if ($null -eq $accessObj) { $accessObj = Get-SPSeriesProp $Item 'access' }

    # Entitlement/accessProfile/role node -- carries the SOURCE (sourceName/sourceId) for ISC.
    $entObj = $null
    if ($null -ne $accessSummary) {
        foreach ($ak in @('entitlement', 'accessProfile', 'role')) {
            $cand = Get-SPSeriesProp $accessSummary $ak
            if ($null -ne $cand) { $entObj = $cand; break }
        }
    }

    if ($null -ne $accessObj) {
        $facts.AccessId   = [string](Get-SPSeriesProp $accessObj 'id' '')
        $facts.AccessType = [string](Get-SPSeriesProp $accessObj 'type' '')
        $facts.AccessName = [string](Get-SPSeriesProp $accessObj 'name' '')
    }

    # Account node (account-level discrimination): nativeIdentity + sourceId.
    $account = Get-SPSeriesProp $Item 'account'
    $accountSourceId = ''
    if ($null -ne $account) {
        $facts.NativeIdentity = [string](Get-SPSeriesProp $account 'nativeIdentity' '')
        $accountSourceId = [string](Get-SPSeriesProp $account 'sourceId' '')
        if ([string]::IsNullOrWhiteSpace($accountSourceId)) {
            $accSrc = Get-SPSeriesProp $account 'source'
            if ($null -ne $accSrc) { $accountSourceId = [string](Get-SPSeriesProp $accSrc 'id' '') }
        }
    }

    # Source id precedence chain: account.sourceId -> entitlement.sourceId -> access.source.id.
    $sourceId = ''
    if (-not [string]::IsNullOrWhiteSpace($accountSourceId)) { $sourceId = $accountSourceId }
    if ([string]::IsNullOrWhiteSpace($sourceId) -and $null -ne $entObj) {
        $sourceId = [string](Get-SPSeriesProp $entObj 'sourceId' '')
    }
    if ([string]::IsNullOrWhiteSpace($sourceId) -and $null -ne $accessObj) {
        $accSource = Get-SPSeriesProp $accessObj 'source'
        if ($null -ne $accSource) { $sourceId = [string](Get-SPSeriesProp $accSource 'id' '') }
    }
    $facts.SourceId = $sourceId

    # Source name (name-derived fallback): entitlement.sourceName -> access.source.name -> account.sourceName.
    $sourceName = ''
    if ($null -ne $entObj) { $sourceName = [string](Get-SPSeriesProp $entObj 'sourceName' '') }
    if ([string]::IsNullOrWhiteSpace($sourceName) -and $null -ne $accessObj) {
        $accSource = Get-SPSeriesProp $accessObj 'source'
        if ($null -ne $accSource) { $sourceName = [string](Get-SPSeriesProp $accSource 'name' '') }
    }
    if ([string]::IsNullOrWhiteSpace($sourceName) -and $null -ne $account) {
        $sourceName = [string](Get-SPSeriesProp $account 'sourceName' '')
    }
    $facts.SourceName = $sourceName

    # Compose the STABLE cross-instance key `idPart|accessPart|sourcePart`. Immutable IDs win over
    # names so an entitlement/source RENAME does not churn the key (same rationale as the snapshot
    # Key at SP.CampaignDelta.psm1:207-212). Lower-case ONLY name-derived fallback components so
    # human case variance collapses; leave GUID/id components verbatim.
    $idPart = $facts.IdentityId
    $accessId = $facts.AccessId
    $accessName = $facts.AccessName
    $accessType = $facts.AccessType
    $nativeIdentity = $facts.NativeIdentity

    # Return '' (never throw) when identityId AND every access discriminator are blank.
    if ([string]::IsNullOrWhiteSpace($idPart) -and
        [string]::IsNullOrWhiteSpace($accessId) -and
        [string]::IsNullOrWhiteSpace($accessName) -and
        [string]::IsNullOrWhiteSpace($nativeIdentity)) {
        $facts.ItemKey = ''
        return $facts
    }

    $accessPart = ''
    if (-not [string]::IsNullOrWhiteSpace($accessId)) {
        $accessPart = $accessId.Trim()
    }
    elseif ($accessType.ToUpperInvariant() -eq 'ACCOUNT' -or [string]::IsNullOrWhiteSpace($accessName)) {
        $accessPart = 'account:' + $nativeIdentity.Trim().ToLowerInvariant()
    }
    else {
        $accessPart = $accessName.Trim().ToLowerInvariant()
    }

    $sourcePart = ''
    if (-not [string]::IsNullOrWhiteSpace($sourceId)) { $sourcePart = $sourceId.Trim() }
    else { $sourcePart = $sourceName.Trim().ToLowerInvariant() }

    $facts.ItemKey = ('{0}|{1}|{2}' -f $idPart, $accessPart, $sourcePart)
    return $facts
}

function Get-SPSeriesItemKey {
    <#
    .SYNOPSIS
        Compute a STABLE cross-instance item key for a certification access-review item, so the
        SAME identity+access pairs JOIN across recurring campaign instances even though the ISC
        item id differs in every campaign. PURE / deterministic / hot-path-safe (no IO, no log).
    .DESCRIPTION
        Accepts EITHER a cache wrapper (@{Item;CertificationId;CertificationName;CampaignName}, the
        jsonl shape written at SP.AuditQueries.psm1:7346-7351) OR a raw ISC item; a non-null .Item
        property is unwrapped first. Mirrors the raw-item field extraction in Group-SPAuditDecisions
        (identityId, access node, access id/type/name, account nativeIdentity, source id/name).

        Composes `idPart|accessPart|sourcePart` where idPart = trimmed identityId; accessPart =
        accessId if present, else 'account:'+nativeIdentity for an ACCOUNT-level item (or when the
        access name is blank), else the access name; sourcePart = the resolved source id, else the
        source name. Immutable IDs win over names so a rename does not churn the key; only the
        name-derived fallback components are lower-cased. Returns '' (never throws) when identityId
        AND every access discriminator are blank.
    .PARAMETER Item
        The cache wrapper or raw ISC access-review item (PSCustomObject or hashtable).
    .PARAMETER IdentityProperty
        OPTIONAL override for the identitySummary property name read for the identity id (the
        built-in chain is identityId -> id). When supplied it is tried FIRST.
    .PARAMETER CertificationId
        Accepted for signature parity with Resolve-SPSeriesItemState; NOT part of the key (the key
        must be cert-independent so instances join), so it is intentionally unused here.
    .OUTPUTS
        [string] the stable cross-instance key, or '' when no discriminator is available.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Item,
        [string]$IdentityProperty,
        [string]$CertificationId
    )
    $raw = Get-SPSeriesUnwrapItem $Item
    $facts = Get-SPSeriesItemFacts -Item $raw -IdentityProperty $IdentityProperty
    return [string]$facts.ItemKey
}

function Resolve-SPSeriesItemState {
    <#
    .SYNOPSIS
        Resolve the HONEST per-item decision state + reviewer attribution for a certification
        access-review item, for the V4c series-attestation walk. PURE: classifies/attributes only
        what it is given (the cache layer supplies the sealed roster + ACTIVE-state cached items).
    .DESCRIPTION
        Unwraps a cache wrapper as Get-SPSeriesItemKey does and derives CertificationId from the
        wrapper when -CertificationId is not supplied. Reuses the SINGLE shared honest classifier
        (ConvertTo-SPCanonicalDecision, guarded): a genuine reviewer Approve/Revoke stays
        Approved/Revoked, but pending OR auto-approved-at-close (idNowAutoApproved) is demoted to
        'Pending' and surfaced here as HonestDecision 'Undecided' -- NEVER a genuine approval.

        Reviewer attribution mirrors the $resolveAssigned closure in Group-SPCompletedPendingByReviewer:
        if the item's cert is in the sealed Roster, the cert-ASSIGNED reviewer wins (ReviewerSource
        'roster') -- the ONLY correct attribution for an undecided item whose item.reviewedBy is null;
        else it falls back to item.reviewedBy ONLY when present (a genuinely-decided item,
        ReviewerSource 'item'); else '(Unassigned)' (ReviewerSource 'none'). item.reviewedBy is NEVER
        read when null.
    .PARAMETER Item
        The cache wrapper or raw ISC access-review item.
    .PARAMETER Roster
        The sealed cert roster (ConvertTo-SPCertRosterEntry-shaped entries:
        CertificationId / ReviewerName / ReviewerId / ReviewerEmail).
    .PARAMETER CertificationId
        The item's certification id; derived from the wrapper when omitted.
    .PARAMETER Unverified
        Propagated provenance flag from the instance meta (CapturedWhileActive / Unverified).
    .PARAMETER Status
        Optional instance status (e.g. ACTIVE/COMPLETED); accepted for caller context, recorded only.
    .OUTPUTS
        [pscustomobject] the honest item-state record (ItemKey, identity/access/source fields,
        RawDecision, HonestDecision, IsGenuineApproval, IsGenuineDecision, IsAutoApproved,
        DecisionDate, reviewer attribution, Unverified).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Item,
        [AllowEmptyCollection()][object[]]$Roster = @(),
        [string]$CertificationId,
        [bool]$Unverified = $false,
        [string]$Status
    )

    # Derive the cert id from the wrapper when the caller did not supply one (do this BEFORE unwrap).
    $certId = ''
    if ($PSBoundParameters.ContainsKey('CertificationId') -and -not [string]::IsNullOrWhiteSpace($CertificationId)) {
        $certId = [string]$CertificationId
    }
    else {
        $certId = [string](Get-SPSeriesProp $Item 'CertificationId' '')
    }

    $raw = Get-SPSeriesUnwrapItem $Item
    $facts = Get-SPSeriesItemFacts -Item $raw

    # Raw decision string (mirror SP.AuditReportCore.psm1 lines 908-924): flat string or nested
    # {value/decision/type/name}.
    $decision = ''
    $decRaw = Get-SPSeriesProp $raw 'decision'
    if ($null -ne $decRaw) {
        if ($decRaw -is [string]) {
            $decision = $decRaw
        }
        else {
            foreach ($prop in @('value', 'decision', 'type', 'name')) {
                $cand = Get-SPSeriesProp $decRaw $prop ''
                if (-not [string]::IsNullOrWhiteSpace([string]$cand)) { $decision = [string]$cand; break }
            }
        }
    }

    # Justification = item.comment else item.comments (mirror lines 793-811).
    $justification = ''
    $cmt = Get-SPSeriesProp $raw 'comment'
    if (-not [string]::IsNullOrWhiteSpace([string]$cmt)) {
        $justification = [string]$cmt
    }
    else {
        $cm = Get-SPSeriesProp $raw 'comments'
        if ($null -ne $cm) {
            if ($cm -is [string]) {
                $justification = $cm
            }
            elseif ($cm -is [System.Collections.IEnumerable]) {
                $parts = @()
                foreach ($c in $cm) {
                    if ($null -eq $c) { continue }
                    if ($c -is [string]) { $parts += $c }
                    else {
                        $cc = Get-SPSeriesProp $c 'comment'
                        $tt = Get-SPSeriesProp $c 'text'
                        if (-not [string]::IsNullOrWhiteSpace([string]$cc)) { $parts += [string]$cc }
                        elseif (-not [string]::IsNullOrWhiteSpace([string]$tt)) { $parts += [string]$tt }
                    }
                }
                $justification = ($parts -join '; ')
            }
        }
    }

    $decisionDate = [string](Get-SPSeriesProp $raw 'decisionDate' '')

    # HONEST decision via the single shared classifier (demotes pending AND idNowAutoApproved-APPROVE
    # to 'Pending'). Guarded so the module does not hard-depend on it being pre-imported; the inline
    # fallback mirrors the same three-bucket logic when the classifier is not in-session.
    $canon = 'Pending'
    if (Get-Command ConvertTo-SPCanonicalDecision -ErrorAction Ignore) {
        $canon = ConvertTo-SPCanonicalDecision -Decision $decision -Justification $justification
    }
    else {
        $decUp = ([string]$decision).ToUpperInvariant()
        if ($decUp -in @('APPROVE', 'APPROVED', 'CERTIFY')) {
            $isMarker = $false
            if (Get-Command Test-SPAutoApproveMarker -ErrorAction Ignore) {
                $isMarker = [bool](Test-SPAutoApproveMarker -Justification $justification)
            }
            elseif (-not [string]::IsNullOrEmpty($justification)) {
                $isMarker = ($justification.IndexOf('idNowAutoApproved', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            }
            $canon = if ($isMarker) { 'Pending' } else { 'Approved' }
        }
        elseif ($decUp -in @('REVOKE', 'REVOKED', 'DENY', 'REJECT', 'EXCEPTION')) {
            $canon = 'Revoked'
        }
        else { $canon = 'Pending' }
    }

    $honestDecision   = if ($canon -eq 'Pending') { 'Undecided' } else { $canon }
    $isGenuineApprove = ($canon -eq 'Approved')
    $isGenuineDecide  = ($canon -in @('Approved', 'Revoked'))
    # Auto-approved-at-close: the raw decision is an APPROVE family value yet the honest classifier
    # demoted it to Pending (only the idNowAutoApproved marker does that) -- equivalent to
    # Test-SPAutoApproveMarker but avoids a second call.
    $decUpper = ([string]$decision).ToUpperInvariant()
    $isAutoApproved = (($decUpper -in @('APPROVE', 'APPROVED', 'CERTIFY')) -and ($canon -eq 'Pending'))

    # Reviewer attribution. Index the roster by CertificationId (first entry wins); a cert in the
    # sealed roster -> the cert-ASSIGNED reviewer (the correct attribution for an undecided item
    # whose item.reviewedBy is null). Else fall back to item.reviewedBy ONLY when present. Else
    # '(Unassigned)'. NEVER read item.reviewedBy when it is null.
    $rosterByCertId = @{}
    foreach ($re in @($Roster)) {
        if ($null -eq $re) { continue }
        $rcId = [string](Get-SPSeriesProp $re 'CertificationId' '')
        if ([string]::IsNullOrWhiteSpace($rcId)) { continue }
        if (-not $rosterByCertId.ContainsKey($rcId)) { $rosterByCertId[$rcId] = $re }
    }

    $reviewerName = ''; $reviewerId = ''; $reviewerEmail = ''; $reviewerSource = 'none'
    $matched = $false
    if (-not [string]::IsNullOrWhiteSpace($certId) -and $rosterByCertId.ContainsKey($certId)) {
        $re = $rosterByCertId[$certId]
        $rn = [string](Get-SPSeriesProp $re 'ReviewerName' '')
        if (-not [string]::IsNullOrWhiteSpace($rn)) {
            $reviewerName   = $rn
            $reviewerId     = [string](Get-SPSeriesProp $re 'ReviewerId' '')
            $reviewerEmail  = [string](Get-SPSeriesProp $re 'ReviewerEmail' '')
            $reviewerSource = 'roster'
            $matched = $true
        }
    }
    if (-not $matched) {
        $rb = Get-SPSeriesProp $raw 'reviewedBy'   # only read further when non-null
        if ($null -ne $rb) {
            $rn = [string](Get-SPSeriesProp $rb 'name' '')
            if (-not [string]::IsNullOrWhiteSpace($rn)) {
                $reviewerName   = $rn
                $reviewerId     = [string](Get-SPSeriesProp $rb 'id' '')
                $reviewerEmail  = [string](Get-SPSeriesProp $rb 'email' '')
                $reviewerSource = 'item'
                $matched = $true
            }
        }
    }
    if (-not $matched) { $reviewerName = '(Unassigned)'; $reviewerSource = 'none' }

    return [pscustomobject]@{
        ItemKey           = [string]$facts.ItemKey
        IdentityId        = [string]$facts.IdentityId
        IdentityName      = [string]$facts.IdentityName
        AccessId          = [string]$facts.AccessId
        AccessName        = [string]$facts.AccessName
        AccessType        = [string]$facts.AccessType
        SourceId          = [string]$facts.SourceId
        SourceName        = [string]$facts.SourceName
        CertificationId   = [string]$certId
        RawDecision       = [string]$decision
        HonestDecision    = [string]$honestDecision
        IsGenuineApproval = [bool]$isGenuineApprove
        IsGenuineDecision = [bool]$isGenuineDecide
        IsAutoApproved    = [bool]$isAutoApproved
        DecisionDate      = [string]$decisionDate
        ReviewerId        = [string]$reviewerId
        ReviewerName      = [string]$reviewerName
        ReviewerEmail     = [string]$reviewerEmail
        ReviewerSource    = [string]$reviewerSource
        Unverified        = [bool]$Unverified
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SPCampaignSeriesKey',
    'Group-SPCampaignSeries',
    'Get-SPSeriesItemKey',
    'Resolve-SPSeriesItemState'
)
