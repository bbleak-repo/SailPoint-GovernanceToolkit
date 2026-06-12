#Requires -Version 5.1
<#
.SYNOPSIS
    [DIAGNOSTIC] Validates campaign snapshot / items-cache JSON files for data completeness and
    consistency -- a fast, HTML-free data-quality check for spotting bad runs.
.DESCRIPTION
    Runs Test-SPCampaignSnapshotIntegrity over one file or every snapshot / items-cache
    file under a directory, and prints a findings report (or JSON). NO API, NO HTML,
    read-only. Use it to answer "did this run capture good data?" before trusting a diff
    or report -- it flags blank decision/source fields, decided-with-no-date, KPI/count
    mismatches, duplicate or blank join keys, empty captures, and partial (interrupted)
    item caches.

    What it inspects, by file kind (auto-detected):
      * Snapshot   (Build-SPCampaignSnapshotData JSON: Meta/Items/Kpi)
      * ItemsCache (items-{id}.jsonl + sibling items-{id}.meta.json)

.PARAMETER Path
    A snapshot .json, an items-*.jsonl, or a DIRECTORY. For a directory, every *.json
    snapshot (excluding *.meta.json) and every items-*.jsonl beneath it is validated.
    Defaults to the toolkit's snapshot directory (Audit\snapshots) when omitted.
.PARAMETER FieldCoverageWarnPct
    Warn when a key field (IdentityId/AccessName/SourceName/Decision/DecisionDate) is
    populated on fewer than this percent of items. Default 90.
.PARAMETER OutputMode
    Console (default): formatted findings to the terminal.
    JSON: machine-parseable result array.
    Both: console output followed by the JSON.
.PARAMETER Help
    Display full comment-based help and exit.
.EXAMPLE
    .\Invoke-SPCacheValidate.ps1 -Path '.\Audit\snapshots\camp-123\20260611-080000.json'
    # Validate a single snapshot.
.EXAMPLE
    .\Invoke-SPCacheValidate.ps1 -Path '.\Audit\snapshots' -OutputMode Console
    # Sweep every snapshot under the directory and flag any bad runs.
.EXAMPLE
    .\Invoke-SPCacheValidate.ps1 -Path '.\Audit\.cache\items-camp-123.jsonl'
    # Check a raw items cache for partial/corrupt fetches.
.NOTES
    Script:  Invoke-SPCacheValidate.ps1
    Version: 1.0.0
    Read-only (no -WhatIf / SupportsShouldProcess by policy: CLI-005).
    Exit codes:
        0 = all files OK (warnings may be present and are reported)
        1 = one or more files have ERROR-severity findings
        2 = parameter / path error (nothing validated)
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path,

    [Parameter()]
    [double]$FieldCoverageWarnPct = 90,

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

#region Module load
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitRoot = Split-Path -Parent $scriptRoot

foreach ($mod in @('SP.Core', 'SP.Audit')) {
    $manifest = Join-Path $toolkitRoot (Join-Path 'Modules' (Join-Path $mod "$mod.psd1"))
    if (Test-Path $manifest) {
        Import-Module $manifest -Force -DisableNameChecking -ErrorAction Stop
    }
    elseif ($mod -eq 'SP.Audit') {
        Write-Host "ERROR: Required module '$mod' not found at: $manifest" -ForegroundColor Red
        exit 2
    }
}
#endregion

#region Resolve targets
if ([string]::IsNullOrWhiteSpace($Path)) {
    # Default to the conventional snapshot directory.
    $Path = Join-Path $toolkitRoot (Join-Path 'Audit' 'snapshots')
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "ERROR: path not found: $Path" -ForegroundColor Red
    exit 2
}

$targets = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $Path -PathType Container) {
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Extension -eq '.json' -and $_.Name -notlike '*.meta.json') -or ($_.Name -like 'items-*.jsonl') } |
        Sort-Object FullName | ForEach-Object { [void]$targets.Add($_.FullName) }
    if ($targets.Count -eq 0) {
        Write-Host "  No snapshot (.json) or items cache (items-*.jsonl) files found under: $Path" -ForegroundColor Yellow
        exit 2
    }
}
else {
    [void]$targets.Add((Resolve-Path -LiteralPath $Path).Path)
}
#endregion

#region Validate
$results = [System.Collections.Generic.List[object]]::new()
foreach ($t in $targets) {
    $r = Test-SPCampaignSnapshotIntegrity -Path $t -FieldCoverageWarnPct $FieldCoverageWarnPct
    if (-not $r.Success) {
        $results.Add([ordered]@{
            File = $t; Kind = 'Unreadable'; Ok = $false
            Findings = @([ordered]@{ Severity = 'Error'; Code = 'UNREADABLE'; Message = $r.Error; Count = 0 })
            Summary = [ordered]@{ Kind = 'Unreadable' }
        })
    }
    else {
        $results.Add($r.Data)
    }
}

$anyError = $false
foreach ($res in $results) { if (-not $res.Ok) { $anyError = $true } }
#endregion

#region Output
if ($OutputMode -ne 'JSON') {
    Write-Host ''
    Write-Host '  SailPoint ISC Governance Toolkit' -ForegroundColor Cyan
    Write-Host '  Cache / Snapshot Data Validator' -ForegroundColor Cyan
    Write-Host "  $('=' * 64)" -ForegroundColor DarkGray
    foreach ($res in $results) {
        $errN  = @($res.Findings | Where-Object { $_.Severity -eq 'Error' }).Count
        $warnN = @($res.Findings | Where-Object { $_.Severity -eq 'Warn' }).Count
        $infoN = @($res.Findings | Where-Object { $_.Severity -eq 'Info' }).Count
        $tag   = if (-not $res.Ok) { 'ISSUES' } elseif ($warnN -gt 0) { 'WARN  ' } else { 'PASS  ' }
        $col   = if (-not $res.Ok) { 'Red' } elseif ($warnN -gt 0) { 'Yellow' } else { 'Green' }
        $label = if ($res.Summary -and $res.Summary.Contains('CampaignName') -and $res.Summary.CampaignName) {
                     "$($res.Summary.CampaignName)  [$($res.Kind)]"
                 } else { "[$($res.Kind)]" }
        Write-Host ''
        Write-Host "  [$tag] " -ForegroundColor $col -NoNewline
        Write-Host "$label" -ForegroundColor White
        Write-Host "          $(Split-Path -Leaf $res.File)" -ForegroundColor DarkGray
        if ($res.Summary -and $res.Summary.Contains('ItemCount')) {
            Write-Host "          items=$($res.Summary.ItemCount)  errors=$errN warns=$warnN info=$infoN" -ForegroundColor DarkGray
        }
        foreach ($f in @($res.Findings)) {
            $fcol = switch ($f.Severity) { 'Error' { 'Red' } 'Warn' { 'Yellow' } default { 'DarkGray' } }
            $cnt  = if ($f.Count -gt 0) { " (x$($f.Count))" } else { '' }
            Write-Host "            - [$($f.Severity)] $($f.Code): $($f.Message)$cnt" -ForegroundColor $fcol
        }
    }
    $okCount = @($results | Where-Object { $_.Ok }).Count
    Write-Host ''
    Write-Host "  $('=' * 64)" -ForegroundColor DarkGray
    Write-Host "  $okCount/$($results.Count) file(s) OK." -ForegroundColor $(if ($anyError) { 'Red' } else { 'Green' })
    Write-Host ''
}

if ($OutputMode -eq 'JSON' -or $OutputMode -eq 'Both') {
    if ($OutputMode -eq 'Both') { Write-Host '  JSON Output:' -ForegroundColor Cyan }
    [PSCustomObject]@{
        Validated = $results.Count
        OkCount   = @($results | Where-Object { $_.Ok }).Count
        AnyError  = $anyError
        Results   = $results.ToArray()
    } | ConvertTo-Json -Depth 8
}
#endregion

if ($anyError) { exit 1 } else { exit 0 }
