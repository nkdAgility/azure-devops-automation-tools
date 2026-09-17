BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModuleRoot = Join-Path $script:RepoRoot 'system/NKDAgility.AzureDevOps.AutomationTools'
    $script:TemplateRoot = Join-Path $script:ModuleRoot 'Templates/customer-repo'
}

Describe 'Thin workspace bootstrap' {
    It 'keeps the managed entry point identical to the UM workspace' {
        $um = Join-Path (Split-Path -Parent $script:RepoRoot) 'NKDAClient-United-Machine/init.ps1'
        if (Test-Path $um) {
            (Get-FileHash (Join-Path $script:TemplateRoot 'init.ps1')).Hash |
                Should -BeExactly (Get-FileHash $um).Hash
        }
    }

    It 'delegates substantive setup to the module' {
        $entry = Get-Content (Join-Path $script:TemplateRoot 'init.ps1') -Raw
        ($entry -split "`n").Count | Should -BeLessThan 80
        $entry | Should -Match 'Invoke-AutomationWorkspaceInit'
        $entry | Should -Not -Match 'Set-AutomationSecrets|Initialize-AutomationWorkspace|CLAUDE\.managed\.md'
    }

    It 'initialises a fresh workspace offline from a clone and exposes the copied module' {
        $workspace = Join-Path $TestDrive 'customer'
        New-Item $workspace -ItemType Directory | Out-Null
        foreach ($name in 'init.ps1', 'capabilities.json', 'workspace.json') {
            Copy-Item (Join-Path $script:TemplateRoot $name) $workspace
        }
        Add-Content (Join-Path $workspace 'init.ps1') '# stale managed copy'
        $previous = $env:AZDO_ENGINE_AUTOMATION
        try {
            $env:AZDO_ENGINE_AUTOMATION = $script:RepoRoot
            $runner = Join-Path $TestDrive 'run-init.ps1'
            @'
param($Workspace)
$ErrorActionPreference = 'Stop'
. (Join-Path $Workspace 'init.ps1') -NoSync
if ((Get-AutomationWorkspace).Root -ne (Resolve-Path $Workspace).Path) { throw 'Workspace context missing' }
'@ | Set-Content $runner
            & pwsh -NoProfile -File $runner $workspace | Out-Null
            $LASTEXITCODE | Should -Be 0
            (Get-Content (Join-Path $workspace 'init.ps1') -Raw) | Should -Not -Match 'stale managed copy'
            Join-Path $workspace '.system/NKDAgility.AzureDevOps.AutomationTools/.source.json' | Should -Exist
            Join-Path $workspace 'secrets/secrets.json' | Should -Exist
            Join-Path $workspace 'AGENTS.md' | Should -Exist
        }
        finally { $env:AZDO_ENGINE_AUTOMATION = $previous }
    }

    It 'uses an existing materialised module for offline gallery bootstrap' {
        $workspace = Join-Path $TestDrive 'gallery-customer'
        New-Item $workspace -ItemType Directory | Out-Null
        foreach ($name in 'init.ps1', 'capabilities.json', 'workspace.json') {
            Copy-Item (Join-Path $script:TemplateRoot $name) $workspace
        }
        $systemModule = Join-Path $workspace '.system/NKDAgility.AzureDevOps.AutomationTools'
        New-Item (Split-Path $systemModule -Parent) -ItemType Directory | Out-Null
        Copy-Item $script:ModuleRoot $systemModule -Recurse
        Join-Path $systemModule 'NKDAgility.AzureDevOps.AutomationTools.psd1' | Should -Exist
        $runner = Join-Path $TestDrive 'run-gallery.ps1'
        @'
param($Workspace)
$ErrorActionPreference = 'Stop'
Remove-Item Env:AZDO_ENGINE_AUTOMATION -ErrorAction SilentlyContinue
Remove-Item Env:AZDO_AUTOMATION_TOOLS -ErrorAction SilentlyContinue
. (Join-Path $Workspace 'init.ps1') -Source gallery -NoSync
if ((Get-AutomationWorkspace).Root -ne (Resolve-Path $Workspace).Path) { throw 'Workspace context missing' }
'@ | Set-Content $runner
        & pwsh -NoProfile -File $runner $workspace | Out-Null
        $LASTEXITCODE | Should -Be 0
        Join-Path $systemModule '.source.json' | Should -Not -Exist
    }

    It 'upgrades a pre-refactor materialised module from a compatible installed module' {
        $workspace = Join-Path $TestDrive 'upgrade-customer'
        New-Item $workspace -ItemType Directory | Out-Null
        foreach ($name in 'init.ps1', 'capabilities.json', 'workspace.json') {
            Copy-Item (Join-Path $script:TemplateRoot $name) $workspace
        }
        $systemRoot = Join-Path $workspace '.system'
        New-Item $systemRoot -ItemType Directory | Out-Null
        $oldModule = Join-Path $systemRoot 'NKDAgility.AzureDevOps.AutomationTools'
        Copy-Item $script:ModuleRoot $oldModule -Recurse
        $manifest = Join-Path $oldModule 'NKDAgility.AzureDevOps.AutomationTools.psd1'
        (Get-Content $manifest -Raw).Replace("        'Invoke-AutomationWorkspaceInit'`r`n", '').Replace("        'Invoke-AutomationWorkspaceInit'`n", '') | Set-Content $manifest

        $modulesPath = Join-Path $TestDrive 'installed'
        New-Item $modulesPath -ItemType Directory | Out-Null
        $installed = Join-Path $modulesPath 'NKDAgility.AzureDevOps.AutomationTools'
        Copy-Item $script:ModuleRoot $installed -Recurse
        $installedManifest = Join-Path $installed 'NKDAgility.AzureDevOps.AutomationTools.psd1'
        (Get-Content $installedManifest -Raw).Replace("ModuleVersion     = '0.4.0'", "ModuleVersion     = '99.0.0'") | Set-Content $installedManifest

        $runner = Join-Path $TestDrive 'run-upgrade.ps1'
        @'
param($Workspace, $ModulesPath)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$ModulesPath$([IO.Path]::PathSeparator)$env:PSModulePath"
Remove-Item Env:AZDO_ENGINE_AUTOMATION -ErrorAction SilentlyContinue
Remove-Item Env:AZDO_AUTOMATION_TOOLS -ErrorAction SilentlyContinue
. (Join-Path $Workspace 'init.ps1') -Source gallery -NoSync
if ((Get-AutomationWorkspace).Root -ne (Resolve-Path $Workspace).Path) { throw 'Workspace context missing' }
'@ | Set-Content $runner
        & pwsh -NoProfile -File $runner $workspace $modulesPath | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $manifest -Raw) | Should -Match 'Invoke-AutomationWorkspaceInit'
    }
}
