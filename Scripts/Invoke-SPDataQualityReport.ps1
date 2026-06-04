#Requires -Version 5.1
<#
.SYNOPSIS
    Comprehensive data quality assessment combining orphan account detection,
    identity attribute quality, and source aggregation health.
.DESCRIPTION
    Orchestrates three data quality dimensions into a unified report:
    - Source Aggregation Health (P16-02): Are sources connected and syncing?
    - Orphan Account Detection (P16-01): Are there ungoverned accounts?
    - Identity Attribute Quality (P16-03): Is identity data complete?

    Produces a composite data quality score (weighted average) and grade.
    Designed for scheduled execution or on-demand assessment.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Browser/PAT token for ISC API authentication.
.PARAMETER TokenExpiryMinutes
    Token validity window in minutes. Default 10.
.PARAMETER SourceId
    Source IDs to assess. If omitted, checks all enabled sources.
.PARAMETER SkipOrphanAccounts
    Skip orphan account detection section.
.PARAMETER SkipIdentityQuality
    Skip identity attribute quality section.
.PARAMETER SkipAggregationHealth
    Skip source aggregation health section.
.PARAMETER IdentityLimit
    Maximum identities to evaluate for quality scoring. Default 500.
.PARAMETER MaxStalenessHours
    Hours after which a source is considered stale. Default 48.
.PARAMETER OutputMode
    Output format: Console, HTML, JSON, or Both (Console + HTML). Default Console.
.PARAMETER OutputPath
    Directory for HTML/JSON output files.
.PARAMETER SendNotification
    Send notification if composite grade is D or F.
.PARAMETER NotifyRecipients
    Email addresses for notification delivery.
.PARAMETER Help
    Display detailed help.
.PARAMETER WhatIf
    Show what would be checked without making API calls.
.EXAMPLE
    .\Invoke-SPDataQualityReport.ps1 -SourceId 'src-ad-001','src-entra-001' -Token $token
    # Run full data quality assessment for specified sources.
.EXAMPLE
    .\Invoke-SPDataQualityReport.ps1 -SkipOrphanAccounts -OutputMode Both -OutputPath '.\Audit'
    # Skip orphan detection, output to console and HTML.
.EXAMPLE
    .\Invoke-SPDataQualityReport.ps1 -WhatIf
    # Dry run -- shows what would be checked without API calls.
.NOTES
    Script:  Invoke-SPDataQualityReport.ps1
    Version: 1.0.0
    Phase:   P16-08
    Exit codes:
        0 = Grade A or B, no critical issues
        1 = Grade C, warnings present
        2 = Parameter error
        3 = Authentication error
        4 = Configuration error
        5 = Grade D or F, critical data quality issues
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [string[]]$SourceId,

    # Section toggles
    [Parameter()]
    [switch]$SkipOrphanAccounts,

    [Parameter()]
    [switch]$SkipIdentityQuality,

    [Parameter()]
    [switch]$SkipAggregationHealth,

    # Tuning
    [Parameter()]
    [int]$IdentityLimit = 500,

    [Parameter()]
    [int]$MaxStalenessHours = 48,

    # Output
    [Parameter()]
    [ValidateSet('Console', 'HTML', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    # Notification
    [Parameter()]
    [switch]$SendNotification,

    [Parameter()]
    [string[]]$NotifyRecipients,

    [Parameter()]
    [Alias('?')]
    [switch]$Help,

    # Note: -WhatIf is provided automatically by SupportsShouldProcess
    # but we accept it explicitly so we can pass it through to sub-steps
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
Write-Host '  Data Quality Report' -ForegroundColor Cyan
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

Write-SPLog -Message "Invoke-SPDataQualityReport started: CorrelationID=$correlationID" `
    -Severity INFO -Component 'DataQualityReport' -Action 'Start' -CorrelationID $correlationID

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

# Resolve effective source IDs from config
$effectiveSourceIds = $SourceId
if (-not $effectiveSourceIds -or $effectiveSourceIds.Count -eq 0) {
    if ($null -ne $config.PSObject.Properties['DeltaCert'] -and
        $null -ne $config.DeltaCert -and
        $null -ne $config.DeltaCert.PSObject.Properties['SourceIds'] -and
        $config.DeltaCert.SourceIds.Count -gt 0) {
        $effectiveSourceIds = @($config.DeltaCert.SourceIds)
    }
}

# WhatIf detection
$isWhatIf = ($WhatIfPreference -eq $true) -or $WhatIf

if ($isWhatIf) {
    Write-Host '  === WhatIf Mode ===' -ForegroundColor Yellow
    Write-Host '  The following checks would be performed:' -ForegroundColor Yellow
    Write-Host ''
    if (-not $SkipAggregationHealth) {
        $srcDisplay = if ($effectiveSourceIds) { $effectiveSourceIds -join ', ' } else { 'all enabled sources' }
        Write-Host "  [1] Source Aggregation Health: $srcDisplay (staleness: ${MaxStalenessHours}h)" -ForegroundColor Gray
    }
    else {
        Write-Host '  [1] Source Aggregation Health: SKIPPED' -ForegroundColor DarkGray
    }
    if (-not $SkipOrphanAccounts) {
        $srcDisplay = if ($effectiveSourceIds) { $effectiveSourceIds -join ', ' } else { 'all enabled sources' }
        Write-Host "  [2] Orphan Account Detection:  $srcDisplay" -ForegroundColor Gray
    }
    else {
        Write-Host '  [2] Orphan Account Detection:  SKIPPED' -ForegroundColor DarkGray
    }
    if (-not $SkipIdentityQuality) {
        Write-Host "  [3] Identity Attribute Quality: up to $IdentityLimit identities (active only)" -ForegroundColor Gray
    }
    else {
        Write-Host '  [3] Identity Attribute Quality: SKIPPED' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

#endregion

#region Step Tracking

$stepResults = [ordered]@{
    AggregationHealth = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    OrphanAccounts    = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    IdentityQuality   = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
    CompositeScore    = @{ Status = 'Skipped'; Detail = ''; Duration = 0 }
}

$worstExitCode = 0

function Set-StepResult {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Detail,
        [double]$Duration
    )
    $stepResults[$Step] = @{ Status = $Status; Detail = $Detail; Duration = $Duration }
}

# Data holders for each section
$aggHealthData = $null
$orphanData    = $null
$qualityData   = $null

#endregion

#region Step 1: Source Aggregation Health

if (-not $SkipAggregationHealth) {
    Write-Host '  Step 1: Source Aggregation Health' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $aggParams = @{
            MaxAcceptableStalenessHours = $MaxStalenessHours
            CorrelationID              = $correlationID
        }
        if ($effectiveSourceIds -and $effectiveSourceIds.Count -gt 0) {
            $aggParams['SourceIds'] = $effectiveSourceIds
        }

        $aggHealthData = Get-SPSourceAggregationHealth @aggParams
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($aggHealthData -and $aggHealthData.Summary) {
            $s = $aggHealthData.Summary
            $detail = "Healthy: $($s.Healthy) | Warning: $($s.Warning) | Critical: $($s.Critical)"
            Set-StepResult -Step 'AggregationHealth' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 1: $detail" -ForegroundColor Green
        }
        else {
            Set-StepResult -Step 'AggregationHealth' -Status 'Warning' -Detail 'No data returned' -Duration $stepDuration
            Write-Host '  Step 1: WARN - No aggregation health data returned' -ForegroundColor Yellow
            Write-SPLog -Message 'Source aggregation health returned no data' `
                -Severity WARN -Component 'DataQualityReport' -Action 'AggregationHealthWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'AggregationHealth' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 1: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Source aggregation health exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DataQualityReport' -Action 'AggregationHealthError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 1: Source Aggregation Health [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 2: Orphan Account Detection

if (-not $SkipOrphanAccounts) {
    Write-Host '  Step 2: Orphan Account Detection' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        if (-not $effectiveSourceIds -or $effectiveSourceIds.Count -eq 0) {
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
            Set-StepResult -Step 'OrphanAccounts' -Status 'Warning' -Detail 'No source IDs configured' -Duration $stepDuration
            Write-Host '  Step 2: WARN - No source IDs available (provide -SourceId or configure DeltaCert.SourceIds)' -ForegroundColor Yellow
            Write-SPLog -Message 'Orphan account detection skipped: no source IDs' `
                -Severity WARN -Component 'DataQualityReport' -Action 'OrphanAccountsWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
        else {
            $orphanParams = @{
                SourceIds              = $effectiveSourceIds
                IncludeDisabledAccounts = $true
                IncludeServiceAccounts  = $true
                CorrelationID          = $correlationID
            }

            $orphanData = Get-SPOrphanAccounts @orphanParams
            $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

            if ($orphanData -and $orphanData.Summary) {
                $s = $orphanData.Summary
                $pct = if ($s.TotalAccountsScanned -gt 0) {
                    [math]::Round(($s.TotalOrphans / $s.TotalAccountsScanned) * 100, 1)
                } else { 0 }
                $detail = "Scanned: $($s.TotalAccountsScanned) | Orphans: $($s.TotalOrphans) ($pct%)"
                Set-StepResult -Step 'OrphanAccounts' -Status 'Success' -Detail $detail -Duration $stepDuration
                Write-Host "  Step 2: $detail" -ForegroundColor Green
            }
            else {
                Set-StepResult -Step 'OrphanAccounts' -Status 'Warning' -Detail 'No data returned' -Duration $stepDuration
                Write-Host '  Step 2: WARN - No orphan account data returned' -ForegroundColor Yellow
                Write-SPLog -Message 'Orphan account detection returned no data' `
                    -Severity WARN -Component 'DataQualityReport' -Action 'OrphanAccountsWarn' -CorrelationID $correlationID
                if ($worstExitCode -lt 1) { $worstExitCode = 1 }
            }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'OrphanAccounts' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 2: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Orphan account detection exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DataQualityReport' -Action 'OrphanAccountsError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 2: Orphan Account Detection [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 3: Identity Attribute Quality

if (-not $SkipIdentityQuality) {
    Write-Host '  Step 3: Identity Attribute Quality' -ForegroundColor Cyan
    $stepStart = Get-Date

    try {
        $qualityParams = @{
            Limit         = $IdentityLimit
            ActiveOnly    = $true
            CorrelationID = $correlationID
        }

        $qualityData = Measure-SPIdentityDataQuality @qualityParams
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds

        if ($qualityData -and $qualityData.Summary) {
            $s = $qualityData.Summary
            $detail = "Score: $($s.OverallQualityScore) (Grade $($s.OverallQualityGrade)) | Scanned: $($s.TotalIdentitiesScanned)"
            Set-StepResult -Step 'IdentityQuality' -Status 'Success' -Detail $detail -Duration $stepDuration
            Write-Host "  Step 3: $detail" -ForegroundColor Green
        }
        else {
            Set-StepResult -Step 'IdentityQuality' -Status 'Warning' -Detail 'No data returned' -Duration $stepDuration
            Write-Host '  Step 3: WARN - No identity quality data returned' -ForegroundColor Yellow
            Write-SPLog -Message 'Identity data quality returned no data' `
                -Severity WARN -Component 'DataQualityReport' -Action 'IdentityQualityWarn' -CorrelationID $correlationID
            if ($worstExitCode -lt 1) { $worstExitCode = 1 }
        }
    }
    catch {
        $stepDuration = ((Get-Date) - $stepStart).TotalSeconds
        Set-StepResult -Step 'IdentityQuality' -Status 'Warning' -Detail $_.Exception.Message -Duration $stepDuration
        Write-Host "  Step 3: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Identity data quality exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DataQualityReport' -Action 'IdentityQualityError' -CorrelationID $correlationID
        if ($worstExitCode -lt 1) { $worstExitCode = 1 }
    }
    Write-Host ''
}
else {
    Write-Host '  Step 3: Identity Attribute Quality [SKIPPED]' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Step 4: Composite Data Quality Score

Write-Host '  Step 4: Composite Data Quality Score' -ForegroundColor Cyan
$stepStart = Get-Date

# Calculate weighted composite score from available sections
# Aggregation health: 30%, Orphan rate: 30%, Identity quality: 40%
# If a section is skipped/failed, redistribute weight to remaining sections

$sectionScores = [ordered]@{}
$sectionWeights = [ordered]@{}

# Aggregation health score: healthy sources / total sources * 100
if (-not $SkipAggregationHealth -and $null -ne $aggHealthData -and $null -ne $aggHealthData.Summary) {
    $aggSummary = $aggHealthData.Summary
    if ($aggSummary.TotalSources -gt 0) {
        $sectionScores['AggregationHealth'] = [math]::Round(($aggSummary.Healthy / $aggSummary.TotalSources) * 100, 1)
    }
    else {
        $sectionScores['AggregationHealth'] = 100.0
    }
    $sectionWeights['AggregationHealth'] = 30
}

# Orphan rate score: (1 - orphans / total) * 100
if (-not $SkipOrphanAccounts -and $null -ne $orphanData -and $null -ne $orphanData.Summary) {
    $orphanSummary = $orphanData.Summary
    if ($orphanSummary.TotalAccountsScanned -gt 0) {
        $sectionScores['OrphanRate'] = [math]::Round((1 - ($orphanSummary.TotalOrphans / $orphanSummary.TotalAccountsScanned)) * 100, 1)
    }
    else {
        $sectionScores['OrphanRate'] = 100.0
    }
    $sectionWeights['OrphanRate'] = 30
}

# Identity quality score: direct from Measure-SPIdentityDataQuality
if (-not $SkipIdentityQuality -and $null -ne $qualityData -and $null -ne $qualityData.Summary) {
    $sectionScores['IdentityQuality'] = [math]::Round([double]$qualityData.Summary.OverallQualityScore, 1)
    $sectionWeights['IdentityQuality'] = 40
}

# Calculate weighted average
$compositeScore = 0.0
$compositeGrade = 'N/A'
$totalWeight = 0
$hasSections = $false

foreach ($section in $sectionScores.Keys) {
    $totalWeight += $sectionWeights[$section]
    $hasSections = $true
}

if ($hasSections -and $totalWeight -gt 0) {
    $weightedSum = 0.0
    foreach ($section in $sectionScores.Keys) {
        $normalizedWeight = $sectionWeights[$section] / $totalWeight
        $weightedSum += $sectionScores[$section] * $normalizedWeight
    }
    $compositeScore = [math]::Round($weightedSum, 1)

    # Grade assignment
    $compositeGrade = if ($compositeScore -ge 90) { 'A' }
        elseif ($compositeScore -ge 80) { 'B' }
        elseif ($compositeScore -ge 70) { 'C' }
        elseif ($compositeScore -ge 60) { 'D' }
        else { 'F' }
}

# Count critical issues
$criticalIssues = 0
if ($null -ne $aggHealthData -and $null -ne $aggHealthData.Summary -and $aggHealthData.Summary.Critical -gt 0) {
    $criticalIssues += $aggHealthData.Summary.Critical
}

$stepDuration = ((Get-Date) - $stepStart).TotalSeconds
$compositeDetail = "Score: $compositeScore (Grade $compositeGrade) | Sections: $($sectionScores.Count)/3"
Set-StepResult -Step 'CompositeScore' -Status 'Success' -Detail $compositeDetail -Duration $stepDuration
Write-Host "  Step 4: $compositeDetail" -ForegroundColor Green
Write-Host ''

# Set exit code based on composite grade
if ($compositeGrade -eq 'D' -or $compositeGrade -eq 'F') {
    $worstExitCode = 5
}
elseif ($compositeGrade -eq 'C' -and $worstExitCode -lt 1) {
    $worstExitCode = 1
}

#endregion

#region Step 5: Report Generation

# HTML report generation
$htmlFiles = @()
if ($OutputMode -eq 'HTML' -or $OutputMode -eq 'Both') {
    Write-Host '  Step 5: HTML Report Generation' -ForegroundColor Cyan

    if ($null -ne $aggHealthData) {
        try {
            $htmlPath = Export-SPSourceAggregationHealthHtml -HealthData $aggHealthData `
                -OutputPath $effectiveOutputPath -CorrelationID $correlationID
            $htmlFiles += $htmlPath
            Write-Host "  - Aggregation Health: $htmlPath" -ForegroundColor Gray
        }
        catch {
            Write-Host "  - Aggregation Health HTML: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($null -ne $orphanData) {
        try {
            $htmlPath = Export-SPOrphanAccountHtml -OrphanData $orphanData `
                -OutputPath $effectiveOutputPath -CorrelationID $correlationID
            $htmlFiles += $htmlPath
            Write-Host "  - Orphan Accounts:    $htmlPath" -ForegroundColor Gray
        }
        catch {
            Write-Host "  - Orphan Accounts HTML: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($null -ne $qualityData) {
        try {
            $htmlPath = Export-SPIdentityDataQualityHtml -QualityData $qualityData `
                -OutputPath $effectiveOutputPath -CorrelationID $correlationID
            $htmlFiles += $htmlPath
            Write-Host "  - Identity Quality:   $htmlPath" -ForegroundColor Gray
        }
        catch {
            Write-Host "  - Identity Quality HTML: WARN - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host ''
}

#endregion

#region Step 6: Notification

if ($SendNotification -and ($compositeGrade -eq 'D' -or $compositeGrade -eq 'F')) {
    Write-Host '  Step 6: Notification (Grade D/F detected)' -ForegroundColor Cyan

    try {
        $notifyParams = @{
            Subject   = "Data Quality Alert: Grade $compositeGrade (Score $compositeScore)"
            Body      = "Data quality composite score $compositeScore (Grade $compositeGrade) detected. Review the data quality report for details."
            Severity  = 'Critical'
            Category  = 'DataQuality'
            CorrelationID = $correlationID
        }
        if ($NotifyRecipients -and $NotifyRecipients.Count -gt 0) {
            $notifyParams['Recipients'] = $NotifyRecipients
        }
        if ($htmlFiles.Count -gt 0) {
            $notifyParams['Attachments'] = $htmlFiles
        }

        $notifyResult = Send-SPNotification @notifyParams
        if ($notifyResult.Success) {
            Write-Host "  Step 6: Notification sent via $($notifyResult.Data.Backends -join ', ')" -ForegroundColor Green
        }
        else {
            Write-Host "  Step 6: WARN - Notification: $($notifyResult.Error)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  Step 6: WARN - Notification failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SPLog -Message "Notification exception: $($_.Exception.Message)" `
            -Severity WARN -Component 'DataQualityReport' -Action 'NotificationError' -CorrelationID $correlationID
    }
    Write-Host ''
}

#endregion

#region Summary

$endTime = Get-Date
$totalDuration = ($endTime - $startTime)
$durationStr = '{0}m {1:00}s' -f [int][math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

# Determine overall result label
$overallResult = switch ($compositeGrade) {
    'A' { 'DATA QUALITY EXCELLENT (Grade A)' }
    'B' { "DATA QUALITY GOOD (Grade B, $criticalIssues critical issues)" }
    'C' { "DATA QUALITY ACCEPTABLE (Grade C, warnings present)" }
    'D' { "DATA QUALITY POOR (Grade D, governance impact likely)" }
    'F' { "DATA QUALITY CRITICAL (Grade F, governance unreliable)" }
    default { "DATA QUALITY UNKNOWN (insufficient data)" }
}

# Console summary
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'Both') {
    Write-Host '  === Data Quality Report ===' -ForegroundColor Cyan
    Write-Host "  Timestamp:   $($startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    if ($effectiveSourceIds) {
        Write-Host "  Sources:     $($effectiveSourceIds -join ', ')"
    }
    else {
        Write-Host '  Sources:     all enabled'
    }
    Write-Host ''

    # Aggregation health section
    if (-not $SkipAggregationHealth -and $null -ne $aggHealthData -and $null -ne $aggHealthData.Summary) {
        $s = $aggHealthData.Summary
        Write-Host '  --- Source Aggregation Health ---'
        Write-Host "    Healthy: $($s.Healthy) | Warning: $($s.Warning) | Critical: $($s.Critical)"
        $avgFreshness = if ($null -ne $s.AvgFreshnessHours) { "$($s.AvgFreshnessHours) hours" } else { 'N/A' }
        Write-Host "    Avg Data Freshness: $avgFreshness"
        Write-Host ''
    }

    # Orphan accounts section
    if (-not $SkipOrphanAccounts -and $null -ne $orphanData -and $null -ne $orphanData.Summary) {
        $s = $orphanData.Summary
        $pct = if ($s.TotalAccountsScanned -gt 0) {
            [math]::Round(($s.TotalOrphans / $s.TotalAccountsScanned) * 100, 1)
        } else { 0 }
        Write-Host '  --- Orphan Accounts ---'
        Write-Host "    Total Scanned: $($s.TotalAccountsScanned.ToString('N0')) | Orphans: $($s.TotalOrphans) ($pct%)"
        Write-Host "    Uncorrelated: $($s.Uncorrelated) | Terminated Owner: $($s.TerminatedOwner) | Dangling: $($s.DanglingReference)"
        Write-Host ''
    }

    # Identity quality section
    if (-not $SkipIdentityQuality -and $null -ne $qualityData -and $null -ne $qualityData.Summary) {
        $s = $qualityData.Summary
        Write-Host '  --- Identity Attribute Quality ---'
        Write-Host "    Score: $($s.OverallQualityScore) (Grade $($s.OverallQualityGrade)) | Identities Scanned: $($s.TotalIdentitiesScanned)"
        Write-Host "    Worst: $($s.WorstAttribute) ($($s.WorstAttributePct)%) | Issues: $($s.IdentitiesWithIssues) identities"
        Write-Host ''
    }

    # Composite section
    Write-Host '  --- Composite Data Quality ---'
    Write-Host "    Score: $compositeScore (Grade $compositeGrade)"
    $scoreComponents = @()
    if ($sectionScores.ContainsKey('AggregationHealth')) {
        $scoreComponents += "Aggregation: $($sectionScores['AggregationHealth'])"
    }
    if ($sectionScores.ContainsKey('OrphanRate')) {
        $scoreComponents += "Orphan Rate: $($sectionScores['OrphanRate'])"
    }
    if ($sectionScores.ContainsKey('IdentityQuality')) {
        $scoreComponents += "Identity: $($sectionScores['IdentityQuality'])"
    }
    if ($scoreComponents.Count -gt 0) {
        Write-Host "    $($scoreComponents -join ' | ')"
    }
    Write-Host ''

    # Result
    $resultColor = if ($worstExitCode -eq 0) { 'Green' }
        elseif ($worstExitCode -le 1) { 'Yellow' }
        else { 'Red' }
    Write-Host "  Result: $overallResult" -ForegroundColor $resultColor
    Write-Host "  Duration: $durationStr"
    Write-Host ''
}

# JSON output
$summaryObject = [ordered]@{
    Timestamp       = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CorrelationID   = $correlationID
    DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
    Duration        = $durationStr
    Sources         = $effectiveSourceIds
    Sections        = [ordered]@{
        AggregationHealth = if ($null -ne $aggHealthData -and $null -ne $aggHealthData.Summary) { $aggHealthData.Summary } else { $null }
        OrphanAccounts    = if ($null -ne $orphanData -and $null -ne $orphanData.Summary) { $orphanData.Summary } else { $null }
        IdentityQuality   = if ($null -ne $qualityData -and $null -ne $qualityData.Summary) { $qualityData.Summary } else { $null }
    }
    Composite       = [ordered]@{
        Score       = $compositeScore
        Grade       = $compositeGrade
        Components  = $sectionScores
        Weights     = $sectionWeights
    }
    Steps           = $stepResults
    Result          = $overallResult
    ExitCode        = $worstExitCode
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    $summaryObject | ConvertTo-Json -Depth 5
}

# JSONL audit trail event
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $auditEvent = [ordered]@{
        Timestamp     = $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'DataQualityReport'
        CorrelationID = $correlationID
        Data          = [ordered]@{
            CompositeScore  = $compositeScore
            CompositeGrade  = $compositeGrade
            SectionScores   = $sectionScores
            Steps           = $stepResults
            DurationSeconds = [math]::Round($totalDuration.TotalSeconds, 1)
            ExitCode        = $worstExitCode
        }
    }
    $jsonLine = $auditEvent | ConvertTo-Json -Depth 10 -Compress
    $auditFile = Join-Path $effectiveOutputPath 'data-quality-audit.jsonl'
    [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)
}
catch {
    Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-SPLog -Message "Audit trail write failed: $($_.Exception.Message)" `
        -Severity WARN -Component 'DataQualityReport' -Action 'AuditTrailError' -CorrelationID $correlationID
}

Write-SPLog -Message "Invoke-SPDataQualityReport completed: ExitCode=$worstExitCode Duration=$durationStr Grade=$compositeGrade" `
    -Severity INFO -Component 'DataQualityReport' -Action 'Complete' -CorrelationID $correlationID

#endregion

exit $worstExitCode
