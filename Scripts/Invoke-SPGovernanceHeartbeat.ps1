#Requires -Version 5.1
<#
.SYNOPSIS
    Lightweight governance heartbeat -- captures campaign-level KPIs at high
    frequency without fetching item-level data.
.DESCRIPTION
    Designed for high-frequency (e.g. every 15-30 minutes) governance metric
    snapshots. Calls only Get-SPAuditCampaigns (a single paginated list call)
    and derives campaign-level KPIs from the response:

      - Active campaign count + names
      - Completed campaign count
      - Overdue count (active campaigns past deadline)
      - Average completion % across active campaigns (from campaign metadata)

    Results are appended to governance-heartbeat.jsonl using the same atomic
    append pattern as Save-SPGovernanceMetrics (copy -> append -> prune ->
    rename). This avoids the expensive per-campaign item fetching that the
    full Invoke-SPGovernanceMetrics pipeline performs.

    Optionally generates an HTML governance dashboard via -IncludeDashboard.
.PARAMETER OutputPath
    Override directory for heartbeat JSONL output. Defaults to the configured
    Audit.OutputPath or <ToolkitRoot>\Audit.
.PARAMETER IncludeDashboard
    Also generate the HTML governance trend dashboard after capturing the
    heartbeat. Calls Get-SPGovernanceDashboardData and
    Export-SPGovernanceDashboardHtml.
.PARAMETER DashboardPeriod
    Time window for the dashboard when -IncludeDashboard is used.
    Valid values: Last7Days, Last30Days, Last90Days. Default Last7Days.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be captured without making API calls.
.EXAMPLE
    .\Invoke-SPGovernanceHeartbeat.ps1 -Token $token
    # Capture heartbeat metrics (campaign-level only, no item fetching).
.EXAMPLE
    .\Invoke-SPGovernanceHeartbeat.ps1 -Token $token -IncludeDashboard
    # Capture heartbeat and regenerate the HTML dashboard.
.EXAMPLE
    .\Invoke-SPGovernanceHeartbeat.ps1 -Token $token -IncludeDashboard -DashboardPeriod Last30Days
    # Heartbeat + dashboard covering the last 30 days.
.EXAMPLE
    .\Invoke-SPGovernanceHeartbeat.ps1 -WhatIf
    # Dry run -- shows what would be captured without API calls.
.NOTES
    Script:  Invoke-SPGovernanceHeartbeat.ps1
    Version: 1.0.0
    Phase:   P16-10
    Exit codes:
        0 = Heartbeat captured successfully
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical failure
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$IncludeDashboard,

    [Parameter()]
    [ValidateSet('Last7Days', 'Last30Days', 'Last90Days')]
    [string]$DashboardPeriod = 'Last7Days',

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [int]$DaysBack = 90,

    [Parameter()]
    [string]$ConfigPath,

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

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Governance Heartbeat (Lightweight)' -ForegroundColor Cyan
Write-Host "  Date:          $todayLabel" -ForegroundColor DarkGray
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

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

# Browser token injection
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

Write-SPLog -Message "Invoke-SPGovernanceHeartbeat started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'GovernanceHeartbeat' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    if ($null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = [string]$config.Audit.OutputPath
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot 'Audit'
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}
if (-not (Test-Path $effectiveOutputPath)) {
    New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
}

# WhatIf detection
$isWhatIf = $WhatIfPreference -eq $true

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following actions would be performed:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  [1] Heartbeat: fetch campaign list (last $DaysBack days)" -ForegroundColor Gray
    Write-Host '      -> Get-SPAuditCampaigns (single API call, no item fetching)' -ForegroundColor Gray
    Write-Host '      -> Compute: activeCount, completedCount, overdueCount, avgCompletionPct' -ForegroundColor Gray
    Write-Host '      -> Append record to governance-heartbeat.jsonl' -ForegroundColor Gray
    if ($IncludeDashboard) {
        Write-Host "  [2] Dashboard: generate HTML dashboard (period: $DashboardPeriod)" -ForegroundColor Gray
        Write-Host '      -> Get-SPGovernanceDashboardData + Export-SPGovernanceDashboardHtml' -ForegroundColor Gray
    }
    else {
        Write-Host '  [2] Dashboard: SKIPPED (not requested)' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

#endregion

#region Step 1: Heartbeat Capture

Write-Host '  Step 1: Heartbeat Capture' -ForegroundColor Cyan
$stepStart = Get-Date
$exitCode = 0

$heartbeatMetrics = [ordered]@{
    'campaigns.activeCount'    = 0
    'campaigns.completedCount' = 0
    'campaigns.overdueCount'   = 0
    'campaigns.avgCompletionPct' = $null
}
$campaignNames = @()

try {
    # Fetch campaigns -- single lightweight API call
    Write-Host '    Fetching campaigns...' -ForegroundColor DarkGray
    $campaignParams = @{ DaysBack = $DaysBack; CorrelationID = $correlationID }
    $campaignResult = Get-SPAuditCampaigns @campaignParams

    $currentCampaigns = @()
    if ($campaignResult.Success -and $null -ne $campaignResult.Data) {
        $currentCampaigns = @($campaignResult.Data)
    }
    Write-Host "    Found $($currentCampaigns.Count) campaign(s) in last $DaysBack days." -ForegroundColor DarkGray

    # Classify campaigns
    $activeStatuses = @('ACTIVE', 'ACTIVATING')
    $activeList     = [System.Collections.Generic.List[object]]::new()
    $completedCount = 0
    $overdueCount   = 0

    foreach ($camp in $currentCampaigns) {
        # Safe property access: support hashtables and PSCustomObjects
        $campStatus = $null
        if ($camp -is [System.Collections.IDictionary]) {
            if ($camp.ContainsKey('status')) { $campStatus = [string]$camp['status'] }
            elseif ($camp.ContainsKey('Status')) { $campStatus = [string]$camp['Status'] }
        }
        else {
            if ($null -ne $camp.status) { $campStatus = [string]$camp.status }
        }

        if ($null -ne $campStatus -and $campStatus.ToUpper() -in $activeStatuses) {
            $activeList.Add($camp)

            # Check overdue: active campaign past deadline
            $deadlineStr = $null
            if ($camp -is [System.Collections.IDictionary]) {
                if ($camp.ContainsKey('deadline')) { $deadlineStr = [string]$camp['deadline'] }
                elseif ($camp.ContainsKey('due')) { $deadlineStr = [string]$camp['due'] }
            }
            else {
                if ($null -ne $camp.deadline) { $deadlineStr = [string]$camp.deadline }
                elseif ($null -ne $camp.due) { $deadlineStr = [string]$camp.due }
            }
            if (-not [string]::IsNullOrWhiteSpace($deadlineStr)) {
                try {
                    $dlDate = [datetime]::Parse($deadlineStr).ToUniversalTime()
                    if ($dlDate -lt (Get-Date).ToUniversalTime()) {
                        $overdueCount++
                    }
                }
                catch { }
            }
        }
        elseif ($null -ne $campStatus -and $campStatus.ToUpper() -eq 'COMPLETED') {
            $completedCount++
        }
    }

    # Extract active campaign names
    foreach ($activeCamp in $activeList) {
        $campName = $null
        if ($activeCamp -is [System.Collections.IDictionary]) {
            if ($activeCamp.ContainsKey('name')) { $campName = [string]$activeCamp['name'] }
        }
        else {
            if ($null -ne $activeCamp.name) { $campName = [string]$activeCamp.name }
        }
        if (-not [string]::IsNullOrWhiteSpace($campName)) {
            $campaignNames += $campName
        }
    }

    # Compute average completion % from campaign-level metadata if available
    # ISC campaign objects may carry completionPercentage in the list response
    $totalCompPct = 0.0
    $compPctCount = 0
    foreach ($activeCamp in $activeList) {
        $compPct = $null
        if ($activeCamp -is [System.Collections.IDictionary]) {
            if ($activeCamp.ContainsKey('completionPercentage')) { $compPct = $activeCamp['completionPercentage'] }
            elseif ($activeCamp.ContainsKey('completedPercentage')) { $compPct = $activeCamp['completedPercentage'] }
        }
        else {
            if ($null -ne $activeCamp.completionPercentage) { $compPct = $activeCamp.completionPercentage }
            elseif ($null -ne $activeCamp.completedPercentage) { $compPct = $activeCamp.completedPercentage }
        }
        if ($null -ne $compPct) {
            try {
                $totalCompPct += [double]$compPct
                $compPctCount++
            }
            catch { }
        }
    }

    $heartbeatMetrics['campaigns.activeCount']    = $activeList.Count
    $heartbeatMetrics['campaigns.completedCount'] = $completedCount
    $heartbeatMetrics['campaigns.overdueCount']   = $overdueCount
    if ($compPctCount -gt 0) {
        $heartbeatMetrics['campaigns.avgCompletionPct'] = [math]::Round($totalCompPct / $compPctCount, 1)
    }

    Write-Host "    Active: $($activeList.Count) | Completed: $completedCount | Overdue: $overdueCount" -ForegroundColor DarkGray

    #region Atomic append to governance-heartbeat.jsonl

    # Resolve metrics path from config (same convention as Save-SPGovernanceMetrics)
    $metricsPath   = Join-Path $effectiveOutputPath 'metrics'
    $retentionDays = 365
    try {
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'Metrics') {
            $metricsCfg = $config.Metrics
            if ($metricsCfg.PSObject.Properties.Name -contains 'Path' -and
                -not [string]::IsNullOrWhiteSpace($metricsCfg.Path)) {
                $metricsPath = $metricsCfg.Path
            }
            if ($metricsCfg.PSObject.Properties.Name -contains 'RetentionDays' -and
                $null -ne $metricsCfg.RetentionDays) {
                $retentionDays = [int]$metricsCfg.RetentionDays
            }
        }
    }
    catch { }

    if (-not [System.IO.Path]::IsPathRooted($metricsPath)) {
        $metricsPath = Join-Path $toolkitRoot $metricsPath
    }
    if (-not (Test-Path -Path $metricsPath -PathType Container)) {
        New-Item -Path $metricsPath -ItemType Directory -Force | Out-Null
    }

    $filePath  = Join-Path -Path $metricsPath -ChildPath 'governance-heartbeat.jsonl'
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $record = [ordered]@{
        timestamp     = $timestamp
        label         = 'heartbeat'
        metrics       = $heartbeatMetrics
        campaignNames = $campaignNames
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $jsonLine  = $record | ConvertTo-Json -Depth 5 -Compress
    $tmpPath   = "${filePath}.tmp"

    try {
        # Copy existing file to tmp, or start fresh
        if (Test-Path -Path $filePath) {
            Copy-Item -Path $filePath -Destination $tmpPath -Force
        }
        else {
            [System.IO.File]::WriteAllText($tmpPath, '', $utf8NoBom)
        }

        # Append the new record
        [System.IO.File]::AppendAllText($tmpPath, "$jsonLine`n", $utf8NoBom)

        # Apply retention: remove lines older than RetentionDays
        $retentionCutoff = (Get-Date).AddDays(-$retentionDays).ToUniversalTime()
        $lines = [System.IO.File]::ReadAllLines($tmpPath, $utf8NoBom)
        $keptLines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $parsed = $line | ConvertFrom-Json
                $lineTs = $null
                if ($null -ne $parsed.timestamp) {
                    $lineTs = [datetime]::Parse([string]$parsed.timestamp).ToUniversalTime()
                }
                if ($null -ne $lineTs -and $lineTs -lt $retentionCutoff) {
                    continue
                }
            }
            catch {
                # Keep unparseable lines to avoid data loss
            }
            $keptLines.Add($line)
        }

        # Write retained lines back
        $content = ($keptLines -join "`n")
        if ($keptLines.Count -gt 0) { $content += "`n" }
        [System.IO.File]::WriteAllText($tmpPath, $content, $utf8NoBom)

        # Atomic rename
        if (Test-Path -Path $filePath) {
            Remove-Item -Path $filePath -Force
        }
        Move-Item -Path $tmpPath -Destination $filePath -Force

        Write-Host "    Heartbeat saved to $filePath" -ForegroundColor Green
    }
    catch {
        # Clean up tmp on failure
        if (Test-Path -Path $tmpPath) {
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
        }
        Write-Host "    ERROR: Failed to save heartbeat: $($_.Exception.Message)" -ForegroundColor Red
        Write-SPLog -Message "Heartbeat save failed: $($_.Exception.Message)" `
            -Severity ERROR -Component 'GovernanceHeartbeat' -Action 'Save' -CorrelationID $correlationID
        $exitCode = 5
    }

    #endregion

    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    Write-Host "  Step 1: Heartbeat captured ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Green
}
catch {
    $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
    Write-Host "  Step 1: ERROR - $($_.Exception.Message) ($([math]::Round($stepDuration, 1))s)" -ForegroundColor Red
    Write-SPLog -Message "Heartbeat capture exception: $($_.Exception.Message)" `
        -Severity ERROR -Component 'GovernanceHeartbeat' -Action 'CaptureError' -CorrelationID $correlationID
    $exitCode = 5
}
Write-Host ''

#endregion

#region Step 2: Dashboard (if -IncludeDashboard)

if ($IncludeDashboard -and $exitCode -eq 0) {
    Write-Host "  Step 2: Dashboard ($DashboardPeriod)" -ForegroundColor Cyan
    $dashStart = Get-Date

    try {
        $dashData = Get-SPGovernanceDashboardData -Period $DashboardPeriod `
            -CorrelationID $correlationID

        if ($null -ne $dashData) {
            $dashResult = Export-SPGovernanceDashboardHtml -DashboardData $dashData `
                -OutputPath $effectiveOutputPath -CorrelationID $correlationID

            $dashDuration = ((Get-Date) - $dashStart).TotalSeconds
            if ($dashResult.Success) {
                Write-Host "    Dashboard: $($dashResult.Data)" -ForegroundColor Green
            }
            else {
                Write-Host "    WARN: Dashboard export: $($dashResult.Error)" -ForegroundColor Yellow
            }
        }
        else {
            $dashDuration = ((Get-Date) - $dashStart).TotalSeconds
            Write-Host '    WARN: No dashboard data returned' -ForegroundColor Yellow
        }
        Write-Host "  Step 2: Dashboard generated ($([math]::Round($dashDuration, 1))s)" -ForegroundColor Green
    }
    catch {
        $dashDuration = ((Get-Date) - $dashStart).TotalSeconds
        Write-Host "  Step 2: WARN - $($_.Exception.Message) ($([math]::Round($dashDuration, 1))s)" -ForegroundColor Yellow
        Write-SPLog -Message "Dashboard generation exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'GovernanceHeartbeat' -Action 'DashboardError' -CorrelationID $correlationID
    }
    Write-Host ''
}
elseif ($IncludeDashboard) {
    Write-Host '  Step 2: Dashboard [SKIPPED - heartbeat capture failed]' -ForegroundColor DarkGray
    Write-Host ''
}
else {
    Write-Host '  Step 2: Dashboard [SKIPPED - not requested]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Summary

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

Write-Host '  === Heartbeat Summary ===' -ForegroundColor Cyan
Write-Host "    Active Campaigns:    $($heartbeatMetrics['campaigns.activeCount'])"
if ($campaignNames.Count -gt 0) {
    Write-Host "    Campaign Names:      $($campaignNames -join ', ')"
}
Write-Host "    Completed Campaigns: $($heartbeatMetrics['campaigns.completedCount'])"
Write-Host "    Overdue:             $($heartbeatMetrics['campaigns.overdueCount'])"
$avgPct = $heartbeatMetrics['campaigns.avgCompletionPct']
$avgPctStr = if ($null -ne $avgPct) { "$avgPct%" } else { 'N/A' }
Write-Host "    Avg Completion:      $avgPctStr"
Write-Host "    Duration:            $durationStr"
Write-Host ''

# JSONL audit trail event
try {
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'GovernanceHeartbeat'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            ActiveCampaigns    = $heartbeatMetrics['campaigns.activeCount']
            CompletedCampaigns = $heartbeatMetrics['campaigns.completedCount']
            OverdueCampaigns   = $heartbeatMetrics['campaigns.overdueCount']
            AvgCompletionPct   = $heartbeatMetrics['campaigns.avgCompletionPct']
            DashboardGenerated = [bool]$IncludeDashboard
            DurationSeconds    = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode           = $exitCode
        }
    }
    $auditJsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditUtf8 = New-Object System.Text.UTF8Encoding($false)
    $auditFile  = Join-Path $effectiveOutputPath 'governance-metrics-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$auditJsonLine`n", $auditUtf8)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'GovernanceHeartbeat' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPGovernanceHeartbeat completed: ExitCode=$exitCode Duration=$durationStr" `
    -Severity INFO -Component 'GovernanceHeartbeat' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $exitCode
