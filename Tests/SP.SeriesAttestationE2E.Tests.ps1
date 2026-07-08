#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    END-TO-END Pester proof of the full V4c series-attestation chain on one synthetic
    11-instance recurring series ("Daily Attestation Manager Campaign - <date>").
.DESCRIPTION
    Proves the WHOLE pipeline on committed rich-cache fixtures:
      committed cache  ->  Get-SPCachedCampaignSeries (variance-tolerant grouping)
                       ->  Get-SPSeriesAttestationDelta (honest classification)
                       ->  Invoke-SPDailyEvidenceReportV4c.ps1 (HTML render).

    The fixture (Tests/TestData/SeriesAttestation/cache, emitted by the deterministic
    Build-SeriesAttestationFixture.ps1) INTENTIONALLY varies the campaign-name spacing /
    separator across instances (spaced hyphen, no-space hyphen, en-dash, double-spaced
    hyphen) -- all 11 MUST still collapse into ONE series.

      E2E-GROUP   variance-tolerant auto-derivation -> 1 series, 11 instances, Daily.
      E2E-ENGINE  the four scenario items classify correctly + honest Counts.
      E2E-CLI     the read-only CLI (child powershell.exe) renders honest HTML; the
                  Newly Attested headline is 2; AlreadyAttestedEarlier (Bob/HR-ReadOnly)
                  is EXCLUDED from the newly-attested section.

    Scenario items (static scope across all 11 instances => NewlyInScope = 0):
      id-alice|finance-rw|src-ad  NewlyAttested            (genuine approve only @ newest)
      id-bob|hr-readonly|src-ad     AlreadyAttestedEarlier   (genuine approve mid-window)
      id-carol|vpn-access|src-ad     NewlyAttested + masked   (prior idNowAutoApproved ignored)
      id-dave|admin-console|src-ad    PersistentlyUndecided    (pending in all 11)

    The CLI-invoking Describe is gated behind -Skip:(-not $script:PwshAvailable) for
    powershell.exe (always present on this Win box) mirroring SP.SeriesAttestationCli.Tests.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Import-TestModules.ps1')
    Import-SPTestModules -Shared -Core -Api -Audit

    $script:PwshAvailable = [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
    $script:V4cPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV4c.ps1'

    # Resolve the COMMITTED cache fixture; self-heal by regenerating into $TestDrive when the
    # committed copy is missing/stale (so the suite never depends on a stale on-disk copy).
    $committedCache = Join-Path (Join-Path (Join-Path $PSScriptRoot 'TestData') 'SeriesAttestation') 'cache'
    $hasFixture = $false
    if (Test-Path $committedCache) {
        $hasFixture = @(Get-ChildItem -Path $committedCache -Filter 'items-*.meta.json' -File -ErrorAction SilentlyContinue).Count -gt 0
    }
    if ($hasFixture) {
        $script:CacheDir = $committedCache
    }
    else {
        $gen = Join-Path (Join-Path (Join-Path $PSScriptRoot 'TestData') 'SeriesAttestation') 'Build-SeriesAttestationFixture.ps1'
        $script:CacheDir = Join-Path $TestDrive 'sa-cache'
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        & $gen -OutputDir $script:CacheDir | Out-Null
    }

    $script:AliceKey = 'id-alice|finance-rw|src-ad'
    $script:BobKey   = 'id-bob|hr-readonly|src-ad'
    $script:CarolKey = 'id-carol|vpn-access|src-ad'
    $script:DaveKey  = 'id-dave|admin-console|src-ad'
}

Describe 'E2E-GROUP: variance-tolerant auto-derivation collapses all 11 into ONE series' {
    BeforeAll {
        $script:gr = Get-SPCachedCampaignSeries -CachePath $script:CacheDir
        $script:grSeries = @($script:gr.Data.Series)
    }
    It 'reads the cache successfully' { $script:gr.Success | Should -BeTrue }
    It 'derives exactly one series (spacing/separator/en-dash variances collapsed)' {
        $script:gr.Data.SeriesCount | Should -Be 1
    }
    It 'keeps all 11 instances in the single series' {
        $script:grSeries[0].InstanceCount | Should -Be 11
    }
    It 'classifies the series period as Daily' {
        $script:grSeries[0].PeriodType | Should -Be 'Daily'
    }
    It 'normalizes the stem regardless of human spacing/case' {
        $script:grSeries[0].NormalizedStem | Should -Be 'daily attestation manager campaign'
    }
}

Describe 'E2E-ENGINE: honest cross-instance classification of the four scenario items' {
    BeforeAll {
        $r = Get-SPCachedCampaignSeries -CachePath $script:CacheDir
        $series = @($r.Data.Series)[0]

        # Materialize each instance EXACTLY like the V4c CLI Step 3.
        $deltaInstances = New-Object System.Collections.Generic.List[object]
        foreach ($inst in @($series.Instances)) {
            $deltaInstances.Add([pscustomobject]@{
                    OrderIndex   = $inst.OrderIndex
                    CampaignId   = $inst.CampaignId
                    CampaignName = $inst.CampaignName
                    Status       = $inst.Status
                    Unverified   = $inst.Unverified
                    PeriodToken  = $inst.PeriodToken
                    Items        = @(& $inst.LoadItems)
                    Roster       = @(& $inst.LoadRoster)
                })
        }

        $script:dr = Get-SPSeriesAttestationDelta -Instances @($deltaInstances.ToArray()) `
            -SeriesStem ([string]$series.SeriesStem) -NormalizedStem ([string]$series.NormalizedStem) `
            -PeriodType ([string]$series.PeriodType)

        $script:byKey = @{}
        foreach ($it in @($script:dr.Data.Items)) { $script:byKey[[string]$it.ItemKey] = $it }
    }

    It 'succeeds' { $script:dr.Success | Should -BeTrue }

    It 'flags id-alice as NewlyAttested (genuine approve only at the newest instance)' {
        $rec = $script:byKey[$script:AliceKey]
        $rec | Should -Not -BeNullOrEmpty
        $rec.Classification                 | Should -Be 'NewlyAttested'
        $rec.IsNewlyAttested                | Should -BeTrue
        $rec.IsAlreadyAttestedEarlier       | Should -BeFalse
        $rec.PriorAutoApprovedMasked        | Should -BeFalse
        $rec.FirstGenuineApprovalOrderIndex | Should -Be 10
    }

    It 'flags id-bob as AlreadyAttestedEarlier (genuine approve earlier in the window)' {
        $rec = $script:byKey[$script:BobKey]
        $rec | Should -Not -BeNullOrEmpty
        $rec.Classification           | Should -Be 'AlreadyAttestedEarlier'
        $rec.IsAlreadyAttestedEarlier | Should -BeTrue
        $rec.IsNewlyAttested          | Should -BeFalse
        $rec.IsDecisionChanged        | Should -BeFalse
    }

    It 'flags id-carol as NewlyAttested with PriorAutoApprovedMasked (the OI1 auto-approve did NOT register)' {
        $rec = $script:byKey[$script:CarolKey]
        $rec | Should -Not -BeNullOrEmpty
        $rec.Classification                 | Should -Be 'NewlyAttested'
        $rec.IsNewlyAttested                | Should -BeTrue
        $rec.PriorAutoApprovedMasked        | Should -BeTrue
        $rec.IsAlreadyAttestedEarlier       | Should -BeFalse
        $rec.FirstGenuineApprovalOrderIndex | Should -Be 10
    }

    It 'flags id-dave as PersistentlyUndecided (pending in all 11 instances)' {
        $rec = $script:byKey[$script:DaveKey]
        $rec | Should -Not -BeNullOrEmpty
        $rec.Classification         | Should -Be 'PersistentlyUndecided'
        $rec.IsPersistentlyUndecided | Should -BeTrue
    }

    It 'reports the honest Counts (NewlyAttested 2, AlreadyAttestedEarlier 1, PersistentlyUndecided 1, rest 0)' {
        $c = $script:dr.Data.Counts
        $c.NewlyAttested          | Should -Be 2
        $c.AlreadyAttestedEarlier | Should -Be 1
        $c.PersistentlyUndecided  | Should -Be 1
        $c.NewlyInScope           | Should -Be 0
        $c.DecisionChanged        | Should -Be 0
        $c.Total                  | Should -Be 4
    }

    It 'attributes the newly-attested items to the cert-assigned reviewer Mona Manager' {
        $na = @($script:dr.Data.NewlyAttestedByReviewer)
        $na.Count | Should -Be 1
        $na[0].ReviewerName | Should -Be 'Mona Manager'
        $na[0].Count        | Should -Be 2
    }
}

Describe 'E2E-CLI: the read-only V4c CLI renders honest HTML end-to-end' {
    BeforeAll {
        $script:cliOut = Join-Path $TestDrive 'e2e-cli-out'
        New-Item -ItemType Directory -Path $script:cliOut -Force | Out-Null

        if ($script:PwshAvailable) {
            & powershell.exe -NoProfile -File $script:V4cPath -CachePath $script:CacheDir -OutputPath $script:cliOut -OutputMode HTML | Out-Null
            $script:cliExit = $LASTEXITCODE
            $script:cliHtml = (Get-ChildItem -Path $script:cliOut -Filter 'daily-evidence-v4c-*.html' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($null -ne $script:cliHtml) {
                $script:cliContent = Get-Content $script:cliHtml.FullName -Raw
            }
        }
    }

    It 'exits 0' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cliExit | Should -Be 0
    }

    It 'writes a non-trivial daily-evidence-v4c-*.html' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cliHtml | Should -Not -BeNullOrEmpty
        $script:cliHtml.Length | Should -BeGreaterThan 500
    }

    It 'names the report and the honest section headings' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cliContent | Should -Match 'Daily Evidence Report v4c'
        $script:cliContent | Should -Match 'Newly Attested'
        $script:cliContent | Should -Match 'Persistently Undecided'
    }

    It 'renders the cert-assigned reviewer and the newly-attested access' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cliContent | Should -Match 'Mona Manager'
        $script:cliContent | Should -Match 'Finance-RW'
        $script:cliContent | Should -Match 'VPN-Access'
        $script:cliContent | Should -Match 'Admin-Console'
        $script:cliContent | Should -Match 'Alice Anders'
        $script:cliContent | Should -Match 'Carol Clark'
        $script:cliContent | Should -Match 'Dave Davis'
    }

    It 'renders the honest Newly Attested KPI of 2' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        $script:cliContent | Should -Match ">2</span><span class='l'>Newly Attested"
    }

    It 'EXCLUDES AlreadyAttestedEarlier (Bob/HR-ReadOnly) from the Newly Attested section' {
        if (-not $script:PwshAvailable) { Set-ItResult -Skipped -Because 'powershell.exe not available'; return }
        # Isolate the Newly Attested section: between its title and the next section title.
        $startMarker = 'Newly Attested This Period'
        $endMarker   = 'Persistently Undecided / Never Attested'
        $si = $script:cliContent.IndexOf($startMarker)
        $ei = $script:cliContent.IndexOf($endMarker)
        $si | Should -BeGreaterThan -1
        $ei | Should -BeGreaterThan $si
        $naSection = $script:cliContent.Substring($si, $ei - $si)
        $naSection | Should -Not -Match 'HR-ReadOnly'
        $naSection | Should -Not -Match 'Bob Brown'
        # ...while a genuinely newly-attested identity IS inside that section.
        $naSection | Should -Match 'Alice Anders'
    }
}
