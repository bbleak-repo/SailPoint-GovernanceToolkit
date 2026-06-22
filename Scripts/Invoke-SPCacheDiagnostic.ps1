#Requires -Version 5.1
<#
.SYNOPSIS
    Comprehensive cache diagnostic and integrity checker for the SailPoint ISC Governance Toolkit.
.DESCRIPTION
    Scans all cache directories and validates every cache file type:
    - Campaign item caches (items-*.jsonl + .meta.json sidecars)
    - Identity cache (identities.jsonl)
    - Account cache (accounts.jsonl)
    - Campaign snapshots ({campaignId}/{timestamp}.json)
    - Campaign trend files ({campaignId}.jsonl)
    - Governance metrics (governance-metrics.jsonl)

    Detects issues including:
    - Partial/interrupted item caches (missing meta sidecar)
    - Stale caches past TTL
    - Corrupt or unparseable JSON/JSONL lines
    - Duplicate keys within a file
    - PS 5.1 datetime auto-conversion artifacts
    - AccessId instability (ISC reassignment churn)
    - Baseline captures masquerading as scope additions
    - Orphaned files and directory structure anomalies
    - Cross-snapshot key drift (items appearing/disappearing between captures)
    - Trend JSONL gaps and anomalies

    Generates a timestamped log file with findings categorized as ERROR, WARN, or INFO.
.PARAMETER OutputPath
    Directory for the diagnostic log file. Default: .\Reports\diagnostics
.PARAMETER Verbose
    Show all findings in console (not just errors/warnings).
.PARAMETER Help
    Display help.
.EXAMPLE
    .\Scripts\Invoke-SPCacheDiagnostic.ps1
    # Full diagnostic scan with log file.
.EXAMPLE
    .\Scripts\Invoke-SPCacheDiagnostic.ps1 -Verbose
    # Full scan with all findings shown in console.
#>
[CmdletBinding()]
param(
    [Parameter()] [string]$OutputPath,
    [Parameter()] [Alias('?')] [switch]$Help
)

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; return }

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

# Load modules
$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true }
)
foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) { Import-Module $mod.Path -Force -ErrorAction Stop -DisableNameChecking }
    elseif ($mod.Required) { Write-Host "ERROR: Module '$($mod.Name)' not found." -ForegroundColor Red; exit 4 }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $toolkitRoot 'Reports\diagnostics' }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $OutputPath "cache-diagnostic-${timestamp}.log"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logSb = New-Object System.Text.StringBuilder 16384
$findings = [System.Collections.Generic.List[object]]::new()
$now = Get-Date

function Add-Finding {
    param([string]$Severity, [string]$Category, [string]$File, [string]$Message, [string]$Detail = '')
    $f = @{ Severity = $Severity; Category = $Category; File = $File; Message = $Message; Detail = $Detail; Timestamp = $now.ToString('HH:mm:ss') }
    $findings.Add($f)
    $color = switch ($Severity) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
    if ($Severity -ne 'INFO' -or $VerbosePreference -eq 'Continue') {
        Write-Host "  [$Severity] $Category`: $Message" -ForegroundColor $color
    }
    [void]$logSb.AppendLine("[$($f.Timestamp)] [$Severity] [$Category] $Message$(if($Detail){" -- $Detail"})")
}

Write-Host ''
Write-Host '  SailPoint Governance Toolkit -- Cache Diagnostic' -ForegroundColor Cyan
Write-Host '  =================================================' -ForegroundColor Cyan
Write-Host "  Toolkit root: $toolkitRoot" -ForegroundColor DarkGray
Write-Host "  Log file:     $logFile" -ForegroundColor DarkGray
Write-Host ''

[void]$logSb.AppendLine("Cache Diagnostic Report -- $($now.ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$logSb.AppendLine("Toolkit root: $toolkitRoot")
[void]$logSb.AppendLine("================================================")
[void]$logSb.AppendLine('')

#region Resolve Cache Paths
$cacheDir = $null; $snapshotDir = $null; $trendDir = $null; $metricsDir = $null
try {
    $cfg = Get-SPConfig
    if ($null -ne $cfg.PSObject.Properties['Audit']) {
        if ($null -ne $cfg.Audit.PSObject.Properties['CachePath'] -and -not [string]::IsNullOrWhiteSpace($cfg.Audit.CachePath)) {
            $cacheDir = [string]$cfg.Audit.CachePath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
            $cacheDir = Join-Path ([string]$cfg.Audit.OutputPath) '.cache'
        }
        if ($null -ne $cfg.Audit.PSObject.Properties['SnapshotPath'] -and -not [string]::IsNullOrWhiteSpace($cfg.Audit.SnapshotPath)) {
            $snapshotDir = [string]$cfg.Audit.SnapshotPath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($cfg.Audit.OutputPath)) {
            $snapshotDir = Join-Path ([string]$cfg.Audit.OutputPath) 'Snapshots'
        }
    }
    if ($null -ne $cfg.PSObject.Properties['Metrics']) {
        if ($null -ne $cfg.Metrics.PSObject.Properties['CampaignTrendPath'] -and -not [string]::IsNullOrWhiteSpace($cfg.Metrics.CampaignTrendPath)) {
            $trendDir = [string]$cfg.Metrics.CampaignTrendPath
        }
        elseif ($null -ne $cfg.Metrics.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace($cfg.Metrics.Path)) {
            $trendDir = Join-Path ([string]$cfg.Metrics.Path) 'campaign-trend'
            $metricsDir = [string]$cfg.Metrics.Path
        }
    }
} catch {
    Add-Finding 'WARN' 'Config' '' "Could not load config: $($_.Exception.Message)"
}

# Resolve relative paths to toolkit root
foreach ($varName in @('cacheDir', 'snapshotDir', 'trendDir', 'metricsDir')) {
    $val = Get-Variable $varName -ValueOnly
    if (-not [string]::IsNullOrWhiteSpace($val) -and -not [System.IO.Path]::IsPathRooted($val)) {
        Set-Variable $varName ([System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $val)))
    }
}

# Defaults
if ([string]::IsNullOrWhiteSpace($cacheDir))    { $cacheDir    = Join-Path $toolkitRoot 'Audit\.cache' }
if ([string]::IsNullOrWhiteSpace($snapshotDir)) { $snapshotDir = Join-Path $toolkitRoot 'Audit\Snapshots' }
if ([string]::IsNullOrWhiteSpace($trendDir))    { $trendDir    = Join-Path $toolkitRoot 'Audit\metrics\campaign-trend' }
if ([string]::IsNullOrWhiteSpace($metricsDir))  { $metricsDir  = Join-Path $toolkitRoot 'Audit\metrics' }

[void]$logSb.AppendLine("Cache directory:    $cacheDir")
[void]$logSb.AppendLine("Snapshot directory: $snapshotDir")
[void]$logSb.AppendLine("Trend directory:    $trendDir")
[void]$logSb.AppendLine("Metrics directory:  $metricsDir")
[void]$logSb.AppendLine('')
#endregion

#region 1. Campaign Item Cache
Write-Host '  [1/6] Campaign Item Cache' -ForegroundColor White
[void]$logSb.AppendLine('=== 1. CAMPAIGN ITEM CACHE ===')

if (Test-Path $cacheDir) {
    $itemFiles = @(Get-ChildItem -Path $cacheDir -Filter 'items-*.jsonl' -File -ErrorAction SilentlyContinue)
    $metaFiles = @(Get-ChildItem -Path $cacheDir -Filter 'items-*.meta.json' -File -ErrorAction SilentlyContinue)
    Add-Finding 'INFO' 'ItemCache' $cacheDir "$($itemFiles.Count) item file(s), $($metaFiles.Count) meta file(s)"

    foreach ($f in $itemFiles) {
        $baseName = $f.BaseName  # items-{campaignId}
        $metaFile = Join-Path $cacheDir "$baseName.meta.json"
        $hasMeta = Test-Path $metaFile

        # Check for partial cache (no meta sidecar)
        if (-not $hasMeta) {
            Add-Finding 'WARN' 'ItemCache' $f.Name 'Items file exists without meta.json sidecar -- PARTIAL/INTERRUPTED fetch' "File size: $([math]::Round($f.Length/1024,1)) KB"
        }

        # Validate JSONL content
        $lineCount = 0; $parseErrors = 0; $blankLines = 0; $certIds = @{}; $keys = @{}; $dupKeys = 0
        try {
            foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, $utf8)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { $blankLines++; continue }
                $lineCount++
                try {
                    $rec = $ln | ConvertFrom-Json
                    # Track certification IDs
                    $cid = if ($null -ne $rec.CertificationId) { [string]$rec.CertificationId } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($cid)) { $certIds[$cid] = $true }
                    # Track item keys for duplicates
                    if ($null -ne $rec.Item) {
                        $k = if ($null -ne $rec.Item.PSObject.Properties['Key']) { [string]$rec.Item.Key } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($k)) {
                            if ($keys.ContainsKey($k)) { $dupKeys++ } else { $keys[$k] = $true }
                        }
                    }
                } catch { $parseErrors++ }
            }
        } catch {
            Add-Finding 'ERROR' 'ItemCache' $f.Name "Cannot read file: $($_.Exception.Message)"
            continue
        }

        Add-Finding 'INFO' 'ItemCache' $f.Name "$lineCount items, $($certIds.Count) certs, $parseErrors parse errors, $dupKeys dup keys"
        if ($parseErrors -gt 0) { Add-Finding 'ERROR' 'ItemCache' $f.Name "$parseErrors line(s) failed JSON parse -- file may be corrupt" }
        if ($dupKeys -gt 0) { Add-Finding 'WARN' 'ItemCache' $f.Name "$dupKeys duplicate item key(s) -- may indicate reassignment churn or resumed fetch overlap" }

        # Validate meta sidecar
        if ($hasMeta) {
            try {
                $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
                $metaItemCount = if ($null -ne $meta.ItemCount) { [int]$meta.ItemCount } else { -1 }
                if ($metaItemCount -ge 0 -and $metaItemCount -ne $lineCount) {
                    Add-Finding 'WARN' 'ItemCache' "$baseName.meta.json" "Meta says $metaItemCount items but JSONL has $lineCount lines" "Delta: $($lineCount - $metaItemCount)"
                }
                # Check staleness
                if ($null -ne $meta.CachedAt) {
                    try {
                        $cachedAt = [datetime]::Parse([string]$meta.CachedAt)
                        $ageHours = [math]::Round(($now - $cachedAt).TotalHours, 1)
                        $isPerm = if ($null -ne $meta.IsPermanent) { [bool]$meta.IsPermanent } else { $false }
                        if (-not $isPerm -and $ageHours -gt 3) {
                            Add-Finding 'WARN' 'ItemCache' "$baseName.meta.json" "Active cache is $ageHours hours old (TTL default: 3h)" "Status: $($meta.Status)"
                        }
                        Add-Finding 'INFO' 'ItemCache' "$baseName.meta.json" "Campaign: $($meta.CampaignName) | Status: $($meta.Status) | Age: ${ageHours}h | Permanent: $isPerm"
                    } catch { Add-Finding 'WARN' 'ItemCache' "$baseName.meta.json" 'CachedAt field is unparseable' }
                }
            } catch { Add-Finding 'ERROR' 'ItemCache' "$baseName.meta.json" "Meta file is corrupt: $($_.Exception.Message)" }
        }
    }

    # Check for orphaned meta files (meta without items)
    foreach ($mf in $metaFiles) {
        $itemsFile = Join-Path $cacheDir "$($mf.BaseName -replace '\.meta$','').jsonl"
        if (-not (Test-Path $itemsFile)) {
            Add-Finding 'WARN' 'ItemCache' $mf.Name 'Orphaned meta file -- items JSONL is missing'
        }
    }
}
else { Add-Finding 'INFO' 'ItemCache' $cacheDir 'Cache directory does not exist (no cache data yet)' }

[void]$logSb.AppendLine('')
#endregion

#region 2. Identity Cache
Write-Host '  [2/6] Identity Cache' -ForegroundColor White
[void]$logSb.AppendLine('=== 2. IDENTITY CACHE ===')

$identityFile = Join-Path $cacheDir 'identities.jsonl'
if (Test-Path $identityFile) {
    $idLineCount = 0; $idParseErrors = 0; $idIds = @{}; $idDuplicates = 0; $idExpired = 0; $idNoFound = 0
    $oldestEntry = $null; $newestEntry = $null
    $ttlMinutes = 1440
    try { $ttlMinutes = [int]$cfg.Audit.IdentityCacheTtlMinutes } catch { }

    try {
        foreach ($ln in [System.IO.File]::ReadAllLines($identityFile, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $idLineCount++
            try {
                $rec = $ln | ConvertFrom-Json
                $rid = [string]$rec.IdentityId
                $cachedAt = [datetime]::Parse([string]$rec.CachedAt)
                if ($null -eq $oldestEntry -or $cachedAt -lt $oldestEntry) { $oldestEntry = $cachedAt }
                if ($null -eq $newestEntry -or $cachedAt -gt $newestEntry) { $newestEntry = $cachedAt }
                if ($idIds.ContainsKey($rid)) { $idDuplicates++ } else { $idIds[$rid] = $true }
                if (($now - $cachedAt).TotalMinutes -gt $ttlMinutes) { $idExpired++ }
                if ($null -ne $rec.Detail -and $rec.Detail.Found -eq $false) { $idNoFound++ }
            } catch { $idParseErrors++ }
        }
    } catch { Add-Finding 'ERROR' 'IdentityCache' 'identities.jsonl' "Cannot read: $($_.Exception.Message)" }

    $fileSize = [math]::Round((Get-Item $identityFile).Length / 1024, 1)
    Add-Finding 'INFO' 'IdentityCache' 'identities.jsonl' "$idLineCount lines, $($idIds.Count) unique, ${fileSize} KB"
    if ($idParseErrors -gt 0) { Add-Finding 'ERROR' 'IdentityCache' 'identities.jsonl' "$idParseErrors lines failed JSON parse" }
    if ($idDuplicates -gt 0) { Add-Finding 'INFO' 'IdentityCache' 'identities.jsonl' "$idDuplicates duplicate entries (will compact on next warm-load)" }
    if ($idExpired -gt 0) { Add-Finding 'INFO' 'IdentityCache' 'identities.jsonl' "$idExpired entries past ${ttlMinutes}-min TTL (will prune on next warm-load)" }
    if ($idNoFound -gt 0) { Add-Finding 'WARN' 'IdentityCache' 'identities.jsonl' "$idNoFound entries with Found=false persisted to disk (should be memory-only)" }
    if ($null -ne $oldestEntry) { Add-Finding 'INFO' 'IdentityCache' 'identities.jsonl' "Oldest: $($oldestEntry.ToString('yyyy-MM-dd HH:mm')) | Newest: $($newestEntry.ToString('yyyy-MM-dd HH:mm'))" }
}
else { Add-Finding 'INFO' 'IdentityCache' 'identities.jsonl' 'File does not exist (no identity data cached yet)' }

[void]$logSb.AppendLine('')
#endregion

#region 3. Account Cache
Write-Host '  [3/6] Account Cache' -ForegroundColor White
[void]$logSb.AppendLine('=== 3. ACCOUNT CACHE ===')

$accountFile = Join-Path $cacheDir 'accounts.jsonl'
if (Test-Path $accountFile) {
    $acctLines = 0; $acctErrors = 0
    try {
        foreach ($ln in [System.IO.File]::ReadAllLines($accountFile, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $acctLines++
            try { $ln | ConvertFrom-Json | Out-Null } catch { $acctErrors++ }
        }
    } catch { Add-Finding 'ERROR' 'AccountCache' 'accounts.jsonl' "Cannot read: $($_.Exception.Message)" }

    $fileSize = [math]::Round((Get-Item $accountFile).Length / 1024, 1)
    Add-Finding 'INFO' 'AccountCache' 'accounts.jsonl' "$acctLines entries, ${fileSize} KB"
    if ($acctErrors -gt 0) { Add-Finding 'ERROR' 'AccountCache' 'accounts.jsonl' "$acctErrors lines failed JSON parse" }
}
else { Add-Finding 'INFO' 'AccountCache' 'accounts.jsonl' 'File does not exist' }

[void]$logSb.AppendLine('')
#endregion

#region 4. Campaign Snapshots
Write-Host '  [4/6] Campaign Snapshots' -ForegroundColor White
[void]$logSb.AppendLine('=== 4. CAMPAIGN SNAPSHOTS ===')

if (Test-Path $snapshotDir) {
    $campDirs = @(Get-ChildItem -Path $snapshotDir -Directory -ErrorAction SilentlyContinue)
    Add-Finding 'INFO' 'Snapshots' $snapshotDir "$($campDirs.Count) campaign folder(s)"

    foreach ($cd in $campDirs) {
        $snapFiles = @(Get-ChildItem -Path $cd.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.sha256$|\.meta\.' })
        if ($snapFiles.Count -eq 0) {
            Add-Finding 'WARN' 'Snapshots' $cd.Name 'Empty campaign folder (no snapshot files)'
            continue
        }

        Add-Finding 'INFO' 'Snapshots' $cd.Name "$($snapFiles.Count) snapshot(s)"

        # Check latest snapshot for key integrity
        $latestSnap = $snapFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        try {
            $snapData = Get-Content $latestSnap.FullName -Raw | ConvertFrom-Json
            $meta = $snapData.Meta
            $items = @($snapData.Items)
            $campName = if ($null -ne $meta) { [string]$meta.CampaignName } else { 'Unknown' }
            $itemCount = $items.Count
            $metaItemCount = if ($null -ne $meta -and $null -ne $meta.ItemCount) { [int]$meta.ItemCount } else { -1 }

            Add-Finding 'INFO' 'Snapshots' "$($cd.Name)/$($latestSnap.Name)" "Campaign: $campName | Items: $itemCount | Status: $($meta.Status)"

            if ($metaItemCount -ge 0 -and $metaItemCount -ne $itemCount) {
                Add-Finding 'ERROR' 'Snapshots' $latestSnap.Name "Meta.ItemCount ($metaItemCount) != actual item count ($itemCount)"
            }

            # Key analysis
            $keyMap = @{}; $blankKeys = 0; $dupSnapKeys = 0
            $accessIds = @{}; $accessIdMissing = 0
            foreach ($it in $items) {
                $k = if ($null -ne $it.PSObject.Properties['Key']) { [string]$it.Key } else { '' }
                if ([string]::IsNullOrWhiteSpace($k)) { $blankKeys++ }
                elseif ($keyMap.ContainsKey($k)) { $dupSnapKeys++ }
                else { $keyMap[$k] = $true }

                $aid = if ($null -ne $it.PSObject.Properties['AccessId']) { [string]$it.AccessId } else { '' }
                if ([string]::IsNullOrWhiteSpace($aid)) { $accessIdMissing++ }
                else { $accessIds[$aid] = $true }
            }

            if ($blankKeys -gt 0) { Add-Finding 'ERROR' 'Snapshots' $latestSnap.Name "$blankKeys items with blank Key (diff engine will skip these)" }
            if ($dupSnapKeys -gt 0) { Add-Finding 'WARN' 'Snapshots' $latestSnap.Name "$dupSnapKeys duplicate keys (last-write-wins in diff map)" }
            if ($accessIdMissing -gt 0) { Add-Finding 'WARN' 'Snapshots' $latestSnap.Name "$accessIdMissing items missing AccessId (key falls back to AccessName, less stable)" }

            # Cross-snapshot key drift (compare latest vs previous)
            if ($snapFiles.Count -ge 2) {
                $prevSnap = $snapFiles | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 -First 1
                try {
                    $prevData = Get-Content $prevSnap.FullName -Raw | ConvertFrom-Json
                    $prevItems = @($prevData.Items)
                    $prevKeys = @{}
                    foreach ($pi in $prevItems) {
                        $pk = if ($null -ne $pi.PSObject.Properties['Key']) { [string]$pi.Key } else { '' }
                        if (-not [string]::IsNullOrWhiteSpace($pk)) { $prevKeys[$pk] = $pi }
                    }

                    $addedKeys = 0; $removedKeys = 0; $accessIdChanged = 0
                    foreach ($k in $keyMap.Keys) {
                        if (-not $prevKeys.ContainsKey($k)) { $addedKeys++ }
                    }
                    foreach ($k in $prevKeys.Keys) {
                        if (-not $keyMap.ContainsKey($k)) { $removedKeys++ }
                    }

                    # Check for AccessId instability (same identity+access name but different AccessId)
                    $curByIdentAccess = @{}
                    foreach ($it in $items) {
                        $iid = if ($null -ne $it.PSObject.Properties['IdentityId']) { [string]$it.IdentityId } else { '' }
                        $aname = if ($null -ne $it.PSObject.Properties['AccessName']) { [string]$it.AccessName } else { '' }
                        $aid = if ($null -ne $it.PSObject.Properties['AccessId']) { [string]$it.AccessId } else { '' }
                        $nameKey = "$iid|$aname"
                        $curByIdentAccess[$nameKey] = $aid
                    }
                    foreach ($pi in $prevItems) {
                        $iid = if ($null -ne $pi.PSObject.Properties['IdentityId']) { [string]$pi.IdentityId } else { '' }
                        $aname = if ($null -ne $pi.PSObject.Properties['AccessName']) { [string]$pi.AccessName } else { '' }
                        $prevAid = if ($null -ne $pi.PSObject.Properties['AccessId']) { [string]$pi.AccessId } else { '' }
                        $nameKey = "$iid|$aname"
                        if ($curByIdentAccess.ContainsKey($nameKey)) {
                            $curAid = $curByIdentAccess[$nameKey]
                            if ($curAid -ne $prevAid -and -not [string]::IsNullOrWhiteSpace($prevAid) -and -not [string]::IsNullOrWhiteSpace($curAid)) {
                                $accessIdChanged++
                            }
                        }
                    }

                    if ($addedKeys -gt 0 -or $removedKeys -gt 0) {
                        $severity = if ($addedKeys -gt ($itemCount * 0.5)) { 'WARN' } else { 'INFO' }
                        Add-Finding $severity 'KeyDrift' $cd.Name "Key drift: +$addedKeys added, -$removedKeys removed between last 2 snapshots"
                        if ($addedKeys -ge $itemCount -and $itemCount -gt 0) {
                            Add-Finding 'WARN' 'KeyDrift' $cd.Name 'ALL items appear as newly added -- likely a baseline capture (no valid prior) or full reassignment'
                        }
                    }
                    if ($accessIdChanged -gt 0) {
                        Add-Finding 'WARN' 'KeyDrift' $cd.Name "$accessIdChanged items have SAME IdentityId+AccessName but DIFFERENT AccessId between snapshots -- ISC reassignment or entitlement regeneration" "This causes false 'newly added' scope items in diff reports"
                    }
                } catch { Add-Finding 'WARN' 'Snapshots' $prevSnap.Name "Could not parse previous snapshot for drift check: $($_.Exception.Message)" }
            }
        } catch { Add-Finding 'ERROR' 'Snapshots' $latestSnap.Name "Cannot parse snapshot: $($_.Exception.Message)" }
    }
}
else { Add-Finding 'INFO' 'Snapshots' $snapshotDir 'Snapshot directory does not exist' }

# --- Cross-Campaign Key Stability (for daily campaigns) ---
# Compare the two most recent campaigns to detect items that exist by IdentityId+AccessName
# in both but have different Keys (AccessId changed between campaigns = false "newly added")
if (Test-Path $snapshotDir) {
    $allLatestSnaps = [System.Collections.Generic.List[object]]::new()
    foreach ($cd in @(Get-ChildItem -Path $snapshotDir -Directory -ErrorAction SilentlyContinue)) {
        $sf = @(Get-ChildItem -Path $cd.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.sha256$' })
        if ($sf.Count -eq 0) { continue }
        $latest = $sf | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        try {
            $snapData = Get-Content $latest.FullName -Raw | ConvertFrom-Json
            $startDate = $null
            if ($null -ne $snapData.Meta -and $null -ne $snapData.Meta.PSObject.Properties['StartDate']) {
                try { $startDate = [datetime]::Parse([string]$snapData.Meta.StartDate) } catch { }
            }
            if ($null -eq $startDate) { $startDate = $latest.LastWriteTime }
            $allLatestSnaps.Add(@{ Dir = $cd.Name; StartDate = $startDate; Snapshot = $snapData; Path = $latest.FullName })
        } catch { }
    }

    if ($allLatestSnaps.Count -ge 2) {
        Write-Host '  [4b] Cross-Campaign Key Stability' -ForegroundColor White
        [void]$logSb.AppendLine('')
        [void]$logSb.AppendLine('=== 4b. CROSS-CAMPAIGN KEY STABILITY ===')

        $sorted = @($allLatestSnaps | Sort-Object { $_.StartDate } -Descending)
        $newest = $sorted[0]; $previous = $sorted[1]
        $nName = if ($null -ne $newest.Snapshot.Meta) { $newest.Snapshot.Meta.CampaignName } else { $newest.Dir }
        $pName = if ($null -ne $previous.Snapshot.Meta) { $previous.Snapshot.Meta.CampaignName } else { $previous.Dir }

        Add-Finding 'INFO' 'CrossCampaign' '' "Comparing newest ($nName) vs previous ($pName)"

        $nItems = @($newest.Snapshot.Items)
        $pItems = @($previous.Snapshot.Items)

        # Build lookup by IdentityId+AccessName (the SEMANTIC key -- same person, same entitlement)
        $nByNameKey = @{}
        foreach ($it in $nItems) {
            $iid = if ($null -ne $it.PSObject.Properties['IdentityId']) { [string]$it.IdentityId } else { '' }
            $aname = if ($null -ne $it.PSObject.Properties['AccessName']) { [string]$it.AccessName } else { '' }
            $aid = if ($null -ne $it.PSObject.Properties['AccessId']) { [string]$it.AccessId } else { '' }
            $key = if ($null -ne $it.PSObject.Properties['Key']) { [string]$it.Key } else { '' }
            $nameKey = "$iid|$aname"
            if (-not [string]::IsNullOrWhiteSpace($iid)) { $nByNameKey[$nameKey] = @{ AccessId = $aid; Key = $key; IdentityName = $(if ($null -ne $it.PSObject.Properties['IdentityName']) { [string]$it.IdentityName } else { '' }) } }
        }

        $pByNameKey = @{}
        $pByKey = @{}
        foreach ($it in $pItems) {
            $iid = if ($null -ne $it.PSObject.Properties['IdentityId']) { [string]$it.IdentityId } else { '' }
            $aname = if ($null -ne $it.PSObject.Properties['AccessName']) { [string]$it.AccessName } else { '' }
            $aid = if ($null -ne $it.PSObject.Properties['AccessId']) { [string]$it.AccessId } else { '' }
            $key = if ($null -ne $it.PSObject.Properties['Key']) { [string]$it.Key } else { '' }
            $nameKey = "$iid|$aname"
            if (-not [string]::IsNullOrWhiteSpace($iid)) { $pByNameKey[$nameKey] = @{ AccessId = $aid; Key = $key } }
            if (-not [string]::IsNullOrWhiteSpace($key)) { $pByKey[$key] = $true }
        }

        # Items in newest that the DIFF engine would see as "newly added" (key not in previous)
        $diffAdded = 0; $falseAdded = 0; $accessIdChurn = 0
        $falseAddedIdentities = @{}
        foreach ($it in $nItems) {
            $key = if ($null -ne $it.PSObject.Properties['Key']) { [string]$it.Key } else { '' }
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if ($pByKey.ContainsKey($key)) { continue }  # key matches -- not "added"

            $diffAdded++  # diff engine would call this "added"

            # But is it SEMANTICALLY the same item? (same person + same entitlement name)
            $iid = if ($null -ne $it.PSObject.Properties['IdentityId']) { [string]$it.IdentityId } else { '' }
            $aname = if ($null -ne $it.PSObject.Properties['AccessName']) { [string]$it.AccessName } else { '' }
            $nameKey = "$iid|$aname"
            if ($pByNameKey.ContainsKey($nameKey)) {
                # SAME person + entitlement EXISTS in previous -- this is a FALSE "newly added"
                $falseAdded++
                $iname = if ($null -ne $it.PSObject.Properties['IdentityName']) { [string]$it.IdentityName } else { $iid }
                if (-not $falseAddedIdentities.ContainsKey($iid)) { $falseAddedIdentities[$iid] = @{ Name = $iname; Count = 0 } }
                $falseAddedIdentities[$iid].Count++

                # Check if AccessId changed
                $prevAid = $pByNameKey[$nameKey].AccessId
                $curAid = if ($null -ne $it.PSObject.Properties['AccessId']) { [string]$it.AccessId } else { '' }
                if ($curAid -ne $prevAid -and -not [string]::IsNullOrWhiteSpace($prevAid) -and -not [string]::IsNullOrWhiteSpace($curAid)) {
                    $accessIdChurn++
                }
            }
        }

        Add-Finding 'INFO' 'CrossCampaign' '' "Newest: $($nItems.Count) items | Previous: $($pItems.Count) items"
        Add-Finding 'INFO' 'CrossCampaign' '' "Items diff engine would mark as 'newly added': $diffAdded"

        if ($falseAdded -gt 0) {
            Add-Finding 'ERROR' 'CrossCampaign' '' "$falseAdded items would show as 'newly added' but the SAME IdentityId+AccessName exists in the previous campaign -- these are FALSE scope additions"
            Add-Finding 'WARN' 'CrossCampaign' '' "Affected identities:"
            foreach ($iid in $falseAddedIdentities.Keys) {
                $fi = $falseAddedIdentities[$iid]
                Add-Finding 'WARN' 'CrossCampaign' '' "  $($fi.Name) ($iid): $($fi.Count) false 'newly added' items"
            }
            if ($accessIdChurn -gt 0) {
                Add-Finding 'ERROR' 'CrossCampaign' '' "$accessIdChurn of these have DIFFERENT AccessId between campaigns -- ISC is regenerating access IDs per campaign, causing key instability"
                Add-Finding 'WARN' 'CrossCampaign' '' "ROOT CAUSE: The diff key uses AccessId which changes between daily campaigns for reassigned certifications. The diff engine should fall back to IdentityId+AccessName matching when AccessId changes."
            }
            else {
                Add-Finding 'WARN' 'CrossCampaign' '' "AccessId is STABLE but keys still don't match -- check if SourceId changed or if items are genuinely from a different source"
            }
        }
        elseif ($diffAdded -gt 0) {
            Add-Finding 'INFO' 'CrossCampaign' '' "All $diffAdded 'newly added' items are genuinely new (identity+access not in previous campaign)"
        }
        else {
            Add-Finding 'INFO' 'CrossCampaign' '' 'No key drift detected -- all items in newest campaign match the previous campaign by key'
        }
    }
}

[void]$logSb.AppendLine('')
#endregion

#region 5. Campaign Trend Files
Write-Host '  [5/6] Campaign Trend Files' -ForegroundColor White
[void]$logSb.AppendLine('=== 5. CAMPAIGN TREND FILES ===')

if (Test-Path $trendDir) {
    $trendFiles = @()
    $searchDirs = @($trendDir)
    try { Get-ChildItem -Path $trendDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $searchDirs += $_.FullName } } catch { }
    foreach ($sd in $searchDirs) { $trendFiles += @(Get-ChildItem -Path $sd -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) }

    Add-Finding 'INFO' 'Trends' $trendDir "$($trendFiles.Count) trend file(s)"

    foreach ($tf in $trendFiles) {
        $tLines = 0; $tErrors = 0; $tDates = [System.Collections.Generic.List[string]]::new()
        $tScopeBaseline = 0; $lastTotal = -1; $totalDrops = 0
        try {
            foreach ($ln in [System.IO.File]::ReadAllLines($tf.FullName, $utf8)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                $tLines++
                try {
                    $rec = $ln | ConvertFrom-Json
                    $ts = [datetime]::Parse([string]$rec.timestamp)
                    $dateKey = $ts.ToString('yyyy-MM-dd')
                    $tDates.Add($dateKey)

                    # Check for baseline captures (scope.added >= total)
                    $m = $rec.metrics
                    if ($null -ne $m) {
                        $sa = $null; $tot = $null
                        try { $saProp = $m.PSObject.Properties['scope.added']; if ($null -ne $saProp) { $sa = [int]$saProp.Value } } catch { }
                        try { $totProp = $m.PSObject.Properties['counts.total']; if ($null -ne $totProp) { $tot = [int]$totProp.Value } } catch { }
                        if ($null -ne $sa -and $null -ne $tot -and $sa -ge $tot -and $tot -gt 0) { $tScopeBaseline++ }
                        # Check for total dropping (items removed/reassigned)
                        if ($null -ne $tot -and $lastTotal -gt 0 -and $tot -lt $lastTotal) { $totalDrops++ }
                        if ($null -ne $tot) { $lastTotal = $tot }
                    }
                } catch { $tErrors++ }
            }
        } catch { Add-Finding 'ERROR' 'Trends' $tf.Name "Cannot read: $($_.Exception.Message)"; continue }

        $uniqueDates = @($tDates | Sort-Object -Unique)
        $dupDates = $tDates.Count - $uniqueDates.Count
        Add-Finding 'INFO' 'Trends' $tf.Name "$tLines records, $($uniqueDates.Count) unique days, $tErrors parse errors"
        if ($tErrors -gt 0) { Add-Finding 'ERROR' 'Trends' $tf.Name "$tErrors lines failed JSON parse" }
        if ($dupDates -gt 0) { Add-Finding 'WARN' 'Trends' $tf.Name "$dupDates duplicate date entries (multiple captures same day)" }
        if ($tScopeBaseline -gt 0) { Add-Finding 'WARN' 'Trends' $tf.Name "$tScopeBaseline baseline capture(s) where scope.added >= total (no valid prior snapshot at time of capture)" }
        if ($totalDrops -gt 0) { Add-Finding 'WARN' 'Trends' $tf.Name "$totalDrops day(s) where total item count DROPPED vs prior day (items removed/reassigned)" }
    }
}
else { Add-Finding 'INFO' 'Trends' $trendDir 'Trend directory does not exist' }

[void]$logSb.AppendLine('')
#endregion

#region 6. Governance Metrics
Write-Host '  [6/6] Governance Metrics' -ForegroundColor White
[void]$logSb.AppendLine('=== 6. GOVERNANCE METRICS ===')

$govFile = Join-Path $metricsDir 'governance-metrics.jsonl'
if (Test-Path $govFile) {
    $gLines = 0; $gErrors = 0
    try {
        foreach ($ln in [System.IO.File]::ReadAllLines($govFile, $utf8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $gLines++
            try { $ln | ConvertFrom-Json | Out-Null } catch { $gErrors++ }
        }
    } catch { Add-Finding 'ERROR' 'GovMetrics' 'governance-metrics.jsonl' "Cannot read: $($_.Exception.Message)" }

    $fileSize = [math]::Round((Get-Item $govFile).Length / 1024, 1)
    Add-Finding 'INFO' 'GovMetrics' 'governance-metrics.jsonl' "$gLines records, ${fileSize} KB"
    if ($gErrors -gt 0) { Add-Finding 'ERROR' 'GovMetrics' 'governance-metrics.jsonl' "$gErrors lines failed JSON parse" }
}
else { Add-Finding 'INFO' 'GovMetrics' 'governance-metrics.jsonl' 'File does not exist' }

$hbFile = Join-Path $metricsDir 'governance-heartbeat.jsonl'
if (Test-Path $hbFile) {
    $hbLines = (Get-Content $hbFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    Add-Finding 'INFO' 'GovMetrics' 'governance-heartbeat.jsonl' "$hbLines heartbeat records"
}

[void]$logSb.AppendLine('')
#endregion

#region Summary
Write-Host ''
Write-Host '  =================================================' -ForegroundColor Cyan
Write-Host '  DIAGNOSTIC SUMMARY' -ForegroundColor Cyan
Write-Host ''

$errors = @($findings | Where-Object { $_.Severity -eq 'ERROR' })
$warns  = @($findings | Where-Object { $_.Severity -eq 'WARN' })
$infos  = @($findings | Where-Object { $_.Severity -eq 'INFO' })

$summaryColor = if ($errors.Count -gt 0) { 'Red' } elseif ($warns.Count -gt 0) { 'Yellow' } else { 'Green' }
$summaryStatus = if ($errors.Count -gt 0) { 'ISSUES FOUND' } elseif ($warns.Count -gt 0) { 'WARNINGS' } else { 'HEALTHY' }

Write-Host "  Status:   $summaryStatus" -ForegroundColor $summaryColor
Write-Host "  Errors:   $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warnings: $($warns.Count)" -ForegroundColor $(if ($warns.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Info:     $($infos.Count)" -ForegroundColor DarkGray
Write-Host ''

[void]$logSb.AppendLine('=== SUMMARY ===')
[void]$logSb.AppendLine("Status: $summaryStatus")
[void]$logSb.AppendLine("Errors: $($errors.Count) | Warnings: $($warns.Count) | Info: $($infos.Count)")
[void]$logSb.AppendLine('')

if ($errors.Count -gt 0) {
    [void]$logSb.AppendLine('--- ERRORS ---')
    foreach ($e in $errors) { [void]$logSb.AppendLine("  [$($e.Category)] $($e.File): $($e.Message)$(if($e.Detail){" -- $($e.Detail)"})") }
    [void]$logSb.AppendLine('')
}
if ($warns.Count -gt 0) {
    [void]$logSb.AppendLine('--- WARNINGS ---')
    foreach ($w in $warns) { [void]$logSb.AppendLine("  [$($w.Category)] $($w.File): $($w.Message)$(if($w.Detail){" -- $($w.Detail)"})") }
    [void]$logSb.AppendLine('')
}

# Write log file
[System.IO.File]::WriteAllText($logFile, $logSb.ToString(), $utf8)
Write-Host "  Log: $logFile" -ForegroundColor White
Write-Host ''
#endregion
