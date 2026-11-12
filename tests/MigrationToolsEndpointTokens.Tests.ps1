#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Public\Common\Test-MigrationToolsEndpointTokens.ps1')
    $secretsFile = Join-Path $TestDrive 'secrets.json'
    Set-Content -LiteralPath $secretsFile -Value '{}'
    $script:Workspace = [pscustomobject]@{ SecretsPath = $secretsFile }
    function Get-AutomationSecrets {
        param([Parameter(Mandatory)][string]$SecretsPath)
        @(
            [pscustomobject]@{ Org = 'src-org'; Url = 'https://dev.azure.com/src-org' },
            [pscustomobject]@{ Org = 'tgt-org'; Url = 'https://dev.azure.com/tgt-org/' }
        )
    }
    $script:Names = 'Source', 'Target' | ForEach-Object {
        "MigrationTools__Endpoints__${_}__Authentication__AccessToken"
        "MigrationTools__Endpoints__${_}__AccessToken"
    }
    function New-Config([string]$SourceToken = '', [string]$TargetMode = 'AccessToken') {
        $path = Join-Path $TestDrive 'configuration-workitems.json'
        @{ MigrationTools = @{ Endpoints = @{
                    Source = @{ Collection = 'https://dev.azure.com/src-org/'; Authentication = @{ AuthenticationMode = 'AccessToken'; AccessToken = $SourceToken } }
                    Target = @{ Collection = 'https://dev.azure.com/tgt-org/'; Authentication = @{ AuthenticationMode = $TargetMode; AccessToken = '' } }
                } } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
        $path
    }
}

Describe 'Test-MigrationToolsEndpointTokens' {
    BeforeEach {
        $script:Saved = @{}
        foreach ($n in $script:Names) { $script:Saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }
    AfterEach {
        foreach ($n in $script:Names) { [Environment]::SetEnvironmentVariable($n, $script:Saved[$n], 'Process') }
    }

    It 'fails naming each unbound endpoint and its secrets.json org' {
        $config = New-Config
        $message = try { Test-MigrationToolsEndpointTokens -ConfigPath $config; '' } catch { $_.Exception.Message }
        $message | Should -BeLike '*2 endpoint(s)*'
        $message | Should -BeLike "*MigrationTools__Endpoints__Source__Authentication__AccessToken*'src-org'*"
        $message | Should -BeLike "*MigrationTools__Endpoints__Target__Authentication__AccessToken*'tgt-org'*"
    }

    It 'passes when both endpoints are bound, nested or flat' {
        $env:MigrationTools__Endpoints__Source__Authentication__AccessToken = 'x'
        $env:MigrationTools__Endpoints__Target__AccessToken = 'y'
        { Test-MigrationToolsEndpointTokens -ConfigPath (New-Config) } | Should -Not -Throw
    }

    It 'ignores endpoints with a token in the config or a non-token mode' {
        { Test-MigrationToolsEndpointTokens -ConfigPath (New-Config -SourceToken 'inline' -TargetMode 'Prompt') } | Should -Not -Throw
    }

    It 'never puts a token value in the message' {
        $env:MigrationTools__Endpoints__Target__Authentication__AccessToken = 'secret-value'
        try { Test-MigrationToolsEndpointTokens -ConfigPath (New-Config); throw 'expected failure' }
        catch { $_.Exception.Message | Should -Not -Match 'secret-value'; $_.Exception.Message | Should -Match 'Source endpoint' }
    }
}
