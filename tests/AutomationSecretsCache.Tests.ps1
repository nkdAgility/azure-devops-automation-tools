#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Private\Get-AutomationSecrets.ps1')
}

Describe 'Get-AutomationSecrets refresh' {
    It 'reads an edited secrets file when refresh is requested' {
        $path = Join-Path $TestDrive 'secrets.json'
        '{"Organisations":[{"Org":"example","Url":"https://dev.azure.com/example/","AccessToken":"first"}]}' |
            Set-Content -LiteralPath $path
        (Get-AutomationSecrets -SecretsPath $path -Refresh)[0].AccessToken | Should -Be 'first'

        '{"Organisations":[{"Org":"example","Url":"https://dev.azure.com/example/","AccessToken":"second"}]}' |
            Set-Content -LiteralPath $path
        (Get-AutomationSecrets -SecretsPath $path)[0].AccessToken | Should -Be 'first'
        (Get-AutomationSecrets -SecretsPath $path -Refresh)[0].AccessToken | Should -Be 'second'
    }
}
