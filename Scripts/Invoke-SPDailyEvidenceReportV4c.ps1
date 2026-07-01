#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the V4c series attestation delta report -- a series-aware, honest
    "newly attested" decision-transition report over the rich audit cache
    (output: daily-evidence-v4c-*.html).
.DESCRIPTION
    V4c is a READ-ONLY report. It reads ONLY the rich audit cache
    (items-<id>.jsonl + items-<id>.meta.json + roster-<id>.json) -- it never
    calls the ISC API, never starts the live mock, never opens a GUI.

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

    This is ADDITIVE: it does NOT replace or modify V3/V4/V4b/V5/V6/V7. The
    cross-campaign snapshot scope-diff stays intact for genuinely-different
    campaigns; V4c is the recurring-series analysis alongside it.

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
    .\Invoke-SPDailyEvidenceReportV4c.ps1
    # Auto-derive every recurring series from the cache and render the delta.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4c.ps1 -SeriesName 'Access Review' -OutputMode HTML
    # Force a single series stem and write only the HTML report.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV4c.ps1 -SimilarityThreshold 0.15 -IncludeUnverified
    # Opt-in fuzzy stem merge; include Unverified items with a badge.
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV4c.ps1
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

# V4c needs SP.Audit (the series reader + pure delta engine live there). SP.Audit
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
Write-Host '  Daily Evidence Report (v4c) -- Series Attestation Delta' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

try {
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV4c started: CorrelationID=$correlationID MinInstances=$MinInstances SimilarityThreshold=$SimilarityThreshold" `
        -Severity INFO -Component 'DailyEvidenceV4c' -Action 'Start' -CorrelationID $correlationID
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
        Write-SPLog -Message "V4c reader threw: $($_.Exception.Message)" -Severity ERROR -Component 'DailyEvidenceV4c' -Action 'Read' -CorrelationID $correlationID
    } catch { }
    exit 4
}

if ($null -eq $seriesRes -or -not $seriesRes.Success) {
    $errMsg = if ($null -ne $seriesRes) { [string]$seriesRes.Error } else { 'null result' }
    Write-Host "  ERROR: Series reader failed: $errMsg" -ForegroundColor Red
    try {
        Write-SPLog -Message "V4c reader failed: $errMsg" -Severity WARN -Component 'DailyEvidenceV4c' -Action 'Read' -CorrelationID $correlationID
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
                Write-SPLog -Message "V4c fuzzy merge -> '$($firstCs.NormalizedStem)' from: $mergedStems" `
                    -Severity INFO -Component 'DailyEvidenceV4c' -Action 'FuzzyMerge' -CorrelationID $correlationID
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

    $seriesResults.Add($dr.Data)
    $na = [int]$dr.Data.Counts['NewlyAttested']
    $pu = [int]$dr.Data.Counts['PersistentlyUndecided']
    Write-Host "    [$($series.NormalizedStem)] instances=$($dr.Data.InstanceCount) newlyAttested=$na persistentlyUndecided=$pu" -ForegroundColor DarkGray
}

$seriesDataList = @($seriesResults.ToArray())

#endregion

#region Step 4: Build HTML report

$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$htmlFile = Join-Path $effectiveOutputPath "daily-evidence-v4c-$timestamp.html"

# Helper: should this item be shown in the headline given the -IncludeUnverified gate?
function Test-V4cItemShown {
    param([object]$Item)
    if ($IncludeUnverified) { return $true }
    $uv = [bool](Get-SPObjectProperty -Object $Item -Name 'Unverified' -Default $false)
    $cuv = [bool](Get-SPObjectProperty -Object $Item -Name 'CurrentUnverified' -Default $false)
    return (-not ($uv -or $cuv))
}

function Get-V4cUnverifiedBadge {
    param([object]$Item)
    $uv = [bool](Get-SPObjectProperty -Object $Item -Name 'Unverified' -Default $false)
    $cuv = [bool](Get-SPObjectProperty -Object $Item -Name 'CurrentUnverified' -Default $false)
    if ($uv -or $cuv) { return " <span class='badge badge-amber'>Unverified</span>" }
    return ''
}

# Helper: reconcile a per-reviewer rollup against the -IncludeUnverified gate. Drops items the
# gate hides (exactly as the HTML tables do via Test-V4cItemShown), recomputes the cluster Count,
# and omits clusters that become empty -- so the JSON rollup mirrors the rendered tables.
function Get-V4cReconcileRollup {
    param([object[]]$Rollup)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rv in @($Rollup)) {
        if ($null -eq $rv) { continue }
        $rvItems = @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())
        $rvShown = @($rvItems | Where-Object { Test-V4cItemShown $_ })
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
function Get-V4cJsonSeriesProjection {
    param([object]$Series)

    $allItems = @(Get-SPObjectProperty -Object $Series -Name 'Items' -Default @())
    $shownItems = @($allItems | Where-Object { Test-V4cItemShown $_ })

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
        NewlyAttestedByReviewer         = (Get-V4cReconcileRollup (Get-SPObjectProperty -Object $Series -Name 'NewlyAttestedByReviewer' -Default @()))
        PersistentlyUndecidedByReviewer = (Get-V4cReconcileRollup (Get-SPObjectProperty -Object $Series -Name 'PersistentlyUndecidedByReviewer' -Default @()))
        Items                   = @($shownItems)
    }
}

$css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#fff;max-width:1200px;}
h1{font-size:22px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:17px;color:#1f3a5f;margin-top:30px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
h3{font-size:14px;color:#336699;margin-top:18px;}
.meta{color:#566;font-size:12px;margin-bottom:16px;line-height:1.6;}
table{border-collapse:collapse;width:100%;margin:8px 0 16px 0;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:120px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;text-align:center;}
.kpi .n{font-size:22px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.note{font-size:11px;color:#777;margin-top:4px;}
.section{margin:18px 0;padding:14px 18px;border:1px solid #d4dce6;border-radius:8px;background:#fafbfd;}
.section-title{font-size:15px;color:#1f3a5f;font-weight:700;margin:0 0 10px 0;padding-bottom:6px;border-bottom:1px solid #d4dce6;}
.series-card{margin:22px 0;padding:18px 20px;border:2px solid #1f3a5f;border-radius:10px;background:#fff;}
.series-head{font-size:16px;color:#1f3a5f;font-weight:700;margin:0 0 4px 0;}
.empty{font-size:12px;color:#888;font-style:italic;margin:4px 0;}
.footer{margin-top:24px;padding-top:8px;border-top:1px solid #d4dce6;font-size:11px;color:#777;}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:9px;font-weight:700;color:#fff;margin-left:6px;vertical-align:middle;}
.badge-red{background:#b00020;}
.badge-amber{background:#9a6700;}
.badge-green{background:#0a7d2c;}
.badge-blue{background:#336699;}
.reviewer-row{font-weight:600;background:#eef3f8;}
'@

$sb = New-Object System.Text.StringBuilder 32768
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence Report v4c -- Series Attestation Delta</title><style>$css</style></head><body>")

# Header banner
[void]$sb.AppendLine("<h1>Daily Evidence Report v4c -- Series Attestation Delta</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Series-aware, honest <strong>newly-attested</strong> decision-transition report over the rich audit cache.<br>")
[void]$sb.AppendLine("Series analyzed: <strong>$($seriesDataList.Count)</strong> &nbsp;|&nbsp; Cache: $(ConvertTo-SPHtmlSafe $cacheDir)<br>")
$unvMode = if ($IncludeUnverified) { 'INCLUDED (badged)' } else { 'EXCLUDED from headline' }
[void]$sb.AppendLine("Unverified provenance: <strong>$unvMode</strong> &nbsp;|&nbsp; Min instances: $MinInstances &nbsp;|&nbsp; Fuzzy threshold: $SimilarityThreshold<br>")
[void]$sb.AppendLine("Generated: $genDate</p>")

if ($seriesDataList.Count -eq 0) {
    [void]$sb.AppendLine("<div class='section'><div class='section-title'>No recurring series found</div>")
    [void]$sb.AppendLine("<p class='empty'>The cache contains no campaign family with at least $MinInstances instance(s) sharing a normalized series stem. Nothing to attest across a window. Run the daily orchestrator across multiple instances of a recurring campaign to populate the series.</p></div>")
}

foreach ($sd in $seriesDataList) {
    $stem = [string](Get-SPObjectProperty -Object $sd -Name 'SeriesStem' -Default '')
    $periodType = [string](Get-SPObjectProperty -Object $sd -Name 'PeriodType' -Default '')
    $instCount = [int](Get-SPObjectProperty -Object $sd -Name 'InstanceCount' -Default 0)
    $newestName = [string](Get-SPObjectProperty -Object $sd -Name 'NewestCampaignName' -Default '')
    $counts = Get-SPObjectProperty -Object $sd -Name 'Counts' -Default @{}
    $items = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
    $unvInstCount = [int](Get-SPObjectProperty -Object $sd -Name 'UnverifiedInstanceCount' -Default 0)

    [void]$sb.AppendLine("<div class='series-card'>")
    $seriesBadge = if ([bool](Get-SPObjectProperty -Object $sd -Name 'Unverified' -Default $false)) { " <span class='badge badge-amber'>Unverified provenance</span>" } else { '' }
    [void]$sb.AppendLine("<div class='series-head'>$(ConvertTo-SPHtmlSafe $stem)$seriesBadge</div>")
    [void]$sb.AppendLine("<p class='meta'>Period type: <strong>$(ConvertTo-SPHtmlSafe $periodType)</strong> &nbsp;|&nbsp; Instances in window: <strong>$instCount</strong> &nbsp;|&nbsp; Newest: $(ConvertTo-SPHtmlSafe $newestName)</p>")

    # KPI band from honest counts. Render from the SAME filtered set the detail tables
    # use (Test-V4cItemShown), so the headline reconciles with the evidence rows below:
    # when -IncludeUnverified is OFF (default) Unverified items are excluded from BOTH the
    # KPI and the rows; when ON, every item is shown in both. (Honesty doctrine: the number
    # a reader sees must reconcile against the rows it summarizes.)
    $kpiShownItems = @($items | Where-Object { Test-V4cItemShown $_ })
    $kpiNewlyAttested = @($kpiShownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'NewlyAttested' }).Count
    $kpiPersistentlyUndecided = @($kpiShownItems | Where-Object { [string](Get-SPObjectProperty -Object $_ -Name 'Classification' -Default '') -eq 'PersistentlyUndecided' }).Count
    $kpiDecisionChanged = @($kpiShownItems | Where-Object { [bool](Get-SPObjectProperty -Object $_ -Name 'IsDecisionChanged' -Default $false) }).Count
    $kpiNewlyInScope = @($kpiShownItems | Where-Object { [bool](Get-SPObjectProperty -Object $_ -Name 'IsNewlyInScope' -Default $false) }).Count
    [void]$sb.AppendLine("<div>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:#0a7d2c;'>$kpiNewlyAttested</span><span class='l'>Newly Attested</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:#b00020;'>$kpiPersistentlyUndecided</span><span class='l'>Persistently Undecided</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>$kpiDecisionChanged</span><span class='l'>Decision Changes</span></span>")
    [void]$sb.AppendLine("<span class='kpi'><span class='n'>$kpiNewlyInScope</span><span class='l'>Newly In Scope</span></span>")
    [void]$sb.AppendLine("</div>")

    if ((-not $IncludeUnverified) -and $unvInstCount -gt 0) {
        [void]$sb.AppendLine("<p class='note'>Note: $unvInstCount instance(s) carry Unverified provenance; their items are EXCLUDED from the headline below. Re-run with -IncludeUnverified to surface them with a badge.</p>")
    }

    # (A) Newly Attested This Period -- per reviewer then per item.
    [void]$sb.AppendLine("<div class='section'><div class='section-title'>Newly Attested This Period</div>")
    [void]$sb.AppendLine("<p class='note'>First GENUINE (honest) reviewer approval of each identity+entitlement in the window. Auto-approved-at-close and pending are NOT counted.</p>")
    $naRollup = @(Get-SPObjectProperty -Object $sd -Name 'NewlyAttestedByReviewer' -Default @())
    $naShown = 0
    foreach ($rv in $naRollup) {
        $rvItems = @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())
        $rvShownItems = @($rvItems | Where-Object { Test-V4cItemShown $_ })
        if ($rvShownItems.Count -eq 0) { continue }
        $rvName = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerName' -Default '(Unassigned)')
        $rvEmail = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerEmail' -Default '')
        [void]$sb.AppendLine("<h3>$(ConvertTo-SPHtmlSafe $rvName) <span class='badge badge-green'>$($rvShownItems.Count)</span> <span style='font-weight:400;color:#888;font-size:11px;'>$(ConvertTo-SPHtmlSafe $rvEmail)</span></h3>")
        [void]$sb.AppendLine("<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th style='text-align:right;'>First Genuine Approval (order)</th></tr></thead><tbody>")
        foreach ($it in $rvShownItems) {
            $idn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
            $acc = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
            $src = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
            $foi = [int](Get-SPObjectProperty -Object $it -Name 'FirstGenuineApprovalOrderIndex' -Default -1)
            $bdg = Get-V4cUnverifiedBadge $it
            [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td style='text-align:right;'>$foi</td></tr>")
            $naShown++
        }
        [void]$sb.AppendLine("</tbody></table>")
    }
    if ($naShown -eq 0) { [void]$sb.AppendLine("<p class='empty'>No genuine first-time approvals in this window.</p>") }
    [void]$sb.AppendLine("</div>")

    # (B) Persistently Undecided / Never Attested.
    [void]$sb.AppendLine("<div class='section'><div class='section-title'>Persistently Undecided / Never Attested</div>")
    [void]$sb.AppendLine("<p class='note'>Items never genuinely decided in ANY instance across the window, grouped by the cert-assigned reviewer.</p>")
    $puRollup = @(Get-SPObjectProperty -Object $sd -Name 'PersistentlyUndecidedByReviewer' -Default @())
    $puShown = 0
    foreach ($rv in $puRollup) {
        $rvItems = @(Get-SPObjectProperty -Object $rv -Name 'Items' -Default @())
        $rvShownItems = @($rvItems | Where-Object { Test-V4cItemShown $_ })
        if ($rvShownItems.Count -eq 0) { continue }
        $rvName = [string](Get-SPObjectProperty -Object $rv -Name 'ReviewerName' -Default '(Unassigned)')
        [void]$sb.AppendLine("<h3>$(ConvertTo-SPHtmlSafe $rvName) <span class='badge badge-red'>$($rvShownItems.Count)</span></h3>")
        [void]$sb.AppendLine("<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th></tr></thead><tbody>")
        foreach ($it in $rvShownItems) {
            $idn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
            $acc = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
            $src = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
            $cur = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default 'Undecided'))
            $bdg = Get-V4cUnverifiedBadge $it
            [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td>$cur</td></tr>")
            $puShown++
        }
        [void]$sb.AppendLine("</tbody></table>")
    }
    if ($puShown -eq 0) { [void]$sb.AppendLine("<p class='empty'>No persistently-undecided items in this window.</p>") }
    [void]$sb.AppendLine("</div>")

    # (C) Decision Changes.
    [void]$sb.AppendLine("<div class='section'><div class='section-title'>Decision Changes</div>")
    [void]$sb.AppendLine("<p class='note'>Items whose genuine decision flipped (Approved and Revoked both present) across the window.</p>")
    $dcItems = @($items | Where-Object { [bool](Get-SPObjectProperty -Object $_ -Name 'IsDecisionChanged' -Default $false) -and (Test-V4cItemShown $_) })
    if ($dcItems.Count -gt 0) {
        [void]$sb.AppendLine("<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th><th>Reviewer</th></tr></thead><tbody>")
        foreach ($it in $dcItems) {
            $idn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
            $acc = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
            $src = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
            $cur = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default ''))
            $rvn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'CurrentReviewerName' -Default ''))
            $bdg = Get-V4cUnverifiedBadge $it
            [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td>$cur</td><td>$rvn</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table>")
    }
    else { [void]$sb.AppendLine("<p class='empty'>No decision changes in this window.</p>") }
    [void]$sb.AppendLine("</div>")

    # (D) Newly In Scope.
    [void]$sb.AppendLine("<div class='section'><div class='section-title'>Newly In Scope</div>")
    [void]$sb.AppendLine("<p class='note'>Items absent from all prior instances and present in the newest -- newly subject to certification.</p>")
    $nisItems = @($items | Where-Object { [bool](Get-SPObjectProperty -Object $_ -Name 'IsNewlyInScope' -Default $false) -and (Test-V4cItemShown $_) })
    if ($nisItems.Count -gt 0) {
        [void]$sb.AppendLine("<table><thead><tr><th>Identity</th><th>Access</th><th>Source</th><th>Current State</th><th>Reviewer</th></tr></thead><tbody>")
        foreach ($it in $nisItems) {
            $idn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'IdentityName' -Default ''))
            $acc = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'AccessName' -Default ''))
            $src = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'SourceName' -Default ''))
            $cur = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'CurrentHonestDecision' -Default ''))
            $rvn = ConvertTo-SPHtmlSafe ([string](Get-SPObjectProperty -Object $it -Name 'CurrentReviewerName' -Default ''))
            $bdg = Get-V4cUnverifiedBadge $it
            [void]$sb.AppendLine("<tr><td>$idn$bdg</td><td>$acc</td><td>$src</td><td>$cur</td><td>$rvn</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table>")
    }
    else { [void]$sb.AppendLine("<p class='empty'>No newly-in-scope items in this window.</p>") }
    [void]$sb.AppendLine("</div>")

    [void]$sb.AppendLine("</div>")  # series-card
}

[void]$sb.AppendLine("<p class='footer'>Daily Evidence Report v4c (Series Attestation Delta) | Series: $($seriesDataList.Count) | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
[void]$sb.AppendLine("</body></html>")

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
        # Reconcile with the HTML: count from the SAME Test-V4cItemShown-filtered set the KPI band
        # uses, not the engine's RAW Counts. Otherwise, when a series has Unverified instances and
        # -IncludeUnverified is OFF (default), the console would include items the HTML excludes and
        # the two surfaces would report different newly-attested totals for the same run.
        $sdItems = @(Get-SPObjectProperty -Object $sd -Name 'Items' -Default @())
        $shownItems = @($sdItems | Where-Object { Test-V4cItemShown $_ })
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
    # -IncludeUnverified gate (Get-V4cJsonSeriesProjection) so the machine surface reports the SAME
    # honest Counts + reviewer rollups + Items the human surfaces show. When -IncludeUnverified is
    # OFF (default) Unverified items are excluded from the JSON headline exactly as they are from
    # the HTML KPI band and console summary; the raw pre-gate engine Counts stay under EngineCounts
    # for audit. Without this the JSON headline could over-state newly-attested vs the report it
    # summarizes when a series carries Unverified instances.
    $jsonSeries = @($seriesDataList | ForEach-Object { Get-V4cJsonSeriesProjection -Series $_ })
    $jsonResult = [ordered]@{
        Version           = 'V4c'
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
        $jsonFile = Join-Path $effectiveOutputPath "daily-evidence-v4c-$timestamp.json"
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
    Write-SPLog -Message "Invoke-SPDailyEvidenceReportV4c completed: Duration=$durationStr Series=$($seriesDataList.Count)" `
        -Severity INFO -Component 'DailyEvidenceV4c' -Action 'Complete' -CorrelationID $correlationID
} catch { }

#endregion

#region Exit Code

# 0: Normal (report rendered, including the valid zero-series case).
exit 0

#endregion
