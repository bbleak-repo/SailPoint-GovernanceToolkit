#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Invoke-SPDailyOrchestrator.ps1 -- structural and static analysis.
.DESCRIPTION
    Tests: ORK-01 through ORK-06
    Covers:
        ORK-01: Script structure -- parses without errors, CmdletBinding, #Requires, help
        ORK-02: Parameters -- expected parameters and skip switches exist with correct types
        ORK-03: Step tracking -- $stepResults ordered hashtable with correct keys and fields
        ORK-04: Exit codes -- $worstExitCode variable and assignments for codes 0/1/3/4/5
        ORK-05: WhatIf support -- WhatIf detection and short-circuit behavior
        ORK-06: JSONL audit trail -- AppendAllText write with required event fields
#>

BeforeAll {
    $script:OrchestratorPath = Join-Path (Split-Path $PSScriptRoot -Parent) `
        'Scripts\Invoke-SPDailyOrchestrator.ps1'

    # Parse once; reuse across all contexts.
    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:OrchestratorPath, [ref]$tokens, [ref]$errors
    )
    $script:ParseErrors = $errors
    $script:Tokens      = $tokens

    # Helper: return the param() block AST.
    function Get-OrchestratorParamBlock {
        $script:Ast.ParamBlock
    }

    # Helper: return the CmdletBinding attribute from the param block.
    function Get-OrchestratorCmdletBinding {
        $pb = Get-OrchestratorParamBlock
        if ($null -eq $pb) { return $null }
        $pb.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
    }

    # Helper: find all string literals in the AST matching a pattern.
    function Find-StringLiterals {
        param([string]$Pattern)
        $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -match $Pattern
        }, $true)
    }

    # Helper: find all variable expressions by name (case-insensitive).
    function Find-VariableUse {
        param([string]$VariableName)
        $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -ieq $VariableName
        }, $true)
    }

    # Helper: find assignment AST nodes where the left side is the named variable.
    function Find-VariableAssignments {
        param([string]$VariableName)
        $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ieq $VariableName
        }, $true)
    }

    # Read raw source for simple text-based assertions.
    $script:RawSource = Get-Content -Path $script:OrchestratorPath -Raw
}

# ---------------------------------------------------------------------------
# ORK-01: Script structure
# ---------------------------------------------------------------------------

Describe "ORK-01: Script structure" {

    It "Script file exists" {
        Test-Path $script:OrchestratorPath | Should -BeTrue
    }

    It "Script parses without syntax errors" {
        $script:ParseErrors.Count | Should -Be 0 -Because "the orchestrator should have no parse errors"
    }

    It "First line is #Requires -Version 5.1" {
        $firstLine = (Get-Content -Path $script:OrchestratorPath -TotalCount 1).Trim()
        $firstLine | Should -Be '#Requires -Version 5.1'
    }

    It "Has [CmdletBinding()] attribute" {
        $cbAttr = Get-OrchestratorCmdletBinding
        $cbAttr | Should -Not -BeNullOrEmpty -Because "script should declare [CmdletBinding()]"
    }

    It "Has CmdletBinding with SupportsShouldProcess" {
        $cbAttr = Get-OrchestratorCmdletBinding
        $cbAttr | Should -Not -BeNullOrEmpty
        $sspArg = $cbAttr.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }
        $sspArg | Should -Not -BeNullOrEmpty -Because "orchestrator mutates state and must support -WhatIf"
    }

    It "Has comment-based help with .SYNOPSIS" {
        $script:RawSource | Should -Match '\.SYNOPSIS' -Because "script should document its purpose"
    }

    It "Has comment-based help with .DESCRIPTION" {
        $script:RawSource | Should -Match '\.DESCRIPTION'
    }

    It "Has comment-based help with at least one .EXAMPLE" {
        $script:RawSource | Should -Match '\.EXAMPLE'
    }
}

# ---------------------------------------------------------------------------
# ORK-02: Parameters
# ---------------------------------------------------------------------------

Describe "ORK-02: Parameters" {

    BeforeAll {
        $pb = Get-OrchestratorParamBlock
        $script:ParamNames = $pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    }

    Context "Core parameters" {

        It "Has -ConfigPath parameter" {
            $script:ParamNames | Should -Contain 'ConfigPath'
        }

        It "Has -Token parameter" {
            $script:ParamNames | Should -Contain 'Token'
        }

        It "Has -TokenExpiryMinutes parameter" {
            $script:ParamNames | Should -Contain 'TokenExpiryMinutes'
        }

        It "-TokenExpiryMinutes has default value of 10" {
            $pb = Get-OrchestratorParamBlock
            $param = $pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TokenExpiryMinutes' }
            $param | Should -Not -BeNullOrEmpty
            $param.DefaultValue | Should -Not -BeNullOrEmpty -Because "TokenExpiryMinutes should have a default"
            $param.DefaultValue.Value | Should -Be 10
        }

        It "Has -SourceId parameter" {
            $script:ParamNames | Should -Contain 'SourceId'
        }

        It "Has -CampaignNamePrefix parameter" {
            $script:ParamNames | Should -Contain 'CampaignNamePrefix'
        }

        It "Has -OutputMode parameter" {
            $script:ParamNames | Should -Contain 'OutputMode'
        }

        It "Has -OutputPath parameter" {
            $script:ParamNames | Should -Contain 'OutputPath'
        }
    }

    Context "Skip switches" {

        It "Has -SkipValidation switch" {
            $script:ParamNames | Should -Contain 'SkipValidation'
        }

        It "Has -SkipCleanup switch" {
            $script:ParamNames | Should -Contain 'SkipCleanup'
        }

        It "Has -SkipDeltaCert switch" {
            $script:ParamNames | Should -Contain 'SkipDeltaCert'
        }

        It "Has -SkipDeltaReport switch" {
            $script:ParamNames | Should -Contain 'SkipDeltaReport'
        }

        It "Has -SkipEscalation switch" {
            $script:ParamNames | Should -Contain 'SkipEscalation'
        }

        It "Has -SkipHealthCheck switch" {
            $script:ParamNames | Should -Contain 'SkipHealthCheck'
        }

        It "Has -SkipDisconnectedApps switch covering steps 7-9" {
            $script:ParamNames | Should -Contain 'SkipDisconnectedApps'
        }

        It "Has -SkipRetention switch" {
            $script:ParamNames | Should -Contain 'SkipRetention'
        }

        It "All skip parameters are SwitchParameter type" {
            $pb = Get-OrchestratorParamBlock
            $skipParams = $pb.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -like 'Skip*'
            }
            $skipParams.Count | Should -BeGreaterOrEqual 7 -Because "at least 7 skip switches expected"
            foreach ($sp in $skipParams) {
                $sp.StaticType.Name | Should -Be 'SwitchParameter' `
                    -Because "$($sp.Name.VariablePath.UserPath) should be a switch"
            }
        }
    }

    Context "Help switch" {

        It "Has -Help switch parameter" {
            $script:ParamNames | Should -Contain 'Help'
        }

        It "-Help is a SwitchParameter" {
            $pb = Get-OrchestratorParamBlock
            $helpParam = $pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Help' }
            $helpParam | Should -Not -BeNullOrEmpty
            $helpParam.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It "-Help has Alias '?'" {
            $pb = Get-OrchestratorParamBlock
            $helpParam = $pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Help' }
            $helpParam | Should -Not -BeNullOrEmpty
            $aliasAttr = $helpParam.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }
            $aliasAttr | Should -Not -BeNullOrEmpty -Because "-Help should have an [Alias()] attribute"
            $aliasValues = $aliasAttr.PositionalArguments | ForEach-Object { $_.Value }
            $aliasValues | Should -Contain '?' -Because "-Help should be aliased to '?'"
        }
    }

    Context "Override parameters" {

        It "Has -HoursBack override parameter" {
            $script:ParamNames | Should -Contain 'HoursBack'
        }

        It "Has -DeadlineDays override parameter" {
            $script:ParamNames | Should -Contain 'DeadlineDays'
        }

        It "Has -ReviewerMode override parameter" {
            $script:ParamNames | Should -Contain 'ReviewerMode'
        }

        It "Has -StaleHours override parameter" {
            $script:ParamNames | Should -Contain 'StaleHours'
        }
    }
}

# ---------------------------------------------------------------------------
# ORK-03: Step tracking
# ---------------------------------------------------------------------------

Describe "ORK-03: Step tracking" {

    BeforeAll {
        # Locate the $stepResults assignment via AST: find the [ordered]@{...} hashtable
        # assigned to $stepResults.
        $assignments = Find-VariableAssignments -VariableName 'stepResults'
        $script:StepResultsAssignment = $assignments | Select-Object -First 1

        # Collect the key names from the ordered hashtable literal.
        # The right-hand side is a CommandExpressionAst wrapping [ordered]@{...}, so we
        # use FindAll to locate the nested HashtableAst rather than navigating by .Child.
        $script:StepKeys = @()
        if ($null -ne $script:StepResultsAssignment) {
            $htNodes = $script:StepResultsAssignment.Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.HashtableAst]
            }, $true)
            if ($htNodes.Count -gt 0) {
                $script:StepKeys = $htNodes[0].KeyValuePairs |
                    ForEach-Object { $_.Item1.Value }
            }
        }
    }

    It "Script defines a \$stepResults variable" {
        $script:StepResultsAssignment | Should -Not -BeNullOrEmpty `
            -Because "`$stepResults must be initialized before any step runs"
    }

    It "\$stepResults has at least 10 step keys" {
        $script:StepKeys.Count | Should -BeGreaterOrEqual 10 `
            -Because "the orchestrator has 10 tracked steps (steps 1-10)"
    }

    It "\$stepResults contains 'Validation' key (Step 1)" {
        $script:StepKeys | Should -Contain 'Validation'
    }

    It "\$stepResults contains 'Cleanup' key (Step 2)" {
        $script:StepKeys | Should -Contain 'Cleanup'
    }

    It "\$stepResults contains 'DeltaCert' key (Step 3)" {
        $script:StepKeys | Should -Contain 'DeltaCert'
    }

    It "\$stepResults contains 'DeltaReport' key (Step 4)" {
        $script:StepKeys | Should -Contain 'DeltaReport'
    }

    It "\$stepResults contains 'Escalation' key (Step 5)" {
        $script:StepKeys | Should -Contain 'Escalation'
    }

    It "\$stepResults contains 'HealthCheck' key (Step 6)" {
        $script:StepKeys | Should -Contain 'HealthCheck'
    }

    It "\$stepResults contains 'DABatch' key (Step 7)" {
        $script:StepKeys | Should -Contain 'DABatch'
    }

    It "\$stepResults contains 'DADecisions' key (Step 8)" {
        $script:StepKeys | Should -Contain 'DADecisions'
    }

    It "\$stepResults contains 'DARemediation' key (Step 9)" {
        $script:StepKeys | Should -Contain 'DARemediation'
    }

    It "\$stepResults contains 'Retention' key (Step 10)" {
        $script:StepKeys | Should -Contain 'Retention'
    }

    It "Each step entry initializes with Status, Detail, and Duration fields" {
        # Find all hashtable literals that are values in the stepResults initialization.
        # We verify by scanning the raw source for the characteristic triple.
        $script:RawSource | Should -Match "Status\s*=\s*'Skipped'" `
            -Because "initial step status should be 'Skipped'"
        $script:RawSource | Should -Match "Detail\s*=\s*''" `
            -Because "initial detail should be an empty string"
        $script:RawSource | Should -Match 'Duration\s*=\s*0' `
            -Because "initial duration should be 0"
    }

    It "Script defines a Set-StepResult helper function" {
        $functions = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-StepResult'
        }, $true)
        $functions.Count | Should -BeGreaterOrEqual 1 `
            -Because "Set-StepResult is the central step recording helper"
    }
}

# ---------------------------------------------------------------------------
# ORK-04: Exit codes
# ---------------------------------------------------------------------------

Describe "ORK-04: Exit codes" {

    BeforeAll {
        # Locate all 'exit' statements in the script.
        $script:ExitStatements = $script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ExitStatementAst]
        }, $true)

        # Collect the distinct integer values passed to 'exit'.
        $script:ExitValues = $script:ExitStatements | ForEach-Object {
            if ($null -ne $_.Pipeline) {
                $_.Pipeline.ToString().Trim()
            }
        } | Where-Object { $_ -ne $null } | Sort-Object -Unique
    }

    It "Script has at least one exit statement" {
        $script:ExitStatements.Count | Should -BeGreaterOrEqual 1
    }

    It "Script uses \$worstExitCode variable" {
        $uses = Find-VariableUse -VariableName 'worstExitCode'
        $uses.Count | Should -BeGreaterThan 0 `
            -Because "`$worstExitCode drives the final exit code"
    }

    It "\$worstExitCode is initialized to 0 (success baseline)" {
        $assignments = Find-VariableAssignments -VariableName 'worstExitCode'
        $zeroInit = $assignments | Where-Object {
            $_.Right.ToString().Trim() -eq '0'
        }
        $zeroInit | Should -Not -BeNullOrEmpty -Because "exit code 0 = all steps succeeded"
    }

    It "Script assigns \$worstExitCode value 1 (warning)" {
        $script:RawSource | Should -Match '\$worstExitCode\s*=\s*1' `
            -Because "exit code 1 = non-critical step warnings"
    }

    It "Script assigns \$worstExitCode value 3 (auth error)" {
        # Exit code 3 is used directly: 'exit 3' after token failure.
        $script:RawSource | Should -Match 'exit\s+3' `
            -Because "exit code 3 = authentication error"
    }

    It "Script assigns \$worstExitCode value 4 (config/validation failure)" {
        $script:RawSource | Should -Match '\$worstExitCode\s*=\s*4' `
            -Because "exit code 4 = configuration validation failed"
    }

    It "Script assigns \$worstExitCode value 5 (critical step failure)" {
        $script:RawSource | Should -Match '\$worstExitCode\s*=\s*5' `
            -Because "exit code 5 = critical step failed"
    }

    It "Script exits using \$worstExitCode as the final expression" {
        # The terminal 'exit $worstExitCode' statement should exist.
        $exitWithVar = $script:ExitStatements | Where-Object {
            $null -ne $_.Pipeline -and
            $_.Pipeline.ToString().Trim() -match '\$worstExitCode'
        }
        $exitWithVar | Should -Not -BeNullOrEmpty `
            -Because "the final exit statement must propagate `$worstExitCode"
    }
}

# ---------------------------------------------------------------------------
# ORK-05: WhatIf support
# ---------------------------------------------------------------------------

Describe "ORK-05: WhatIf support" {

    It "Script detects WhatIf via \$WhatIfPreference" {
        $script:RawSource | Should -Match 'WhatIfPreference' `
            -Because "CmdletBinding sets `$WhatIfPreference when -WhatIf is passed"
    }

    It "Script stores WhatIf detection in \$isWhatIf variable" {
        $uses = Find-VariableUse -VariableName 'isWhatIf'
        $uses.Count | Should -BeGreaterThan 0 `
            -Because "`$isWhatIf is used throughout to gate write operations"
    }

    It "\$isWhatIf is assigned from \$WhatIfPreference" {
        $assignments = Find-VariableAssignments -VariableName 'isWhatIf'
        $wifAssign = $assignments | Where-Object {
            $_.Right.ToString() -match 'WhatIfPreference'
        }
        $wifAssign | Should -Not -BeNullOrEmpty `
            -Because "`$isWhatIf should be derived from `$WhatIfPreference"
    }

    It "Script has a WhatIf short-circuit or notice block" {
        # The script emits a dry-run notice when $isWhatIf is true.
        $script:RawSource | Should -Match '\[WhatIf\]' `
            -Because "a WhatIf notice should be written to the console"
    }

    It "Sub-steps receive WhatIf via explicit parameter injection" {
        # Each step guard: if ($isWhatIf) { $params['WhatIf'] = $true }
        $script:RawSource | Should -Match "isWhatIf.*WhatIf|WhatIf.*isWhatIf" `
            -Because "sub-script invocations must propagate WhatIf"
    }

    It "WhatIf result label is 'WHATIF' in summary" {
        $script:RawSource | Should -Match "'WHATIF'" `
            -Because "the daily summary labels a WhatIf run distinctly"
    }
}

# ---------------------------------------------------------------------------
# ORK-06: JSONL audit trail
# ---------------------------------------------------------------------------

Describe "ORK-06: JSONL audit trail" {

    It "Script calls [System.IO.File]::AppendAllText for the JSONL audit file" {
        $script:RawSource | Should -Match 'AppendAllText' `
            -Because "the audit trail is written with AppendAllText to build a JSONL log"
    }

    It "Audit file has a .jsonl extension" {
        $script:RawSource | Should -Match '\.jsonl' `
            -Because "audit trail uses the JSONL (newline-delimited JSON) format"
    }

    It "Audit event includes 'Timestamp' field" {
        $script:RawSource | Should -Match "Timestamp\s*=" `
            -Because "each audit event must be timestamped"
    }

    It "Audit event includes 'Action' field set to 'DailyOrchestrator'" {
        $script:RawSource | Should -Match "Action\s*=\s*'DailyOrchestrator'" `
            -Because "Action identifies the source of the audit event"
    }

    It "Audit event includes 'CorrelationID' field" {
        $script:RawSource | Should -Match "CorrelationID\s*=" `
            -Because "CorrelationID links the audit event to the orchestrator run"
    }

    It "Audit event 'Data' contains 'Steps' field (the step results)" {
        $script:RawSource | Should -Match "Steps\s*=" `
            -Because "audit Data.Steps carries the per-step outcome summary"
    }

    It "Audit event uses UTC timestamps (ToUniversalTime)" {
        $script:RawSource | Should -Match 'ToUniversalTime' `
            -Because "audit timestamps should be in UTC for consistency"
    }

    It "Audit event uses UTF-8-no-BOM encoding" {
        $script:RawSource | Should -Match 'UTF8Encoding' `
            -Because "JSONL files should use UTF-8 without BOM"
    }

    It "Script writes audit trail before early-exit on config failure" {
        # The early-abort block for Step 1 also calls AppendAllText before exiting.
        # Verify there are multiple occurrences of AppendAllText.
        $occurrences = ([regex]::Matches($script:RawSource, 'AppendAllText')).Count
        $occurrences | Should -BeGreaterOrEqual 2 `
            -Because "audit trail is written both in the early-abort path and at normal completion"
    }
}
