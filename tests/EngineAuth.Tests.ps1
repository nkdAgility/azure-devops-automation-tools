# Structural guards for the authentication contract: every engine that talks to an
# Azure DevOps organisation delegates credential resolution to the module's
# Resolve-AzureDevOpsAuth, so all of them answer "which credential here" identically
# and cannot drift. The resolver's precedence - pinned by its own Describe below - is:
#
#   1. a supplied PAT              an explicit credential is an instruction, not a
#                                  fallback; nobody should be asked to sign in as
#                                  somebody else when they already named an identity
#   2. Windows integrated          when the host is not dev.azure.com /
#                                  *.visualstudio.com - on-premises means send NO
#                                  credential and let the stack negotiate; Entra
#                                  cannot succeed there and only pops a prompt
#   3. Entra                       the hosted service, when nothing was supplied
#
# Ambient identity is still the default whenever no PAT is given (2 and 3 are both
# ambient); PAT parameters stay optional; engines re-resolve per repo / feed /
# work-item batch so the module's token cache can renew near expiry. The binder
# templates expand $ENV:AZDO_PAT_* placeholders leniently, so an unset variable
# omits the PAT instead of failing the run. Everything here is an AST/text check -
# no network, no PATs.

# One contract row per engine:
#   PatParams      - PAT parameters that must exist and must NOT be mandatory.
#   EntraFunctions - local auth function(s) that must delegate to the module's
#                    Resolve-AzureDevOpsAuth rather than resolve Entra themselves.
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
    @{ Engine = 'Remove-CommitMentionLinks.ps1'
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

    It 'delegates credential resolution to the shared Resolve-AzureDevOpsAuth' {
        foreach ($fn in $EntraFunctions) {
            $definition = $script:EngineAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fn
                }, $true)
            $definition | Should -Not -BeNullOrEmpty -Because "the engine must resolve credentials through $fn"

            $text = $definition.Extent.Text
            $text | Should -Match 'Resolve-AzureDevOpsAuth' -Because 'credential resolution lives in the module so the engines cannot drift'
            $text | Should -Not -Match 'Get-AzureDevOpsAccessToken' -Because 'no engine resolves Entra itself any more - the resolver decides PAT / Windows / Entra by what was supplied and by host'
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

Describe 'Shared credential resolver (Resolve-AzureDevOpsAuth)' {

    BeforeAll {
        $script:ResolverPath = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Public\Common\Resolve-AzureDevOpsAuth.ps1'
        $script:ResolverAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ResolverPath, [ref]$null, [ref]$null)
        $script:ResolverText = Get-Content -LiteralPath $script:ResolverPath -Raw
        # Strip the comment-based help so index comparisons measure CODE order, not
        # the order concepts happen to be explained in.
        $script:ResolverCode = ($script:ResolverText -split '#>', 2)[-1]
    }

    It 'honours a supplied PAT before anything else - an instruction, not a fallback' {
        $script:ResolverCode | Should -Match 'if \(\$Pat\)'
        $script:ResolverCode.IndexOf('if ($Pat)') |
            Should -BeLessThan $script:ResolverCode.IndexOf('Test-AzureDevOpsHosted') -Because 'a named credential must win before the host is even considered'
    }

    It 'decides Windows integrated auth by host, before ever trying Entra' {
        # The host rule itself lives in Test-AzureDevOpsHosted - the one place it is
        # written down - and the resolver consults it before Entra.
        $predicateText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Public\Common\Test-AzureDevOpsHosted.ps1') -Raw
        $predicateText | Should -Match 'dev\.azure\.com'
        $predicateText | Should -Match 'visualstudio\.com'
        $script:ResolverCode | Should -Match 'Test-AzureDevOpsHosted'
        $script:ResolverCode.IndexOf('Test-AzureDevOpsHosted') |
            Should -BeLessThan $script:ResolverCode.IndexOf('Get-AzureDevOpsAccessToken') -Because 'Entra cannot succeed against an on-premises host, so trying it first only produces a sign-in prompt'
    }

    It 'expresses Windows auth as the absence of a credential' {
        # Empty Headers is the caller signal for -UseDefaultCredentials; empty GitHeader
        # makes Get-AzureDevOpsGitAuthArgs emit no http.extraheader option at all.
        $windows = [regex]::Match($script:ResolverCode, "(?s)Mode\s*=\s*'Windows'.*?Token\s*=\s*''")
        $windows.Success | Should -BeTrue
        $windows.Value | Should -Match 'Headers\s*=\s*@\{\}'
        $windows.Value | Should -Match "GitHeader\s*=\s*''"
        $windows.Value | Should -Match "Token\s*=\s*''"
    }

    It 'throws with guidance when nothing can authenticate' {
        $script:ResolverCode | Should -Match '\bthrow\b'
        $script:ResolverCode | Should -Match 'secrets\\secrets\.json' -Because 'the error must say where the PAT goes, not just that one is missing'
    }
}

Describe 'Engines build URLs from the collection URL, never a hardcoded cloud host' {
    # The organisation URL IS the API base, hosted and on-premises alike. An engine that
    # rebuilds requests as "https://dev.azure.com/$org/..." silently aims an on-premises
    # run at a same-named PUBLIC organisation. The hosted-only subdomains (pkgs., feeds.,
    # vssps.) do not exist on a server at all, so building one of those is only legal
    # inside a branch that has asked Test-AzureDevOpsHosted first.

    BeforeAll {
        $script:EnginesDir = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines'
        # Interpolated cloud-host URL strings, found via the AST so comments and
        # doc examples never trip the guard.
        $script:FindCloudUrlStrings = {
            param($EngineFile)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($EngineFile, [ref]$null, [ref]$null)
            @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                        $node.Extent.Text -match '^"https://(dev|pkgs|feeds|vssps)\.(azure|dev\.azure|visualstudio)'
                    }, $true))
        }
    }

    It 'never interpolates a dev.azure.com / subdomain URL outside a hosted branch (<_>)' -ForEach @(
        'Migrate-Repos.ps1', 'Migrate-Artifacts.ps1', 'Migrate-ReposToGitHub.ps1',
        'Update-WikiWorkItemLinks.ps1', 'Update-CommentAttachmentLinks.ps1',
        'Set-WorkItemStartId.ps1', 'Remove-CommitMentionLinks.ps1'
    ) {
        $file = Join-Path $script:EnginesDir $_
        $offenders = foreach ($str in (& $script:FindCloudUrlStrings $file)) {
            # A cloud-host build is legal only inside a function that branches on
            # Test-AzureDevOpsHosted (the hosted arm of a host-aware URL helper).
            $enclosing = $str.Parent
            while ($enclosing -and $enclosing -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $enclosing = $enclosing.Parent
            }
            if (-not $enclosing -or $enclosing.Extent.Text -notmatch 'Test-AzureDevOpsHosted') {
                "line $($str.Extent.StartLineNumber): $($str.Extent.Text)"
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'a URL rebuilt against a hardcoded cloud host aims an on-premises run at a same-named public organisation'
    }
}

Describe 'Git auth args helper (Get-AzureDevOpsGitAuthArgs)' {

    BeforeAll {
        $script:HelperText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Public\Common\Get-AzureDevOpsGitAuthArgs.ps1') -Raw
    }

    It 'emits no option at all for an empty header - absent, not blank' {
        # 'http.extraheader=' (blank) makes git send an empty Authorization header,
        # which suppresses the negotiation Windows integrated auth depends on.
        $script:HelperText | Should -Match 'if \(\$GitHeader\)'
        $script:HelperText | Should -Match 'return , @\(\)'
    }

    It 'is the only way engines attach the git header' {
        $enginesDir = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines'
        $offenders = Get-ChildItem -Path $enginesDir -Filter '*.ps1' |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'http\.extraheader=\$script:' } |
            ForEach-Object { $_.Name }
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'a site that interpolates the header itself will emit a BLANK header under Windows auth instead of omitting it'
    }
}
