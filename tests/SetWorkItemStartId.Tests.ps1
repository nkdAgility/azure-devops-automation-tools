#Requires -Modules Pester

# Behaviour of Engines\Set-WorkItemStartId.ps1 against a fake Azure DevOps that
# keeps its own work item ID counter. No network, no credentials.

Describe 'Set-WorkItemStartId' {

    BeforeAll {
        $script:Engine = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines\Set-WorkItemStartId.ps1'

        # The module's resolver, stubbed: any header set will do.
        function global:Resolve-AzureDevOpsAuth { param($Collection, $Pat) @{ Mode = 'test'; Headers = @{ Authorization = 'Basic test' } } }
    }

    AfterAll {
        Remove-Item Function:\Resolve-AzureDevOpsAuth -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:Fake = @{ Next = 1000; Created = [System.Collections.Generic.List[int]]::new(); Destroyed = [System.Collections.Generic.List[int]]::new(); Calls = [System.Collections.Generic.List[string]]::new(); Leftovers = @(7, 8) }
        Mock Invoke-RestMethod {
            $u = [string]$Uri
            if ($u -match '/_apis/wit/wiql') {
                $global:Fake.Calls.Add('wiql')
                $ids = $global:Fake.Leftovers; $global:Fake.Leftovers = @()
                return [pscustomobject]@{ workItems = @($ids | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
            }
            if ($u -match '/_apis/wit/\$batch') {
                $requests = @($Body | ConvertFrom-Json)
                $global:Fake.Calls.Add("batch:$($requests.Count)")
                # Azure DevOps refuses a batch whose new items share a temporary ID (VS403357).
                $tempIds = @($requests | ForEach-Object { @($_.body | Where-Object { $_.path -eq '/id' })[0].value })
                if (@($tempIds | Where-Object { $null -eq $_ }).Count -gt 0 -or @($tempIds | Select-Object -Unique).Count -ne $requests.Count) {
                    throw 'VS403357: Work items in the batch are expected to be unique'
                }
                $value = foreach ($r in $requests) {
                    $id = $global:Fake.Next; $global:Fake.Next++
                    $global:Fake.Created.Add($id)
                    [pscustomobject]@{ code = 200; body = (@{ id = $id } | ConvertTo-Json) }
                }
                return [pscustomobject]@{ count = @($value).Count; value = @($value) }
            }
            if ($u -match '/_apis/wit/workitemsdelete') {
                $req = $Body | ConvertFrom-Json
                $global:Fake.Calls.Add("destroy:$(@($req.ids).Count)")
                $req.destroy | Should -BeTrue
                foreach ($id in @($req.ids)) { $global:Fake.Destroyed.Add([int]$id) }
                return $null
            }
            throw "unexpected call: $Method $u"
        }
    }

    It 'destroys leftovers first, then creates and destroys in batches up to the target' {
        $last = & $script:Engine -OrgUrl 'https://dev.azure.com/demo' -Project 'Demo' -MinId 1450 -BatchSize 200 -Confirm:$false 6>$null

        $last | Should -Be 1449
        # leftovers found by title and destroyed before anything is created
        $global:Fake.Calls[0] | Should -Be 'wiql'
        $global:Fake.Calls[1] | Should -Be 'destroy:2'
        # first batch is a single probe; then full batches, trimmed at the end
        $batches = @($global:Fake.Calls | Where-Object { $_ -like 'batch:*' })
        $batches[0] | Should -Be 'batch:1'
        $batches[1] | Should -Be 'batch:200'
        $batches[-1] | Should -Be 'batch:49'
        # everything created was destroyed
        @($global:Fake.Created | Where-Object { $global:Fake.Destroyed -notcontains $_ }).Count | Should -Be 0
        ($global:Fake.Created | Measure-Object -Maximum).Maximum | Should -Be 1449
    }

    It 'honours -BatchSize 1 (one item per create and per destroy)' {
        $global:Fake.Leftovers = @()
        & $script:Engine -OrgUrl 'https://dev.azure.com/demo' -Project 'Demo' -MinId 1004 -BatchSize 1 -Confirm:$false 6>$null | Out-Null
        @($global:Fake.Calls | Where-Object { $_ -like 'batch:*' }) | Should -Be @('batch:1', 'batch:1', 'batch:1', 'batch:1')
        @($global:Fake.Calls | Where-Object { $_ -like 'destroy:*' }) | Should -Be @('destroy:1', 'destroy:1', 'destroy:1', 'destroy:1')
    }

    It 'creates nothing under -WhatIf' {
        & $script:Engine -OrgUrl 'https://dev.azure.com/demo' -Project 'Demo' -MinId 5000 -WhatIf 6>$null | Out-Null
        $global:Fake.Created.Count | Should -Be 0
        $global:Fake.Destroyed.Count | Should -Be 0
    }
}
