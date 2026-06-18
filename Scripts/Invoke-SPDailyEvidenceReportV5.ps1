#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the daily certification evidence report (v5) -- the trend-aware evidence
    artifact with multi-day progression charts (output: daily-evidence-v5-*.html).
.DESCRIPTION
    V5 reads per-campaign trend JSONL files (daily snapshots with per-reviewer data,
    scope changes, timing, and risk metrics) and renders multi-day progression charts.

    Key design principle: No campaign capture = no data point = no bar/cell.  Weekends
    and holidays where the orchestrator does not run simply do not appear.  The charts
    show only business days that had actual captures.

    Visualization styles (A through N):
      A   Horizontal bar charts    -- reviewer completion over N days
      B   Stacked progress bars    -- decision distribution day-by-day
      B2  Vertical bar chart       -- items reviewed % + reviewer completion %
      C   Sparkline mini-charts    -- compact metric trends with current/prior/delta
      D   Table with delta arrows  -- per-reviewer numeric comparison + status
      E   Privileged access gauge  -- semicircular SVG gauge with sparkline
      F   Scope drift monitor      -- cumulative decisions vs scope growth
      G   Rubber-stamp detector    -- approval ratio lollipop chart
      H   Reviewer activity heatmap -- decision intensity grid
      I   Workload treemap         -- reviewer item volume
      J   Completion projection    -- line chart with deadline projection
      K   Decision velocity leader -- segmented bar chart + rank badges
      L   Scope waterfall          -- daily pending item changes
      M   Engagement timeline      -- Gantt-style reviewer activity map
      N   Cross-campaign risk      -- multi-campaign risk matrix

    Optionally captures a new trend point before rendering (unless -NoCapture).

    Exit codes:
        0 = Healthy (completion >= 80%, no stalled reviewers, on track)
        1 = Warning (completion 50-79%, some concerns)
        2 = Parameter error
        4 = Configuration error
        5 = Critical (completion < 50%, stalled, or insufficient data)
.PARAMETER DaysBack
    Campaign trend lookback window in days. Default: 14.
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name filter.
.PARAMETER CampaignNameStartsWith
    Campaign name begins with this prefix.
.PARAMETER CampaignNameContains
    Campaign name contains this substring.
.PARAMETER CampaignId
    Specific campaign ID to report on.
.PARAMETER Status
    Campaign status filter. One or more of: STAGED, ACTIVE, COMPLETING, COMPLETED.
    Applied to both live API campaign fetching (capture mode) and trend JSONL record
    filtering (NoCapture mode). If omitted, all statuses are included.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication (used only if capturing new snapshot).
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER SourceId
    Source IDs to scope analytics. If omitted, uses configured sources.
.PARAMETER SlaHours
    Hours before a revocation is considered overdue. Default 48.
.PARAMETER HighRiskThreshold
    Risk score threshold for high-risk classification. Default 70.
.PARAMETER OutputMode
    Console: formatted summary to terminal.
    HTML: self-contained HTML report file.
    JSON: machine-parseable result object.
    Both (default): console output and HTML file.
.PARAMETER OutputPath
    Directory for output files. Defaults to daily-evidence subdirectory.
.PARAMETER DeadlineDays
    Days until deadline for Style J projection. Default 5.
.PARAMETER NoCapture
    Offline mode -- do not capture a new snapshot, just read existing trend data.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be executed without making API calls.
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV5.ps1 -NoCapture
    # Render trend report from existing JSONL data (no API calls).
.EXAMPLE
    .\Invoke-SPDailyEvidenceReportV5.ps1 -DaysBack 30 -CampaignNameContains 'Q2'
    # 30-day trend for campaigns matching 'Q2'.
.NOTES
    Script:  Invoke-SPDailyEvidenceReportV5.ps1
    Version: 1.0.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [int]$DaysBack = 14,

    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [string]$CampaignId,

    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    [Parameter()]
    [int]$SlaHours = 48,

    [Parameter()]
    [int]$HighRiskThreshold = 70,

    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Both',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [int]$DeadlineDays = 5,

    [Parameter()]
    [switch]$NoCapture,

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

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true  }
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

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '$ConfigPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host "ERROR: Configuration validation failed. Check settings.json for required values." -ForegroundColor Red
    exit 4
}

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

# Browser token injection (only needed if capturing)
if ($Token -and -not $NoCapture) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

$effectiveDaysBack = $DaysBack
if ($effectiveDaysBack -le 0) { $effectiveDaysBack = 14 }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Daily Evidence Report (v5) -- Trend View' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  Period:        Last $effectiveDaysBack day(s)" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

Write-SPLog -Message "Invoke-SPDailyEvidenceReportV5 started: CorrelationID=$correlationID DaysBack=$effectiveDaysBack" `
    -Severity INFO -Component 'DailyEvidenceV5' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $deOutputPath = $null
    if ($null -ne $config.PSObject.Properties['DailyEvidence'] -and
        $null -ne $config.DailyEvidence -and
        $null -ne $config.DailyEvidence.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.DailyEvidence.OutputPath)) {
        $deOutputPath = [string]$config.DailyEvidence.OutputPath
    }

    if ($null -ne $deOutputPath) {
        $effectiveOutputPath = $deOutputPath
    }
    elseif ($null -ne $config.PSObject.Properties['Audit'] -and
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

#region WhatIf

$isWhatIf = ($WhatIfPreference -eq $true)

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following steps would be executed:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  [1] Resolve trend directory from config" -ForegroundColor Gray
    if (-not $NoCapture) {
        Write-Host "  [2] Capture today's snapshot + save trend point" -ForegroundColor Gray
    } else {
        Write-Host "  [2] (Skipped -- NoCapture mode)" -ForegroundColor Gray
    }
    Write-Host "  [3] Find campaign trend JSONL file(s)" -ForegroundColor Gray
    $nameFilterDesc = ''
    if ($CampaignId)             { $nameFilterDesc += " CampaignId='$CampaignId'" }
    if ($CampaignName)           { $nameFilterDesc += " Name='$CampaignName'" }
    if ($CampaignNameStartsWith) { $nameFilterDesc += " StartsWith='$CampaignNameStartsWith'" }
    if ($CampaignNameContains)   { $nameFilterDesc += " Contains='$CampaignNameContains'" }
    if ($nameFilterDesc) { Write-Host "      Filters:$nameFilterDesc" -ForegroundColor Gray }
    Write-Host "  [4] Read JSONL records within ${effectiveDaysBack}-day window" -ForegroundColor Gray
    Write-Host '  [5] Render charts A through N' -ForegroundColor Gray
    Write-Host "  [6] Write HTML report to: $effectiveOutputPath" -ForegroundColor Gray
    Write-Host ''
    Write-Host "  Output mode:  $OutputMode" -ForegroundColor DarkGray
    Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

#endregion

#region Helper: safe property access

function Get-V5Prop {
    param($Object, [string]$Name, $Default = '')
    return (Get-SPObjectProperty -Object $Object -Name $Name -Default $Default)
}

function Get-V5MetricVal {
    # Read a flat metric from a JSONL record's .metrics object.
    # Handles both hashtable and PSCustomObject (ConvertFrom-Json returns PSCustomObject).
    param([object]$Metrics, [string]$Name, $Default = 0)
    if ($null -eq $Metrics) { return $Default }
    try {
        if ($Metrics -is [System.Collections.IDictionary]) {
            if ($Metrics.Contains($Name)) { $v = $Metrics[$Name]; if ($null -ne $v) { return $v } }
            return $Default
        }
        $p = $Metrics.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

#endregion

#region Step 1: Resolve Trend Directory

Write-Host '  Step 1: Resolve trend directory' -ForegroundColor Cyan

$trendDir = $null
$envName = ''
try {
    if ($null -ne $config.PSObject.Properties['Environment'] -and
        -not [string]::IsNullOrWhiteSpace($config.Environment)) {
        $envName = [string]$config.Environment
    }
} catch { }

# Resolve trend directory -- same logic as Get-SPCampaignTrendDir
try {
    if ($null -ne $config.PSObject.Properties['Metrics']) {
        if ($null -ne $config.Metrics.PSObject.Properties['CampaignTrendPath'] -and
            -not [string]::IsNullOrWhiteSpace($config.Metrics.CampaignTrendPath)) {
            $trendDir = [string]$config.Metrics.CampaignTrendPath
        }
        elseif ($null -ne $config.Metrics.PSObject.Properties['Path'] -and
                -not [string]::IsNullOrWhiteSpace($config.Metrics.Path)) {
            $trendDir = Join-Path ([string]$config.Metrics.Path) 'campaign-trend'
        }
    }
} catch { }
if ([string]::IsNullOrWhiteSpace($trendDir)) { $trendDir = '.\Audit\metrics\campaign-trend' }
if (-not [System.IO.Path]::IsPathRooted($trendDir)) {
    $trendDir = [System.IO.Path]::GetFullPath((Join-Path $toolkitRoot $trendDir))
}
# Environment subfolder
if (-not [string]::IsNullOrWhiteSpace($envName)) {
    $safeEnv = $envName -replace '[^A-Za-z0-9_\-]', '_'
    $trendDir = Join-Path $trendDir $safeEnv
}

Write-Host "    Trend directory: $trendDir" -ForegroundColor DarkGray

if (-not (Test-Path $trendDir)) {
    Write-Host "    Trend directory does not exist yet." -ForegroundColor Yellow
    if (-not $NoCapture) {
        Write-Host "    Will create after first capture." -ForegroundColor DarkGray
    } else {
        Write-Host "  ERROR: No trend data and -NoCapture specified. Cannot generate report." -ForegroundColor Red
        Write-Host "  Suggestion: Run the daily orchestrator (Invoke-SPCertTracker) at least once" -ForegroundColor Yellow
        Write-Host "  to capture campaign snapshots, or remove the -NoCapture flag." -ForegroundColor Yellow
        exit 5
    }
}

Write-Host ''

#endregion

#region Step 2: Capture today's snapshot (optional)

if (-not $NoCapture) {
    Write-Host "  Step 2: Capture today's snapshot" -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Fetch campaigns
        Write-Host '    Fetching campaigns...' -ForegroundColor DarkGray
        $campaignParams = @{ DaysBack = $effectiveDaysBack; CorrelationID = $correlationID }
        if ($CampaignName)           { $campaignParams['CampaignName']           = $CampaignName }
        if ($CampaignNameStartsWith) { $campaignParams['CampaignNameStartsWith'] = $CampaignNameStartsWith }
        if ($CampaignNameContains)   { $campaignParams['CampaignNameContains']   = $CampaignNameContains }
        if ($Status)                 { $campaignParams['Status']                 = $Status }
        if ($SourceId)               { $campaignParams['SourceId']               = $SourceId }

        $campaignResult = Get-SPAuditCampaigns @campaignParams
        $currentCampaigns = @()
        if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
            $currentCampaigns = @($campaignResult.Data)
        }

        # If CampaignId filter, restrict
        if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
            $currentCampaigns = @($currentCampaigns | Where-Object { [string]$_.id -eq $CampaignId })
        }

        Write-Host "    Found $($currentCampaigns.Count) campaign(s)." -ForegroundColor DarkGray

        if ($currentCampaigns.Count -gt 0) {
            $prov = @{}
            if (-not [string]::IsNullOrWhiteSpace($envName)) { $prov['Environment'] = $envName }

            foreach ($camp in $currentCampaigns) {
                $campId   = [string]$camp.id
                $campName = [string]$camp.name
                Write-Host "    Capturing: $campName" -ForegroundColor DarkGray

                try {
                    $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
                    $certifications = @()
                    if ($certResult.Success -and $null -ne $certResult.Data) {
                        $certifications = @($certResult.Data)
                    }

                    $wrappedItems = [System.Collections.Generic.List[object]]::new()
                    $cacheResult = Get-SPCachedCampaignItems -Campaign $camp -Certifications $certifications -CorrelationID $correlationID
                    if ($cacheResult.Success) {
                        foreach ($wi in $cacheResult.Data) { $wrappedItems.Add($wi) }
                    }

                    $campaignMetadata = @{
                        StartDate      = if ($null -ne $camp.created)   { [string]$camp.created }   else { '' }
                        DueDate        = if ($null -ne $camp.deadline)  { [string]$camp.deadline }
                                         elseif ($null -ne $camp.due)   { [string]$camp.due }       else { '' }
                        CompletionDate = if ($null -ne $camp.completed) { [string]$camp.completed } else { '' }
                    }

                    $decisions = Group-SPAuditDecisions -Items $wrappedItems.ToArray() -CampaignMetadata $campaignMetadata
                    $snapshot = Build-SPCampaignSnapshotData -Campaign $camp -Certifications $certifications -Decisions $decisions -Provenance $prov

                    # Save snapshot
                    try { Save-SPCampaignSnapshot -Snapshot $snapshot | Out-Null } catch { }

                    # Save trend point (this is the key line for V5)
                    try {
                        $tpResult = Save-SPCampaignTrendPoint -Snapshot $snapshot
                        if ($tpResult.Success) {
                            Write-Host "      Trend point saved: $($tpResult.Data.Timestamp)" -ForegroundColor DarkGreen
                        } else {
                            Write-Host "      WARN: Trend save: $($tpResult.Error)" -ForegroundColor Yellow
                        }
                    } catch {
                        Write-Host "      WARN: Trend save failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "    WARN: Capture failed for ${campName}: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "  Step 2: Capture complete ($([math]::Round($stepDuration,1))s)" -ForegroundColor Green
    }
    catch {
        Write-Host "  Step 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Capture exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DailyEvidenceV5' -Action 'CaptureError' -CorrelationID $correlationID
    }
    Write-Host ''
} else {
    Write-Host '  Step 2: Skipped (NoCapture mode)' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 3: Find and read campaign trend JSONL

Write-Host '  Step 3: Read campaign trend data' -ForegroundColor Cyan

$utf8 = New-Object System.Text.UTF8Encoding($false)
$cutoff = (Get-Date).AddDays(-$effectiveDaysBack).ToUniversalTime()
$trendRecords = [System.Collections.Generic.List[object]]::new()
$campaignNameResolved = ''
$campaignIdResolved = ''
$campaignDueDate = ''
$campaignStatus = ''

# Also collect all campaign trend files for Style N (cross-campaign risk)
$allCampaignLatest = [System.Collections.Generic.List[object]]::new()

if (Test-Path $trendDir) {
    # Search the trend directory and one level of subdirectories
    $searchDirs = @($trendDir)
    try {
        $subDirs = Get-ChildItem -Path $trendDir -Directory -ErrorAction SilentlyContinue
        foreach ($sd in $subDirs) { $searchDirs += $sd.FullName }
    } catch { }

    $allJsonlFiles = @()
    foreach ($dir in $searchDirs) {
        $allJsonlFiles += @(Get-ChildItem -Path $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    }

    Write-Host "    Found $($allJsonlFiles.Count) trend file(s)" -ForegroundColor DarkGray

    # Determine which file(s) to read for the primary campaign
    $targetFiles = @()

    if (-not [string]::IsNullOrWhiteSpace($CampaignId)) {
        # Specific campaign ID
        $safeId = $CampaignId -replace '[^A-Za-z0-9_\-]', '_'
        $targetFiles = @($allJsonlFiles | Where-Object { $_.BaseName -eq $safeId })
        if ($targetFiles.Count -eq 0) {
            Write-Host "    No trend file found for CampaignId: $CampaignId" -ForegroundColor Yellow
            Write-Host "    Available files: $($allJsonlFiles | ForEach-Object { $_.BaseName })" -ForegroundColor DarkGray
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CampaignName) -or
            -not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith) -or
            -not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
        # Name-based filter: scan files to find matching campaign names
        foreach ($f in $allJsonlFiles) {
            try {
                $lines = [System.IO.File]::ReadAllLines($f.FullName, $utf8)
                if ($lines.Count -eq 0) { continue }
                # Check last line for campaign name
                $lastLine = $lines[$lines.Count - 1]
                if ([string]::IsNullOrWhiteSpace($lastLine)) {
                    for ($li = $lines.Count - 2; $li -ge 0; $li--) {
                        if (-not [string]::IsNullOrWhiteSpace($lines[$li])) { $lastLine = $lines[$li]; break }
                    }
                }
                $lastRec = $lastLine | ConvertFrom-Json
                $cn = [string]$lastRec.campaignName
                $match = $false
                if (-not [string]::IsNullOrWhiteSpace($CampaignName) -and $cn -eq $CampaignName) { $match = $true }
                if (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith) -and $cn.StartsWith($CampaignNameStartsWith, [System.StringComparison]::OrdinalIgnoreCase)) { $match = $true }
                if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains) -and $cn.IndexOf($CampaignNameContains, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $match = $true }
                if ($match) { $targetFiles += $f }
            } catch { }
        }
    }
    else {
        # No filter: find the most recently modified JSONL (most recent active campaign)
        $targetFiles = @($allJsonlFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }

    # Read records from target file(s)
    foreach ($f in $targetFiles) {
        try {
            foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, $utf8)) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                try {
                    $rec = $ln | ConvertFrom-Json
                    $ts = [datetime]::Parse([string]$rec.timestamp).ToUniversalTime()
                    if ($ts -lt $cutoff) { continue }
                    # Apply Status filter to trend records (if specified)
                    if ($Status -and $Status.Count -gt 0) {
                        $recStatus = [string]$rec.status
                        if ($recStatus -notin $Status) { continue }
                    }
                    $trendRecords.Add($rec)
                } catch { }
            }
        } catch { }
    }

    # Read latest record from ALL campaign files for cross-campaign view (Style N)
    foreach ($f in $allJsonlFiles) {
        try {
            $lines = [System.IO.File]::ReadAllLines($f.FullName, $utf8)
            $lastLine = ''
            for ($li = $lines.Count - 1; $li -ge 0; $li--) {
                if (-not [string]::IsNullOrWhiteSpace($lines[$li])) { $lastLine = $lines[$li]; break }
            }
            if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
                $lastRec = $lastLine | ConvertFrom-Json
                $allCampaignLatest.Add($lastRec)
            }
        } catch { }
    }
}

# Sort records by timestamp
$trendRecords = [System.Collections.Generic.List[object]]::new(
    @($trendRecords | Sort-Object { [datetime]::Parse([string]$_.timestamp) })
)

Write-Host "    Loaded $($trendRecords.Count) trend record(s) within ${effectiveDaysBack}-day window" -ForegroundColor DarkGray

if ($trendRecords.Count -eq 0) {
    Write-Host '' -ForegroundColor Red
    Write-Host '  ERROR: No trend data found for the specified campaign/filter.' -ForegroundColor Red
    Write-Host '' -ForegroundColor Yellow
    Write-Host '  Suggestions:' -ForegroundColor Yellow
    Write-Host '    - Run the daily orchestrator (Invoke-SPCertTracker) to capture snapshots' -ForegroundColor Yellow
    Write-Host '    - Check your -CampaignName / -CampaignId filters' -ForegroundColor Yellow
    Write-Host "    - Increase -DaysBack (current: $effectiveDaysBack)" -ForegroundColor Yellow
    Write-Host "    - Verify trend directory: $trendDir" -ForegroundColor Yellow
    Write-Host '' -ForegroundColor Red
    exit 5
}

# Resolve campaign metadata from the latest record
$latestRecord = $trendRecords[$trendRecords.Count - 1]
$campaignNameResolved = [string]$latestRecord.campaignName
$campaignIdResolved   = [string]$latestRecord.campaignId
$campaignDueDate      = [string]$latestRecord.dueDate
$campaignStatus       = [string]$latestRecord.status

Write-Host "    Campaign: $campaignNameResolved ($campaignIdResolved)" -ForegroundColor DarkGray
Write-Host "    Status: $campaignStatus" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region Step 4: Build $dailyData from JSONL records

Write-Host '  Step 4: Build daily data from trend records' -ForegroundColor Cyan

# Deduplicate: keep only the LATEST record per calendar day
$dayMap = [ordered]@{}
foreach ($rec in $trendRecords) {
    $ts = [datetime]::Parse([string]$rec.timestamp)
    $dayKey = $ts.ToString('yyyy-MM-dd')
    $dayMap[$dayKey] = $rec
}

$dailyData = @()
foreach ($dayKey in $dayMap.Keys) {
    $rec = $dayMap[$dayKey]
    $ts = [datetime]::Parse([string]$rec.timestamp)
    $m = $rec.metrics

    # Map per-reviewer data
    $dayReviewers = @()
    $reviewerArray = $null
    try {
        if ($null -ne $rec.PSObject.Properties['reviewers'] -and $null -ne $rec.reviewers) {
            $reviewerArray = @($rec.reviewers)
        }
    } catch { }

    if ($null -ne $reviewerArray) {
        foreach ($rv in $reviewerArray) {
            if ($null -eq $rv) { continue }
            $dayReviewers += @{
                Name       = [string](Get-V5Prop $rv 'reviewer' '')
                Total      = [int](Get-V5Prop $rv 'total' 0)
                Approved   = [int](Get-V5Prop $rv 'approved' 0)
                Revoked    = [int](Get-V5Prop $rv 'revoked' 0)
                Pending    = [int](Get-V5Prop $rv 'pending' 0)
                Completion = [double](Get-V5Prop $rv 'completion' 0)
            }
        }
    }

    $total    = [int](Get-V5MetricVal $m 'counts.total' 0)
    $approved = [int](Get-V5MetricVal $m 'counts.approved' 0)
    $revoked  = [int](Get-V5MetricVal $m 'counts.revoked' 0)
    $pending  = [int](Get-V5MetricVal $m 'counts.pending' 0)

    $dailyData += @{
        Date          = $ts.ToString('yyyy-MM-dd')
        DayLabel      = $ts.ToString('MM/dd')
        Reviewers     = $dayReviewers
        Total         = $total
        Approved      = $approved
        Revoked       = $revoked
        Pending       = $pending
        CompletionPct = [double](Get-V5MetricVal $m 'completion.byDecisionPct' 0)
        ScopeAdded    = [int](Get-V5MetricVal $m 'scope.added' 0)
        ScopeRemoved  = [int](Get-V5MetricVal $m 'scope.removed' 0)
        PrivPending   = [int](Get-V5MetricVal $m 'counts.privPending' 0)
        PrivTotal     = [int](Get-V5MetricVal $m 'risk.privilegedTotal' 0)
    }
}

$dayCount = $dailyData.Count
Write-Host "    Built $dayCount daily data point(s)" -ForegroundColor DarkGray

# Build reviewer list (distinct across all days)
$reviewerNames = [ordered]@{}
foreach ($d in $dailyData) {
    foreach ($rv in $d.Reviewers) {
        $rn = $rv.Name
        if (-not [string]::IsNullOrWhiteSpace($rn) -and -not $reviewerNames.Contains($rn)) {
            $reviewerNames[$rn] = $true
        }
    }
}

# Build reviewer summary with behavior classification and first-seen tracking
$reviewers = @()
foreach ($rn in $reviewerNames.Keys) {
    [double]$firstComp = -1; [double]$lastComp = 0; $firstSeenIdx = -1
    for ($di = 0; $di -lt $dailyData.Count; $di++) {
        $rvDay = $dailyData[$di].Reviewers | Where-Object { $_.Name -eq $rn }
        if ($null -ne $rvDay) {
            $compVal = [double]$rvDay.Completion
            if ($firstComp -lt 0) { $firstComp = $compVal; $firstSeenIdx = $di }
            $lastComp = $compVal
        }
    }
    if ($firstComp -lt 0) { $firstComp = 0 }

    [double]$delta = $lastComp - $firstComp
    $style = if ($lastComp -ge 100) { 'finishing' }
             elseif ($lastComp -ge 90) { 'finishing' }
             elseif ($delta -lt 1 -and $lastComp -lt 95) { 'stalled' }
             elseif ($delta -lt 5) { 'slow' }
             else { 'steady' }

    $reviewers += @{
        Name            = $rn
        StartCompletion = $firstComp
        LastCompletion  = $lastComp
        Style           = $style
        FirstSeenIdx    = $firstSeenIdx
        FirstSeenDate   = if ($firstSeenIdx -ge 0) { $dailyData[$firstSeenIdx].DayLabel } else { 'N/A' }
    }
}

Write-Host "    Reviewers: $($reviewers.Count)" -ForegroundColor DarkGray
Write-Host ''

#endregion

#region Insufficient Data Guard

$insufficientData = ($dayCount -lt 2)

if ($insufficientData) {
    Write-Host '  NOTE: Less than 2 data points -- single-point report only.' -ForegroundColor Yellow
    Write-Host '        Multi-day charts require at least 2 captures on different days.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Build HTML Report

Write-Host '  Step 5: Build HTML report' -ForegroundColor Cyan

$colors = Get-SPHtmlColorPalette
$genDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$safeCampId = $campaignIdResolved -replace '[^A-Za-z0-9_\-]', '_'
$htmlFile = Join-Path $effectiveOutputPath "daily-evidence-v5-${safeCampId}-${timestamp}.html"

$css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#fff;max-width:1200px;}
h1{font-size:22px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:17px;color:#1f3a5f;margin-top:30px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
h3{font-size:14px;color:#336699;margin-top:20px;}
.meta{color:#566;font-size:12px;margin-bottom:16px;line-height:1.6;}
table{border-collapse:collapse;width:100%;margin:8px 0 16px 0;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:130px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;text-align:center;}
.kpi .n{font-size:22px;font-weight:700;color:#1f3a5f;display:block;}
.kpi .l{font-size:11px;color:#566;text-transform:uppercase;letter-spacing:.04em;}
.note{font-size:11px;color:#777;margin-top:4px;}
.section{margin:24px 0;padding:16px 20px;border:1px solid #d4dce6;border-radius:8px;background:#fafbfd;}
.section-title{font-size:15px;color:#1f3a5f;font-weight:700;margin:0 0 12px 0;padding-bottom:6px;border-bottom:1px solid #d4dce6;}
.style-label{display:inline-block;padding:3px 10px;border-radius:12px;font-size:10px;font-weight:700;color:#fff;background:#336699;margin-bottom:8px;text-transform:uppercase;letter-spacing:.06em;}
.bar-track{background:#e3e9f0;border-radius:4px;height:18px;width:100%;position:relative;overflow:hidden;}
.bar-fill{height:18px;border-radius:4px;transition:width 0.3s;}
.bar-label{position:absolute;right:4px;top:1px;font-size:10px;font-weight:600;color:#1f3a5f;}
.stacked-bar{display:flex;height:22px;border-radius:4px;overflow:hidden;margin:2px 0;}
.stacked-seg{height:22px;display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:600;color:#fff;}
.up-arrow{display:inline-block;width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-bottom:8px solid #0a7d2c;margin-right:3px;}
.down-arrow{display:inline-block;width:0;height:0;border-left:5px solid transparent;border-right:5px solid transparent;border-top:8px solid #b00020;margin-right:3px;}
.flat-line{display:inline-block;width:12px;height:3px;background:#9a6700;margin-right:3px;vertical-align:middle;}
.delta-up{color:#0a7d2c;font-weight:600;}
.delta-down{color:#b00020;font-weight:600;}
.delta-flat{color:#9a6700;}
.footer{margin-top:24px;padding-top:8px;border-top:1px solid #d4dce6;font-size:11px;color:#777;}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:9px;font-weight:700;color:#fff;margin-left:6px;vertical-align:middle;}
.badge-red{background:#b00020;}
.badge-amber{background:#9a6700;}
.badge-green{background:#0a7d2c;}
.badge-gold{background:#c5960c;color:#fff;}
.badge-silver{background:#888;}
.badge-bronze{background:#8b5e3c;}
.risk-matrix td{padding:6px 8px;font-size:12px;border-bottom:1px solid #e3e9f0;vertical-align:middle;}
.risk-matrix th{padding:6px 8px;font-size:11px;}
.thermometer{display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;}
.thermometer-fill{height:14px;border-radius:7px;}
'@

$sb = New-Object System.Text.StringBuilder 32768
[void]$sb.AppendLine("<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Daily Evidence V5 -- Trend Report</title><style>$css</style></head><body>")

# Header
[void]$sb.AppendLine("<h1>Daily Certification Evidence Report (V5) -- Trend View</h1>")
[void]$sb.AppendLine("<p class='meta'>")
[void]$sb.AppendLine("Campaign: <strong>$(ConvertTo-SPHtmlSafe $campaignNameResolved)</strong><br>")
[void]$sb.AppendLine("Status: $(ConvertTo-SPHtmlSafe $campaignStatus)<br>")
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("Period: Last $dayCount captures ($($dailyData[0].Date) to $($dailyData[$dayCount - 1].Date))<br>")
} else {
    [void]$sb.AppendLine("Period: Single capture ($($dailyData[0].Date))<br>")
}
[void]$sb.AppendLine("Generated: $genDate</p>")

# Today's KPIs
$today = $dailyData[$dayCount - 1]
$yesterday = if ($dayCount -ge 2) { $dailyData[$dayCount - 2] } else { $today }
$weekAgo   = $dailyData[0]
$completionDelta = [math]::Round($today.CompletionPct - $yesterday.CompletionPct, 1)
$weekDelta = [math]::Round($today.CompletionPct - $weekAgo.CompletionPct, 1)

[void]$sb.AppendLine("<div style='margin:16px 0;'>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.CompletionPct)%</span><span class='l'>Completion</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.Approved)</span><span class='l'>Approved</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($today.Revoked)</span><span class='l'>Revoked</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$($colors.Red);'>$($today.Pending)</span><span class='l'>Pending</span></span>")
[void]$sb.AppendLine("<span class='kpi'><span class='n'>$($reviewers.Count)</span><span class='l'>Reviewers</span></span>")
if ($dayCount -ge 2) {
    $dSign = if ($weekDelta -gt 0) { '+' } else { '' }
    $dColor = if ($weekDelta -gt 5) { $colors.Green } elseif ($weekDelta -lt -2) { $colors.Red } else { $colors.Amber }
    $dLabel = if ($dayCount -ge 7) { "${dayCount}-Day Change" } else { "${dayCount}-Day Change" }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dColor;'>${dSign}${weekDelta}%</span><span class='l'>$dLabel</span></span>")
}
# SLA Countdown KPI -- handles overdue (negative days)
$effectiveDeadlineDaysKPI = $DeadlineDays
$isOverdue = $false
if (-not [string]::IsNullOrWhiteSpace($campaignDueDate)) {
    try {
        $dueDtKPI = [datetime]::Parse($campaignDueDate)
        $daysToDeadlineKPI = [int][math]::Floor(($dueDtKPI - (Get-Date)).TotalDays)
        $effectiveDeadlineDaysKPI = $daysToDeadlineKPI
        if ($daysToDeadlineKPI -lt 0) { $isOverdue = $true }
    } catch { }
}
if ($isOverdue) {
    $overdueDays = [math]::Abs($effectiveDeadlineDaysKPI)
    $dlKpiColor = $colors.Red
    [void]$sb.AppendLine("<span class='kpi' style='border-color:$($colors.Red);background:$($colors.LightRedBg);'><span class='n' style='color:$($colors.Red);'>OVERDUE</span><span class='l'>by $overdueDays day(s)</span></span>")
} else {
    $dlKpiColor = if ($effectiveDeadlineDaysKPI -le 3) { $colors.Red } elseif ($effectiveDeadlineDaysKPI -le 7) { $colors.Amber } else { $colors.Green }
    [void]$sb.AppendLine("<span class='kpi'><span class='n' style='color:$dlKpiColor;'>$effectiveDeadlineDaysKPI</span><span class='l'>Days to Deadline</span></span>")
}
[void]$sb.AppendLine("</div>")

# Executive summary paragraph
$stalledRvCount = @($reviewers | Where-Object { $_.Style -eq 'stalled' }).Count
$privPendCount = $today.PrivPending
$velocityPerDay = if ($dayCount -ge 2) { [math]::Round(($today.CompletionPct - $weekAgo.CompletionPct) / [math]::Max(1, $dayCount - 1), 1) } else { 0 }
if ($isOverdue) {
    $summaryText = "Campaign is $($today.CompletionPct)% complete and OVERDUE by $([math]::Abs($effectiveDeadlineDaysKPI)) day(s)."
} else {
    $projectedCompletion = [math]::Min(100, $today.CompletionPct + ($velocityPerDay * $effectiveDeadlineDaysKPI))
    $willComplete = if ($projectedCompletion -ge 99.5) { 'will' } else { 'will NOT' }
    $summaryText = "Campaign is $($today.CompletionPct)% complete with $effectiveDeadlineDaysKPI business days until deadline."
}
if ($stalledRvCount -gt 0) {
    $summaryText += " $stalledRvCount reviewer(s) have made zero progress (stalled)."
}
if ($privPendCount -gt 0) {
    $summaryText += " $privPendCount privileged access items remain pending review."
}
if ($dayCount -ge 2 -and -not $isOverdue) {
    $summaryText += " Current velocity (${velocityPerDay}%/day) suggests the campaign $willComplete complete on time."
}
elseif ($dayCount -ge 2 -and $isOverdue) {
    $remaining = 100 - $today.CompletionPct
    $daysNeeded = if ($velocityPerDay -gt 0) { [int][math]::Ceiling($remaining / $velocityPerDay) } else { 999 }
    $summaryText += " Current velocity (${velocityPerDay}%/day). Estimated $daysNeeded more business day(s) needed to complete."
}
[void]$sb.AppendLine("<p style='font-size:13px;color:#1c2b3a;line-height:1.6;margin:12px 0 16px 0;padding:10px 14px;background:#f6f9fc;border-left:4px solid $dlKpiColor;border-radius:4px;'>$summaryText</p>")

# Insufficient data banner
if ($insufficientData) {
    [void]$sb.AppendLine("<div class='section' style='background:#fff7e6;border-color:#ffd97a;'>")
    [void]$sb.AppendLine("<div class='section-title' style='color:#7a5a00;'>Insufficient Trend Data</div>")
    [void]$sb.AppendLine("<p style='color:#7a5a00;font-size:13px;'>Only $dayCount data point(s) available. Multi-day progression charts require at least 2 captures on different days. Below shows today's snapshot data only. Run the orchestrator daily to accumulate the series.</p>")
    [void]$sb.AppendLine("</div>")
}

# ===== STYLE J: Completion Projection vs Deadline =====
if ($dayCount -ge 3) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Completion Projection vs Deadline</div>")
    [void]$sb.AppendLine("<p class='note'>Solid line = actual completion %. Dashed = linear projection from last 3 days velocity. Vertical red line = deadline. Green fill if on track, red if shortfall projected.</p>")

    $jW = 700; $jH = 220; $jPadL = 50; $jPadR = 60; $jPadT = 20; $jPadB = 40
    $jPlotW = $jW - $jPadL - $jPadR; $jPlotH = $jH - $jPadT - $jPadB
    $completionVals = @($dailyData | ForEach-Object { $_.CompletionPct })

    # Velocity from last 3 data points (note: these are not necessarily consecutive calendar days)
    $vel3 = ($completionVals[$dayCount - 1] - $completionVals[[math]::Max(0, $dayCount - 3)]) / [math]::Min(2, [math]::Max(1, $dayCount - 1))
    if ($vel3 -lt 0) { $vel3 = 0 }

    # Resolve deadline days: from JSONL dueDate or parameter (handles overdue = negative)
    $effectiveDeadlineDays = $DeadlineDays
    if (-not [string]::IsNullOrWhiteSpace($campaignDueDate)) {
        try {
            $dueDt = [datetime]::Parse($campaignDueDate)
            $daysToDeadline = [int][math]::Floor(($dueDt - (Get-Date)).TotalDays)
            $effectiveDeadlineDays = $daysToDeadline  # can be negative (overdue)
        } catch { }
    }

    $projectionDays = if ($effectiveDeadlineDays -ge 0) { [math]::Max(3, $effectiveDeadlineDays + 2) } else { 5 }
    $deadlineDayIdx = $effectiveDeadlineDays  # negative = deadline is in the past
    $totalDays = $dayCount + $projectionDays

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$jW' height='$jH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($p = 0; $p -le 100; $p += 25) {
        $yy = [int]($jPadT + $jPlotH - ($p / 100 * $jPlotH))
        [void]$sb.AppendLine("<line x1='$jPadL' y1='$yy' x2='$($jW - $jPadR)' y2='$yy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($jPadL - 5)' y='$($yy + 4)' text-anchor='end' font-size='9' fill='#888'>${p}%</text>")
    }

    $y100 = [int]($jPadT + $jPlotH - (100 / 100 * $jPlotH))
    [void]$sb.AppendLine("<line x1='$jPadL' y1='$y100' x2='$($jW - $jPadR)' y2='$y100' stroke='$($colors.Green)' stroke-width='1' stroke-dasharray='3,3' opacity='0.5'/>")

    $actPts = @()
    for ($i = 0; $i -lt $dayCount; $i++) {
        $ax = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        $ay = [int]($jPadT + $jPlotH - ($completionVals[$i] / 100 * $jPlotH))
        $actPts += "$ax,$ay"
    }

    $actFill = "M $jPadL $($jPadT + $jPlotH)"
    foreach ($pt in $actPts) { $actFill += " L $($pt -replace ',',' ')" }
    $lastActParts = $actPts[$actPts.Count - 1] -split ','
    $actFill += " L $($lastActParts[0]) $($jPadT + $jPlotH) Z"
    [void]$sb.AppendLine("<path d='$actFill' fill='#336699' opacity='0.1'/>")
    [void]$sb.AppendLine("<polyline points='$($actPts -join ' ')' stroke='#336699' stroke-width='2.5' fill='none'/>")

    foreach ($pt in $actPts) {
        $parts = $pt -split ','
        [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='#336699'/>")
    }

    $projPts = @($actPts[$actPts.Count - 1])
    $lastPct = $completionVals[$dayCount - 1]
    for ($i = 1; $i -le $projectionDays; $i++) {
        $projPct = [math]::Min(100, $lastPct + ($vel3 * $i))
        $px = [int]($jPadL + (($dayCount - 1 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        $py = [int]($jPadT + $jPlotH - ($projPct / 100 * $jPlotH))
        $projPts += "$px,$py"
    }

    $projAtDeadline = [math]::Min(100, $lastPct + ($vel3 * $deadlineDayIdx))
    $hitsTarget = $projAtDeadline -ge 99.5
    $projFillColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }

    $projFill = "M $($lastActParts[0]) $($jPadT + $jPlotH)"
    foreach ($pt in $projPts) { $projFill += " L $($pt -replace ',',' ')" }
    $lastProjParts = $projPts[$projPts.Count - 1] -split ','
    $projFill += " L $($lastProjParts[0]) $($jPadT + $jPlotH) Z"
    [void]$sb.AppendLine("<path d='$projFill' fill='$projFillColor' opacity='0.08'/>")
    [void]$sb.AppendLine("<polyline points='$($projPts -join ' ')' stroke='$projFillColor' stroke-width='2' fill='none' stroke-dasharray='6,4'/>")

    $deadlineX = [int]($jPadL + (($dayCount - 1 + $deadlineDayIdx) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
    [void]$sb.AppendLine("<line x1='$deadlineX' y1='$jPadT' x2='$deadlineX' y2='$($jPadT + $jPlotH)' stroke='$($colors.Red)' stroke-width='2' stroke-dasharray='4,3'/>")
    [void]$sb.AppendLine("<text x='$($deadlineX + 4)' y='$($jPadT + 14)' font-size='9' font-weight='600' fill='$($colors.Red)'>DEADLINE</text>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $lx = [int]($jPadL + ($i / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }
    for ($i = 1; $i -le $projectionDays; $i++) {
        $lx = [int]($jPadL + (($dayCount - 1 + $i) / [math]::Max(1, $totalDays - 1)) * $jPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($jH - 8)' text-anchor='middle' font-size='8' fill='#aaa'>+${i}d</text>")
    }

    $projRounded = [math]::Round($projAtDeadline, 1)
    $calloutText = if ($hitsTarget) { "ON TRACK: projected $($projRounded)% at deadline" } else { "AT RISK: projected only $($projRounded)% at deadline (velocity: $([math]::Round($vel3,1))%/day)" }
    $calloutColor = if ($hitsTarget) { $colors.Green } else { $colors.Red }
    # Place callout at top-right of chart to avoid overlap with projection labels
    [void]$sb.AppendLine("<text x='$($jW - $jPadR)' y='$($jPadT + 14)' text-anchor='end' font-size='10' font-weight='600' fill='$calloutColor'>$calloutText</text>")

    [void]$sb.AppendLine("<line x1='$($jPadL + 5)' y1='$($jPadT + 5)' x2='$($jPadL + 25)' y2='$($jPadT + 5)' stroke='#336699' stroke-width='2.5'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 29)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Actual</text>")
    [void]$sb.AppendLine("<line x1='$($jPadL + 75)' y1='$($jPadT + 5)' x2='$($jPadL + 95)' y2='$($jPadT + 5)' stroke='$projFillColor' stroke-width='2' stroke-dasharray='6,4'/>")
    [void]$sb.AppendLine("<text x='$($jPadL + 99)' y='$($jPadT + 9)' font-size='9' fill='#1c2b3a'>Projection</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== Build-Sparkline helper (used by multiple styles) =====
function Build-Sparkline {
    param([double[]]$Values, [string]$Color = '#1f3a5f', [int]$Width = 140, [int]$Height = 28)
    if ($Values.Count -eq 0) { return "<svg width='$Width' height='$Height'></svg>" }
    $max = ($Values | Measure-Object -Maximum).Maximum
    if ($max -eq 0) { $max = 1 }
    $barW = [int][math]::Floor(($Width - ($Values.Count - 1) * 2) / [math]::Max(1, $Values.Count))
    $svgParts = "<svg width='$Width' height='$Height' style='vertical-align:middle;'>"
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $h = [math]::Max(2, [int][math]::Round($Values[$i] / $max * ($Height - 2)))
        $x = $i * ($barW + 2)
        $y = $Height - $h
        $opacity = [math]::Round(0.3 + (0.7 * $i / [math]::Max(1, $Values.Count - 1)), 2)
        $svgParts += "<rect x='$x' y='$y' width='$barW' height='$h' fill='$Color' opacity='$opacity'/>"
    }
    $svgParts += "</svg>"
    return $svgParts
}

# ===== Build-MetricBarChart helper (individual vertical bar chart with value labels) =====
function Build-MetricBarChart {
    param([string]$Title, [double[]]$Values, [string[]]$Labels, [string]$Color, [string]$Unit = '',
          [int]$ChartW = 600, [int]$ChartH = 160, [bool]$HighIsGood = $true)
    $leftPad = 45; $topPad = 10; $bottomPad = 40
    $drawH = $ChartH - $topPad - $bottomPad
    $cnt = $Values.Count
    if ($cnt -eq 0) { return '' }
    $barW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.65)
    $gapW = [int][math]::Floor(($ChartW - $leftPad - 10) / $cnt * 0.35)
    $maxVal = [math]::Max(1, ($Values | Measure-Object -Maximum).Maximum)

    # Delta for header
    $first = $Values[0]; $last = $Values[$cnt - 1]; $delta = [math]::Round($last - $first, 1)
    $dSign = if ($delta -gt 0) { '+' } else { '' }
    $dColor = if ($HighIsGood) { if ($delta -gt 0) { '#0a7d2c' } elseif ($delta -lt 0) { '#b00020' } else { '#9a6700' } } else { if ($delta -gt 0) { '#b00020' } elseif ($delta -lt 0) { '#0a7d2c' } else { '#9a6700' } }

    $svgH = $ChartH + 10
    $svg = "<div style='margin:8px 0;'>"
    $svg += "<div style='font-size:13px;font-weight:600;color:#1f3a5f;margin-bottom:4px;'>$Title <span style='font-size:12px;color:$dColor;margin-left:8px;'>${dSign}${delta}${Unit} vs first capture</span></div>"
    $svg += "<svg width='$ChartW' height='$svgH' style='font-family:Segoe UI,Arial,sans-serif;'>"

    # Y-axis gridlines (4 lines)
    for ($g = 0; $g -le 4; $g++) {
        $gVal = [math]::Round($maxVal * $g / 4, 0)
        $gy = $topPad + $drawH - [int]($drawH * $g / 4)
        $svg += "<line x1='$leftPad' y1='$gy' x2='$ChartW' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>"
        $svg += "<text x='$($leftPad - 4)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>${gVal}${Unit}</text>"
    }

    # Bars with value labels
    for ($i = 0; $i -lt $cnt; $i++) {
        $v = $Values[$i]
        $bH = [int][math]::Max(2, [math]::Round($v / $maxVal * $drawH))
        $bX = $leftPad + $i * ($barW + $gapW) + [int]($gapW / 2)
        $bY = $topPad + $drawH - $bH
        $opacity = [math]::Round(0.4 + (0.6 * $i / [math]::Max(1, $cnt - 1)), 2)
        $svg += "<rect x='$bX' y='$bY' width='$barW' height='$bH' fill='$Color' opacity='$opacity' rx='2'/>"
        # Value label on top of bar
        $svg += "<text x='$($bX + [int]($barW/2))' y='$($bY - 3)' text-anchor='middle' font-size='10' font-weight='600' fill='$Color'>$([math]::Round($v,0))${Unit}</text>"
        # Date label below
        $labelY = $topPad + $drawH + 14
        $svg += "<text x='$($bX + [int]($barW/2))' y='$labelY' text-anchor='middle' font-size='9' fill='#566'>$($Labels[$i])</text>"
    }

    $svg += "</svg></div>"
    return $svg
}

# ===== STYLE C: Metric Trend Bar Charts (individual per metric) =====
[void]$sb.AppendLine("<div class='section'>")

[void]$sb.AppendLine("<div class='section-title'>Metric Trends -- Day-by-Day Detail</div>")
[void]$sb.AppendLine("<p class='note'>Individual bar charts for key metrics showing the exact value per capture day. Each bar represents one business day of data.</p>")

$dayLabels = @($dailyData | ForEach-Object { $_.DayLabel })

$metricCharts = @(
    @{ Title = 'Overall Completion'; Values = @($dailyData | ForEach-Object { $_.CompletionPct }); Color = '#336699'; Unit = '%'; HighIsGood = $true }
    @{ Title = 'Approved Items';     Values = @($dailyData | ForEach-Object { $_.Approved });      Color = $colors.Green; Unit = ''; HighIsGood = $true }
    @{ Title = 'Revoked Items';      Values = @($dailyData | ForEach-Object { $_.Revoked });       Color = $colors.Red; Unit = ''; HighIsGood = $false }
    @{ Title = 'Pending Items';      Values = @($dailyData | ForEach-Object { $_.Pending });       Color = $colors.Amber; Unit = ''; HighIsGood = $false }
)

foreach ($mc in $metricCharts) {
    $chart = Build-MetricBarChart -Title $mc.Title -Values $mc.Values -Labels $dayLabels -Color $mc.Color -Unit $mc.Unit -HighIsGood $mc.HighIsGood
    [void]$sb.AppendLine($chart)
}

[void]$sb.AppendLine("</div>")

# ===== STYLE D: Table with Delta Arrows =====
if ($dayCount -ge 2 -and $reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Per-Reviewer Accountability -- Numeric Comparison with Direction</div>")
    [void]$sb.AppendLine("<p class='note'>Shows each reviewer's completion today vs first capture, with direction arrows. Stalled reviewers (zero change) are highlighted.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th>Reviewer</th><th style='text-align:right;'>First</th><th style='text-align:right;'>Yesterday</th><th style='text-align:right;'>Today</th><th style='text-align:center;'>Direction</th><th style='text-align:right;'>Change</th><th>Status</th><th style='font-size:10px;'>In Scope Since</th></tr></thead><tbody>")
    $rvIdx = 0
    foreach ($rv in $reviewers) {
        $todayRv = $dailyData[$dayCount - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
        $yestRv  = $dailyData[$dayCount - 2].Reviewers | Where-Object { $_.Name -eq $rv.Name }

        # Use first-seen data for the "First" column (not day 0 if they weren't in scope)
        $firstRv = if ($rv.FirstSeenIdx -ge 0) { $dailyData[$rv.FirstSeenIdx].Reviewers | Where-Object { $_.Name -eq $rv.Name } } else { $null }

        [double]$todayPct = if ($todayRv) { [double]$todayRv.Completion } else { 0 }
        [double]$yestPct  = if ($yestRv) { [double]$yestRv.Completion } else { 0 }
        [double]$firstPct = if ($firstRv) { [double]$firstRv.Completion } else { 0 }
        $todayPct = [math]::Max(0, [math]::Min(100, $todayPct))
        $yestPct  = [math]::Max(0, [math]::Min(100, $yestPct))
        $firstPct = [math]::Max(0, [math]::Min(100, $firstPct))

        [double]$delta7 = [math]::Round($todayPct - $firstPct, 1)
        $arrow = if ($delta7 -gt 2) { "<span class='up-arrow'></span>" } elseif ($delta7 -lt -2) { "<span class='down-arrow'></span>" } else { "<span class='flat-line'></span>" }
        $dClass = if ($delta7 -gt 2) { 'delta-up' } elseif ($delta7 -lt -2) { 'delta-down' } else { 'delta-flat' }
        $dSign = if ($delta7 -gt 0) { '+' } else { '' }

        $status = if ($todayPct -ge 100) { "<span style='color:$($colors.Green);font-weight:600;'>Complete</span>" }
                  elseif ($delta7 -lt 1 -and $todayPct -lt 95) { "<span style='color:$($colors.Red);font-weight:600;'>STALLED</span>" }
                  elseif ($delta7 -lt 5) { "<span style='color:$($colors.Amber);'>Slow</span>" }
                  else { "<span style='color:$($colors.Green);'>On Track</span>" }

        # "In Scope Since" column -- shows when reviewer first appeared
        $scopeSince = if ($rv.FirstSeenIdx -eq 0) { 'Day 1' } elseif ($rv.FirstSeenIdx -gt 0) { $rv.FirstSeenDate } else { 'N/A' }
        $scopeStyle = if ($rv.FirstSeenIdx -gt 0) { "color:$($colors.Amber);font-weight:600;" } else { 'color:#888;' }

        $bg = if ($delta7 -lt 1 -and $todayPct -lt 95) { " style='background:#fdecec;'" } elseif ($rvIdx % 2 -eq 1) { " style='background:#f6f9fc;'" } else { '' }
        $rvName = ConvertTo-SPHtmlSafe $rv.Name
        [void]$sb.AppendLine("<tr$bg><td style='font-weight:600;'>$rvName</td><td style='text-align:right;color:#888;'>${firstPct}%</td><td style='text-align:right;'>${yestPct}%</td><td style='text-align:right;font-weight:600;'>${todayPct}%</td><td style='text-align:center;'>$arrow</td><td style='text-align:right;' class='$dClass'>${dSign}${delta7}%</td><td>$status</td><td style='font-size:10px;$scopeStyle'>$scopeSince</td></tr>")
        $rvIdx++
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

# ===== STYLE B: Stacked Progress Bars (CSS) =====
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Decision Distribution -- Day-by-Day Stacked Bars</div>")
    [void]$sb.AppendLine("<p class='note'>Green=Approved, Red=Revoked, Gray=Pending. The width of each segment shows the proportion of total items.</p>")

    [void]$sb.AppendLine("<table><thead><tr><th style='width:100px;'>Day</th><th>Decision Distribution</th><th style='width:70px;text-align:right;'>Completion</th></tr></thead><tbody>")
    foreach ($d in $dailyData) {
        $aPct = [math]::Round($d.Approved / [math]::Max(1, $d.Total) * 100, 0)
        $rPct = [math]::Round($d.Revoked / [math]::Max(1, $d.Total) * 100, 0)
        $pPct = 100 - $aPct - $rPct
        if ($pPct -lt 0) { $pPct = 0 }
        [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$($d.DayLabel)</td>")
        [void]$sb.AppendLine("<td><div class='stacked-bar'>")
        if ($aPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${aPct}%;background:$($colors.Green);'>$(if($aPct -ge 8){"${aPct}%"})</div>") }
        if ($rPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${rPct}%;background:$($colors.Red);'>$(if($rPct -ge 8){"${rPct}%"})</div>") }
        if ($pPct -gt 0) { [void]$sb.AppendLine("<div class='stacked-seg' style='width:${pPct}%;background:#ccc;color:#555;'>$(if($pPct -ge 8){"${pPct}%"})</div>") }
        [void]$sb.AppendLine("</div></td>")
        [void]$sb.AppendLine("<td style='text-align:right;font-weight:600;'>$($d.CompletionPct)%</td></tr>")
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

# ===== STYLE E: Privileged Access Trend =====
[void]$sb.AppendLine("<div class='section'>")

[void]$sb.AppendLine("<div class='section-title'>Privileged Access -- Pending Review Trend</div>")

$todayPrivPending = [int]$today.PrivPending
$todayPrivTotal   = [int]$today.PrivTotal
$privReviewedPct  = if ($todayPrivTotal -gt 0) { [math]::Round(($todayPrivTotal - $todayPrivPending) / $todayPrivTotal * 100, 1) } else { 0 }
$privStatusColor  = if ($todayPrivPending -eq 0) { $colors.Green } elseif ($todayPrivPending -le 3) { $colors.Amber } else { $colors.Red }

[void]$sb.AppendLine("<p class='note'>Tracks privileged entitlements still awaiting review. These items carry higher risk and should be prioritized.</p>")

# KPI row for privileged
[void]$sb.AppendLine("<div style='margin:8px 0 16px 0;'>")
$kpiS = "display:inline-block;min-width:120px;margin:4px 8px 4px 0;padding:8px 12px;border:1px solid $($colors.Border);border-radius:6px;background:$($colors.LightGrayBg);text-align:center;"
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$privStatusColor;display:block;'>$todayPrivPending</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Pending</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Dark);display:block;'>$todayPrivTotal</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Total</span></span>")
[void]$sb.AppendLine("<span style='$kpiS'><span style='font-size:20px;font-weight:700;color:$($colors.Dark);display:block;'>${privReviewedPct}%</span><span style='font-size:10px;color:#566;text-transform:uppercase;'>Priv Reviewed</span></span>")
[void]$sb.AppendLine("</div>")

# Bar chart of privileged pending over time
$privPendingValues = @($dailyData | ForEach-Object { [double]$_.PrivPending })
$privChart = Build-MetricBarChart -Title 'Privileged Items Pending Review' -Values $privPendingValues -Labels $dayLabels -Color '#7b2d8e' -HighIsGood $false
[void]$sb.AppendLine($privChart)

[void]$sb.AppendLine("</div>")


# ===== STYLE G: Rubber-Stamp Risk Detector =====
if ($reviewers.Count -gt 0 -and $today.Reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Rubber-Stamp Risk Detector -- Approval Ratio Analysis</div>")
    [void]$sb.AppendLine("<p class='note'>Horizontal lollipop chart per reviewer. Dot position = approval ratio (Approved / Decided * 100). Circle size = items decided. Dashed threshold at 95%.</p>")

    $todayReviewers = $today.Reviewers
    $gW = 700; $gH = 30 + ($todayReviewers.Count * 40); $gPadL = 120; $gPadR = 120; $gPlotW = $gW - $gPadL - $gPadR

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$gW' height='$gH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    [void]$sb.AppendLine("<text x='$($gPadL + $gPlotW / 2)' y='14' text-anchor='middle' font-size='10' fill='#888'>Approval Ratio (%)</text>")

    $scaleVals = @(0, 25, 50, 75, 95, 100)
    foreach ($sv in $scaleVals) {
        $sx = [int]($gPadL + ($sv / 100 * $gPlotW))
        [void]$sb.AppendLine("<line x1='$sx' y1='20' x2='$sx' y2='$($gH - 5)' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$sx' y='28' text-anchor='middle' font-size='8' fill='#aaa'>${sv}%</text>")
    }

    $thresh95x = [int]($gPadL + (95 / 100 * $gPlotW))
    [void]$sb.AppendLine("<line x1='$thresh95x' y1='20' x2='$thresh95x' y2='$($gH - 5)' stroke='$($colors.Red)' stroke-width='1.5' stroke-dasharray='5,3'/>")
    [void]$sb.AppendLine("<text x='$($thresh95x + 3)' y='28' font-size='8' fill='$($colors.Red)'>95% threshold</text>")

    $ri = 0
    foreach ($rv in $todayReviewers) {
        [int]$decided = [int]$rv.Approved + [int]$rv.Revoked
        $approvalRatio = if ($decided -gt 0) { [math]::Round([int]$rv.Approved / $decided * 100, 1) } else { 0 }
        $yPos = 38 + ($ri * 40)
        $rvName = ConvertTo-SPHtmlSafe $rv.Name

        [void]$sb.AppendLine("<text x='$($gPadL - 8)' y='$($yPos + 5)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

        $dotX = [int]($gPadL + ($approvalRatio / 100 * $gPlotW))
        [void]$sb.AppendLine("<line x1='$gPadL' y1='$yPos' x2='$dotX' y2='$yPos' stroke='#ccc' stroke-width='2'/>")

        $dotR = [math]::Max(6, [math]::Min(16, [int]($decided / 2)))
        $dotColor = if ($approvalRatio -ge 100) { $colors.Red } elseif ($approvalRatio -ge 95) { $colors.Amber } else { $colors.Green }
        [void]$sb.AppendLine("<circle cx='$dotX' cy='$yPos' r='$dotR' fill='$dotColor' opacity='0.85'/>")
        [void]$sb.AppendLine("<text x='$dotX' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>$decided</text>")

        $badgeX = $gW - $gPadR + 10
        if ($decided -eq 0) {
            [void]$sb.AppendLine("<text x='$badgeX' y='$($yPos + 4)' font-size='9' fill='#888'>NO DECISIONS</text>")
        } elseif ($approvalRatio -ge 100) {
            [void]$sb.AppendLine("<rect x='$badgeX' y='$($yPos - 8)' width='90' height='16' rx='8' fill='$($colors.Red)'/>")
            [void]$sb.AppendLine("<text x='$($badgeX + 45)' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>RUBBER STAMP</text>")
        } elseif ($approvalRatio -ge 95) {
            [void]$sb.AppendLine("<rect x='$badgeX' y='$($yPos - 8)' width='62' height='16' rx='8' fill='$($colors.Amber)'/>")
            [void]$sb.AppendLine("<text x='$($badgeX + 31)' y='$($yPos + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#fff'>WARNING</text>")
        } else {
            [void]$sb.AppendLine("<text x='$badgeX' y='$($yPos + 4)' font-size='9' fill='$($colors.Green)'>$($approvalRatio)%</text>")
        }
        $ri++
    }

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE H: Reviewer Activity Heatmap =====
if ($dayCount -ge 2 -and $reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Reviewer Activity Heatmap -- ${dayCount}-Day Decision Intensity</div>")
    [void]$sb.AppendLine("<p class='note'>Rows = reviewers, Columns = days. Cell color intensity = decisions made that day (daily delta). Five-level blue scale. Inactive reviewers highlighted in light red.</p>")

    $hCellW = [math]::Min(70, [int](560 / [math]::Max(1, $dayCount)))
    $hCellH = 32; $hLabelW = 120
    $hTotalW = $hLabelW + ($dayCount * $hCellW) + 10
    $hTotalH = 30 + ($reviewers.Count * $hCellH) + 5
    $heatColors = @('#f0f2f5', '#c6dbef', '#6baed6', '#2171b5', '#084594')

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;overflow-x:auto;'>")
    [void]$sb.AppendLine("<svg width='$hTotalW' height='$hTotalH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $hx = $hLabelW + ($i * $hCellW) + ($hCellW / 2)
        [void]$sb.AppendLine("<text x='$hx' y='16' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }

    $rvIdx = 0
    foreach ($rv in $reviewers) {
        $hy = 24 + ($rvIdx * $hCellH)
        $rvName = ConvertTo-SPHtmlSafe $rv.Name
        $totalActivity = 0

        $deltas = @()
        for ($i = 0; $i -lt $dayCount; $i++) {
            $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $todayDec = if ($rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            if ($i -gt 0) {
                $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
                $prevDec = if ($rvPrev) { [int]$rvPrev.Approved + [int]$rvPrev.Revoked } else { 0 }
                $delta = [math]::Max(0, $todayDec - $prevDec)
            } else {
                $delta = $todayDec
            }
            $deltas += $delta
            $totalActivity += $delta
        }

        if ($totalActivity -eq 0) {
            [void]$sb.AppendLine("<rect x='0' y='$hy' width='$hTotalW' height='$hCellH' fill='#fdecec' opacity='0.5'/>")
        }

        [void]$sb.AppendLine("<text x='$($hLabelW - 8)' y='$($hy + $hCellH / 2 + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

        $maxDelta = ($deltas | Measure-Object -Maximum).Maximum
        if ($maxDelta -eq 0) { $maxDelta = 1 }
        for ($i = 0; $i -lt $deltas.Count; $i++) {
            $hcx = $hLabelW + ($i * $hCellW)
            $val = $deltas[$i]
            $level = [math]::Min(4, [int][math]::Floor($val / $maxDelta * 4.99))
            if ($val -eq 0) { $level = 0 }
            $cellColor = $heatColors[$level]
            [void]$sb.AppendLine("<rect x='$($hcx + 2)' y='$($hy + 2)' width='$($hCellW - 4)' height='$($hCellH - 4)' rx='3' fill='$cellColor' stroke='#e3e9f0' stroke-width='1'/>")
            if ($val -gt 0) {
                $textColor = if ($level -ge 3) { '#fff' } else { '#1c2b3a' }
                [void]$sb.AppendLine("<text x='$($hcx + $hCellW / 2)' y='$($hy + $hCellH / 2 + 4)' text-anchor='middle' font-size='10' font-weight='600' fill='$textColor'>$val</text>")
            }
        }
        $rvIdx++
    }

    $legY = $hTotalH - 2
    [void]$sb.AppendLine("<text x='$hLabelW' y='$($legY)' font-size='9' fill='#888'>Intensity:</text>")
    for ($lv = 0; $lv -lt 5; $lv++) {
        $lx = $hLabelW + 55 + ($lv * 22)
        [void]$sb.AppendLine("<rect x='$lx' y='$($legY - 10)' width='18' height='12' rx='2' fill='$($heatColors[$lv])' stroke='#d4dce6' stroke-width='0.5'/>")
    }

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE N: Cross-Campaign Risk Matrix =====
if ($allCampaignLatest.Count -gt 0) {
    $campaigns = @()
    foreach ($rec in $allCampaignLatest) {
        $m = $rec.metrics
        $cn     = [string]$rec.campaignName
        $total  = [int](Get-V5MetricVal $m 'counts.total' 0)
        $appr   = [int](Get-V5MetricVal $m 'counts.approved' 0)
        $rev    = [int](Get-V5MetricVal $m 'counts.revoked' 0)
        $pend   = [int](Get-V5MetricVal $m 'counts.pending' 0)
        $compPct = [double](Get-V5MetricVal $m 'completion.byDecisionPct' 0)
        $privPend = [int](Get-V5MetricVal $m 'counts.privPending' 0)
        $rvTotal = [int](Get-V5MetricVal $m 'counts.reviewersTotal' 0)
        $rvSigned = [int](Get-V5MetricVal $m 'counts.reviewersSigned' 0)

        # Compute deadline days from dueDate
        $dlDays = 999
        $dueDateStr = [string]$rec.dueDate
        if (-not [string]::IsNullOrWhiteSpace($dueDateStr)) {
            try {
                $dueDt = [datetime]::Parse($dueDateStr)
                $dlDays = [int][math]::Floor(($dueDt - (Get-Date)).TotalDays)
                if ($dlDays -lt 0) { $dlDays = 0 }
            } catch { }
        }

        # Count stalled reviewers from the reviewers array
        $stalledCount = 0
        $reviewerArr = $null
        try {
            if ($null -ne $rec.PSObject.Properties['reviewers'] -and $null -ne $rec.reviewers) {
                $reviewerArr = @($rec.reviewers)
            }
        } catch { }
        if ($null -ne $reviewerArr) {
            foreach ($rvr in $reviewerArr) {
                $rvComp = [double](Get-V5Prop $rvr 'completion' 0)
                if ($rvComp -lt 5) { $stalledCount++ }
            }
        }

        $campaigns += @{
            Name = $cn
            Completion = $compPct
            Deadline = $dlDays
            Pending = $pend
            PrivPending = $privPend
            StalledReviewers = $stalledCount
            TotalReviewers = $rvTotal
            Approved = $appr
            Revoked = $rev
            Total = $total
            RiskScore = 0
        }
    }

    # Compute risk scores
    foreach ($c in $campaigns) {
        $timeRisk = if ($c.Deadline -le 2) { 40 } elseif ($c.Deadline -le 5) { 25 } else { 10 }
        $completionRisk = [math]::Max(0, [int]((100 - $c.Completion) * 0.4))
        $privRisk = [math]::Min(25, [int]($c.PrivPending * 1.5))
        $stalledRisk = $c.StalledReviewers * 8
        $c.RiskScore = [math]::Min(100, $timeRisk + $completionRisk + $privRisk + $stalledRisk)
    }

    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Cross-Campaign Risk Matrix</div>")
    [void]$sb.AppendLine("<p class='note'>Multi-campaign view with composite risk scoring. Risk = f(deadline proximity, completion gap, privileged pending, stalled reviewers).</p>")

    [void]$sb.AppendLine("<table class='risk-matrix'><thead><tr>")
    [void]$sb.AppendLine("<th>Campaign</th><th style='text-align:center;'>Completion</th><th style='text-align:center;'>Progress</th><th style='text-align:center;'>Deadline</th><th style='text-align:center;'>Priv. Pending</th><th style='text-align:center;'>Stalled</th><th style='text-align:center;'>Risk Score</th>")
    [void]$sb.AppendLine("</tr></thead><tbody>")

    foreach ($c in $campaigns) {
        $cName = ConvertTo-SPHtmlSafe $c.Name

        $donutR = 14; $donutCx = 20; $donutCy = 20; $donutStroke = 6
        $circumference = [math]::Round(2 * [math]::PI * $donutR, 1)
        $dashLen = [math]::Round($circumference * $c.Completion / 100, 1)
        $gapLen = [math]::Round($circumference - $dashLen, 1)
        $donutColor = if ($c.Completion -ge 80) { $colors.Green } elseif ($c.Completion -ge 50) { $colors.Amber } else { $colors.Red }
        $donutSvg = "<svg width='40' height='40' style='vertical-align:middle;'>"
        $donutSvg += "<circle cx='$donutCx' cy='$donutCy' r='$donutR' fill='none' stroke='#e3e9f0' stroke-width='$donutStroke'/>"
        $donutSvg += "<circle cx='$donutCx' cy='$donutCy' r='$donutR' fill='none' stroke='$donutColor' stroke-width='$donutStroke' stroke-dasharray='$dashLen $gapLen' stroke-dashoffset='$([math]::Round($circumference * 0.25, 1))' stroke-linecap='round'/>"
        $donutSvg += "<text x='$donutCx' y='$($donutCy + 4)' text-anchor='middle' font-size='8' font-weight='700' fill='#1c2b3a'>$([math]::Round($c.Completion,0))%</text>"
        $donutSvg += "</svg>"

        $thermColor = if ($c.Completion -ge 80) { $colors.Green } elseif ($c.Completion -ge 50) { $colors.Amber } else { $colors.Red }
        $thermBar = "<span class='thermometer'><span class='thermometer-fill' style='width:$($c.Completion)%;background:$thermColor;display:inline-block;'></span></span>"

        $dlColor = if ($c.Deadline -le 2) { $colors.Red } elseif ($c.Deadline -le 5) { $colors.Amber } else { $colors.Green }
        $dlLabel = if ($c.Deadline -ge 999) { 'N/A' } else { "$($c.Deadline)d" }
        $dlSvg = "<svg width='16' height='16' style='vertical-align:middle;'><circle cx='8' cy='8' r='6' fill='$dlColor'/></svg>"
        $dlText = "$dlSvg <span style='font-weight:600;'>$dlLabel</span>"

        $riskColor = if ($c.RiskScore -ge 60) { $colors.Red } elseif ($c.RiskScore -ge 35) { $colors.Amber } else { $colors.Green }
        $riskW = $c.RiskScore
        $riskBar = "<div style='display:inline-block;width:100px;height:14px;background:#e3e9f0;border-radius:7px;overflow:hidden;vertical-align:middle;'>"
        $riskBar += "<div style='width:${riskW}%;height:14px;background:$riskColor;border-radius:7px;display:inline-block;'></div></div>"
        $riskBar += " <span style='font-size:11px;font-weight:600;color:$riskColor;'>$($c.RiskScore)</span>"

        $privColor = if ($c.PrivPending -gt 10) { $colors.Red } elseif ($c.PrivPending -gt 5) { $colors.Amber } else { '#1c2b3a' }
        $stalledColor = if ($c.StalledReviewers -gt 0) { $colors.Red } else { $colors.Green }

        [void]$sb.AppendLine("<tr>")
        [void]$sb.AppendLine("<td style='font-weight:600;'>$cName</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$donutSvg</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$thermBar</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$dlText</td>")
        [void]$sb.AppendLine("<td style='text-align:center;font-weight:600;color:$privColor;'>$($c.PrivPending)</td>")
        [void]$sb.AppendLine("<td style='text-align:center;font-weight:600;color:$stalledColor;'>$($c.StalledReviewers) / $($c.TotalReviewers)</td>")
        [void]$sb.AppendLine("<td style='text-align:center;'>$riskBar</td>")
        [void]$sb.AppendLine("</tr>")
    }

    [void]$sb.AppendLine("</tbody></table></div>")
}

# ===== STYLE A: Horizontal Bar Charts (SVG) -- Reviewer Completion =====
if ($dayCount -ge 2 -and $reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Reviewer Completion -- ${dayCount}-Day Progression (Horizontal Bar Charts)</div>")
    [void]$sb.AppendLine("<p class='note'>Each bar shows the reviewer's completion percentage. The rightmost bar is today; color indicates status (green=complete, blue=progressing, red=stalled).</p>")

    [void]$sb.AppendLine("<table><thead><tr><th style='width:120px;'>Reviewer</th>")
    foreach ($d in $dailyData) { [void]$sb.AppendLine("<th style='width:100px;text-align:center;font-size:10px;'>$($d.DayLabel)</th>") }
    [void]$sb.AppendLine("</tr></thead><tbody>")

    foreach ($rv in $reviewers) {
        [void]$sb.AppendLine("<tr><td style='font-weight:600;'>$(ConvertTo-SPHtmlSafe $rv.Name)</td>")
        for ($dIdx = 0; $dIdx -lt $dailyData.Count; $dIdx++) {
            $d = $dailyData[$dIdx]
            $rvDay = $d.Reviewers | Where-Object { $_.Name -eq $rv.Name }
            if ($null -eq $rvDay -and $dIdx -lt $rv.FirstSeenIdx) {
                # Reviewer was not yet in scope -- show gray N/A cell
                [void]$sb.AppendLine("<td><div class='bar-track' style='background:#e8e8e8;'><span class='bar-label' style='color:#aaa;font-style:italic;'>N/A</span></div></td>")
            }
            else {
                $pct = if ($rvDay) { [double]$rvDay.Completion } else { 0 }
                $pct = [math]::Max(0, [math]::Min(100, $pct))
                $barColor = if ($pct -ge 95) { $colors.Green } elseif ($rv.Style -eq 'stalled') { $colors.Red } else { '#336699' }
                [void]$sb.AppendLine("<td><div class='bar-track'><div class='bar-fill' style='width:${pct}%;background:$barColor;'></div><span class='bar-label'>${pct}%</span></div></td>")
            }
        }
        [void]$sb.AppendLine("</tr>")
    }
    [void]$sb.AppendLine("</tbody></table></div>")
}

# ===== STYLE M: Reviewer Engagement Timeline =====
if ($dayCount -ge 2 -and $reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Reviewer Engagement Timeline -- Gantt-Style Activity Map</div>")
    [void]$sb.AppendLine("<p class='note'>Per reviewer: gray baseline = ${dayCount}-day window. Blue bar = first-to-last active day. Markers: circle=first decision, diamond=50% completion, star=100% completion.</p>")

    $mW = 700; $mRowH = 40; $mPadL = 140; $mPadR = 100
    $mH = 40 + ($reviewers.Count * $mRowH)
    $mPlotW = $mW - $mPadL - $mPadR

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$mW' height='$mH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $dx = [int]($mPadL + ($i / [math]::Max(1, $dayCount - 1)) * $mPlotW)
        [void]$sb.AppendLine("<line x1='$dx' y1='20' x2='$dx' y2='$($mH - 5)' stroke='#f0f2f5' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$dx' y='14' text-anchor='middle' font-size='9' fill='#888'>$($dailyData[$i].DayLabel)</text>")
    }

    $ri = 0
    foreach ($rv in $reviewers) {
        $yCenter = 35 + ($ri * $mRowH)
        $rvName = ConvertTo-SPHtmlSafe $rv.Name

        $firstActive = -1; $lastActive = -1; $halfDay = -1; $doneDay = -1
        for ($i = 0; $i -lt $dayCount; $i++) {
            $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $dayDec = if ($rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            $dayCompletion = if ($rvDay) { [double]$rvDay.Completion } else { 0 }
            if ($i -gt 0) {
                $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
                $prevDec = if ($rvPrev) { [int]$rvPrev.Approved + [int]$rvPrev.Revoked } else { 0 }
                $delta = $dayDec - $prevDec
            } else {
                $delta = $dayDec
            }
            if ($delta -gt 0) {
                if ($firstActive -eq -1) { $firstActive = $i }
                $lastActive = $i
            }
            if ($dayCompletion -ge 50 -and $halfDay -eq -1) { $halfDay = $i }
            if ($dayCompletion -ge 100 -and $doneDay -eq -1) { $doneDay = $i }
        }

        [void]$sb.AppendLine("<text x='$($mPadL - 8)' y='$($yCenter + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

        $lineX1 = $mPadL; $lineX2 = $mPadL + $mPlotW
        [void]$sb.AppendLine("<line x1='$lineX1' y1='$yCenter' x2='$lineX2' y2='$yCenter' stroke='#e3e9f0' stroke-width='6' stroke-linecap='round'/>")

        if ($firstActive -ge 0 -and $lastActive -ge 0) {
            $actX1 = [int]($mPadL + ($firstActive / [math]::Max(1, $dayCount - 1)) * $mPlotW)
            $actX2 = [int]($mPadL + ($lastActive / [math]::Max(1, $dayCount - 1)) * $mPlotW)
            # Ensure minimum bar width when firstActive == lastActive
            if ($actX2 -le $actX1) { $actX2 = $actX1 + 6 }
            [void]$sb.AppendLine("<line x1='$actX1' y1='$yCenter' x2='$actX2' y2='$yCenter' stroke='#336699' stroke-width='8' stroke-linecap='round'/>")
            [void]$sb.AppendLine("<circle cx='$actX1' cy='$yCenter' r='6' fill='#336699' stroke='#fff' stroke-width='1.5'/>")
        }

        if ($halfDay -ge 0) {
            $hx = [int]($mPadL + ($halfDay / [math]::Max(1, $dayCount - 1)) * $mPlotW)
            [void]$sb.AppendLine("<polygon points='$hx,$($yCenter - 7) $($hx + 6),$yCenter $hx,$($yCenter + 7) $($hx - 6),$yCenter' fill='$($colors.Amber)' stroke='#fff' stroke-width='1'/>")
        }

        if ($doneDay -ge 0) {
            $stx = [int]($mPadL + ($doneDay / [math]::Max(1, $dayCount - 1)) * $mPlotW)
            $sr = 7; $sir = 3
            $starPts = ''
            for ($s = 0; $s -lt 5; $s++) {
                $outerAngle = [math]::PI / 2 + ($s * 2 * [math]::PI / 5)
                $innerAngle = $outerAngle + [math]::PI / 5
                $ox = [math]::Round($stx + $sr * [math]::Cos($outerAngle), 1)
                $oy = [math]::Round($yCenter - $sr * [math]::Sin($outerAngle), 1)
                $ix = [math]::Round($stx + $sir * [math]::Cos($innerAngle), 1)
                $iy = [math]::Round($yCenter - $sir * [math]::Sin($innerAngle), 1)
                $starPts += "$ox,$oy $ix,$iy "
            }
            [void]$sb.AppendLine("<polygon points='$($starPts.Trim())' fill='$($colors.Green)' stroke='#fff' stroke-width='1'/>")
        }

        # Get last known completion for this reviewer
        $lastCompletion = 0
        for ($ci = $dayCount - 1; $ci -ge 0; $ci--) {
            $rvCheck = $dailyData[$ci].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            if ($rvCheck) { $lastCompletion = $rvCheck.Completion; break }
        }
        # Don't flag as stalled if completion >= 90%
        $statusText = if ($firstActive -eq -1) { '(not started)' }
                      elseif ($lastCompletion -ge 90) { '(finishing)' }
                      elseif ($lastActive -lt ($dayCount - 3) -and $doneDay -eq -1) { '(stalled)' }
                      else { '(steady)' }
        $statusColor = if ($statusText -eq '(not started)') { $colors.Red }
                       elseif ($statusText -eq '(stalled)') { $colors.Amber }
                       elseif ($statusText -eq '(finishing)') { $colors.Green }
                       else { '#888' }
        [void]$sb.AppendLine("<text x='$($mW - $mPadR + 10)' y='$($yCenter + 4)' font-size='9' fill='$statusColor'>$statusText</text>")

        $ri++
    }

    $legY = $mH - 5
    [void]$sb.AppendLine("<circle cx='$($mPadL + 5)' cy='$($legY - 4)' r='4' fill='#336699'/>")
    [void]$sb.AppendLine("<text x='$($mPadL + 14)' y='$legY' font-size='9' fill='#1c2b3a'>First Decision</text>")
    [void]$sb.AppendLine("<polygon points='$($mPadL + 100),$($legY - 8) $($mPadL + 105),$($legY - 4) $($mPadL + 100),$legY $($mPadL + 95),$($legY - 4)' fill='$($colors.Amber)'/>")
    [void]$sb.AppendLine("<text x='$($mPadL + 112)' y='$legY' font-size='9' fill='#1c2b3a'>50% Complete</text>")
    $ssx = $mPadL + 200; $ssy = $legY - 4
    $starLegPts = ''
    for ($s = 0; $s -lt 5; $s++) {
        $outerAngle = [math]::PI / 2 + ($s * 2 * [math]::PI / 5)
        $innerAngle = $outerAngle + [math]::PI / 5
        $ox = [math]::Round($ssx + 5 * [math]::Cos($outerAngle), 1)
        $oy = [math]::Round($ssy - 5 * [math]::Sin($outerAngle), 1)
        $ix = [math]::Round($ssx + 2 * [math]::Cos($innerAngle), 1)
        $iy = [math]::Round($ssy - 2 * [math]::Sin($innerAngle), 1)
        $starLegPts += "$ox,$oy $ix,$iy "
    }
    [void]$sb.AppendLine("<polygon points='$($starLegPts.Trim())' fill='$($colors.Green)'/>")
    [void]$sb.AppendLine("<text x='$($mPadL + 210)' y='$legY' font-size='9' fill='#1c2b3a'>100% Complete</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE K: Decision Velocity Leaderboard =====
if ($dayCount -ge 2 -and $reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Decision Velocity Leaderboard</div>")
    [void]$sb.AppendLine("<p class='note'>Horizontal bar per reviewer: average items decided per active day. Bars segmented green=approved, red=revoked. Rank badges for top 3. Dashed line = team average.</p>")

    $rvVelocities = @()
    foreach ($rv in $reviewers) {
        $totalDecisions = 0; $totalAppr = 0; $totalRevk = 0; $activeDays = 0
        for ($i = 0; $i -lt $dayCount; $i++) {
            $rvDay = $dailyData[$i].Reviewers | Where-Object { $_.Name -eq $rv.Name }
            $dayDec = if ($rvDay) { [int]$rvDay.Approved + [int]$rvDay.Revoked } else { 0 }
            if ($i -gt 0) {
                $rvPrev = $dailyData[$i - 1].Reviewers | Where-Object { $_.Name -eq $rv.Name }
                $prevDec = if ($rvPrev) { [int]$rvPrev.Approved + [int]$rvPrev.Revoked } else { 0 }
                $delta = [math]::Max(0, $dayDec - $prevDec)
            } else {
                $delta = $dayDec
            }
            if ($delta -gt 0) { $activeDays++ }
            $totalDecisions += $delta
        }

        # Compute approval ratio from cumulative data across ALL days
        $totalAppr = 0; $totalRevk = 0
        foreach ($day in $dailyData) {
            $rvDay2 = $day.Reviewers | Where-Object { $_.Name -eq $rv.Name }
            if ($rvDay2) { $totalAppr += $rvDay2.Approved; $totalRevk += $rvDay2.Revoked }
        }
        # Use cumulative ratio to split the velocity decisions
        $totalDec2 = $totalAppr + $totalRevk
        $apprRatio = if ($totalDec2 -gt 0) { $totalAppr / $totalDec2 } else { 0.8 }
        $totalAppr = [int]($totalDecisions * $apprRatio)
        $totalRevk = $totalDecisions - $totalAppr

        $velocity = if ($activeDays -gt 0) { [math]::Round($totalDecisions / $activeDays, 1) } else { 0 }
        $rvVelocities += @{
            Name = $rv.Name
            TotalDecisions = $totalDecisions
            ApprovedTotal = $totalAppr
            RevokedTotal = $totalRevk
            ActiveDays = $activeDays
            Velocity = $velocity
        }
    }

    $rvVelocities = @($rvVelocities | Sort-Object { -$_.Velocity })
    $maxVel = [math]::Max(1, ($rvVelocities | Measure-Object -Property Velocity -Maximum).Maximum)
    $teamAvg = [math]::Round(($rvVelocities | Measure-Object -Property Velocity -Average).Average, 1)

    $kW = 700; $kBarH = 32; $kH = 40 + ($rvVelocities.Count * ($kBarH + 12)); $kPadL = 140; $kPadR = 80
    $kPlotW = $kW - $kPadL - $kPadR

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$kW' height='$kH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    $avgX = [int]($kPadL + ($teamAvg / $maxVel * $kPlotW))
    [void]$sb.AppendLine("<line x1='$avgX' y1='10' x2='$avgX' y2='$($kH - 10)' stroke='#336699' stroke-width='1.5' stroke-dasharray='5,3'/>")
    [void]$sb.AppendLine("<text x='$($avgX + 3)' y='18' font-size='8' fill='#336699'>Avg: $teamAvg/day</text>")

    $rankColors = @('#c5960c', '#888888', '#8b5e3c')
    $rankLabels = @('#1', '#2', '#3')

    $ki = 0
    foreach ($rvv in $rvVelocities) {
        $yPos = 30 + ($ki * ($kBarH + 12))
        $rvName = ConvertTo-SPHtmlSafe $rvv.Name

        if ($ki -lt 3 -and $rvv.Velocity -gt 0) {
            [void]$sb.AppendLine("<circle cx='15' cy='$($yPos + $kBarH / 2)' r='12' fill='$($rankColors[$ki])'/>")
            [void]$sb.AppendLine("<text x='15' y='$($yPos + $kBarH / 2 + 4)' text-anchor='middle' font-size='9' font-weight='700' fill='#fff'>$($rankLabels[$ki])</text>")
        }

        [void]$sb.AppendLine("<text x='$($kPadL - 8)' y='$($yPos + $kBarH / 2 + 4)' text-anchor='end' font-size='11' font-weight='600' fill='#1c2b3a'>$rvName</text>")

        if ($rvv.Velocity -eq 0) {
            [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$kPlotW' height='$kBarH' fill='#f0f2f5' rx='4'/>")
            [void]$sb.AppendLine("<text x='$($kPadL + 10)' y='$($yPos + $kBarH / 2 + 4)' font-size='10' font-weight='600' fill='$($colors.Red)'>NOT STARTED</text>")
        } else {
            $totalW = [int]($rvv.Velocity / $maxVel * $kPlotW)
            $apprW = [int]($rvv.ApprovedTotal / [math]::Max(1, $rvv.TotalDecisions) * $totalW)
            $revkW = $totalW - $apprW

            [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$kPlotW' height='$kBarH' fill='#f0f2f5' rx='4'/>")
            [void]$sb.AppendLine("<rect x='$kPadL' y='$yPos' width='$apprW' height='$kBarH' fill='$($colors.Green)' rx='4'/>")
            if ($revkW -gt 0) {
                [void]$sb.AppendLine("<rect x='$($kPadL + $apprW)' y='$yPos' width='$revkW' height='$kBarH' fill='$($colors.Red)' rx='0'/>")
            }
            [void]$sb.AppendLine("<text x='$($kPadL + $totalW + 6)' y='$($yPos + $kBarH / 2 + 4)' font-size='10' font-weight='600' fill='#1c2b3a'>$($rvv.Velocity)/day</text>")
        }
        $ki++
    }

    $legY = $kH - 5
    [void]$sb.AppendLine("<rect x='$kPadL' y='$($legY - 10)' width='12' height='12' rx='2' fill='$($colors.Green)'/>")
    [void]$sb.AppendLine("<text x='$($kPadL + 16)' y='$legY' font-size='9' fill='#1c2b3a'>Approved</text>")
    [void]$sb.AppendLine("<rect x='$($kPadL + 80)' y='$($legY - 10)' width='12' height='12' rx='2' fill='$($colors.Red)'/>")
    [void]$sb.AppendLine("<text x='$($kPadL + 96)' y='$legY' font-size='9' fill='#1c2b3a'>Revoked</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE B2: Vertical Bar Chart -- Items Reviewed % + Reviewer Completion % =====
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Completion Progression -- Vertical Bar Chart (Items Reviewed % + Reviewer Completion %)</div>")
    [void]$sb.AppendLine("<p class='note'>Blue bars show the percentage of items reviewed (decided). Green bars show the percentage of reviewers who have fully completed. Height is proportional to 100%.</p>")

    $chartWidth = 700
    $chartHeight = 200
    $groupWidth = [int][math]::Floor(($chartWidth - 40) / $dayCount)
    $barWidth = [int][math]::Floor($groupWidth * 0.35)
    $gap = [int][math]::Floor($groupWidth * 0.08)
    $leftPad = 40

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$chartWidth' height='$($chartHeight + 60)' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($pct = 0; $pct -le 100; $pct += 25) {
        $y = [int]($chartHeight - ($pct / 100 * $chartHeight) + 10)
        [void]$sb.AppendLine("<line x1='$leftPad' y1='$y' x2='$chartWidth' y2='$y' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($leftPad - 5)' y='$($y + 4)' text-anchor='end' font-size='10' fill='#888'>${pct}%</text>")
    }

    for ($i = 0; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        $xBase = $leftPad + ($i * $groupWidth) + $gap

        $itemsPct = [math]::Max(0, [math]::Min(100, $d.CompletionPct))
        $itemsH = [int][math]::Max(2, [math]::Round($itemsPct / 100 * $chartHeight))
        $itemsY = $chartHeight - $itemsH + 10
        $itemsOpacity = [math]::Round(0.5 + (0.5 * $i / [math]::Max(1, $dayCount - 1)), 2)
        [void]$sb.AppendLine("<rect x='$xBase' y='$itemsY' width='$barWidth' height='$itemsH' fill='#336699' opacity='$itemsOpacity' rx='2'/>")
        if ($itemsH -gt 15) {
            [void]$sb.AppendLine("<text x='$($xBase + [int]($barWidth/2))' y='$($itemsY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='#336699'>$($itemsPct)%</text>")
        }

        $rvCompleted = @($d.Reviewers | Where-Object { $_.Completion -ge 100 }).Count
        $rvTotal = $d.Reviewers.Count
        $rvPct = if ($rvTotal -gt 0) { [math]::Max(0, [math]::Min(100, [math]::Round($rvCompleted / $rvTotal * 100, 0))) } else { 0 }
        $rvH = [int][math]::Max(2, [math]::Round($rvPct / 100 * $chartHeight))
        $rvY = $chartHeight - $rvH + 10
        $rvX = $xBase + $barWidth + $gap
        [void]$sb.AppendLine("<rect x='$rvX' y='$rvY' width='$barWidth' height='$rvH' fill='$($colors.Green)' opacity='$itemsOpacity' rx='2'/>")
        if ($rvH -gt 15) {
            [void]$sb.AppendLine("<text x='$($rvX + [int]($barWidth/2))' y='$($rvY - 3)' text-anchor='middle' font-size='9' font-weight='600' fill='$($colors.Green)'>$($rvPct)%</text>")
        }

        $labelX = $xBase + $barWidth + [int]($gap / 2)
        $labelY = $chartHeight + 25
        [void]$sb.AppendLine("<text x='$labelX' y='$labelY' text-anchor='middle' font-size='10' fill='#566'>$($d.DayLabel)</text>")
    }

    $legendY = $chartHeight + 45
    [void]$sb.AppendLine("<rect x='$($leftPad + 20)' y='$legendY' width='12' height='12' fill='#336699' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($leftPad + 37)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Items Reviewed %</text>")
    [void]$sb.AppendLine("<rect x='$($leftPad + 170)' y='$legendY' width='12' height='12' fill='$($colors.Green)' rx='2'/>")
    [void]$sb.AppendLine("<text x='$($leftPad + 187)' y='$($legendY + 10)' font-size='11' fill='#1c2b3a'>Reviewers Completed %</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}

# ===== STYLE F: Scope Drift Monitor =====
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Scope Drift Monitor -- Decisions vs Scope Growth</div>")
    [void]$sb.AppendLine("<p class='note'>Overlays cumulative decisions made against cumulative scope growth. If scope grows faster than decisions, the gap is highlighted in red.</p>")

    $cumDecisions = @(); $cumScope = @()
    $runDecisions = 0; $runScope = 0
    for ($i = 0; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]
        if ($i -gt 0) {
            $prevD = $dailyData[$i - 1]
            $dailyDecided = ($d.Approved + $d.Revoked) - ($prevD.Approved + $prevD.Revoked)
            if ($dailyDecided -lt 0) { $dailyDecided = 0 }
            $runDecisions += $dailyDecided
            $runScope += ($d.ScopeAdded - $d.ScopeRemoved)
        }
        $cumDecisions += $runDecisions
        $cumScope += $runScope
    }

    $fW = 640; $fH = 200; $fPadL = 50; $fPadR = 20; $fPadT = 10; $fPadB = 40
    $fPlotW = $fW - $fPadL - $fPadR; $fPlotH = $fH - $fPadT - $fPadB
    $allVals = $cumDecisions + $cumScope
    $fMax = [math]::Max(1, ($allVals | Measure-Object -Maximum).Maximum)

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$fW' height='$fH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($g = 0; $g -le 4; $g++) {
        $gVal = [int]($fMax * $g / 4)
        $gy = [int]($fPadT + $fPlotH - ($g / 4 * $fPlotH))
        [void]$sb.AppendLine("<line x1='$fPadL' y1='$gy' x2='$($fW - $fPadR)' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($fPadL - 5)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$gVal</text>")
    }

    $decPts = @(); $scopePts = @()
    for ($i = 0; $i -lt $dayCount; $i++) {
        $px = [int]($fPadL + ($i / [math]::Max(1, $dayCount - 1)) * $fPlotW)
        $decY = [int]($fPadT + $fPlotH - ($cumDecisions[$i] / $fMax * $fPlotH))
        $scopeY = [int]($fPadT + $fPlotH - ($cumScope[$i] / $fMax * $fPlotH))
        $decPts += "$px,$decY"
        $scopePts += "$px,$scopeY"
    }

    $gapFill = "M $($scopePts[0] -replace ',',' ')"
    for ($i = 1; $i -lt $scopePts.Count; $i++) { $gapFill += " L $($scopePts[$i] -replace ',',' ')" }
    for ($i = $decPts.Count - 1; $i -ge 0; $i--) { $gapFill += " L $($decPts[$i] -replace ',',' ')" }
    $gapFill += " Z"
    [void]$sb.AppendLine("<path d='$gapFill' fill='$($colors.Red)' opacity='0.1'/>")

    $decArea = "M $fPadL $($fPadT + $fPlotH)"
    for ($i = 0; $i -lt $decPts.Count; $i++) { $decArea += " L $($decPts[$i] -replace ',',' ')" }
    $decArea += " L $($fW - $fPadR) $($fPadT + $fPlotH) Z"
    [void]$sb.AppendLine("<path d='$decArea' fill='$($colors.Green)' opacity='0.12'/>")
    [void]$sb.AppendLine("<polyline points='$($decPts -join ' ')' stroke='$($colors.Green)' stroke-width='2.5' fill='none'/>")

    $scopeArea = "M $fPadL $($fPadT + $fPlotH)"
    for ($i = 0; $i -lt $scopePts.Count; $i++) { $scopeArea += " L $($scopePts[$i] -replace ',',' ')" }
    $scopeArea += " L $($fW - $fPadR) $($fPadT + $fPlotH) Z"
    [void]$sb.AppendLine("<path d='$scopeArea' fill='$($colors.Amber)' opacity='0.1'/>")
    [void]$sb.AppendLine("<polyline points='$($scopePts -join ' ')' stroke='$($colors.Amber)' stroke-width='2.5' fill='none' stroke-dasharray='6,3'/>")

    for ($i = 0; $i -lt $dayCount; $i++) {
        $parts = $decPts[$i] -split ','
        [void]$sb.AppendLine("<circle cx='$($parts[0])' cy='$($parts[1])' r='3' fill='$($colors.Green)'/>")
        $parts2 = $scopePts[$i] -split ','
        [void]$sb.AppendLine("<circle cx='$($parts2[0])' cy='$($parts2[1])' r='3' fill='$($colors.Amber)'/>")
    }

    for ($i = 0; $i -lt $dayCount; $i++) {
        $lx = [int]($fPadL + ($i / [math]::Max(1, $dayCount - 1)) * $fPlotW)
        [void]$sb.AppendLine("<text x='$lx' y='$($fH - 5)' text-anchor='middle' font-size='9' fill='#566'>$($dailyData[$i].DayLabel)</text>")
    }

    [void]$sb.AppendLine("<line x1='$($fPadL + 10)' y1='$($fPadT + 3)' x2='$($fPadL + 30)' y2='$($fPadT + 3)' stroke='$($colors.Green)' stroke-width='2.5'/>")
    [void]$sb.AppendLine("<text x='$($fPadL + 34)' y='$($fPadT + 7)' font-size='10' fill='#1c2b3a'>Cumulative Decisions</text>")
    [void]$sb.AppendLine("<line x1='$($fPadL + 180)' y1='$($fPadT + 3)' x2='$($fPadL + 200)' y2='$($fPadT + 3)' stroke='$($colors.Amber)' stroke-width='2.5' stroke-dasharray='6,3'/>")
    [void]$sb.AppendLine("<text x='$($fPadL + 204)' y='$($fPadT + 7)' font-size='10' fill='#1c2b3a'>Cumulative Scope Drift</text>")

    $finalDec = $cumDecisions[$cumDecisions.Count - 1]
    $finalScope = $cumScope[$cumScope.Count - 1]
    $driftStatus = if ($finalScope -gt $finalDec) { 'SCOPE OUTPACING DECISIONS' } else { 'Decisions keeping pace' }
    $driftColor = if ($finalScope -gt $finalDec) { $colors.Red } else { $colors.Green }
    [void]$sb.AppendLine("<text x='$($fW - $fPadR)' y='$($fPadT + 20)' text-anchor='end' font-size='10' font-weight='600' fill='$driftColor'>$driftStatus</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE I: Workload Distribution Treemap =====
if ($today.Reviewers.Count -gt 0) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Workload Distribution Treemap -- Reviewer Item Volume</div>")
    [void]$sb.AppendLine("<p class='note'>Each rectangle = a reviewer, area proportional to their total items. Color by completion: green >=90%, amber 50-89%, red &lt;50%.</p>")

    $iW = 700; $iH = 200
    $todayRvs = @($today.Reviewers | Sort-Object { -$_.Total })
    $totalAllItems = ($todayRvs | Measure-Object -Property Total -Sum).Sum
    if ($totalAllItems -eq 0) { $totalAllItems = 1 }

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$iW' height='$iH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    $xPos = 0; $yPos = 0; $rowH = $iH
    foreach ($rv in $todayRvs) {
        $fraction = $rv.Total / $totalAllItems
        $rectW = [int][math]::Max(40, [math]::Round($fraction * $iW))
        if ($xPos + $rectW -gt $iW) { $rectW = $iW - $xPos }
        if ($rectW -le 0) { continue }

        $rvCompClamped = [math]::Max(0, [math]::Min(100, $rv.Completion))
        $tmColor = if ($rvCompClamped -ge 90) { $colors.Green } elseif ($rvCompClamped -ge 50) { $colors.Amber } else { $colors.Red }
        $rvName = ConvertTo-SPHtmlSafe $rv.Name

        [void]$sb.AppendLine("<rect x='$xPos' y='$yPos' width='$rectW' height='$rowH' fill='$tmColor' opacity='0.2' stroke='#fff' stroke-width='2'/>")
        [void]$sb.AppendLine("<rect x='$xPos' y='$yPos' width='$rectW' height='$rowH' fill='$tmColor' opacity='0.65' stroke='#fff' stroke-width='2' rx='4'/>")

        $labelFontSize = if ($rectW -gt 100) { 12 } else { 10 }
        $midX = $xPos + ($rectW / 2)
        $midY = $yPos + ($rowH / 2)
        [void]$sb.AppendLine("<text x='$midX' y='$($midY - 10)' text-anchor='middle' font-size='$labelFontSize' font-weight='700' fill='#fff'>$rvName</text>")
        [void]$sb.AppendLine("<text x='$midX' y='$($midY + 8)' text-anchor='middle' font-size='11' fill='#fff'>$($rv.Total) items</text>")
        [void]$sb.AppendLine("<text x='$midX' y='$($midY + 24)' text-anchor='middle' font-size='10' fill='#fff'>$($rvCompClamped)%</text>")

        $xPos += $rectW
    }

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# ===== STYLE L: Scope Waterfall =====
if ($dayCount -ge 2) {
    [void]$sb.AppendLine("<div class='section'>")

    [void]$sb.AppendLine("<div class='section-title'>Scope Waterfall -- Daily Changes to Pending Items</div>")
    [void]$sb.AppendLine("<p class='note'>Waterfall chart: starting bar = Day 1 pending. Each subsequent day shows scope added (green up), scope removed (red down), and items decided (blue down). Final bar = today's pending.</p>")

    $lW = 700; $lH = 260; $lPadL = 50; $lPadR = 20; $lPadT = 20; $lPadB = 50
    $lPlotW = $lW - $lPadL - $lPadR; $lPlotH = $lH - $lPadT - $lPadB

    $wfSegments = @()
    $wfSegments += @{ Label = $dailyData[0].DayLabel; Type = 'start'; Value = $dailyData[0].Pending; RunTotal = $dailyData[0].Pending }

    $runTotal = $dailyData[0].Pending
    for ($i = 1; $i -lt $dayCount; $i++) {
        $d = $dailyData[$i]; $prev = $dailyData[$i - 1]
        $scopeAdd = $d.ScopeAdded
        $scopeRem = $d.ScopeRemoved
        $decided = [math]::Max(0, ($d.Approved + $d.Revoked) - ($prev.Approved + $prev.Revoked))

        if ($scopeAdd -gt 0) {
            $wfSegments += @{ Label = ''; Type = 'up'; Value = $scopeAdd; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "+$scopeAdd scope" }
            $runTotal += $scopeAdd
        }
        if ($scopeRem -gt 0) {
            $wfSegments += @{ Label = ''; Type = 'scope-down'; Value = $scopeRem; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "-$scopeRem scope" }
            $runTotal -= $scopeRem
        }
        if ($decided -gt 0) {
            $wfSegments += @{ Label = ''; Type = 'decided'; Value = $decided; RunTotal = $runTotal; Day = $d.DayLabel; Desc = "-$decided decided" }
            $runTotal -= $decided
        }
    }
    $wfSegments += @{ Label = 'Today'; Type = 'end'; Value = $today.Pending; RunTotal = $today.Pending }

    $allRunTotals = @($wfSegments | ForEach-Object { $_.RunTotal }) + @($wfSegments | ForEach-Object { $_.RunTotal + $_.Value })
    $lMaxVal = [math]::Max(1, ($allRunTotals | Measure-Object -Maximum).Maximum)
    $segCount = $wfSegments.Count
    $segW = [math]::Max(8, [int][math]::Floor($lPlotW / ($segCount + 1)))
    $barW = [int]($segW * 0.7)

    [void]$sb.AppendLine("<div style='text-align:center;margin:12px 0;'>")
    [void]$sb.AppendLine("<svg width='$lW' height='$lH' style='font-family:Segoe UI,Arial,sans-serif;'>")

    for ($g = 0; $g -le 4; $g++) {
        $gVal = [int]($lMaxVal * $g / 4)
        $gy = [int]($lPadT + $lPlotH - ($g / 4 * $lPlotH))
        [void]$sb.AppendLine("<line x1='$lPadL' y1='$gy' x2='$($lW - $lPadR)' y2='$gy' stroke='#e3e9f0' stroke-width='1'/>")
        [void]$sb.AppendLine("<text x='$($lPadL - 5)' y='$($gy + 4)' text-anchor='end' font-size='9' fill='#888'>$gVal</text>")
    }

    $prevBarTop = 0; $prevBarX = 0
    for ($si = 0; $si -lt $wfSegments.Count; $si++) {
        $seg = $wfSegments[$si]
        $sx = $lPadL + ($si * $segW) + [int](($segW - $barW) / 2)
        $baseline = [int]($lPadT + $lPlotH)

        if ($seg.Type -eq 'start' -or $seg.Type -eq 'end') {
            $bh = [int]($seg.Value / $lMaxVal * $lPlotH)
            $by = $baseline - $bh
            $bColor = if ($seg.Type -eq 'start') { '#336699' } else { '#1f3a5f' }
            [void]$sb.AppendLine("<rect x='$sx' y='$by' width='$barW' height='$bh' fill='$bColor' rx='2'/>")
            [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($by - 4)' text-anchor='middle' font-size='9' font-weight='600' fill='$bColor'>$($seg.Value)</text>")
            $prevBarTop = $by
        }
        elseif ($seg.Type -eq 'up') {
            $baseY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
            $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
            $by = $baseY - $bh
            [void]$sb.AppendLine("<rect x='$sx' y='$by' width='$barW' height='$bh' fill='$($colors.Green)' opacity='0.75' rx='2'/>")
            [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($by - 3)' text-anchor='middle' font-size='8' fill='$($colors.Green)'>+$($seg.Value)</text>")
            $prevBarTop = $by
        }
        elseif ($seg.Type -eq 'scope-down') {
            $topY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
            $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
            [void]$sb.AppendLine("<rect x='$sx' y='$topY' width='$barW' height='$bh' fill='$($colors.Red)' opacity='0.75' rx='2'/>")
            [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($topY - 3)' text-anchor='middle' font-size='8' fill='$($colors.Red)'>-$($seg.Value)</text>")
            $prevBarTop = $topY
        }
        elseif ($seg.Type -eq 'decided') {
            $topY = [int]($baseline - ($seg.RunTotal / $lMaxVal * $lPlotH))
            $bh = [math]::Max(3, [int]($seg.Value / $lMaxVal * $lPlotH))
            [void]$sb.AppendLine("<rect x='$sx' y='$topY' width='$barW' height='$bh' fill='#336699' opacity='0.75' rx='2'/>")
            [void]$sb.AppendLine("<text x='$($sx + $barW / 2)' y='$($topY - 3)' text-anchor='middle' font-size='8' fill='#336699'>-$($seg.Value)</text>")
            $prevBarTop = $topY
        }

        if ($si -lt $wfSegments.Count - 1 -and $seg.Type -ne 'start') {
            $connX1 = $sx + $barW
            $connX2 = $lPadL + (($si + 1) * $segW) + [int](($segW - $barW) / 2)
            [void]$sb.AppendLine("<line x1='$connX1' y1='$prevBarTop' x2='$connX2' y2='$prevBarTop' stroke='#aaa' stroke-width='1' stroke-dasharray='3,2'/>")
        }

        $prevBarX = $sx
    }

    [void]$sb.AppendLine("<text x='$($lPadL + $barW / 2)' y='$($lH - 10)' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>$($dailyData[0].DayLabel)</text>")
    $endX = $lPadL + (($wfSegments.Count - 1) * $segW) + ($barW / 2)
    [void]$sb.AppendLine("<text x='$endX' y='$($lH - 10)' text-anchor='middle' font-size='9' font-weight='600' fill='#566'>Today</text>")

    $legY = $lH - 25
    [void]$sb.AppendLine("<rect x='$($lPadL + 60)' y='$($legY - 10)' width='10' height='10' rx='2' fill='$($colors.Green)' opacity='0.75'/>")
    [void]$sb.AppendLine("<text x='$($lPadL + 74)' y='$legY' font-size='9' fill='#1c2b3a'>Scope Added</text>")
    [void]$sb.AppendLine("<rect x='$($lPadL + 155)' y='$($legY - 10)' width='10' height='10' rx='2' fill='$($colors.Red)' opacity='0.75'/>")
    [void]$sb.AppendLine("<text x='$($lPadL + 169)' y='$legY' font-size='9' fill='#1c2b3a'>Scope Removed</text>")
    [void]$sb.AppendLine("<rect x='$($lPadL + 265)' y='$($legY - 10)' width='10' height='10' rx='2' fill='#336699' opacity='0.75'/>")
    [void]$sb.AppendLine("<text x='$($lPadL + 279)' y='$legY' font-size='9' fill='#1c2b3a'>Decided</text>")

    [void]$sb.AppendLine("</svg>")
    [void]$sb.AppendLine("</div></div>")
}


# Footer
$envFooter = if (-not [string]::IsNullOrWhiteSpace($envName)) { " | Env: $envName" } else { '' }
[void]$sb.AppendLine("<p class='footer'>Daily Evidence V5 (Trend View) | Campaign: $(ConvertTo-SPHtmlSafe $campaignNameResolved)$envFooter | Generated: $genDate | SailPoint ISC Governance Toolkit</p>")
[void]$sb.AppendLine('</body></html>')

# Write HTML
Write-SPHtmlFile -Path $htmlFile -Content $sb.ToString()
Write-Host "    HTML: $htmlFile" -ForegroundColor Green
Write-Host ''

#endregion

#region Console Output

if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host '  === V5 Trend Summary ===' -ForegroundColor Cyan
    Write-Host "  Campaign:     $campaignNameResolved" -ForegroundColor White
    Write-Host "  Status:       $campaignStatus" -ForegroundColor White
    Write-Host "  Completion:   $($today.CompletionPct)%" -ForegroundColor White
    Write-Host "  Approved:     $($today.Approved)" -ForegroundColor White
    Write-Host "  Revoked:      $($today.Revoked)" -ForegroundColor White
    Write-Host "  Pending:      $($today.Pending)" -ForegroundColor White
    Write-Host "  Reviewers:    $($reviewers.Count)" -ForegroundColor White
    if ($dayCount -ge 2) {
        $trendDir2 = if ($weekDelta -gt 0) { 'UP' } elseif ($weekDelta -lt 0) { 'DOWN' } else { 'FLAT' }
        Write-Host "  Trend:        ${trendDir2} (${dSign}${weekDelta}% over $dayCount days)" -ForegroundColor White
    }
    Write-Host "  Priv Pending: $($today.PrivPending) of $($today.PrivTotal)" -ForegroundColor White

    # Stalled reviewers
    $stalledRvs = @($reviewers | Where-Object { $_.Style -eq 'stalled' })
    if ($stalledRvs.Count -gt 0) {
        Write-Host "  STALLED:      $($stalledRvs.Count) reviewer(s): $($stalledRvs.Name -join ', ')" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region JSON Output

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $jsonResult = [ordered]@{
        Version        = 'V5'
        CampaignName   = $campaignNameResolved
        CampaignId     = $campaignIdResolved
        Status         = $campaignStatus
        DueDate        = $campaignDueDate
        DataPoints     = $dayCount
        Period         = @{
            Start = $dailyData[0].Date
            End   = $dailyData[$dayCount - 1].Date
        }
        Current        = [ordered]@{
            CompletionPct = $today.CompletionPct
            Approved      = $today.Approved
            Revoked       = $today.Revoked
            Pending       = $today.Pending
            PrivPending   = $today.PrivPending
            PrivTotal     = $today.PrivTotal
            Reviewers     = $reviewers.Count
        }
        Trend          = [ordered]@{
            CompletionDelta = $weekDelta
            Direction       = if ($weekDelta -gt 2) { 'Up' } elseif ($weekDelta -lt -2) { 'Down' } else { 'Flat' }
        }
        StalledReviewers = @($reviewers | Where-Object { $_.Style -eq 'stalled' } | ForEach-Object { $_.Name })
        HtmlReport     = $htmlFile
        CorrelationID  = $correlationID
        GeneratedAt    = $genDate
    }

    if ($OutputMode -eq 'JSON') {
        $jsonResult | ConvertTo-Json -Depth 6
    }
    else {
        $jsonFile = Join-Path $effectiveOutputPath "daily-evidence-v5-${safeCampId}-${timestamp}.json"
        $jsonResult | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-Host "    JSON: $jsonFile" -ForegroundColor Green
    }
}

#endregion

#region Audit Trail

$totalDuration = (Get-Date) - $startTime
$durationStr = "$([math]::Round($totalDuration.TotalSeconds, 1))s"

Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray

Write-SPLog -Message "Invoke-SPDailyEvidenceReportV5 completed: Duration=$durationStr DataPoints=$dayCount" `
    -Severity INFO -Component 'DailyEvidenceV5' -Action 'Complete' -CorrelationID $correlationID

#endregion

#region Exit Code

# 0: Healthy (completion >= 80%, no stalled, on track)
# 1: Warning (completion 50-79%, some concerns)
# 5: Critical (completion < 50%, stalled, insufficient data)

$exitCode = 0

if ($insufficientData) {
    $exitCode = 5
}
elseif ($today.CompletionPct -lt 50) {
    $exitCode = 5
}
elseif ($today.CompletionPct -lt 80 -or @($reviewers | Where-Object { $_.Style -eq 'stalled' }).Count -gt 0) {
    $exitCode = 1
}

exit $exitCode

#endregion
