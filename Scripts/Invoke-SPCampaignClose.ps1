#Requires -Version 5.1
<#
.SYNOPSIS
    Find and optionally complete SailPoint ISC certification campaigns.
.DESCRIPTION
    Searches for ISC certification campaigns by name, status, and date filters,
    then displays a summary table of matching campaigns.

    By default (without -SetCompleted) the script is purely READ-ONLY: it lists
    matching campaigns with their name, ID, status, creation date, deadline,
    decided/total items, and completion percentage. No API write calls are made.

    With -SetCompleted, the script calls Complete-SPCampaign for each matching
    campaign. This transitions the campaign to COMPLETED status, causing all
    undecided items to maintain current access (auto-approve). A JSONL audit
    trail entry is written for each completion.

    With -WhatIf -SetCompleted, the script shows what WOULD be completed
    without making any API calls.

    Safety:
      - Requires Safety.AllowCompleteCampaign = true in settings.json
      - If more than 5 campaigns match with -SetCompleted, confirmation is
        required (use -Force to skip)
      - Without -SetCompleted, purely read-only
.PARAMETER CampaignName
    Exact (case-insensitive) campaign name match. Highest precedence among
    name filters.
.PARAMETER CampaignNameStartsWith
    Campaigns whose name begins with this prefix (server-side filter).
    Ignored if -CampaignName is also specified.
.PARAMETER CampaignNameContains
    Substring (contains) match on the campaign name, applied client-side
    and case-insensitively. Ignored if -CampaignName or
    -CampaignNameStartsWith is also specified.
.PARAMETER Status
    One or more campaign status values to filter by.
    Valid: STAGED, ACTIVE, COMPLETING, COMPLETED. Default: ACTIVE.
.PARAMETER DaysBack
    Number of days to look back from now for campaign creation date.
    Default: 1. Set to 0 to disable date filtering.
.PARAMETER SetCompleted
    When specified, calls Complete-SPCampaign for each matching campaign.
    Without this switch the script is read-only.
.PARAMETER Force
    Skip confirmation prompt when -SetCompleted would affect more than 5
    campaigns.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to Resolve-SPConfigPath.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    Bypasses OAuth client_credentials authentication. The "Bearer " prefix
    is stripped automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPCampaignClose.ps1 -Status ACTIVE -DaysBack 7
    # List all ACTIVE campaigns created in the last 7 days.
.EXAMPLE
    .\Invoke-SPCampaignClose.ps1 -CampaignName 'Q1 Manager Review' -SetCompleted
    # Complete the campaign with the exact name 'Q1 Manager Review'.
.EXAMPLE
    .\Invoke-SPCampaignClose.ps1 -CampaignNameContains 'Delta' -Status ACTIVE -SetCompleted -WhatIf
    # Dry-run: show which ACTIVE campaigns containing 'Delta' would be completed.
.EXAMPLE
    .\Invoke-SPCampaignClose.ps1 -Status ACTIVE,STAGED -DaysBack 30 -SetCompleted -Force
    # Complete all ACTIVE and STAGED campaigns from the last 30 days, skipping
    # the confirmation prompt even if more than 5 match.
.NOTES
    Script:  Invoke-SPCampaignClose.ps1
    Version: 1.0.0
    Exit codes:
        0 = Success (listing completed, or campaigns completed successfully)
        1 = No campaigns matched the search criteria
        2 = Parameter error (no filter specified)
        3 = Authentication error (failed to acquire/validate token)
        4 = Configuration error (settings.json missing/invalid/first-run)
        5 = Completion failed (one or more campaigns could not be completed)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$CampaignName,

    [Parameter()]
    [string]$CampaignNameStartsWith,

    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [int]$DaysBack = 1,

    [Parameter()]
    [switch]$SetCompleted,

    [Parameter()]
    [switch]$Force,

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

foreach ($moduleDef in @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';   Name = 'SP.Core';  Required = $true },
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';     Name = 'SP.Api';   Required = $true },
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'; Name = 'SP.Audit'; Required = $true }
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

$hasNameFilter = (-not [string]::IsNullOrWhiteSpace($CampaignName)) -or
                 (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) -or
                 (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))

$hasStatusFilter = ($null -ne $Status -and $Status.Count -gt 0)

if (-not $hasNameFilter -and -not $hasStatusFilter -and -not $PSBoundParameters.ContainsKey('DaysBack')) {
    Write-Host 'ERROR: At least one filter is required.' -ForegroundColor Red
    Write-Host '       Filters:  -CampaignName, -CampaignNameStartsWith, -CampaignNameContains, -Status, -DaysBack' -ForegroundColor Yellow
    Write-Host '       Example:  .\Invoke-SPCampaignClose.ps1 -Status ACTIVE -DaysBack 7' -ForegroundColor Yellow
    exit 2
}

# Default status when none specified
if (-not $hasStatusFilter) {
    $Status = @('ACTIVE')
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try { Initialize-SPLogging -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Campaign Close' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

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

# Build a human-readable description of the name filter in effect
$nameFilterDesc =
    if     (-not [string]::IsNullOrWhiteSpace($CampaignName))           { "name is '$CampaignName'" }
    elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains))   { "name contains '$CampaignNameContains'" }
    elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) { "name starts with '$CampaignNameStartsWith'" }
    else   { '(any name)' }

Write-SPLog -Message "Invoke-SPCampaignClose started: $nameFilterDesc, Status=$($Status -join ','), DaysBack=$DaysBack, SetCompleted=$($SetCompleted.IsPresent)" `
    -Severity INFO -Component 'Invoke-SPCampaignClose' -Action 'Start' -CorrelationID $correlationID

#endregion

#region WhatIf (read-only preview when -SetCompleted -WhatIf)

if (($WhatIfPreference -eq $true) -and -not $SetCompleted.IsPresent) {
    Write-Host '  [WhatIf] Would search campaigns with the following parameters:' -ForegroundColor Yellow
    Write-Host "    Name filter:  $nameFilterDesc" -ForegroundColor Gray
    Write-Host "    Status:       $($Status -join ', ')" -ForegroundColor Gray
    Write-Host "    DaysBack:     $DaysBack" -ForegroundColor Gray
    Write-Host "    SetCompleted: No (read-only listing)" -ForegroundColor Gray
    exit 0
}

#endregion

#region Search Campaigns

$startTime = Get-Date

Write-Host "  Searching campaigns ($nameFilterDesc, status=$($Status -join ','), days=$DaysBack)..." -ForegroundColor Gray

$searchParams = @{
    Status        = $Status
    DaysBack      = $DaysBack
    CorrelationID = $correlationID
}

if (-not [string]::IsNullOrWhiteSpace($CampaignName)) {
    $searchParams['CampaignName'] = $CampaignName
}
elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
    $searchParams['CampaignNameContains'] = $CampaignNameContains
}
elseif (-not [string]::IsNullOrWhiteSpace($CampaignNameStartsWith)) {
    $searchParams['CampaignNameStartsWith'] = $CampaignNameStartsWith
}

$campaignResult = $null
try {
    $campaignResult = Get-SPAuditCampaigns @searchParams
}
catch {
    Write-Host "ERROR: Campaign search failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $campaignResult.Success) {
    Write-Host "ERROR: Campaign search failed: $($campaignResult.Error)" -ForegroundColor Red
    exit 1
}

$campaigns = @($campaignResult.Data)
if ($campaigns.Count -eq 0) {
    Write-Host '  No campaigns matched the search criteria.' -ForegroundColor Yellow
    Write-SPLog -Message 'No campaigns matched search criteria' `
        -Severity WARN -Component 'Invoke-SPCampaignClose' -Action 'Search' -CorrelationID $correlationID
    exit 1
}

$searchElapsed = ((Get-Date) - $startTime).TotalSeconds
Write-Host "  Found $($campaigns.Count) campaign(s) ($([Math]::Round($searchElapsed, 1))s)" -ForegroundColor Green
Write-Host ''

#endregion

#region Display Campaign Table

# Build table rows with campaign details
$tableRows = foreach ($camp in $campaigns) {
    $campName = if ($null -ne $camp.name) { [string]$camp.name } else { '(unknown)' }
    $campId   = if ($null -ne $camp.id)   { [string]$camp.id }   else { '?' }
    $campStatus = if ($null -ne $camp.status) { [string]$camp.status } else { '?' }

    $createdStr = ''
    if ($null -ne $camp.created) {
        try {
            $createdDt = [DateTime]::Parse($camp.created)
            $createdStr = $createdDt.ToString('yyyy-MM-dd')
        }
        catch { $createdStr = [string]$camp.created }
    }

    $deadlineStr = ''
    if ($null -ne $camp.deadline) {
        try {
            $deadlineDt = [DateTime]::Parse($camp.deadline)
            $deadlineStr = $deadlineDt.ToString('yyyy-MM-dd')
        }
        catch { $deadlineStr = [string]$camp.deadline }
    }

    $totalItems   = 0
    $decidedItems = 0
    if ($camp.PSObject.Properties.Name -contains 'totalItems' -and $null -ne $camp.totalItems) {
        $totalItems = [int]$camp.totalItems
    }
    if ($camp.PSObject.Properties.Name -contains 'completedItems' -and $null -ne $camp.completedItems) {
        $decidedItems = [int]$camp.completedItems
    }
    $pendingItems  = [math]::Max(0, $totalItems - $decidedItems)
    $completionPct = if ($totalItems -gt 0) { [math]::Round(($decidedItems / $totalItems) * 100, 1) } else { 0.0 }

    [PSCustomObject]@{
        Name         = $campName
        Id           = $campId
        Status       = $campStatus
        Created      = $createdStr
        Deadline     = $deadlineStr
        Decided      = $decidedItems
        Total        = $totalItems
        Pending      = $pendingItems
        CompletionPct = $completionPct
    }
}

$tableRows = @($tableRows)

# Print table header
$colName     = 'Campaign Name'.PadRight(40)
$colId       = 'ID'.PadRight(38)
$colStatus   = 'Status'.PadRight(12)
$colCreated  = 'Created'.PadRight(12)
$colDeadline = 'Deadline'.PadRight(12)
$colItems    = 'Decided/Total'.PadRight(15)
$colPct      = 'Compl%'

Write-Host "  $colName $colId $colStatus $colCreated $colDeadline $colItems $colPct" -ForegroundColor White
Write-Host "  $('-' * 137)" -ForegroundColor DarkGray

foreach ($row in $tableRows) {
    $rName = "$($row.Name)".PadRight(40)
    if ($rName.Length -gt 40) { $rName = $rName.Substring(0, 37) + '...' }

    $rId = "$($row.Id)".PadRight(38)
    if ($rId.Length -gt 38) { $rId = $rId.Substring(0, 35) + '...' }

    $rStatus   = "$($row.Status)".PadRight(12)
    $rCreated  = "$($row.Created)".PadRight(12)
    $rDeadline = "$($row.Deadline)".PadRight(12)
    $rItems    = "$($row.Decided)/$($row.Total)".PadRight(15)
    $rPct      = "$($row.CompletionPct)%"

    $statusColor = switch ($row.Status) {
        'ACTIVE'     { 'Green' }
        'STAGED'     { 'Yellow' }
        'COMPLETING' { 'Cyan' }
        'COMPLETED'  { 'DarkGray' }
        default      { 'White' }
    }

    Write-Host "  $rName " -NoNewline
    Write-Host "$rId " -NoNewline
    Write-Host "$rStatus " -NoNewline -ForegroundColor $statusColor
    Write-Host "$rCreated $rDeadline $rItems $rPct"
}

Write-Host ''
Write-Host "  Found $($campaigns.Count) campaign(s) matching criteria." -ForegroundColor Cyan

#endregion

#region Complete Campaigns

if (-not $SetCompleted.IsPresent) {
    Write-SPLog -Message "Read-only listing complete: $($campaigns.Count) campaign(s) found" `
        -Severity INFO -Component 'Invoke-SPCampaignClose' -Action 'List' -CorrelationID $correlationID
    exit 0
}

# --- SetCompleted path ---

# WhatIf: show what would be completed and exit
if ($WhatIfPreference -eq $true) {
    Write-Host ''
    Write-Host '  [WhatIf] The following campaigns WOULD be completed:' -ForegroundColor Yellow
    foreach ($row in $tableRows) {
        Write-Host "    WhatIf: Would complete $($row.Name) ($($row.Id))" -ForegroundColor Yellow
        if ($row.Pending -gt 0) {
            Write-Host "      $($row.Pending) undecided item(s) would auto-approve (maintain current access)." -ForegroundColor DarkYellow
        }
    }
    Write-Host ''
    Write-Host "  [WhatIf] $($campaigns.Count) campaign(s) would be completed. No API calls made." -ForegroundColor Yellow
    exit 0
}

# Safety: warn about pending items across all campaigns
$totalPending = ($tableRows | Measure-Object -Property Pending -Sum).Sum
if ($totalPending -gt 0) {
    Write-Host ''
    Write-Host "  WARNING: Completing a campaign makes all undecided items maintain current access." -ForegroundColor Yellow
    Write-Host "           $totalPending item(s) are still pending across $($campaigns.Count) campaign(s)." -ForegroundColor Yellow
}

# Confirmation gate: more than 5 campaigns requires confirmation (or -Force)
if ($campaigns.Count -gt 5 -and -not $Force.IsPresent) {
    Write-Host ''
    Write-Host "  $($campaigns.Count) campaigns matched. Use -Force to skip this confirmation." -ForegroundColor Yellow
    $confirm = Read-Host "  Type 'YES' to complete all $($campaigns.Count) campaigns"
    if ($confirm -ne 'YES') {
        Write-Host '  Aborted. No campaigns were completed.' -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ''

$completedCount = 0
$failedCount    = 0
$failedCampaigns = @()

foreach ($camp in $campaigns) {
    $campName = if ($null -ne $camp.name) { [string]$camp.name } else { '(unknown)' }
    $campId   = if ($null -ne $camp.id)   { [string]$camp.id }   else { '?' }

    Write-Host "  Completing: $campName ($campId)..." -NoNewline -ForegroundColor Gray

    try {
        $completeResult = Complete-SPCampaign -CampaignId $campId -CorrelationID $correlationID

        if ($completeResult.Success) {
            Write-Host ' OK' -ForegroundColor Green
            $completedCount++

            Write-SPLog -Message "Campaign completed: Name='$campName', Id='$campId'" `
                -Severity INFO -Component 'Invoke-SPCampaignClose' -Action 'Complete' -CorrelationID $correlationID

            # Write JSONL audit entry
            try {
                $auditOutputPath = Join-Path $toolkitRoot 'Output'
                if ($null -ne $config.PSObject.Properties['Output'] -and
                    $null -ne $config.Output -and
                    $null -ne $config.Output.PSObject.Properties['Path'] -and
                    -not [string]::IsNullOrWhiteSpace($config.Output.Path)) {
                    $auditOutputPath = $config.Output.Path
                }

                if (-not (Test-Path -Path $auditOutputPath -PathType Container)) {
                    New-Item -Path $auditOutputPath -ItemType Directory -Force -WhatIf:$false | Out-Null
                }

                $auditEntry = [ordered]@{
                    Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    Action        = 'CampaignCompleted'
                    CampaignId    = $campId
                    CampaignName  = $campName
                    CorrelationID = $correlationID
                }

                $jsonLine  = $auditEntry | ConvertTo-Json -Depth 5 -Compress
                $auditFile = Join-Path -Path $auditOutputPath -ChildPath 'campaign-close.jsonl'
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::AppendAllText($auditFile, "$jsonLine`n", $utf8NoBom)

                Write-SPLog -Message "Audit entry written to $auditFile" `
                    -Severity INFO -Component 'Invoke-SPCampaignClose' -Action 'Audit' -CorrelationID $correlationID
            }
            catch {
                Write-SPLog -Message "Failed to write audit JSONL: $($_.Exception.Message)" `
                    -Severity WARN -Component 'Invoke-SPCampaignClose' -Action 'Audit' -CorrelationID $correlationID
            }
        }
        else {
            Write-Host " FAILED: $($completeResult.Error)" -ForegroundColor Red
            $failedCount++
            $failedCampaigns += @{ Name = $campName; Id = $campId; Error = $completeResult.Error }

            Write-SPLog -Message "Campaign completion failed: Name='$campName', Id='$campId', Error='$($completeResult.Error)'" `
                -Severity ERROR -Component 'Invoke-SPCampaignClose' -Action 'Complete' -CorrelationID $correlationID
        }
    }
    catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $failedCount++
        $failedCampaigns += @{ Name = $campName; Id = $campId; Error = $_.Exception.Message }

        Write-SPLog -Message "Campaign completion exception: Name='$campName', Id='$campId', Error='$($_.Exception.Message)'" `
            -Severity ERROR -Component 'Invoke-SPCampaignClose' -Action 'Complete' -CorrelationID $correlationID
    }
}

# Summary
Write-Host ''
Write-Host "  Completion summary: $completedCount succeeded, $failedCount failed (of $($campaigns.Count) total)" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    Write-Host ''
    Write-Host '  Failed campaigns:' -ForegroundColor Red
    foreach ($fc in $failedCampaigns) {
        Write-Host "    - $($fc.Name) ($($fc.Id)): $($fc.Error)" -ForegroundColor Red
    }
}

$runDuration = ((Get-Date) - $startTime).TotalSeconds
Write-SPLog -Message "Invoke-SPCampaignClose finished: Completed=$completedCount, Failed=$failedCount, Duration=$([math]::Round($runDuration, 2))s" `
    -Severity INFO -Component 'Invoke-SPCampaignClose' -Action 'Finish' -CorrelationID $correlationID

if ($failedCount -gt 0) {
    exit 5
}

exit 0

#endregion
