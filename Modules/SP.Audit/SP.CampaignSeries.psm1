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

Export-ModuleMember -Function @(
    'Get-SPCampaignSeriesKey',
    'Group-SPCampaignSeries'
)
