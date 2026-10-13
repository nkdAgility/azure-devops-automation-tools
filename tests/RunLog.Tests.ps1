#Requires -Modules Pester

# Run logs are transcripts, so every scenario runs in a child pwsh: a transcript
# started inside the Pester host would record (and be stopped by) the test run itself.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModuleRoot = Join-Path $script:RepoRoot 'system/NKDAgility.AzureDevOps.AutomationTools'
    $script:Manifest = Join-Path $script:ModuleRoot 'NKDAgility.AzureDevOps.AutomationTools.psd1'
    $script:TemplateRoot = Join-Path $script:ModuleRoot 'Templates'

    # Writes a runbook into an engagement folder. $Body runs between the module import and
    # nothing else: each runbook wires its own Start/Stop so the tests see the template shape.
    function New-TestRunbook {
        param([string]$Folder, [string]$Name, [string]$Body)
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $path = Join-Path $Folder "$Name.ps1"
        @"
`$ErrorActionPreference = 'Stop'
Import-Module '$script:Manifest' -Force
Start-AutomationRunLog -Name '$Name'
try {
$Body
}
finally { Stop-AutomationRunLog }
"@ | Set-Content -LiteralPath $path
        $path
    }

    function Invoke-Child {
        param([string]$Path)
        foreach ($name in 'NKDA_RUNLOG', 'NKDA_RUNLOG_DEPTH', 'NKDA_RUNLOG_PID') {
            Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
        }
        $output = & pwsh -NoProfile -NonInteractive -File $Path 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
}

Describe 'Start-AutomationRunLog / Stop-AutomationRunLog' {
    BeforeEach {
        $script:Engagement = Join-Path $TestDrive ("ws-{0}\migrations\01-Test" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Runs = Join-Path $script:Engagement 'output\runs'
    }

    It 'records the console of a run under the engagement output\runs folder, named for the runbook and time' {
        $runbook = New-TestRunbook $script:Engagement 'Run-Thing' "Write-Host 'host-line'; Write-Output 'output-line'"
        $result = Invoke-Child $runbook
        $result.ExitCode | Should -Be 0

        $logs = @(Get-ChildItem $script:Runs -Filter *.log)
        $logs.Count | Should -Be 1
        $logs[0].Name | Should -Match '^Run-Thing-\d{8}-\d{6}\.log$'
        $text = Get-Content $logs[0].FullName -Raw
        $text | Should -Match 'host-line'
        $text | Should -Match 'output-line'
        $text | Should -Match 'Host Application: .*Run-Thing\.ps1'   # -IncludeInvocationHeader
    }

    It 'writes a nested runbook into its caller''s log, and keeps the log open after the nested one returns' {
        $inner = New-TestRunbook $script:Engagement 'Run-Inner' "Write-Host 'inner-line'"
        $outer = New-TestRunbook $script:Engagement 'Sync' "Write-Host 'before-inner'; & '$inner'; Write-Host 'after-inner'"
        $result = Invoke-Child $outer
        $result.ExitCode | Should -Be 0

        $logs = @(Get-ChildItem $script:Runs -Filter *.log)
        $logs.Count | Should -Be 1
        $logs[0].Name | Should -Match '^Sync-'
        $text = Get-Content $logs[0].FullName -Raw
        $text | Should -Match 'before-inner'
        $text | Should -Match 'inner-line'
        $text | Should -Match 'after-inner'
    }

    It 'joins the caller''s log from a child pwsh process without stopping it' {
        $inner = New-TestRunbook $script:Engagement 'Run-Child' "Write-Host 'child-line'"
        $outer = New-TestRunbook $script:Engagement 'Sync' "& pwsh -NoProfile -File '$inner' | Out-Host; Write-Host 'after-child'"
        (Invoke-Child $outer).ExitCode | Should -Be 0

        $logs = @(Get-ChildItem $script:Runs -Filter *.log)
        $logs.Count | Should -Be 1
        $text = Get-Content $logs[0].FullName -Raw
        $text | Should -Match 'child-line'    # the child's own output landed in the caller's log
        $text | Should -Match 'after-child'   # and the child did not stop it
        # The child joined rather than starting a log of its own.
        @(Get-ChildItem $script:Runs -Filter 'Run-Child-*.log').Count | Should -Be 0
    }

    It 'never overwrites an earlier run that started in the same second, or a concurrent one' {
        $probe = Join-Path $script:Engagement 'rapid.ps1'
        New-Item -ItemType Directory $script:Engagement -Force | Out-Null
        @"
Import-Module '$script:Manifest' -Force
foreach (`$i in 1..3) {
    Start-AutomationRunLog -Name 'Rapid' -EngagementPath '$script:Engagement'
    Write-Host "run-`$i"
    Stop-AutomationRunLog
}
"@ | Set-Content $probe
        # Two processes at once, each starting three runs back to back.
        foreach ($name in 'NKDA_RUNLOG', 'NKDA_RUNLOG_DEPTH', 'NKDA_RUNLOG_PID') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
        $procs = 1..2 | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$probe`"" -WindowStyle Hidden -PassThru }
        $procs | Wait-Process

        $logs = @(Get-ChildItem $script:Runs -Filter 'Rapid-*.log')
        $logs.Count | Should -Be 6
        foreach ($log in $logs) { (Get-Content $log.FullName -Raw) | Should -Match 'run-\d' }
    }

    It 'throws and claims no log when the transcript cannot start' {
        # output\runs exists as a FILE, so neither the folder nor the transcript can be made.
        New-Item -ItemType Directory (Join-Path $script:Engagement 'output') -Force | Out-Null
        'not a folder' | Set-Content (Join-Path $script:Engagement 'output\runs')
        $probe = Join-Path $script:Engagement 'blocked.ps1'
        @"
Import-Module '$script:Manifest' -Force
try { Start-AutomationRunLog -Name 'Blocked' -EngagementPath '$script:Engagement'; Write-Output 'started' }
catch { Write-Output 'threw' }
Write-Output "env-after: [`$env:NKDA_RUNLOG]"
"@ | Set-Content $probe
        $result = Invoke-Child $probe
        $result.Output | Should -Match 'threw'
        $result.Output | Should -Not -Match 'started'
        $result.Output | Should -Match 'env-after: \[\]'
    }

    It 'closes the log in finally when the runbook throws, and keeps what ran' {
        $runbook = New-TestRunbook $script:Engagement 'Run-Fails' "Write-Host 'got-this-far'; throw 'boom'"
        $probe = Join-Path $script:Engagement 'probe.ps1'
        @"
try { & '$runbook' } catch { Write-Output "caught: `$(`$_.Exception.Message)" }
Write-Output "env-after: [`$env:NKDA_RUNLOG]"
try { Stop-Transcript | Out-Null; Write-Output 'transcript-still-open' } catch { Write-Output 'transcript-closed' }
"@ | Set-Content $probe
        $result = Invoke-Child $probe
        $result.Output | Should -Match 'caught: boom'
        $result.Output | Should -Match 'env-after: \[\]'
        $result.Output | Should -Match 'transcript-closed'

        $log = @(Get-ChildItem $script:Runs -Filter *.log)[0]
        $text = Get-Content $log.FullName -Raw
        $text | Should -Match 'got-this-far'
        $text | Should -Match 'End time'   # footer written by Stop-Transcript
    }

    It 'starts a fresh log when the variables were left behind by a process that no longer exists' {
        $runbook = New-TestRunbook $script:Engagement 'Run-Stale' "Write-Host 'fresh'"
        $probe = Join-Path $script:Engagement 'stale.ps1'
        @"
`$env:NKDA_RUNLOG = 'C:\nowhere\stale.log'; `$env:NKDA_RUNLOG_DEPTH = '1'; `$env:NKDA_RUNLOG_PID = '999999'
& '$runbook'
"@ | Set-Content $probe
        (Invoke-Child $probe).ExitCode | Should -Be 0
        @(Get-ChildItem $script:Runs -Filter 'Run-Stale-*.log').Count | Should -Be 1
    }

    It 'honours -EngagementPath' {
        $elsewhere = Join-Path $TestDrive 'explicit-engagement'
        $probe = Join-Path $script:Engagement 'explicit.ps1'
        New-Item -ItemType Directory $script:Engagement -Force | Out-Null
        @"
Import-Module '$script:Manifest' -Force
Start-AutomationRunLog -Name 'Explicit' -EngagementPath '$elsewhere'
Stop-AutomationRunLog
"@ | Set-Content $probe
        (Invoke-Child $probe).ExitCode | Should -Be 0
        @(Get-ChildItem (Join-Path $elsewhere 'output\runs') -Filter 'Explicit-*.log').Count | Should -Be 1
    }
}

Describe 'Native tool output in run logs' {
    # Engines call git (and az, npm, mvn, dotnet) directly, unwrapped. This holds that their
    # stdout and stderr reach the transcript. It must run in a real console: with redirected
    # handles, as Invoke-Child uses, the transcript sees something different from a runbook.
    It 'records git stdout and stderr, at statement level and inside a function' -Skip:(-not $IsWindows -or -not (Get-Command git -ErrorAction SilentlyContinue)) {
        $engagement = Join-Path $TestDrive 'native\migrations\04-Native'
        $runbook = New-TestRunbook $engagement 'Run-Native' @'
$repo = Join-Path $PSScriptRoot 'repo'
New-Item -ItemType Directory $repo -Force | Out-Null
& git -C $repo init -q
function Invoke-EngineGit { & git -C $repo --version; & git -C $repo marker-in-function }
& git -C $repo --version
& git -C $repo marker-at-statement
Invoke-EngineGit
'@
        foreach ($name in 'NKDA_RUNLOG', 'NKDA_RUNLOG_DEPTH', 'NKDA_RUNLOG_PID') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
        Start-Process pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$runbook`"" -WindowStyle Hidden -Wait

        $log = @(Get-ChildItem (Join-Path $engagement 'output\runs') -Filter *.log)[0]
        $text = Get-Content $log.FullName -Raw
        ([regex]::Matches($text, 'git version \d')).Count | Should -Be 2
        $text | Should -Match "'marker-at-statement' is not a git command"
        $text | Should -Match "'marker-in-function' is not a git command"
    }
}

Describe 'Copy-AutomationRunLogArtifact' {
    It 'copies a folder and a file next to the log, into a folder named for the log' {
        $engagement = Join-Path $TestDrive 'copy\migrations\02-Copy'
        $toolLogs = Join-Path $TestDrive 'tool-logs'
        New-Item -ItemType Directory (Join-Path $toolLogs 'sub') -Force | Out-Null
        'tool log' | Set-Content (Join-Path $toolLogs 'migration.log')
        'nested' | Set-Content (Join-Path $toolLogs 'sub\detail.log')
        $single = Join-Path $TestDrive 'single.txt'
        'single' | Set-Content $single

        $runbook = New-TestRunbook $engagement 'Sync' @"
Copy-AutomationRunLogArtifact -Path '$toolLogs' -As 'devopsmigration-configuration-workitems'
Copy-AutomationRunLogArtifact -Path '$toolLogs' -As 'devopsmigration-configuration-workitems'
Copy-AutomationRunLogArtifact -Path '$single'
Copy-AutomationRunLogArtifact -Path 'C:\does\not\exist'
"@
        (Invoke-Child $runbook).ExitCode | Should -Be 0

        $log = @(Get-ChildItem (Join-Path $engagement 'output\runs') -Filter *.log)[0]
        $artifacts = Join-Path $log.DirectoryName $log.BaseName
        Test-Path (Join-Path $artifacts 'devopsmigration-configuration-workitems\migration.log') | Should -BeTrue
        Test-Path (Join-Path $artifacts 'devopsmigration-configuration-workitems\sub\detail.log') | Should -BeTrue
        # A second copy of the same folder refreshes it rather than nesting a copy inside.
        Test-Path (Join-Path $artifacts 'devopsmigration-configuration-workitems\tool-logs') | Should -BeFalse
        Test-Path (Join-Path $artifacts 'single.txt') | Should -BeTrue
    }

    It 'copies a folder whose path holds wildcard characters' {
        $engagement = Join-Path $TestDrive 'brackets\migrations\03-Brackets'
        $toolLogs = Join-Path $TestDrive 'WinGet[x64]\Logs'
        New-Item -ItemType Directory -Path $toolLogs -Force | Out-Null
        'bracketed' | Set-Content -LiteralPath (Join-Path $toolLogs 'migration.log')

        $runbook = New-TestRunbook $engagement 'Sync' "Copy-AutomationRunLogArtifact -Path '$toolLogs' -As 'devopsmigration'"
        (Invoke-Child $runbook).ExitCode | Should -Be 0

        $log = @(Get-ChildItem (Join-Path $engagement 'output\runs') -Filter *.log)[0]
        Test-Path -LiteralPath (Join-Path $log.DirectoryName "$($log.BaseName)\devopsmigration\migration.log") | Should -BeTrue
    }

    It 'does nothing when no run log is active' {
        Remove-Item Env:\NKDA_RUNLOG -ErrorAction SilentlyContinue
        Import-Module $script:Manifest -Force
        $source = Join-Path $TestDrive 'orphan.txt'
        'x' | Set-Content $source
        { Copy-AutomationRunLogArtifact -Path $source } | Should -Not -Throw
    }
}

Describe 'Run logs never contain tokens' {
    It 'keeps a fake token out of the transcript across init.ps1, Set-AutomationSecrets and a runbook' {
        $token = 'FAKETOKEN' + [guid]::NewGuid().ToString('N')
        $workspace = Join-Path $TestDrive 'secret-ws'
        New-Item -ItemType Directory (Join-Path $workspace 'secrets') -Force | Out-Null
        foreach ($name in 'init.ps1', 'capabilities.json', 'workspace.json') {
            Copy-Item (Join-Path $script:TemplateRoot "customer-repo/$name") $workspace
        }
        @{
            Organisations = @(
                @{ Org = 'fake-source'; Url = 'https://dev.azure.com/fake-source'; AccessToken = $token
                   Projects = @{ ProjectA = $token }
                   EnvVars = @('MigrationTools__Endpoints__Source__Authentication__AccessToken') }
                @{ Org = 'fake-github'; Url = 'https://github.com/fake-github'; AccessToken = $token; EnvVars = @('GITHUB_TOKEN') }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $workspace 'secrets/secrets.json')

        $engagement = Join-Path $workspace 'migrations\01-Secrets'
        New-Item -ItemType Directory $engagement -Force | Out-Null
        # The template shape: init.ps1, then the run log, then secrets loaded inside it -
        # verbose and with the returned names printed, so anything they emit is recorded.
        @'
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\init.ps1" -NoSync
Start-AutomationRunLog -Name 'Sync'
try {
    Set-AutomationSecrets -Project 'ProjectA' -Verbose
    Get-ChildItem Env:\AZDO_PAT_* | ForEach-Object { Write-Host "loaded $($_.Name)" }
}
finally { Stop-AutomationRunLog }
'@ | Set-Content (Join-Path $engagement 'Sync.ps1')

        # An outer transcript covers init.ps1 too, which runs before the run log starts.
        $outerLog = Join-Path $TestDrive 'outer.log'
        $probe = Join-Path $TestDrive 'secret-probe.ps1'
        @"
Start-Transcript -LiteralPath '$outerLog' | Out-Null
try { & '$(Join-Path $engagement 'Sync.ps1')' -Verbose } finally { Stop-Transcript | Out-Null }
"@ | Set-Content $probe

        $previous = $env:AZDO_ENGINE_AUTOMATION
        try {
            $env:AZDO_ENGINE_AUTOMATION = $script:RepoRoot
            $result = Invoke-Child $probe
        }
        finally { $env:AZDO_ENGINE_AUTOMATION = $previous }

        $result.ExitCode | Should -Be 0 -Because $result.Output
        $runLog = @(Get-ChildItem (Join-Path $engagement 'output\runs') -Filter *.log)[0]
        $runText = Get-Content $runLog.FullName -Raw
        $runText | Should -Match 'loaded AZDO_PAT_FAKE_SOURCE'   # the secrets path really ran
        $runText | Should -Not -Match $token
        (Get-Content $outerLog -Raw) | Should -Not -Match $token
        $result.Output | Should -Not -Match $token
    }
}

Describe 'Runbook templates are wired for run logs' {
    BeforeDiscovery {
        $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'system/NKDAgility.AzureDevOps.AutomationTools/Templates/migrations'
        $script:Runbooks = Get-ChildItem $root -Recurse -Filter *.ps1 | ForEach-Object {
            @{ Name = "$($_.Directory.Name)/$($_.Name)"; Path = $_.FullName }
        }
    }

    It '<Name> starts the run log after init.ps1 and stops it' -TestCases $script:Runbooks {
        param($Name, $Path)
        $text = Get-Content $Path -Raw
        $init = $text.IndexOf('init.ps1"')
        $start = $text.IndexOf('Start-AutomationRunLog')
        $init | Should -BeGreaterThan 0
        $start | Should -BeGreaterThan $init
        $text | Should -Match 'Stop-AutomationRunLog'
        if ($text -notmatch '(?i)selection-by-selection') {
            $text | Should -Match '(?s)try \{.*\}\s*finally \{ Stop-AutomationRunLog \}\s*$'
        }
    }

    It 'every Sync.ps1 that runs devopsmigration keeps the tool''s log folder' {
        $root = Join-Path $script:TemplateRoot 'migrations'
        foreach ($file in Get-ChildItem $root -Recurse -Include Sync.ps1, Run-Inventory.ps1) {
            $text = Get-Content $file.FullName -Raw
            if ($text -match '\.Source (execute|queue)') {
                $text | Should -Match 'Copy-AutomationRunLogArtifact' -Because $file.FullName
                # 'Logpath:' is printed at startup on every run; 'Check the logs for errors:' is
                # not printed on a validation failure, which is the run whose logs matter most.
                $text | Should -Match ([regex]::Escape("(?:Logpath|Check the logs for errors):")) -Because $file.FullName
            }
        }
    }

    It 'the customer .gitignore never ignores engagement run logs' {
        $gitignore = Get-Content (Join-Path $script:TemplateRoot 'customer-repo/gitignore.template')
        $gitignore | Should -Contain '/output/'
        $gitignore | Should -Contain '!/migrations/*/output/runs/'
        $gitignore | Should -Not -Contain 'output/'
    }
}

Describe 'Enable-AutomationRunLog' {
    BeforeAll { Import-Module $script:Manifest -Force }

    It 'wraps a seed runbook after its init.ps1 line, and is idempotent' {
        $folder = Join-Path $TestDrive 'enable\migrations\03-Old'
        New-Item -ItemType Directory $folder -Force | Out-Null
        $path = Join-Path $folder 'Run-Old.ps1'
        @'
param([switch]$X)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\init.ps1"
Write-Host 'body'
'@ | Set-Content $path

        Enable-AutomationRunLog -Path $path -WhatIf
        (Get-Content $path -Raw) | Should -Not -Match 'Start-AutomationRunLog'

        Enable-AutomationRunLog -Path $path
        $text = Get-Content $path -Raw
        $text | Should -Match "(?m)init\.ps1`"\r?\n# Record"
        $text | Should -Match "Start-AutomationRunLog -Name 'Run-Old'\r?\ntry \{"
        $text | Should -Match 'finally \{ Stop-AutomationRunLog \}'
        Enable-AutomationRunLog -Path $path
        (Get-Content $path -Raw) | Should -BeExactly $text
    }

    It 'converts the engagement-local Start-RunLog.ps1 pattern to the module functions' {
        $folder = Join-Path $TestDrive 'enable\migrations\05-Local'
        New-Item -ItemType Directory $folder -Force | Out-Null
        $path = Join-Path $folder 'Sync.ps1'
        @'
param()
. "$PSScriptRoot\Start-RunLog.ps1" -Name 'Sync'
try {
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\init.ps1"
Copy-RunLogArtifact -Path $x -As 'y'
}
finally { Stop-RunLog }
'@ | Set-Content $path
        Enable-AutomationRunLog -Path $path
        $text = Get-Content $path -Raw
        $text | Should -Match "(?m)^Start-AutomationRunLog -Name 'Sync'\r?$"
        $text | Should -Match 'Copy-AutomationRunLogArtifact -Path'
        $text | Should -Match 'finally \{ Stop-AutomationRunLog \}'
        $text | Should -Not -Match 'Start-RunLog\.ps1|\bStop-RunLog\b|\bCopy-RunLogArtifact\b'
        # The local script ran before init.ps1; the module function has to run after it.
        $text.IndexOf('Start-AutomationRunLog') | Should -BeGreaterThan $text.IndexOf('init.ps1"')
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'wires a runbook whose init.ps1 line is the last line, with no newline' {
        $folder = Join-Path $TestDrive 'enable\migrations\06-Eof'
        New-Item -ItemType Directory $folder -Force | Out-Null
        $path = Join-Path $folder 'Run-Eof.ps1'
        Set-Content -LiteralPath $path -Value "param()`n. `"`$PSScriptRoot\..\..\init.ps1`"" -NoNewline

        Enable-AutomationRunLog -Path $path
        $text = Get-Content $path -Raw
        $text | Should -Match "init\.ps1`"\r?\n# Record"
        $text | Should -Match 'finally \{ Stop-AutomationRunLog \}'
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'leaves selection-by-selection runbooks to be wired by hand' {
        $path = Join-Path $TestDrive 'scratch.ps1'
        @'
# Run selection-by-selection in VS Code.
. "$PSScriptRoot\..\..\init.ps1"
'@ | Set-Content $path
        $before = Get-Content $path -Raw
        Enable-AutomationRunLog -Path $path -WarningAction SilentlyContinue
        (Get-Content $path -Raw) | Should -BeExactly $before
    }
}
