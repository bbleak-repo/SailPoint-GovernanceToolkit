#Requires -Version 5.1
<#
.SYNOPSIS
    Unified campaign search and analysis tool for SailPoint ISC.
.DESCRIPTION
    Combines all campaign search features into a single CLI:

      - Keyword/type/status/date filtering
      - Deadline urgency classification (-ShowDeadlines)
      - Per-campaign KPI metrics (-ShowMetrics)
      - Reviewer workload analysis (-ReviewerIdentityId)
      - Identity decision history (-IdentityId)
      - Source coverage analysis (-SourceCoverage)
      - Side-by-side campaign comparison (-CompareIds)

    At least one filter or analysis parameter is required. Without any filter
    the script exits with code 2.

    Output modes: Console (tabular), JSON (machine-parseable), CSV (file),
    HTML (styled report).
.PARAMETER Keyword
    Substring search against campaign names. Uses ISC 'co' (contains) filter.
.PARAMETER Type
    Campaign type filter: MANAGER, SOURCE_OWNER, SEARCH, ROLE_COMPOSITION.
    Server-side filter via: type eq "MANAGER".
.PARAMETER Status
    One or more campaign status values. Default: COMPLETED, ACTIVE.
    Valid: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
.PARAMETER CreatedAfter
    Lower bound for campaign creation date (ISO 8601 or DateTime).
    Client-side filter. Takes precedence over -DaysBack.
.PARAMETER CreatedBefore
    Upper bound for campaign creation date (ISO 8601 or DateTime).
    Client-side filter. Takes precedence over -DaysBack.
.PARAMETER DaysBack
    Number of days to look back from now. Default: 90. Ignored when
    -CreatedAfter or -CreatedBefore is specified.
.PARAMETER ShowDeadlines
    Include deadline urgency classification (Overdue/Critical/Warning/OnTrack)
    for each campaign in the results.
.PARAMETER ShowMetrics
    Include per-campaign KPIs (approval rate, completion rate, reviewer count,
    response times) in the results.
.PARAMETER ReviewerIdentityId
    Find all campaigns and certifications assigned to a specific reviewer.
    Returns per-campaign workload counts.
.PARAMETER IdentityId
    Show all access review decisions made about a specific identity across
    all matching campaigns.
.PARAMETER SourceCoverage
    Run source coverage analysis: which ISC sources have been audited by
    campaigns and which have not.
.PARAMETER CompareIds
    Two or more campaign IDs for side-by-side metric comparison.
    Incompatible with other analysis modes.
.PARAMETER OutputMode
    Output format: Console (default), JSON, CSV, HTML.
.PARAMETER OutputPath
    Directory for CSV/HTML output files. Created if absent. Defaults to
    .\SearchResults relative to the toolkit root.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Resolve-SPConfigPath.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials authentication.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -Type MANAGER -CreatedAfter '2026-01-01' -CreatedBefore '2026-03-31'
    # Find all MANAGER campaigns from Q1.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -Status ACTIVE -ShowDeadlines
    # Show deadline urgency for all active campaigns.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -IdentityId 'id-001' -Status COMPLETED -DaysBack 365
    # Find all decisions about a specific identity.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -CompareIds 'camp-001','camp-002' -OutputMode HTML
    # Compare two campaigns side-by-side with HTML output.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -SourceCoverage -DaysBack 365
    # Source coverage analysis for the past year.
.EXAMPLE
    .\Invoke-SPCampaignSearch.ps1 -ReviewerIdentityId 'id-mgr-001' -Status ACTIVE
    # Show reviewer workload for a specific manager.
.NOTES
    Script:  Invoke-SPCampaignSearch.ps1
    Version: 1.0.0
    Exit codes:
        0 = Search completed successfully
        1 = No results matched the search criteria
        2 = Parameter error (missing filter or invalid combination)
        3 = Authentication error (failed to acquire token)
        4 = Configuration error (settings.json missing/invalid/first-run)
        5 = Report generation error
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # --- Filters ---
    [Parameter()]
    [string]$Keyword,

    [Parameter()]
    [ValidateSet('MANAGER', 'SOURCE_OWNER', 'SEARCH', 'ROLE_COMPOSITION')]
    [string]$Type,

    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVATING', 'ACTIVE', 'COMPLETING', 'COMPLETED', 'ERROR')]
    [string[]]$Status,

    [Parameter()]
    [DateTime]$CreatedAfter,

    [Parameter()]
    [DateTime]$CreatedBefore,

    [Parameter()]
    [int]$DaysBack = 90,

    # --- Analysis modes ---
    [Parameter()]
    [switch]$ShowDeadlines,

    [Parameter()]
    [switch]$ShowMetrics,

    [Parameter()]
    [string]$ReviewerIdentityId,

    [Parameter()]
    [string]$IdentityId,

    [Parameter()]
    [switch]$SourceCoverage,

    [Parameter()]
    [string[]]$CompareIds,

    # --- Output ---
    [Parameter()]
    [ValidateSet('Console', 'JSON', 'CSV', 'HTML')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$OutputPath,

    # --- Standard ---
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

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

$coreModulePath  = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath   = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$auditModulePath = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;  Name = 'SP.Core';  Required = $true },
    @{ Path = $apiModulePath;   Name = 'SP.Api';   Required = $true },
    @{ Path = $auditModulePath; Name = 'SP.Audit'; Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $moduleDef.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 4
        }
    }
}

#endregion

#region Parameter Validation

# Determine which mode we are in
$modeCompare  = ($null -ne $CompareIds -and $CompareIds.Count -gt 0)
$modeReviewer = (-not [string]::IsNullOrWhiteSpace($ReviewerIdentityId))
$modeIdentity = (-not [string]::IsNullOrWhiteSpace($IdentityId))
$modeSource   = $SourceCoverage.IsPresent

$hasFilter = $Keyword -or $Type -or $Status -or
    $PSBoundParameters.ContainsKey('CreatedAfter') -or
    $PSBoundParameters.ContainsKey('CreatedBefore') -or
    $PSBoundParameters.ContainsKey('DaysBack')

$hasAnalysis = $modeCompare -or $modeReviewer -or $modeIdentity -or $modeSource

if (-not $hasFilter -and -not $hasAnalysis) {
    Write-Host 'ERROR: At least one filter or analysis parameter is required.' -ForegroundColor Red
    Write-Host '       Filters:  -Keyword, -Type, -Status, -CreatedAfter, -CreatedBefore, -DaysBack' -ForegroundColor Yellow
    Write-Host '       Analysis: -ReviewerIdentityId, -IdentityId, -SourceCoverage, -CompareIds' -ForegroundColor Yellow
    Write-Host '       Example:  .\Invoke-SPCampaignSearch.ps1 -Status COMPLETED -DaysBack 90' -ForegroundColor Yellow
    exit 2
}

# CompareIds requires exactly 2+ IDs
if ($modeCompare -and $CompareIds.Count -lt 2) {
    Write-Host 'ERROR: -CompareIds requires at least 2 campaign IDs.' -ForegroundColor Red
    exit 2
}

# Mutual exclusion: only one analysis mode at a time
$analysisModeCount = @($modeCompare, $modeReviewer, $modeIdentity, $modeSource).Where({ $_ }).Count
if ($analysisModeCount -gt 1) {
    Write-Host 'ERROR: Only one analysis mode allowed at a time: -CompareIds, -ReviewerIdentityId, -IdentityId, or -SourceCoverage.' -ForegroundColor Red
    exit 2
}

# Default status when no status specified
if (-not $Status) {
    $Status = @('COMPLETED', 'ACTIVE')
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Resolve config
if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

# Initialize logging (best-effort before config load)
try { Initialize-SPLogging -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Campaign Search' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '${ConfigPath}': $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host 'INFO: First-run configuration detected. Update settings.json and run again.' -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host 'ERROR: Configuration validation failed. Check settings.json for required values.' -ForegroundColor Red
    exit 4
}

# Re-initialize logging with config
try { Initialize-SPLogging -Force -ErrorAction SilentlyContinue } catch { }

# Inject browser token if provided
if ($Token) {
    Write-Host '  Auth: Injecting browser token...' -ForegroundColor Gray
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

Write-SPLog -Message 'Invoke-SPCampaignSearch started' `
    -Severity INFO -Component 'Invoke-SPCampaignSearch' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
if (-not $OutputPath) {
    $OutputPath = '.\SearchResults'
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = [System.IO.Path]::GetFullPath(
        (Join-Path $toolkitRoot $OutputPath.TrimStart('.\').TrimStart('./'))
    )
}

#endregion

#region WhatIf Support

if ($WhatIfPreference -eq $true) {
    Write-Host '  [WhatIf] Would search campaigns with the following parameters:' -ForegroundColor Yellow
    if ($Keyword)     { Write-Host "    Keyword:      $Keyword" -ForegroundColor Gray }
    if ($Type)        { Write-Host "    Type:         $Type" -ForegroundColor Gray }
    if ($Status)      { Write-Host "    Status:       $($Status -join ', ')" -ForegroundColor Gray }
    if ($PSBoundParameters.ContainsKey('CreatedAfter'))  { Write-Host "    CreatedAfter: $CreatedAfter" -ForegroundColor Gray }
    if ($PSBoundParameters.ContainsKey('CreatedBefore')) { Write-Host "    CreatedBefore: $CreatedBefore" -ForegroundColor Gray }
    if (-not $PSBoundParameters.ContainsKey('CreatedAfter') -and -not $PSBoundParameters.ContainsKey('CreatedBefore')) {
        Write-Host "    DaysBack:     $DaysBack" -ForegroundColor Gray
    }
    if ($modeCompare)  { Write-Host "    CompareIds:   $($CompareIds -join ', ')" -ForegroundColor Gray }
    if ($modeReviewer) { Write-Host "    ReviewerId:   $ReviewerIdentityId" -ForegroundColor Gray }
    if ($modeIdentity) { Write-Host "    IdentityId:   $IdentityId" -ForegroundColor Gray }
    if ($modeSource)   { Write-Host '    SourceCoverage: enabled' -ForegroundColor Gray }
    if ($ShowDeadlines){ Write-Host '    ShowDeadlines: enabled' -ForegroundColor Gray }
    if ($ShowMetrics)  { Write-Host '    ShowMetrics:   enabled' -ForegroundColor Gray }
    Write-Host "    OutputMode:   $OutputMode" -ForegroundColor Gray
    Write-Host "    OutputPath:   $OutputPath" -ForegroundColor Gray
    exit 0
}

#endregion

#region Execute Search

$startTime = Get-Date
$searchResult = $null

# ============================================================
#  MODE 1: Campaign Comparison (CompareIds)
# ============================================================
if ($modeCompare) {
    Write-Host "  Comparing $($CompareIds.Count) campaigns..." -ForegroundColor Gray

    $compareOutputMode = if ($OutputMode -eq 'HTML') { 'HTML' }
                         elseif ($OutputMode -eq 'CSV') { 'CSV' }
                         else { 'Console' }

    $compareParams = @{
        CampaignIds   = $CompareIds
        OutputMode    = $compareOutputMode
        CorrelationID = $correlationID
    }
    if ($compareOutputMode -in @('HTML', 'CSV')) {
        if (-not (Test-Path $OutputPath)) {
            $null = New-Item -ItemType Directory -Path $OutputPath -Force
        }
        $compareParams['OutputPath'] = $OutputPath
    }

    $searchResult = Compare-SPCampaigns @compareParams

    if (-not $searchResult.Success) {
        Write-Host "ERROR: Comparison failed: $($searchResult.Error)" -ForegroundColor Red
        exit 1
    }

    $outputData = $searchResult.Data
    $resultLabel = 'Comparison'
    $resultCount = $CompareIds.Count
}
# ============================================================
#  MODE 2: Reviewer Workload (ReviewerIdentityId)
# ============================================================
elseif ($modeReviewer) {
    Write-Host "  Searching reviewer workload for '$ReviewerIdentityId'..." -ForegroundColor Gray

    $workloadResult = Get-SPReviewerWorkload -ReviewerIdentityId $ReviewerIdentityId `
        -Status $Status -CorrelationID $correlationID

    if (-not $workloadResult.Success) {
        Write-Host "ERROR: Reviewer workload query failed: $($workloadResult.Error)" -ForegroundColor Red
        exit 1
    }

    $outputData = $workloadResult.Data
    $resultLabel = 'Reviewer Workload'
    $resultCount = $workloadResult.Data.TotalCampaigns
}
# ============================================================
#  MODE 3: Identity Decision History (IdentityId)
# ============================================================
elseif ($modeIdentity) {
    Write-Host "  Searching decision history for identity '$IdentityId'..." -ForegroundColor Gray

    $historyParams = @{
        IdentityId    = $IdentityId
        Status        = $Status
        CorrelationID = $correlationID
    }
    if (-not $PSBoundParameters.ContainsKey('CreatedAfter') -and -not $PSBoundParameters.ContainsKey('CreatedBefore')) {
        $historyParams['DaysBack'] = $DaysBack
    }
    else {
        # Use a wide window; date range is on the campaign query inside the function
        $historyParams['DaysBack'] = 3650
    }

    $historyResult = Get-SPIdentityDecisionHistory @historyParams

    if (-not $historyResult.Success) {
        Write-Host "ERROR: Identity decision history failed: $($historyResult.Error)" -ForegroundColor Red
        exit 1
    }

    $outputData = $historyResult.Data
    $resultLabel = 'Identity Decision History'
    $resultCount = $historyResult.Data.TotalDecisions
}
# ============================================================
#  MODE 4: Source Coverage Analysis (SourceCoverage)
# ============================================================
elseif ($modeSource) {
    Write-Host '  Analyzing source coverage...' -ForegroundColor Gray

    $coverageParams = @{
        Status        = $Status
        CorrelationID = $correlationID
    }
    if (-not $PSBoundParameters.ContainsKey('CreatedAfter') -and -not $PSBoundParameters.ContainsKey('CreatedBefore')) {
        $coverageParams['DaysBack'] = $DaysBack
    }
    else {
        $coverageParams['DaysBack'] = 3650
    }

    $coverageResult = Get-SPSourceCampaignCoverage @coverageParams

    if (-not $coverageResult.Success) {
        Write-Host "ERROR: Source coverage analysis failed: $($coverageResult.Error)" -ForegroundColor Red
        exit 1
    }

    $outputData = $coverageResult.Data
    $resultLabel = 'Source Coverage'
    $resultCount = $coverageResult.Data.Summary.TotalSources
}
# ============================================================
#  MODE 5: Standard Campaign Search (default)
# ============================================================
else {
    Write-Host '  Searching campaigns...' -ForegroundColor Gray

    $searchParams = @{
        Status        = $Status
        CorrelationID = $correlationID
    }

    # Name filter -- Keyword maps to CampaignNameContains
    if ($Keyword) {
        $searchParams['CampaignNameContains'] = $Keyword
    }

    # Campaign type filter
    if ($Type) {
        $searchParams['CampaignType'] = $Type
    }

    # Date filtering: explicit range takes precedence over DaysBack
    if ($PSBoundParameters.ContainsKey('CreatedAfter')) {
        $searchParams['CreatedAfter'] = $CreatedAfter
    }
    if ($PSBoundParameters.ContainsKey('CreatedBefore')) {
        $searchParams['CreatedBefore'] = $CreatedBefore
    }
    if (-not $PSBoundParameters.ContainsKey('CreatedAfter') -and -not $PSBoundParameters.ContainsKey('CreatedBefore')) {
        $searchParams['DaysBack'] = $DaysBack
    }

    $campaignResult = Get-SPAuditCampaigns @searchParams

    if (-not $campaignResult.Success) {
        Write-Host "ERROR: Campaign search failed: $($campaignResult.Error)" -ForegroundColor Red
        exit 1
    }

    $campaigns = @($campaignResult.Data)
    if ($campaigns.Count -eq 0) {
        Write-Host '  No campaigns matched the search criteria.' -ForegroundColor Yellow
        Write-SPLog -Message 'No campaigns matched search criteria' `
            -Severity WARN -Component 'Invoke-SPCampaignSearch' -Action 'Search' -CorrelationID $correlationID
        exit 1
    }

    Write-Host "  Found $($campaigns.Count) campaign(s)" -ForegroundColor Green

    # --- Optional: Deadline classification ---
    $deadlineData = $null
    if ($ShowDeadlines) {
        Write-Host '  Classifying deadline urgency...' -ForegroundColor Gray

        $deadlineResult = Get-SPCampaignDeadlineStatus -Status $Status `
            -DaysBack $DaysBack -CorrelationID $correlationID

        if ($deadlineResult.Success) {
            $deadlineData = $deadlineResult.Data

            # Merge DeadlineStatus onto campaign objects
            $deadlineLookup = @{}
            foreach ($bucket in @('Overdue', 'Critical', 'Warning', 'OnTrack', 'Completed', 'NoDeadline')) {
                foreach ($camp in @($deadlineData.$bucket)) {
                    if ($null -ne $camp -and $null -ne $camp.id) {
                        $deadlineLookup[$camp.id] = $bucket
                    }
                }
            }
            foreach ($camp in $campaigns) {
                if ($deadlineLookup.ContainsKey($camp.id)) {
                    $camp | Add-Member -NotePropertyName 'DeadlineStatus' -NotePropertyValue $deadlineLookup[$camp.id] -Force
                }
                else {
                    $camp | Add-Member -NotePropertyName 'DeadlineStatus' -NotePropertyValue 'Unknown' -Force
                }
            }
        }
        else {
            Write-Host "  WARN: Deadline classification failed: $($deadlineResult.Error)" -ForegroundColor Yellow
        }
    }

    # --- Optional: Per-campaign metrics ---
    $metricsData = $null
    if ($ShowMetrics) {
        Write-Host '  Computing campaign metrics...' -ForegroundColor Gray

        $metricsResult = Measure-SPCampaignMetrics -Campaigns $campaigns -CorrelationID $correlationID

        if ($metricsResult.Success) {
            $metricsData = @($metricsResult.Data)
        }
        else {
            Write-Host "  WARN: Metrics computation failed: $($metricsResult.Error)" -ForegroundColor Yellow
        }
    }

    # Build output data
    $outputData = @{
        Campaigns     = $campaigns
        DeadlineData  = $deadlineData
        MetricsData   = $metricsData
    }
    $resultLabel = 'Campaign Search'
    $resultCount = $campaigns.Count
}

$elapsed = ((Get-Date) - $startTime).TotalSeconds

#endregion

#region Output Formatting

Write-Host ''
Write-Host "  $resultLabel -- $resultCount result(s) ($([Math]::Round($elapsed, 1))s)" -ForegroundColor Cyan
Write-Host "  $('=' * 60)" -ForegroundColor DarkGray

# ---- CONSOLE OUTPUT ----
if ($OutputMode -eq 'Console' -or $OutputMode -eq 'JSON') {

    if ($modeCompare -and $null -ne $outputData.ComparisonTable) {
        # Comparison table
        Write-Host ''
        foreach ($row in $outputData.ComparisonTable) {
            $metricLabel = $row.Metric.PadRight(25)
            $values = ($row.PSObject.Properties | Where-Object { $_.Name -ne 'Metric' } |
                ForEach-Object { "$($_.Value)".PadRight(20) }) -join ''
            Write-Host "  $metricLabel $values"
        }
        if ($null -ne $outputData.HtmlPath) {
            Write-Host ''
            Write-Host "  HTML report: $($outputData.HtmlPath)" -ForegroundColor Green
        }
    }
    elseif ($modeReviewer) {
        Write-Host "  Reviewer: $($outputData.ReviewerName) ($($outputData.ReviewerId))" -ForegroundColor White
        Write-Host "  Total Campaigns: $($outputData.TotalCampaigns)  |  Items: $($outputData.TotalItems)  |  Pending: $($outputData.TotalPending)"
        Write-Host ''
        if ($null -ne $outputData.Campaigns -and $outputData.Campaigns.Count -gt 0) {
            Write-Host "  $('Campaign Name'.PadRight(35)) $('Assigned'.PadRight(10)) $('Decided'.PadRight(10)) Pending"
            Write-Host "  $('-' * 65)"
            foreach ($wl in $outputData.Campaigns) {
                $cName = "$($wl.CampaignName)".PadRight(35)
                if ($cName.Length -gt 35) { $cName = $cName.Substring(0, 32) + '...' }
                Write-Host "  $cName $("$($wl.ItemsAssigned)".PadRight(10)) $("$($wl.ItemsDecided)".PadRight(10)) $($wl.ItemsPending)"
            }
        }
    }
    elseif ($modeIdentity) {
        Write-Host "  Identity: $($outputData.IdentityName) ($($outputData.IdentityId))" -ForegroundColor White
        Write-Host "  Total Decisions: $($outputData.TotalDecisions)"
        Write-Host ''
        if ($null -ne $outputData.Campaigns) {
            foreach ($campEntry in $outputData.Campaigns) {
                Write-Host "  Campaign: $($campEntry.CampaignName) ($($campEntry.CampaignDate))" -ForegroundColor White
                if ($null -ne $campEntry.Decisions -and $campEntry.Decisions.Count -gt 0) {
                    foreach ($dec in $campEntry.Decisions) {
                        $decIcon = if ($dec.Decision -eq 'APPROVE') { '[APPROVE]' }
                                   elseif ($dec.Decision -eq 'REVOKE') { '[REVOKE ]' }
                                   else { "[$(($dec.Decision + '        ').Substring(0,7))]" }
                        Write-Host "    $decIcon $($dec.AccessName) -- by $($dec.ReviewerName) ($($dec.DecisionDate))"
                    }
                }
                Write-Host ''
            }
        }
    }
    elseif ($modeSource) {
        $summary = $outputData.Summary
        Write-Host "  Total Sources: $($summary.TotalSources)  |  Covered: $($summary.Covered)  |  Uncovered: $($summary.Uncovered)  |  Rate: $($summary.CoverageRate)%"
        Write-Host ''
        if ($null -ne $outputData.Uncovered -and $outputData.Uncovered.Count -gt 0) {
            Write-Host '  UNCOVERED SOURCES:' -ForegroundColor Yellow
            foreach ($src in $outputData.Uncovered) {
                Write-Host "    - $($src.SourceName) ($($src.SourceId))"
            }
            Write-Host ''
        }
        if ($null -ne $outputData.Covered -and $outputData.Covered.Count -gt 0) {
            Write-Host '  COVERED SOURCES:'
            Write-Host "  $('Source Name'.PadRight(30)) $('Last Campaign'.PadRight(30)) $('Count'.PadRight(6)) Last Date"
            Write-Host "  $('-' * 80)"
            foreach ($src in $outputData.Covered) {
                $sName = "$($src.SourceName)".PadRight(30)
                if ($sName.Length -gt 30) { $sName = $sName.Substring(0, 27) + '...' }
                $cName = "$($src.LastCampaign)".PadRight(30)
                if ($cName.Length -gt 30) { $cName = $cName.Substring(0, 27) + '...' }
                Write-Host "  $sName $cName $("$($src.CampaignCount)".PadRight(6)) $($src.LastCampaignDate)"
            }
        }
    }
    else {
        # Standard campaign search
        $campaigns = $outputData.Campaigns
        $metricsData = $outputData.MetricsData

        Write-Host ''

        if ($ShowMetrics -and $null -ne $metricsData) {
            # Metrics view: show per-campaign KPIs
            Write-Host "  $('Campaign Name'.PadRight(30)) $('Type'.PadRight(14)) $('Status'.PadRight(11)) $('Approve%'.PadRight(9)) $('Revoke%'.PadRight(9)) $('Complete%'.PadRight(10)) Reviewers"
            Write-Host "  $('-' * 93)"

            foreach ($m in $metricsData) {
                $cName = "$($m.CampaignName)".PadRight(30)
                if ($cName.Length -gt 30) { $cName = $cName.Substring(0, 27) + '...' }
                $cType   = "$($m.CampaignType)".PadRight(14)
                $cStatus = "$($m.CampaignStatus)".PadRight(11)
                $aRate   = "$($m.ApprovalRate)".PadRight(9)
                $rRate   = "$($m.RevocationRate)".PadRight(9)
                $compR   = "$($m.CompletionRate)".PadRight(10)
                $revCnt  = "$($m.ReviewerCount)"
                Write-Host "  $cName $cType $cStatus $aRate $rRate $compR $revCnt"
            }
        }
        elseif ($ShowDeadlines) {
            # Deadline view
            Write-Host "  $('Campaign Name'.PadRight(35)) $('Type'.PadRight(14)) $('Status'.PadRight(11)) Deadline Status"
            Write-Host "  $('-' * 75)"

            foreach ($camp in $campaigns) {
                $cName = "$($camp.name)".PadRight(35)
                if ($cName.Length -gt 35) { $cName = $cName.Substring(0, 32) + '...' }
                $cType   = if ($null -ne $camp.type) { "$($camp.type)".PadRight(14) } else { ''.PadRight(14) }
                $cStatus = if ($null -ne $camp.status) { "$($camp.status)".PadRight(11) } else { ''.PadRight(11) }
                $dStatus = if ($null -ne $camp.DeadlineStatus) { $camp.DeadlineStatus } else { 'N/A' }

                $dColor = switch ($dStatus) {
                    'Overdue'   { 'Red' }
                    'Critical'  { 'Red' }
                    'Warning'   { 'Yellow' }
                    'OnTrack'   { 'Green' }
                    'Completed' { 'DarkGray' }
                    default     { 'Gray' }
                }
                Write-Host "  $cName $cType $cStatus " -NoNewline
                Write-Host $dStatus -ForegroundColor $dColor
            }

            # Show summary if available
            if ($null -ne $deadlineData -and $null -ne $deadlineData.Summary) {
                $s = $deadlineData.Summary
                Write-Host ''
                Write-Host "  Summary: Overdue=$($s.Overdue)  Critical=$($s.Critical)  Warning=$($s.Warning)  OnTrack=$($s.OnTrack)  Completed=$($s.Completed)  NoDeadline=$($s.NoDeadline)"
            }
        }
        else {
            # Simple list view
            Write-Host "  $('Campaign Name'.PadRight(35)) $('Type'.PadRight(14)) $('Status'.PadRight(11)) Created"
            Write-Host "  $('-' * 75)"

            foreach ($camp in $campaigns) {
                $cName = "$($camp.name)".PadRight(35)
                if ($cName.Length -gt 35) { $cName = $cName.Substring(0, 32) + '...' }
                $cType   = if ($null -ne $camp.type) { "$($camp.type)".PadRight(14) } else { ''.PadRight(14) }
                $cStatus = if ($null -ne $camp.status) { "$($camp.status)".PadRight(11) } else { ''.PadRight(11) }
                $cDate   = ''
                if ($null -ne $camp.created) {
                    if ($camp.created -is [datetime]) {
                        $cDate = ([datetime]$camp.created).ToUniversalTime().ToString('yyyy-MM-dd')
                    }
                    else {
                        $parsedDate = [datetime]::MinValue
                        if ([datetime]::TryParse($camp.created.ToString(), [ref]$parsedDate)) {
                            $cDate = $parsedDate.ToUniversalTime().ToString('yyyy-MM-dd')
                        }
                        else {
                            $cDate = $camp.created.ToString()
                        }
                    }
                }
                Write-Host "  $cName $cType $cStatus $cDate"
            }
        }
    }
}

# ---- JSON OUTPUT ----
if ($OutputMode -eq 'JSON') {
    Write-Host ''
    $jsonOutput = @{
        CorrelationID = $correlationID
        Mode          = $resultLabel
        ResultCount   = $resultCount
        ElapsedSec    = [Math]::Round($elapsed, 2)
        Data          = $outputData
    }
    $jsonOutput | ConvertTo-Json -Depth 10
}

# ---- CSV OUTPUT ----
if ($OutputMode -eq 'CSV') {
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvFile = Join-Path $OutputPath "CampaignSearch-${timestamp}.csv"

    if (-not $modeCompare -and -not $modeReviewer -and -not $modeIdentity -and -not $modeSource) {
        # Standard campaign search CSV
        $csvRows = [System.Collections.Generic.List[object]]::new()

        if ($ShowMetrics -and $null -ne $outputData.MetricsData) {
            foreach ($m in $outputData.MetricsData) {
                $csvRows.Add([PSCustomObject]@{
                    CampaignName    = $m.CampaignName
                    CampaignId      = $m.CampaignId
                    CampaignType    = $m.CampaignType
                    Status          = $m.CampaignStatus
                    TotalItems      = $m.TotalItems
                    ApprovalRate    = $m.ApprovalRate
                    RevocationRate  = $m.RevocationRate
                    CompletionRate  = $m.CompletionRate
                    ReviewerCount   = $m.ReviewerCount
                    AvgResponseHrs  = $m.AvgResponseTimeHours
                    DeadlineStatus  = $m.DeadlineStatus
                })
            }
        }
        else {
            foreach ($camp in $outputData.Campaigns) {
                $createdStr = ''
                if ($null -ne $camp.created) {
                    if ($camp.created -is [datetime]) {
                        $createdStr = ([datetime]$camp.created).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                    else {
                        $createdStr = $camp.created.ToString()
                    }
                }
                $row = [PSCustomObject]@{
                    CampaignName = $camp.name
                    CampaignId   = $camp.id
                    Type         = $camp.type
                    Status       = $camp.status
                    Created      = $createdStr
                }
                if ($ShowDeadlines -and $null -ne $camp.DeadlineStatus) {
                    $row | Add-Member -NotePropertyName 'DeadlineStatus' -NotePropertyValue $camp.DeadlineStatus
                }
                $csvRows.Add($row)
            }
        }

        $csvRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }
    elseif ($modeReviewer) {
        $reviewerRows = [System.Collections.Generic.List[object]]::new()
        foreach ($wl in $outputData.Campaigns) {
            $reviewerRows.Add([PSCustomObject]@{
                ReviewerName  = $outputData.ReviewerName
                ReviewerId    = $outputData.ReviewerId
                CampaignName  = $wl.CampaignName
                CampaignId    = $wl.CampaignId
                ItemsAssigned = $wl.ItemsAssigned
                ItemsDecided  = $wl.ItemsDecided
                ItemsPending  = $wl.ItemsPending
            })
        }
        $reviewerRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }
    elseif ($modeIdentity) {
        $identityRows = [System.Collections.Generic.List[object]]::new()
        foreach ($campEntry in $outputData.Campaigns) {
            foreach ($dec in $campEntry.Decisions) {
                $identityRows.Add([PSCustomObject]@{
                    IdentityName  = $outputData.IdentityName
                    IdentityId    = $outputData.IdentityId
                    CampaignName  = $campEntry.CampaignName
                    CampaignDate  = $campEntry.CampaignDate
                    AccessName    = $dec.AccessName
                    Decision      = $dec.Decision
                    ReviewerName  = $dec.ReviewerName
                    DecisionDate  = $dec.DecisionDate
                })
            }
        }
        $identityRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }
    elseif ($modeSource) {
        $sourceRows = [System.Collections.Generic.List[object]]::new()
        foreach ($src in $outputData.Covered) {
            $sourceRows.Add([PSCustomObject]@{
                SourceName       = $src.SourceName
                SourceId         = $src.SourceId
                CoverageStatus   = 'Covered'
                LastCampaign     = $src.LastCampaign
                LastCampaignDate = $src.LastCampaignDate
                CampaignCount    = $src.CampaignCount
            })
        }
        foreach ($src in $outputData.Uncovered) {
            $sourceRows.Add([PSCustomObject]@{
                SourceName       = $src.SourceName
                SourceId         = $src.SourceId
                CoverageStatus   = 'Uncovered'
                LastCampaign     = ''
                LastCampaignDate = ''
                CampaignCount    = 0
            })
        }
        $sourceRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }
    elseif ($modeCompare -and $null -ne $outputData.ComparisonTable) {
        $outputData.ComparisonTable | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }

    Write-Host "  CSV written: $csvFile" -ForegroundColor Green
}

# ---- HTML OUTPUT ----
if ($OutputMode -eq 'HTML') {
    if (-not (Test-Path $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }

    if ($modeCompare) {
        # Comparison HTML is handled by Compare-SPCampaigns directly
        if ($null -ne $outputData.HtmlPath) {
            Write-Host "  HTML report: $($outputData.HtmlPath)" -ForegroundColor Green
        }
        else {
            Write-Host '  WARN: HTML comparison report was not generated.' -ForegroundColor Yellow
        }
    }
    else {
        # Generate a simple HTML search results report
        $timestamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $htmlFile    = Join-Path $OutputPath "CampaignSearch-${timestamp}.html"

        $htmlBody = [System.Text.StringBuilder]::new()
        [void]$htmlBody.AppendLine('<!DOCTYPE html>')
        [void]$htmlBody.AppendLine('<html><head><meta charset="utf-8"/>')
        [void]$htmlBody.AppendLine("<title>Campaign Search Results - $generatedAt</title>")
        [void]$htmlBody.AppendLine('<style>')
        [void]$htmlBody.AppendLine('body { font-family: Calibri, Arial, sans-serif; margin: 20px; color: #333; }')
        [void]$htmlBody.AppendLine('h1 { color: #336699; font-size: 18pt; }')
        [void]$htmlBody.AppendLine('h2 { color: #336699; font-size: 14pt; margin-top: 20px; }')
        [void]$htmlBody.AppendLine('table { border-collapse: collapse; width: 100%; margin-top: 10px; }')
        [void]$htmlBody.AppendLine('th { background: #336699; color: white; padding: 8px 12px; text-align: left; font-size: 10pt; }')
        [void]$htmlBody.AppendLine('td { padding: 6px 12px; border-bottom: 1px solid #ddd; font-size: 10pt; }')
        [void]$htmlBody.AppendLine('tr:nth-child(even) { background: #f5f8fc; }')
        [void]$htmlBody.AppendLine('.overdue { color: #CC3333; font-weight: bold; }')
        [void]$htmlBody.AppendLine('.critical { color: #CC3333; font-weight: bold; }')
        [void]$htmlBody.AppendLine('.warning { color: #CC8800; font-weight: bold; }')
        [void]$htmlBody.AppendLine('.ontrack { color: #339933; }')
        [void]$htmlBody.AppendLine('.footer { margin-top: 20px; font-size: 8pt; color: #999; }')
        [void]$htmlBody.AppendLine('</style></head><body>')
        [void]$htmlBody.AppendLine("<h1>Campaign Search Results</h1>")
        [void]$htmlBody.AppendLine("<p>Generated: $generatedAt | CorrelationID: $correlationID | Mode: $resultLabel | Results: $resultCount</p>")

        if ($modeReviewer) {
            [void]$htmlBody.AppendLine("<h2>Reviewer Workload: $([System.Net.WebUtility]::HtmlEncode($outputData.ReviewerName))</h2>")
            [void]$htmlBody.AppendLine("<p>Total Campaigns: $($outputData.TotalCampaigns) | Items: $($outputData.TotalItems) | Pending: $($outputData.TotalPending)</p>")
            [void]$htmlBody.AppendLine('<table><tr><th>Campaign</th><th>Assigned</th><th>Decided</th><th>Pending</th></tr>')
            foreach ($wl in $outputData.Campaigns) {
                [void]$htmlBody.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($wl.CampaignName))</td><td>$($wl.ItemsAssigned)</td><td>$($wl.ItemsDecided)</td><td>$($wl.ItemsPending)</td></tr>")
            }
            [void]$htmlBody.AppendLine('</table>')
        }
        elseif ($modeIdentity) {
            [void]$htmlBody.AppendLine("<h2>Decision History: $([System.Net.WebUtility]::HtmlEncode($outputData.IdentityName))</h2>")
            [void]$htmlBody.AppendLine("<p>Total Decisions: $($outputData.TotalDecisions)</p>")
            foreach ($campEntry in $outputData.Campaigns) {
                [void]$htmlBody.AppendLine("<h2>$([System.Net.WebUtility]::HtmlEncode($campEntry.CampaignName)) ($($campEntry.CampaignDate))</h2>")
                [void]$htmlBody.AppendLine('<table><tr><th>Access</th><th>Decision</th><th>Reviewer</th><th>Date</th></tr>')
                foreach ($dec in $campEntry.Decisions) {
                    [void]$htmlBody.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($dec.AccessName))</td><td>$($dec.Decision)</td><td>$([System.Net.WebUtility]::HtmlEncode($dec.ReviewerName))</td><td>$($dec.DecisionDate)</td></tr>")
                }
                [void]$htmlBody.AppendLine('</table>')
            }
        }
        elseif ($modeSource) {
            $summary = $outputData.Summary
            [void]$htmlBody.AppendLine("<h2>Source Coverage Analysis</h2>")
            [void]$htmlBody.AppendLine("<p>Total: $($summary.TotalSources) | Covered: $($summary.Covered) | Uncovered: $($summary.Uncovered) | Rate: $($summary.CoverageRate)%</p>")

            if ($outputData.Uncovered.Count -gt 0) {
                [void]$htmlBody.AppendLine('<h2>Uncovered Sources</h2>')
                [void]$htmlBody.AppendLine('<table><tr><th>Source Name</th><th>Source ID</th></tr>')
                foreach ($src in $outputData.Uncovered) {
                    [void]$htmlBody.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($src.SourceName))</td><td>$($src.SourceId)</td></tr>")
                }
                [void]$htmlBody.AppendLine('</table>')
            }

            [void]$htmlBody.AppendLine('<h2>Covered Sources</h2>')
            [void]$htmlBody.AppendLine('<table><tr><th>Source</th><th>Last Campaign</th><th>Count</th><th>Last Date</th></tr>')
            foreach ($src in $outputData.Covered) {
                [void]$htmlBody.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($src.SourceName))</td><td>$([System.Net.WebUtility]::HtmlEncode($src.LastCampaign))</td><td>$($src.CampaignCount)</td><td>$($src.LastCampaignDate)</td></tr>")
            }
            [void]$htmlBody.AppendLine('</table>')
        }
        else {
            # Standard campaign search HTML
            $campList = $outputData.Campaigns

            if ($ShowMetrics -and $null -ne $outputData.MetricsData) {
                [void]$htmlBody.AppendLine('<table><tr><th>Campaign</th><th>Type</th><th>Status</th><th>Items</th><th>Approve%</th><th>Revoke%</th><th>Complete%</th><th>Reviewers</th><th>Avg Resp (hrs)</th></tr>')
                foreach ($m in $outputData.MetricsData) {
                    [void]$htmlBody.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($m.CampaignName))</td><td>$($m.CampaignType)</td><td>$($m.CampaignStatus)</td><td>$($m.TotalItems)</td><td>$($m.ApprovalRate)</td><td>$($m.RevocationRate)</td><td>$($m.CompletionRate)</td><td>$($m.ReviewerCount)</td><td>$($m.AvgResponseTimeHours)</td></tr>")
                }
                [void]$htmlBody.AppendLine('</table>')
            }
            else {
                $hasDeadline = $ShowDeadlines
                $headerRow = '<tr><th>Campaign</th><th>Type</th><th>Status</th><th>Created</th>'
                if ($hasDeadline) { $headerRow += '<th>Deadline Status</th>' }
                $headerRow += '</tr>'
                [void]$htmlBody.AppendLine("<table>$headerRow")

                foreach ($camp in $campList) {
                    $createdStr = ''
                    if ($null -ne $camp.created) {
                        if ($camp.created -is [datetime]) {
                            $createdStr = ([datetime]$camp.created).ToUniversalTime().ToString('yyyy-MM-dd')
                        }
                        else {
                            $createdStr = $camp.created.ToString()
                        }
                    }
                    $row = "<tr><td>$([System.Net.WebUtility]::HtmlEncode($camp.name))</td><td>$($camp.type)</td><td>$($camp.status)</td><td>$createdStr</td>"
                    if ($hasDeadline) {
                        $dStatus = if ($null -ne $camp.DeadlineStatus) { $camp.DeadlineStatus } else { 'N/A' }
                        $dClass = switch ($dStatus) {
                            'Overdue'  { 'overdue' }
                            'Critical' { 'critical' }
                            'Warning'  { 'warning' }
                            'OnTrack'  { 'ontrack' }
                            default    { '' }
                        }
                        $row += "<td class=""$dClass"">$dStatus</td>"
                    }
                    $row += '</tr>'
                    [void]$htmlBody.AppendLine($row)
                }
                [void]$htmlBody.AppendLine('</table>')
            }
        }

        [void]$htmlBody.AppendLine("<p class=""footer"">SailPoint ISC Governance Toolkit - Campaign Search | CorrelationID: $correlationID</p>")
        [void]$htmlBody.AppendLine('</body></html>')

        $htmlBody.ToString() | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
        Write-Host "  HTML report: $htmlFile" -ForegroundColor Green
    }
}

#endregion

#region Completion

Write-Host ''
Write-SPLog -Message "Invoke-SPCampaignSearch completed ($resultLabel, $resultCount results, ${elapsed}s)" `
    -Severity INFO -Component 'Invoke-SPCampaignSearch' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
