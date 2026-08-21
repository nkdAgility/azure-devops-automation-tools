#Requires -Modules Pester

# Covers the Azure DevOps -> GitHub migration surface against stubbed transports:
# the name slug, the GitHub invoker's paging and 404 contract, the inventory CSV's
# merge semantics, the GitHubRepos scaffolding type, and the engine's shape. As with
# WorkItemLink.Tests.ps1, stubs are defined with the script: scope modifier inside
# & $module { } so they land in the module's own scope. Each Describe force-reimports
# the module first, so one Describe's stubs never leak into the next.

BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\NKDAgility.AzureDevOps.AutomationTools.psd1'
}

Describe 'ConvertTo-GitHubRepoName' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools
    }

    It 'replaces runs of disallowed characters with a single hyphen' {
        & $script:Module { ConvertTo-GitHubRepoName -Name 'My Payments Repo' } | Should -BeExactly 'My-Payments-Repo'
        & $script:Module { ConvertTo-GitHubRepoName -Name 'a  +  b' } | Should -BeExactly 'a-b'
    }

    It 'keeps allowed characters and case' {
        & $script:Module { ConvertTo-GitHubRepoName -Name 'GF.MS.Milling_RTPM-Analytics' } | Should -BeExactly 'GF.MS.Milling_RTPM-Analytics'
    }

    It 'trims leading and trailing hyphens' {
        & $script:Module { ConvertTo-GitHubRepoName -Name ' (deprecated) old ' } | Should -BeExactly 'deprecated-old'
    }

    It 'throws when nothing valid remains' {
        { & $script:Module { ConvertTo-GitHubRepoName -Name '???' } } | Should -Throw '*cannot be converted*'
    }
}

Describe 'Get-AzureDevOpsAccessToken' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools
        # Stub the private Entra acquisition so the public wrapper is exercised
        # without Az.Accounts or a sign-in.
        & $script:Module {
            function script:Get-EntraAccessToken {
                param([string]$Collection, [switch]$Force)
                "entra-token-for-$Collection"
            }
        }
    }

    It 'returns the Entra token for the collection' {
        Get-AzureDevOpsAccessToken -Collection 'https://compucal.visualstudio.com' |
            Should -BeExactly 'entra-token-for-https://compucal.visualstudio.com'
    }
}

Describe 'Get-GitHubAccessToken' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools

        # A gh stub in module scope shadows any real gh on PATH for calls made from
        # inside the module, making the CLI leg deterministic on any machine.
        & $script:Module {
            $script:GhCliToken = $null
            function script:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$CliArgs)
                if ($script:GhCliToken) {
                    $global:LASTEXITCODE = 0
                    return $script:GhCliToken
                }
                $global:LASTEXITCODE = 1
            }
        }
        $script:SavedGitHubToken = $env:GITHUB_TOKEN
    }

    AfterAll {
        $env:GITHUB_TOKEN = $script:SavedGitHubToken
    }

    It 'prefers the signed-in gh CLI over GITHUB_TOKEN' {
        & $script:Module { $script:GhCliToken = 'gh-cli-token' }
        $env:GITHUB_TOKEN = 'env-token'
        Get-GitHubAccessToken | Should -BeExactly 'gh-cli-token'
    }

    It 'falls back to GITHUB_TOKEN when gh is signed out' {
        & $script:Module { $script:GhCliToken = $null }
        $env:GITHUB_TOKEN = 'env-token'
        Get-GitHubAccessToken | Should -BeExactly 'env-token'
    }

    It 'throws with guidance when neither is available' {
        & $script:Module { $script:GhCliToken = $null }
        $env:GITHUB_TOKEN = ''
        { Get-GitHubAccessToken } | Should -Throw '*No usable GitHub credential*'
    }

    It 'skips a candidate the org rejects (expired SAML session) and uses the next' {
        # The gh token exists but answers 403 SAML-enforcement for the org; the
        # SSO-authorised PAT in GITHUB_TOKEN must win instead of the run failing.
        & $script:Module {
            $script:GhCliToken = 'saml-dead-gh-token'
            function script:Invoke-GitHubApi {
                param($Path, $Method = 'Get', $Query, $Body, $Token, [switch]$AllPages, [switch]$AllowNotFound)
                if ($Token -eq 'saml-dead-gh-token') {
                    throw "GitHub REST call failed: Get https://api.github.com/orgs/x`nResource protected by organization SAML enforcement."
                }
            }
        }
        $env:GITHUB_TOKEN = 'sso-authorised-pat'
        Get-GitHubAccessToken -Org 'x' -WarningAction SilentlyContinue | Should -BeExactly 'sso-authorised-pat'
    }

    It 'throws SSO guidance when every candidate is rejected by the org' {
        & $script:Module { $script:GhCliToken = 'saml-dead-gh-token' }
        $env:GITHUB_TOKEN = 'saml-dead-gh-token'
        { Get-GitHubAccessToken -Org 'x' -WarningAction SilentlyContinue } | Should -Throw '*Configure SSO*'
    }
}

Describe 'Invoke-GitHubApi' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools

        # Ambient resolution stub, so the tokenless path needs no gh CLI or env var.
        & $script:Module {
            function script:Get-GitHubAccessToken { 'ambient-token' }
        }

        # Stub Invoke-RestMethod inside the module so the invoker's own paging, 404
        # and error-surfacing logic runs for real without any network. The stub honours
        # -ResponseHeadersVariable by setting the named variable in its caller's scope,
        # exactly as the real cmdlet does.
        & $script:Module {
            $script:GhPages = @{
                'https://api.github.com/orgs/x/repos?per_page=100'        = @{
                    Body = @([pscustomobject]@{ name = 'repo-one' })
                    Link = '<https://api.github.com/orgs/x/repos?per_page=100&page=2>; rel="next", <https://api.github.com/orgs/x/repos?per_page=100&page=2>; rel="last"'
                }
                'https://api.github.com/orgs/x/repos?per_page=100&page=2' = @{
                    Body = @([pscustomobject]@{ name = 'repo-two' })
                    Link = $null
                }
                'https://api.github.com/repos/x/present'                  = @{
                    Body = [pscustomobject]@{ name = 'present'; default_branch = 'main' }
                    Link = $null
                }
            }
            function script:Invoke-RestMethod {
                param($Uri, $Method, $Headers, $ContentType, $Body, $ErrorAction, [string]$ResponseHeadersVariable)

                $script:LastAuthHeader = $Headers.Authorization

                if ($Uri -like '*/repos/x/missing') {
                    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                        'Response status code does not indicate success: 404 (Not Found).', $response)
                }

                $page = $script:GhPages[$Uri]
                if (-not $page) { throw "unexpected uri: $Uri" }
                if ($ResponseHeadersVariable) {
                    $headerDict = @{}
                    if ($page.Link) { $headerDict['Link'] = @($page.Link) }
                    Set-Variable -Name $ResponseHeadersVariable -Value $headerDict -Scope 1
                }
                $page.Body
            }
        }
    }

    It 'follows Link rel="next" pagination with -AllPages' {
        $repos = @(& $script:Module { Invoke-GitHubApi -Path 'orgs/x/repos' -Token 't' -AllPages })
        $repos.Count | Should -Be 2
        $repos.name | Should -Contain 'repo-one'
        $repos.name | Should -Contain 'repo-two'
    }

    It 'returns the raw response for a single call' {
        $repo = & $script:Module { Invoke-GitHubApi -Path 'repos/x/present' -Token 't' }
        $repo.default_branch | Should -BeExactly 'main'
    }

    It 'returns $null on 404 with -AllowNotFound' {
        & $script:Module { Invoke-GitHubApi -Path 'repos/x/missing' -Token 't' -AllowNotFound } | Should -BeNullOrEmpty
    }

    It 'throws on 404 without -AllowNotFound' {
        { & $script:Module { Invoke-GitHubApi -Path 'repos/x/missing' -Token 't' } } | Should -Throw 'GitHub REST call failed*'
    }

    It 'resolves the token ambiently when none is supplied' {
        & $script:Module { Invoke-GitHubApi -Path 'repos/x/present' } | Out-Null
        & $script:Module { $script:LastAuthHeader } | Should -BeExactly 'Bearer ambient-token'
    }
}

Describe 'Invoke-AzureDevOpsApi Entra-to-PAT fallback' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools

        # An org that is not Entra-backed: acquisition throws, and the invoker must
        # fall back to a PAT resolved for the collection instead of surfacing it.
        & $script:Module {
            function script:Get-EntraAccessToken {
                param([string]$Collection, [switch]$Force)
                throw "'$Collection' is not Entra-backed"
            }
            function script:Invoke-RestMethod {
                param($Uri, $Method, $Headers, $ContentType, $Body, $ErrorAction, [string]$ResponseHeadersVariable)
                $script:LastAdoAuthHeader = $Headers.Authorization
                [pscustomobject]@{ value = @() }
            }
        }
        $script:SavedContosoPat = $env:AZDO_PAT_CONTOSO
    }

    AfterAll {
        $env:AZDO_PAT_CONTOSO = $script:SavedContosoPat
    }

    It 'falls back to the derived AZDO_PAT_<ORG> variable for a visualstudio.com org' {
        $env:AZDO_PAT_CONTOSO = 'fallback-pat'
        $expected = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(':fallback-pat'))

        Get-TeamProject -Collection 'https://contoso.visualstudio.com' -WarningAction SilentlyContinue | Out-Null
        & $script:Module { $script:LastAdoAuthHeader } | Should -BeExactly $expected
    }

    It 'still throws when no PAT can be resolved either' {
        $env:AZDO_PAT_CONTOSO = ''
        # A different collection so neither the PAT cache nor the warn-once cache hides the failure.
        { Get-TeamProject -Collection 'https://nowhere.visualstudio.com' } | Should -Throw '*not Entra-backed*'
    }
}

Describe 'Export-GitRepoInventory' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
        $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools

        # Stub both private invokers. The Azure DevOps stub serves projects (as the
        # aggregated array -FollowContinuation produces) and per-project repo lists
        # from mutable script-scope test data, so each test can shape the source.
        & $script:Module {
            $script:TestProjects = @()
            $script:TestRepos = @{}
            $script:GhOrgRepos = @()

            function script:Invoke-AzureDevOpsApi {
                param($Collection, $Path, $Method = 'Get', $ApiVersion, $Query, $Body, $Pat,
                    [switch]$UseDefaultCredentials, [switch]$FollowContinuation)

                if ($Path -eq '_apis/projects') { return $script:TestProjects }
                if ($Path -match '^(?<proj>[^/]+)/_apis/git/repositories$') {
                    $project = [uri]::UnescapeDataString($Matches['proj'])
                    return [pscustomobject]@{ value = @($script:TestRepos[$project]) }
                }
                throw "unexpected path: $Path"
            }

            function script:Invoke-GitHubApi {
                param($Path, $Method = 'Get', $Query, $Body, $Token, [switch]$AllPages, [switch]$AllowNotFound)
                if ($Path -match '^orgs/.+/repos$') { return @($script:GhOrgRepos) }
                throw "unexpected path: $Path"
            }
        }

        $script:SetSource = {
            param($Projects, $Repos, $GhRepos)
            & $script:Module {
                param($p, $r, $g)
                $script:TestProjects = $p
                $script:TestRepos = $r
                $script:GhOrgRepos = $g
            } $Projects $Repos $GhRepos
        }

        $script:NewRepo = {
            param($Id, $Name, [switch]$Disabled)
            [pscustomobject]@{
                id            = $Id
                name          = $Name
                size          = 5MB
                defaultBranch = 'refs/heads/main'
                webUrl        = "https://src/$Name"
                isDisabled    = [bool]$Disabled
            }
        }
    }

    BeforeEach {
        $script:CsvPath = Join-Path $TestDrive ("inventory-{0}.csv" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        & $script:SetSource `
            @([pscustomobject]@{ name = 'Alpha'; id = 'p1' }, [pscustomobject]@{ name = 'Beta'; id = 'p2' }) `
            @{
                Alpha = @((& $script:NewRepo '1' 'Payments'), (& $script:NewRepo '2' 'Shared Lib'))
                Beta  = @((& $script:NewRepo '3' 'Payments'))
            } `
            @()
    }

    It 'creates rows for every repo with slugified, collision-free TargetNames' {
        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' -PassThru)

        $rows.Count | Should -Be 3
        ($rows | Where-Object SourceRepoId -EQ '1').TargetName | Should -BeExactly 'Payments'
        ($rows | Where-Object SourceRepoId -EQ '2').TargetName | Should -BeExactly 'Shared-Lib'
        # Same repo name in a second project: project-prefixed slug.
        ($rows | Where-Object SourceRepoId -EQ '3').TargetName | Should -BeExactly 'Beta-Payments'
        ($rows | Where-Object SourceRepoId -EQ '1').Approved | Should -BeNullOrEmpty

        $csv = @(Import-Csv -LiteralPath $script:CsvPath)
        $csv.Count | Should -Be 3
        @($csv[0].PSObject.Properties.Name) | Should -Contain 'Notes'
    }

    It 'preserves customer edits and refreshes facts on re-export' {
        Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' | Out-Null

        # Customer approves one repo, renames its target and leaves a note.
        $edited = @(Import-Csv -LiteralPath $script:CsvPath)
        foreach ($row in $edited) {
            if ($row.SourceRepoId -eq '1') {
                $row.Approved = 'yes'
                $row.TargetName = 'payments-service'
                $row.Notes = 'rename per customer'
            }
        }
        $edited | Export-Csv -LiteralPath $script:CsvPath -NoTypeInformation -Encoding UTF8

        # The repo grows on the source before the next refresh.
        & $script:Module { $script:TestRepos['Alpha'][0].size = 10MB }

        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' -PassThru)
        $row = $rows | Where-Object SourceRepoId -EQ '1'
        $row.Approved | Should -BeExactly 'yes'
        $row.TargetName | Should -BeExactly 'payments-service'
        $row.Notes | Should -BeExactly 'rename per customer'
        [double]$row.SizeMB | Should -Be 10
    }

    It 'keeps vanished repos as MissingFromSource instead of deleting them' {
        Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' | Out-Null

        & $script:Module { $script:TestRepos['Beta'] = @() }

        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' -PassThru)
        $rows.Count | Should -Be 3
        ($rows | Where-Object SourceRepoId -EQ '3').Status | Should -BeExactly 'MissingFromSource'
        ($rows | Where-Object SourceRepoId -EQ '1').Status | Should -BeExactly 'Active'
    }

    It 'avoids TargetNames already taken in the GitHub org' {
        & $script:Module { $script:GhOrgRepos = @([pscustomobject]@{ name = 'Payments' }) }

        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' `
                -GitHubOrg 'x' -GitHubToken 't' -PassThru)
        # 'Payments' is taken on GitHub, so the first claimant is prefixed too.
        ($rows | Where-Object SourceRepoId -EQ '1').TargetName | Should -BeExactly 'Alpha-Payments'
        ($rows | Where-Object SourceRepoId -EQ '3').TargetName | Should -BeExactly 'Beta-Payments'
    }

    It 'only adds disabled repos as new rows with -IncludeDisabled' {
        & $script:Module {
            $script:TestRepos['Alpha'] = @($script:TestRepos['Alpha']) + @(
                [pscustomobject]@{ id = '9'; name = 'Old'; size = 0; defaultBranch = ''; webUrl = ''; isDisabled = $true })
        }

        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' -PassThru)
        @($rows | Where-Object SourceRepoId -EQ '9').Count | Should -Be 0

        $rows = @(Export-GitRepoInventory -Collection 'https://src.example' -Path $script:CsvPath -Pat 'p' -IncludeDisabled -PassThru)
        ($rows | Where-Object SourceRepoId -EQ '9').Status | Should -BeExactly 'Disabled'
    }
}

Describe 'New-Migration -Type GitHubRepos' {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
    }

    It 'scaffolds the github-repos template with provenance' {
        $workspace = Join-Path $TestDrive 'workspace'
        New-Item -Path $workspace -ItemType Directory -Force | Out-Null

        New-Migration -Name 'GitHubContract' -Type GitHubRepos -Path $workspace | Out-Null

        $folder = Join-Path $workspace 'migrations\01-GitHubContract'
        Join-Path $folder 'github-repos-config.json' | Should -Exist
        Join-Path $folder 'Run-Export-RepoInventory.ps1' | Should -Exist
        Join-Path $folder 'Run-Migrate-ReposToGitHub.ps1' | Should -Exist
        Join-Path $folder 'Sync.ps1' | Should -Exist
        Join-Path $folder 'notes.md' | Should -Exist

        $stamp = Get-Content (Join-Path $folder '.template.json') -Raw | ConvertFrom-Json
        $stamp.type | Should -BeExactly 'GitHubRepos'
        $stamp.template | Should -BeExactly 'github-repos'
    }
}

Describe 'Migrate-ReposToGitHub engine shape' {

    BeforeAll {
        $script:EnginePath = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines\Migrate-ReposToGitHub.ps1'
        $script:EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($script:EnginePath, [ref]$null, [ref]$null)
    }

    It 'supports -WhatIf' {
        $cmdletBinding = $script:EngineAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.FullName -match 'CmdletBinding' }
        $supports = $cmdletBinding.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }
        $supports | Should -Not -BeNullOrEmpty -Because 'anything that writes to a GitHub org must be previewable'
        $supports.Argument.Extent.Text | Should -BeExactly '$true'
    }

    It 'keeps the LFS oversize rewrite strictly opt-in' {
        # A history rewrite is a customer decision; the switch must exist and default off.
        $parameter = $script:EngineAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'LfsMigrateOversize' }
        $parameter | Should -Not -BeNullOrEmpty
        $parameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
    }

    It 'does not require tokens - ambient identity is the default' {
        foreach ($name in 'SourcePat', 'GitHubToken') {
            $parameter = $script:EngineAst.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter | Should -Not -BeNullOrEmpty
            $mandatory = $parameter.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.FullName -match 'Parameter' -and
                ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and $_.Argument.Extent.Text -eq '$true' })
            }
            $mandatory | Should -BeNullOrEmpty -Because "$name is the fallback behind Entra / the gh CLI, not a requirement"
        }
    }

    It 'defaults MaxPushSizeGB to the GitHub 2 GB push limit' {
        # The 2 GB limit is exactly the kind of constant that silently regresses when
        # someone copies from Migrate-Repos.ps1, whose Azure DevOps limit is 5.
        $parameter = $script:EngineAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'MaxPushSizeGB' }
        $parameter | Should -Not -BeNullOrEmpty
        $parameter.DefaultValue.Extent.Text | Should -BeExactly '2'
    }

    It 'never pushes with --mirror' {
        # A mirror push would include server-managed refs (refs/pull/*), which GitHub
        # rejects. The explicit heads/tags refspecs are the contract.
        $text = Get-Content $script:EnginePath -Raw
        $text | Should -Not -Match "push',\s*'--mirror"
    }
}
