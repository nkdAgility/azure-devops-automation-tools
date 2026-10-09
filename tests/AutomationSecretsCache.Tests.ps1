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

Describe 'Get-AutomationSecrets per-project PATs' {
    It 'reads a Projects map, case-insensitively, dropping placeholders' {
        $path = Join-Path $TestDrive 'projects-map.json'
        '{"Organisations":[{"Org":"example","Projects":{"Alpha":"pat-a","Beta":"<beta-pat>"}}]}' |
            Set-Content -LiteralPath $path
        $entry = (Get-AutomationSecrets -SecretsPath $path -Refresh)[0]
        $entry.Projects['alpha'] | Should -Be 'pat-a'
        $entry.Projects.Contains('Beta') | Should -BeFalse
        $entry.AccessToken | Should -BeNullOrEmpty
    }

    It 'reads a Projects list of Project/AccessToken objects' {
        $path = Join-Path $TestDrive 'projects-list.json'
        '{"Organisations":[{"Org":"example","Projects":[{"Project":"Alpha","AccessToken":"pat-a"}]}]}' |
            Set-Content -LiteralPath $path
        (Get-AutomationSecrets -SecretsPath $path -Refresh)[0].Projects['Alpha'] | Should -Be 'pat-a'
    }

    It 'gives an entry without Projects an empty map' {
        $path = Join-Path $TestDrive 'no-projects.json'
        '{"Organisations":[{"Org":"example","AccessToken":"pat"}]}' | Set-Content -LiteralPath $path
        (Get-AutomationSecrets -SecretsPath $path -Refresh)[0].Projects.Count | Should -Be 0
    }
}
