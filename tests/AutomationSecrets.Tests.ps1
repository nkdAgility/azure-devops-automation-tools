#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Public\Common\Set-AutomationSecrets.ps1')
    . (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Private\Get-DerivedPatEnvVarName.ps1')
    function Write-FixStep { param([string]$Message) }
    function Get-AutomationSecrets {
        param([string]$SecretsPath, [switch]$Refresh)
        if (-not $Refresh) { throw 'Secrets must be refreshed on every load' }
        $script:TestEntries
    }
    function Get-AzureDevOpsAccessToken {
        param([string]$Collection)
        if ($script:FailEntra) { throw 'mock sign-in failure' }
        'mock-entra-token'
    }
    $script:Names = @(
        'AZDO_PAT_SOURCE', 'AZDO_PAT_TARGET',
        'MigrationTools__Endpoints__Source__AccessToken',
        'MigrationTools__Endpoints__Source__Authentication__AccessToken',
        'MigrationTools__Endpoints__Target__AccessToken',
        'MigrationTools__Endpoints__Target__Authentication__AccessToken',
        'AZDO_PAT_SOURCE__PROJECT_A', 'AZDO_PAT_SOURCE__PROJECT_B'
    )
}

Describe 'Set-AutomationSecrets endpoint bindings' {
    BeforeEach {
        $script:FailEntra = $false
        $script:SavedEnvironment = @{}
        foreach ($name in $script:Names) {
            $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, 'stale', 'Process')
        }
        $script:TestEntries = @(
            [pscustomobject]@{ Org = 'source'; Url = 'https://source.visualstudio.com/'; AccessToken = 'source-pat'; IsPlaceholder = $false; EnvVars = @('MigrationTools__Endpoints__Source__Authentication__AccessToken') },
            [pscustomobject]@{ Org = 'target'; Url = 'https://dev.azure.com/target/'; AccessToken = $null; IsPlaceholder = $false; EnvVars = @('MigrationTools__Endpoints__Target__Authentication__AccessToken') }
        )
    }
    AfterEach {
        foreach ($name in $script:Names) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name], 'Process')
        }
    }

    It 'refreshes source PAT and target Entra credentials in all three formats' {
        Set-AutomationSecrets -SecretsPath $TestDrive -WarningAction Stop | Out-Null
        foreach ($name in @($script:Names | Where-Object { $_ -notmatch '__PROJECT_' })) {
            $expected = if ($name -match 'SOURCE|Source') { 'source-pat' } else { 'mock-entra-token' }
            [Environment]::GetEnvironmentVariable($name) | Should -Be $expected
        }
    }

    It 'preserves deliberate CI values only with NoClobber' {
        Set-AutomationSecrets -SecretsPath $TestDrive -NoClobber | Out-Null
        foreach ($name in $script:Names) {
            [Environment]::GetEnvironmentVariable($name) | Should -Be 'stale'
        }
    }

    It 'fills missing CI endpoint formats from an injected credential' {
        [Environment]::SetEnvironmentVariable('MigrationTools__Endpoints__Target__AccessToken', $null, 'Process')
        Set-AutomationSecrets -SecretsPath $TestDrive -NoClobber | Out-Null
        [Environment]::GetEnvironmentVariable('MigrationTools__Endpoints__Target__AccessToken') | Should -Be 'stale'
    }

    It 'rejects conflicting pre-existing CI bindings' {
        [Environment]::SetEnvironmentVariable('MigrationTools__Endpoints__Target__AccessToken', 'different', 'Process')
        { Set-AutomationSecrets -SecretsPath $TestDrive -NoClobber | Out-Null } | Should -Throw '*conflicting pre-existing*'
    }

    It 'clears stale interactive values when a PAT is a placeholder' {
        $script:TestEntries[0].AccessToken = $null
        $script:TestEntries[0].IsPlaceholder = $true
        Set-AutomationSecrets -SecretsPath $TestDrive -WarningAction SilentlyContinue | Out-Null
        foreach ($name in @($script:Names | Where-Object { $_ -match 'SOURCE|Source' })) {
            [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty
        }
    }

    It 'clears stale target bindings when Entra sign-in fails' {
        $script:FailEntra = $true
        Set-AutomationSecrets -SecretsPath $TestDrive -WarningAction SilentlyContinue | Out-Null
        foreach ($name in @($script:Names | Where-Object { $_ -match 'TARGET|Target' })) {
            [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty
        }
    }

    It 'clears stale bindings when an organisation is removed' {
        $script:TestEntries = @()
        Set-AutomationSecrets -SecretsPath $TestDrive | Out-Null
        foreach ($name in $script:Names) {
            [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty
        }
    }

    It 'exports every per-project PAT under its derived name' {
        $script:TestEntries[0] | Add-Member -NotePropertyName Projects -NotePropertyValue ([ordered]@{ 'Project-A' = 'pat-a'; 'Project.B' = 'pat-b' })
        Set-AutomationSecrets -SecretsPath $TestDrive | Out-Null
        [Environment]::GetEnvironmentVariable('AZDO_PAT_SOURCE__PROJECT_A') | Should -Be 'pat-a'
        [Environment]::GetEnvironmentVariable('AZDO_PAT_SOURCE__PROJECT_B') | Should -Be 'pat-b'
        [Environment]::GetEnvironmentVariable('MigrationTools__Endpoints__Source__AccessToken') | Should -Be 'source-pat'
    }

    It 'binds a selected project PAT to every organisation-level name' {
        $script:TestEntries[0] | Add-Member -NotePropertyName Projects -NotePropertyValue ([ordered]@{ 'Project-A' = 'pat-a'; 'Project.B' = 'pat-b' })
        Set-AutomationSecrets -SecretsPath $TestDrive -Project 'project.b', 'UnrelatedTarget' | Out-Null
        foreach ($name in @($script:Names | Where-Object { $_ -cmatch 'SOURCE$|Source' })) {
            [Environment]::GetEnvironmentVariable($name) | Should -Be 'pat-b'
        }
        [Environment]::GetEnvironmentVariable('MigrationTools__Endpoints__Target__AccessToken') | Should -Be 'mock-entra-token'
    }

    It 'uses a selected project PAT when the organisation has no token of its own' {
        $script:TestEntries[0].AccessToken = $null
        $script:TestEntries[0] | Add-Member -NotePropertyName Projects -NotePropertyValue ([ordered]@{ 'Project-A' = 'pat-a' })
        Set-AutomationSecrets -SecretsPath $TestDrive -Project 'Project-A' -WarningAction Stop | Out-Null
        [Environment]::GetEnvironmentVariable('MigrationTools__Endpoints__Source__Authentication__AccessToken') | Should -Be 'pat-a'
    }

    It 'refuses two selected projects in one organisation' {
        $script:TestEntries[0] | Add-Member -NotePropertyName Projects -NotePropertyValue ([ordered]@{ 'Project-A' = 'pat-a'; 'Project.B' = 'pat-b' })
        { Set-AutomationSecrets -SecretsPath $TestDrive -Project 'Project-A', 'Project.B' | Out-Null } | Should -Throw '*more than one selected project*'
    }

    It 'clears stale bindings when interactive init has no secrets file' {
        $script:TestEntries = @()
        Set-AutomationSecrets -SecretsPath (Join-Path $TestDrive 'missing.json') -ClearMissing | Out-Null
        foreach ($name in $script:Names) {
            [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty
        }
    }
}
