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

    It 'pushes only the commits the target lacks' {
        # Segmenting from a branch's first commit rewinds a branch the target already has
        # further along, which git rejects - so a partly migrated repository could never
        # be finished.
        $script:Text | Should -Match 'refs/remotes/\$TargetRemote/\*'
        $script:Text | Should -Match '\$range = if \(\$from\)'
        $script:Text | Should -Match 'already up to date'
    }

    It 'leaves a diverged branch alone unless explicitly told to force it' {
        $p = $script:EngineAst.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ForceDivergedBranches' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $script:Text | Should -Match 'use -ForceDivergedBranches to overwrite'
    }

    It 'records what a forced branch discarded, before discarding it' {
        # 'some branches were forced' is not a record; the commits that existed only on
        # the target are.
        $script:Text | Should -Match '\$script:ForcedBranches\.Add'
        $script:Text | Should -Match 'OrphanCommits'
        $forcedAt = $script:Text.IndexOf('$script:ForcedBranches.Add')
        $pushAt = $script:Text.IndexOf('$segmentArgs = @(''push'')')
        $forcedAt | Should -BeLessThan $pushAt -Because 'the record is written before the overwrite'
    }

    It 'forces every push path of a diverged branch, not only the tip' {
        # The FIRST push already conflicts with the target's discarded tip, so forcing
        # only the final one would fail before reaching it. Asserted as 'every push
        # construction carries the flag' rather than a count, so adding a path (the
        # single-push route did exactly that) cannot quietly leave one unforced.
        $fn = Get-EngineFunctionSource -Name 'Push-BranchSegmented'
        $pushBuilds = [regex]::Matches($fn, "@\('push'\)[^\r\n]*")
        $pushBuilds.Count | Should -BeGreaterThan 1
        foreach ($build in $pushBuilds) {
            $build.Value | Should -Match "if \(\`$forcePush\) \{ @\('--force'\) \}" -Because "every push path must honour it: $($build.Value)"
        }
    }

    It 'measures the WHOLE outstanding payload and pushes once when it fits' {
        # Segmenting is for one case only: more than a single push can carry. That is a
        # property of everything outstanding, not of any one branch. Measured on this
        # engagement mid-migration: 413 MB left across every ref - one push, where
        # per-branch segmenting was queuing tens of thousands of pushes of nothing.
        $fn = Get-EngineFunctionSource -Name 'Push-Segmented'
        $fn | Should -Match "Measure-PushPayload -Branch '--all'"
        $fn | Should -Match 'Fits in one push'
        $fn | Should -Match 'Push-Mirror -CloneDir \$CloneDir -TargetRemote \$TargetRemote'
        # And the whole-repo decision must come BEFORE the per-branch loop.
        $wholeAt = $fn.IndexOf("Measure-PushPayload -Branch '--all'")
        $perBranchAt = $fn.IndexOf('Push-BranchSegmented -Branch $branch')
        $wholeAt | Should -BeGreaterThan 0
        $wholeAt | Should -BeLessThan $perBranchAt
    }

    It 'falls back to per-branch when the batch push is rejected' {
        # A diverged branch rejects the batch; per-branch can force those.
        $fn = Get-EngineFunctionSource -Name 'Push-Segmented'
        $fn | Should -Match 'single push rejected'
        $fn | Should -Match 'falling back to per-branch'
    }

    It 'measures the payload rather than segmenting by commit count' {
        # Commit count is a poor proxy: one 22,173-commit branch carried 4.97 GB while
        # branches of similar length sharing its history carried nothing at all, and
        # segmenting those produced pushes reporting 'Total 0 (delta 0)' - thousands of
        # ref updates transferring nothing.
        $fn = Get-EngineFunctionSource -Name 'Measure-PushPayload'
        $fn | Should -Match '--not "--remotes=\$TargetRemote"' -Because 'the payload is only what the target lacks'
        $fn | Should -Match 'objectsize:disk'
        $script:Text | Should -Match '\$payload = Measure-PushPayload'
    }

    It 'sends a branch in one push when it fits, however many commits it spans' {
        $fn = Get-EngineFunctionSource -Name 'Push-BranchSegmented'
        $fn | Should -Match 'if \(\$payload -le \$limitBytes\)'
        $fn | Should -Match 'one push'
    }

    It 'derives the segment size from the measured payload' {
        $fn = Get-EngineFunctionSource -Name 'Push-BranchSegmented'
        $fn | Should -Match '\$needed = \[math\]::Ceiling\(\$payload / \$limitBytes\)'
        $fn | Should -Match '\$effectiveBatch = \[math\]::Max\(1, \[math\]::Ceiling\(\$total / \$needed\)\)'
        # And the loop must use it, not the parameter it replaces.
        $fn | Should -Match 'for \(\$i = \$effectiveBatch - 1; \$i -lt \$total; \$i \+= \$effectiveBatch\)'
    }

    It 'falls back to commit-count segments when the payload cannot be measured' {
        $fn = Get-EngineFunctionSource -Name 'Push-BranchSegmented'
        $fn | Should -Match 'payload could not be measured'
        $fn | Should -Match '\$effectiveBatch = \$BatchSize'
    }

    It 'leaves headroom under the push limit for packing overhead' {
        # The measurement is of on-disk sizes; a push packs, and packing is not free.
        $fn = Get-EngineFunctionSource -Name 'Push-BranchSegmented'
        $fn | Should -Match '\$MaxPushSizeGB \* 1GB \* 0\.8'
    }

    It 'does not shadow the automatic $args variable' {
        $script:Text | Should -Not -Match '(?m)^\s*\$args\s*='
    }

    It 'never pushes with --mirror' {
        # A mirror push carries server-managed refs (refs/pull/*), which the target rejects.
        $script:Text | Should -Not -Match "push',\s*'--mirror"
    }
}

Describe 'Commit mention linking' {

    BeforeAll {
        $script:Text = Get-Content $script:EnginePath -Raw
        . ([scriptblock]::Create((Get-EngineFunctionSource -Name 'Set-RepositoryOption')))
    }

    It 'disables mentions before anything is pushed' {
        # The whole point: a push of full history with mentions live is the incident.
        $disableAt = $script:Text.IndexOf('Disable-CommitMention -RepoId')
        $syncAt = $script:Text.IndexOf('Sync-SourceMirror -CloneDir')
        $disableAt | Should -BeGreaterThan 0
        $disableAt | Should -BeLessThan $syncAt
    }

    It 'restores them in a finally, so an interrupted run does not leave them changed' {
        $script:Text | Should -Match '(?s)finally\s*\{[^}]*Restore-CommitMention'
    }

    It 'treats a failure to disable as a HARD STOP, not a warning' {
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Disable-CommitMention'
            }, $true)[0].Extent.Text
        $fn | Should -Match 'throw'
        $fn | Should -Not -Match 'Write-Warning[^\r\n]*refusing'
    }

    It 'verifies a write by re-reading rather than trusting the status code' {
        # The endpoint answers 200 for a body it does not understand, so the response
        # proves nothing. This is the single most important property of this code.
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-RepositoryOption'
            }, $true)[0].Extent.Text
        $fn | Should -Match 'Get-RepositoryOption -RepoId \$RepoId'
        $fn | Should -Match 'throw'
    }

    It 'sends the double-encoded body the endpoint requires' {
        # 'option' must be a JSON STRING. An object is accepted with a 200 and ignored,
        # which is exactly the silent failure this guards against.
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-RepositoryOption'
            }, $true)[0].Extent.Text
        $fn | Should -Match '\$inner = \(\[ordered\]@\{ key = \$Key; value = \$Value \}'
        $fn | Should -Match '\[ordered\]@\{ option = \$inner \}'

        # And prove the shape it produces, rather than only that the code says so.
        # [ordered] is required for this to be stable: a plain hashtable emits its
        # keys in an arbitrary order, which made this assertion flaky.
        $inner = ([ordered]@{ key = 'WitMentionsEnabled'; value = $false } | ConvertTo-Json -Compress)
        $body = ([ordered]@{ option = $inner } | ConvertTo-Json -Compress)
        $body | Should -BeExactly '{"option":"{\"key\":\"WitMentionsEnabled\",\"value\":false}"}'
    }

    It 'documents that the endpoint is undocumented and may change' {
        # A future maintainer must not discover this the hard way.
        $script:Text | Should -Match 'NOT DOCUMENTED BY MICROSOFT'
        $script:Text | Should -Match 'without notice'
    }

    It 'leaves an option alone when it was already off' {
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Restore-CommitMention'
            }, $true)[0].Extent.Text
        $fn | Should -Match 'it was off before'
    }
}

Describe 'Push watchdog and verification' {

    BeforeAll {
        $script:Text = Get-Content $script:EnginePath -Raw
        . ([scriptblock]::Create((Get-EngineFunctionSource -Name 'Get-LocalRefCount')))
        $script:Made = [System.Collections.Generic.List[string]]::new()
    }

    AfterAll {
        foreach ($d in $script:Made) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'pushes through the watchdog, not a bare invocation' {
        # A bare 'git push' waits forever when the helper pipe breaks: the transfer
        # completes server-side and the client never returns.
        $script:Text | Should -Match "Invoke-GitWatched -WorkingDirectory \`$CloneDir -Activity 'push'"
    }

    It 'keeps push output live rather than capturing it' {
        # Capturing would hide git's own 'Writing objects: 45%' progress, which is the
        # most useful signal a push is healthy. Invoke-GitWatched must not redirect.
        $watched = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GitWatched'
            }, $true)[0].Extent.Text
        $watched | Should -Not -Match 'RedirectStandardOutput'
        # Inherited streams: no redirection means git writes straight to the console.
        $watched | Should -Match '\$psi\.UseShellExecute = \$false'
        $watched | Should -Not -Match 'RedirectStandardError'
    }

    It 'passes each git argument separately, so the auth header survives its spaces' {
        # Start-Process -ArgumentList JOINS an array with spaces and quotes nothing, which
        # split 'http.extraheader=AUTHORIZATION: Bearer <token>' and made git read 'Bearer'
        # as a command. Every push through the watcher failed that way, falling back to a
        # per-branch path that only worked because it uses a different invoker.
        $script:Text | Should -Not -Match 'Start-Process -FilePath ''git'' -ArgumentList'
        foreach ($name in 'Invoke-GitWatched', 'Invoke-GitWithHeartbeat') {
            $fn = Get-EngineFunctionSource -Name $name
            $fn | Should -Match '\$psi\.ArgumentList\.Add' -Because "$name must add arguments individually"
        }
    }

    It 'reports elapsed time past an hour without wrapping back to zero' {
        # 'mm:ss' on a TimeSpan is minutes-WITHIN-the-hour, so an hour-long push reported
        # '03:23 elapsed' and read as though it had restarted - the worst possible signal
        # to someone deciding whether to kill a run that is legitimately still going.
        $script:Text | Should -Not -Match '\{1:mm\\:ss\} elapsed'

        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:Text, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Format-Elapsed' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        Invoke-Expression $fn.Extent.Text

        Format-Elapsed -Span ([timespan]::FromSeconds(203))  | Should -Be '03:23'
        Format-Elapsed -Span ([timespan]::FromMinutes(59.5)) | Should -Be '59:30'
        Format-Elapsed -Span ([timespan]::FromMinutes(63.4)) | Should -Be '1:03:24'
        Format-Elapsed -Span ([timespan]::FromHours(2.75))   | Should -Be '2:45:00'
    }

    It 'requires BOTH idleness and no connection before calling a push stalled' {
        # Idle alone is normal: the client sits at zero CPU while the server analyses,
        # validates and stores. Killing on idleness alone would abort healthy pushes.
        $watched = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GitWatched'
            }, $true)[0].Extent.Text
        $watched | Should -Match 'Test-TreeHasConnection'
        $watched | Should -Match '\$busy = .*-or \(Test-TreeHasConnection'
    }

    It 'assumes a connection exists when it cannot tell' {
        # Uncertainty must never kill a healthy push.
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-TreeHasConnection'
            }, $true)[0].Extent.Text
        $fn | Should -Match 'catch\s*\{[^}]*return \$true'
    }

    It 'verifies refs on the target before recording success' {
        $verifyAt = $script:Text.IndexOf('Get-TargetRefCount -Name $targetName')
        $summaryAt = $script:Text.IndexOf("-Status `$status")
        $verifyAt | Should -BeGreaterThan 0
        $verifyAt | Should -BeLessThan $summaryAt
    }

    It 'counts local refs correctly on a real repository' {
        $repo = New-TestRepo {
            Add-Commit -Path 'a.txt' -Content 'a' -Message 'one'
            & git tag v1 2>$null
            & git checkout --quiet -b second 2>$null
            Add-Commit -Path 'b.txt' -Content 'b' -Message 'two'
            & git tag v2 2>$null
        }
        $script:Made.Add($repo)
        # 2 heads (main, second) + 2 tags
        Get-LocalRefCount -CloneDir $repo | Should -Be 4
    }

    It 'builds a commit-graph after cloning, and never fails the migration over it' {
        $script:Text | Should -Match 'Write-CommitGraph -CloneDir \$CloneDir'
        $fn = $script:EngineAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-CommitGraph'
            }, $true)[0].Extent.Text
        $fn | Should -Match 'commit-graph.*write.*--reachable'
        $fn | Should -Match 'continuing without it'
    }
}

