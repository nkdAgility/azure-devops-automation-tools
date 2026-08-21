# Structural guards for the ambient-first authentication contract: every engine
# that talks to an Azure DevOps organisation resolves credentials Entra-first via
# the module's Get-AzureDevOpsAccessToken, keeps its PAT parameters as optional
# fallbacks, and re-resolves per repo / feed / work-item batch so the module's
# token cache can renew near expiry. The binder templates expand $ENV:AZDO_PAT_*
# placeholders leniently, so an unset variable omits the fallback instead of
# failing the run. Everything here is an AST/text check - no network, no PATs.

# One contract row per engine:
#   PatParams      - PAT parameters that must exist and must NOT be mandatory.
#   EntraFunctions - local auth function(s) that must try Get-AzureDevOpsAccessToken
#                    BEFORE falling back to a PAT and must throw when neither works.
#   RenewalCommands- auth entry points that must be invoked more than once (the
#                    initial resolution plus at least one per-item renewal).
$engineContracts = @(
    @{ Engine = 'Migrate-Repos.ps1'
       PatParams = @('SourcePat', 'TargetPat')
       EntraFunctions = @('Initialize-SourceAuth', 'Initialize-TargetAuth')
       RenewalCommands = @('Initialize-SourceAuth', 'Initialize-TargetAuth') }
    @{ Engine = 'Migrate-Artifacts.ps1'
       PatParams = @('SourcePat', 'TargetPat')
       EntraFunctions = @('Initialize-SourceAuth', 'Initialize-TargetAuth')
       RenewalCommands = @('Initialize-SourceAuth', 'Initialize-TargetAuth') }
    @{ Engine = 'Migrate-ReposToGitHub.ps1'
       PatParams = @('SourcePat')
       EntraFunctions = @('Initialize-SourceAuth')
       RenewalCommands = @('Initialize-SourceAuth') }
    @{ Engine = 'Update-WikiWorkItemLinks.ps1'
       PatParams = @('TargetPat')
       EntraFunctions = @('Initialize-TargetAuth')
       RenewalCommands = @('Initialize-TargetAuth') }
    @{ Engine = 'Update-CommentAttachmentLinks.ps1'
       PatParams = @('SourcePat', 'TargetPat')
       EntraFunctions = @('Initialize-AdoAuth')
       RenewalCommands = @('Initialize-SourceAuth', 'Initialize-TargetAuth') }
    @{ Engine = 'Set-WorkItemStartId.ps1'
       PatParams = @('Pat')
       EntraFunctions = @('Initialize-Auth')
       RenewalCommands = @('Initialize-Auth') }
)

Describe 'Engine ambient-first authentication (<Engine>)' -ForEach $engineContracts {

    BeforeAll {
        $script:EnginePath = Join-Path $PSScriptRoot "..\system\NKDAgility.AzureDevOps.AutomationTools\Engines\$Engine"
        $script:EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($script:EnginePath, [ref]$null, [ref]$null)
    }

    It 'keeps every PAT parameter optional - a fallback, not a requirement' {
        foreach ($name in $PatParams) {
            $parameter = $script:EngineAst.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter | Should -Not -BeNullOrEmpty -Because "the $name fallback parameter must still exist"
            $mandatory = $parameter.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.FullName -match 'Parameter' -and
                ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and $_.Argument.Extent.Text -eq '$true' })
            }
            $mandatory | Should -BeNullOrEmpty -Because "$name is the fallback behind Entra, not a requirement"
        }
    }

    It 'tries Entra via Get-AzureDevOpsAccessToken before any PAT fallback' {
        foreach ($fn in $EntraFunctions) {
            $definition = $script:EngineAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fn
                }, $true)
            $definition | Should -Not -BeNullOrEmpty -Because "the engine must resolve credentials through $fn"

            $text = $definition.Extent.Text
            $text | Should -Match 'Get-AzureDevOpsAccessToken' -Because 'Entra comes from the module, not a local sign-in'
            $text | Should -Match 'falling back' -Because 'the PAT fallback must announce itself once'
            $text.IndexOf('Get-AzureDevOpsAccessToken') |
                Should -BeLessThan $text.IndexOf('falling back') -Because 'Entra is tried first; the PAT is only the fallback'
            $text | Should -Match '\bthrow\b' -Because 'no credential at all must fail with guidance, not limp on'
        }
    }

    It 're-resolves credentials during the run so cached Entra tokens can renew' {
        foreach ($command in $RenewalCommands) {
            $calls = @($script:EngineAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq $command
                    }, $true))
            $calls.Count | Should -BeGreaterThan 1 -Because "$command must run at start AND per repo/feed/work-item batch, or a long run outlives its token"
        }
    }
}

# The binders expand $ENV:* placeholders from the per-migration JSON config. PAT
# placeholders must expand leniently: the engines default to ambient identity, so
# an unset AZDO_PAT_* / GITHUB_TOKEN variable means 'no fallback', not an error.
$binderContracts = @(
    @{ Binder = 'migration-tools\Run-Migrate-Repos.ps1';        FallbackParams = @('SourcePat', 'TargetPat') }
    @{ Binder = 'migration-tools\Run-Migrate-Artifacts.ps1';    FallbackParams = @('SourcePat', 'TargetPat') }
    @{ Binder = 'github-repos\Run-Migrate-ReposToGitHub.ps1';   FallbackParams = @('SourcePat', 'GitHubToken') }
)

Describe 'Binder templates treat tokens as optional fallbacks (<Binder>)' -ForEach $binderContracts {

    BeforeAll {
        $script:BinderPath = Join-Path $PSScriptRoot "..\system\NKDAgility.AzureDevOps.AutomationTools\Templates\migrations\$Binder"
        $script:BinderAst = [System.Management.Automation.Language.Parser]::ParseFile($script:BinderPath, [ref]$null, [ref]$null)
        $script:BinderText = Get-Content -LiteralPath $script:BinderPath -Raw
    }

    It 'has a lenient Expand-EnvPlaceholder (-AllowMissing)' {
        $definition = $script:BinderAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Expand-EnvPlaceholder'
            }, $true)
        $definition | Should -Not -BeNullOrEmpty
        $allowMissing = $definition.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowMissing' }
        $allowMissing | Should -Not -BeNullOrEmpty -Because 'an unset fallback-token variable must resolve to $null, not throw'
    }

    It 'lists every token parameter as a fallback and expands with -AllowMissing' {
        foreach ($name in $FallbackParams) {
            $script:BinderText | Should -Match "fallbackTokenParams[^\r\n]*'$name'" -Because "$name must be in the lenient list"
        }
        $script:BinderText | Should -Match 'AllowMissing:\(\$fallbackTokenParams -contains' -Because 'the lenient switch must actually be wired to the expansion call'
    }
}
