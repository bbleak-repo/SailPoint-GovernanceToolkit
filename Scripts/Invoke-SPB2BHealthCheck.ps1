#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that the ISC-side B2B guest governance layer is still intact and healthy.
.DESCRIPTION
    Ongoing verification companion to Invoke-SPB2BSetup.ps1. Run it weekly, and
    before every B2B certification campaign, to catch the failure modes that
    accumulate silently: a source that stopped aggregating, a new Entra group
    with no access profile, a role whose criteria reference an identity
    attribute the tenant renamed, a transform lookup missing a partner domain.

    Eleven checks are performed:

      1  Source exists and connection status                       FAIL if missing
      2  Last account aggregation within the account threshold     WARN if stale
      3  Aggregation timeline within the entitlement threshold     WARN if stale
      4  Every B2B entitlement has an access profile               FAIL per orphan
      5  Every B2B access profile is linked to a role              WARN per unlinked
      6  All B2B roles have non-empty membership criteria          FAIL per empty
      7  Role criteria reference known identity attributes         WARN if unknown
      8  Transform lookup covers all observed partner domains      WARN per gap
      9  ADD_ENTITLEMENT / REMOVE_ENTITLEMENT policies exist       FAIL if missing
      10 B2B guests with zero role assignments                     WARN with list
      11 Group naming convention compliance                        INFO

    Checks 1-6 reuse the SP.Audit inventory functions rather than re-implementing
    pagination: Get-SPSourceAggregationHealth supplies source status and
    aggregation freshness, and the entitlement / access profile / role
    inventories supply the catalogs this script cross-references.

    CHECK 3 CAVEAT:
        ISC exposes an account-aggregation history (/v3/account-aggregations) but
        no equivalent entitlement-aggregation history, so check 3 evaluates the
        same source aggregation timeline against the looser entitlement
        threshold. It answers "has this source synced recently enough that
        entitlement data should be trustworthy", not "when did load-entitlements
        last run".

    SCOPE REQUIREMENT:
        All checks are read-only. The token needs source, entitlement,
        access-profile, role, and transform read permission, plus identity search
        for check 10. A read-only PAT is sufficient; missing permission surfaces
        as a per-check Error rather than aborting the run.

.PARAMETER SourceId
    ISC source ID for the Entra connector. Either this or -SourceName is required.
.PARAMETER SourceName
    ISC source name, resolved to an ID by exact-name lookup.
.PARAMETER GroupPrefix
    Entra group name prefix identifying B2B groups.
    Defaults to config B2B.GroupPrefix (CLD-B2B).
.PARAMETER RolePrefix
    Role name prefix identifying B2B roles. Default: 'B2B-'.
.PARAMETER TransformName
    Name of the partner group resolver transform. Default: 'B2B Partner Group Resolver'.
.PARAMETER AccountStalenessHours
    Hours after which check 2 reports the source as stale. Default: 24.
.PARAMETER EntitlementStalenessHours
    Hours after which check 3 reports the source as stale. Default: 48.
.PARAMETER KnownIdentityAttribute
    Identity attribute property names check 7 accepts without warning. Defaults to
    attribute.userType, attribute.email, attribute.jobTitle. Supply the tenant's
    own mappings when the identity profile uses different names.
.PARAMETER GuestSampleLimit
    Maximum B2B guests check 10 evaluates for role assignment. Default: 250.
.PARAMETER OutputPath
    Directory for the HTML report and JSONL evidence file. Default: .\Reports.
.PARAMETER ConfigPath
    Path to settings.json. Auto-resolved if omitted.
.PARAMETER Token
    Pre-obtained JWT bearer token from the ISC admin console browser session.
.PARAMETER TokenExpiryMinutes
    Minutes until the browser token is considered expired. Default: 10.
.PARAMETER Quiet
    Suppress console output; the exit code and the report files are the result.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPB2BHealthCheck.ps1 -SourceName 'Entra ID - CORP' -Token $token
    # Standard weekly run with a console summary and an HTML report.
.EXAMPLE
    .\Invoke-SPB2BHealthCheck.ps1 -SourceId 'src-entra-001' -Quiet -Token $token
    # Scheduled run: exit code only, report written to disk.
.EXAMPLE
    .\Invoke-SPB2BHealthCheck.ps1 -SourceId 'src-entra-001' `
        -KnownIdentityAttribute 'attribute.isc_userType','attribute.mail' -Token $token
    # Tenant with customized identity profile attribute mappings.
.NOTES
    Script:  Invoke-SPB2BHealthCheck.ps1
    Version: 1.0.0
    Exit codes:
        0 = All checks passed
        1 = Warnings only
        2 = Failures found
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceId,

    [Parameter()]
    [string]$SourceName,

    [Parameter()]
    [string]$GroupPrefix,

    [Parameter()]
    [string]$RolePrefix = 'B2B-',

    [Parameter()]
    [string]$TransformName = 'B2B Partner Group Resolver',

    [Parameter()]
    [int]$AccountStalenessHours = 24,

    [Parameter()]
    [int]$EntitlementStalenessHours = 48,

    [Parameter()]
    [string[]]$KnownIdentityAttribute = @('attribute.userType', 'attribute.email', 'attribute.jobTitle'),

    [Parameter()]
    [int]$GuestSampleLimit = 250,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [int]$TokenExpiryMinutes = 10,

    [Parameter()]
    [switch]$Quiet,

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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Audit\SP.Audit.psd1';   Name = 'SP.Audit';  Required = $true }
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
            exit 2
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

function Write-B2BHost {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

Write-B2BHost ''
Write-B2BHost '  SailPoint ISC Governance Toolkit' 'Cyan'
Write-B2BHost '  B2B Governance Health Check' 'Cyan'
Write-B2BHost "  CorrelationID:   $correlationID" 'DarkGray'
Write-B2BHost ''

$config = $null
try {
    $config = Get-SPConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host "ERROR: Failed to load configuration from '$ConfigPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

if (-not (Test-SPConfig -Config $config)) {
    Write-Host 'ERROR: Configuration validation failed. Check settings.json for required values.' -ForegroundColor Red
    exit 2
}

try {
    Initialize-SPLogging -Force -ErrorAction SilentlyContinue
} catch { }

if ($Token) {
    $tokenResult = Set-SPBrowserToken -Token $Token -ExpiryMinutes $TokenExpiryMinutes `
        -CorrelationID $correlationID
    if (-not $tokenResult.Success) {
        Write-Host "ERROR: Invalid token: $($tokenResult.Error)" -ForegroundColor Red
        exit 2
    }
    Write-B2BHost "  Auth: Browser token active (expires: $($tokenResult.Data.ExpiresAt.ToString('HH:mm:ss')))" 'Green'
}

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

$effectiveOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($effectiveOutputPath)) {
    $effectiveOutputPath = '.\Reports'
}

# Check registry. Each entry records Status (Pass/Warn/Fail/Info/Error/Skipped),
# a one-line Detail for the report table, and any per-item findings.
$checks = [System.Collections.Generic.List[object]]::new()

# Populated by the criteria walk in check 7 and consumed by check 8. Initialized
# here so check 8 still runs (reporting an empty domain set) when the role detail
# lookup fails and the walk never happens.
$script:B2BObservedAttributes = @{}
$script:B2BObservedDomains    = @{}

function Add-B2BCheck {
    param(
        [int]$Number,
        [string]$Name,
        [string]$Status,
        [string]$Detail,
        [string[]]$Findings = @()
    )
    $checks.Add([ordered]@{
        Number   = $Number
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Findings = @($Findings)
    })
}

Write-SPLog -Message "Invoke-SPB2BHealthCheck started: Prefix='$effectivePrefix'" `
    -Severity INFO -Component 'Invoke-SPB2BHealthCheck' -Action 'Start' -CorrelationID $correlationID

#endregion

#region Resolve Source

$resolvedSourceId   = $SourceId
$resolvedSourceName = $SourceName

if ([string]::IsNullOrWhiteSpace($resolvedSourceId)) {
    $lookup = Get-SPSources -Name $SourceName -CorrelationID $correlationID
    if (-not $lookup.Success) {
        Write-Host "ERROR: Source lookup failed: $($lookup.Error)" -ForegroundColor Red
        if ($lookup.Error -match '403|forbidden') {
            Write-Host '       The token lacks source read permission.' -ForegroundColor Yellow
        }
        exit 2
    }
    $sourceMatches = @($lookup.Data)
    if ($sourceMatches.Count -ne 1) {
        Write-Host "ERROR: Expected exactly one source named '$SourceName', found $($sourceMatches.Count). Use -SourceId." -ForegroundColor Red
        exit 2
    }
    $resolvedSourceId = [string]$sourceMatches[0].id
}

#endregion

#region Checks 1-3: Source and Aggregation Health

Write-B2BHost '  Checks 1-3: Source and aggregation health...' 'Cyan'

$aggHealth   = $null
$sourceEntry = $null
try {
    $aggHealth = Get-SPSourceAggregationHealth -SourceIds @($resolvedSourceId) `
        -MaxAcceptableStalenessHours $AccountStalenessHours -CorrelationID $correlationID
    if ($null -ne $aggHealth -and $null -ne $aggHealth.Sources) {
        $sourceEntry = @($aggHealth.Sources) | Select-Object -First 1
    }
}
catch {
    $aggHealth = $null
}

if ($null -eq $sourceEntry) {
    Add-B2BCheck -Number 1 -Name 'Source exists and connection status' -Status 'Fail' `
        -Detail "Source '$resolvedSourceId' returned no aggregation health record. It may not exist, or may be disabled."
    Add-B2BCheck -Number 2 -Name 'Account aggregation freshness' -Status 'Skipped' `
        -Detail 'Source health unavailable.'
    Add-B2BCheck -Number 3 -Name 'Entitlement data freshness' -Status 'Skipped' `
        -Detail 'Source health unavailable.'
}
else {
    if ([string]::IsNullOrWhiteSpace($resolvedSourceName)) {
        $resolvedSourceName = [string]$sourceEntry['SourceName']
    }

    $healthStatus = [string]$sourceEntry['HealthStatus']
    $check1Status = switch ($healthStatus) {
        'Healthy'  { 'Pass' }
        'Warning'  { 'Warn' }
        'Critical' { 'Fail' }
        default    { 'Warn' }
    }
    Add-B2BCheck -Number 1 -Name 'Source exists and connection status' -Status $check1Status `
        -Detail "Source '$resolvedSourceName' health = $healthStatus (consecutive failures: $($sourceEntry['ConsecutiveFailures']))."

    $freshness = $sourceEntry['DataFreshnessHours']
    if ($null -eq $freshness) {
        Add-B2BCheck -Number 2 -Name 'Account aggregation freshness' -Status 'Warn' `
            -Detail 'No successful account aggregation found in the recent history.'
        Add-B2BCheck -Number 3 -Name 'Entitlement data freshness' -Status 'Warn' `
            -Detail 'No successful aggregation found, so entitlement data age cannot be established.'
    }
    else {
        $freshnessHours = [double]$freshness
        if ($freshnessHours -gt $AccountStalenessHours) {
            Add-B2BCheck -Number 2 -Name 'Account aggregation freshness' -Status 'Warn' `
                -Detail "Last successful aggregation was ${freshnessHours}h ago (threshold ${AccountStalenessHours}h)."
        }
        else {
            Add-B2BCheck -Number 2 -Name 'Account aggregation freshness' -Status 'Pass' `
                -Detail "Last successful aggregation was ${freshnessHours}h ago (threshold ${AccountStalenessHours}h)."
        }

        # ISC exposes no entitlement-aggregation history, so this evaluates the
        # source's aggregation timeline against the looser entitlement threshold.
        if ($freshnessHours -gt $EntitlementStalenessHours) {
            Add-B2BCheck -Number 3 -Name 'Entitlement data freshness' -Status 'Warn' `
                -Detail "Source aggregation timeline is ${freshnessHours}h old (entitlement threshold ${EntitlementStalenessHours}h). Entitlement data may be stale."
        }
        else {
            Add-B2BCheck -Number 3 -Name 'Entitlement data freshness' -Status 'Pass' `
                -Detail "Source aggregation timeline is ${freshnessHours}h old (entitlement threshold ${EntitlementStalenessHours}h)."
        }
    }
}

#endregion

#region Check 4: Entitlement to Access Profile Coverage

Write-B2BHost '  Check 4: B2B entitlement access profile coverage...' 'Cyan'

$b2bEntitlementNames = @()
$entInventory = Get-SPEntitlementInventory -SourceIds @($resolvedSourceId) -CorrelationID $correlationID
$allEntitlementNames = @()

if (-not $entInventory.Success) {
    Add-B2BCheck -Number 4 -Name 'B2B entitlements have access profiles' -Status 'Error' `
        -Detail "Entitlement inventory failed: $($entInventory.Error)"
}
else {
    foreach ($srcKey in $entInventory.Data.Sources.Keys) {
        foreach ($rec in @($entInventory.Data.Sources[$srcKey].Entitlements)) {
            $allEntitlementNames += [string]$rec.Name
        }
    }
    $b2bEntitlementNames = @($allEntitlementNames | Where-Object { $_ -like "$effectivePrefix-*" })
}

$apInventory  = Get-SPAccessProfileInventory -SourceIds @($resolvedSourceId) -IncludeEntitlements `
    -CorrelationID $correlationID
$apRecords    = @()
$apEntitlementNames = @{}

if (-not $apInventory.Success) {
    Add-B2BCheck -Number 4 -Name 'B2B entitlements have access profiles' -Status 'Error' `
        -Detail "Access profile inventory failed: $($apInventory.Error)"
}
elseif ($entInventory.Success) {
    foreach ($srcKey in $apInventory.Data.Sources.Keys) {
        foreach ($ap in @($apInventory.Data.Sources[$srcKey].AccessProfiles)) {
            $apRecords += $ap
            foreach ($entName in @($ap.Entitlements)) {
                if (-not [string]::IsNullOrWhiteSpace($entName)) {
                    $apEntitlementNames[$entName.ToLower()] = $true
                }
            }
        }
    }

    $orphans = @()
    foreach ($entName in $b2bEntitlementNames) {
        if (-not $apEntitlementNames.ContainsKey($entName.ToLower())) {
            $orphans += $entName
        }
    }

    if ($b2bEntitlementNames.Count -eq 0) {
        Add-B2BCheck -Number 4 -Name 'B2B entitlements have access profiles' -Status 'Warn' `
            -Detail "No $effectivePrefix-* entitlements found on this source. Either no B2B groups exist yet, or entitlement aggregation has not run."
    }
    elseif ($orphans.Count -gt 0) {
        Add-B2BCheck -Number 4 -Name 'B2B entitlements have access profiles' -Status 'Fail' `
            -Detail "$($orphans.Count) of $($b2bEntitlementNames.Count) B2B entitlement(s) are not bundled into any access profile." `
            -Findings $orphans
    }
    else {
        Add-B2BCheck -Number 4 -Name 'B2B entitlements have access profiles' -Status 'Pass' `
            -Detail "All $($b2bEntitlementNames.Count) B2B entitlement(s) are bundled into an access profile."
    }
}

#endregion

#region Checks 5-7: Role Linkage and Criteria

Write-B2BHost '  Checks 5-7: Role linkage and membership criteria...' 'Cyan'

$roleInventory = Get-SPRoleInventory -CorrelationID $correlationID
$b2bRoleRecords = @()

if (-not $roleInventory.Success) {
    Add-B2BCheck -Number 5 -Name 'B2B access profiles are linked to roles' -Status 'Error' `
        -Detail "Role inventory failed: $($roleInventory.Error)"
    Add-B2BCheck -Number 6 -Name 'B2B roles have membership criteria' -Status 'Skipped' `
        -Detail 'Role inventory unavailable.'
}
else {
    $b2bRoleRecords = @($roleInventory.Data.Roles | Where-Object { $_.Name -like "$RolePrefix*" })

    # Check 5: every B2B access profile must be referenced by at least one role
    $linkedApNames = @{}
    foreach ($role in @($roleInventory.Data.Roles)) {
        foreach ($apName in @($role.AccessProfileNames)) {
            if (-not [string]::IsNullOrWhiteSpace($apName)) {
                $linkedApNames[$apName.ToLower()] = $true
            }
        }
    }

    # A B2B access profile is one whose bundled entitlements carry the B2B prefix.
    $b2bApNames = @()
    foreach ($ap in $apRecords) {
        $isB2B = $false
        foreach ($entName in @($ap.Entitlements)) {
            if ($entName -like "$effectivePrefix-*") { $isB2B = $true; break }
        }
        if ($isB2B) { $b2bApNames += [string]$ap.Name }
    }

    $unlinked = @()
    foreach ($apName in $b2bApNames) {
        if (-not $linkedApNames.ContainsKey($apName.ToLower())) {
            $unlinked += $apName
        }
    }

    if ($b2bApNames.Count -eq 0) {
        Add-B2BCheck -Number 5 -Name 'B2B access profiles are linked to roles' -Status 'Warn' `
            -Detail 'No B2B access profiles found to evaluate.'
    }
    elseif ($unlinked.Count -gt 0) {
        Add-B2BCheck -Number 5 -Name 'B2B access profiles are linked to roles' -Status 'Warn' `
            -Detail "$($unlinked.Count) of $($b2bApNames.Count) B2B access profile(s) are not granted by any role. Tier 2 profiles granted only by access request are expected here." `
            -Findings $unlinked
    }
    else {
        Add-B2BCheck -Number 5 -Name 'B2B access profiles are linked to roles' -Status 'Pass' `
            -Detail "All $($b2bApNames.Count) B2B access profile(s) are granted by at least one role."
    }
}

# Checks 6 and 7 need the criteria structure itself, which the role inventory
# summarizes but does not carry. Fetch just the B2B roles for the detail.
$b2bRoleObjects = @()
$roleDetail = Get-SPRoles -NamePrefix $RolePrefix -CorrelationID $correlationID
$roleDetailOk = $roleDetail.Success

if (-not $roleDetailOk) {
    Add-B2BCheck -Number 6 -Name 'B2B roles have membership criteria' -Status 'Error' `
        -Detail "Role detail lookup failed: $($roleDetail.Error)"
    Add-B2BCheck -Number 7 -Name 'Role criteria reference known identity attributes' -Status 'Skipped' `
        -Detail 'Role detail unavailable.'
}
else {
    $b2bRoleObjects = @($roleDetail.Data)

    # Check 6: a criteria role with no children grants nothing and matches nobody
    $emptyCriteria = @()
    foreach ($role in $b2bRoleObjects) {
        $roleName = [string]$role.name
        $hasCriteria = $false
        if ($null -ne $role.PSObject.Properties['membership'] -and $null -ne $role.membership) {
            $memType = ''
            if ($null -ne $role.membership.PSObject.Properties['type']) {
                $memType = [string]$role.membership.type
            }
            if ($memType -eq 'CRITERIA' -and
                $null -ne $role.membership.PSObject.Properties['criteria'] -and
                $null -ne $role.membership.criteria) {
                $crit = $role.membership.criteria
                $childCount = 0
                if ($null -ne $crit.PSObject.Properties['children'] -and $null -ne $crit.children) {
                    $childCount = @($crit.children).Count
                }
                $hasValue = ($null -ne $crit.PSObject.Properties['value'] -and
                             -not [string]::IsNullOrWhiteSpace([string]$crit.value))
                $hasCriteria = ($childCount -gt 0 -or $hasValue)
            }
        }
        if (-not $hasCriteria) {
            $emptyCriteria += $roleName
        }
    }

    if ($b2bRoleObjects.Count -eq 0) {
        Add-B2BCheck -Number 6 -Name 'B2B roles have membership criteria' -Status 'Warn' `
            -Detail "No roles matching '$RolePrefix*' found."
    }
    elseif ($emptyCriteria.Count -gt 0) {
        Add-B2BCheck -Number 6 -Name 'B2B roles have membership criteria' -Status 'Fail' `
            -Detail "$($emptyCriteria.Count) of $($b2bRoleObjects.Count) B2B role(s) have no usable membership criteria and will never auto-assign." `
            -Findings $emptyCriteria
    }
    else {
        Add-B2BCheck -Number 6 -Name 'B2B roles have membership criteria' -Status 'Pass' `
            -Detail "All $($b2bRoleObjects.Count) B2B role(s) carry non-empty membership criteria."
    }

    # Check 7: walk the criteria tree and collect every identity attribute property
    function Get-B2BCriteriaAttributes {
        param($Node)
        if ($null -eq $Node) { return }
        if ($null -ne $Node.PSObject.Properties['key'] -and $null -ne $Node.key -and
            $null -ne $Node.key.PSObject.Properties['property'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Node.key.property)) {
            $prop = [string]$Node.key.property
            $script:B2BObservedAttributes[$prop] = $true

            # An email CONTAINS clause carries the partner domain the tenant is
            # actually governing -- check 8 compares those against the transform.
            if ($prop -like '*email*' -and
                $null -ne $Node.PSObject.Properties['value'] -and
                -not [string]::IsNullOrWhiteSpace([string]$Node.value)) {
                $script:B2BObservedDomains[([string]$Node.value).ToLower()] = $true
            }
        }
        if ($null -ne $Node.PSObject.Properties['children'] -and $null -ne $Node.children) {
            foreach ($child in @($Node.children)) {
                Get-B2BCriteriaAttributes -Node $child
            }
        }
    }

    foreach ($role in $b2bRoleObjects) {
        if ($null -ne $role.PSObject.Properties['membership'] -and $null -ne $role.membership -and
            $null -ne $role.membership.PSObject.Properties['criteria']) {
            Get-B2BCriteriaAttributes -Node $role.membership.criteria
        }
    }

    $unknownAttributes = @()
    foreach ($attr in $script:B2BObservedAttributes.Keys) {
        if ($KnownIdentityAttribute -notcontains $attr) {
            $unknownAttributes += $attr
        }
    }

    if ($script:B2BObservedAttributes.Count -eq 0) {
        Add-B2BCheck -Number 7 -Name 'Role criteria reference known identity attributes' -Status 'Warn' `
            -Detail 'No identity attribute references found in B2B role criteria.'
    }
    elseif ($unknownAttributes.Count -gt 0) {
        Add-B2BCheck -Number 7 -Name 'Role criteria reference known identity attributes' -Status 'Warn' `
            -Detail "$($unknownAttributes.Count) criteria attribute(s) are outside the expected set. Confirm they exist in the tenant's identity profile mappings -- a renamed attribute silently matches nobody." `
            -Findings $unknownAttributes
    }
    else {
        Add-B2BCheck -Number 7 -Name 'Role criteria reference known identity attributes' -Status 'Pass' `
            -Detail "All $($script:B2BObservedAttributes.Count) criteria attribute(s) are in the expected set."
    }
}

#endregion

#region Check 8: Transform Lookup Coverage

Write-B2BHost '  Check 8: Transform lookup coverage...' 'Cyan'

$transformResult = Get-SPTransforms -Name $TransformName -CorrelationID $correlationID

if (-not $transformResult.Success) {
    Add-B2BCheck -Number 8 -Name 'Transform lookup covers observed partner domains' -Status 'Error' `
        -Detail "Transform lookup failed: $($transformResult.Error)"
}
else {
    $transform = @($transformResult.Data) | Select-Object -First 1

    if ($null -eq $transform) {
        Add-B2BCheck -Number 8 -Name 'Transform lookup covers observed partner domains' -Status 'Warn' `
            -Detail "Transform '$TransformName' not found. This is expected when setup ran without -IncludeTransform."
    }
    else {
        $findings   = @()
        $tableKeys  = @{}
        if ($null -ne $transform.PSObject.Properties['attributes'] -and $null -ne $transform.attributes -and
            $null -ne $transform.attributes.PSObject.Properties['table'] -and $null -ne $transform.attributes.table) {
            foreach ($prop in $transform.attributes.table.PSObject.Properties) {
                $tableKeys[$prop.Name.ToLower()] = $true
            }
        }

        # The ISC lookup is EXACT match, so the input stage must reduce the email
        # to a bare domain before the table is consulted. A raw email input means
        # every guest falls through to the default entry.
        $inputIsSplitChain = $false
        if ($null -ne $transform.PSObject.Properties['attributes'] -and $null -ne $transform.attributes -and
            $null -ne $transform.attributes.PSObject.Properties['input'] -and $null -ne $transform.attributes.input) {
            $inputJson = $transform.attributes.input | ConvertTo-Json -Depth 10 -Compress
            $inputIsSplitChain = ($inputJson -match '"type"\s*:\s*"split"')
        }

        if (-not $inputIsSplitChain) {
            $findings += "Transform input stage is not a split chain. The ISC lookup is exact-match, so a raw email input routes every guest to the default entry."
        }

        $observedDomainList = @($script:B2BObservedDomains.Keys)
        foreach ($domain in $observedDomainList) {
            if (-not $tableKeys.ContainsKey($domain)) {
                $findings += "Domain '$domain' appears in role criteria but has no entry in the transform lookup table."
            }
        }

        if ($findings.Count -gt 0) {
            Add-B2BCheck -Number 8 -Name 'Transform lookup covers observed partner domains' -Status 'Warn' `
                -Detail "$($findings.Count) transform issue(s) found across $($tableKeys.Count) table entries." `
                -Findings $findings
        }
        else {
            Add-B2BCheck -Number 8 -Name 'Transform lookup covers observed partner domains' -Status 'Pass' `
                -Detail "Split-chain input confirmed; all $($observedDomainList.Count) observed domain(s) present in the $($tableKeys.Count)-entry table."
        }
    }
}

#endregion

#region Check 9: Provisioning Policies

Write-B2BHost '  Check 9: Provisioning policies...' 'Cyan'

$policyResult = Get-SPProvisioningPolicies -SourceId $resolvedSourceId -CorrelationID $correlationID

if (-not $policyResult.Success) {
    Add-B2BCheck -Number 9 -Name 'Provisioning policies exist' -Status 'Error' `
        -Detail "Provisioning policy lookup failed: $($policyResult.Error)"
}
else {
    $usageTypes = @()
    foreach ($pol in @($policyResult.Data)) {
        if ($null -ne $pol -and $null -ne $pol.PSObject.Properties['usageType'] -and $null -ne $pol.usageType) {
            $usageTypes += [string]$pol.usageType
        }
    }

    $missing = @()
    if ($usageTypes -notcontains 'ADD_ENTITLEMENT')    { $missing += 'ADD_ENTITLEMENT' }
    if ($usageTypes -notcontains 'REMOVE_ENTITLEMENT') { $missing += 'REMOVE_ENTITLEMENT' }

    if ($missing.Count -gt 0) {
        Add-B2BCheck -Number 9 -Name 'Provisioning policies exist' -Status 'Fail' `
            -Detail 'The connector cannot push group membership changes without these policies. Enable provisioning on the source in the ISC admin UI.' `
            -Findings $missing
    }
    else {
        Add-B2BCheck -Number 9 -Name 'Provisioning policies exist' -Status 'Pass' `
            -Detail 'ADD_ENTITLEMENT and REMOVE_ENTITLEMENT policies are present.'
    }
}

#endregion

#region Check 10: Guests Without Role Assignments

Write-B2BHost '  Check 10: B2B guests without role assignments...' 'Cyan'

$guestQuery = "attributes.userType:Guest AND @access(name:$effectivePrefix-*)"
$guestSearch = Invoke-SPApiRequest -Method POST -Endpoint '/search' -Body @{
    indices = @('identities')
    query   = @{ query = $guestQuery }
    limit   = $GuestSampleLimit
} -CorrelationID $correlationID

if (-not $guestSearch.Success) {
    Add-B2BCheck -Number 10 -Name 'B2B guests have role assignments' -Status 'Error' `
        -Detail "Identity search failed: $($guestSearch.Error)"
}
else {
    $guests = @($guestSearch.Data)
    $roleless = @()

    foreach ($guest in $guests) {
        $roleCount = $null
        if ($null -ne $guest.PSObject.Properties['roleCount'] -and $null -ne $guest.roleCount) {
            $roleCount = [int]$guest.roleCount
        }
        elseif ($null -ne $guest.PSObject.Properties['roles'] -and $null -ne $guest.roles) {
            $roleCount = @($guest.roles).Count
        }

        if ($null -ne $roleCount -and $roleCount -eq 0) {
            $label = ''
            if ($null -ne $guest.PSObject.Properties['displayName'] -and
                -not [string]::IsNullOrWhiteSpace($guest.displayName)) {
                $label = [string]$guest.displayName
            }
            elseif ($null -ne $guest.PSObject.Properties['name']) {
                $label = [string]$guest.name
            }
            if ($null -ne $guest.PSObject.Properties['email'] -and
                -not [string]::IsNullOrWhiteSpace($guest.email)) {
                $label = "$label <$($guest.email)>"
            }
            $roleless += $label
        }
    }

    if ($guests.Count -eq 0) {
        Add-B2BCheck -Number 10 -Name 'B2B guests have role assignments' -Status 'Warn' `
            -Detail "No B2B guests found holding $effectivePrefix-* access."
    }
    elseif ($roleless.Count -gt 0) {
        Add-B2BCheck -Number 10 -Name 'B2B guests have role assignments' -Status 'Warn' `
            -Detail "$($roleless.Count) of $($guests.Count) sampled B2B guest(s) hold B2B access with no role assignment. Access was granted outside the role model, or criteria have not been re-evaluated since the last identity refresh." `
            -Findings $roleless
    }
    else {
        Add-B2BCheck -Number 10 -Name 'B2B guests have role assignments' -Status 'Pass' `
            -Detail "All $($guests.Count) sampled B2B guest(s) carry at least one role assignment."
    }
}

#endregion

#region Check 11: Naming Convention Compliance

Write-B2BHost '  Check 11: Group naming convention compliance...' 'Cyan'

if ($allEntitlementNames.Count -eq 0) {
    Add-B2BCheck -Number 11 -Name 'Group naming convention compliance' -Status 'Skipped' `
        -Detail 'Entitlement inventory unavailable.'
}
else {
    $compliant   = @($allEntitlementNames | Where-Object { $_ -like "$effectivePrefix-*" })
    $onPremSynced = @($allEntitlementNames | Where-Object { $_ -like 'SG-*' })

    # Groups that look B2B by intent but sit outside the governed prefix. These
    # never reach the setup script's discovery filter, so they stay ungoverned.
    $nearMisses = @($allEntitlementNames | Where-Object {
        $_ -notlike "$effectivePrefix-*" -and ($_ -like '*B2B*' -or $_ -like '*Guest*')
    })

    $findings = @()
    foreach ($name in $nearMisses) {
        $findings += "$name (matches B2B intent but not the '$effectivePrefix-' prefix)"
    }

    Add-B2BCheck -Number 11 -Name 'Group naming convention compliance' -Status 'Info' `
        -Detail "$($compliant.Count) group(s) follow the '$effectivePrefix-' convention, $($onPremSynced.Count) are 'SG-' on-prem synced, $($nearMisses.Count) look B2B but sit outside the prefix (of $($allEntitlementNames.Count) total)." `
        -Findings $findings
}

#endregion

#region Report and Exit

$runEnd      = Get-Date
$runDuration = ($runEnd - $runStart).TotalSeconds

$passCount  = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
$warnCount  = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
$failCount  = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
$errorCount = @($checks | Where-Object { $_.Status -eq 'Error' }).Count
$infoCount  = @($checks | Where-Object { $_.Status -eq 'Info' }).Count
$skipCount  = @($checks | Where-Object { $_.Status -eq 'Skipped' }).Count

$palette   = Get-SPHtmlColorPalette
$todayLabel = $runStart.ToString('yyyy-MM-dd')

function Get-B2BStatusColor {
    param([string]$Status)
    switch ($Status) {
        'Pass'  { return $palette.Green }
        'Warn'  { return $palette.Amber }
        'Fail'  { return $palette.Red }
        'Error' { return $palette.Red }
        'Info'  { return $palette.Blue }
        default { return $palette.Gray }
    }
}

# Console summary
if (-not $Quiet) {
    Write-Host ''
    Write-Host '  B2B Governance Health Check Results' -ForegroundColor Cyan
    Write-Host "  $('=' * 70)" -ForegroundColor DarkGray
    foreach ($check in $checks) {
        $color = switch ($check.Status) {
            'Pass'  { 'Green' }
            'Warn'  { 'Yellow' }
            'Fail'  { 'Red' }
            'Error' { 'Red' }
            'Info'  { 'Cyan' }
            default { 'DarkGray' }
        }
        Write-Host ("  {0,2}. {1,-48} {2}" -f $check.Number, $check.Name, $check.Status.ToUpper()) -ForegroundColor $color
        Write-Host "      $($check.Detail)" -ForegroundColor DarkGray
        foreach ($finding in @($check.Findings)) {
            Write-Host "        - $finding" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host "  Pass: $passCount | Warn: $warnCount | Fail: $failCount | Error: $errorCount | Info: $infoCount | Skipped: $skipCount" -ForegroundColor Cyan
}

# HTML report
$reportPath = $null
try {
    if (-not (Test-Path $effectiveOutputPath)) {
        New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
    }
    $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1c2b3a;margin:24px;background:#ffffff;}
h1{font-size:20px;color:#1f3a5f;border-bottom:2px solid #1f3a5f;padding-bottom:6px;margin-bottom:4px;}
h2{font-size:15px;color:#1f3a5f;margin-top:26px;border-bottom:1px solid #d4dce6;padding-bottom:4px;}
.meta{color:#556677;font-size:12px;margin-bottom:8px;}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:12px;}
th{background:#1f3a5f;color:#fff;text-align:left;padding:6px 8px;font-weight:600;}
td{border-bottom:1px solid #e3e9f0;padding:5px 8px;vertical-align:top;}
tr:nth-child(even) td{background:#f6f9fc;}
.kpi{display:inline-block;min-width:110px;margin:6px 10px 6px 0;padding:10px 14px;border:1px solid #d4dce6;border-radius:6px;background:#f6f9fc;}
.kpi .n{font-size:22px;font-weight:700;display:block;}
.kpi .l{font-size:11px;color:#556677;text-transform:uppercase;letter-spacing:.04em;}
.status{font-weight:700;}
.findings{margin:4px 0 0 16px;padding:0;color:#556677;font-size:11px;}
.note{font-size:11px;color:#777777;margin-top:10px;}
'@

    $sb = New-SPHtmlDocument -Title "B2B Governance Health Check - $todayLabel" -Css $css
    [void]$sb.Append('<h1>B2B Governance Health Check</h1>')
    [void]$sb.Append("<p class='meta'>Source: $(ConvertTo-SPHtmlSafe $resolvedSourceName) ($(ConvertTo-SPHtmlSafe $resolvedSourceId)) &middot; Group prefix: $(ConvertTo-SPHtmlSafe $effectivePrefix) &middot; $todayLabel</p>")

    [void]$sb.Append("<div class='kpi'><span class='n' style='color:$($palette.Green)'>$passCount</span><span class='l'>Passed</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n' style='color:$($palette.Amber)'>$warnCount</span><span class='l'>Warnings</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n' style='color:$($palette.Red)'>$failCount</span><span class='l'>Failures</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n' style='color:$($palette.Red)'>$errorCount</span><span class='l'>Errors</span></div>")
    [void]$sb.Append("<div class='kpi'><span class='n' style='color:$($palette.Gray)'>$($infoCount + $skipCount)</span><span class='l'>Info / Skipped</span></div>")

    [void]$sb.Append('<h2>Checks</h2>')
    [void]$sb.Append('<table><tr><th style="width:36px;">#</th><th>Check</th><th style="width:80px;">Status</th><th>Detail</th></tr>')

    foreach ($check in $checks) {
        $statusColor = Get-B2BStatusColor -Status $check.Status
        $detailHtml  = ConvertTo-SPHtmlSafe $check.Detail
        $findingList = @($check.Findings)
        if ($findingList.Count -gt 0) {
            $detailHtml += '<ul class="findings">'
            foreach ($finding in $findingList) {
                $detailHtml += '<li>' + (ConvertTo-SPHtmlSafe $finding) + '</li>'
            }
            $detailHtml += '</ul>'
        }
        [void]$sb.Append("<tr><td>$($check.Number)</td><td>$(ConvertTo-SPHtmlSafe $check.Name)</td>")
        [void]$sb.Append("<td class='status' style='color:$statusColor'>$($check.Status.ToUpper())</td>")
        [void]$sb.Append("<td>$detailHtml</td></tr>")
    }
    [void]$sb.Append('</table>')

    [void]$sb.Append("<p class='note'>Check 3 evaluates the source aggregation timeline against the entitlement threshold: ISC exposes an account-aggregation history but no equivalent entitlement-aggregation history.</p>")
    [void]$sb.Append("<p class='note'>Duration: $([math]::Round($runDuration, 1))s &middot; CorrelationID: $(ConvertTo-SPHtmlSafe $correlationID)</p>")
    [void]$sb.Append('<p class="note">Generated by Invoke-SPB2BHealthCheck.ps1 v1.0.0</p>')
    [void]$sb.Append('</body></html>')

    $reportName = "B2B-HealthCheck_$($runStart.ToString('yyyyMMdd-HHmmss')).html"
    $reportPath = Join-Path $effectiveOutputPath $reportName
    Write-SPHtmlFile -Path $reportPath -Content $sb.ToString()
    Write-B2BHost "  HTML report:     $reportPath" 'DarkGray'
}
catch {
    Write-Host "  WARN: Failed to write HTML report: $($_.Exception.Message)" -ForegroundColor Yellow
    $reportPath = $null
}

# JSONL evidence
try {
    if (-not (Test-Path $effectiveOutputPath)) {
        New-Item -ItemType Directory -Path $effectiveOutputPath -Force | Out-Null
    }
    $evidenceEvent = [ordered]@{
        Timestamp     = $runEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Action        = 'B2BHealthCheck'
        CorrelationID = $correlationID
        SourceId      = $resolvedSourceId
        SourceName    = $resolvedSourceName
        GroupPrefix   = $effectivePrefix
        DurationSec   = [math]::Round($runDuration, 1)
        Summary       = [ordered]@{
            Passed  = $passCount
            Warned  = $warnCount
            Failed  = $failCount
            Errored = $errorCount
            Info    = $infoCount
            Skipped = $skipCount
        }
        Checks        = @($checks)
    }
    $jsonLine     = $evidenceEvent | ConvertTo-Json -Depth 6 -Compress
    $evidenceFile = Join-Path $effectiveOutputPath 'b2b-healthcheck-evidence.jsonl'
    $utf8NoBom    = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($evidenceFile, "$jsonLine`n", $utf8NoBom)
    Write-B2BHost "  Evidence:        $evidenceFile" 'DarkGray'
}
catch {
    Write-Host "  WARN: Failed to write evidence file: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-B2BHost "  CorrelationID:   $correlationID" 'DarkGray'
Write-B2BHost ''

Write-SPLog -Message "Invoke-SPB2BHealthCheck completed: Pass=$passCount Warn=$warnCount Fail=$failCount Error=$errorCount" `
    -Severity INFO -Component 'Invoke-SPB2BHealthCheck' -Action 'Complete' -CorrelationID $correlationID

#endregion

# An Error status means a check could not run -- treated as a failure so a
# permission gap never reads as a clean bill of health.
if ($failCount -gt 0 -or $errorCount -gt 0) { exit 2 }
if ($warnCount -gt 0) { exit 1 }

exit 0
