#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the two distributable zips from the current working tree.

.DESCRIPTION
    Single source of truth for packaging. Produces:

      SailPoint-GovernanceToolkit-UserHandoff.zip  (user-deployable)
        Structured layout that the launcher expects -- Scripts\, Modules\,
        Gui\, Config\ -- plus user docs, onboarding templates and workflow
        diagrams. Excludes Tests\ and developer docs. Runs as-is via
        Scripts\Show-SPDashboard.ps1.

      SailPoint-GovernanceToolkit.zip              (portable / full)
        Same runtime tree plus Tests\ (unit tests + TestData) and developer
        docs (DEV.md, toolkit-status.md) relocated to the root.

    Both zips also carry tools\Intake-Tool\ (the cross-product IAM app
    onboarding intake tool) -- a dotted-line companion to this project, kept
    under tools\ so it never shadows the toolkit runtime.

    Both layouts preserve the Modules\SP.X\ structure so module manifests and
    the GUI's ..\..\Gui XAML lookup resolve correctly. The previous flat
    user-handoff layout could not run because Show-SPDashboard.ps1 derives the
    toolkit root as the parent of its own \Scripts dir.

    Never includes per-developer or runtime files (*.local.json, vault data,
    Logs/Evidence/Reports/Audit output, Tests\Harness, Tests\Tools).

.PARAMETER OutputDir
    Directory to write the zips into. Defaults to the repo root (next to this
    script). The distribution smoke test passes a temp dir here.

.PARAMETER UserOnly
    Build only the user-handoff zip.

.PARAMETER PortableOnly
    Build only the portable zip.

.OUTPUTS
    [pscustomobject] per zip built: @{ Name; Path; Entries; SizeKB }

.EXAMPLE
    .\build-dist.ps1
    Rebuild both zips in place.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$OutputDir,
    [Parameter()][switch]$UserOnly,
    [Parameter()][switch]$PortableOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$RepoRoot = $PSScriptRoot
if (-not $OutputDir) { $OutputDir = $RepoRoot }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# --- plan helpers ---------------------------------------------------------

function New-Plan { @{ items = [System.Collections.Generic.List[object]]::new() } }

function Add-Item {
    param($Plan, [string]$Entry, [string]$Src)
    if (-not (Test-Path -LiteralPath $Src)) { throw "build-dist: source not found for entry '$Entry': $Src" }
    $Plan.items.Add([pscustomobject]@{ Entry = $Entry; Src = (Resolve-Path -LiteralPath $Src).Path })
}

function Add-Tree {
    # Add every matching file under $Dir, preserving its sub-path beneath $Prefix.
    param($Plan, [string]$Dir, [string]$Prefix, [string[]]$Include)
    $base = (Resolve-Path -LiteralPath (Join-Path $RepoRoot $Dir)).Path
    Get-ChildItem -LiteralPath $base -Recurse -File -Include $Include | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1) -replace '\\', '/'
        Add-Item $Plan "$Prefix/$rel" $_.FullName
    }
}

function Build-Zip {
    param($Plan, [string]$TargetPath, [string]$Name)
    # Guard against accidental flatten collisions.
    $dupes = $Plan.items | Group-Object Entry | Where-Object Count -gt 1
    if ($dupes) { throw "build-dist: duplicate entries in $Name -> $($dupes.Name -join ', ')" }
    if (Test-Path -LiteralPath $TargetPath) { Remove-Item -LiteralPath $TargetPath -Force }
    $fs = [System.IO.File]::Open($TargetPath, [System.IO.FileMode]::CreateNew)
    try {
        $ar = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($item in $Plan.items) {
                $entry = $ar.CreateEntry($item.Entry, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = (Get-Item -LiteralPath $item.Src).LastWriteTime
                $stream = $entry.Open()
                try { $bytes = [System.IO.File]::ReadAllBytes($item.Src); $stream.Write($bytes, 0, $bytes.Length) }
                finally { $stream.Dispose() }
            }
        } finally { $ar.Dispose() }
    } finally { $fs.Dispose() }
    [pscustomobject]@{
        Name    = $Name
        Path    = $TargetPath
        Entries = $Plan.items.Count
        SizeKB  = [Math]::Round((Get-Item -LiteralPath $TargetPath).Length / 1KB, 1)
    }
}

# --- recipes --------------------------------------------------------------

function Get-RuntimePlan {
    # Shared runtime tree (structured): Modules, Scripts, Gui, base Config.
    param($Plan)
    # Recursively discovers all .psm1/.psd1 under Modules/ -- includes SP.Shared automatically.
    Add-Tree $Plan 'Modules' 'Modules' @('*.psm1', '*.psd1')
    Add-Tree $Plan 'Scripts' 'Scripts' @('*.ps1')
    Add-Tree $Plan 'Gui'     'Gui'     @('*.xaml')
    Add-Item $Plan 'Config/settings.json'       (Join-Path $RepoRoot 'Config\settings.json')
    Add-Item $Plan 'Config/test-campaigns.csv'  (Join-Path $RepoRoot 'Config\test-campaigns.csv')
    Add-Item $Plan 'Config/test-identities.csv' (Join-Path $RepoRoot 'Config\test-identities.csv')
    # Dotted-line companion tool: IAM app onboarding intake (scripts + docs + the
    # HTML intake form). Shipped in BOTH zips, preserved under tools\Intake-Tool\.
    if (Test-Path (Join-Path $RepoRoot 'tools\Intake-Tool')) {
        Add-Tree $Plan 'tools\Intake-Tool' 'tools/Intake-Tool' @('*.ps1', '*.md', '*.html', '*.css', '*.py', '*.json')
    }
}

function Get-UserPlan {
    $p = New-Plan
    Get-RuntimePlan $p

    # Root-level user docs
    Add-Item $p 'README.md'            (Join-Path $RepoRoot 'README.md')
    Add-Item $p 'QUICKSTART.md'        (Join-Path $RepoRoot 'QUICKSTART.md')
    Add-Item $p 'USER-GUIDE.html'      (Join-Path $RepoRoot 'USER-GUIDE.html')
    Add-Item $p 'SANDBOX-API-SETUP.md' (Join-Path $RepoRoot 'docs\SANDBOX-API-SETUP.md')

    # Onboarding templates (for app owners providing disconnected CSVs)
    Add-Item $p 'Config/Templates/ONBOARDING-GUIDE.md'               (Join-Path $RepoRoot 'Config\Templates\ONBOARDING-GUIDE.md')
    Add-Item $p 'Config/Templates/VERSION-HISTORY.md'                (Join-Path $RepoRoot 'Config\Templates\VERSION-HISTORY.md')
    Add-Item $p 'Config/Templates/disconnected-app-accounts.csv'      (Join-Path $RepoRoot 'Config\Templates\disconnected-app-accounts.csv')
    Add-Item $p 'Config/Templates/disconnected-app-entitlements.csv'  (Join-Path $RepoRoot 'Config\Templates\disconnected-app-entitlements.csv')

    # Workflow diagrams referenced by the onboarding/user guide
    Add-Tree $p 'docs/designs/disconnected-app-workflows' 'docs/designs/disconnected-app-workflows' @('*.png')

    # Governance HTML guides (persona-specific: manager attestation, app owner,
    # connector playbook, campaign rollout, SaaS architecture, metrics dashboard, etc.)
    # Excludes mockup-audit-report.html (dev-only visual prototype).
    $htmlExclude = @('mockup-audit-report.html')
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs') -File -Filter '*.html' |
        Where-Object { $_.Name -notin $htmlExclude } |
        ForEach-Object { Add-Item $p "docs/$($_.Name)" $_.FullName }

    # HTML guide assets (email templates, integration diagrams, ISC UI mockups)
    $assetsDir = Join-Path $RepoRoot 'docs\assets'
    if (Test-Path $assetsDir) {
        Get-ChildItem -LiteralPath $assetsDir -File -Filter '*.html' |
            ForEach-Object { Add-Item $p "docs/assets/$($_.Name)" $_.FullName }
    }

    # Playbook Markdown (canonical source-of-truth reference docs for CLI + GUI)
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs\playbook') -File -Filter '*.md' |
        ForEach-Object { Add-Item $p "docs/playbook/$($_.Name)" $_.FullName }

    return $p
}

function Get-PortablePlan {
    $p = New-Plan
    Get-RuntimePlan $p
    # Root docs (README/QUICKSTART from root; DEV/SANDBOX/toolkit-status relocated from docs\)
    Add-Item $p 'README.md'           (Join-Path $RepoRoot 'README.md')
    Add-Item $p 'QUICKSTART.md'       (Join-Path $RepoRoot 'QUICKSTART.md')
    Add-Item $p 'DEV.md'              (Join-Path $RepoRoot 'docs\DEV.md')
    Add-Item $p 'SANDBOX-API-SETUP.md'(Join-Path $RepoRoot 'docs\SANDBOX-API-SETUP.md')
    Add-Item $p 'toolkit-status.md'   (Join-Path $RepoRoot 'docs\toolkit-status.md')
    # Tests (unit tests + static TestData) -- excludes Harness/ and Tools/
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'Tests') -File |
        Where-Object { $_.Name -eq 'Import-TestModules.ps1' -or $_.Name -like '*.Tests.ps1' } |
        ForEach-Object { Add-Item $p "Tests/$($_.Name)" $_.FullName }
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'Tests\TestData') -File |
        ForEach-Object { Add-Item $p "Tests/TestData/$($_.Name)" $_.FullName }
    return $p
}

# --- build ----------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
if (-not $PortableOnly) {
    $results.Add((Build-Zip (Get-UserPlan) (Join-Path $OutputDir 'SailPoint-GovernanceToolkit-UserHandoff.zip') 'UserHandoff (structured)'))
}
if (-not $UserOnly) {
    $results.Add((Build-Zip (Get-PortablePlan) (Join-Path $OutputDir 'SailPoint-GovernanceToolkit.zip') 'Portable'))
}
$results | Format-Table -AutoSize | Out-String | Write-Host
$results
