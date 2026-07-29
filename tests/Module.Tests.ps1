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
