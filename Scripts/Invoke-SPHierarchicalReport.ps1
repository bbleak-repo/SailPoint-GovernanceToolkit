#Requires -Version 5.1
<#
.SYNOPSIS
    Generates hierarchical leadership certification rollup reports.
.DESCRIPTION
    Produces one self-contained HTML file per leader at or above the specified org level.
    Each file contains the leader's full certification sub-tree with collapsible drill-down:

        Executive (level 3+)
          ▶ VP (level 2)
              ▶ Director (level 1) — report recipients by default
                  ▶ Manager (level 0, the certifier) — shows certified identities
                      ▼ Identity — shows entitlement-level decisions

    Data flow:
        Get-SPAuditCampaigns → Get-SPAuditCertifications → Get-SPAuditCertificationItems
            → Group-SPAuditDecisions (decision index)
            → Build-SPOrgTree (org chain from certifier IDs)
            → Build-SPLeadershipHierarchy (join decisions to org tree)
            → Export-SPHierarchicalLeadershipHtml (one HTML file per leader)

    The join uses certifier identity IDs from the certification objects. Without
    a certifier ID in the cert, decisions for that cert cannot be attributed to
    a reviewer node in the org tree and will be omitted from the report.

    SCOPE REQUIREMENT:
        idn:campaign:read, idn:campaign-report:read (read campaigns/certs/items)
        sp:search:read (resolve identity details for org tree walks)

.PARAMETER CampaignNameContains
    Substring filter for campaign names. Only campaigns whose name contains this
    string are included. Use to scope to 'AD Delta Cert', 'Daily Attestation', etc.
.PARAMETER DaysBack
    Number of days back to search for campaigns. Default: 30.
.PARAMETER Status
    Campaign statuses to include. Default: COMPLETED and ACTIVE.
    Valid: STAGED, ACTIVATING, ACTIVE, COMPLETING, COMPLETED, ERROR.
.PARAMETER OrgDepth
    Maximum levels to walk up the manager chain from certifiers. Default: 5.
    Increase if your org has more than 5 levels between frontline manager and CEO.
.PARAMETER MinReportLevel
    Minimum org level to generate a top-level HTML file for.
    0 = certifiers (managers), 1 = directors (default), 2 = VPs, 3 = executives.
    Each leader at this level and above gets their own HTML file showing their subtree.
.PARAMETER OutputPath
    Directory to write HTML reports. Default: .\Audit\HierarchicalReports.
.PARAMETER ReportTitle
    Title shown in the HTML report header.
.PARAMETER Token
    Pre-obtained JWT bearer token. Bypasses OAuth client_credentials.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token expires. Default: 10.
.PARAMETER ConfigPath
    Path to settings.json. Defaults to ..\Config\settings.json.
.PARAMETER OutputMode
    Console (default), JSON, or Both.
.PARAMETER Help
    Show full help and exit.
.EXAMPLE
    .\Invoke-SPHierarchicalReport.ps1
    # Last 30 days, all COMPLETED+ACTIVE campaigns, one HTML per director and above.
.EXAMPLE
    .\Invoke-SPHierarchicalReport.ps1 -CampaignNameContains 'Daily Attestation' -DaysBack 7
    # Scope to specific campaign prefix, last 7 days.
.EXAMPLE
    .\Invoke-SPHierarchicalReport.ps1 -MinReportLevel 2 -OutputPath '.\Reports\VPs'
    # Only generate VP-and-above files (skip per-director files).
.EXAMPLE
    .\Invoke-SPHierarchicalReport.ps1 -WhatIf
    # Show what campaigns and certs would be included without writing any files.
.NOTES
    Script:  Invoke-SPHierarchicalReport.ps1
    Version: 1.0.0
    Exit codes:
        0 = Reports generated (or WhatIf completed)
        1 = No campaigns or certifications found in window
        3 = Authentication error
        4 = Configuration error
        5 = Report generation error
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$CampaignNameContains,

    [Parameter()]
    [int]$DaysBack = 30,

    [Parameter()]
    [ValidateSet('STAGED','ACTIVATING','ACTIVE','COMPLETING','COMPLETED','ERROR')]
    [string[]]$Status = @('COMPLETED','ACTIVE'),

    [Parameter()]
    [int]$OrgDepth = 5,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$MinReportLevel = 1,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ReportTitle = 'Certification Governance Rollup',

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [ValidateSet('Console', 'JSON', 'Both')]
    [string]$OutputMode = 'Console',

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
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';     Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DeltaCert\SP.DeltaCert.psd1'; Name = 'SP.DeltaCert'; Required = $true }
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

$correlationID = [guid]::NewGuid().ToString()

if (-not $ConfigPath) { $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot }

try { Initialize-SPLogging -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  Hierarchical Leadership Certification Report' -ForegroundColor Cyan
Write-Host "  CorrelationID: $correlationID" -ForegroundColor DarkGray
Write-Host ''

$config = $null
try { $config = Get-SPConfig -ConfigPath $ConfigPath }
catch {
    Write-Host "ERROR: Failed to load configuration: $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}

if (Test-SPConfigFirstRun -Config $config) {
    Write-Host "INFO: First-run configuration detected. Update settings.json and run again." -ForegroundColor Yellow
    exit 4
}

try { Initialize-SPLogging -Force -ErrorAction SilentlyContinue } catch { }

if ($Token) {
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 3
    }
    Write-Host "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" -ForegroundColor Green
}

# Resolve output path
$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $auditPath = '.\Audit'
    if ($null -ne $config.PSObject.Properties['Audit'] -and
        -not [string]::IsNullOrWhiteSpace($config.Audit.OutputPath)) {
        $auditPath = $config.Audit.OutputPath
    }
    $effectiveOutputPath = Join-Path $auditPath "HierarchicalReports"
}

#endregion

#region WhatIf preview

if (($WhatIfPreference -eq $true)) {
    Write-Host '  [WhatIf] Dry-run mode — no files will be written.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Would generate hierarchical reports with:' -ForegroundColor Cyan
    Write-Host "    DaysBack:         $DaysBack"
    Write-Host "    Status:           $($Status -join ', ')"
    Write-Host "    CampaignFilter:   $(if([string]::IsNullOrWhiteSpace($CampaignNameContains)){'(all campaigns)'}else{$CampaignNameContains})"
    Write-Host "    OrgDepth:         $OrgDepth"
    Write-Host "    MinReportLevel:   $MinReportLevel ($(switch($MinReportLevel){0{'managers+'}1{'directors+'}2{'VPs+'}3{'executives+'}default{'custom'}}))"
    Write-Host "    OutputPath:       $effectiveOutputPath"
    Write-Host ''
}

#endregion

#region Data Collection

$runStart = Get-Date

# Step 1: Get campaigns in window
Write-Host "  Step 1: Fetching campaigns (last $DaysBack days, status: $($Status -join '/'))..." -ForegroundColor Cyan
$campParams = @{
    Status        = $Status
    DaysBack      = $DaysBack
    CorrelationID = $correlationID
}
if (-not [string]::IsNullOrWhiteSpace($CampaignNameContains)) {
    $campParams['CampaignNameContains'] = $CampaignNameContains
}

$campResult = Get-SPAuditCampaigns @campParams
if (-not $campResult.Success) {
    Write-Host "ERROR: Campaign fetch failed: $($campResult.Error)" -ForegroundColor Red
    exit 5
}
$campaigns = @($campResult.Data)
Write-Host "  Found $($campaigns.Count) campaign(s)" -ForegroundColor DarkGray

if ($campaigns.Count -eq 0) {
    Write-Host ''
    Write-Host '  No campaigns found in the specified window.' -ForegroundColor Yellow
    exit 1
}

if (($WhatIfPreference -eq $true)) {
    Write-Host ''
    Write-Host "  WhatIf: Would process $($campaigns.Count) campaign(s):" -ForegroundColor Cyan
    $campaigns | Select-Object -First 10 | ForEach-Object {
        Write-Host "    - $($_.name)  [$($_.status)]" -ForegroundColor DarkGray
    }
    if ($campaigns.Count -gt 10) {
        Write-Host "    ... and $($campaigns.Count - 10) more" -ForegroundColor DarkGray
    }
    exit 0
}

# Step 2: Get certifications (to build certifier ID map)
Write-Host "  Step 2: Fetching certifications..." -ForegroundColor Cyan
$allCerts = [System.Collections.Generic.List[object]]::new()
foreach ($camp in $campaigns) {
    $certsResult = Get-SPAuditCertifications -CampaignId $camp.id -CorrelationID $correlationID
    if ($certsResult.Success) {
        foreach ($cert in @($certsResult.Data)) { $allCerts.Add($cert) }
    }
}
Write-Host "  Found $($allCerts.Count) certification(s)" -ForegroundColor DarkGray

if ($allCerts.Count -eq 0) {
    Write-Host '  No certifications found in the campaigns.' -ForegroundColor Yellow
    exit 1
}

# Step 3: Build certifier ID map (certId → reviewerIdentityId)
# ISC v3 API uses 'reviewer' on certification objects; some internal/SDK paths use 'certifier'.
# We check both so the script works against the real ISC API, mock servers, and SDK payloads.
$certReviewerIdMap = @{}
foreach ($cert in $allCerts) {
    $certId = [string]$cert.id
    $certifierId = ''
    foreach ($prop in @('certifier', 'reviewer')) {
        if ($null -ne $cert.PSObject.Properties[$prop] -and
            $null -ne $cert.$prop -and
            $null -ne $cert.$prop.PSObject.Properties['id'] -and
            -not [string]::IsNullOrWhiteSpace($cert.$prop.id)) {
            $certifierId = [string]$cert.$prop.id
            break
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($certifierId)) {
        $certReviewerIdMap[$certId] = $certifierId
    }
}
$uniqueCertifierIds = @($certReviewerIdMap.Values | Select-Object -Unique)
Write-Host "  Found $($uniqueCertifierIds.Count) unique certifier(s)" -ForegroundColor DarkGray

if ($uniqueCertifierIds.Count -eq 0) {
    Write-Host '  No reviewer/certifier identity IDs found in certifications. Cannot build org tree.' -ForegroundColor Yellow
    Write-Host '  ISC certification objects must have reviewer.id (v3 API) or certifier.id (SDK).' -ForegroundColor DarkGray
    Write-Host '  This field is populated by default for standard certifications — check your PAT scopes.' -ForegroundColor DarkGray
    exit 1
}

# Step 4: Get certification items (decision data)
# Group-SPAuditDecisions expects enriched wrappers: @{Item; CertificationId; CertificationName; CampaignName}
# Build a campaign-name lookup from the campaigns array for efficient access
Write-Host "  Step 3: Fetching certification items (decisions)..." -ForegroundColor Cyan
$campNameById = @{}
foreach ($camp in $campaigns) {
    if ($camp.PSObject.Properties['id'] -and $camp.PSObject.Properties['name']) {
        $campNameById[[string]$camp.id] = [string]$camp.name
    }
}

$allItems = [System.Collections.Generic.List[object]]::new()
$certCount = $allCerts.Count
$certIdx   = 0
foreach ($cert in $allCerts) {
    $certIdx++
    if ($certCount -le 50 -or ($certIdx % 10 -eq 0)) {
        Write-Host "    Processing cert $certIdx of $certCount..." -ForegroundColor DarkGray
    }
    $certId   = [string]$cert.id
    $certName = if ($cert.PSObject.Properties['name']) { [string]$cert.name } else { $certId }
    $campId   = ''
    if ($cert.PSObject.Properties['campaign'] -and $null -ne $cert.campaign -and
        $cert.campaign.PSObject.Properties['id']) { $campId = [string]$cert.campaign.id }
    $campName = if (-not [string]::IsNullOrWhiteSpace($campId) -and $campNameById.ContainsKey($campId)) {
        $campNameById[$campId] } else { '' }

    $itemsResult = Get-SPAuditCertificationItems -CertificationId $certId -CorrelationID $correlationID
    if ($itemsResult.Success) {
        foreach ($item in @($itemsResult.Data)) {
            # Wrap raw item with cert/campaign context required by Group-SPAuditDecisions
            $allItems.Add(@{
                Item              = $item
                CertificationId   = $certId
                CertificationName = $certName
                CampaignName      = $campName
            })
        }
    }
}
Write-Host "  Found $($allItems.Count) certification item(s)" -ForegroundColor DarkGray

if ($allItems.Count -eq 0) {
    Write-Host '  No certification items found. Reports would be empty.' -ForegroundColor Yellow
    exit 1
}

# Step 5: Group decisions
Write-Host "  Step 4: Grouping decisions..." -ForegroundColor Cyan
$decisions = Group-SPAuditDecisions -Items $allItems.ToArray()

$totalA = @($decisions.Approved).Count
$totalR = @($decisions.Revoked).Count
$totalP = @($decisions.Pending).Count
Write-Host "  Decisions: $totalA approved, $totalR revoked, $totalP pending" -ForegroundColor DarkGray

# Step 6: Build org tree from certifier IDs
Write-Host "  Step 5: Building org tree (depth=$OrgDepth)..." -ForegroundColor Cyan
$orgTreeResult = Build-SPOrgTree -IdentityIds $uniqueCertifierIds -MaxDepth $OrgDepth `
    -CorrelationID $correlationID
if (-not $orgTreeResult.Success) {
    Write-Host "ERROR: Org tree build failed: $($orgTreeResult.Error)" -ForegroundColor Red
    exit 5
}
$orgTree = $orgTreeResult.Data
Write-Host "  Org tree: $($orgTree.Nodes.Count) node(s), top level=$($orgTree.TopLevel)" -ForegroundColor DarkGray

# Step 7: Build leadership hierarchy (join decisions to org tree)
Write-Host "  Step 6: Building leadership hierarchy..." -ForegroundColor Cyan
$hierarchyResult = Build-SPLeadershipHierarchy -Decisions $decisions -OrgTree $orgTree `
    -CertReviewerIdMap $certReviewerIdMap -CorrelationID $correlationID
if (-not $hierarchyResult.Success) {
    Write-Host "ERROR: Hierarchy build failed: $($hierarchyResult.Error)" -ForegroundColor Red
    exit 5
}

#endregion

#region Generate Reports

if (-not (Test-Path -Path $effectiveOutputPath -PathType Container)) {
    New-Item -Path $effectiveOutputPath -ItemType Directory -Force | Out-Null
}

$startStr = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-dd')
$endStr   = (Get-Date).ToString('yyyy-MM-dd')
$dateRange = "$startStr to $endStr"

Write-Host "  Step 7: Generating HTML reports (MinLevel=$MinReportLevel)..." -ForegroundColor Cyan

$exportResult = Export-SPHierarchicalLeadershipHtml `
    -HierarchyData $hierarchyResult.Data `
    -OutputPath    $effectiveOutputPath `
    -ReportTitle   $ReportTitle `
    -DateRange     $dateRange `
    -CampaignCount $campaigns.Count `
    -MinReportLevel $MinReportLevel `
    -CorrelationID  $correlationID

if (-not $exportResult.Success) {
    Write-Host "ERROR: Report export failed: $($exportResult.Error)" -ForegroundColor Red
    exit 5
}

$runEnd      = Get-Date
$runDuration = [math]::Round(($runEnd - $runStart).TotalSeconds, 1)

#endregion

#region Output

$summary = [PSCustomObject]@{
    CorrelationID       = $correlationID
    StartedAt           = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt         = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds     = $runDuration
    Campaigns           = $campaigns.Count
    Certifications      = $allCerts.Count
    Items               = $allItems.Count
    Approved            = $totalA
    Revoked             = $totalR
    Pending             = $totalP
    OrgNodes            = $orgTree.Nodes.Count
    ReportsGenerated    = $exportResult.Data.FileCount
    OutputPath          = $effectiveOutputPath
    Files               = $exportResult.Data.Files
    Environment         = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 5
    }
    default {
        Write-Host ''
        Write-Host '  Hierarchical Leadership Report Complete' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Campaigns:            $($campaigns.Count)" -ForegroundColor DarkGray
        Write-Host "  Certifications:       $($allCerts.Count)" -ForegroundColor DarkGray
        Write-Host "  Decision items:       $($allItems.Count)   (A=$totalA R=$totalR P=$totalP)" -ForegroundColor DarkGray
        Write-Host "  Org nodes:            $($orgTree.Nodes.Count)" -ForegroundColor DarkGray
        Write-Host "  Reports generated:    $($exportResult.Data.FileCount)" -ForegroundColor Green
        Write-Host "  Output directory:     $effectiveOutputPath" -ForegroundColor DarkGray
        Write-Host "  Duration:             $runDuration s" -ForegroundColor DarkGray
        Write-Host ''
        if ($exportResult.Data.FileCount -gt 0) {
            Write-Host '  Generated files:' -ForegroundColor DarkGray
            foreach ($f in $exportResult.Data.Files) {
                Write-Host "    $f" -ForegroundColor White
            }
        }
        Write-Host ''
        if ($OutputMode -eq 'Both') {
            $summary | ConvertTo-Json -Depth 5
        }
    }
}

Write-SPLog -Message "Invoke-SPHierarchicalReport completed: Reports=$($exportResult.Data.FileCount) Items=$($allItems.Count) Duration=${runDuration}s" `
    -Severity INFO -Component 'Invoke-SPHierarchicalReport' -Action 'Complete' -CorrelationID $correlationID

exit 0

#endregion
