Describe 'Artifact engine URL and REST failures' {
    BeforeAll {
        $enginePath = Join-Path $PSScriptRoot '../system/NKDAgility.AzureDevOps.AutomationTools/Engines/Migrate-Artifacts.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($enginePath, [ref]$null, [ref]$null)
        $helperNames = @('Get-OrgName', 'Get-VssPsBaseUrl', 'Get-PackagingBaseUrl', 'Get-FeedsBaseUrl', 'Get-PackagingWebBase', 'New-AdoRequestError', 'Invoke-AdoApi', 'Invoke-AdoWebRequest')
        $helpers = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $helperNames }, $true)
        $helperSource = ($helpers | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
        . ([scriptblock]::Create($helperSource))
        function Test-AzureDevOpsHosted { param([string]$Collection) ([uri]$Collection).Host -match '^(dev\.azure\.com|[^.]+\.visualstudio\.com)$' }
    }

    It 'normalizes both hosted URL forms across every service host' {
        foreach ($orgUrl in @('https://georgfischer.visualstudio.com', 'https://georgfischer.visualstudio.com/', 'https://dev.azure.com/georgfischer/')) {
            Get-OrgName -OrgUrl $orgUrl | Should -Be 'georgfischer'
            Get-FeedsBaseUrl -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://feeds.dev.azure.com/georgfischer/Project/_apis/packaging'
            Get-PackagingBaseUrl -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://pkgs.dev.azure.com/georgfischer/Project/_apis/packaging'
            Get-PackagingWebBase -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://pkgs.dev.azure.com/georgfischer/Project/'
            Get-VssPsBaseUrl -OrgUrl $orgUrl | Should -Be 'https://vssps.dev.azure.com/georgfischer/_apis'
        }
    }

    It 'keeps Azure DevOps Server requests on the collection host' {
        $orgUrl = 'https://ado.example.test/tfs/Collection/'
        Get-FeedsBaseUrl -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://ado.example.test/tfs/Collection/Project/_apis/packaging'
        Get-PackagingBaseUrl -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://ado.example.test/tfs/Collection/Project/_apis/packaging'
        Get-PackagingWebBase -OrgUrl $orgUrl -Project 'Project' | Should -Be 'https://ado.example.test/tfs/Collection/Project/'
        Get-VssPsBaseUrl -OrgUrl $orgUrl | Should -Be 'https://ado.example.test/tfs/Collection/_apis'
    }

    It 'reports REST operation, method and status without credentials' {
        Mock Invoke-RestMethod {
            $error = [System.Exception]::new('secret response')
            $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 401 }
            throw $error
        }
        function Invoke-FeedProbe { Invoke-AdoApi -Uri 'https://user:password@feeds.dev.azure.com/org/_apis/packaging/feeds?token=secret' -Headers @{ Authorization = 'Basic secret' } -Method Post }
        try { Invoke-FeedProbe; throw 'Expected failure' }
        catch {
            $_.Exception.Message | Should -Be 'Invoke-FeedProbe failed: Post https://feeds.dev.azure.com/org/_apis/packaging/feeds (HTTP 401).'
        }
    }

    It 'reports web request failures without leaking query tokens or authorization headers' {
        Mock Invoke-WebRequest {
            $error = [System.Exception]::new('secret response')
            $error | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = 403 }
            throw $error
        }
        function Invoke-PackageProbe { Invoke-AdoWebRequest -Uri 'https://pkgs.dev.azure.com/org/feed?token=secret' -Headers @{ Authorization = 'Bearer secret' } -ExtraArgs @{ Method = 'Get' } }
        try { Invoke-PackageProbe; throw 'Expected failure' }
        catch {
            $_.Exception.Message | Should -Be 'Invoke-PackageProbe failed: Get https://pkgs.dev.azure.com/org/feed (HTTP 403).'
        }
    }
}
