#Requires -Modules Pester

# Covers Migrate-Repos.ps1's decision-making against REAL git repositories built in
# temp folders. The engine is a script with a main region, so it cannot be dot-sourced
# without running a migration: the functions under test are lifted out by AST and
# evaluated on their own.
#
# Real repositories rather than stubs because every bug these tests exist to prevent
# was about what git actually reports - which refs carry .gitattributes, at what path,
# in which commit - and a stub would have happily agreed with the wrong answer.

BeforeAll {
    $script:EnginePath = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines\Migrate-Repos.ps1'
    $script:EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($script:EnginePath, [ref]$null, [ref]$null)

    # Returns the SOURCE rather than defining anything: dot-sourcing inside a function
    # would define the engine function in that function's scope, where no It block
    # could see it. The caller dot-sources into its own scope instead.
    function script:Get-EngineFunctionSource {
        param([string[]]$Name)
        $source = $script:EngineAst.FindAll({
                param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object { $_.Name -in $Name } | ForEach-Object { $_.Extent.Text }
        if (@($source).Count -ne @($Name).Count) {
            throw "Expected $(@($Name).Count) function(s) [$($Name -join ', ')] in the engine, found $(@($source).Count)."
        }
        return ($source -join "`n")
    }

    function script:New-TestRepo {
        # A real repository. Returns its path. Commits are made with explicit identity
        # so the test does not depend on the machine's git config.
        param([scriptblock]$Build)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("lfsdetect-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Push-Location $dir
        try {
            & git init --quiet --initial-branch=main 2>$null
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            & git config commit.gpgsign false
            & $Build
        }
        finally { Pop-Location }
        return $dir
    }

    function script:Add-Commit {
        param([string]$Path, [string]$Content, [string]$Message)
        $full = Join-Path (Get-Location) $Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -LiteralPath $full -Value $Content -Encoding UTF8
        & git add -A 2>$null
        & git commit --quiet -m $Message 2>$null
    }
}

Describe 'Test-RepoUsesLfs' {

    BeforeAll {
        . ([scriptblock]::Create((Get-EngineFunctionSource -Name 'Test-RepoUsesLfs')))
        $script:Made = [System.Collections.Generic.List[string]]::new()
    }

    AfterAll {
        foreach ($d in $script:Made) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is false for a repository with no .gitattributes at all' {
        $repo = New-TestRepo { Add-Commit -Path 'readme.md' -Content 'hello' -Message 'init' }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeFalse
    }

    It 'is false when .gitattributes exists but declares no lfs filter' {
        # The QATools case: 677 refs carried a .gitattributes, none of them LFS.
        $repo = New-TestRepo {
            Add-Commit -Path 'readme.md' -Content 'hello' -Message 'init'
            Add-Commit -Path '.gitattributes' -Content "* text=auto`n*.sln merge=union" -Message 'attrs'
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeFalse
    }

    It 'is true when the root .gitattributes declares an lfs filter' {
        $repo = New-TestRepo {
            Add-Commit -Path '.gitattributes' -Content "*.bin filter=lfs diff=lfs merge=lfs -text" -Message 'lfs'
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeTrue
    }

    It 'is true when only a NESTED .gitattributes declares lfs' {
        # Checking just the repository root would miss this and skip the transfer,
        # shipping pointers with no content behind them.
        $repo = New-TestRepo {
            Add-Commit -Path 'readme.md' -Content 'hello' -Message 'init'
            Add-Commit -Path 'assets/textures/.gitattributes' -Content "*.png filter=lfs diff=lfs merge=lfs -text" -Message 'nested lfs'
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeTrue
    }

    It 'is true when lfs was declared in history but removed from the tip' {
        # Old commits still hold pointers, so their objects still have to travel.
        $repo = New-TestRepo {
            Add-Commit -Path '.gitattributes' -Content "*.bin filter=lfs diff=lfs merge=lfs -text" -Message 'lfs'
            Remove-Item '.gitattributes' -Force
            & git add -A 2>$null
            & git commit --quiet -m 'drop attrs' 2>$null
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeTrue
    }

    It 'is true when lfs is declared only on a NON-default branch' {
        # A mirror carries every branch, so every branch's objects get pushed.
        $repo = New-TestRepo {
            Add-Commit -Path 'readme.md' -Content 'hello' -Message 'init'
            & git checkout --quiet -b feature 2>$null
            Add-Commit -Path '.gitattributes' -Content "*.psd filter=lfs diff=lfs merge=lfs -text" -Message 'lfs on branch'
            & git checkout --quiet main 2>$null
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeTrue
    }

    It 'tolerates whitespace around the filter declaration' {
        $repo = New-TestRepo {
            Add-Commit -Path '.gitattributes' -Content "*.bin filter = lfs diff=lfs -text" -Message 'spaced'
        }
        $script:Made.Add($repo)
        Test-RepoUsesLfs -CloneDir $repo | Should -BeTrue
    }

    It 'fails SAFE - an unreadable repository is assumed to use lfs' {
        # Skipping the transfer on uncertainty would silently produce a repository
        # whose LFS pointers resolve to nothing. Slow beats wrong.
        Test-RepoUsesLfs -CloneDir (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-repo-xyz123') |
            Should -BeTrue
    }
}

Describe 'Push-Lfs gating' {

    BeforeAll {
        $script:Text = Get-Content $script:EnginePath -Raw
    }

    It 'decides whether LFS is in use before any per-ref work' {
        # Ordering is the whole point: Test-RepoUsesLfs must run before the dry-run
        # pre-check, because both the pre-check and the push are per-ref walks.
        $detectAt = $script:Text.IndexOf('Test-RepoUsesLfs -CloneDir $CloneDir')
        $pendingAt = $script:Text.IndexOf('Get-PendingLfsCount -CloneDir $CloneDir')
        $detectAt | Should -BeGreaterThan 0
        $detectAt | Should -BeLessThan $pendingAt
    }

    It 'still honours -SkipLfs and a missing git-lfs' {
        $script:Text | Should -Match '\$SkipLfs -or -not \(Test-GitLfs\)'
    }
}

Describe 'Migrate-Repos engine shape' {

    BeforeAll {
        $script:Text = Get-Content $script:EnginePath -Raw
    }

    It 'supports -WhatIf' {
        $cmdletBinding = $script:EngineAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.FullName -match 'CmdletBinding' }
        ($cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) |
            Should -Not -BeNullOrEmpty -Because 'anything that writes to an organisation must be previewable'
    }

    It 'renames in transit only alongside a named repository' {
        # -TargetRepoName across a whole-project run has no defensible repository to
        # apply the new name to.
        $parameter = $script:EngineAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetRepoName' }
        $parameter | Should -Not -BeNullOrEmpty
        $script:Text | Should -Match '\$TargetRepoName -and -not \$RepoName'
    }

    It 'creates and pushes under the target name, but caches the mirror under the source name' {
        # A rename must not orphan the cached mirror - re-cloning a large repository
        # is hours of transfer.
        $script:Text | Should -Match 'New-TargetRepo -Name \$targetName'
        $script:Text | Should -Match 'Get-TargetRepoUrl -Name \$targetName'
        $script:Text | Should -Match 'Join-Path \$WorkRoot \(\$Repo\.name \+ ''\.git''\)'
    }

    It 'never pushes with --mirror' {
        # A mirror push carries server-managed refs (refs/pull/*), which the target rejects.
        $script:Text | Should -Not -Match "push',\s*'--mirror"
    }
}
