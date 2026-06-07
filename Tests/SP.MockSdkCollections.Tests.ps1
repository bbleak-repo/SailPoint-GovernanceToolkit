#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    T-03 -- Mock serves non-empty SDK collections (seed-drop regression guard).

    Catches the exact regression that triggered this run: a seed regeneration
    (New-BulkSeedData) that dropped the SDK collections so that
    /v3/access-request-approvals, /v3/workflows, and /v3/campaign-filters all
    served 0 rows -- leaving the SDK tab's Approvals / Workflows / Campaign
    Filters sub-tabs empty -- while Templates and Work Items were fine.

    When a live mock is reachable at http://localhost:8080 (probe /health), this
    test obtains a single OAuth Bearer token and asserts that ALL of the SDK
    collections serve NON-EMPTY counts:
      * /v3/access-request-approvals/pending          (>=1)
      * /v3/access-request-approvals/completed         (>=1)
      * /v3/access-request-approvals/approval-summary  (pending+approved+rejected > 0)
      * /v3/workflows                                  (>=1)
      * /v3/workflows/{id}/executions                  (>=1 for at least one workflow)
      * /v3/campaign-filters                           (>=1)
      * /v3/campaign-templates                         (>=1)
      * /v3/work-items/summary                         (open+completed > 0)

    Pure raw Invoke-RestMethod probing -- NO toolkit modules, NO Show-SPDashboard,
    NO FlaUI. When the mock is NOT reachable (or OAuth fails) the live Context is
    marked Inconclusive via Set-ItResult so the full suite stays GREEN in a
    headless CI environment without a running mock.

    BaseUrl is overridable via $env:SP_MOCK_BASEURL (default http://localhost:8080).
#>

Describe 'SP.MockSdkCollections - mock serves non-empty SDK collections (seed-drop regression guard)' {

    BeforeAll {
        if ($env:SP_MOCK_BASEURL) {
            $script:BaseUrl = $env:SP_MOCK_BASEURL
        } else {
            $script:BaseUrl = 'http://localhost:8080'
        }

        # Reachability probe -> $script:MockUp ($true/$false).
        $script:MockUp  = $false
        $script:Token   = $null
        $script:Headers = $null

        try {
            $h = Invoke-RestMethod -Uri "$($script:BaseUrl)/health" -TimeoutSec 3 -ErrorAction Stop
            if ($h.status -eq 'ok') { $script:MockUp = $true }
        } catch {
            $script:MockUp = $false
        }

        # Obtain the OAuth token EXACTLY ONCE (mock tokens rotate; re-fetching
        # mid-suite can 401 with a stale token). Reuse $script:Headers for all probes.
        if ($script:MockUp) {
            try {
                $body = 'grant_type=client_credentials&client_id=test&client_secret=test'
                $t = Invoke-RestMethod -Uri "$($script:BaseUrl)/oauth/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 5 -ErrorAction Stop
                if ($t.access_token) {
                    $script:Token   = $t.access_token
                    $script:Headers = @{ Authorization = "Bearer $($script:Token)" }
                } else {
                    $script:MockUp = $false
                }
            } catch {
                $script:MockUp = $false
            }
        }

        # Helper closure: GET a /v3 endpoint with the bearer header, return parsed JSON.
        $script:Probe = {
            param([string]$Path)
            Invoke-RestMethod -Uri "$($script:BaseUrl)$Path" -Headers $script:Headers -TimeoutSec 10 -ErrorAction Stop
        }
    }

    Context 'Live mock SDK collections are non-empty' {

        BeforeEach {
            if (-not $script:MockUp) {
                Set-ItResult -Inconclusive -Because 'mock not reachable at /health or OAuth failed; live regression guard skipped (headless CI without a mock stays green)'
            }
        }

        It 'serves >=1 pending approval (/v3/access-request-approvals/pending)' {
            $d = & $script:Probe '/v3/access-request-approvals/pending'
            @($d).Count | Should -BeGreaterThan 0
        }

        It 'serves >=1 completed approval (/v3/access-request-approvals/completed)' {
            # Assign first: in PS 5.1 @(Invoke-RestMethod ...) as a DIRECT expression
            # wraps the returned Object[] as a single element (.Count always 1).
            # The assign-first idiom unrolls correctly so an empty [] yields .Count 0.
            $d = & $script:Probe '/v3/access-request-approvals/completed'
            @($d).Count | Should -BeGreaterThan 0
        }

        It 'serves an approval-summary with pending+approved+rejected total > 0 (/v3/access-request-approvals/approval-summary)' {
            $s = & $script:Probe '/v3/access-request-approvals/approval-summary'
            ([int]$s.pending + [int]$s.approved + [int]$s.rejected) | Should -BeGreaterThan 0
        }

        It 'serves >=1 workflow (/v3/workflows)' {
            $wf = @(& $script:Probe '/v3/workflows')
            $wf.Count | Should -BeGreaterThan 0
        }

        It 'serves >=1 execution for at least one workflow (/v3/workflows/{id}/executions)' {
            $wf = @(& $script:Probe '/v3/workflows')
            $wf.Count | Should -BeGreaterThan 0
            $found = $false
            foreach ($w in $wf) {
                $ex = @(& $script:Probe "/v3/workflows/$($w.id)/executions")
                if ($ex.Count -gt 0) { $found = $true; break }
            }
            $found | Should -BeTrue
        }

        It 'serves >=1 campaign-filter (/v3/campaign-filters)' {
            # Assign first (see completed-approval note): @(Invoke-RestMethod ...) as a
            # direct expression does NOT unroll in PS 5.1, so an empty [] would falsely
            # report .Count 1 and defeat the regression guard.
            $f = & $script:Probe '/v3/campaign-filters'
            @($f).Count | Should -BeGreaterThan 0
        }

        It 'serves >=1 campaign-template (/v3/campaign-templates)' {
            # Assign first (see completed-approval note) so an empty [] yields .Count 0.
            $t = & $script:Probe '/v3/campaign-templates'
            @($t).Count | Should -BeGreaterThan 0
        }

        It 'serves a work-items summary with open+completed > 0 (/v3/work-items/summary)' {
            $ws = & $script:Probe '/v3/work-items/summary'
            ([int]$ws.open + [int]$ws.completed) | Should -BeGreaterThan 0
        }
    }
}
