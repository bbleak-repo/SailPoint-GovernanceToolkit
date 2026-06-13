#Requires -Version 5.1
<#
.SYNOPSIS
    Generates deterministic, date-stamped disconnected-app CSV snapshots (accounts +
    optional entitlements) for the toolkit's Disconnected App Onboarding Kit.
.DESCRIPTION
    Test-data generator for the disconnected-app flow. Produces cert-ready CSV files
    that conform EXACTLY to the schemas enforced by SP.DisconnectedAppValidator:

        accounts:     id,name,givenName,familyName,e-mail,groups,IIQDisabled
        entitlements: id,name,displayName,description

    All randomness is driven by a single seeded [System.Random] so the same -Seed
    always yields byte-identical content (important for delta + Pester repeatability).
    Files are written UTF-8 (no BOM) to satisfy Test-SPFileIsUtf8 and are sorted by
    'id' so the validator's sort-order check stays clean.

    When -WithEntitlements is supplied, the generator emits one entitlement row for
    every group id referenced by any account (so Test-SPDisconnectedAppCrossReference
    passes) plus a few deterministic orphan entitlements. DebtNext-style apps omit the
    entitlement file (accounts-only).

    This script ONLY writes test data; it does not call any live API and does not
    modify any module, script, or tracked configuration.

.PARAMETER AppName
    Application name. Used for the output subdirectory, id prefixes, and snapshot dir.
    Example: 'PEP-Plus', 'DebtNext'.
.PARAMETER OutputDir
    Base Imports directory. The dated files are written to {OutputDir}/{AppName}/.
    Defaults to .\DisconnectedApps\Imports relative to the toolkit root.
.PARAMETER SnapshotDir
    Optional snapshot root. When supplied, the generated files are also copied to
    {SnapshotDir}/{AppName}/{yyyy-MM-dd}-{accounts|entitlements}.csv via
    Save-SPDisconnectedAppSnapshot (only valid when ReportDate is today).
.PARAMETER AccountCount
    Number of account rows to generate. Default: 25.
.PARAMETER EntitlementCount
    Number of distinct entitlement (group) ids accounts may draw from. Default: 8.
.PARAMETER Seed
    Integer seed for deterministic content. Default: 42.
.PARAMETER ReportDate
    Date stamp (yyyy-MM-dd) for the file names. Default: today.
.PARAMETER WithEntitlements
    Emit the entitlements CSV (and assign groups to accounts). When omitted, accounts
    have an empty 'groups' column and no entitlement file is written (DebtNext style).
.PARAMETER OutputMode
    Console (default): human-readable summary.
    JSON: machine-parseable result object (for CLI parsing).
.PARAMETER Help
    Display full comment-based help and exit.
.OUTPUTS
    [hashtable] @{Success; Data=@{AppName; AccountFile; EntitlementFile; AccountRows;
        EntitlementRows; ReportDate; Snapshot=@{Accounts;Entitlements}}; Error}
.EXAMPLE
    .\New-SPDisconnectedAppSnapshotData.ps1 -AppName PEP-Plus -WithEntitlements `
        -AccountCount 25 -EntitlementCount 8 -Seed 42
    # Deterministic PEP-Plus snapshot with accounts + entitlements.
.EXAMPLE
    .\New-SPDisconnectedAppSnapshotData.ps1 -AppName DebtNext -AccountCount 20 -Seed 7
    # Accounts-only DebtNext snapshot.
.NOTES
    Script:  New-SPDisconnectedAppSnapshotData.ps1
    Version: 1.0.0
    Component: Disconnected App Test-Data Generator
    Exit codes:
        0 = Success
        1 = Generation error
        2 = Parameter error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AppName,

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [string]$SnapshotDir,

    [Parameter()]
    [ValidateRange(1, 100000)]
    [int]$AccountCount = 25,

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int]$EntitlementCount = 8,

    [Parameter()]
    [int]$Seed = 42,

    [Parameter()]
    [string]$ReportDate,

    [Parameter()]
    [switch]$WithEntitlements,

    [Parameter()]
    [ValidateSet('Console', 'JSON')]
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
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Shared\SP.Shared.psd1';                    Name = 'SP.Shared'            }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.Core\SP.Core.psd1';                        Name = 'SP.Core'              }
    @{ Path = Join-Path $toolkitRoot 'Modules\SP.DisconnectedApps\SP.DisconnectedApps.psd1'; Name = 'SP.DisconnectedApps' }
)

foreach ($mod in $moduleChain) {
    if (Test-Path $mod.Path) {
        Import-Module $mod.Path -Force -ErrorAction SilentlyContinue -DisableNameChecking
    }
    else {
        $moduleDir = Split-Path -Parent $mod.Path
        $psm1Files = Get-ChildItem -Path $moduleDir -Filter '*.psm1' -ErrorAction SilentlyContinue
        foreach ($psm1 in $psm1Files) {
            Import-Module $psm1.FullName -Force -ErrorAction SilentlyContinue -DisableNameChecking
        }
    }
}

#endregion

#region Setup

if ([string]::IsNullOrWhiteSpace($ReportDate)) {
    $ReportDate = Get-Date -Format 'yyyy-MM-dd'
}

# Validate ReportDate format
if ($ReportDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
    Write-Host "ERROR: -ReportDate must be in yyyy-MM-dd format, got '$ReportDate'." -ForegroundColor Red
    exit 2
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $toolkitRoot 'DisconnectedApps\Imports'
}

# Slug used for ids (lowercase, alnum + hyphen only)
$appSlug = ($AppName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($appSlug)) { $appSlug = 'app' }

#endregion

#region Deterministic Pools

# Fixed name pools indexed by the seeded RNG so content is reproducible.
$givenPool = @(
    'Olivia', 'Liam', 'Emma', 'Noah', 'Ava', 'Ethan', 'Sophia', 'Mason',
    'Isabella', 'Logan', 'Mia', 'Lucas', 'Amelia', 'Jackson', 'Harper',
    'Aiden', 'Evelyn', 'Elijah', 'Abigail', 'James', 'Emily', 'Benjamin',
    'Charlotte', 'Sebastian', 'Madison', 'Henry', 'Scarlett', 'Carter',
    'Victoria', 'Owen', 'Aria', 'Wyatt', 'Grace', 'Julian', 'Chloe', 'Levi'
)
$familyPool = @(
    'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller',
    'Davis', 'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Gonzalez',
    'Wilson', 'Anderson', 'Thomas', 'Taylor', 'Moore', 'Jackson', 'Martin',
    'Lee', 'Perez', 'Thompson', 'White', 'Harris', 'Sanchez', 'Clark',
    'Ramirez', 'Lewis', 'Robinson', 'Walker', 'Young', 'Allen', 'King'
)

#endregion

#region Generate

try {
    $rng = [System.Random]::new($Seed)

    $appOutputDir = Join-Path $OutputDir $AppName
    if (-not (Test-Path -Path $appOutputDir -PathType Container)) {
        New-Item -Path $appOutputDir -ItemType Directory -Force | Out-Null
    }

    # --- Build the entitlement id pool (group ids) -----------------------------
    # Group ids are always derived so accounts can reference them; the entitlement
    # FILE is only written when -WithEntitlements is set.
    $groupIds = @()
    for ($g = 1; $g -le $EntitlementCount; $g++) {
        $groupIds += ('{0}-grp-{1:000}' -f $appSlug, $g)
    }

    # --- Generate account rows -------------------------------------------------
    $usedGroupIds = @{}
    $accountRows = [System.Collections.Generic.List[psobject]]::new()

    for ($i = 1; $i -le $AccountCount; $i++) {
        $given  = $givenPool[$rng.Next(0, $givenPool.Count)]
        $family = $familyPool[$rng.Next(0, $familyPool.Count)]
        $acctId = '{0}-acct-{1:0000}' -f $appSlug, $i
        $email  = ('{0}.{1}.{2:0000}@example.com' -f $given.ToLowerInvariant(), $family.ToLowerInvariant(), $i)

        # ~10% disabled, deterministic
        $disabled = if ($rng.Next(0, 10) -eq 0) { 'true' } else { 'false' }

        # Group assignment: only when entitlements are emitted. 1..3 distinct groups.
        $groupsValue = ''
        if ($WithEntitlements -and $groupIds.Count -gt 0) {
            $numGroups = 1 + $rng.Next(0, [Math]::Min(3, $groupIds.Count))
            $picked = [System.Collections.Generic.List[string]]::new()
            $guard = 0
            while ($picked.Count -lt $numGroups -and $guard -lt 50) {
                $cand = $groupIds[$rng.Next(0, $groupIds.Count)]
                if (-not $picked.Contains($cand)) {
                    $picked.Add($cand)
                    $usedGroupIds[$cand] = $true
                }
                $guard++
            }
            # Sort for stable output
            $sortedPicked = @($picked | Sort-Object)
            $groupsValue = ($sortedPicked -join ',')
        }

        $accountRows.Add([PSCustomObject][ordered]@{
            id          = $acctId
            name        = $email
            givenName   = $given
            familyName  = $family
            'e-mail'    = $email
            groups      = $groupsValue
            IIQDisabled = $disabled
        })
    }

    # Sort by id (Ordinal) so the validator's sort-order check is clean.
    $sortedAccounts = @($accountRows | Sort-Object -Property id)

    # --- Write accounts CSV (UTF-8 no BOM) -------------------------------------
    $accountFile = Join-Path $appOutputDir ("{0}-accounts.csv" -f $ReportDate)
    $csvText = ($sortedAccounts | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($accountFile, ($csvText + "`r`n"), $utf8NoBom)

    # --- Entitlement rows (only when requested) --------------------------------
    $entitlementFile = ''
    $entitlementRowCount = 0
    if ($WithEntitlements) {
        $entRows = [System.Collections.Generic.List[psobject]]::new()
        # One row per group id in the pool (covers every referenced group + orphans).
        for ($g = 1; $g -le $EntitlementCount; $g++) {
            $entId = '{0}-grp-{1:000}' -f $appSlug, $g
            $entRows.Add([PSCustomObject][ordered]@{
                id          = $entId
                name        = ('{0}_GROUP_{1:000}' -f $appSlug.ToUpperInvariant(), $g)
                displayName = ('{0} Group {1:000}' -f $AppName, $g)
                description = ('Access group {0:000} for {1} disconnected application.' -f $g, $AppName)
            })
        }
        $sortedEnt = @($entRows | Sort-Object -Property id)
        $entitlementFile = Join-Path $appOutputDir ("{0}-entitlements.csv" -f $ReportDate)
        $entCsvText = ($sortedEnt | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        [System.IO.File]::WriteAllText($entitlementFile, ($entCsvText + "`r`n"), $utf8NoBom)
        $entitlementRowCount = $sortedEnt.Count
    }

    # --- Optional snapshot copy (only valid for today) -------------------------
    $snapAccounts = ''
    $snapEntitlements = ''
    if (-not [string]::IsNullOrWhiteSpace($SnapshotDir) -and
        $ReportDate -eq (Get-Date -Format 'yyyy-MM-dd') -and
        (Get-Command Save-SPDisconnectedAppSnapshot -ErrorAction SilentlyContinue)) {
        $snapA = Save-SPDisconnectedAppSnapshot -FilePath $accountFile -AppName $AppName `
            -FileType 'accounts' -SnapshotDir $SnapshotDir
        if ($snapA.Success) { $snapAccounts = $snapA.Data }
        if ($WithEntitlements -and -not [string]::IsNullOrWhiteSpace($entitlementFile)) {
            $snapE = Save-SPDisconnectedAppSnapshot -FilePath $entitlementFile -AppName $AppName `
                -FileType 'entitlements' -SnapshotDir $SnapshotDir
            if ($snapE.Success) { $snapEntitlements = $snapE.Data }
        }
    }

    $result = @{
        Success = $true
        Data    = @{
            AppName         = $AppName
            AccountFile     = $accountFile
            EntitlementFile = $entitlementFile
            AccountRows     = $sortedAccounts.Count
            EntitlementRows = $entitlementRowCount
            ReportDate      = $ReportDate
            Seed            = $Seed
            Snapshot        = @{
                Accounts     = $snapAccounts
                Entitlements = $snapEntitlements
            }
        }
        Error   = $null
    }

    if ($OutputMode -eq 'JSON') {
        ([PSCustomObject]@{
            Success         = $true
            AppName         = $AppName
            AccountFile     = $accountFile
            EntitlementFile = $entitlementFile
            AccountRows     = $sortedAccounts.Count
            EntitlementRows = $entitlementRowCount
            ReportDate      = $ReportDate
            Seed            = $Seed
        } | ConvertTo-Json -Depth 5)
    }
    else {
        Write-Host ''
        Write-Host "  Disconnected App Snapshot Generator" -ForegroundColor Cyan
        Write-Host "    App:          $AppName" -ForegroundColor DarkGray
        Write-Host "    Report date:  $ReportDate" -ForegroundColor DarkGray
        Write-Host "    Seed:         $Seed" -ForegroundColor DarkGray
        Write-Host "    Accounts:     $($sortedAccounts.Count) -> $accountFile" -ForegroundColor Green
        if ($WithEntitlements) {
            Write-Host "    Entitlements: $entitlementRowCount -> $entitlementFile" -ForegroundColor Green
        }
        Write-Host ''
    }

    # Emit the result object so callers (in-process dot-source) get the envelope.
    if (Get-Command Write-SPLog -ErrorAction SilentlyContinue) {
        try {
            Write-SPLog -Message "Generated disconnected snapshot for '$AppName' ($($sortedAccounts.Count) accounts, $entitlementRowCount entitlements, seed=$Seed, date=$ReportDate)" `
                -Severity INFO -Component 'New-SPDisconnectedAppSnapshotData' -Action 'Generate' -ErrorAction SilentlyContinue
        } catch { }
    }

    return $result
}
catch {
    $errMsg = "New-SPDisconnectedAppSnapshotData failed: $($_.Exception.Message)"
    Write-Host "ERROR: $errMsg" -ForegroundColor Red
    if ($OutputMode -eq 'JSON') {
        ([PSCustomObject]@{ Success = $false; Error = $errMsg } | ConvertTo-Json)
    }
    exit 1
}

#endregion
