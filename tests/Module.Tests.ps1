#Requires -Modules Pester

# Hygiene checks over the module itself: these catch the mistakes that are easy
# to make when adding a function - forgetting FunctionsToExport, or leaving a
# file that no longer parses.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'NKDAgility.AzureDevOps.AutomationTools.psd1'
    $script:Manifest = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
    $script:PublicNames = @(Get-ChildItem (Join-Path $script:ModuleRoot 'Public') -Filter *.ps1 -Recurse).BaseName
}

Describe 'Module manifest' {

    It 'imports without error' {
        { Import-Module $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports every function file under Public' {
        $missing = @($script:PublicNames | Where-Object { $_ -notin $script:Manifest.FunctionsToExport })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a new Public function must be added to FunctionsToExport'
    }

    It 'exports nothing that has no file under Public' {
        $orphans = @($script:Manifest.FunctionsToExport | Where-Object { $_ -notin $script:PublicNames })
        $orphans -join ', ' | Should -BeNullOrEmpty -Because 'FunctionsToExport must not name a function that was renamed or removed'
    }

    It 'declares one function per file' {
        Import-Module $script:ManifestPath -Force
        foreach ($name in $script:PublicNames) {
            Get-Command -Module 'NKDAgility.AzureDevOps.AutomationTools' -Name $name -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$name.ps1 should define a function of the same name"
        }
    }
}

Describe 'Script files parse' {

    It 'every .ps1 in the repo parses' {
        $root = Join-Path $PSScriptRoot '..'
        $files = Get-ChildItem $root -Filter *.ps1 -Recurse -File |
            Where-Object { $_.FullName -notmatch '\\\.git\\' }

        $broken = foreach ($file in $files) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
            if ($errors) { "$($file.Name) ($($errors.Count) errors)" }
        }
        $broken -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Module is self-contained' {

    # The module is COPIED out of this repo into a client workspace's .system\ folder.
    # Anything it reaches for above its own root does not exist at runtime, so these
    # guard the copy contract rather than the docs.

    It 'has no upward path arithmetic' {
        $offenders = @(Get-ChildItem $script:ModuleRoot -Filter *.ps1 -Recurse -File |
                Where-Object { $_.FullName -notmatch '\\Templates\\' } |
                Select-String -Pattern 'Split-Path\s+-Parent\s+\(Split-Path', 'Join-Path\s+\$[\w:]*(ModuleRoot|ModuleBase|PSScriptRoot)\s+\S*\.\.' |
                ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'the module must resolve its own files from $script:ModuleRoot, never by walking up out of it'
    }

    It 'ships the templates it scaffolds from' {
        foreach ($folder in 'customer-repo', 'migrations\data-import', 'migrations\migration-tools', 'migrations\migration-platform') {
            Join-Path $script:ModuleRoot (Join-Path 'Templates' $folder) |
                Should -Exist -Because 'New-AutomationWorkspace and New-Migration resolve templates from inside the module'
        }
    }
}

Describe 'Engine shape' {

    # Every nkdAgility engine presents the same surface to a customer workspace, so the
    # workspace's init.ps1 can drive any of them without special-casing. This asserts
    # THIS engine's half of that contract; azure-devops-governance-as-code asserts the
    # same list against its own module. Change one, change both.

    It 'is a module folder named for the module' {
        $manifestName = [System.IO.Path]::GetFileNameWithoutExtension($script:ManifestPath)
        Split-Path -Leaf $script:ModuleRoot | Should -BeExactly $manifestName
    }

    It 'ships Templates\customer-repo laid out relative to the workspace root' {
        Join-Path $script:ModuleRoot 'Templates\customer-repo' | Should -Exist
    }

    It 'declares which of those files it owns' {
        $managed = Join-Path $script:ModuleRoot 'Templates\customer-repo\.managed'
        $managed | Should -Exist -Because 'the workspace refreshes exactly the files an engine names here, and treats the rest as seeds'
        @(Get-Content $managed | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) |
            Should -Not -BeNullOrEmpty
    }

    It 'every managed path exists in the template' {
        $templateRoot = Join-Path $script:ModuleRoot 'Templates\customer-repo'
        $managed = @(Get-Content (Join-Path $templateRoot '.managed') |
                Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                ForEach-Object { $_.Trim() -replace '/', '\' })
        foreach ($relative in $managed) {
            Join-Path $templateRoot $relative | Should -Exist -Because "'$relative' is declared managed but is not in the template"
        }
    }

    It 'ships agent guidance for the capability' {
        Join-Path $script:ModuleRoot 'Agents\CAPABILITY.md' | Should -Exist -Because 'the workspace renders this into CLAUDE.md, AGENTS.md and copilot-instructions.md'
    }

    It 'scaffolds correctly when copied out of the repo' {
        # The contract test: copy just the module somewhere with no relationship to this
        # repo, and prove both scaffold commands still work.
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("adoat-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $moduleCopy = Join-Path $sandbox 'NKDAgility.AzureDevOps.AutomationTools'
        $workspace = Join-Path $sandbox 'workspace'
        $sandboxModule = $null
        try {
            New-Item -Path $sandbox -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $script:ModuleRoot -Destination $moduleCopy -Recurse

            $sandboxModule = Import-Module (Join-Path $moduleCopy 'NKDAgility.AzureDevOps.AutomationTools.psd1') -Force -PassThru
            New-AutomationWorkspace -Path $workspace | Out-Null
            Join-Path $workspace 'workspace.json' | Should -Exist
            Join-Path $workspace '.gitignore' | Should -Exist

            Initialize-AutomationWorkspace -Path $workspace -NoLogging | Out-Null
            New-Migration -Name 'Contract' -Type DataImport -Path $workspace | Out-Null
            Join-Path $workspace 'migrations\01-Contract\DataImport-Cleanup.ps1' | Should -Exist
            Join-Path $workspace 'migrations\01-Contract\.template.json' | Should -Exist
        }
        finally {
            # Unload the sandbox copy explicitly: it shares this module's name, so leaving
            # it loaded makes Get-Module return two and breaks every later test that
            # resolves the module by name.
            if ($sandboxModule) { Remove-Module -ModuleInfo $sandboxModule -Force -ErrorAction SilentlyContinue }
            Import-Module $script:ManifestPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Toolkit holds no customer data' {

    # The client-workspace model only holds if the toolkit cannot accumulate
    # customer data again. These assert the structure, not just the docs.

    It 'has no data folder' {
        Test-Path (Join-Path $PSScriptRoot '..\data') | Should -BeFalse
    }

    It 'has no config.json' {
        Test-Path (Join-Path $PSScriptRoot '..\config.json') | Should -BeFalse
    }

    It 'gitignores /data/ with no exception' {
        $gitignore = Get-Content (Join-Path $PSScriptRoot '..\.gitignore')
        $gitignore | Should -Contain '/data/'
        @($gitignore | Where-Object { $_ -like '!*data*' }) | Should -BeNullOrEmpty
    }

    It 'has no script that dot-sources includes relative to the current directory' {
        $root = Join-Path $PSScriptRoot '..\src'
        $offenders = @(Get-ChildItem $root -Filter *.ps1 -Recurse -File |
                Select-String -Pattern '^\s*\.\s+\.\\src\\' |
                ForEach-Object { $_.Path })
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'these scripts run from a client repo, where .\src does not exist'
    }
}
