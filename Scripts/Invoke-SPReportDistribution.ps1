#Requires -Version 5.1
<#
.SYNOPSIS
    Generates and optionally distributes leadership reports via SMTP.
.DESCRIPTION
    Combines campaign audit, leadership rollup, per-band report generation, and
    email distribution into a single CLI workflow.

    Default behavior is generate-only: reports are created but not emailed.
    Use -PreviewOnly to see the distribution plan without generating reports.
    Use -SendReports to generate AND send each report to the corresponding leader.

    The script queries campaigns matching the -Status and -DaysBack filters,
    builds the org tree (optionally merging a supplement CSV), resolves band
    classifications, groups decisions by leadership level, and generates
    per-band HTML reports using Export-SPLeadershipBandHtml.

    Distribution events are logged to a JSONL audit trail for traceability.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json relative to the
    Scripts directory.
.PARAMETER Status
    Filter campaigns by one or more status values. Valid values: STAGED, ACTIVE,
    COMPLETING, COMPLETED. Required.
.PARAMETER DaysBack
    Only include campaigns created within the last N days. Default: 30.
.PARAMETER LeadershipDepth
    Maximum number of levels to walk above the reviewed identities when building
    the org tree. Default: 4.
.PARAMETER TargetBands
    Array of band letters to include in report generation (e.g. @('B','C')).
    When omitted, all bands are included.
.PARAMETER SendReports
    When specified, sends each generated report to the corresponding leader via
    SMTP. Requires Audit.Smtp.Enabled = true. Connection settings (Server, From,
    Port, UseSsl) can be in Audit.Smtp or will fall back to Notification.Smtp.
.PARAMETER PreviewOnly
    Show the distribution plan (who would receive what) without generating
    reports or sending email. Exits after displaying the preview.
.PARAMETER OrgSupplementPath
    Path to an org chart supplement CSV that overrides or fills gaps in the
    ISC manager chain data. When omitted, checks the Leadership.OrgChartSupplementPath
    setting in config.
.PARAMETER OutputPath
    Directory to write report output files. Overrides Audit.OutputPath in settings.json.
.PARAMETER OutputMode
    Output destination for the final summary. Console (default), JSON, or Both.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER DetailLevel
    Controls identity-level detail in generated reports: Summary, Detailed, or Verbose.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPReportDistribution.ps1 -Status COMPLETED -DaysBack 30 -PreviewOnly
    # Preview the distribution plan without generating or sending reports.
.EXAMPLE
    .\Invoke-SPReportDistribution.ps1 -Status COMPLETED -TargetBands @('B','C')
    # Generate VP and Director band reports (no email).
.EXAMPLE
    .\Invoke-SPReportDistribution.ps1 -Status COMPLETED -SendReports
    # Generate all leadership reports and send via SMTP.
.EXAMPLE
    .\Invoke-SPReportDistribution.ps1 -Status COMPLETED -OrgSupplementPath '.\Config\org-chart-supplement.csv'
    # Generate reports using supplement CSV to fill org tree gaps.
.NOTES
    Script:  Invoke-SPReportDistribution.ps1
    Version: 1.0.0
    Exit codes:
        0 = Distribution completed successfully
        1 = No campaigns matched the filter criteria
        2 = Parameter error
        3 = Authentication error
        4 = SMTP failure (when -SendReports is used)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [ValidateSet('STAGED', 'ACTIVE', 'COMPLETING', 'COMPLETED')]
    [string[]]$Status,

    [Parameter()]
    [int]$DaysBack = 30,

    [Parameter()]
    [int]$LeadershipDepth = 4,

    [Parameter()]
    [string[]]$TargetBands,

    [Parameter()]
    [switch]$SendReports,

    [Parameter()]
    [switch]$PreviewOnly,

    [Parameter()]
    [string]$OrgSupplementPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [ValidateSet('Summary', 'Detailed', 'Verbose')]
    [string]$DetailLevel = 'Verbose',

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

$coreModulePath      = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1'
$apiModulePath       = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1'
$auditModulePath     = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1'
$deltaCertModulePath = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'

foreach ($moduleDef in @(
    @{ Path = $coreModulePath;      Name = 'SP.Core';      Required = $true },
    @{ Path = $apiModulePath;       Name = 'SP.Api';       Required = $true },
    @{ Path = $auditModulePath;     Name = 'SP.Audit';     Required = $true },
    @{ Path = $deltaCertModulePath; Name = 'SP.DeltaCert'; Required = $true }
)) {
    if (Test-Path $moduleDef.Path) {
        Import-Module $moduleDef.Path -Force -ErrorAction Stop -DisableNameChecking
    }
    else {
        $moduleDir  = Split-Path -Parent $moduleDef.Path
        $psm1Files  = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        if ($psm1Files) {
            foreach ($psm1 in $psm1Files) {
                Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
            }
        }
        elseif ($moduleDef.Required) {
            Write-Host "ERROR: Required module '$($moduleDef.Name)' not found at: $($moduleDef.Path)" -ForegroundColor Red
            exit 2
        }
    }
}

#endregion

#region Setup

$correlationID = [guid]::NewGuid().ToString()

# Resolve config path
if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

# Initialize logging (best-effort before config)
try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
}
catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Report Distribution' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

# Load configuration
$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '$ConfigPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow
    exit 2
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host "ERROR: Configuration validation failed. Check settings.json for required values." -ForegroundColor Red
    exit 2
}

# Re-initialize logging with loaded config
try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
}
catch { }

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

Write-SPLog -Message "Invoke-SPReportDistribution started" `
    -Severity INFO -Component 'Invoke-SPReportDistribution' -Action 'Start' -CorrelationID $correlationID

# Resolve output path
if (-not $OutputPath) {
    if ($config.Audit -and $config.Audit.OutputPath) {
        $OutputPath = $config.Audit.OutputPath
    }
    else {
        $OutputPath = '.\Audit'
    }
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = [System.IO.Path]::GetFullPath(
        (Join-Path $toolkitRoot $OutputPath.TrimStart('.\').TrimStart('./'))
    )
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# Apply config defaults for DaysBack
$effectiveDaysBack = $DaysBack
if ($config.Audit -and $config.Audit.DefaultDaysBack -and $DaysBack -eq 30) {
    $effectiveDaysBack = [int]$config.Audit.DefaultDaysBack
}

# Resolve org supplement path: parameter > config > none
$effectiveSupplementPath = $OrgSupplementPath
if ([string]::IsNullOrWhiteSpace($effectiveSupplementPath) -and
    $config.Leadership -and
    $config.Leadership.PSObject.Properties.Name -contains 'OrgChartSupplementPath' -and
    -not [string]::IsNullOrWhiteSpace($config.Leadership.OrgChartSupplementPath)) {
    $effectiveSupplementPath = $config.Leadership.OrgChartSupplementPath
}

# Check UseSupplementForReports toggle
$useSupplementForReports = $false
if ($config.Leadership -and
    $config.Leadership.PSObject.Properties.Name -contains 'UseSupplementForReports') {
    $useSupplementForReports = $config.Leadership.UseSupplementForReports -eq $true
}
# Explicit -OrgSupplementPath param overrides the toggle
if (-not [string]::IsNullOrWhiteSpace($OrgSupplementPath)) {
    $useSupplementForReports = $true
}

# Resolve band mapping from config
$bandMapping = $null
if ($config.Leadership -and
    $config.Leadership.PSObject.Properties.Name -contains 'DefaultBandMapping') {
    $bandMapping = @{}
    $rawMap = $config.Leadership.DefaultBandMapping
    if ($null -ne $rawMap) {
        foreach ($prop in $rawMap.PSObject.Properties) {
            $bandMapping[[int]$prop.Name] = [string]$prop.Value
        }
    }
}

# ISC band attribute from config
$iscBandAttribute = 'jobLevel'
if ($config.Leadership -and
    $config.Leadership.PSObject.Properties.Name -contains 'ISCBandAttribute' -and
    -not [string]::IsNullOrWhiteSpace($config.Leadership.ISCBandAttribute)) {
    $iscBandAttribute = $config.Leadership.ISCBandAttribute
}

#endregion

#region WhatIf

if ($WhatIfPreference -eq $true) {
    Write-Host ''
    Write-Host '  [WhatIf] Dry-run mode enabled. No API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Would query campaigns with the following filters:" -ForegroundColor Cyan
    Write-Host "    Status:              $($Status -join ', ')"
    Write-Host "    DaysBack:            $effectiveDaysBack"
    Write-Host "    LeadershipDepth:     $LeadershipDepth"
    if ($TargetBands) { Write-Host "    TargetBands:         $($TargetBands -join ', ')" }
    if ($PreviewOnly) { Write-Host "    Mode:                Preview Only" -ForegroundColor Yellow }
    elseif ($SendReports) { Write-Host "    Mode:                Generate + Send" -ForegroundColor Cyan }
    else { Write-Host "    Mode:                Generate Only (no email)" }
    if (-not [string]::IsNullOrWhiteSpace($effectiveSupplementPath)) {
        Write-Host "    OrgSupplement:       $effectiveSupplementPath"
    }
    Write-Host ''
    Write-Host "  Would write output to: $OutputPath" -ForegroundColor Cyan
    Write-Host "  CorrelationID:         $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [WhatIf] Validation complete. Re-run without -WhatIf to execute.' -ForegroundColor Yellow
    Write-SPLog -Message "Distribution skipped: -WhatIf" -Severity INFO `
        -Component 'Invoke-SPReportDistribution' -Action 'WhatIfSkip' -CorrelationID $correlationID
    exit 0
}

#endregion

#region Campaign Data Collection

$runStart = Get-Date

Write-Host "  Querying campaigns (Status=$($Status -join ','), DaysBack=$effectiveDaysBack)..." -ForegroundColor Cyan

$campaignsResult = Get-SPAuditCampaigns -Status $Status -DaysBack $effectiveDaysBack -CorrelationID $correlationID

if (-not $campaignsResult.Success) {
    Write-Host "ERROR: Failed to retrieve campaigns: $($campaignsResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Failed to retrieve campaigns: $($campaignsResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPReportDistribution' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 3
}

$campaigns = $campaignsResult.Data

if (-not $campaigns -or $campaigns.Count -eq 0) {
    Write-Host "  No campaigns matched the specified filter criteria." -ForegroundColor Yellow
    Write-SPLog -Message "No campaigns matched filter criteria" `
        -Severity WARN -Component 'Invoke-SPReportDistribution' -Action 'GetCampaigns' -CorrelationID $correlationID
    exit 1
}

Write-Host "  Found $($campaigns.Count) campaign(s)." -ForegroundColor Green
Write-Host ''

# Collect all certification items across campaigns
$allCampaignAudits = [System.Collections.Generic.List[object]]::new()

foreach ($campaign in $campaigns) {
    $campId   = $campaign.id
    $campName = $campaign.name

    Write-Host "  Processing: $campName ($campId)" -ForegroundColor Cyan

    # --- Certifications ---
    Write-Host "    Getting certifications..." -ForegroundColor DarkGray
    $certResult = Get-SPAuditCertifications -CampaignId $campId -CorrelationID $correlationID
    $certifications = @()
    if ($certResult.Success) {
        $certifications = @($certResult.Data)
    }
    else {
        Write-Host "    WARN: Could not retrieve certifications: $($certResult.Error)" -ForegroundColor Yellow
        Write-SPLog -Message "Could not retrieve certifications for campaign ${campId}: $($certResult.Error)" `
            -Severity WARN -Component 'Invoke-SPReportDistribution' -Action 'GetCertifications' -CorrelationID $correlationID
    }

    # --- Certification items (cached) ---
    # Fetched from ISC once per campaign, then served from disk/memory on later runs. The
    # certs fetched above are passed through so the cache doesn't re-enumerate them. Items
    # return pre-wrapped; the raw $allItems list is rebuilt from .Item.
    $wrappedAllItems = [System.Collections.Generic.List[object]]::new()
    $allItems        = [System.Collections.Generic.List[object]]::new()
    $cacheResult = Get-SPCachedCampaignItems -Campaign $campaign -Certifications $certifications -CorrelationID $correlationID
    if ($cacheResult.Success) {
        foreach ($wi in $cacheResult.Data) {
            $wrappedAllItems.Add($wi)
            $allItems.Add($wi.Item)
        }
        $srcLabel = if ($cacheResult.FromCache) { 'cache' } else { 'ISC' }
        Write-Host "    Collected $($allItems.Count) review items across $($certifications.Count) certification(s) [from $srcLabel]." -ForegroundColor DarkGray
    }
    else {
        Write-Host "    WARN: Could not retrieve items: $($cacheResult.Error)" -ForegroundColor Yellow
    }

    # --- Resolve identity accounts for UPN/email ---
    $uniqueIdentityIds = @($wrappedAllItems | ForEach-Object {
        $item = $_.Item
        $iid = if ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.identityId) { $item.identitySummary.identityId }
               elseif ($null -ne $item.identitySummary -and $null -ne $item.identitySummary.id) { $item.identitySummary.id }
               else { $null }
        $iid
    } | Where-Object { $_ } | Sort-Object -Unique)

    $accountMap = @{}
    if ($uniqueIdentityIds.Count -gt 0) {
        Write-Host "    Resolving account attributes for $($uniqueIdentityIds.Count) unique identit(ies)..." -ForegroundColor DarkGray
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $uniqueIdentityIds -CorrelationID $correlationID
        if ($acctResult.Success) {
            $accountMap = $acctResult.Data
        }
        else {
            Write-Host "    WARN: Account resolution failed (non-fatal): $($acctResult.Error)" -ForegroundColor Yellow
        }
    }

    # --- Build campaign metadata ---
    $campaignMetadata = @{
        StartDate      = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
        DueDate        = if ($null -ne $campaign.deadline)  { [string]$campaign.deadline }
                         elseif ($null -ne $campaign.due)    { [string]$campaign.due }       else { '' }
        CompletionDate = if ($null -ne $campaign.completed) { [string]$campaign.completed }  else { '' }
    }

    # --- Cert reviewer email map ---
    $certReviewerEmailMap = @{}
    foreach ($cert in $certifications) {
        if ($null -ne $cert.id -and $null -ne $cert.reviewer -and
            $null -ne $cert.reviewer.email -and
            -not [string]::IsNullOrWhiteSpace([string]$cert.reviewer.email)) {
            $certReviewerEmailMap[[string]$cert.id] = [string]$cert.reviewer.email
        }
    }

    # --- Categorize decisions ---
    $decisionGroups  = Group-SPAuditDecisions -Items $wrappedAllItems.ToArray() -AccountMap $accountMap -CampaignMetadata $campaignMetadata -CertReviewerEmailMap $certReviewerEmailMap
    $reviewerMetrics = Measure-SPAuditReviewerMetrics -Certifications $certifications

    $campaignAudit = @{
        CampaignName    = $campName
        CampaignId      = $campId
        Status          = if ($null -ne $campaign.status)    { [string]$campaign.status }    else { '' }
        Created         = if ($null -ne $campaign.created)   { [string]$campaign.created }   else { '' }
        Completed       = if ($null -ne $campaign.completed) { [string]$campaign.completed } else { '' }
        Decisions       = $decisionGroups
        ReviewerMetrics = $reviewerMetrics
    }
    $allCampaignAudits.Add($campaignAudit)

    Write-Host "    Done." -ForegroundColor Green
}

#endregion

#region Org Tree & Leadership

Write-Host ''
Write-Host '  Building org tree and leadership data...' -ForegroundColor Cyan

# Collect all unique identity IDs from all campaigns
$allIdentityIds = [System.Collections.Generic.List[string]]::new()
foreach ($audit in $allCampaignAudits) {
    $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
    if ($null -eq $d) { continue }
    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        if (-not $d.ContainsKey($category) -or $null -eq $d[$category]) { continue }
        foreach ($item in @($d[$category])) {
            if ($null -ne $item.IdentityId -and -not [string]::IsNullOrWhiteSpace($item.IdentityId)) {
                if (-not $allIdentityIds.Contains($item.IdentityId)) {
                    $allIdentityIds.Add($item.IdentityId)
                }
            }
        }
    }
}

if ($allIdentityIds.Count -eq 0) {
    Write-Host '  No identity IDs found in decisions -- no reports to distribute.' -ForegroundColor Yellow
    Write-SPLog -Message "No identity IDs in decisions -- nothing to distribute" `
        -Severity WARN -Component 'Invoke-SPReportDistribution' -Action 'BuildOrgTree' -CorrelationID $correlationID
    exit 1
}

Write-Host "    Building org tree for $($allIdentityIds.Count) unique identit(ies) (depth=$LeadershipDepth)..." -ForegroundColor DarkGray
$orgTreeResult = Build-SPOrgTree -IdentityIds $allIdentityIds.ToArray() -MaxDepth $LeadershipDepth -CorrelationID $correlationID

if (-not $orgTreeResult.Success) {
    Write-Host "ERROR: Org tree build failed: $($orgTreeResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Org tree build failed: $($orgTreeResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPReportDistribution' -Action 'BuildOrgTree' -CorrelationID $correlationID
    exit 2
}

$orgTree = $orgTreeResult.Data
Write-Host "    Org tree: $($orgTree.LeafCount) leaves, $(@($orgTree.Managers).Count) managers, $(@($orgTree.Directors).Count) directors, $(@($orgTree.TopLeaders).Count) top leader(s)" -ForegroundColor DarkGray

# --- Optionally merge org chart supplement ---
$supplement = $null
if ($useSupplementForReports -and -not [string]::IsNullOrWhiteSpace($effectiveSupplementPath)) {
    if (-not [System.IO.Path]::IsPathRooted($effectiveSupplementPath)) {
        $effectiveSupplementPath = [System.IO.Path]::GetFullPath(
            (Join-Path $toolkitRoot $effectiveSupplementPath.TrimStart('.\').TrimStart('./'))
        )
    }

    if (Test-Path $effectiveSupplementPath) {
        Write-Host "    Importing org chart supplement: $effectiveSupplementPath" -ForegroundColor DarkGray
        $suppResult = Import-SPOrgChartSupplement -FilePath $effectiveSupplementPath -CorrelationID $correlationID
        if ($suppResult.Success) {
            $supplement = $suppResult.Data
            Write-Host "    Supplement loaded: $($suppResult.Data.Entries.Count) entries" -ForegroundColor DarkGray

            # Build identity email map for merge
            $identityEmailMap = @{}
            foreach ($nodeId in $orgTree.Nodes.Keys) {
                $node = $orgTree.Nodes[$nodeId]
                if ($null -ne $node.Identity -and $null -ne $node.Identity.Email -and
                    -not [string]::IsNullOrWhiteSpace($node.Identity.Email)) {
                    $identityEmailMap[$nodeId] = $node.Identity.Email
                }
            }

            $mergeResult = Merge-SPOrgTreeWithSupplement `
                -OrgTree $orgTree `
                -Supplement $suppResult.Data.Entries `
                -IdentityEmailMap $identityEmailMap `
                -CorrelationID $correlationID
            $orgTree = $mergeResult
            Write-Host "    Org tree merged with supplement (applied=$($mergeResult.SupplementApplied), synthetic=$(@($mergeResult.SyntheticNodes).Count))" -ForegroundColor DarkGray
        }
        else {
            Write-Host "    WARN: Supplement import failed: $($suppResult.Error)" -ForegroundColor Yellow
            Write-SPLog -Message "Supplement import failed: $($suppResult.Error)" `
                -Severity WARN -Component 'Invoke-SPReportDistribution' -Action 'ImportSupplement' -CorrelationID $correlationID
        }
    }
    else {
        Write-Host "    WARN: Supplement file not found: $effectiveSupplementPath" -ForegroundColor Yellow
    }
}

# --- Resolve band classifications ---
Write-Host "    Resolving band classifications..." -ForegroundColor DarkGray
$bandParams = @{
    OrgTree = $orgTree
}
if ($null -ne $supplement) {
    $bandParams['Supplement'] = $supplement.Entries
}
if ($null -ne $bandMapping) {
    $bandParams['BandMapping'] = $bandMapping
}
$bandParams['ISCBandAttribute'] = $iscBandAttribute

$bandResult = Resolve-SPIdentityBand @bandParams

if (-not $bandResult.Success) {
    Write-Host "    WARN: Band resolution failed: $($bandResult.Error)" -ForegroundColor Yellow
    Write-SPLog -Message "Band resolution failed: $($bandResult.Error)" `
        -Severity WARN -Component 'Invoke-SPReportDistribution' -Action 'ResolveBands' -CorrelationID $correlationID
    # Continue with empty band data -- reports will still generate without band filtering
    $bandData = @{ Bands = @{}; Sources = @{}; Summary = @{} }
}
else {
    $bandData = $bandResult.Data
    Write-Host "    Bands resolved: A=$($bandData.Summary.A) B=$($bandData.Summary.B) C=$($bandData.Summary.C) D=$($bandData.Summary.D) E=$($bandData.Summary.E)" -ForegroundColor DarkGray
}

# --- Merge decisions across campaigns ---
$mergedDecisions = @{
    Approved = [System.Collections.Generic.List[object]]::new()
    Revoked  = [System.Collections.Generic.List[object]]::new()
    Pending  = [System.Collections.Generic.List[object]]::new()
}
foreach ($audit in $allCampaignAudits) {
    $d = if ($audit.ContainsKey('Decisions') -and $null -ne $audit['Decisions']) { $audit['Decisions'] } else { $null }
    if ($null -eq $d) { continue }
    foreach ($category in @('Approved', 'Revoked', 'Pending')) {
        if ($d.ContainsKey($category) -and $null -ne $d[$category]) {
            foreach ($item in @($d[$category])) {
                $mergedDecisions[$category].Add($item)
            }
        }
    }
}
$mergedDecisionsHt = @{
    Approved = $mergedDecisions['Approved'].ToArray()
    Revoked  = $mergedDecisions['Revoked'].ToArray()
    Pending  = $mergedDecisions['Pending'].ToArray()
}

# --- Merge reviewer metrics ---
$mergedReviewerMetrics = $null
if ($allCampaignAudits.Count -eq 1 -and $allCampaignAudits[0].ContainsKey('ReviewerMetrics')) {
    $mergedReviewerMetrics = $allCampaignAudits[0]['ReviewerMetrics']
}
elseif ($allCampaignAudits.Count -gt 1) {
    $combinedMetrics = [System.Collections.Generic.List[object]]::new()
    foreach ($audit in $allCampaignAudits) {
        if ($audit.ContainsKey('ReviewerMetrics') -and $null -ne $audit['ReviewerMetrics'] -and
            $null -ne $audit['ReviewerMetrics']['ReviewerMetrics']) {
            foreach ($rm in @($audit['ReviewerMetrics']['ReviewerMetrics'])) {
                $combinedMetrics.Add($rm)
            }
        }
    }
    if ($combinedMetrics.Count -gt 0) {
        $mergedReviewerMetrics = @{ ReviewerMetrics = $combinedMetrics.ToArray() }
    }
}

# --- Group decisions by leadership ---
Write-Host '    Grouping decisions by leadership level...' -ForegroundColor DarkGray
$groupParams = @{
    Decisions = $mergedDecisionsHt
    OrgTree   = $orgTree
}
if ($null -ne $mergedReviewerMetrics) {
    $groupParams['ReviewerMetrics'] = $mergedReviewerMetrics
}
$leadershipData = Group-SPAuditByLeadership @groupParams

Write-Host "    Leadership grouping complete." -ForegroundColor DarkGray

#endregion

#region Preview Mode

if ($PreviewOnly) {
    Write-Host ''
    Write-Host '  Distribution Preview' -ForegroundColor Cyan
    Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
    Write-Host ''

    $previewLines = Show-SPReportDistributionPreview `
        -OrgTree $orgTree `
        -LeadershipData $leadershipData `
        -IncludeEmail

    foreach ($line in $previewLines) {
        Write-Host "  $line"
    }

    Write-Host ''
    Write-SPLog -Message "Distribution preview displayed (PreviewOnly mode)" `
        -Severity INFO -Component 'Invoke-SPReportDistribution' -Action 'Preview' -CorrelationID $correlationID
    exit 0
}

#endregion

#region Report Generation

$leadershipOutputPath = Join-Path $OutputPath 'leadership'
if (-not (Test-Path $leadershipOutputPath)) {
    $null = New-Item -ItemType Directory -Path $leadershipOutputPath -Force
}

# Build campaign name and date range for report headers
$campaignLabel = if ($allCampaignAudits.Count -eq 1) {
    $allCampaignAudits[0]['CampaignName']
}
else {
    "$($allCampaignAudits.Count) Campaigns (Combined)"
}

$dateRange = ''
$allCreated = @($allCampaignAudits | ForEach-Object {
    if ($_['Created']) { $_['Created'] }
} | Where-Object { $_ } | Sort-Object)
if ($allCreated.Count -gt 0) {
    $startDate = ($allCreated[0] -split 'T')[0]
    $endDate   = ((Get-Date).ToString('yyyy-MM-dd'))
    $dateRange = "$startDate to $endDate"
}

Write-Host ''
Write-Host '  Generating per-band leadership reports...' -ForegroundColor Cyan

$bandReportParams = @{
    LeadershipData = $leadershipData
    Decisions      = $mergedDecisionsHt
    OrgTree        = $orgTree
    BandData       = $bandData
    CampaignName   = $campaignLabel
    DateRange      = $dateRange
    OutputPath     = $leadershipOutputPath
    CorrelationID  = $correlationID
    DetailLevel    = $DetailLevel
}
if ($null -ne $TargetBands -and $TargetBands.Count -gt 0) {
    $bandReportParams['TargetBands'] = $TargetBands
}

$bandReportResult = Export-SPLeadershipBandHtml @bandReportParams

if (-not $bandReportResult.Success) {
    Write-Host "ERROR: Report generation failed: $($bandReportResult.Error)" -ForegroundColor Red
    Write-SPLog -Message "Report generation failed: $($bandReportResult.Error)" `
        -Severity ERROR -Component 'Invoke-SPReportDistribution' -Action 'GenerateReports' -CorrelationID $correlationID
    exit 2
}

$generatedFiles = @($bandReportResult.Data.Files)
$reportCount    = $bandReportResult.Data.ReportCount
$bandsIncluded  = @($bandReportResult.Data.BandsIncluded)

Write-Host "    Generated $reportCount report(s) for bands: $($bandsIncluded -join ', ')" -ForegroundColor Green
foreach ($f in $generatedFiles) {
    Write-Host "    Report: $f" -ForegroundColor DarkGray
}

#endregion

#region Distribution (Send)

$distributionEvents = [System.Collections.Generic.List[object]]::new()
$sendFailures = 0

if ($SendReports -and $generatedFiles.Count -gt 0) {
    Write-Host ''
    Write-Host '  Distributing reports via SMTP...' -ForegroundColor Cyan

    # Build leader ID -> email mapping by resolving all leader identities
    $leaderIds = [System.Collections.Generic.List[string]]::new()
    foreach ($lvlKey in $leadershipData.Levels.Keys) {
        foreach ($lid in $leadershipData.Levels[$lvlKey].Leaders.Keys) {
            if ($lid -ne '__unmanaged__' -and -not $leaderIds.Contains($lid)) {
                $leaderIds.Add($lid)
            }
        }
    }

    $leaderEmailMap = @{}
    $leaderNameMap  = @{}
    if ($leaderIds.Count -gt 0) {
        $acctResult = Resolve-SPAuditIdentityAccounts -IdentityIds $leaderIds.ToArray() -CorrelationID $correlationID
        if ($acctResult.Success -and $null -ne $acctResult.Data) {
            foreach ($lid in $acctResult.Data.Keys) {
                $acct = $acctResult.Data[$lid]
                if ($null -ne $acct -and $null -ne $acct.Email -and
                    -not [string]::IsNullOrWhiteSpace([string]$acct.Email)) {
                    $leaderEmailMap[$lid] = [string]$acct.Email
                }
            }
        }
    }
    # Also build name map from org tree nodes
    foreach ($lid in $leaderIds) {
        if ($orgTree.Nodes.ContainsKey($lid)) {
            $node = $orgTree.Nodes[$lid]
            if ($null -ne $node.Identity -and -not [string]::IsNullOrWhiteSpace($node.Identity.Name)) {
                $leaderNameMap[$lid] = $node.Identity.Name
            }
        }
    }

    foreach ($reportFile in $generatedFiles) {
        $fileName = Split-Path -Path $reportFile -Leaf

        # Match report file to a leader by checking leader names in the filename
        $matchedLeaderId = $null
        foreach ($lid in $leaderNameMap.Keys) {
            $safeName = ($leaderNameMap[$lid] -replace '[\\/:*?"<>|]', '_').TrimEnd('.')
            $safeName = ($safeName -replace '\s+', '_')
            if ($fileName -match [regex]::Escape($safeName)) {
                $matchedLeaderId = $lid
                break
            }
        }

        $recipientEmail = ''
        $recipientName  = $fileName
        if ($null -ne $matchedLeaderId) {
            $recipientName = if ($leaderNameMap.ContainsKey($matchedLeaderId)) { $leaderNameMap[$matchedLeaderId] } else { $matchedLeaderId }
            $recipientEmail = if ($leaderEmailMap.ContainsKey($matchedLeaderId)) { $leaderEmailMap[$matchedLeaderId] } else { '' }
        }

        $deliveryStatus = 'Skipped'
        $deliveryError  = ''

        if (-not [string]::IsNullOrWhiteSpace($recipientEmail)) {
            try {
                $sendResult = Send-SPReport `
                    -ReportPath $reportFile `
                    -RecipientEmail $recipientEmail `
                    -RecipientName $recipientName `
                    -CorrelationID $correlationID
                if ($sendResult.Success) {
                    $deliveryStatus = $sendResult.Data.Action
                    Write-Host "    Sent: $fileName -> $recipientEmail ($recipientName)" -ForegroundColor Green
                }
                else {
                    $deliveryStatus = 'Failed'
                    $deliveryError  = $sendResult.Error
                    $sendFailures++
                    Write-Host "    FAILED: $fileName -> $recipientEmail : $($sendResult.Error)" -ForegroundColor Red
                }
            }
            catch {
                $deliveryStatus = 'Failed'
                $deliveryError  = $_.Exception.Message
                $sendFailures++
                Write-Host "    FAILED: $fileName -> $recipientEmail : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "    Skipped (no email): $fileName ($recipientName)" -ForegroundColor Yellow
        }

        $distributionEvents.Add(@{
            Action         = 'ReportDistributed'
            LeaderName     = $recipientName
            RecipientEmail = $recipientEmail
            ReportPath     = $reportFile
            FileName       = $fileName
            Band           = if ($null -ne $matchedLeaderId -and $bandData.Bands.ContainsKey($matchedLeaderId)) { $bandData.Bands[$matchedLeaderId] } else { '' }
            DeliveryStatus = $deliveryStatus
            DeliveryError  = $deliveryError
        })
    }
}
elseif (-not $SendReports) {
    # Log generation-only events
    foreach ($reportFile in $generatedFiles) {
        $distributionEvents.Add(@{
            Action         = 'ReportGenerated'
            ReportPath     = $reportFile
            FileName       = (Split-Path -Path $reportFile -Leaf)
            DeliveryStatus = 'GenerateOnly'
        })
    }
}

#endregion

#region Audit Trail

# Write distribution events to JSONL
if ($distributionEvents.Count -gt 0) {
    $jsonlPath = Export-SPAuditJsonl `
        -Events $distributionEvents.ToArray() `
        -OutputPath $leadershipOutputPath `
        -FileName "distribution-$(Get-Date -Format 'yyyyMMdd-HHmmss').jsonl" `
        -CorrelationID $correlationID
    Write-Host ''
    Write-Host "  Distribution log: $jsonlPath" -ForegroundColor DarkGray
}

#endregion

#region Output

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

$summary = [PSCustomObject]@{
    CorrelationID    = $correlationID
    StartedAt        = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt      = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds  = [math]::Round($runDuration, 2)
    CampaignsQueried = $allCampaignAudits.Count
    ReportsGenerated = $reportCount
    BandsIncluded    = ($bandsIncluded -join ', ')
    SendReports      = [bool]$SendReports
    SendFailures     = $sendFailures
    OutputPath       = $leadershipOutputPath
    Environment      = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    'Console' {
        Write-Host ''
        Write-Host '  Distribution Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Campaigns queried: $($summary.CampaignsQueried)" -ForegroundColor Green
        Write-Host "  Reports generated: $($summary.ReportsGenerated)" -ForegroundColor Green
        Write-Host "  Bands included:    $($summary.BandsIncluded)" -ForegroundColor Green
        if ($SendReports) {
            Write-Host "  Send failures:     $sendFailures" -ForegroundColor $(if ($sendFailures -gt 0) { 'Red' } else { 'Green' })
        }
        else {
            Write-Host "  Send mode:         Generate only (use -SendReports to email)" -ForegroundColor DarkGray
        }
        Write-Host "  Duration:          $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Output path:       $($summary.OutputPath)" -ForegroundColor DarkGray
        Write-Host "  Environment:       $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $correlationID" -ForegroundColor DarkGray
        Write-Host ''
    }
    'Both' {
        Write-Host ''
        Write-Host '  Distribution Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Campaigns queried: $($summary.CampaignsQueried)" -ForegroundColor Green
        Write-Host "  Reports generated: $($summary.ReportsGenerated)" -ForegroundColor Green
        Write-Host "  Bands included:    $($summary.BandsIncluded)" -ForegroundColor Green
        if ($SendReports) {
            Write-Host "  Send failures:     $sendFailures" -ForegroundColor $(if ($sendFailures -gt 0) { 'Red' } else { 'Green' })
        }
        else {
            Write-Host "  Send mode:         Generate only (use -SendReports to email)" -ForegroundColor DarkGray
        }
        Write-Host "  Duration:          $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Output path:       $($summary.OutputPath)" -ForegroundColor DarkGray
        Write-Host "  Environment:       $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:     $correlationID" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  JSON Output:' -ForegroundColor Cyan
        $summary | ConvertTo-Json -Depth 10
    }
}

Write-SPLog -Message "Invoke-SPReportDistribution completed: $reportCount report(s), $sendFailures failure(s)" `
    -Severity INFO -Component 'Invoke-SPReportDistribution' -Action 'Complete' -CorrelationID $correlationID

if ($SendReports -and $sendFailures -gt 0) {
    exit 4
}

exit 0

#endregion
