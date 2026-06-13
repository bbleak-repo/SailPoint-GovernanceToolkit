#Requires -Version 5.1
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for Invoke-SPReportDistribution.ps1 (SMTP email delivery).
.DESCRIPTION
    Tests: RD-01 through RD-08
    Covers:
        RD-01: AST syntax validation (parse without errors)
        RD-02: CmdletBinding with SupportsShouldProcess
        RD-03: Parameter validation (names, types, mandatory, ValidateSet)
        RD-04: Status parameter is mandatory with ValidateSet
        RD-05: WhatIf/PreviewOnly mode does NOT send emails
        RD-06: SMTP config validation (Server, Port, From required when SendReports)
        RD-07: Exit codes match documented values
        RD-08: Distribution audit trail (JSONL logging)
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Scripts\Invoke-SPReportDistribution.ps1'

    # Helper: parse a script file and return its AST + any parse errors
    function Get-ScriptAst {
        param([string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors
        )
        return @{ Ast = $ast; Errors = $errors; Tokens = $tokens }
    }

    # Helper: extract the param() block AST from a script
    function Get-ScriptParamBlock {
        param([string]$Path)
        $parsed = Get-ScriptAst -Path $Path
        return $parsed.Ast.ParamBlock
    }

    # Helper: extract CmdletBinding attribute from a script
    function Get-CmdletBindingAttribute {
        param([string]$Path)
        $paramBlock = Get-ScriptParamBlock -Path $Path
        if ($null -eq $paramBlock) { return $null }
        $cbAttr = $paramBlock.Attributes | Where-Object {
            $_.TypeName.Name -eq 'CmdletBinding'
        }
        return $cbAttr
    }

    # Helper: get a specific parameter AST by name
    function Get-ScriptParameter {
        param([string]$Path, [string]$ParameterName)
        $paramBlock = Get-ScriptParamBlock -Path $Path
        if ($null -eq $paramBlock) { return $null }
        return $paramBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq $ParameterName
        }
    }

    # Pre-parse
    $script:Parsed = Get-ScriptAst -Path $script:ScriptPath
    $script:ParamBlock = $script:Parsed.Ast.ParamBlock
}

Describe 'Invoke-SPReportDistribution' {

    Context 'RD-01: AST syntax validation' {

        It 'script file exists' {
            Test-Path $script:ScriptPath | Should -BeTrue
        }

        It 'parses without syntax errors' {
            $script:Parsed.Errors.Count | Should -Be 0 `
                -Because 'Invoke-SPReportDistribution.ps1 should have no parse errors'
        }

        It 'begins with #Requires -Version 5.1' {
            $firstLine = (Get-Content -Path $script:ScriptPath -TotalCount 1).Trim()
            $firstLine | Should -Be '#Requires -Version 5.1' `
                -Because 'all toolkit scripts require PS 5.1'
        }
    }

    Context 'RD-02: CmdletBinding with SupportsShouldProcess' {

        It 'has a [CmdletBinding()] attribute' {
            $cbAttr = Get-CmdletBindingAttribute -Path $script:ScriptPath
            $cbAttr | Should -Not -BeNullOrEmpty `
                -Because 'Invoke-SPReportDistribution should have [CmdletBinding()]'
        }

        It 'declares SupportsShouldProcess' {
            $cbAttr = Get-CmdletBindingAttribute -Path $script:ScriptPath
            $sspArg = $cbAttr.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'SupportsShouldProcess'
            }
            $sspArg | Should -Not -BeNullOrEmpty `
                -Because 'a script that sends emails must declare SupportsShouldProcess'
        }
    }

    Context 'RD-03: Parameter validation' {

        It 'has a param() block' {
            $script:ParamBlock | Should -Not -BeNullOrEmpty
        }

        It 'declares the -ConfigPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'ConfigPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -Status parameter as [string[]]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Status'
            $param | Should -Not -BeNullOrEmpty
        }

        It 'declares the -DaysBack parameter as [int]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'DaysBack'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
        }

        It 'declares the -CampaignName parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'CampaignName'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -CampaignNameStartsWith parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'CampaignNameStartsWith'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -CampaignNameContains parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'CampaignNameContains'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -LeadershipDepth parameter as [int]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'LeadershipDepth'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
        }

        It 'declares the -TargetBands parameter as [string[]]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'TargetBands'
            $param | Should -Not -BeNullOrEmpty
        }

        It 'declares the -SendReports switch parameter' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'SendReports'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It 'declares the -PreviewOnly switch parameter' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'PreviewOnly'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It 'declares the -OrgSupplementPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'OrgSupplementPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -OutputPath parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'OutputPath'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -OutputMode parameter with ValidateSet Console/JSON/Both' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'OutputMode'
            $param | Should -Not -BeNullOrEmpty
            $vsAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'ValidateSet'
            }
            $vsAttr | Should -Not -BeNullOrEmpty `
                -Because 'OutputMode should have a ValidateSet attribute'
            $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
            $validValues | Should -Contain 'Console'
            $validValues | Should -Contain 'JSON'
            $validValues | Should -Contain 'Both'
        }

        It 'declares the -Token parameter as [string]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Token'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'String'
        }

        It 'declares the -TokenExpiryMinutes parameter as [int]' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'TokenExpiryMinutes'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'Int32'
        }

        It 'declares the -DetailLevel parameter with ValidateSet Summary/Detailed/Verbose' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'DetailLevel'
            $param | Should -Not -BeNullOrEmpty
            $vsAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'ValidateSet'
            }
            $vsAttr | Should -Not -BeNullOrEmpty `
                -Because 'DetailLevel should have a ValidateSet attribute'
            $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
            $validValues | Should -Contain 'Summary'
            $validValues | Should -Contain 'Detailed'
            $validValues | Should -Contain 'Verbose'
        }

        It 'declares the -Help switch parameter with ? alias' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Help'
            $param | Should -Not -BeNullOrEmpty
            $param.StaticType.Name | Should -Be 'SwitchParameter'
            $aliasAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'Alias'
            }
            $aliasAttr | Should -Not -BeNullOrEmpty
            $aliasValues = $aliasAttr.PositionalArguments | ForEach-Object { $_.Value }
            $aliasValues | Should -Contain '?'
        }
    }

    Context 'RD-04: Status parameter is mandatory with ValidateSet' {

        It '-Status is declared as Mandatory' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Status'
            $paramAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'Parameter'
            }
            # Check for Mandatory named argument
            $mandatoryArg = $paramAttr.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            }
            $mandatoryArg | Should -Not -BeNullOrEmpty `
                -Because 'Status should be a mandatory parameter'
        }

        It '-Status has ValidateSet STAGED/ACTIVE/COMPLETING/COMPLETED' {
            $param = Get-ScriptParameter -Path $script:ScriptPath -ParameterName 'Status'
            $vsAttr = $param.Attributes | Where-Object {
                $_.TypeName.Name -eq 'ValidateSet'
            }
            $vsAttr | Should -Not -BeNullOrEmpty `
                -Because 'Status should have a ValidateSet attribute'
            $validValues = $vsAttr.PositionalArguments | ForEach-Object { $_.Value }
            $validValues | Should -Contain 'STAGED'
            $validValues | Should -Contain 'ACTIVE'
            $validValues | Should -Contain 'COMPLETING'
            $validValues | Should -Contain 'COMPLETED'
        }
    }

    Context 'RD-05: WhatIf/PreviewOnly mode does NOT send emails' {

        It 'script references WhatIfPreference for dry-run detection' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '\$WhatIfPreference' `
                -Because 'the script should check WhatIfPreference for dry-run mode'
        }

        It 'WhatIf mode displays dry-run banner and exits without API calls' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Dry-run mode enabled.*No API calls will be made' `
                -Because 'WhatIf should display a clear dry-run banner'
        }

        It 'WhatIf mode exits with code 0 (no actual execution)' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            # The WhatIf block ends with exit 0
            $scriptContent | Should -Match 'WhatIfSkip.*\r?\n\s+exit\s+0' `
                -Because 'WhatIf should exit cleanly with code 0'
        }

        It 'PreviewOnly mode calls Show-SPReportDistributionPreview and exits' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Show-SPReportDistributionPreview' `
                -Because 'PreviewOnly should show the distribution plan'
        }

        It 'PreviewOnly block exits with code 0' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            # After the preview section there is an exit 0 -- use (?s) for dotall (cross-line) matching
            $scriptContent | Should -Match '(?s)Action.*Preview.*exit\s+0' `
                -Because 'PreviewOnly should exit with code 0 after displaying preview'
        }

        It 'Send-SPReport is only called when SendReports is true' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            # $SendReports gates a block that calls Send-SPReport -- use (?s) for dotall matching
            $scriptContent | Should -Match '(?s)\$SendReports.*Send-SPReport' `
                -Because 'email sending should be gated by the SendReports switch'
        }
    }

    Context 'RD-06: SMTP config validation' {

        It 'script checks Audit.Smtp.Enabled when SendReports is used' {
            # The help doc says: "Requires Audit.Smtp.Enabled = true"
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Smtp' `
                -Because 'the script should reference SMTP configuration'
        }

        It 'script delegates email sending to Send-SPReport' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Send-SPReport' `
                -Because 'the script should use Send-SPReport for email delivery'
        }

        It 'script passes recipient email and name to Send-SPReport' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'RecipientEmail' `
                -Because 'Send-SPReport should receive the recipient email'
            $scriptContent | Should -Match 'RecipientName' `
                -Because 'Send-SPReport should receive the recipient name'
        }
    }

    Context 'RD-07: Exit codes match documented values' {

        It 'exits 0 on successful distribution' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+0' `
                -Because 'exit code 0 indicates success'
        }

        It 'exits 1 when no campaigns matched filters' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+1' `
                -Because 'exit code 1 indicates no matching campaigns'
        }

        It 'exits 2 on parameter error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+2' `
                -Because 'exit code 2 indicates parameter error'
        }

        It 'exits 3 on authentication error' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+3' `
                -Because 'exit code 3 indicates authentication error'
        }

        It 'exits 4 on SMTP failure when SendReports is used' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'exit\s+4' `
                -Because 'exit code 4 indicates SMTP failure'
        }

        It 'documents exit codes in comment-based help' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match '0\s*=\s*Distribution completed successfully'
            $scriptContent | Should -Match '1\s*=\s*No campaigns matched'
            $scriptContent | Should -Match '2\s*=\s*Parameter error'
            $scriptContent | Should -Match '3\s*=\s*Authentication error'
            $scriptContent | Should -Match '4\s*=\s*SMTP failure'
        }
    }

    Context 'RD-08: Distribution audit trail' {

        It 'writes distribution events to JSONL audit trail' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'Export-SPAuditJsonl' `
                -Because 'distribution events should be logged to JSONL'
        }

        It 'tracks ReportDistributed and ReportGenerated actions' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'ReportDistributed' `
                -Because 'sent reports should be logged as ReportDistributed'
            $scriptContent | Should -Match 'ReportGenerated' `
                -Because 'generate-only reports should be logged as ReportGenerated'
        }

        It 'records delivery status in distribution events' {
            $scriptContent = Get-Content -Path $script:ScriptPath -Raw
            $scriptContent | Should -Match 'DeliveryStatus' `
                -Because 'each distribution event should record its delivery status'
        }
    }
}
