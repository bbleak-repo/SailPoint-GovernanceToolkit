#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    End-to-end tests for V8's Section 2 family -- Newly Decided, Re-Approved After
    Revoke, and Decision Activity -- rendered from state files built through the REAL
    state machine (Update-SPEntitlementState), never hand-written JSONL.

.DESCRIPTION
    Scenario (5 instances, 2026-09-01 .. 2026-09-05, all one series):
      a|x|s Ann/App_A   : P(01) -> A(03)            newly decided; approval event 09-03
      b|y|s Ben/App_B   : R(01 first seen) -> A(04) re-approved flop; approval event 09-04
      c|z|s Cyd/App_C   : A(01 first seen)          contributes NOTHING anywhere
      d|w|s Dot/App_D   : P(01) -> R(02)            revocation event 09-02
      e|v|s Eve/App_E   : P(01) -> R(03) -> A(05)   revocation 09-03 + approval 09-05 + flop

    Expected Decision Activity: 3 approval events (03/04/05), 2 revocation events (02/03).

    V8D-01: report renders read-only (-NoRefresh) from the synthesized state files
    V8D-02: Newly Decided carries the observed transitions, not first-seen decisions
    V8D-03: Re-Approved After Revoke lists both flops with mined revocation days
    V8D-04: Decision Activity daily counts are exact (chart + raw table)
    V8D-05: top revoked rankings + source breakdown are exact
    V8D-06: -NoRefresh does not rewrite the state files
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.EntitlementState.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '..\Modules\SP.Audit\SP.ReviewerState.psm1') -Force -DisableNameChecking
    $script:V8Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Invoke-SPDailyEvidenceReportV8.ps1'
    $script:MDir = Join-Path $TestDrive 'v8d-metrics'
    New-Item -ItemType Directory -Path $script:MDir -Force | Out-Null

    function New-V8DItem {
        param([string]$Key, [string]$Dec, [string]$Idn, [string]$Acc, [string]$Src = 'Corp AD')
        [PSCustomObject]@{
            ItemKey = $Key; HonestDecision = $Dec; IsAutoApproved = $false
            IsGenuineDecision = ($Dec -ne 'Undecided'); ReviewerName = 'Val Reviewer'
            ReviewerEmail = 'v@x.com'; ReviewerId = 'rv-1'; IdentityId = ($Key -split '\|')[0]
            IdentityName = $Idn; AccessName = $Acc; AccessType = 'ENTITLEMENT'
            SourceId = 'src-1'; SourceName = $Src; DecisionDate = '2026-09-01T10:00:00Z'
        }
    }

    $state = @{}
    $null = Update-SPEntitlementState -StateMap $state -InstanceId 'i1' -InstanceDate '2026-09-01' -SeriesName 's' -TodayLabel '2026-09-06' -ResolvedItems @(
        (New-V8DItem 'a|x|s' 'Undecided' 'Ann' 'App_A'), (New-V8DItem 'b|y|s' 'Revoked' 'Ben' 'App_B'),
        (New-V8DItem 'c|z|s' 'Approved' 'Cyd' 'App_C'), (New-V8DItem 'd|w|s' 'Undecided' 'Dot' 'App_D'),
        (New-V8DItem 'e|v|s' 'Undecided' 'Eve' 'App_E'))
    $null = Update-SPEntitlementState -StateMap $state -InstanceId 'i2' -InstanceDate '2026-09-02' -SeriesName 's' -TodayLabel '2026-09-06' -ResolvedItems @(
        (New-V8DItem 'd|w|s' 'Revoked' 'Dot' 'App_D'))
    $null = Update-SPEntitlementState -StateMap $state -InstanceId 'i3' -InstanceDate '2026-09-03' -SeriesName 's' -TodayLabel '2026-09-06' -ResolvedItems @(
        (New-V8DItem 'a|x|s' 'Approved' 'Ann' 'App_A'), (New-V8DItem 'e|v|s' 'Revoked' 'Eve' 'App_E'))
    $null = Update-SPEntitlementState -StateMap $state -InstanceId 'i4' -InstanceDate '2026-09-04' -SeriesName 's' -TodayLabel '2026-09-06' -ResolvedItems @(
        (New-V8DItem 'b|y|s' 'Approved' 'Ben' 'App_B'))
    $null = Update-SPEntitlementState -StateMap $state -InstanceId 'i5' -InstanceDate '2026-09-05' -SeriesName 's' -TodayLabel '2026-09-06' -ResolvedItems @(
        (New-V8DItem 'e|v|s' 'Approved' 'Eve' 'App_E'))

    $null = Write-SPEntitlementState -StateMap $state -Path (Join-Path $script:MDir 'entitlement-state.jsonl') -ProcessedInstances @{} -LastRunDate '2026-09-05'
    $rv = @{}
    $null = Update-SPReviewerState -ReviewerMap $rv -ResolvedItems @((New-V8DItem 'a|x|s' 'Approved' 'Ann' 'App_A')) -InstanceId 'i5' -InstanceDate '2026-09-05' -SeriesName 's' -InstanceStatus 'COMPLETED' -TodayLabel '2026-09-06'
    $null = Write-SPReviewerState -ReviewerMap $rv -Path (Join-Path $script:MDir 'reviewer-state.jsonl') -ProcessedInstances @{} -LastRunDate '2026-09-05'

    $script:EntWriteTime = (Get-Item (Join-Path $script:MDir 'entitlement-state.jsonl')).LastWriteTimeUtc

    $script:OutDir = Join-Path $TestDrive 'v8d-out'
    New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
    $null = & $script:V8Path -MetricsPath $script:MDir -OutputPath $script:OutDir -NoRefresh `
        -StartDate '2026-09-01' -EndDate '2026-09-06' -OutputMode HTML *>&1
    $hf = Get-ChildItem $script:OutDir -Filter 'daily-evidence-v8-*.html' | Select-Object -First 1
    $script:Html = if ($hf) { Get-Content $hf.FullName -Raw } else { '' }
}

Describe 'V8D-01: renders read-only from synthesized state' {
    It 'produced the HTML report' {
        $script:Html | Should -Not -BeNullOrEmpty
    }
}

Describe 'V8D-02: Newly Decided honors observed transitions' {
    It 'lists the PENDING->APPROVE item' {
        $script:Html | Should -Match 'Ann'
        $script:Html | Should -Match '>PENDING<'
    }
    It 'never lists the first-seen-approved item anywhere in section 2' {
        $script:Html | Should -Not -Match 'App_C'
    }
}

Describe 'V8D-03: Re-Approved After Revoke' {
    It 'reports both flops' {
        $script:Html | Should -Match 'Re-Approved After Revoke \(2\)'
    }
    It 'mines the revocation day from the state log for Ben (R on 09-01, A on 09-04)' {
        $script:Html | Should -Match 'Ben'
        $script:Html | Should -Match '2026-09-01'
        $script:Html | Should -Match '2026-09-04'
    }
}

Describe 'V8D-04: Decision Activity daily counts' {
    It 'header tallies 3 approval / 2 revocation events' {
        $script:Html | Should -Match 'Decision Activity \(3 approval / 2 revocation'
    }
    It 'raw daily rows are exact' {
        $script:Html | Should -Match '<tr><td>2026-09-02</td><td>0</td><td>1</td></tr>'
        $script:Html | Should -Match '<tr><td>2026-09-03</td><td>1</td><td>1</td></tr>'
        $script:Html | Should -Match '<tr><td>2026-09-04</td><td>1</td><td>0</td></tr>'
        $script:Html | Should -Match '<tr><td>2026-09-05</td><td>1</td><td>0</td></tr>'
    }
    It 'renders the trend chart SVG' {
        $script:Html | Should -Match '<svg[^>]*font-family'
    }
}

Describe 'V8D-05: rankings and source breakdown' {
    It 'top revoked entitlements include the two revoked apps' {
        $script:Html | Should -Match 'App_D'
        $script:Html | Should -Match 'App_E'
    }
    It 'source breakdown counts 3 approvals / 2 revocations for Corp AD' {
        $script:Html | Should -Match 'Corp AD</td><td>3</td><td>2</td>'
    }
}

Describe 'V8D-06: -NoRefresh is genuinely read-only' {
    It 'did not rewrite the entitlement state file' {
        (Get-Item (Join-Path $script:MDir 'entitlement-state.jsonl')).LastWriteTimeUtc | Should -Be $script:EntWriteTime
    }
}
