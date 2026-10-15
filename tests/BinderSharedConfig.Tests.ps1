# migrate-repos-config.json is shared by Run-Migrate-Repos.ps1 and Run-Migrate-Artifacts.ps1.
# Each binder must drop settings its engine does not accept rather than splat them and fail
# with "A parameter cannot be found that matches parameter name ...".

Describe 'Binder parameter conversion ignores settings for the other engine' {
    BeforeDiscovery {
        $script:Cases = @(
            @{ Binder = 'Run-Migrate-Repos.ps1'; Engine = 'Migrate-Repos.ps1'; Foreign = 'IncludePromotedUpstream'; Own = 'SourceOrg' }
            @{ Binder = 'Run-Migrate-Repos.ps1'; Engine = 'Migrate-Repos.ps1'; Foreign = 'IncludeUpstream'; Own = 'SourceOrg' }
            @{ Binder = 'Run-Migrate-Artifacts.ps1'; Engine = 'Migrate-Artifacts.ps1'; Foreign = 'SkipWiki'; Own = 'SourceOrg' }
        )
    }

    It '<Binder> drops <Foreign> and keeps <Own>' -ForEach $script:Cases {
        $moduleRoot = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools'
        $binderPath = Join-Path $moduleRoot "Templates\migrations\migration-tools\$Binder"
        $enginePath = Join-Path $moduleRoot "Engines\$Engine"

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($binderPath, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-MigrateParams' }, $true) |
            Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty

        # The binder's own source of truth: the engine's parameter list.
        $validParams = (Get-Command -Name $enginePath).Parameters.Keys
        $validParams | Should -Not -Contain $Foreign
        $switchParams = @()
        $fallbackTokenParams = @()
        function Expand-EnvPlaceholder { param([string]$Value, [switch]$AllowMissing) $Value }
        . ([scriptblock]::Create($fn.Extent.Text))

        $settings = [ordered]@{ $Own = 'https://dev.azure.com/example'; $Foreign = $true }
        $params = ConvertTo-MigrateParams -Settings $settings

        $params.Keys | Should -Not -Contain $Foreign
        $params[$Own] | Should -Be 'https://dev.azure.com/example'
    }
}
