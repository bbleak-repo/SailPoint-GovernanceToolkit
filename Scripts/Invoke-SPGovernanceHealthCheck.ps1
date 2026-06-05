#Requires -Version 5.1
<#
.SYNOPSIS
    Runs all governance health checks in a single command and reports pass/fail.
.DESCRIPTION
    Orchestrates six governance health dimensions into one consolidated report:
    1. Source Aggregation Health (P16-02): Are sources connected and syncing?
    2. Data Quality Score (P16-03): Is identity data complete and accurate?
    3. Policy Compliance (P13-04): Do governance policies pass?
    4. Configuration Drift (P14-07): Has config changed since last snapshot?
    5. Orphan Accounts (P16-01): Are there ungoverned accounts?
    6. Campaign Coverage Gaps (P16-04): Are entitlements being reviewed?

    Produces a console summary with pass/fail/warn per check, an overall health
    grade, and an optional HTML report for distribution.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication.
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER SourceId
    Source IDs to assess. If omitted, uses configured sources or all enabled.
.PARAMETER MaxStalenessHours
    Hours after which a source is considered stale. Default 48.
.PARAMETER IdentityLimit
    Maximum identities for data quality scoring. Default 500.
.PARAMETER SnapshotPath
    Directory containing configuration snapshots for drift comparison.
    Defaults to {Audit.OutputPath}/snapshots/.
.PARAMETER DaysBack
    Campaign lookback window for coverage gap analysis. Default 90.
.PARAMETER SkipAggregationHealth
    Skip source aggregation health check.
.PARAMETER SkipDataQuality
    Skip identity data quality check.
.PARAMETER SkipPolicyCompliance
    Skip governance policy compliance check.
.PARAMETER SkipConfigDrift
    Skip configuration drift comparison.
.PARAMETER SkipOrphanAccounts
    Skip orphan account detection.
.PARAMETER SkipCoverageGaps
    Skip campaign coverage gap analysis.
.PARAMETER OutputMode
    Output format: Console, HTML, JSON, or Both (Console + HTML). Default Console.
.PARAMETER OutputPath
    Directory for HTML/JSON output. Auto-resolved from config if omitted.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be checked without making API calls.
.EXAMPLE
    .\Invoke-SPGovernanceHealthCheck.ps1 -Token $token
    # Run all six health checks with default settings.
.EXAMPLE
    .\Invoke-SPGovernanceHealthCheck.ps1 -SkipCoverageGaps -SkipConfigDrift -Token $token
    # Run subset of checks (skip coverage gaps and config drift).
.EXAMPLE
    .\Invoke-SPGovernanceHealthCheck.ps1 -OutputMode Both -OutputPath '.\Audit\healthcheck' -Token $token
    # Full health check with console output and HTML report.
.EXAMPLE
    .\Invoke-SPGovernanceHealthCheck.ps1 -WhatIf
    # Dry run -- shows what would be checked without API calls.
.NOTES
    Script:  Invoke-SPGovernanceHealthCheck.ps1
    Version: 1.0.0
    Phase:   P14-09 (DF-08)
    Exit codes:
        0 = All checks passed (grade A or B)
        1 = Warnings present (grade C)
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Critical failures (grade D or F)
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    # Tuning
    [Parameter()]
    [int]$MaxStalenessHours = 48,

    [Parameter()]
    [int]$IdentityLimit = 500,

    [Parameter()]
    [string]$SnapshotPath,

    [Parameter()]
    [int]$DaysBack = 90,

    # Skip switches
    [Parameter()]
    [switch]$SkipAggregationHealth,

    [Parameter()]
    [switch]$SkipDataQuality,

    [Parameter()]
    [switch]$SkipPolicyCompliance,

    [Parameter()]
    [switch]$SkipConfigDrift,

    [Parameter()]
    [switch]$SkipOrphanAccounts,

    [Parameter()]
    [switch]$SkipCoverageGaps,

    # Output
    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [Alias('?')]
    [switch]$Help,

    [Parameter()]
    [switch]$WhatIf
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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';   Name = 'SP.Core';  Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';     Name = 'SP.Api';   Required = $true  }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'; Name = 'SP.Audit'; Required = $true  }
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
Write-Host '  Governance Health Check' -ForegroundColor Cyan
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

Write-SPLog -Message "Invoke-SPGovernanceHealthCheck started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'HealthCheck' -Action 'Start' -CorrelationID $correlationID

# Resolve source IDs from config if not specified
$effectiveSourceIds = @()
if ($null -ne $SourceId -and $SourceId.Count -gt 0) {
    $effectiveSourceIds = @($SourceId)
}
elseif ($null -ne $config.PSObject.Properties['DeltaCert'] -and
    $null -ne $config.DeltaCert -and
    $null -ne $config.DeltaCert.PSObject.Properties['SourceIds'] -and
    $config.DeltaCert.SourceIds.Count -gt 0) {
    $effectiveSourceIds = @($config.DeltaCert.SourceIds)
}

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    if ($null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveOutputPath = Join-Path ([string]$config.Audit.OutputPath) 'healthcheck'
    }
    else {
        $effectiveOutputPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'healthcheck')
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveOutputPath)) {
    $effectiveOutputPath = Join-Path $toolkitRoot $effectiveOutputPath
}

# Resolve snapshot path
$effectiveSnapshotPath = $SnapshotPath
if ([string]::IsNullOrWhiteSpace($effectiveSnapshotPath)) {
    if ($null -ne $config.PSObject.Properties['Audit'] -and
        $null -ne $config.Audit -and
        $null -ne $config.Audit.PSObject.Properties['OutputPath'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $effectiveSnapshotPath = Join-Path ([string]$config.Audit.OutputPath) 'snapshots'
    }
    else {
        $effectiveSnapshotPath = Join-Path $toolkitRoot (Join-Path 'Audit' 'snapshots')
    }
}
if (-not [System.IO.Path]::IsPathRooted($effectiveSnapshotPath)) {
    $effectiveSnapshotPath = Join-Path $toolkitRoot $effectiveSnapshotPath
}

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true) -or $WhatIf

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following checks would be executed:' -ForegroundColor Yellow
    Write-Host ''

    $checkNum = 1
    if (-not $SkipAggregationHealth) {
        $srcDisplay = if ($effectiveSourceIds.Count -gt 0) { $effectiveSourceIds -join ', ' } else { 'all enabled sources' }
        Write-Host "  [$checkNum] Source Aggregation Health: $srcDisplay (staleness: ${MaxStalenessHours}h)" -ForegroundColor Gray
        $checkNum++
    }
    if (-not $SkipDataQuality) {
        Write-Host "  [$checkNum] Identity Data Quality: limit=$IdentityLimit identities" -ForegroundColor Gray
        $checkNum++
    }
    if (-not $SkipPolicyCompliance) {
        Write-Host "  [$checkNum] Governance Policy Compliance" -ForegroundColor Gray
        $checkNum++
    }
    if (-not $SkipConfigDrift) {
        Write-Host "  [$checkNum] Configuration Drift: snapshots at $effectiveSnapshotPath" -ForegroundColor Gray
        $checkNum++
    }
    if (-not $SkipOrphanAccounts) {
        Write-Host "  [$checkNum] Orphan Account Detection: $srcDisplay" -ForegroundColor Gray
        $checkNum++
    }
    if (-not $SkipCoverageGaps) {
        Write-Host "  [$checkNum] Campaign Coverage Gaps: DaysBack=$DaysBack" -ForegroundColor Gray
        $checkNum++
    }

    Write-Host ''
    Write-Host "  Output mode:  $OutputMode" -ForegroundColor DarkGray
    Write-Host "  Output path:  $effectiveOutputPath" -ForegroundColor DarkGray
    Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [WhatIf] Validation complete. Re-run without -WhatIf to execute.' -ForegroundColor Yellow
    exit 0
}

#endregion

#region Check Results Tracking

$checkResults = [ordered]@{
    AggregationHealth = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
    DataQuality       = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
    PolicyCompliance  = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
    ConfigDrift       = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
    OrphanAccounts    = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
    CoverageGaps      = @{ Status = 'Skipped'; Detail = ''; Grade = '-'; Duration = 0 }
}

function Set-CheckResult {
    param([string]$Check, [string]$Status, [string]$Detail, [string]$Grade, [double]$Duration)
    $checkResults[$Check]['Status']   = $Status
    $checkResults[$Check]['Detail']   = $Detail
    $checkResults[$Check]['Grade']    = $Grade
    $checkResults[$Check]['Duration'] = [math]::Round($Duration, 2)
}

#endregion

#region Check 1: Source Aggregation Health

if (-not $SkipAggregationHealth) {
    Write-Host '  [1] Source Aggregation Health' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $aggParams = @{ CorrelationID = $correlationID; MaxAcceptableStalenessHours = $MaxStalenessHours }
        if ($effectiveSourceIds.Count -gt 0) { $aggParams['SourceIds'] = $effectiveSourceIds }

        $aggResult = Get-SPSourceAggregationHealth @aggParams

        if ($aggResult.Success) {
            $data = $aggResult.Data
            $healthy = @($data.Sources | Where-Object { $_.Status -eq 'Healthy' }).Count
            $stale   = @($data.Sources | Where-Object { $_.Status -eq 'Stale' }).Count
            $failed  = @($data.Sources | Where-Object { $_.Status -eq 'Failed' }).Count
            $total   = $data.Sources.Count

            $grade = if ($failed -gt 0) { 'F' }
                     elseif ($stale -gt 0 -and $stale -ge ($total / 2)) { 'D' }
                     elseif ($stale -gt 0) { 'C' }
                     elseif ($healthy -eq $total) { 'A' }
                     else { 'B' }

            $detail = "$healthy/$total healthy"
            if ($stale -gt 0)  { $detail += ", $stale stale" }
            if ($failed -gt 0) { $detail += ", $failed failed" }

            $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
            Set-CheckResult -Check 'AggregationHealth' -Status $status -Detail $detail `
                -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
        }
        else {
            Set-CheckResult -Check 'AggregationHealth' -Status 'Error' -Detail $aggResult.Error `
                -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      Error: $($aggResult.Error)" -ForegroundColor Red
        }
    }
    catch {
        Set-CheckResult -Check 'AggregationHealth' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Check 2: Identity Data Quality

if (-not $SkipDataQuality) {
    Write-Host '  [2] Identity Data Quality' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $qualityResult = Measure-SPIdentityDataQuality -Limit $IdentityLimit -ActiveOnly -CorrelationID $correlationID

        if ($null -ne $qualityResult -and $null -ne $qualityResult.Summary) {
            $score = $qualityResult.Summary.OverallScore
            $grade = if ($score -ge 90) { 'A' }
                     elseif ($score -ge 80) { 'B' }
                     elseif ($score -ge 70) { 'C' }
                     elseif ($score -ge 60) { 'D' }
                     else { 'F' }

            $detail = "Score: $score% ($($qualityResult.Summary.IdentitiesEvaluated) identities)"
            $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
            Set-CheckResult -Check 'DataQuality' -Status $status -Detail $detail `
                -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
        }
        else {
            Set-CheckResult -Check 'DataQuality' -Status 'Error' -Detail 'No quality data returned' `
                -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host '      Error: No quality data returned' -ForegroundColor Red
        }
    }
    catch {
        Set-CheckResult -Check 'DataQuality' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Check 3: Policy Compliance

if (-not $SkipPolicyCompliance) {
    Write-Host '  [3] Governance Policy Compliance' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $policyResults = Test-SPGovernancePolicy -CorrelationID $correlationID

        if ($null -ne $policyResults) {
            $passed = $policyResults.Summary.Passed
            $failed = $policyResults.Summary.Failed
            $total  = $passed + $failed

            $grade = if ($failed -eq 0) { 'A' }
                     elseif ($failed -le 1 -and $total -gt 3) { 'B' }
                     elseif ($failed -le ($total / 3)) { 'C' }
                     elseif ($failed -le ($total / 2)) { 'D' }
                     else { 'F' }

            $detail = "$passed/$total policies passed"
            if ($failed -gt 0) { $detail += " ($failed violations)" }

            $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
            Set-CheckResult -Check 'PolicyCompliance' -Status $status -Detail $detail `
                -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
        }
        else {
            Set-CheckResult -Check 'PolicyCompliance' -Status 'Error' -Detail 'No policy results returned' `
                -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host '      Error: No policy results returned' -ForegroundColor Red
        }
    }
    catch {
        Set-CheckResult -Check 'PolicyCompliance' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Check 4: Configuration Drift

if (-not $SkipConfigDrift) {
    Write-Host '  [4] Configuration Drift' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Find the two most recent snapshots
        $snapshotFiles = @()
        if (Test-Path $effectiveSnapshotPath) {
            $snapshotFiles = @(Get-ChildItem -Path $effectiveSnapshotPath -Filter 'snapshot-*.json' |
                Sort-Object -Property LastWriteTime -Descending |
                Select-Object -First 2)
        }

        if ($snapshotFiles.Count -lt 2) {
            Set-CheckResult -Check 'ConfigDrift' -Status 'Skipped' `
                -Detail "Need 2+ snapshots (found $($snapshotFiles.Count)) in $effectiveSnapshotPath" `
                -Grade '-' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      Skipped: Need 2+ snapshots (found $($snapshotFiles.Count))" -ForegroundColor DarkGray
        }
        else {
            $newerSnapshot = Get-SPConfigurationSnapshot -Path $snapshotFiles[0].FullName -CorrelationID $correlationID
            $olderSnapshot = Get-SPConfigurationSnapshot -Path $snapshotFiles[1].FullName -CorrelationID $correlationID

            # Get-SPConfigurationSnapshot returns hashtable directly on success, or @{Success=$false} on error
            $newerOk = ($null -ne $newerSnapshot -and -not ($newerSnapshot.ContainsKey('Success') -and $newerSnapshot['Success'] -eq $false))
            $olderOk = ($null -ne $olderSnapshot -and -not ($olderSnapshot.ContainsKey('Success') -and $olderSnapshot['Success'] -eq $false))

            if (-not $newerOk -or -not $olderOk) {
                $errDetail = 'Failed to load snapshot files'
                if (-not $newerOk -and $newerSnapshot.ContainsKey('Error')) { $errDetail = $newerSnapshot['Error'] }
                elseif (-not $olderOk -and $olderSnapshot.ContainsKey('Error')) { $errDetail = $olderSnapshot['Error'] }
                Set-CheckResult -Check 'ConfigDrift' -Status 'Error' -Detail $errDetail `
                    -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
                Write-Host "      Error: $errDetail" -ForegroundColor Red
            }
            else {
                $driftResult = Compare-SPConfigurationSnapshots -SnapshotA $olderSnapshot -SnapshotB $newerSnapshot `
                    -CorrelationID $correlationID

                if ($driftResult.Success) {
                    $changeCount = $driftResult.Data.Summary.TotalChanges
                    $grade = if ($changeCount -eq 0) { 'A' }
                             elseif ($changeCount -le 3) { 'B' }
                             elseif ($changeCount -le 10) { 'C' }
                             elseif ($changeCount -le 20) { 'D' }
                             else { 'F' }

                    $detail = "$changeCount change(s) detected"
                    if ($changeCount -eq 0) { $detail = 'No drift detected' }

                    $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
                    Set-CheckResult -Check 'ConfigDrift' -Status $status -Detail $detail `
                        -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
                    Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
                }
                else {
                    Set-CheckResult -Check 'ConfigDrift' -Status 'Error' -Detail $driftResult.Error `
                        -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
                    Write-Host "      Error: $($driftResult.Error)" -ForegroundColor Red
                }
            }
        }
    }
    catch {
        Set-CheckResult -Check 'ConfigDrift' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Check 5: Orphan Accounts

if (-not $SkipOrphanAccounts) {
    Write-Host '  [5] Orphan Account Detection' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $orphanParams = @{ CorrelationID = $correlationID }
        if ($effectiveSourceIds.Count -gt 0) { $orphanParams['SourceIds'] = $effectiveSourceIds }

        $orphanResult = Get-SPOrphanAccounts @orphanParams

        if ($orphanResult.Success) {
            $data = $orphanResult.Data
            $orphanCount = $data.TotalOrphans
            $totalAccts  = $data.TotalAccounts
            $pct = if ($totalAccts -gt 0) { [math]::Round(($orphanCount / $totalAccts) * 100, 1) } else { 0 }

            $grade = if ($pct -eq 0) { 'A' }
                     elseif ($pct -le 2) { 'B' }
                     elseif ($pct -le 5) { 'C' }
                     elseif ($pct -le 10) { 'D' }
                     else { 'F' }

            $detail = "$orphanCount orphan(s) of $totalAccts accounts ($pct%)"
            if ($orphanCount -eq 0) { $detail = 'No orphan accounts detected' }

            $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
            Set-CheckResult -Check 'OrphanAccounts' -Status $status -Detail $detail `
                -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
        }
        else {
            Set-CheckResult -Check 'OrphanAccounts' -Status 'Error' -Detail $orphanResult.Error `
                -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      Error: $($orphanResult.Error)" -ForegroundColor Red
        }
    }
    catch {
        Set-CheckResult -Check 'OrphanAccounts' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Check 6: Campaign Coverage Gaps

if (-not $SkipCoverageGaps) {
    Write-Host '  [6] Campaign Coverage Gaps' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        # Retrieve campaigns for coverage analysis
        $campParams = @{ DaysBack = $DaysBack; CorrelationID = $correlationID }
        $campResult = Get-SPAuditCampaigns @campParams

        if (-not $campResult.Success -or $null -eq $campResult.Data -or $campResult.Data.Count -eq 0) {
            Set-CheckResult -Check 'CoverageGaps' -Status 'Skipped' `
                -Detail "No campaigns found in last $DaysBack days" `
                -Grade '-' -Duration ((Get-Date) - $stepStart).TotalSeconds
            Write-Host "      Skipped: No campaigns found in last $DaysBack days" -ForegroundColor DarkGray
        }
        else {
            # Retrieve entitlement inventory
            $invParams = @{ CorrelationID = $correlationID; IncludeReviewHistory = $true }
            if ($effectiveSourceIds.Count -gt 0) { $invParams['SourceIds'] = $effectiveSourceIds }

            $invResult = Get-SPEntitlementInventory @invParams

            if (-not $invResult.Success) {
                Set-CheckResult -Check 'CoverageGaps' -Status 'Error' `
                    -Detail "Entitlement inventory failed: $($invResult.Error)" `
                    -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
                Write-Host "      Error: Entitlement inventory failed: $($invResult.Error)" -ForegroundColor Red
            }
            else {
                # Build campaign audit hashtables for coverage analysis
                $auditHts = @($campResult.Data | ForEach-Object {
                    @{
                        CampaignId   = $_.id
                        CampaignName = $_.name
                        Status       = if ($null -ne $_.status) { [string]$_.status } else { '' }
                    }
                })

                $gapResult = Get-SPCampaignCoverageGaps -CampaignAudits $auditHts `
                    -EntitlementInventory $invResult.Data -CorrelationID $correlationID

                $neverReviewed = @($gapResult.Gaps | Where-Object { $_.Coverage -eq 'NeverReviewed' }).Count
                $partial       = @($gapResult.Gaps | Where-Object { $_.Coverage -eq 'PartiallyReviewed' }).Count
                $totalEntitlements = $gapResult.Summary.TotalEntitlements

                $gapPct = if ($totalEntitlements -gt 0) {
                    [math]::Round(($neverReviewed / $totalEntitlements) * 100, 1)
                } else { 0 }

                $grade = if ($neverReviewed -eq 0 -and $partial -eq 0) { 'A' }
                         elseif ($gapPct -le 5) { 'B' }
                         elseif ($gapPct -le 15) { 'C' }
                         elseif ($gapPct -le 30) { 'D' }
                         else { 'F' }

                $detail = "$neverReviewed never reviewed, $partial partially reviewed (of $totalEntitlements)"
                if ($neverReviewed -eq 0 -and $partial -eq 0) { $detail = 'Full coverage -- all entitlements reviewed' }

                $status = if ($grade -in @('A', 'B')) { 'Pass' } elseif ($grade -eq 'C') { 'Warn' } else { 'Fail' }
                Set-CheckResult -Check 'CoverageGaps' -Status $status -Detail $detail `
                    -Grade $grade -Duration ((Get-Date) - $stepStart).TotalSeconds
                Write-Host "      $status [$grade]: $detail" -ForegroundColor $(if ($status -eq 'Pass') { 'Green' } elseif ($status -eq 'Warn') { 'Yellow' } else { 'Red' })
            }
        }
    }
    catch {
        Set-CheckResult -Check 'CoverageGaps' -Status 'Error' -Detail $_.Exception.Message `
            -Grade '?' -Duration ((Get-Date) - $stepStart).TotalSeconds
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
}

#endregion

#region Overall Grade Calculation

$activeChecks = @($checkResults.Keys | Where-Object { $checkResults[$_]['Status'] -ne 'Skipped' })
$gradeValues = @{ 'A' = 4; 'B' = 3; 'C' = 2; 'D' = 1; 'F' = 0; '?' = 0; '-' = -1 }

$gradedChecks = @($activeChecks | Where-Object { $checkResults[$_]['Grade'] -ne '?' -and $checkResults[$_]['Grade'] -ne '-' })
$overallGrade = '-'
$overallScore = 0

if ($gradedChecks.Count -gt 0) {
    $totalScore = 0
    foreach ($check in $gradedChecks) {
        $totalScore += $gradeValues[$checkResults[$check]['Grade']]
    }
    $overallScore = [math]::Round($totalScore / $gradedChecks.Count, 2)
    $overallGrade = if ($overallScore -ge 3.5) { 'A' }
                    elseif ($overallScore -ge 2.5) { 'B' }
                    elseif ($overallScore -ge 1.5) { 'C' }
                    elseif ($overallScore -ge 0.5) { 'D' }
                    else { 'F' }
}

$passCount = @($activeChecks | Where-Object { $checkResults[$_]['Status'] -eq 'Pass' }).Count
$warnCount = @($activeChecks | Where-Object { $checkResults[$_]['Status'] -eq 'Warn' }).Count
$failCount = @($activeChecks | Where-Object { $checkResults[$_]['Status'] -eq 'Fail' }).Count
$errorCount = @($activeChecks | Where-Object { $checkResults[$_]['Status'] -eq 'Error' }).Count

#endregion

#region Output

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# Build summary object
$summaryObject = [ordered]@{
    CorrelationID   = $correlationID
    GeneratedAt     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    Duration        = $durationStr
    OverallGrade    = $overallGrade
    OverallScore    = $overallScore
    ChecksPassed    = $passCount
    ChecksWarned    = $warnCount
    ChecksFailed    = $failCount
    ChecksErrored   = $errorCount
    ChecksSkipped   = ($checkResults.Count - $activeChecks.Count)
    Checks          = [ordered]@{}
}

foreach ($check in $checkResults.Keys) {
    $summaryObject['Checks'][$check] = [ordered]@{
        Status   = $checkResults[$check]['Status']
        Grade    = $checkResults[$check]['Grade']
        Detail   = $checkResults[$check]['Detail']
        Duration = $checkResults[$check]['Duration']
    }
}

# Console output
# Display labels for each check -- used by BOTH the Console and HTML blocks below.
# Defined here (not inside the Console block) so an HTML-only run still has it;
# previously the HTML table loop referenced an unset $checkLabels and crashed.
$checkLabels = [ordered]@{
    AggregationHealth = 'Source Aggregation'
    DataQuality       = 'Identity Data Quality'
    PolicyCompliance  = 'Policy Compliance'
    ConfigDrift       = 'Configuration Drift'
    OrphanAccounts    = 'Orphan Accounts'
    CoverageGaps      = 'Campaign Coverage'
}

if ($OutputMode -in @('Console', 'Both')) {
    Write-Host '  =============================================' -ForegroundColor DarkGray
    Write-Host "  OVERALL HEALTH GRADE: $overallGrade" -ForegroundColor $(
        if ($overallGrade -in @('A', 'B')) { 'Green' }
        elseif ($overallGrade -eq 'C') { 'Yellow' }
        elseif ($overallGrade -eq '-') { 'DarkGray' }
        else { 'Red' }
    )
    Write-Host '  =============================================' -ForegroundColor DarkGray
    Write-Host ''

    foreach ($check in $checkResults.Keys) {
        $r = $checkResults[$check]
        $label = ($checkLabels[$check]).PadRight(22)
        $statusIcon = switch ($r['Status']) {
            'Pass'    { 'PASS' }
            'Warn'    { 'WARN' }
            'Fail'    { 'FAIL' }
            'Error'   { 'ERR!' }
            'Skipped' { 'SKIP' }
            default   { '----' }
        }
        $color = switch ($r['Status']) {
            'Pass'    { 'Green' }
            'Warn'    { 'Yellow' }
            'Fail'    { 'Red' }
            'Error'   { 'Red' }
            'Skipped' { 'DarkGray' }
            default   { 'Gray' }
        }
        $gradeDisplay = if ($r['Grade'] -ne '-') { "[$($r['Grade'])]" } else { '[-]' }
        Write-Host "  $statusIcon $gradeDisplay $label $($r['Detail'])" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host "  Passed: $passCount  Warned: $warnCount  Failed: $failCount  Errors: $errorCount" -ForegroundColor DarkGray
    Write-Host "  Duration: $durationStr" -ForegroundColor DarkGray
    Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
    Write-Host ''
}

# HTML output
if ($OutputMode -in @('HTML', 'Both')) {
    if (-not (Test-Path $effectiveOutputPath)) {
        New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
    }

    $htmlFileName = "healthcheck-$($startTime.ToString('yyyyMMdd-HHmmss')).html"
    $htmlFilePath = Join-Path $effectiveOutputPath $htmlFileName

    $gradeColor = switch ($overallGrade) {
        'A' { '#339933' }
        'B' { '#339933' }
        'C' { '#FF9900' }
        'D' { '#CC3333' }
        'F' { '#CC3333' }
        default { '#999999' }
    }

    $checkRowsHtml = ''
    foreach ($check in $checkResults.Keys) {
        $r = $checkResults[$check]
        $rowColor = switch ($r['Status']) {
            'Pass'    { '#339933' }
            'Warn'    { '#FF9900' }
            'Fail'    { '#CC3333' }
            'Error'   { '#CC3333' }
            'Skipped' { '#999999' }
            default   { '#999999' }
        }
        $displayName = $checkLabels[$check]
        $checkRowsHtml += @"
        <tr>
            <td style="padding:8px;border-bottom:1px solid #eee;"><strong>$displayName</strong></td>
            <td style="padding:8px;border-bottom:1px solid #eee;color:$rowColor;font-weight:bold;">$($r['Status'].ToUpper())</td>
            <td style="padding:8px;border-bottom:1px solid #eee;font-weight:bold;">$($r['Grade'])</td>
            <td style="padding:8px;border-bottom:1px solid #eee;">$($r['Detail'])</td>
            <td style="padding:8px;border-bottom:1px solid #eee;color:#666;">$($r['Duration'])s</td>
        </tr>
"@
    }

    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Governance Health Check - $todayLabel</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 900px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        h1 { color: #333; margin-bottom: 5px; }
        .subtitle { color: #666; margin-bottom: 20px; }
        .grade-badge { display: inline-block; font-size: 48px; font-weight: bold; color: $gradeColor; border: 4px solid $gradeColor; border-radius: 12px; padding: 10px 24px; margin: 10px 0 20px 0; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; }
        th { background: #f8f8f8; padding: 10px 8px; text-align: left; border-bottom: 2px solid #ddd; font-size: 13px; text-transform: uppercase; color: #555; }
        .meta { margin-top: 20px; padding-top: 15px; border-top: 1px solid #eee; color: #888; font-size: 12px; }
    </style>
</head>
<body>
<div class="container">
    <h1>Governance Health Check</h1>
    <p class="subtitle">SailPoint ISC Governance Toolkit - $todayLabel</p>
    <div class="grade-badge">$overallGrade</div>
    <p>Passed: <strong>$passCount</strong> | Warned: <strong>$warnCount</strong> | Failed: <strong>$failCount</strong> | Errors: <strong>$errorCount</strong></p>
    <table>
        <tr>
            <th>Check</th>
            <th>Status</th>
            <th>Grade</th>
            <th>Detail</th>
            <th>Duration</th>
        </tr>
$checkRowsHtml
    </table>
    <div class="meta">
        <p>Duration: $durationStr | CorrelationID: $correlationID</p>
        <p>Generated by Invoke-SPGovernanceHealthCheck.ps1 v1.0.0</p>
    </div>
</div>
</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($htmlFilePath, $htmlContent, $utf8NoBom)
    Write-Host "  HTML report: $htmlFilePath" -ForegroundColor DarkGray
}

# JSON output
if ($OutputMode -eq 'JSON') {
    $summaryObject | ConvertTo-Json -Depth 5
}

# JSONL audit trail
try {
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'GovernanceHealthCheck'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            OverallGrade = $overallGrade
            OverallScore = $overallScore
            Passed       = $passCount
            Warned       = $warnCount
            Failed       = $failCount
            Errored      = $errorCount
            Duration     = [math]::Round($totalDuration.TotalSeconds, 1)
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 5 -Compress
    $auditDir = $effectiveOutputPath
    if (-not (Test-Path $auditDir)) {
        New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
    }
    $auditFile = Join-Path $auditDir 'healthcheck-audit.jsonl'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-SPLog -Message "Invoke-SPGovernanceHealthCheck completed: Grade=$overallGrade, Pass=$passCount, Warn=$warnCount, Fail=$failCount, Duration=$durationStr" `
    -Severity INFO -Component 'HealthCheck' -Action 'Complete' -CorrelationID $correlationID

#endregion

# Exit code based on overall grade
$exitCode = switch ($overallGrade) {
    'A' { 0 }
    'B' { 0 }
    'C' { 1 }
    'D' { 5 }
    'F' { 5 }
    default { 0 }
}

if ($errorCount -gt 0 -and $exitCode -lt 5) { $exitCode = 5 }

exit $exitCode
