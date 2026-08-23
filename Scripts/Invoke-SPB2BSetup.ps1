#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the SailPoint ISC governance layer for a B2B partner: access profiles,
    criteria-based roles, transform lookup, and an optional certification campaign.
.DESCRIPTION
    Entry point CLI script for B2B guest governance setup. It picks up where the
    Entra-side work stops: the app registration, the CLD-B2B-* security groups,
    and the ISC source connection are created manually (change control). This
    script configures everything ISC-side on top of an already-aggregated source.

    1. Verifies the ISC source exists and looks like an Entra connector
    2. Verifies the partner's CLD-B2B-* groups aggregated as entitlements
    3. Creates one access profile per entitlement (idempotent)
    4. Creates baseline and leadership roles with membership criteria (idempotent)
    5. Verifies ADD_ENTITLEMENT / REMOVE_ENTITLEMENT provisioning policies exist
    6. Deploys or updates the partner-domain lookup transform (-IncludeTransform)
    7. Creates a SEARCH certification campaign (-CreateCampaign)
    8. Prints a summary and appends a JSONL audit trail

    Every create step performs a GET first and skips objects that already exist,
    so re-running after a partial failure is safe.

    CERTIFIER SEMANTICS:
        B2B guests arrive via cross-tenant sync and have NO manager identity in
        the local tenant, so a manager-reviewed campaign would assign every review
        to nobody. This script therefore NEVER falls back to manager review. The
        certifier resolves in order: -CertifierIdentityId / config
        B2B.CertifierIdentityId -> the source's owner.id -> -OwnerIdentityId. If
        none resolve, campaign creation is REFUSED (exit 4).

    SCOPE REQUIREMENT:
        Reads need source, entitlement, access-profile, role, and transform read
        permission. Writes need access-profile, role, and transform manage
        permission, and the aggregation triggers need source manage permission --
        the toolkit's usual read-only PAT is not sufficient. A browser JWT from an
        ISC admin console session (-Token) carries admin permissions and is the
        simplest option for a one-time setup.

.PARAMETER PartnerName
    Partner identifier used in group, access profile, and role naming.
    Example: 'PartnerA' -> groups CLD-B2B-PartnerA-*, role B2B-PartnerA-User.
.PARAMETER PartnerDomain
    Partner email domain used in role criteria and the transform lookup table.
    Example: 'partnera.com'
.PARAMETER SourceId
    ISC source ID for the Entra connector. Either this or -SourceName is required.
.PARAMETER SourceName
    ISC source name, resolved to an ID by exact-name lookup. Alternative to -SourceId.
.PARAMETER OwnerIdentityId
    IAM admin identity ID recorded as owner on every access profile and role.
.PARAMETER Tier2Apps
    Optional app names expected to have elevated groups
    ({Prefix}-{Partner}-{App}-Admin). Missing app groups are reported as warnings.
.PARAMETER LeadershipTitles
    Job title keywords for the leadership role criteria.
    Defaults to config B2B.DefaultLeadershipTitles.
.PARAMETER GroupPrefix
    Entra group name prefix. Defaults to config B2B.GroupPrefix (CLD-B2B).
.PARAMETER UserTypeAttribute
    Identity attribute property for the guest check. Default: attribute.userType.
.PARAMETER EmailAttribute
    Identity attribute property for the domain check. Default: attribute.email.
.PARAMETER JobTitleAttribute
    Identity attribute property for the leadership check. Default: attribute.jobTitle.
.PARAMETER TriggerAggregation
    When entitlements are missing, trigger an entitlement aggregation and stop so
    the run can be retried once ISC finishes processing.
.PARAMETER IncludeTransform
    Deploy or update the partner-domain lookup transform.
.PARAMETER TransformName
    Name of the lookup transform. Default: 'B2B Partner Group Resolver'.
.PARAMETER TransformDefault
    Fallback group name for unmatched domains. Default: 'CLD-B2B-Unknown-Review'.
.PARAMETER CreateCampaign
    Create a SEARCH certification campaign covering the partner's B2B guests.
.PARAMETER CampaignDeadline
    Campaign deadline. Defaults to today plus config B2B.DefaultCertDeadlineDays.
.PARAMETER CertifierIdentityId
    Explicit campaign certifier. Overrides config B2B.CertifierIdentityId.
.PARAMETER OutputPath
    Directory for the JSONL audit trail. Default: .\Audit\b2b.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
    The "Bearer " prefix is stripped automatically if present.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER OutputMode
    Console (default): formatted summary to terminal.
    JSON: machine-parseable result object.
    Both: console output followed by the JSON object.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPB2BSetup.ps1 -PartnerName 'PartnerA' -PartnerDomain 'partnera.com' `
        -SourceName 'Entra ID - CORP' -OwnerIdentityId 'ident-iam-admin' -WhatIf
    # Dry run: show every access profile and role that would be created.
.EXAMPLE
    .\Invoke-SPB2BSetup.ps1 -PartnerName 'PartnerA' -PartnerDomain 'partnera.com' `
        -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
        -Tier2Apps 'SvcNow','SharePoint' -Token 'eyJhbGciOiJSUzI1...'
    # Full setup with elevated app groups, using an admin browser token.
.EXAMPLE
    .\Invoke-SPB2BSetup.ps1 -PartnerName 'PartnerA' -PartnerDomain 'partnera.com' `
        -SourceId 'src-entra-001' -OwnerIdentityId 'ident-iam-admin' `
        -IncludeTransform -CreateCampaign -CertifierIdentityId 'ident-iam-lead'
    # Setup plus transform deployment and a certification campaign.
.NOTES
    Script:  Invoke-SPB2BSetup.ps1
    Version: 1.0.0
    Exit codes:
        0 = Setup completed successfully
        1 = Entitlements not found (groups not aggregated)
        2 = Parameter error
        3 = API error (auth failure, rate limit, etc.)
        4 = Configuration error
        5 = Partial completion (some steps succeeded, some failed -- see audit log)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PartnerName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PartnerDomain,

    [Parameter()]
    [string]$SourceId,

    [Parameter()]
    [string]$SourceName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OwnerIdentityId,

    [Parameter()]
    [string[]]$Tier2Apps,

    [Parameter()]
    [string[]]$LeadershipTitles,

    [Parameter()]
    [string]$GroupPrefix,

    [Parameter()]
    [string]$UserTypeAttribute = 'attribute.userType',

    [Parameter()]
    [string]$EmailAttribute = 'attribute.email',

    [Parameter()]
    [string]$JobTitleAttribute = 'attribute.jobTitle',

    [Parameter()]
    [switch]$TriggerAggregation,

    [Parameter()]
    [switch]$IncludeTransform,

    [Parameter()]
    [string]$TransformName = 'B2B Partner Group Resolver',

    [Parameter()]
    [string]$TransformDefault = 'CLD-B2B-Unknown-Review',

    [Parameter()]
    [switch]$CreateCampaign,

    [Parameter()]
    [datetime]$CampaignDeadline,

    [Parameter()]
    [string]$CertifierIdentityId,

    [Parameter()]
    [string]$OutputPath,

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
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$toolkitRoot = Split-Path -Parent $scriptRoot

$moduleChain = @(
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1'; Name = 'SP.Shared'; Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';     Name = 'SP.Core';   Required = $true }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Api\SP.Api.psd1';       Name = 'SP.Api';    Required = $true }
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
$runStart      = Get-Date

if ([string]::IsNullOrWhiteSpace($SourceId) -and [string]::IsNullOrWhiteSpace($SourceName)) {
    Write-Host 'ERROR: Supply either -SourceId or -SourceName.' -ForegroundColor Red
    exit 2
}

if (-not $ConfigPath) {
    $ConfigPath = Resolve-SPConfigPath -ToolkitRoot $toolkitRoot
}

try {
    Initialize-SPLogging -ErrorAction SilentlyContinue
} catch { }

Write-Host ''
Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
Write-Host '  B2B Governance Setup' -ForegroundColor Cyan
Write-Host "  Partner:         $PartnerName ($PartnerDomain)" -ForegroundColor Cyan
Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
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
    Write-Host 'INFO: First-run configuration detected. Update settings.json and run again.' -ForegroundColor Yellow
    exit 4
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host 'ERROR: Configuration validation failed. Check settings.json for required values.' -ForegroundColor Red
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

Write-Host '  NOTE: B2B setup performs writes. Your token needs access-profile, role, and' -ForegroundColor DarkGray
Write-Host '        transform manage permission (plus source manage to trigger aggregation).' -ForegroundColor DarkGray
Write-Host '        The toolkit read-only PAT is not sufficient; use an admin browser token.' -ForegroundColor DarkGray
Write-Host ''

# Apply config defaults for parameters not explicitly provided
$b2bConfig = $null
if ($null -ne $config.PSObject.Properties['B2B'] -and $null -ne $config.B2B) {
    $b2bConfig = $config.B2B
}

$effectivePrefix = $GroupPrefix
if ([string]::IsNullOrWhiteSpace($effectivePrefix)) {
    if ($null -ne $b2bConfig -and
        $null -ne $b2bConfig.PSObject.Properties['GroupPrefix'] -and
        -not [string]::IsNullOrWhiteSpace($b2bConfig.GroupPrefix)) {
        $effectivePrefix = [string]$b2bConfig.GroupPrefix
    }
    else {
        $effectivePrefix = 'CLD-B2B'
    }
}

$effectiveTitles = $LeadershipTitles
if ($null -eq $effectiveTitles -or @($effectiveTitles).Count -eq 0) {
    if ($null -ne $b2bConfig -and
        $null -ne $b2bConfig.PSObject.Properties['DefaultLeadershipTitles'] -and
        @($b2bConfig.DefaultLeadershipTitles).Count -gt 0) {
        $effectiveTitles = @($b2bConfig.DefaultLeadershipTitles)
    }
    else {
        $effectiveTitles = @('Director', 'VP', 'Chief')
    }
}

$effectiveDeadlineDays = 30
if ($null -ne $b2bConfig -and
    $null -ne $b2bConfig.PSObject.Properties['DefaultCertDeadlineDays'] -and
    [int]$b2bConfig.DefaultCertDeadlineDays -gt 0) {
    $effectiveDeadlineDays = [int]$b2bConfig.DefaultCertDeadlineDays
}

$effectiveCreateCampaign = [bool]$CreateCampaign
if (-not $effectiveCreateCampaign -and
    $null -ne $b2bConfig -and
    $null -ne $b2bConfig.PSObject.Properties['AutoCreateCampaign']) {
    $effectiveCreateCampaign = [bool]$b2bConfig.AutoCreateCampaign
}

$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $effectiveOutputPath = '.\Audit\b2b'
}

$groupPrefixForPartner = "$effectivePrefix-$PartnerName"
$isDryRun = ($WhatIfPreference -eq $true)

# Result verbs recorded in the summary and audit trail. A dry run still walks
# every step, so the record has to distinguish planned work from applied work.
$createdVerb = 'Created'
$updatedVerb = 'Updated'
if ($isDryRun) {
    $createdVerb = 'WouldCreate'
    $updatedVerb = 'WouldUpdate'
}

# Audit trail: one JSONL record per governance action, appended as the run proceeds
# so a mid-run failure still leaves evidence of everything already applied.
$auditEvents = [System.Collections.Generic.List[object]]::new()

function Add-B2BAuditEvent {
    param(
        [string]$Step,
        [string]$Action,
        [string]$Target,
        [string]$Result,
        [string]$ObjectId,
        [string]$Detail
    )
    $auditEvents.Add([ordered]@{
        Timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        CorrelationID = $correlationID
        Partner       = $PartnerName
        Step          = $Step
        Action        = $Action
        Target        = $Target
        Result        = $Result
        ObjectId      = $ObjectId
        Detail        = $Detail
        WhatIf        = $isDryRun
    })
}

# Flushes the audit events to the JSONL trail. Called from every exit path, not
# just the final summary: a run refused at the campaign step has already mutated
# the tenant in steps 3-6, and that evidence must survive the early exit.
function Write-B2BAuditTrail {
    if ($auditEvents.Count -eq 0) { return $null }
    try {
        # -WhatIf:$false -- the audit trail is local evidence of the run, not a
        # tenant write. Without this the script's own SupportsShouldProcess
        # suppresses the directory creation and a dry run leaves no record.
        if (-not (Test-Path $effectiveOutputPath)) {
            New-Item -ItemType Directory -Path $effectiveOutputPath -Force -WhatIf:$false | Out-Null
        }
        $auditFile = Join-Path $effectiveOutputPath 'b2b-setup-audit.jsonl'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $lines     = New-Object System.Text.StringBuilder
        foreach ($evt in $auditEvents) {
            [void]$lines.Append(($evt | ConvertTo-Json -Depth 5 -Compress))
            [void]$lines.Append("`n")
        }
        [System.IO.File]::AppendAllText($auditFile, $lines.ToString(), $utf8NoBom)
        return $auditFile
    }
    catch {
        Write-Host "  WARN: Failed to write audit trail: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

$stepStatus = [ordered]@{
    'Source'              = 'Pending'
    'Entitlements'        = 'Pending'
    'AccessProfiles'      = 'Pending'
    'Roles'               = 'Pending'
    'ProvisioningPolicy'  = 'Pending'
    'Transform'           = 'Skipped'
    'Campaign'            = 'Skipped'
}
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

Write-SPLog -Message "Invoke-SPB2BSetup started: Partner='$PartnerName' Domain='$PartnerDomain' Prefix='$effectivePrefix'" `
    -Severity INFO -Component 'Invoke-SPB2BSetup' -Action 'Start' -CorrelationID $correlationID

if ($isDryRun) {
    Write-Host '  [WhatIf] Dry-run mode. No write API calls will be made.' -ForegroundColor Yellow
    Write-Host ''
}

#endregion

#region Step 1: Verify Source

Write-Host '  Step 1: Verifying ISC source...' -ForegroundColor Cyan

$resolvedSourceId   = $SourceId
$resolvedSourceName = $SourceName

if ([string]::IsNullOrWhiteSpace($resolvedSourceId)) {
    $lookup = Get-SPSources -Name $SourceName -CorrelationID $correlationID
    if (-not $lookup.Success) {
        Write-Host "ERROR: Source lookup failed: $($lookup.Error)" -ForegroundColor Red
        if ($lookup.Error -match '403|forbidden') {
            Write-Host '       The token lacks source read permission.' -ForegroundColor Yellow
        }
        exit 3
    }
    $sourceMatches = @($lookup.Data)
    if ($sourceMatches.Count -eq 0) {
        Write-Host "ERROR: No source named '$SourceName' found in this tenant." -ForegroundColor Red
        exit 2
    }
    if ($sourceMatches.Count -gt 1) {
        Write-Host "ERROR: $($sourceMatches.Count) sources named '$SourceName'. Use -SourceId to disambiguate." -ForegroundColor Red
        exit 2
    }
    $resolvedSourceId = [string]$sourceMatches[0].id
}

$sourceResult = Get-SPSource -SourceId $resolvedSourceId -CorrelationID $correlationID
if (-not $sourceResult.Success) {
    Write-Host "ERROR: Source '$resolvedSourceId' could not be retrieved: $($sourceResult.Error)" -ForegroundColor Red
    if ($sourceResult.Error -match '403|forbidden') {
        Write-Host '       The token lacks source read permission.' -ForegroundColor Yellow
    }
    elseif ($sourceResult.Error -match '404|not found') {
        Write-Host '       No source with that ID exists in this tenant.' -ForegroundColor Yellow
    }
    $stepStatus['Source'] = 'Fail'
    Add-B2BAuditEvent -Step '1' -Action 'VerifySource' -Target $resolvedSourceId -Result 'Fail' -Detail $sourceResult.Error
    Write-B2BAuditTrail | Out-Null
    exit 3
}

$source             = $sourceResult.Data
$resolvedSourceName = [string]$source.name
$sourceConnector    = ''
if ($null -ne $source.PSObject.Properties['connector'] -and $null -ne $source.connector) {
    $sourceConnector = [string]$source.connector
}
$sourceOwnerId = ''
if ($null -ne $source.PSObject.Properties['owner'] -and $null -ne $source.owner -and
    $null -ne $source.owner.PSObject.Properties['id']) {
    $sourceOwnerId = [string]$source.owner.id
}

Write-Host "    Source:    $resolvedSourceName ($resolvedSourceId)" -ForegroundColor DarkGray
Write-Host "    Connector: $sourceConnector" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($sourceOwnerId)) {
    Write-Host "    Owner:     $sourceOwnerId" -ForegroundColor DarkGray
}

if ($sourceConnector -notmatch 'azure|entra') {
    $warnMsg = "Source connector is '$sourceConnector', not an Entra/Azure AD connector. Group entitlements may not behave as expected."
    Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
    $warnings.Add($warnMsg)
}

$stepStatus['Source'] = 'Pass'
Add-B2BAuditEvent -Step '1' -Action 'VerifySource' -Target $resolvedSourceName -Result 'Pass' -ObjectId $resolvedSourceId -Detail "connector=$sourceConnector"

#endregion

#region Step 2: Verify Entitlements Aggregated

Write-Host '  Step 2: Verifying aggregated entitlements...' -ForegroundColor Cyan

$entResult = Get-SPEntitlements -SourceId $resolvedSourceId -NamePrefix $groupPrefixForPartner `
    -CorrelationID $correlationID

if (-not $entResult.Success) {
    Write-Host "ERROR: Entitlement lookup failed: $($entResult.Error)" -ForegroundColor Red
    if ($entResult.Error -match '403|forbidden') {
        Write-Host '       The token lacks entitlement read permission.' -ForegroundColor Yellow
    }
    $stepStatus['Entitlements'] = 'Fail'
    Add-B2BAuditEvent -Step '2' -Action 'VerifyEntitlements' -Target $groupPrefixForPartner -Result 'Fail' -Detail $entResult.Error
    Write-B2BAuditTrail | Out-Null
    exit 3
}

$entitlements = @($entResult.Data)
$baselineName = "$groupPrefixForPartner-Users"
$baselineEnt  = $entitlements | Where-Object { $_.name -eq $baselineName } | Select-Object -First 1

if ($null -eq $baselineEnt) {
    Write-Host ''
    Write-Host "  No $groupPrefixForPartner-* baseline entitlement found." -ForegroundColor Yellow
    Write-Host "  Ensure groups exist in Entra and run entitlement aggregation before retrying." -ForegroundColor Yellow
    Write-Host "  Expected at minimum: $baselineName" -ForegroundColor Yellow

    if ($TriggerAggregation) {
        Write-Host ''
        Write-Host '  Triggering entitlement aggregation...' -ForegroundColor Cyan
        $aggParams = @{
            SourceId      = $resolvedSourceId
            CorrelationID = $correlationID
        }
        if ($isDryRun) { $aggParams['WhatIf'] = $true }
        $aggResult = Start-SPEntitlementAggregation @aggParams

        if ($aggResult.Success) {
            Write-Host '    Aggregation submitted. Re-run this script once ISC finishes processing.' -ForegroundColor Green
            Add-B2BAuditEvent -Step '2' -Action 'TriggerEntitlementAggregation' -Target $resolvedSourceId -Result 'Submitted'
        }
        else {
            Write-Host "    Aggregation trigger failed: $($aggResult.Error)" -ForegroundColor Red
            Write-Host '    Aggregation triggers write to the tenant; a 403 means source manage permission is missing.' -ForegroundColor Yellow
            Add-B2BAuditEvent -Step '2' -Action 'TriggerEntitlementAggregation' -Target $resolvedSourceId -Result 'Fail' -Detail $aggResult.Error
        }
    }
    else {
        Write-Host '  Re-run with -TriggerAggregation to start an entitlement aggregation now.' -ForegroundColor Yellow
    }

    $stepStatus['Entitlements'] = 'Fail'
    Add-B2BAuditEvent -Step '2' -Action 'VerifyEntitlements' -Target $baselineName -Result 'NotFound'
    $earlyAudit = Write-B2BAuditTrail
    if ($null -ne $earlyAudit) {
        Write-Host "  Audit trail:     $earlyAudit" -ForegroundColor DarkGray
    }
    Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

Write-Host "    Found $($entitlements.Count) entitlement(s) matching '$groupPrefixForPartner-*':" -ForegroundColor DarkGray
foreach ($ent in $entitlements) {
    Write-Host "      $($ent.name)" -ForegroundColor DarkGray
}

# Sample one guest carrying the baseline group and inspect the email attribute.
# When the tenant's email attribute maps to the guest UPN
# (user_partnera.com#EXT#@corp.onmicrosoft.com) rather than mail, the domain
# lookup and the email CONTAINS criteria both silently miss every guest.
$sampleQuery  = "attributes.userType:Guest AND @access(name:`"$baselineName`")"
$sampleResult = Invoke-SPApiRequest -Method POST -Endpoint '/search' -Body @{
    indices = @('identities')
    query   = @{ query = $sampleQuery }
    limit   = 1
} -CorrelationID $correlationID

if ($sampleResult.Success -and $null -ne $sampleResult.Data) {
    $sampleHits = @($sampleResult.Data)
    if ($sampleHits.Count -gt 0) {
        $sampleEmail = ''
        $sampleHit   = $sampleHits[0]
        if ($null -ne $sampleHit.PSObject.Properties['email'] -and $null -ne $sampleHit.email) {
            $sampleEmail = [string]$sampleHit.email
        }
        elseif ($null -ne $sampleHit.PSObject.Properties['attributes'] -and $null -ne $sampleHit.attributes -and
                $null -ne $sampleHit.attributes.PSObject.Properties['email']) {
            $sampleEmail = [string]$sampleHit.attributes.email
        }

        if ($sampleEmail -like '*#EXT#*') {
            $warnMsg = "Sampled guest email '$sampleEmail' contains #EXT#. The tenant's email identity attribute appears to map to the guest UPN, not mail. Domain matching in role criteria and the transform lookup will miss every guest until the mapping is corrected."
            Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
            $warnings.Add($warnMsg)
            Add-B2BAuditEvent -Step '2' -Action 'SampleGuestEmail' -Target $sampleEmail -Result 'Warn' -Detail 'UPN #EXT# format detected'
        }
        else {
            Write-Host "    Sampled guest email format looks usable for domain matching." -ForegroundColor DarkGray
            Add-B2BAuditEvent -Step '2' -Action 'SampleGuestEmail' -Result 'Pass'
        }
    }
    else {
        Write-Host '    No guest currently holds the baseline group -- email format not verified.' -ForegroundColor DarkGray
    }
}
else {
    Write-Host '    Guest sampling skipped (identity search unavailable).' -ForegroundColor DarkGray
}

$stepStatus['Entitlements'] = 'Pass'
Add-B2BAuditEvent -Step '2' -Action 'VerifyEntitlements' -Target $groupPrefixForPartner -Result 'Pass' -Detail "$($entitlements.Count) entitlement(s)"

# Report expected tier 2 app groups that did not aggregate
if ($null -ne $Tier2Apps) {
    foreach ($app in $Tier2Apps) {
        if ([string]::IsNullOrWhiteSpace($app)) { continue }
        $expected = "$groupPrefixForPartner-$app-Admin"
        $found    = $entitlements | Where-Object { $_.name -eq $expected } | Select-Object -First 1
        if ($null -eq $found) {
            $warnMsg = "Expected tier 2 group '$expected' not found among aggregated entitlements."
            Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
            $warnings.Add($warnMsg)
        }
    }
}

#endregion

#region Step 3: Create Access Profiles

Write-Host '  Step 3: Creating access profiles...' -ForegroundColor Cyan

# Classification drives requestability: baseline and leadership access is granted
# automatically by role criteria (not requestable); everything else is elevated
# tier 2 access that must go through access request and approval.
function Get-B2BGroupTier {
    param([string]$Suffix)
    if ($Suffix -eq 'Users')      { return 'Baseline' }
    if ($Suffix -eq 'Leadership') { return 'Leadership' }
    return 'Tier2'
}

$accessProfileMap = @{}   # entitlement name -> @{ Id; Name; Tier; Status }
$apCreated = 0
$apSkipped = 0

foreach ($ent in $entitlements) {
    $entName = [string]$ent.name
    $entId   = [string]$ent.id
    $suffix  = $entName
    if ($entName.StartsWith("$groupPrefixForPartner-")) {
        $suffix = $entName.Substring($groupPrefixForPartner.Length + 1)
    }
    $tier   = Get-B2BGroupTier -Suffix $suffix
    $apName = "B2B $PartnerName - $suffix Access"

    # Idempotency: GET before create. ISC returns 400 on a duplicate name rather
    # than returning the existing object, so a blind POST breaks every re-run.
    $existing = Get-SPAccessProfiles -Name $apName -CorrelationID $correlationID
    if (-not $existing.Success) {
        Write-Host "    ERROR: Access profile lookup failed for '$apName': $($existing.Error)" -ForegroundColor Red
        $failures.Add("Access profile lookup '$apName': $($existing.Error)")
        Add-B2BAuditEvent -Step '3' -Action 'LookupAccessProfile' -Target $apName -Result 'Fail' -Detail $existing.Error
        continue
    }

    $existingAp = @($existing.Data) | Select-Object -First 1
    if ($null -ne $existingAp) {
        Write-Host "    Exists:  $apName" -ForegroundColor DarkGray
        $accessProfileMap[$entName] = @{
            Id     = [string]$existingAp.id
            Name   = $apName
            Tier   = $tier
            Status = 'AlreadyExists'
        }
        $apSkipped++
        Add-B2BAuditEvent -Step '3' -Action 'CreateAccessProfile' -Target $apName -Result 'AlreadyExists' -ObjectId ([string]$existingAp.id)
        continue
    }

    $apParams = @{
        Name            = $apName
        SourceId        = $resolvedSourceId
        SourceName      = $resolvedSourceName
        OwnerIdentityId = $OwnerIdentityId
        EntitlementId   = @($entId)
        Description     = "B2B $tier access for $PartnerName guests. Entitlement: $entName. Managed by the SailPoint Governance Toolkit."
        CorrelationID   = $correlationID
    }
    if ($tier -eq 'Tier2') { $apParams['Requestable'] = $true }
    if ($isDryRun)         { $apParams['WhatIf'] = $true }

    $apResult = New-SPAccessProfile @apParams

    if (-not $apResult.Success) {
        Write-Host "    ERROR: Failed to create '$apName': $($apResult.Error)" -ForegroundColor Red
        $failures.Add("Access profile '$apName': $($apResult.Error)")
        Add-B2BAuditEvent -Step '3' -Action 'CreateAccessProfile' -Target $apName -Result 'Fail' -Detail $apResult.Error
        continue
    }

    $newApId = ''
    if ($null -ne $apResult.Data -and $null -ne $apResult.Data.PSObject.Properties['id']) {
        $newApId = [string]$apResult.Data.id
    }

    if ($isDryRun) {
        Write-Host "    Would create: $apName (tier=$tier, requestable=$($tier -eq 'Tier2'))" -ForegroundColor Yellow
    }
    else {
        Write-Host "    Created: $apName ($newApId)" -ForegroundColor Green
    }

    $accessProfileMap[$entName] = @{
        Id     = $newApId
        Name   = $apName
        Tier   = $tier
        Status = $createdVerb
    }
    $apCreated++
    Add-B2BAuditEvent -Step '3' -Action 'CreateAccessProfile' -Target $apName -Result $createdVerb -ObjectId $newApId -Detail "tier=$tier"
}

$stepStatus['AccessProfiles'] = if ($failures.Count -gt 0) { 'Partial' } else { 'Pass' }

#endregion

#region Step 4: Create Roles With Criteria

Write-Host '  Step 4: Creating roles with membership criteria...' -ForegroundColor Cyan
Write-Host "    Criteria attributes: $UserTypeAttribute, $EmailAttribute, $JobTitleAttribute" -ForegroundColor DarkGray
Write-Host '    Verify these match your ISC identity profile mappings -- tenants can rename them.' -ForegroundColor DarkGray

# Baseline criteria: userType is Guest AND email carries the partner domain.
$baselineCriteria = @{
    operation = 'AND'
    children  = @(
        @{
            operation = 'EQUALS'
            key       = @{ type = 'IDENTITY'; property = $UserTypeAttribute }
            value     = 'Guest'
        }
        @{
            operation = 'CONTAINS'
            key       = @{ type = 'IDENTITY'; property = $EmailAttribute }
            value     = $PartnerDomain
        }
    )
}

$roleResults = [System.Collections.Generic.List[object]]::new()

function New-B2BRoleIfMissing {
    param(
        [string]$RoleName,
        [string]$RoleDescription,
        [string[]]$AccessProfileIds,
        [hashtable]$RoleCriteria
    )

    $existing = Get-SPRoles -Name $RoleName -CorrelationID $correlationID
    if (-not $existing.Success) {
        Write-Host "    ERROR: Role lookup failed for '$RoleName': $($existing.Error)" -ForegroundColor Red
        $failures.Add("Role lookup '$RoleName': $($existing.Error)")
        Add-B2BAuditEvent -Step '4' -Action 'LookupRole' -Target $RoleName -Result 'Fail' -Detail $existing.Error
        return $null
    }

    $existingRole = @($existing.Data) | Select-Object -First 1
    if ($null -ne $existingRole) {
        Write-Host "    Exists:  $RoleName" -ForegroundColor DarkGray
        Add-B2BAuditEvent -Step '4' -Action 'CreateRole' -Target $RoleName -Result 'AlreadyExists' -ObjectId ([string]$existingRole.id)
        return @{ Name = $RoleName; Id = [string]$existingRole.id; Status = 'AlreadyExists' }
    }

    $roleParams = @{
        Name            = $RoleName
        OwnerIdentityId = $OwnerIdentityId
        Criteria        = $RoleCriteria
        Description     = $RoleDescription
        CorrelationID   = $correlationID
    }
    if ($null -ne $AccessProfileIds -and @($AccessProfileIds).Count -gt 0) {
        $roleParams['AccessProfileId'] = @($AccessProfileIds)
    }
    if ($isDryRun) { $roleParams['WhatIf'] = $true }

    $created = New-SPRole @roleParams

    if (-not $created.Success) {
        Write-Host "    ERROR: Failed to create role '$RoleName': $($created.Error)" -ForegroundColor Red
        $failures.Add("Role '$RoleName': $($created.Error)")
        Add-B2BAuditEvent -Step '4' -Action 'CreateRole' -Target $RoleName -Result 'Fail' -Detail $created.Error
        return $null
    }

    $newRoleId = ''
    if ($null -ne $created.Data -and $null -ne $created.Data.PSObject.Properties['id']) {
        $newRoleId = [string]$created.Data.id
    }

    if ($isDryRun) {
        Write-Host "    Would create: $RoleName" -ForegroundColor Yellow
    }
    else {
        Write-Host "    Created: $RoleName ($newRoleId)" -ForegroundColor Green
    }

    Add-B2BAuditEvent -Step '4' -Action 'CreateRole' -Target $RoleName -Result $createdVerb -ObjectId $newRoleId
    return @{ Name = $RoleName; Id = $newRoleId; Status = $createdVerb }
}

# Baseline role
$baselineApId = ''
if ($accessProfileMap.ContainsKey($baselineName)) {
    $baselineApId = [string]$accessProfileMap[$baselineName].Id
}
$baselineRole = New-B2BRoleIfMissing -RoleName "B2B-$PartnerName-User" `
    -RoleDescription "Auto-assigned to all $PartnerName B2B guests. Grants baseline application access." `
    -AccessProfileIds @($baselineApId) -RoleCriteria $baselineCriteria
if ($null -ne $baselineRole) { $roleResults.Add($baselineRole) }

# Leadership role -- only when the leadership group actually aggregated
$leadershipName = "$groupPrefixForPartner-Leadership"
if ($accessProfileMap.ContainsKey($leadershipName)) {
    $titleChildren = @()
    foreach ($title in $effectiveTitles) {
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $titleChildren += @{
            operation = 'CONTAINS'
            key       = @{ type = 'IDENTITY'; property = $JobTitleAttribute }
            value     = $title
        }
    }

    $leadershipCriteria = @{
        operation = 'AND'
        children  = @(
            @{
                operation = 'EQUALS'
                key       = @{ type = 'IDENTITY'; property = $UserTypeAttribute }
                value     = 'Guest'
            }
            @{
                operation = 'CONTAINS'
                key       = @{ type = 'IDENTITY'; property = $EmailAttribute }
                value     = $PartnerDomain
            }
            @{
                operation = 'OR'
                children  = @($titleChildren)
            }
        )
    }

    $leadershipRole = New-B2BRoleIfMissing -RoleName "B2B-$PartnerName-Leadership" `
        -RoleDescription "Auto-assigned to $PartnerName guests with leadership titles ($($effectiveTitles -join ', ')). Grants additional access." `
        -AccessProfileIds @([string]$accessProfileMap[$leadershipName].Id) -RoleCriteria $leadershipCriteria
    if ($null -ne $leadershipRole) { $roleResults.Add($leadershipRole) }
}
else {
    Write-Host "    Skipped: no '$leadershipName' entitlement, leadership role not created." -ForegroundColor DarkGray
}

$stepStatus['Roles'] = if ($roleResults.Count -eq 0) { 'Fail' } elseif ($failures.Count -gt 0) { 'Partial' } else { 'Pass' }

#endregion

#region Step 5: Verify Provisioning Policies

Write-Host '  Step 5: Verifying provisioning policies...' -ForegroundColor Cyan

$policyResult = Get-SPProvisioningPolicies -SourceId $resolvedSourceId -CorrelationID $correlationID

if (-not $policyResult.Success) {
    $warnMsg = "Provisioning policy check failed: $($policyResult.Error)"
    Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
    $warnings.Add($warnMsg)
    $stepStatus['ProvisioningPolicy'] = 'Warn'
    Add-B2BAuditEvent -Step '5' -Action 'VerifyProvisioningPolicies' -Target $resolvedSourceId -Result 'Warn' -Detail $policyResult.Error
}
else {
    $usageTypes = @()
    foreach ($pol in @($policyResult.Data)) {
        if ($null -ne $pol -and $null -ne $pol.PSObject.Properties['usageType'] -and $null -ne $pol.usageType) {
            $usageTypes += [string]$pol.usageType
        }
    }

    $hasAdd    = $usageTypes -contains 'ADD_ENTITLEMENT'
    $hasRemove = $usageTypes -contains 'REMOVE_ENTITLEMENT'

    if ($hasAdd -and $hasRemove) {
        Write-Host '    ADD_ENTITLEMENT and REMOVE_ENTITLEMENT policies present.' -ForegroundColor Green
        $stepStatus['ProvisioningPolicy'] = 'Pass'
        Add-B2BAuditEvent -Step '5' -Action 'VerifyProvisioningPolicies' -Target $resolvedSourceId -Result 'Pass'
    }
    else {
        $missing = @()
        if (-not $hasAdd)    { $missing += 'ADD_ENTITLEMENT' }
        if (-not $hasRemove) { $missing += 'REMOVE_ENTITLEMENT' }
        $warnMsg = "Provisioning policies not found: $($missing -join ', '). The Entra connector may not be configured for provisioning. Enable provisioning on the source in the ISC admin UI -- this script cannot create policies."
        Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
        $warnings.Add($warnMsg)
        $stepStatus['ProvisioningPolicy'] = 'Warn'
        Add-B2BAuditEvent -Step '5' -Action 'VerifyProvisioningPolicies' -Target $resolvedSourceId -Result 'Warn' -Detail "missing=$($missing -join ',')"
    }
}

#endregion

#region Step 6: Deploy Transform

$transformSummary = $null

if ($IncludeTransform) {
    Write-Host '  Step 6: Deploying partner group resolver transform...' -ForegroundColor Cyan

    # ISC lookup transforms are EXACT match: a table keyed 'partnera.com' never
    # matches the input 'user@partnera.com', so every guest would fall through to
    # the default entry. The input must therefore be a chain that reduces the
    # email to a bare lowercase domain BEFORE the lookup runs:
    #     email identity attribute -> split on '@' index 1 -> lower -> lookup
    $domainKey = $PartnerDomain.ToLower()
    $targetGroup = $baselineName

    $inputChain = @{
        type       = 'lower'
        attributes = @{
            input = @{
                type       = 'split'
                attributes = @{
                    input     = @{
                        type       = 'identityAttribute'
                        attributes = @{ name = 'email' }
                    }
                    delimiter = '@'
                    index     = 1
                    throws    = $true
                }
            }
        }
    }

    $existingTransform = Get-SPTransforms -Name $TransformName -CorrelationID $correlationID

    if (-not $existingTransform.Success) {
        $warnMsg = "Transform lookup failed: $($existingTransform.Error)"
        Write-Host "    Warning: $warnMsg" -ForegroundColor Yellow
        $warnings.Add($warnMsg)
        $stepStatus['Transform'] = 'Warn'
        Add-B2BAuditEvent -Step '6' -Action 'LookupTransform' -Target $TransformName -Result 'Fail' -Detail $existingTransform.Error
    }
    else {
        $found = @($existingTransform.Data) | Select-Object -First 1

        if ($null -eq $found) {
            $attrs = @{
                input   = $inputChain
                table   = @{ $domainKey = $targetGroup }
                default = $TransformDefault
            }

            $tfParams = @{
                Name          = $TransformName
                Type          = 'lookup'
                Attributes    = $attrs
                CorrelationID = $correlationID
            }
            if ($isDryRun) { $tfParams['WhatIf'] = $true }

            $tfResult = New-SPTransform @tfParams

            if ($tfResult.Success) {
                $tfId = ''
                if ($null -ne $tfResult.Data -and $null -ne $tfResult.Data.PSObject.Properties['id']) {
                    $tfId = [string]$tfResult.Data.id
                }
                if ($isDryRun) {
                    Write-Host "    Would create transform '$TransformName' with $domainKey -> $targetGroup" -ForegroundColor Yellow
                }
                else {
                    Write-Host "    Created transform: $TransformName ($tfId)" -ForegroundColor Green
                }
                $stepStatus['Transform'] = 'Pass'
                $transformSummary = @{ Name = $TransformName; Id = $tfId; Status = $createdVerb; Domain = $domainKey }
                Add-B2BAuditEvent -Step '6' -Action 'CreateTransform' -Target $TransformName -Result $createdVerb -ObjectId $tfId -Detail "$domainKey -> $targetGroup"
            }
            else {
                Write-Host "    ERROR: Transform creation failed: $($tfResult.Error)" -ForegroundColor Red
                $failures.Add("Transform '$TransformName': $($tfResult.Error)")
                $stepStatus['Transform'] = 'Fail'
                Add-B2BAuditEvent -Step '6' -Action 'CreateTransform' -Target $TransformName -Result 'Fail' -Detail $tfResult.Error
            }
        }
        else {
            # Update is a FULL replacement, so the existing table must be carried
            # forward -- sending only the new key would delete every other partner.
            $tfId = [string]$found.id
            $mergedTable = @{}
            if ($null -ne $found.PSObject.Properties['attributes'] -and $null -ne $found.attributes -and
                $null -ne $found.attributes.PSObject.Properties['table'] -and $null -ne $found.attributes.table) {
                foreach ($prop in $found.attributes.table.PSObject.Properties) {
                    $mergedTable[$prop.Name] = [string]$prop.Value
                }
            }
            $alreadyMapped = ($mergedTable.ContainsKey($domainKey) -and $mergedTable[$domainKey] -eq $targetGroup)
            $mergedTable[$domainKey] = $targetGroup

            $existingDefault = $TransformDefault
            if ($null -ne $found.PSObject.Properties['attributes'] -and $null -ne $found.attributes -and
                $null -ne $found.attributes.PSObject.Properties['default'] -and
                -not [string]::IsNullOrWhiteSpace($found.attributes.default)) {
                $existingDefault = [string]$found.attributes.default
            }

            $attrs = @{
                input   = $inputChain
                table   = $mergedTable
                default = $existingDefault
            }

            $tfParams = @{
                TransformId   = $tfId
                Name          = $TransformName
                Type          = 'lookup'
                Attributes    = $attrs
                CorrelationID = $correlationID
            }
            if ($isDryRun) { $tfParams['WhatIf'] = $true }

            $tfResult = Set-SPTransform @tfParams

            if ($tfResult.Success) {
                if ($alreadyMapped) {
                    Write-Host "    Transform '$TransformName' already maps $domainKey -> $targetGroup; input chain refreshed." -ForegroundColor DarkGray
                }
                elseif ($isDryRun) {
                    Write-Host "    Would update transform '$TransformName': add $domainKey -> $targetGroup ($($mergedTable.Count) total entries)" -ForegroundColor Yellow
                }
                else {
                    Write-Host "    Updated transform: $TransformName ($($mergedTable.Count) table entries)" -ForegroundColor Green
                }
                $stepStatus['Transform'] = 'Pass'
                $transformSummary = @{ Name = $TransformName; Id = $tfId; Status = $updatedVerb; Domain = $domainKey }
                Add-B2BAuditEvent -Step '6' -Action 'UpdateTransform' -Target $TransformName -Result $updatedVerb -ObjectId $tfId -Detail "$domainKey -> $targetGroup"
            }
            else {
                Write-Host "    ERROR: Transform update failed: $($tfResult.Error)" -ForegroundColor Red
                $failures.Add("Transform '$TransformName': $($tfResult.Error)")
                $stepStatus['Transform'] = 'Fail'
                Add-B2BAuditEvent -Step '6' -Action 'UpdateTransform' -Target $TransformName -Result 'Fail' -Detail $tfResult.Error
            }
        }
    }
}

#endregion

#region Step 7: Create Certification Campaign

$campaignSummary = $null

if ($effectiveCreateCampaign) {
    Write-Host '  Step 7: Creating certification campaign...' -ForegroundColor Cyan

    # Certifier resolution. B2B guests have no manager identity in the local
    # tenant, so manager review is NOT a fallback -- an unresolvable certifier is
    # a hard configuration failure, not a downgrade.
    $effectiveCertifier = $CertifierIdentityId
    $certifierSource    = 'parameter'

    if ([string]::IsNullOrWhiteSpace($effectiveCertifier) -and
        $null -ne $b2bConfig -and
        $null -ne $b2bConfig.PSObject.Properties['CertifierIdentityId'] -and
        -not [string]::IsNullOrWhiteSpace($b2bConfig.CertifierIdentityId)) {
        $effectiveCertifier = [string]$b2bConfig.CertifierIdentityId
        $certifierSource    = 'config B2B.CertifierIdentityId'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveCertifier) -and
        -not [string]::IsNullOrWhiteSpace($sourceOwnerId)) {
        $effectiveCertifier = $sourceOwnerId
        $certifierSource    = 'source owner'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveCertifier) -and
        -not [string]::IsNullOrWhiteSpace($OwnerIdentityId)) {
        $effectiveCertifier = $OwnerIdentityId
        $certifierSource    = 'access profile/role owner'
    }

    if ([string]::IsNullOrWhiteSpace($effectiveCertifier)) {
        Write-Host '  ERROR: No certifier could be resolved for the B2B campaign.' -ForegroundColor Red
        Write-Host '         B2B guests have no manager identity in this tenant, so manager review' -ForegroundColor Yellow
        Write-Host '         is never used as a fallback. Set -CertifierIdentityId or' -ForegroundColor Yellow
        Write-Host '         B2B.CertifierIdentityId in settings.json, or assign an owner to the source.' -ForegroundColor Yellow
        $stepStatus['Campaign'] = 'Fail'
        Add-B2BAuditEvent -Step '7' -Action 'ResolveCertifier' -Result 'Fail' -Detail 'No certifier resolved; campaign refused'
        Write-SPLog -Message 'B2B campaign refused: no resolvable certifier' `
            -Severity ERROR -Component 'Invoke-SPB2BSetup' -Action 'Campaign' -CorrelationID $correlationID
        # Steps 3-6 may have already written to the tenant; that record must
        # survive this refusal.
        $earlyAudit = Write-B2BAuditTrail
        if ($null -ne $earlyAudit) {
            Write-Host "  Audit trail:     $earlyAudit" -ForegroundColor DarkGray
        }
        Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
        Write-Host ''
        exit 4
    }

    Write-Host "    Certifier: $effectiveCertifier (from $certifierSource)" -ForegroundColor DarkGray

    $deadlineDate = $CampaignDeadline
    if ($null -eq $deadlineDate -or $deadlineDate -eq [datetime]::MinValue) {
        $deadlineDate = (Get-Date).AddDays($effectiveDeadlineDays)
    }
    $deadlineIso = $deadlineDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $campaignName = "B2B Guest Access Review - $PartnerName - $((Get-Date).ToString('yyyy-MM-dd'))"

    # Identity-index query: the partner's guests on this source holding any of the
    # partner's B2B groups. Same inline-filter path Invoke-SPDisconnectedAppCert
    # uses -- no saved search object required.
    $searchQuery = "@accounts.source.name:`"$resolvedSourceName`" AND attributes.userType:Guest AND @entitlements.name:$groupPrefixForPartner-*"

    # Idempotency: skip when a campaign with this exact name already exists.
    $existingCampaigns = Search-SPCampaigns -Keyword $campaignName -CorrelationID $correlationID
    $duplicate = $null
    if ($existingCampaigns.Success) {
        $duplicate = @($existingCampaigns.Data) | Where-Object { $_.name -eq $campaignName } | Select-Object -First 1
    }

    if ($null -ne $duplicate) {
        Write-Host "    Exists:  $campaignName ($($duplicate.id))" -ForegroundColor DarkGray
        $stepStatus['Campaign'] = 'Pass'
        $campaignSummary = @{ Name = $campaignName; Id = [string]$duplicate.id; Status = 'AlreadyExists'; Certifier = $effectiveCertifier }
        Add-B2BAuditEvent -Step '7' -Action 'CreateCampaign' -Target $campaignName -Result 'AlreadyExists' -ObjectId ([string]$duplicate.id)
    }
    elseif ($isDryRun) {
        Write-Host "    Would create campaign: $campaignName" -ForegroundColor Yellow
        Write-Host "      Query:    $searchQuery" -ForegroundColor DarkGray
        Write-Host "      Deadline: $deadlineIso" -ForegroundColor DarkGray
        $stepStatus['Campaign'] = 'Pass'
        $campaignSummary = @{ Name = $campaignName; Id = ''; Status = 'WouldCreate'; Certifier = $effectiveCertifier }
        Add-B2BAuditEvent -Step '7' -Action 'CreateCampaign' -Target $campaignName -Result 'WouldCreate' -Detail "certifier=$effectiveCertifier"
    }
    else {
        $campResult = New-SPCampaign -Name $campaignName -Type SEARCH `
            -SearchFilter $searchQuery -CertifierIdentityId $effectiveCertifier `
            -Deadline $deadlineIso `
            -Description "Access review of $PartnerName B2B guests holding $groupPrefixForPartner-* entitlements. Certifier assigned explicitly: B2B guests have no local manager." `
            -CorrelationID $correlationID

        if ($campResult.Success) {
            $campId = ''
            if ($null -ne $campResult.Data -and $null -ne $campResult.Data.PSObject.Properties['id']) {
                $campId = [string]$campResult.Data.id
            }
            Write-Host "    Created: $campaignName ($campId)" -ForegroundColor Green
            Write-Host '    Campaign is STAGED. Activate it in the ISC console or with Start-SPCampaign.' -ForegroundColor DarkGray
            $stepStatus['Campaign'] = 'Pass'
            $campaignSummary = @{ Name = $campaignName; Id = $campId; Status = 'Created'; Certifier = $effectiveCertifier }
            Add-B2BAuditEvent -Step '7' -Action 'CreateCampaign' -Target $campaignName -Result 'Created' -ObjectId $campId -Detail "certifier=$effectiveCertifier"
        }
        else {
            Write-Host "    ERROR: Campaign creation failed: $($campResult.Error)" -ForegroundColor Red
            $failures.Add("Campaign '$campaignName': $($campResult.Error)")
            $stepStatus['Campaign'] = 'Fail'
            Add-B2BAuditEvent -Step '7' -Action 'CreateCampaign' -Target $campaignName -Result 'Fail' -Detail $campResult.Error
        }
    }
}

#endregion

#region Step 8: Summary and Audit Trail

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

# Append the JSONL audit trail
$auditFilePath = Write-B2BAuditTrail

$summary = [PSCustomObject]@{
    CorrelationID     = $correlationID
    PartnerName       = $PartnerName
    PartnerDomain     = $PartnerDomain
    SourceId          = $resolvedSourceId
    SourceName        = $resolvedSourceName
    GroupPrefix       = $groupPrefixForPartner
    StartedAt         = $runStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CompletedAt       = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    DurationSeconds   = [math]::Round($runDuration, 2)
    WhatIf            = $isDryRun
    EntitlementCount  = $entitlements.Count
    AccessProfiles    = @($accessProfileMap.Keys | ForEach-Object { $accessProfileMap[$_] })
    Roles             = $roleResults.ToArray()
    Transform         = $transformSummary
    Campaign          = $campaignSummary
    Checklist         = $stepStatus
    Warnings          = $warnings.ToArray()
    Failures          = $failures.ToArray()
    AuditFile         = $auditFilePath
    Environment       = $config.Global.EnvironmentName
}

switch ($OutputMode) {
    'JSON' {
        $summary | ConvertTo-Json -Depth 10
    }
    default {
        Write-Host ''
        Write-Host '  B2B Governance Setup Summary' -ForegroundColor Cyan
        Write-Host "  $('=' * 60)" -ForegroundColor DarkGray
        Write-Host "  Partner:           $PartnerName ($PartnerDomain)" -ForegroundColor DarkGray
        Write-Host "  Source:            $resolvedSourceName ($resolvedSourceId)" -ForegroundColor DarkGray
        Write-Host "  Entitlements:      $($entitlements.Count)" -ForegroundColor DarkGray
        Write-Host "  Access profiles:   $apCreated created/planned, $apSkipped already existed" -ForegroundColor DarkGray
        Write-Host "  Roles:             $($roleResults.Count)" -ForegroundColor DarkGray
        foreach ($rr in $roleResults) {
            Write-Host "    $($rr.Name) -- $($rr.Status) $($rr.Id)" -ForegroundColor DarkGray
        }
        if ($null -ne $transformSummary) {
            Write-Host "  Transform:         $($transformSummary.Name) -- $($transformSummary.Status)" -ForegroundColor DarkGray
        }
        if ($null -ne $campaignSummary) {
            Write-Host "  Campaign:          $($campaignSummary.Name) -- $($campaignSummary.Status)" -ForegroundColor DarkGray
        }

        Write-Host ''
        Write-Host '  Validation checklist:' -ForegroundColor Cyan
        foreach ($key in $stepStatus.Keys) {
            $status = $stepStatus[$key]
            $color  = switch ($status) {
                'Pass'    { 'Green' }
                'Partial' { 'Yellow' }
                'Warn'    { 'Yellow' }
                'Fail'    { 'Red' }
                default   { 'DarkGray' }
            }
            Write-Host ("    {0,-20} {1}" -f $key, $status) -ForegroundColor $color
        }

        if ($warnings.Count -gt 0) {
            Write-Host ''
            Write-Host "  Warnings ($($warnings.Count)):" -ForegroundColor Yellow
            foreach ($w in $warnings) {
                Write-Host "    $w" -ForegroundColor Yellow
            }
        }

        if ($failures.Count -gt 0) {
            Write-Host ''
            Write-Host "  Failures ($($failures.Count)):" -ForegroundColor Red
            foreach ($f in $failures) {
                Write-Host "    $f" -ForegroundColor Red
            }
        }

        Write-Host ''
        Write-Host '  Next steps:' -ForegroundColor Cyan
        Write-Host '    Role criteria are evaluated during identity refresh, not at creation time.' -ForegroundColor DarkGray
        Write-Host '    Run an identity refresh (or wait for the next aggregation cycle) before' -ForegroundColor DarkGray
        Write-Host '    expecting guests to appear in the new roles.' -ForegroundColor DarkGray
        if ($null -ne $campaignSummary -and $campaignSummary.Status -eq 'Created') {
            Write-Host '    Activate the staged campaign when the access assignments have settled.' -ForegroundColor DarkGray
        }

        if ($null -ne $auditFilePath) {
            Write-Host ''
            Write-Host "  Audit trail:     $auditFilePath" -ForegroundColor DarkGray
        }
        Write-Host "  Duration:        $($summary.DurationSeconds) seconds" -ForegroundColor DarkGray
        Write-Host "  Environment:     $($summary.Environment)" -ForegroundColor DarkGray
        Write-Host "  CorrelationID:   $correlationID" -ForegroundColor DarkGray
        Write-Host ''

        if ($OutputMode -eq 'Both') {
            Write-Host '  JSON Output:' -ForegroundColor Cyan
            $summary | ConvertTo-Json -Depth 10
        }
    }
}

Write-SPLog -Message "Invoke-SPB2BSetup completed: Partner='$PartnerName' AccessProfiles=$($accessProfileMap.Count) Roles=$($roleResults.Count) Failures=$($failures.Count) Warnings=$($warnings.Count)" `
    -Severity INFO -Component 'Invoke-SPB2BSetup' -Action 'Complete' -CorrelationID $correlationID

#endregion

if ($failures.Count -gt 0) { exit 5 }

exit 0
