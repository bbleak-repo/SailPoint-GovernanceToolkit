#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the V4f series attestation delta report -- V4e plus the Approved Items
    First-Approval Timeline: WHEN each currently-approved grant was first genuinely
    approved, and WHICH grants became approved mid-window ('newly approved'). Same
    "newly attested" decision-transition analysis as V4c, rendered in the V4/V4b
    visual family (gradient header, sectioned layout, collapsible tables)
    (output: daily-evidence-v4f-*.html).
.DESCRIPTION
    V4e is a READ-ONLY report. It reads ONLY the rich audit cache
    (items-<id>.jsonl + items-<id>.meta.json + roster-<id>.json) -- it never
    calls the ISC API, never starts the live mock, never opens a GUI.

    V4e shares V4c's engine and pipeline byte-for-byte (Get-SPCachedCampaignSeries +
    Get-SPSeriesAttestationDelta); the ONLY difference is the HTML skin -- V4e wears
    the V4/V4b chrome (gradient banner, .section blocks with h2 headings, KPI tiles,
    table.report styling, <details> collapsibles) so it looks consistent with the
    rest of the daily-evidence family. V4c stays as-is (its own analytics-style look).

    It AUTO-DERIVES recurring campaign series by stripping the variable temporal
    token from each campaign name (daily date, quarter, month-year, year) and
    grouping by a normalized stem that is robust to human spacing/separator/case
    variances. For each series it walks the cached instances chronologically and
    flags, per identity+entitlement item, the FIRST genuine (honest) reviewer
    approval in the window (the "newly attested" headline), plus persistent
    non-attestation, decision changes, and newly-in-scope items.

    Honesty doctrine: it reuses the shared honest classifier via the pure engine
    Get-SPSeriesAttestationDelta -- auto-approved-at-close (idNowAutoApproved) and
    pending decisions are demoted to Undecided and NEVER counted as a genuine
    approval; COMPLETED instances are attributed to the cert-ASSIGNED reviewer off
    the sealed roster; Unverified provenance is propagated and flagged.

    This is ADDITIVE: it does NOT replace or modify V3/V4/V4b/V4c/V5/V6/V7. The
    cross-campaign snapshot scope-diff stays intact for genuinely-different
    campaigns; V4e is the V4/V4b-styled sibling of the V4c recurring-series analysis.

    Exit codes:
        0 = Normal
        2 = Parameter error
        4 = Configuration / reader failure
        5 = Critical (unexpected failure)
.PARAMETER SeriesName
    OVERRIDE GUARD (alias -SeriesStem): force an explicit series stem instead of
    auto-derivation. Passed through to the reader only when bound.
.PARAMETER SeriesPattern
    OVERRIDE GUARD: a user-supplied temporal regex used instead of the built-in
    ladder. Passed through to the reader only when bound.
.PARAMETER SimilarityThreshold
    OPT-IN fuzzy near-match (0..1). Default 0 = OFF (exact-match grouping only).
    When > 0, near-identical series stems are consolidated via Levenshtein
    distance (the merge is logged as audit evidence).
.PARAMETER MinInstances
    Minimum number of instances for a series to be reported. Default 2 (a single
    capture is not a "series"). Passed to the reader.
.PARAMETER Window
    Narrow each series to its newest N instances before the delta engine + rendering.
    Default 0 = the FULL cached window (all instances). Alias -DaysBack. Applied AFTER
    MinInstances filtering (a series must have >= MinInstances TOTAL cached instances to
    appear, then the window narrows what is analyzed). The newest instance is ALWAYS
    retained (it drives the exec-box single-day panel). ValidateRange(0, 10000).
.PARAMETER IncludeUnverified
    By default Unverified-provenance items are EXCLUDED from the headline (and
    reported as an "Unverified (excluded)" note). When set, they are included and
    rendered with a visible "Unverified" badge.
.PARAMETER CachePath
    Override the rich-cache directory (alias -Path). Defaults via the reader to
    the configured Audit cache dir.
.PARAMETER OutputPath
    Directory for output files. Defaults to the daily-evidence subdirectory.
.PARAMETER OutputMode
    Console: per-series summary to terminal.
    JSON: machine-readable JSON to stdout.
    HTML: self-contained HTML report file.
    Both (default): console output and HTML file.
.PARAMETER Help
    Display detailed help.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4f.ps1
    # Auto-derive every recurring series from the cache and render the delta (V4b look).
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4f.ps1 -SeriesName 'Access Review' -OutputMode HTML
    # Force a single series stem and write only the HTML report.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4f.ps1 -SimilarityThreshold 0.15 -IncludeUnverified
    # Opt-in fuzzy stem merge; include Unverified items with a badge.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4f.ps1 -Window 2 -OutputMode Console
    # Narrow each series to its two newest instances (today vs yesterday single-day diff).
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV4f.ps1
    Version: 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('SeriesStem')]
    [string]$SeriesName,

    [Parameter()]
    [string]$SeriesPattern,

    [Parameter()]
    [ValidateRange(0, 1)]
    [double]$SimilarityThreshold = 0,

    [Parameter()]
    [int]$MinInstances = 2,

    [Parameter()]
    [Alias('DaysBack')]
    [ValidateRange(0, 10000)]
    [int]$Window = 0,

    [Parameter()]
    [switch]$IncludeUnverified,

    [Parameter()]
    [Alias('Path')]
    [string]$CachePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'HTML', 'Both')]
    [string]$OutputMode = 'Both',

    [Parameter()]
    [Alias('?')]
    [switch]$Help
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    return
}

#region Module Load

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$toolkitRoot = Split-Path -Parent $scriptRoot

# V4e needs SP.Audit (the series reader + pure delta engine live there). SP.Audit
# depends on SP.Api/SP.Core; import order Shared -> Core -> Api -> Audit.
$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($mod.Required) {
            Write-Host "ERROR: Required module '$($mod.Name)' not found at: $($mod.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Setup

$startTime = Get-Date
$correlationID = [guid]::NewGuid().ToString()
$todayLabel = $startTime.ToString('yyyy-MM-dd')

$cfgPath = $null
try {
    $cfgPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
} catch {
    $defaultCfg = Join-Path $toolkitRoot 'settings.json'
    if (Test-Path $defaultCfg) { $cfgPath = $defaultCfg }
}

$config = $null
if ($cfgPath) {
    try {
        $config = Get-SPConfig -ConfigPath $cfgPath
    }
    catch {
        Write-Host "WARN: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Evidence Report (v4f) -- Series Attestation Delta + First-Approval Timeline' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV4f started: CorrelationID=$correlationID MinInstances=$MinInstances SimilarityThreshold=$SimilarityThreshold Window=$Window" `
        -Severity INFO -Component 'DailyEvidenceV4f' -Action 'Start' -CorrelationID $correlationID
} catch { }

# Resolve output path (mirrors the V6 OutputPath-resolution region).
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $deOutputPath = $null
    if ($null -ne $config) {
        try {
            if ($null -ne $config.PSObject.Properties['DailyEvidence'] -and
                $null -ne $config.DailyEvidence -and
                $null -ne $config.DailyEvidence.PSObject.Properties['OutputPath'] -and
                -not [string]::IsNullOrWhiteSpace($config.DailyEvidence.OutputPath)) {
                $deOutputPath = [string]$config.DailyEvidence.OutputPath
            }
        } catch { }
    }

    if ($null -ne $deOutputPath) {
        $effectiveOutputPath = $deOutputPath
    }
    elseif ($null -ne $config -and $null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = Join-Path ([string]$config.Audit.OutputPath) 'daily-evidence'
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'daily-evidence')
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}
if (-not (Test-Path $effectiveOutputPath)) {
    New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
}

#endregion

#region Step 1: Read the cache and auto-derive series

Write-Host '  Step 1: Read rich cache and derive recurring series' -ForegroundColor Cyan

# When opt-in fuzzy near-match is on, read with MinInstances=1 so a mistyped singleton
# (e.g. 'Acess Review - <date>' among 'Access Review - <date>') survives Step 1 and can be
# rescued into its family by the Step-2 fuzzy merge; MinInstances is re-applied AFTER the merge.
$readerMinInstances = if ($SimilarityThreshold -gt 0) { 1 } else { $MinInstances }
$readerArgs = @{ MinInstances = $readerMinInstances; CorrelationID = $correlationID }
if ($PSBoundParameters.ContainsKey('CachePath'))     { $readerArgs['CachePath'] = $CachePath }
if ($PSBoundParameters.ContainsKey('SeriesName'))    { $readerArgs['SeriesStem'] = $SeriesName }
if ($PSBoundParameters.ContainsKey('SeriesPattern')) { $readerArgs['SeriesPattern'] = $SeriesPattern }

$seriesRes = $null
try {
    $seriesRes = Get-SPCachedCampaignSeries @readerArgs
} catch {
    Write-Host "  ERROR: Series reader threw: $($_.Exception.Message)" -ForegroundColor Red
    try {
        Write-SPLog -Message "V4e reader threw: $($_.Exception.Message)" -Severity ERROR -Component 'DailyEvidenceV4f' -Action 'Read' -CorrelationID $correlationID
    } catch { }
    exit 4
}

if ($null -eq $seriesRes -or -not $seriesRes.Success) {
    $errMsg = if ($null -ne $seriesRes) { [string]$seriesRes.Error } else { 'null result' }
    Write-Host "  ERROR: Series reader failed: $errMsg" -ForegroundColor Red
    try {
        Write-SPLog -Message "V4e reader failed: $errMsg" -Severity WARN -Component 'DailyEvidenceV4f' -Action 'Read' -CorrelationID $correlationID
    } catch { }
    exit 4
}

$cacheDir = [string]$seriesRes.Data.CacheDir
$seriesList = @($seriesRes.Data.Series)
Write-Host "    Cache dir: $cacheDir" -ForegroundColor DarkGray
Write-Host "    Series found: $($seriesList.Count) (instances kept: $($seriesRes.Data.InstanceCount))" -ForegroundColor DarkGray

#endregion

#region Step 2: Opt-in fuzzy consolidation (default OFF)

if ($SimilarityThreshold -gt 0 -and $seriesList.Count -gt 1) {
    Write-Host "  Step 2: Opt-in fuzzy stem consolidation (threshold=$SimilarityThreshold)" -ForegroundColor Cyan
    $stemToSeries = @{}
    foreach ($s in $seriesList) { $stemToSeries[[string]$s.NormalizedStem] = $s }

    $synthetic = New-Object System.Collections.Generic.List[object]
    foreach ($s in $seriesList) {
        $synthetic.Add([pscustomobject]@{ id = [string]$s.NormalizedStem; Name = [string]$s.NormalizedStem })
    }

    $grp = $null
    try {
        $grp = Group-SPCampaignSeries -Campaigns @($synthetic.ToArray()) -SimilarityThreshold $SimilarityThreshold
    } catch {
        Write-Host "    WARN: fuzzy consolidation failed, keeping exact-match series: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($null -ne $grp -and $grp.Success) {
        $merged = New-Object System.Collections.Generic.List[object]
        foreach ($cluster in @($grp.Data)) {
            $clusterSeries = New-Object System.Collections.Generic.List[object]
            foreach ($m in @($cluster.Members)) {
                $ms = [string](Get-SPObjectProperty -Object $m -Name 'id' -Default '')
                if ($stemToSeries.ContainsKey($ms)) { $clusterSeries.Add($stemToSeries[$ms]) }
            }
            $cs = @($clusterSeries.ToArray())
            if ($cs.Count -eq 0) { continue }
            if ($cs.Count -eq 1) { $merged.Add($cs[0]); continue }

            # Merge >1 reader series: concat instances, re-sort by ChronoKey then CampaignId,
            # re-stamp OrderIndex, keep the earliest series' stem/period (audit-explainable).
            $allInst = New-Object System.Collections.Generic.List[object]
            foreach ($one in $cs) { foreach ($inst in @($one.Instances)) { $allInst.Add($inst) } }
            $reSorted = @($allInst.ToArray() | Sort-Object -Property @{ Expression = {
                        '{0:o}|{1}' -f $_.ChronoKey, $_.CampaignId
                    } })
            for ($qi = 0; $qi -lt $reSorted.Count; $qi++) { $reSorted[$qi].OrderIndex = $qi }

            $firstCs = $cs[0]
            $mergedStems = @($cs | ForEach-Object { [string]$_.NormalizedStem }) -join ', '
            $merged.Add([ordered]@{
                    SeriesStem     = [string]$firstCs.SeriesStem
                    NormalizedStem = [string]$firstCs.NormalizedStem
                    PeriodType     = [string]$firstCs.PeriodType
                    InstanceCount  = $reSorted.Count
                    Instances      = @($reSorted)
                })
            Write-Host "    Merged near-match stems into '$($firstCs.NormalizedStem)': $mergedStems" -ForegroundColor DarkGray
            try {
                Write-SPLog -Message "V4e fuzzy merge -> '$($firstCs.NormalizedStem)' from: $mergedStems" `
                    -Severity INFO -Component 'DailyEvidenceV4f' -Action 'FuzzyMerge' -CorrelationID $correlationID
            } catch { }
        }
        $seriesList = @($merged.ToArray())
        Write-Host "    Series after consolidation: $($seriesList.Count)" -ForegroundColor DarkGray
    }
}

# Re-apply MinInstances AFTER the fuzzy merge: Step 1 deliberately read with MinInstances=1
# (see $readerMinInstances) so a mistyped singleton could survive to be rescued by the fuzzy
# pass; now drop any stem still below the user's threshold once the merges are done. This runs
# even when Step 2's merge block was skipped (a lone surviving singleton must not slip through).
if ($SimilarityThreshold -gt 0 -and $MinInstances -gt 1) {
    $beforeReFilter = $seriesList.Count
    $seriesList = @($seriesList | Where-Object { @($_.Instances).Count -ge $MinInstances })
    if ($seriesList.Count -ne $beforeReFilter) {
        Write-Host "    Series after MinInstances=$MinInstances re-filter: $($seriesList.Count)" -ForegroundColor DarkGray
    }
}

#endregion

#region Step 2b: Apply -Window (narrow each series to its newest N instances)

# Guarded on $Window -gt 0 so the default full-window path is completely untouched
# (byte-for-byte reproduction of today's output when -Window is omitted or 0). Runs
# AFTER MinInstances filtering: a series must have >= MinInstances TOTAL cached instances
# to appear, then the window narrows what is analyzed/rendered. The engine re-sorts by
# OrderIndex and treats the LAST instance as newest, so keeping the original absolute
# OrderIndex values on the retained slice is correct (Select-Object -Last preserves
# ascending chronological order). The newest instance is always retained.
if ($Window -gt 0) {
    Write-Host "  Step 2b: Narrow each series to its newest $Window instance(s)" -ForegroundColor Cyan
    $windowed = New-Object System.Collections.Generic.List[object]
    foreach ($s in $seriesList) {
        $inst = @($s.Instances)
        if ($inst.Count -gt $Window) {
            $kept = @($inst | Select-Object -Last $Window)
            $s['Instances'] = $kept
            $s['InstanceCount'] = $kept.Count
            Write-Host "    [$($s.NormalizedStem)] $($inst.Count) -> $($kept.Count) instance(s)" -ForegroundColor DarkGray
        }
        $windowed.Add($s)
    }
    $seriesList = @($windowed.ToArray())
}

#endregion

#region Step 3: Run the pure delta engine per series

Write-Host '  Step 3: Compute series attestation delta' -ForegroundColor Cyan

$seriesResults = New-Object System.Collections.Generic.List[object]
foreach ($series in $seriesList) {
    # Materialize each instance for the PURE engine (the report layer does the IO).
    $deltaInstances = New-Object System.Collections.Generic.List[object]
    foreach ($inst in @($series.Instances)) {
        $loadedItems = @()
        $loadedRoster = @()
        try { $loadedItems = @(& $inst.LoadItems) } catch { $loadedItems = @() }
        try { $loadedRoster = @(& $inst.LoadRoster) } catch { $loadedRoster = @() }
        $deltaInstances.Add([pscustomobject]@{
                OrderIndex   = $inst.OrderIndex
                CampaignId   = $inst.CampaignId
                CampaignName = $inst.CampaignName
                Status       = $inst.Status
                Unverified   = $inst.Unverified
                PeriodToken  = $inst.PeriodToken
                ChronoKey    = $inst.ChronoKey
                CachedAt     = $inst.CachedAt
                Items        = @($loadedItems)
                Roster       = @($loadedRoster)
            })
    }

    $dr = $null
    try {
        $dr = Get-SPSeriesAttestationDelta -Instances @($deltaInstances.ToArray()) `
            -SeriesStem ([string]$series.SeriesStem) -NormalizedStem ([string]$series.NormalizedStem) `
            -PeriodType ([string]$series.PeriodType) -CorrelationID $correlationID
    } catch {
        Write-Host "    WARN: delta engine threw for series '$($series.NormalizedStem)': $($_.Exception.Message)" -ForegroundColor Yellow
        continue
    }
    if ($null -eq $dr -or -not $dr.Success) {
        $de = if ($null -ne $dr) { [string]$dr.Error } else { 'null result' }
        Write-Host "    WARN: delta engine failed for series '$($series.NormalizedStem)': $de" -ForegroundColor Yellow
        continue
    }

    # Per-INSTANCE single-day completion (V4b-faithful). REUSE the already-built honest engines inside
    # Get-SPSeriesInstanceCompletion (ConvertTo-SPCanonicalDecision via Resolve-SPSeriesItemState /
    # genuine reviewer sign-off from Group-SPCompletedPendingByReviewer / source-aware
    # Get-SPRevocationDisposition) -- NO engine changes. Compute completion for EVERY instance in the
    # window (identical engine + args to the exec box), build a newest-first list, and DERIVE the
    # newest-instance exec-box contract from that same list so nothing is computed twice. Additive:
    # attach to the ordered Data map so ONLY the HTML render layer reads it. Get-V4eJsonSeriesProjection
    # builds JSON from explicit keys, so these new keys never leak into the JSON/console headline
    # (reconciliation kept).
    $instanceCompletionList = New-Object System.Collections.Generic.List[object]
    foreach ($di in @($deltaInstances.ToArray())) {
        $icRes = $null
        try {
            $icRes = Get-SPSeriesInstanceCompletion -Items @($di.Items) -Roster @($di.Roster) `
                -Status ([string]$di.Status) -Unverified ([bool]$di.Unverified) -CorrelationID $correlationID
        } catch {
            Write-Host "    WARN: instance completion threw for series '$($series.NormalizedStem)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
        $comp = $null
        if ($null -ne $icRes -and $icRes.Success) { $comp = $icRes.Data }
        if ($null -eq $comp) {
            # Zero-fill default (mirrors the render-layer default map) so a failed instance never throws.
            $comp = [ordered]@{
                Status = ''; Total = 0; Approved = 0; Revoked = 0; Undecided = 0
                ItemsDecided = 0; ItemsDecidedPct = 0; ReviewersSigned = 0; ReviewersTotal = 0
                Removal = [ordered]@{ Deprovisioned = 0; Queued = 0; Pending = 0 }
            }
        }
        # HONESTY: the rich cache does NOT persist a per-instance completion timestamp, so the closest
        # honest value we can surface is CachedAt -- the moment this instance's evidence was CAPTURED.
        # Expose it under an accurately-labelled "Captured" column (it was previously mislabelled
        # "Completed", which overstated a capture-time proxy as the campaign's true completion time).
        $capturedAt = $null
        if (($di.CachedAt -is [datetime]) -and ($di.CachedAt -ne [datetime]::MinValue)) {
            $capturedAt = $di.CachedAt
        }
        $instanceCompletionList.Add([ordered]@{
                CampaignName = [string]$di.CampaignName
                Status       = [string]$di.Status
                Unverified   = [bool]$di.Unverified
                OrderIndex   = [int]$di.OrderIndex
                Completion   = $comp
                Created      = $di.ChronoKey
                Captured     = $capturedAt
            })
    }
    # Sort newest-first by OrderIndex. NOTE: Sort-Object -Property 'OrderIndex' does NOT extract the
    # key from an [ordered]/hashtable entry in PS 5.1 (it sorts on the whole dictionary), so use an
    # explicit scriptblock expression to read the integer key.
    $instanceCompletions = @($instanceCompletionList.ToArray() | Sort-Object -Property @{ Expression = { [int]$_['OrderIndex'] } } -Descending)
    $dr.Data['InstanceCompletions'] = $instanceCompletions
    if ($instanceCompletions.Count -gt 0) {
        $dr.Data['NewestInstanceCompletion'] = $instanceCompletions[0].Completion
        $dr.Data['NewestInstanceUnverified'] = [bool]$instanceCompletions[0].Unverified
    }
    else {
        $dr.Data['NewestInstanceCompletion'] = $null
        $dr.Data['NewestInstanceUnverified'] = $false
    }

    $seriesResults.Add($dr.Data)
    $na = [int]$dr.Data.Counts['NewlyAttested']
    $pu = [int]$dr.Data.Counts['PersistentlyUndecided']
    Write-Host "    [$($series.NormalizedStem)] instances=$($dr.Data.InstanceCount) newlyAttested=$na persistentlyUndecided=$pu" -ForegroundColor DarkGray
}

$seriesDataList = @($seriesResults.ToArray())

#endregion

#region Step 4: Build HTML report (V4/V4b visual family)

$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$htmlFile = Join-Path $effectiveOutputPath "daily-evidence-v4f-$timestamp.html"

# V4b HTML-escape helper (verbatim from V4b): wraps ConvertTo-SPHtmlSafe; null/whitespace -> ''.
# The verbatim-V4b section copies (later items) call ConvertTo-SafeHtml, so it must resolve here.
function ConvertTo-SafeHtml {
    [OutputType([string])]
    param([Parameter()]$Value)
    if ($null -eq $Value) { return '' }
    $str = [string]$Value
    if ([string]::IsNullOrWhiteSpace($str)) { return '' }
    return (ConvertTo-SPHtmlSafe $str)
}

# Helper: should this item be shown in the headline given the -IncludeUnverified gate?
function Test-V4eItemShown {
    param([object]$Item)
    if ($IncludeUnverified) { return $true }
    $uv = [bool](Get-SPObjectProperty -Object $Item -Name 'Unverified' -Default $false)
    $cuv = [bool](Get-SPObjectProperty -Object $Item -Name 'CurrentUnverified' -Default $false)
    return (-not ($uv -or $cuv))
}

function Get-V4eUnverifiedBadge {
    param([object]$Item)
    $uv = [bool](Get-SPObjectProperty -Object $Item -Name 'Unverified' -Default $false)
    $cuv = [bool](Get-SPObjectProperty -Object $Item -Name 'CurrentUnverified' -Default $false)
    if ($uv -or $cuv) { return " <span class='badge badge-amber'>Unverified</span>" }
    return ''
}

# Helper: reconcile a per-reviewer rollup against the -IncludeUnverified gate. Drops items the
# gate hides (exactly as the HTML tables do via Test-V4eItemShown), recomputes the cluster Count,
# and omits clusters that become empty -- so the JSON rollup mirrors the rendered tables.
function Get-V4eReconcileRollup {
    param([object[]]$Rollup)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rv in @($Rollup)) {
        if ($null -eq $rv) { continue }
        $rvItems = @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())
        $rvShown = @($rvItems | Where-Object { Test-V4eItemShown $_ })
        if ($rvShown.Count -eq 0) { continue }
        $out.Add([ordered]@{
                ReviewerName  = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerName' -Default '(Unassigned)')
                ReviewerId    = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerId' -Default '')
                ReviewerEmail = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerEmail' -Default '')
                Count         = [int]$rvShown.Count
                Items         = @($rvShown)
            })
    }
    return @($out.ToArray())
}

# Helper: project an engine series Data object onto the JSON surface so its headline (Counts +
# reviewer rollups + Items) RECONCILES with the rendered HTML/console under the -IncludeUnverified
# gate. When the gate is OFF (default) Unverified items are excluded from the headline numbers
# exactly as the HTML KPI band and console summary exclude them, so a machine consumer reading the
# JSON never sees an inflated count vs the report it summarizes. The raw pre-gate engine Counts are
# preserved under EngineCounts for audit. When the gate is ON the reconciled values equal the
# engine values (every item is shown). (Honesty doctrine: the headline a reader sees -- human OR
# machine -- must reconcile against the rows it summarizes.)
function Get-V4eJsonSeriesProjection {
    param([object]$Series)

    $allItems = @(Get-SPObjectProperty -Object $Series -Name 'Items' -Default @())
    $shownItems = @($allItems | Where-Object { Test-V4eItemShown $_ })

    # Recompute Counts by Classification from the SHOWN set (the same by-classification method the
    # engine uses, just over the gated rows).
    $recCounts = [ordered]@{
        NewlyInScope           = 0
        DecisionChanged        = 0
        NewlyAttested          = 0
        AlreadyAttestedEarlier = 0
        PersistentlyUndecided  = 0
        OtherDecided           = 0
        Total                  = 0
    }
    foreach ($it in $shownItems) {
        $cls = [string](Get-SPObjectProperty -Object $it -Name 'Classification' -Default '')
        if ($recCounts.Contains($cls)) { $recCounts[$cls] = [int]$recCounts[$cls] + 1 }
        $recCounts['Total'] = [int]$recCounts['Total'] + 1
    }

    return [ordered]@{
        SeriesStem              = [string](Get-SPObjectProperty -Object $Series -Name 'SeriesStem' -Default '')
        NormalizedStem          = [string](Get-SPObjectProperty -Object $Series -Name 'NormalizedStem' -Default '')
        PeriodType              = [string](Get-SPObjectProperty -Object $Series -Name 'PeriodType' -Default '')
        InstanceCount           = [int](Get-SPObjectProperty -Object $Series -Name 'InstanceCount' -Default 0)
        NewestCampaignId        = [string](Get-SPObjectProperty -Object $Series -Name 'NewestCampaignId' -Default '')
        NewestCampaignName      = [string](Get-SPObjectProperty -Object $Series -Name 'NewestCampaignName' -Default '')
        NewestOrderIndex        = [int](Get-SPObjectProperty -Object $Series -Name 'NewestOrderIndex' -Default -1)
        Unverified              = [bool](Get-SPObjectProperty -Object $Series -Name 'Unverified' -Default $false)
        UnverifiedInstanceCount = [int](Get-SPObjectProperty -Object $Series -Name 'UnverifiedInstanceCount' -Default 0)
        IncludeUnverified       = [bool]$IncludeUnverified
        UnverifiedItemsExcluded = [int]($allItems.Count - $shownItems.Count)
        Counts                  = $recCounts
        EngineCounts            = (Get-SPObjectProperty -Object $Series -Name 'Counts' -Default @{})
        NewlyAttestedByReviewer         = (Get-V4eReconcileRollup (Get-SPObjectProperty -Object $Series -Name 'NewlyAttestedByReviewer' -Default @()))
        PersistentlyUndecidedByReviewer = (Get-V4eReconcileRollup (Get-SPObjectProperty -Object $Series -Name 'PersistentlyUndecidedByReviewer' -Default @()))
        Items                   = @($shownItems)
    }
}

# Build the V4-style decision-distribution donut (SVG + legend) from classification segments.
function New-V4eDonut {
    param([object[]]$Segments, [int]$Total, [string]$CenterLabel = 'items')
    if ($Total -le 0) { return "<p class='note' style='text-align:center'>No items in window.</p>" }
    $out = New-Object System.Text.StringBuilder
    [void]$out.Append("<svg width='140' height='140' viewBox='0 0 42 42' style='display:block;margin:0 auto'>")
    [void]$out.Append("<circle cx='21' cy='21' r='15.9' pathLength='100' fill='transparent' stroke='#e0e0e0' stroke-width='3.2'></circle>")
    $cum = 0.0
    foreach ($seg in $Segments) {
        $cnt = [int](Get-SPObjectProperty -Object $seg -Name 'Count' -Default 0)
        if ($cnt -le 0) { continue }
        $pct = [math]::Round($cnt * 100.0 / $Total, 1)
        $rest = [math]::Round(100 - $pct, 1)
        $off = [math]::Round(-$cum, 1)
        $col = [string](Get-SPObjectProperty -Object $seg -Name 'Color' -Default '#999999')
        [void]$out.Append("<circle cx='21' cy='21' r='15.9' pathLength='100' fill='transparent' stroke='$col' stroke-width='3.2' stroke-dasharray='$pct $rest' stroke-dashoffset='$off' transform='rotate(-90 21 21)'></circle>")
        $cum += $pct
    }
    [void]$out.Append("<text x='21' y='19.5' text-anchor='middle' style='font-size:5px;font-weight:bold;fill:#2c3e50'>$Total</text>")
    [void]$out.Append("<text x='21' y='24' text-anchor='middle' style='font-size:2.8px;fill:#777'>$CenterLabel</text></svg>")
    [void]$out.Append("<table style='margin:8px auto 0;font-size:11px;border-collapse:collapse'>")
    foreach ($seg in $Segments) {
        $cnt = [int](Get-SPObjectProperty -Object $seg -Name 'Count' -Default 0)
        if ($cnt -le 0) { continue }
        $pct = [math]::Round($cnt * 100.0 / $Total, 1)
        $col = [string](Get-SPObjectProperty -Object $seg -Name 'Color' -Default '#999999')
        $lbl = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $seg -Name 'Label' -Default ''))
        [void]$out.Append("<tr><td style='padding:2px 4px'><svg width='10' height='10'><circle cx='5' cy='5' r='4' fill='$col'/></svg></td><td style='padding:2px 6px;color:#555'>$lbl`: $cnt ($pct%)</td></tr>")
    }
    [void]$out.Append("</table>")
    return $out.ToString()
}

$css = @'
*{box-sizing:border-box}
body{font-family:"Segoe UI",Arial,sans-serif;background:#f4f6f9;color:#333;margin:0;padding:20px}
.container{max-width:1100px;margin:0 auto}
.header{background:linear-gradient(135deg,#264d73,#336699);color:#fff;padding:24px 32px;border-radius:8px 8px 0 0}
.header h1{margin:0 0 6px;font-size:22px}.header .meta{font-size:12px;opacity:.85}
.header .status-line{margin-top:8px;font-size:13px;opacity:.9}
.section{background:#fff;border:1px solid #e0e0e0;border-top:none;padding:20px 32px}
.section h2{color:#264d73;font-size:15px;border-bottom:2px solid #e8eef5;padding-bottom:6px;margin-top:0}
.scope-inline{display:flex;flex-wrap:wrap;gap:12px 26px;font-size:13px;color:#555;margin-top:4px}
.scope-inline .n{font-size:22px;font-weight:700;color:#264d73;display:block;line-height:1.1}
.scope-inline .t{font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:#777}
.execbox{background:#f8f9fa;border:1px solid #e0e0e0;border-top:none;padding:20px 32px;font-family:-apple-system,'Segoe UI',system-ui,sans-serif}
.execbox h3{color:#2c3e50;margin:0 0 16px;font-size:16px;border-bottom:2px solid #336699;padding-bottom:6px}
table.report{border-collapse:collapse;width:100%;margin:12px 0;font-size:12px}
table.report th{background:#e8eef5;padding:8px 10px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;color:#555}
table.report td{padding:7px 10px;border-bottom:1px solid #eee}table.report tr:nth-child(even){background:#fafafa}
.s-green{color:#339933;font-weight:600}.s-amber{color:#9a6700;font-weight:600}.s-red{color:#CC3333;font-weight:600}.s-gray{color:#777}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600}
.badge-priv{background:#ffcdd2;color:#b71c1c}
.badge-amber{background:#fff3cd;color:#9a6700}
summary{cursor:pointer}
.subhead{font-size:13px;color:#264d73;margin:16px 0 4px;font-weight:bold}
.footer{text-align:center;color:#999;font-size:11px;padding:16px;border-top:1px solid #eee}
.section:last-of-type{border-radius:0 0 8px 8px}
@media print{body{background:#fff;padding:0}.container{max-width:100%}.header{border-radius:0}}
'@

$sb = New-Object System.Text.StringBuilder 32768
[void]$sb.AppendLine("<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence Report v4e -- Series Attestation Delta</title><style>$css</style></head><body><div class='container'>")

# Header banner (V4/V4b family chrome)
$totalNA = 0; $totalPU = 0
$totalInstances = 0
$reviewerSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($sd0 in $seriesDataList) {
    $it0 = @(@(Get-SPObjectProperty -Object $sd0 -Name 'Items' -Default @()) | Where-Object { Test-V4eItemShown $_ })
    $totalNA += @($it0 | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'NewlyAttested' }).Count
    $totalPU += @($it0 | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'PersistentlyUndecided' }).Count
    $totalInstances += [int](Get-SPObjectProperty -Object $sd0 -Name 'InstanceCount' -Default 0)
    foreach ($rItem in $it0) {
        $rid = [string](Get-SPObjectProperty -Object $rItem -Name 'CurrentReviewerId' -Default '')
        $rnm = [string](Get-SPObjectProperty -Object $rItem -Name 'CurrentReviewerName' -Default '')
        $rk = if ($rid) { $rid } else { $rnm }
        if ($rk) { [void]$reviewerSet.Add($rk) }
    }
}
$unvMode = if ($IncludeUnverified) { 'INCLUDED (badged)' } else { 'EXCLUDED from headline' }
# ---- HEADER (V4b shell, verbatim markup rebound to series data) ----
[void]$sb.AppendLine('<div class="header">')
[void]$sb.AppendLine('<h1>Daily Evidence Report</h1>')
[void]$sb.AppendLine('<div class="meta">SailPoint ISC Governance Toolkit | Series Attestation Delta (v4e) | Cache: ' + (ConvertTo-SafeHtml $cacheDir) + ' | Generated: ' + $genDate + '</div>')
[void]$sb.AppendLine('<div class="status-line">' + $seriesDataList.Count + ' series analyzed &middot; ' + $totalNA + ' newly attested &middot; ' + $totalPU + ' persistently undecided &middot; Unverified: ' + $unvMode + ' &middot; Min instances: ' + $MinInstances + '</div>')
[void]$sb.AppendLine('</div>')

# ---- Certification Scope (V4b shell, verbatim markup rebound to series totals) ----
[void]$sb.AppendLine('<div class="section"><h2>Certification Scope</h2><div class="scope-inline">')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $seriesDataList.Count) + '</span><span class="t">recurring series</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $totalInstances) + '</span><span class="t">campaign instances</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $totalNA) + '</span><span class="t">newly attested</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + ('{0:N0}' -f $totalPU) + '</span><span class="t">persistently undecided</span></div>')
[void]$sb.AppendLine('<div><span class="n">' + $reviewerSet.Count + '</span><span class="t">reviewers involved</span></div>')
[void]$sb.AppendLine('</div></div>')

# V4b decision-distribution donut lambda (VERBATIM from Invoke-SPDailyEvidenceReportV4b.ps1 render
# region, lines 1682-1699). Rebound per series to the NEWEST-instance approve/revoke/undecided
# percentages so the exec-box donut is byte-faithful to V4b. Defined once before the render loop.
$donut = {
    param($ap, $rp, $pp, $tot)
    if ($tot -le 0) { return '<div style="color:#999;font-size:11px;padding:48px 0">No items</div>' }
    $o2 = -$ap
    $o3 = -([math]::Round($ap + $rp, 1))
    $ar1 = [math]::Round(100 - $ap, 1); $ar2 = [math]::Round(100 - $rp, 1); $ar3 = [math]::Round(100 - $pp, 1)
    $tf = '{0:N0}' -f $tot
    return @"
<svg width="140" height="140" viewBox="0 0 42 42" style="display:block;margin:0 auto">
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#e0e0e0" stroke-width="3.2"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#339933" stroke-width="3.2" stroke-dasharray="$ap $ar1" stroke-dashoffset="0" transform="rotate(-90 21 21)"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#CC3333" stroke-width="3.2" stroke-dasharray="$rp $ar2" stroke-dashoffset="$o2" transform="rotate(-90 21 21)"></circle>
<circle cx="21" cy="21" r="15.9" pathLength="100" fill="transparent" stroke="#FF8800" stroke-width="3.2" stroke-dasharray="$pp $ar3" stroke-dashoffset="$o3" transform="rotate(-90 21 21)"></circle>
<text x="21" y="19.5" text-anchor="middle" style="font-size:5px;font-weight:bold;fill:#2c3e50">$tf</text>
<text x="21" y="24" text-anchor="middle" style="font-size:2.8px;fill:#777">items</text>
</svg>
"@
}

# V4b date formatter lambda (VERBATIM from Invoke-SPDailyEvidenceReportV4b.ps1 lines 1672-1676).
# Fed a string (blank -> '-'); used by Section A's Created/Captured columns. Defined once here.
$fmtDt = {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return '-' }
    try { return ([datetime]::Parse($s)).ToString('yyyy-MM-dd HH:mm') } catch { return $s }
}

# PER-SERIES BODY = PLACEHOLDER (SCAFFOLD-V4E). Later items replace this loop with the verbatim
# V4b execbox / Section A / Section B / Decision Summary chrome rebound to series-attestation data.
if ($seriesDataList.Count -eq 0) {
    [void]$sb.AppendLine('<div class="section"><h2>No recurring series found</h2>')
    [void]$sb.AppendLine('<p>The cache contains no campaign family with at least ' + $MinInstances + ' instance(s) sharing a normalized series stem.</p></div>')
}
foreach ($sd in $seriesDataList) {
    $stem = [string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default '')
    $periodType = [string](Get-SPObjectProperty -Object $sd -Name 'PeriodType' -Default '')
    $instCount = [int](Get-SPObjectProperty -Object $sd -Name 'InstanceCount' -Default 0)
    $newestName = [string](Get-SPObjectProperty -Object $sd -Name 'NewestCampaignName' -Default '')

    # Compute the classification count map ONCE from the -IncludeUnverified-gated item set. The
    # donut, the two metric cells, the coverage blurb, AND Key Indicators all read from THIS SAME
    # map -- honesty reconciliation: every surface counts the same rows (mirror Get-V4eJsonSeries-
    # Projection's recCounts loop so the HTML and JSON headlines match).
    $allItems = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
    $shownItems = @($allItems | Where-Object { Test-V4eItemShown $_ })
    $shownTotal = $shownItems.Count
    $clsCounts = [ordered]@{
        NewlyInScope           = 0
        DecisionChanged        = 0
        NewlyAttested          = 0
        AlreadyAttestedEarlier = 0
        PersistentlyUndecided  = 0
        OtherDecided           = 0
    }
    # Coverage denominator input: count the INDEPENDENT IsPersistentlyUndecided fact in
    # the same pass. The Classification precedence ladder masks it -- an item that has
    # never been genuinely decided but is new in the latest instance classifies as
    # NewlyInScope, so subtracting only Classification=='PersistentlyUndecided' counted
    # brand-new undecided entitlements as "genuinely attested" (10 new undecided items
    # could render '100% genuinely attested').
    $cUndecidedFact = 0
    foreach ($it in $shownItems) {
        $cls = [string](Get-SPObjectProperty -Object $it -Name 'Classification' -Default '')
        if ($clsCounts.Contains($cls)) { $clsCounts[$cls] = [int]$clsCounts[$cls] + 1 }
        if ([bool](Get-SPObjectProperty -Object $it -Name 'IsPersistentlyUndecided' -Default $false)) { $cUndecidedFact++ }
    }
    $cNA = [int]$clsCounts['NewlyAttested']
    $cAA = [int]$clsCounts['AlreadyAttestedEarlier']
    $cPU = [int]$clsCounts['PersistentlyUndecided']
    $cDC = [int]$clsCounts['DecisionChanged']
    $cNS = [int]$clsCounts['NewlyInScope']
    $cOD = [int]$clsCounts['OtherDecided']

    # h3 name + status badge (family blue; a series has no COMPLETED status).
    $seriesNameSafe = ConvertTo-SafeHtml $stem
    $periodUp = ''
    if (-not [string]::IsNullOrWhiteSpace($periodType)) { $periodUp = $periodType.ToUpperInvariant() }
    $statusBadge = ConvertTo-SafeHtml ("$periodUp SERIES - $instCount INSTANCES")
    # Health-color the badge like V4b's status badge: green when nothing is left persistently
    # undecided, amber when the series still has never-attested items.
    $badgeBg = if ($cPU -eq 0) { '#339933' } else { '#9a6700' }

    # Metadata table values.
    $periodTypeSafe = ConvertTo-SafeHtml $periodType
    $newestNameSafe = ConvertTo-SafeHtml $newestName

    # Donut segments over the SAME gated set (New-V4eDonut emits svg + legend, drops zero rows).
    $segs = @(
        [pscustomobject]@{ Label = 'Newly Attested';        Count = $cNA; Color = '#339933' }
        [pscustomobject]@{ Label = 'Already Attested';      Count = $cAA; Color = '#336699' }
        [pscustomobject]@{ Label = 'Persistently Undecided'; Count = $cPU; Color = '#CC3333' }
        [pscustomobject]@{ Label = 'Decision Changed';      Count = $cDC; Color = '#FF8800' }
        [pscustomobject]@{ Label = 'Newly In Scope';        Count = $cNS; Color = '#17a2b8' }
        [pscustomobject]@{ Label = 'Other Decided';         Count = $cOD; Color = '#999999' }
    )
    $donutSvg = New-V4eDonut -Segments $segs -Total $shownTotal -CenterLabel 'items'

    # Attestation-coverage VISUAL panel (mirrors V4b's removal-status panel: big %, bar, labels)
    # in place of the dropped per-campaign removal status; series-rebound.
    # 'Genuinely attested' = has at least one genuine (non-auto-approved) decision anywhere
    # in the series: subtract the independent undecided FACT, not the masked classification.
    $covered = $shownTotal - $cUndecidedFact
    $covPct = if ($shownTotal -gt 0) { [int][math]::Round($covered / $shownTotal * 100) } else { 0 }
    $undPct = 100 - $covPct
    $covColor = if ($covPct -ge 80) { '#339933' } elseif ($covPct -ge 50) { '#9a6700' } else { '#CC3333' }

    # ---- NEWEST-INSTANCE single-day completion (V4b-faithful). Read the completion Data attached in
    # Step 3 (Get-SPSeriesInstanceCompletion -- honest classifier / roster sign-off / removal). Zero-
    # fill a default map when absent so the panel never throws. All V4b render formulas below are
    # copied byte-for-byte from Invoke-SPDailyEvidenceReportV4b.ps1, only rebinding the source vars.
    $ic = Get-SPObjectProperty -Object $sd -Name 'NewestInstanceCompletion' -Default $null
    if ($null -eq $ic) {
        $ic = [ordered]@{
            Status = ''; Total = 0; Approved = 0; Revoked = 0; Undecided = 0
            ItemsDecided = 0; ItemsDecidedPct = 0; ReviewersSigned = 0; ReviewersTotal = 0
            Removal = [ordered]@{ Deprovisioned = 0; Queued = 0; Pending = 0 }
        }
    }
    $icTotal      = [int]$ic['Total']
    $icApproved   = [int]$ic['Approved']
    $icRevoked    = [int]$ic['Revoked']
    $icUndecided  = [int]$ic['Undecided']
    $icDecided    = [int]$ic['ItemsDecided']
    $icDecidedPct = [int]$ic['ItemsDecidedPct']
    $icRevSigned  = [int]$ic['ReviewersSigned']
    $icRevTotal   = [int]$ic['ReviewersTotal']
    $icRemoval    = $ic['Removal']
    $removed = [int]$icRemoval['Deprovisioned']
    $queued  = [int]$icRemoval['Queued']
    $remPend = [int]$icRemoval['Pending']
    $totRevoked = $icRevoked

    # Status badge (V4b 1868): newest-instance ACTUAL status, green when COMPLETED/COMPLETING.
    $icStatusRaw = ([string]$ic['Status']).ToUpperInvariant()
    $stColor = switch ($icStatusRaw) { 'COMPLETED' { '#339933' } 'COMPLETING' { '#339933' } default { '#336699' } }
    $cStatusUp = ConvertTo-SafeHtml $icStatusRaw

    # Closed-incomplete honest qualifier row (V4b 1880-1884), guarded.
    $qualSubRow = ''
    if (Get-Command Get-SPClosedIncompleteQualifier -ErrorAction Ignore) {
        $qExec = Get-SPClosedIncompleteQualifier -Status $icStatusRaw -ReviewersSigned $icRevSigned -ReviewersTotal $icRevTotal -UndecidedCount $icUndecided
        if ($qExec.IsClosedIncomplete) {
            $qualSubRow = '<tr><td colspan="2" style="padding:6px 8px;border:1px solid #b9770e;background:#fff8e1;color:#7a5200;font-size:11px;font-weight:600;border-radius:0 0 6px 6px">&#9888; ' + (ConvertTo-SafeHtml $qExec.Caption) + '</td></tr>'
        }
    }

    # Reviewer completion (V4b 1853 + 1869), guarded with a manual fraction/percent fallback.
    $rvc = $null
    if (Get-Command Get-SPReviewerCompletion -ErrorAction Ignore) {
        $rvc = Get-SPReviewerCompletion -Signed $icRevSigned -Total $icRevTotal
    }
    if ($null -ne $rvc) {
        $rvcFraction = [string]$rvc.FractionLabel
        $rvcPercent  = [string]$rvc.PercentLabel
        $revCompPct  = [int]$rvc.Pct
    }
    else {
        $revCompPct  = if ($icRevTotal -gt 0) { [int][math]::Round($icRevSigned / $icRevTotal * 100, 0) } else { 0 }
        $rvcFraction = "$icRevSigned / $icRevTotal"
        $rvcPercent  = "$revCompPct%"
    }
    $revCompColor = if ($revCompPct -ge 100) { '#339933' } elseif ($revCompPct -ge 50) { '#FF9900' } else { '#CC3333' }
    $pendColor = if ($icUndecided -eq 0) { '#339933' } else { '#FF9900' }

    # Newest-instance decision-distribution donut % (V4b 1822-1827: sum-to-100 correction + sliver).
    $apct = if ($icTotal -gt 0) { [math]::Round($icApproved / $icTotal * 100, 1) } else { 0 }
    $rpct = if ($icTotal -gt 0) { [math]::Round($icRevoked / $icTotal * 100, 1) } else { 0 }
    $ppct = if ($icTotal -gt 0) { [math]::Round($icUndecided / $icTotal * 100, 1) } else { 0 }
    if ($icTotal -gt 0 -and ($apct + $rpct + $ppct) -ne 100) { $apct = [math]::Round(100 - $rpct - $ppct, 1) }
    if ($icUndecided -gt 0 -and $ppct -lt 0.5) { $ppct = 0.5; $apct = [math]::Round(100 - $rpct - $ppct, 1) }
    $execDonutSvg = & $donut $apct $rpct $ppct $icTotal

    # Removal status (V4b 1865-1895) rebound to the newest instance's Removal counts.
    $remPct = if ($totRevoked -gt 0) { [math]::Round($removed / $totRevoked * 100, 0) } else { 0 }
    $qPct   = if ($totRevoked -gt 0) { [math]::Round($queued / $totRevoked * 100, 0) } else { 0 }
    $remPendPct = 100 - $remPct - $qPct; if ($remPendPct -lt 0) { $remPendPct = 0 }
    $remColor = if ($totRevoked -eq 0) { '#777777' } elseif ($remPct -ge 100) { '#339933' } elseif ($remPct -ge 50) { '#FF9900' } else { '#CC3333' }
    if ($totRevoked -gt 0) {
        $remBlock = @"
<div style="text-align:center;margin-bottom:10px"><span style="font-size:36px;font-weight:bold;color:$remColor">$remPct%</span><br><span style="font-size:12px;color:#777">$removed of $totRevoked deprovisioned (connected AD)</span></div>
<table style="width:100%;border-collapse:collapse;height:18px;margin-bottom:6px"><tr><td style="width:$remPct%;background:#339933;height:18px;border-radius:4px 0 0 4px"></td><td style="width:$qPct%;background:#336699;height:18px"></td><td style="width:$remPendPct%;background:#FF8800;height:18px;border-radius:0 4px 4px 0"></td></tr></table>
<table style="width:100%;font-size:11px;border-collapse:collapse"><tr><td style="color:#339933;font-weight:bold;padding:2px 0">$removed Deprovisioned</td><td style="color:#264d73;font-weight:bold;text-align:center;padding:2px 0">$queued Queued</td><td style="color:#FF8800;font-weight:bold;text-align:right;padding:2px 0">$remPend Pending</td></tr></table>
<p style="font-size:10px;color:#999;margin:6px 0 0;text-align:center;font-style:italic">Deprovisioned = revoke completed on a connected Active Directory source. Queued = revoke recorded on a disconnected / other source; actual removal is fulfilled downstream and not confirmed here.</p>
"@
    }
    else {
        $remBlock = '<div style="text-align:center;color:#777;font-size:13px;padding:18px 0">No revocations in this campaign.</div>'
    }

    # Unverified honesty: badge (never blank) the exec h3 when the newest instance is Unverified and
    # the gate is off (mirror Get-V4eUnverifiedBadge).
    $execUnvBadge = ''
    $newestUnv = [bool](Get-SPObjectProperty -Object $sd -Name 'NewestInstanceUnverified' -Default $false)
    if ($newestUnv -and (-not $IncludeUnverified)) {
        $execUnvBadge = " <span class='badge badge-amber'>Unverified</span>"
    }

    # Compact series-attestation coverage stat (moved off the middle column; Removal Status now owns
    # it). Reuses $covered/$covPct/$shownTotal/$instCount computed above.
    $coverageStat = "<p style='font-size:11px;color:#777;text-align:center'>Series attestation coverage: $covPct% ($covered of $shownTotal genuinely attested across $instCount instances)</p>"

    $execHtml = @"
<div class="execbox">
<h3>Executive Summary &mdash; $seriesNameSafe$execUnvBadge</h3>
<table style="width:100%;border-collapse:collapse;margin-bottom:18px"><tr>
<td style="width:50%;vertical-align:top;padding-right:16px">
<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr><td colspan="2" style="padding:12px 16px;background:$stColor;border-radius:6px;text-align:center"><span style="color:#fff;font-size:22px;font-weight:bold;letter-spacing:1px">$cStatusUp</span></td></tr>
$qualSubRow
<tr>
<td style="padding:10px 4px;text-align:center;color:#555;font-size:12px"><span style="font-weight:bold;font-size:16px;color:#2c3e50">$rvcFraction</span><br>Reviewers Signed Off</td>
<td style="padding:10px 4px;text-align:center;color:#555;font-size:12px"><span style="font-weight:bold;font-size:16px;color:#2c3e50">$('{0:N0}' -f $icDecided) / $('{0:N0}' -f $icTotal)</span><br>Items Decided ($icDecidedPct%)</td>
</tr>
</table>
</td>
<td style="width:50%;vertical-align:top;padding-left:16px">
<table style="width:100%;border-collapse:collapse;font-size:13px">
<tr><td style="padding:6px 8px;font-weight:bold;color:#555;width:120px">Series</td><td style="padding:6px 8px;color:#2c3e50">$seriesNameSafe</td></tr>
<tr><td style="padding:6px 8px;font-weight:bold;color:#555">Period type</td><td style="padding:6px 8px;color:#2c3e50">$periodTypeSafe</td></tr>
<tr><td style="padding:6px 8px;font-weight:bold;color:#555">Instances</td><td style="padding:6px 8px;color:#2c3e50">$instCount</td></tr>
<tr><td style="padding:6px 8px;font-weight:bold;color:#555">Newest</td><td style="padding:6px 8px;color:#2c3e50">$newestNameSafe</td></tr>
</table>
</td>
</tr></table>
<table style="width:100%;border-collapse:collapse"><tr>
<td style="width:33%;vertical-align:top;padding-right:12px;text-align:center">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Decision Distribution</p>
$execDonutSvg
<table style="margin:8px auto 0;font-size:11px;border-collapse:collapse">
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#339933"/></svg></td><td style="padding:2px 6px;color:#555">Approved: $('{0:N0}' -f $icApproved) ($apct%)</td></tr>
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#CC3333"/></svg></td><td style="padding:2px 6px;color:#555">Revoked: $('{0:N0}' -f $icRevoked) ($rpct%)</td></tr>
<tr><td style="padding:2px 4px"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="#FF8800"/></svg></td><td style="padding:2px 6px;color:#555">Undecided: $('{0:N0}' -f $icUndecided) ($ppct%)</td></tr>
</table>
</td>
<td style="width:34%;vertical-align:top;padding:0 12px">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Revoked Access &mdash; Removal Status</p>
$remBlock
</td>
<td style="width:33%;vertical-align:top;padding-left:12px">
<p style="font-weight:bold;font-size:12px;color:#555;margin:0 0 8px">Key Indicators</p>
<table style="width:100%;border-collapse:collapse;font-size:12px">
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;width:20px"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$revCompColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Reviewer Completion</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$revCompColor">$rvcPercent</td></tr>
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$pendColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Pending Items</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$pendColor">$('{0:N0}' -f $icUndecided)</td></tr>
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="$remColor"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Deprovisioned (AD)</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:$remColor">$remPct%</td></tr>
<tr><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#339933"/></svg></td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;color:#555">Newly Attested</td><td style="padding:5px 4px;border-bottom:1px solid #e0e0e0;font-weight:bold;text-align:right;color:#339933">$cNA</td></tr>
<tr><td style="padding:5px 4px"><svg width="12" height="12"><circle cx="6" cy="6" r="5" fill="#CC3333"/></svg></td><td style="padding:5px 4px;color:#555">Persistently Undecided</td><td style="padding:5px 4px;font-weight:bold;text-align:right;color:#CC3333">$cPU</td></tr>
</table>
</td>
</tr></table>
$coverageStat
</div>
"@
    [void]$sb.AppendLine($execHtml)
    [void]$sb.AppendLine('<!-- SCAFFOLD-V4E: Section B / Decision Summary pending for ' + (ConvertTo-SafeHtml $stem) + ' -->')
}

# ---- A. Campaign Completion Evidence (by instance) (V4b table.report chrome, rebound per instance) ----
# ONE row per INSTANCE in the window (newest first), grouped by series with a subhead when >1 series.
# The day-by-day multi-day completion view. Numbers come from Get-SPSeriesInstanceCompletion (the SAME
# honest engine + args the newest-instance exec box uses), so the newest row's Items Decided / Total
# reconciles byte-for-byte with the exec box, and the total row count across series equals the
# Certification Scope 'campaign instances' count. V4b-EXACT table.report markup + s-* cell classes.
if ($seriesDataList.Count -gt 0) {
    [void]$sb.AppendLine('<div class="section"><h2>A. Campaign Completion Evidence (by instance)</h2>')
    $multiSeries = $seriesDataList.Count -gt 1
    foreach ($sd in $seriesDataList) {
        if ($multiSeries) {
            [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default ''))) + '</div>')
        }
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Campaign</th><th>Status</th><th>Total Items</th><th>Approved</th><th>Revoked</th><th>Undecided</th><th>Items Decided %</th><th>Reviewer %</th><th>Created</th><th>Captured</th></tr></thead><tbody>')
        $comps = @(Get-SPObjectProperty -Object $sd -Name 'InstanceCompletions' -Default @())
        foreach ($e in $comps) {
            $ic = $e.Completion
            $t = [int]$ic['Total']; $a = [int]$ic['Approved']; $r = [int]$ic['Revoked']; $p = [int]$ic['Undecided']
            $pc = [int]$ic['ItemsDecidedPct']
            $pcCls = if ($pc -ge 80) { 's-green' } elseif ($pc -ge 50) { 's-amber' } else { 's-red' }

            # Reviewer % via the SAME guarded Get-SPReviewerCompletion the exec box uses.
            $icSigned = [int]$ic['ReviewersSigned']; $icTotalRev = [int]$ic['ReviewersTotal']
            $rvcA = $null
            if (Get-Command Get-SPReviewerCompletion -ErrorAction Ignore) {
                $rvcA = Get-SPReviewerCompletion -Signed $icSigned -Total $icTotalRev
            }
            if ($null -ne $rvcA) {
                $rvLabel = [string]$rvcA.CombinedLabel
                $rvCls = switch ($rvcA.SeverityClass) { 'green' { 's-green' } 'amber' { 's-amber' } 'red' { 's-red' } default { 's-amber' } }
            }
            else {
                $rvPct = if ($icTotalRev -gt 0) { [math]::Round($icSigned / $icTotalRev * 100, 0) } else { 0 }
                $rvLabel = "$rvPct% ($icSigned/$icTotalRev)"
                $rvCls = if ($rvPct -ge 80) { 's-green' } elseif ($rvPct -ge 50) { 's-amber' } else { 's-red' }
            }

            # Campaign (instance) name; badge Unverified instances when off-gate (NEVER drop the row).
            $cn = ConvertTo-SafeHtml ([string]$e.CampaignName)
            if ([bool]$e.Unverified -and -not $IncludeUnverified) {
                $cn = $cn + " <span class='badge badge-amber'>Unverified</span>"
            }

            # Status cell (fall back to the instance status when the engine status is blank), plus the
            # optional closed-incomplete honest qualifier sub-line (keeps the 10-column shape).
            $icStatus = [string]$ic['Status']
            if ([string]::IsNullOrWhiteSpace($icStatus)) { $icStatus = [string]$e.Status }
            $cs = ConvertTo-SafeHtml $icStatus
            if (Get-Command Get-SPClosedIncompleteQualifier -ErrorAction Ignore) {
                $qA = Get-SPClosedIncompleteQualifier -Status $icStatus -ReviewersSigned $icSigned -ReviewersTotal $icTotalRev -UndecidedCount $p
                if ($qA.IsClosedIncomplete) {
                    $cs = $cs + "<br><span class='s-amber' style='font-size:10px'>" + (ConvertTo-SafeHtml $qA.Caption) + "</span>"
                }
            }

            # Created / Captured via the V4b $fmtDt lambda (blank -> '-'). Captured = CachedAt (the
            # evidence-capture time); the cache has no true per-instance completion timestamp.
            $crStr = if ($e.Created -is [datetime] -and $e.Created -ne [datetime]::MinValue) { $e.Created.ToString('o') } else { '' }
            $cmpStr = if ($e.Captured -is [datetime] -and $e.Captured -ne [datetime]::MinValue) { $e.Captured.ToString('o') } else { '' }
            $cr = & $fmtDt $crStr
            $cmp = & $fmtDt $cmpStr

            [void]$sb.AppendLine("<tr><td>$cn</td><td>$cs</td><td>$('{0:N0}' -f $t)</td><td>$('{0:N0}' -f $a)</td><td class='s-red'>$('{0:N0}' -f $r)</td><td>$('{0:N0}' -f $p)</td><td class='$pcCls'>$pc%</td><td class='$rvCls'>$rvLabel</td><td>$cr</td><td>$cmp</td></tr>")
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    [void]$sb.AppendLine('</div>')
}

# ---- B. Reviewer Accountability (V4b Section-B chrome, rebound to series reviewer rollups) ----
# The NEW content the user wants preserved: TWO per-reviewer breakdowns per series --
#   (1) "Newly Attested by Reviewer"                     -- who FINALLY (genuinely) attested each item.
#   (2) "Persistently Undecided / Never Attested by Reviewer" -- items never genuinely decided across the window.
# Attribution is to the cert-ASSIGNED reviewer via the engine's NewlyAttestedByReviewer /
# PersistentlyUndecidedByReviewer rollups. Every rollup is passed through Get-V4eReconcileRollup so
# the per-reviewer counts here reconcile with Section A and the exec box under -IncludeUnverified
# (same reconciled rollups the JSON emits => HTML == JSON == Section A). DROP the V4b per-campaign
# machinery (Group-SPCompletedPendingByReviewer, reassigned/force-close/active-vs-completed) -- a
# recurring series has no single cert Status; this is a pure series reviewer roll-up.
if ($seriesDataList.Count -gt 0) {
    [void]$sb.AppendLine('<div class="section"><h2>B. Reviewer Accountability</h2>')
    $anyRev = $false
    foreach ($sd in $seriesDataList) {
        $naRollup = @(Get-V4eReconcileRollup (Get-SPObjectProperty -Object $sd -Name 'NewlyAttestedByReviewer' -Default @()))
        $puRollup = @(Get-V4eReconcileRollup (Get-SPObjectProperty -Object $sd -Name 'PersistentlyUndecidedByReviewer' -Default @()))
        if ($naRollup.Count -eq 0 -and $puRollup.Count -eq 0) { continue }
        $anyRev = $true
        [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default ''))) + '</div>')

        # (1) Newly Attested by Reviewer -- reviewer + email + count + the items they finally attested.
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:12px;margin-bottom:4px'>Newly Attested by Reviewer (" + @($naRollup).Count + ")</summary>")
        [void]$sb.AppendLine("<div style='font-size:11px;color:#777;margin-bottom:4px'>First GENUINE (honest) reviewer approval of each identity+entitlement in the window. Auto-approved-at-close and pending are NOT counted.</div>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th style="text-align:right">Newly Attested</th><th>Items Attested</th></tr></thead><tbody>')
        if ($naRollup.Count -eq 0) {
            [void]$sb.AppendLine('<tr><td colspan="4" style="color:#777;font-style:italic">No genuine first-time approvals in this window.</td></tr>')
        }
        else {
            foreach ($rv in $naRollup) {
                $rvName = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerName' -Default '')
                if ([string]::IsNullOrWhiteSpace($rvName)) { $rvName = '(Unassigned)' }
                $rvEmail = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerEmail' -Default '')
                $rvCount = [int](Get-SPObjectProperty -Object $rv -Name 'Count' -Default 0)
                $rowBg = if ($rvName -eq '(Unassigned)') { " style='background:#fdecec'" } else { '' }
                $itemsCell = New-Object System.Text.StringBuilder
                foreach ($it in @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())) {
                    $idn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
                    $acc = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
                    $src = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
                    $bdg = Get-V4eUnverifiedBadge $it
                    [void]$itemsCell.Append("<div style='padding:1px 0'>$idn &mdash; $acc <span class='s-gray'>($src)</span>$bdg</div>")
                }
                [void]$sb.AppendLine("<tr$rowBg><td style='font-weight:600'>" + (ConvertTo-SafeHtml $rvName) + "</td><td>" + (ConvertTo-SafeHtml $rvEmail) + "</td><td style='text-align:right;font-weight:600' class='s-green'>$rvCount</td><td>" + $itemsCell.ToString() + "</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></details>')

        # (2) Persistently Undecided / Never Attested by Reviewer -- items never genuinely decided across the window.
        [void]$sb.AppendLine("<details><summary style='font-weight:bold;font-size:12px;margin:8px 0 4px'>Persistently Undecided / Never Attested by Reviewer (" + @($puRollup).Count + ")</summary>")
        [void]$sb.AppendLine("<div style='font-size:11px;color:#777;margin-bottom:4px'>Items never genuinely decided in ANY instance across the window, grouped by the cert-assigned reviewer.</div>")
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Reviewer</th><th>Email</th><th style="text-align:right">Never Attested</th><th>Items Never Decided</th></tr></thead><tbody>')
        if ($puRollup.Count -eq 0) {
            [void]$sb.AppendLine('<tr><td colspan="4" style="color:#777;font-style:italic">No persistently-undecided items in this window.</td></tr>')
        }
        else {
            foreach ($rv in $puRollup) {
                $rvName = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerName' -Default '')
                if ([string]::IsNullOrWhiteSpace($rvName)) { $rvName = '(Unassigned)' }
                $rvEmail = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerEmail' -Default '')
                $rvCount = [int](Get-SPObjectProperty -Object $rv -Name 'Count' -Default 0)
                $rowBg = if ($rvName -eq '(Unassigned)') { " style='background:#fdecec'" } else { '' }
                $itemsCell = New-Object System.Text.StringBuilder
                foreach ($it in @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())) {
                    $idn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
                    $acc = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
                    $src = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
                    $cur = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default 'Undecided'))
                    $bdg = Get-V4eUnverifiedBadge $it
                    [void]$itemsCell.Append("<div style='padding:1px 0'>$idn &mdash; $acc <span class='s-gray'>($src)</span>$bdg <span class='s-gray'>[$cur]</span></div>")
                }
                [void]$sb.AppendLine("<tr$rowBg><td style='font-weight:600'>" + (ConvertTo-SafeHtml $rvName) + "</td><td>" + (ConvertTo-SafeHtml $rvEmail) + "</td><td style='text-align:right;font-weight:600' class='s-red'>$rvCount</td><td>" + $itemsCell.ToString() + "</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></details>')
    }
    if (-not $anyRev) { [void]$sb.AppendLine('<p style="color:#777">No reviewer accountability data available.</p>') }
    [void]$sb.AppendLine('</div>')
}

# ---- C. Approved Items -- First-Approval Timeline (V4f addition) -------------------------
# Answers two leadership questions V4e could not: (1) WHICH currently-approved grants are
# NEWLY approved (first genuine approval happened mid-window rather than carried from the
# window's first instance), and (2) WHEN each approved grant was FIRST genuinely approved.
# Date source: the reviewer's own DecisionDate on the item in the first genuinely-approving
# instance (the honest moment of approval), falling back to that instance's calendar day.
# For a daily series, carried items date to the window's first campaign day (typically the
# 1st of the month); newly approved items date mid-month -- exactly the split requested.
if ($seriesDataList.Count -gt 0) {
    [void]$sb.AppendLine('<div class="section"><h2>C. Approved Items -- First-Approval Timeline</h2>')
    foreach ($sd in $seriesDataList) {
        [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default ''))) + '</div>')

        # SAME Test-V4eItemShown gate as the donut / Section A / JSON (honesty reconciliation).
        $faAll = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
        $faShown = @($faAll | Where-Object { Test-V4eItemShown $_ })

        # Currently-approved grants only (newest instance carries a genuine approval).
        $faApproved = @($faShown | Where-Object {
            [bool](Get-SPObjectProperty -Object $_ -Name 'CurrentIsGenuineApproval' -Default $false)
        })

        # Window start = earliest instance any shown item was seen in; a first approval in a
        # LATER instance means the grant became approved mid-window ("newly approved").
        $faWindowStart = -1
        foreach ($it in $faShown) {
            $fs = [int](Get-SPObjectProperty -Object $it -Name 'FirstSeenOrderIndex' -Default -1)
            if ($fs -ge 0 -and ($faWindowStart -lt 0 -or $fs -lt $faWindowStart)) { $faWindowStart = $fs }
        }

        $faCarried = [System.Collections.Generic.List[object]]::new()
        $faNewly   = [System.Collections.Generic.List[object]]::new()
        foreach ($it in $faApproved) {
            $fga = [int](Get-SPObjectProperty -Object $it -Name 'FirstGenuineApprovalOrderIndex' -Default -1)
            if ($fga -ge 0 -and $faWindowStart -ge 0 -and $fga -gt $faWindowStart) { $faNewly.Add($it) } else { $faCarried.Add($it) }
        }

        [void]$sb.AppendLine("<p style='font-size:12px;color:#555'>Currently approved (genuine, deduplicated by grant): <b>$($faApproved.Count)</b> &mdash; " +
            "approved since the window start: <b>$($faCarried.Count)</b> &middot; <span style='color:#0a7d2c;font-weight:700'>newly approved mid-window: $($faNewly.Count)</span></p>")

        # Newly-approved detail first (the actionable list), then the carried list collapsed.
        foreach ($bucket in @(
            @{ Label = "Newly approved mid-window ($($faNewly.Count))";      Items = $faNewly;   Open = ' open' },
            @{ Label = "Approved since window start ($($faCarried.Count))";  Items = $faCarried; Open = '' }
        )) {
            [void]$sb.AppendLine("<details$($bucket.Open)><summary>$(ConvertTo-SafeHtml $bucket.Label)</summary>")
            if (@($bucket.Items).Count -eq 0) {
                [void]$sb.AppendLine('<p style="color:#777;font-size:12px">None.</p>')
            }
            else {
                [void]$sb.AppendLine('<table class="report"><thead><tr><th>First Approved</th><th>Identity</th><th>Access</th><th>Source</th><th>First-Approval Campaign</th><th>Reviewer</th></tr></thead><tbody>')
                $faSorted = @($bucket.Items | Sort-Object -Property @{ Expression = { [string](Get-SPObjectProperty -Object $_ -Name 'FirstGenuineApprovalDate' -Default '9999-99-99') } }, `
                                                                     @{ Expression = { [string](Get-SPObjectProperty -Object $_ -Name 'IdentityName' -Default '') } })
                foreach ($it in $faSorted) {
                    $fad = [string](Get-SPObjectProperty -Object $it -Name 'FirstGenuineApprovalDate' -Default '')
                    if ([string]::IsNullOrWhiteSpace($fad)) { $fad = '(no date)' }
                    [void]$sb.AppendLine('<tr>' +
                        "<td style='white-space:nowrap'>$(ConvertTo-SafeHtml $fad)</td>" +
                        "<td>$(ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default '')))</td>" +
                        "<td>$(ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default '')))</td>" +
                        "<td>$(ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default '')))</td>" +
                        "<td style='font-size:11px'>$(ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'FirstGenuineApprovalCampaign' -Default '')))</td>" +
                        "<td>$(ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentReviewerName' -Default '')))</td>" +
                        '</tr>')
                }
                [void]$sb.AppendLine('</tbody></table>')
            }
            [void]$sb.AppendLine('</details>')
        }
    }
    [void]$sb.AppendLine('</div>')
}

# ---- Decision Summary (V4b Decision-Summary chrome, rebound to series classifications) ----
# TWO V4b-style <details> collapsibles per series: Decision Changes (genuine decision flipped)
# and Newly In Scope (absent from all priors, present in the newest). Both are FILTERED by
# Classification (NOT the IsDecisionChanged/IsNewlyInScope precedence flags) so the row counts
# reconcile with Section A's cDC/cNS, the donut, and JSON Counts.DecisionChanged/NewlyInScope
# (the engine's precedence ladder can set IsDecisionChanged=true on a NewlyInScope-classified
# item). Both <details> render for EVERY series (even when empty, with a None. row) so the chrome
# is deterministic -- mirrors V4b, which always renders its Decision-Summary details.
if ($seriesDataList.Count -gt 0) {
    [void]$sb.AppendLine('<div class="section"><h2>Decision Summary</h2>')
    foreach ($sd in $seriesDataList) {
        [void]$sb.AppendLine('<div class="subhead">' + (ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default ''))) + '</div>')

        # SAME Test-V4eItemShown gate the donut / Section A / JSON use (honesty reconciliation).
        $allItems = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
        $shownItems = @($allItems | Where-Object { Test-V4eItemShown $_ })

        # Unverified-provenance note where this series has excluded Unverified instances (inline
        # amber style; V4e CSS has no .note class, mirror V4b's inline Decision-Summary notes).
        $excluded = $allItems.Count - $shownItems.Count
        if ((-not $IncludeUnverified) -and $excluded -gt 0) {
            [void]$sb.AppendLine('<p style="color:#9a6700;font-size:11px;margin:2px 0 6px"><strong>Note:</strong> ' + $excluded + ' item(s) from Unverified-provenance instance(s) were EXCLUDED from this series'' headline. Re-run with -IncludeUnverified to include them (badged).</p>')
        }

        # Decision Changes -- filter by Classification so the row count reconciles with Section A's
        # cDC / the donut / JSON Counts.DecisionChanged (NOT the IsDecisionChanged precedence flag).
        $dcItems = @($shownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'DecisionChanged' })
        [void]$sb.AppendLine("<details><summary class='s-amber' style='font-size:13px;margin:12px 0 6px'>Decision Changes (" + $dcItems.Count + " items)</summary>")
        [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:2px 0 6px">Items whose genuine decision flipped (Approved and Revoked both present) across the window.</p>')
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th><th>Reviewer</th></tr></thead><tbody>')
        if ($dcItems.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="5" style="color:#777;font-style:italic">None.</td></tr>') }
        else {
            foreach ($it in $dcItems) {
                $idn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
                $acc = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
                $src = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
                $cur = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default ''))
                $rvn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentReviewerName' -Default ''))
                $bdg = Get-V4eUnverifiedBadge $it
                [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td>$cur</td><td>$rvn</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></details>')

        # Newly In Scope -- filter by Classification (reconciles with Section A's cNS / donut / JSON).
        $nisItems = @($shownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'NewlyInScope' })
        [void]$sb.AppendLine("<details><summary class='s-gray' style='font-size:13px;margin:12px 0 6px'>Newly In Scope (" + $nisItems.Count + " items)</summary>")
        [void]$sb.AppendLine('<p style="color:#777;font-size:11px;margin:2px 0 6px">Items absent from all prior instances and present in the newest -- newly subject to certification.</p>')
        [void]$sb.AppendLine('<table class="report"><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th><th>Reviewer</th></tr></thead><tbody>')
        if ($nisItems.Count -eq 0) { [void]$sb.AppendLine('<tr><td colspan="5" style="color:#777;font-style:italic">None.</td></tr>') }
        else {
            foreach ($it in $nisItems) {
                $idn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
                $acc = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
                $src = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
                $cur = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default ''))
                $rvn = ConvertTo-SafeHtml ([string](Get-SPObjectProperty -Object $it -Name 'CurrentReviewerName' -Default ''))
                $bdg = Get-V4eUnverifiedBadge $it
                [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td>$cur</td><td>$rvn</td></tr>")
            }
        }
        [void]$sb.AppendLine('</tbody></table></details>')
    }
    [void]$sb.AppendLine('</div>')
}

# ---- Footer (V4b-EXACT chrome, rebranded v4e; unit swapped campaign(s) -> series) ----
[void]$sb.AppendLine('<div class="footer">SailPoint ISC Governance Toolkit &middot; Daily Evidence Report v4e &middot; Generated: ' + (ConvertTo-SafeHtml $genDate) + ' &middot; CorrelationID: ' + (ConvertTo-SafeHtml $correlationID) + ' &middot; ' + $seriesDataList.Count + ' series</div>')
[void]$sb.AppendLine("</div></body></html>")

if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    Write-SPHtmlFile -Path $htmlFile -Content $sb.ToString()
    Write-Host "    HTML: $htmlFile" -ForegroundColor Green
}

#endregion

#region Step 5: Console summary

if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host ''
    Write-Host '  Series summary:' -ForegroundColor Cyan
    if ($seriesDataList.Count -eq 0) {
        Write-Host '    (no recurring series found)' -ForegroundColor DarkGray
    }
    foreach ($sd in $seriesDataList) {
        # Reconcile with the HTML: count from the SAME Test-V4eItemShown-filtered set the KPI band
        # uses, not the engine's RAW Counts. Otherwise, when a series has Unverified instances and
        # -IncludeUnverified is OFF (default), the console would include items the HTML excludes and
        # the two surfaces would report different newly-attested totals for the same run.
        $sdItems = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
        $shownItems = @($sdItems | Where-Object { Test-V4eItemShown $_ })
        $na = @($shownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'NewlyAttested' }).Count
        $pu = @($shownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'PersistentlyUndecided' }).Count
        $stem = [string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default '')
        Write-Host "    - $stem : newly-attested=$na  persistently-undecided=$pu" -ForegroundColor DarkGray
    }
    Write-Host ''
}

#endregion

#region Step 6: JSON output

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    # Reconcile the JSON headline with the rendered HTML/console: project each series through the
    # -IncludeUnverified gate (Get-V4eJsonSeriesProjection) so the machine surface reports the SAME
    # honest Counts + reviewer rollups + Items the human surfaces show. When -IncludeUnverified is
    # OFF (default) Unverified items are excluded from the JSON headline exactly as they are from
    # the HTML KPI band and console summary; the raw pre-gate engine Counts stay under EngineCounts
    # for audit. Without this the JSON headline could over-state newly-attested vs the report it
    # summarizes when a series carries Unverified instances.
    $jsonSeries = @($seriesDataList | ForEach-Object { Get-V4eJsonSeriesProjection -Series $_ })
    $jsonResult = [ordered]@{
        Version           = 'V4e'
        SeriesCount       = $seriesDataList.Count
        IncludeUnverified = [bool]$IncludeUnverified
        Series            = @($jsonSeries)
        CorrelationID     = $correlationID
        GeneratedAt       = $genDate
        # Only advertise the HTML artifact when it was actually written to disk (HTML/Both);
        # a JSON-only run writes no HTML file, so reporting a path would be a false reference.
        HtmlReport        = if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') { $htmlFile } else { $null }
    }

    if ($OutputMode -eq 'JSON') {
        $jsonResult | ConvertTo-Json -Depth 8
    }
    else {
        $jsonFile = Join-Path $effectiveOutputPath "daily-evidence-v4f-$timestamp.json"
        $jsonResult | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-Host "    JSON: $jsonFile" -ForegroundColor Green
    }
}

#endregion

#region Audit Trail

$totalDuration = (Get-Date) - $startTime
$durationStr = "$([math]::Round($totalDuration.TotalSeconds, 1))s"
Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV4e completed: Duration=$durationStr Series=$($seriesDataList.Count)" `
        -Severity INFO -Component 'DailyEvidenceV4f' -Action 'Complete' -CorrelationID $correlationID
} catch { }

#endregion

#region Exit Code

# 0: Normal (report rendered, including the valid zero-series case).
exit 0

#endregion
