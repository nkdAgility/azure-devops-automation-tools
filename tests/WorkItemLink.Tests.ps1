#Requires -Modules Pester

# Covers the REST link-inventory commands against a stubbed transport. The stub
# replaces the module's private Invoke-AzureDevOpsApi, so everything above it -
# link type filtering, WIQL parsing, enrichment, comment matching, file output -
# is exercised for real without touching a collection.

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\NKDAgility.AzureDevOps.AutomationTools.psd1'
    Import-Module $manifest -Force
    $script:Module = Get-Module NKDAgility.AzureDevOps.AutomationTools
    $script:Collection = 'https://tfs/col'

    # Defined with the script: scope modifier so it lands in the module's own
    # scope; a plain function inside & { } would go to a child scope and vanish.
    & $script:Module {
        $script:RelationTypes = @'
{ "value": [
  { "name": "Related",     "referenceName": "System.LinkTypes.Related",  "attributes": { "usage": "workItemLink", "topology": "network",    "editable": false, "enabled": true } },
  { "name": "Affects",     "referenceName": "Custom.Affects-Forward",    "attributes": { "usage": "workItemLink", "topology": "dependency", "editable": true,  "enabled": true } },
  { "name": "Affected By", "referenceName": "Custom.Affects-Reverse",    "attributes": { "usage": "workItemLink", "topology": "dependency", "editable": true,  "enabled": true } },
  { "name": "Mitigates",   "referenceName": "Custom.Mitigates",          "attributes": { "usage": "workItemLink", "topology": "network",    "editable": true,  "enabled": true } },
  { "name": "Attachment",  "referenceName": "AttachedFile",              "attributes": { "usage": "resource" } }
] }
'@
        $script:WorkItems = @'
{ "value": [
  { "id": 10, "fields": { "System.TeamProject": "Mammoth",  "System.WorkItemType": "Bug",  "System.Title": "Login fails", "System.State": "Active" },
    "relations": [ { "rel": "Custom.Affects-Forward", "url": "https://tfs/col/_apis/wit/workItems/20", "attributes": { "comment": "blocks release" } },
                   { "rel": "Custom.Affects-Forward", "url": "https://tfs/col/_apis/wit/workItems/30", "attributes": {} } ] },
  { "id": 20, "fields": { "System.TeamProject": "Mammoth",  "System.WorkItemType": "Task", "System.Title": "Patch auth",  "System.State": "New" },  "relations": [] },
  { "id": 30, "fields": { "System.TeamProject": "Whistler", "System.WorkItemType": "Epic", "System.Title": "Identity",    "System.State": "New" },  "relations": [] },
  { "id": 40, "fields": { "System.TeamProject": "Whistler", "System.WorkItemType": "Risk", "System.Title": "Data loss",   "System.State": "Open" },
    "relations": [ { "rel": "Custom.Mitigates", "url": "https://tfs/col/_apis/wit/workItems/20", "attributes": { "comment": "mitigation plan" } } ] }
] }
'@
        function script:Invoke-AzureDevOpsApi {
            param($Collection, $Path, $Method = 'Get', $ApiVersion, $Query, $Body, $Pat)

            if ($Path -eq '_apis/wit/workitemrelationtypes') { return $script:RelationTypes | ConvertFrom-Json }

            if ($Path -like '*_apis/wit/wiql') {
                # MustContain returns a seed row per source with rel = null ahead
                # of the real link rows.
                if ($Body.query -match 'Custom\.Affects-Forward') {
                    return '{ "workItemRelations": [
                        { "rel": null, "source": null, "target": { "id": 10 } },
                        { "rel": "Custom.Affects-Forward", "source": { "id": 10 }, "target": { "id": 20 } },
                        { "rel": "Custom.Affects-Forward", "source": { "id": 10 }, "target": { "id": 30 } } ] }' | ConvertFrom-Json
                }
                if ($Body.query -match 'Custom\.Mitigates') {
                    return '{ "workItemRelations": [
                        { "rel": null, "source": null, "target": { "id": 40 } },
                        { "rel": "Custom.Mitigates", "source": { "id": 40 }, "target": { "id": 20 } } ] }' | ConvertFrom-Json
                }
                return '{ "workItemRelations": [] }' | ConvertFrom-Json
            }

            if ($Path -eq '_apis/wit/workitems') {
                $wanted = $Query.ids -split ',' | ForEach-Object { [int]$_ }
                $all = ($script:WorkItems | ConvertFrom-Json).value
                return [pscustomobject]@{ value = @($all | Where-Object { $_.id -in $wanted }) }
            }

            throw "unexpected path: $Path"
        }
    }
}

Describe 'Get-WorkItemLinkType' {

    It 'returns custom work item link ends only, excluding System and resource usage' {
        $custom = @(Get-WorkItemLinkType -Collection $script:Collection -CustomOnly)
        $custom.Count | Should -Be 3
        $custom.ReferenceName | Should -Not -Contain 'System.LinkTypes.Related'
        $custom.ReferenceName | Should -Not -Contain 'AttachedFile'
    }

    It 'flags the reverse end' {
        $reverse = @(Get-WorkItemLinkType -Collection $script:Collection -CustomOnly | Where-Object IsReverse)
        $reverse.ReferenceName | Should -Be 'Custom.Affects-Reverse'
    }

    It 'matches both ends from a bare reference name' {
        @(Get-WorkItemLinkType -Collection $script:Collection -ReferenceName 'Custom.Affects').Count | Should -Be 2
    }
}

Describe 'Get-WorkItemLink' {

    BeforeAll { $script:Links = @(Get-WorkItemLink -Collection $script:Collection) }

    It 'queries forward ends only, so each link appears once' {
        $script:Links.Count | Should -Be 3
    }

    It 'resolves both endpoints' {
        $link = $script:Links | Where-Object { $_.SourceId -eq 10 -and $_.TargetId -eq 20 }
        $link.SourceTitle | Should -Be 'Login fails'
        $link.SourceType | Should -Be 'Bug'
        $link.TargetTitle | Should -Be 'Patch auth'
    }

    It 'captures a cross-project target' {
        $link = $script:Links | Where-Object { $_.TargetId -eq 30 }
        $link.SourceProject | Should -Be 'Mammoth'
        $link.TargetProject | Should -Be 'Whistler'
    }

    It 'matches the comment to the right relation' {
        ($script:Links | Where-Object { $_.TargetId -eq 20 -and $_.SourceId -eq 10 }).Comment | Should -Be 'blocks release'
    }

    It 'leaves the comment empty rather than borrowing a sibling link''s' {
        ($script:Links | Where-Object { $_.TargetId -eq 30 }).Comment | Should -BeNullOrEmpty
    }

    It 'handles a single link, where property access yields scalars not arrays' {
        $single = @(Get-WorkItemLink -Collection $script:Collection -ReferenceName 'Custom.Mitigates')
        $single.Count | Should -Be 1
        $single[0].SourceTitle | Should -Be 'Data loss'
        $single[0].TargetTitle | Should -Be 'Patch auth'
        $single[0].Comment | Should -Be 'mitigation plan'
    }

    It 'throws on a link type that does not exist' {
        { Get-WorkItemLink -Collection $script:Collection -ReferenceName 'Nope.Missing' } |
            Should -Throw -ExpectedMessage '*No work item link type*'
    }
}

Describe 'Export-WorkItemLinkInventory' {

    BeforeAll {
        $script:OutDir = Join-Path ([System.IO.Path]::GetTempPath()) ('linkinv-' + [guid]::NewGuid().ToString('N'))
        $script:JsonPath = Join-Path $script:OutDir 'WorkItemLinks.json'
        $script:Result = Export-WorkItemLinkInventory -Collection $script:Collection -Path $script:JsonPath
    }

    It 'writes the json record and the csv sibling' {
        Test-Path $script:JsonPath | Should -BeTrue
        Test-Path $script:Result.CsvPath | Should -BeTrue
    }

    It 'records the collection, link types and every link' {
        $json = Get-Content $script:JsonPath -Raw | ConvertFrom-Json
        $json.collection | Should -Be $script:Collection
        $json.linkCount | Should -Be 3
        $json.links.Count | Should -Be 3
        $json.linkTypes.Count | Should -Be 3
    }

    It 'writes one csv row per link' {
        @(Import-Csv $script:Result.CsvPath).Count | Should -Be 3
    }

    It 'still writes a file when there are no links of that type' {
        $empty = Join-Path $script:OutDir 'none.json'
        $result = Export-WorkItemLinkInventory -Collection $script:Collection -ReferenceName 'Custom.Affects-Reverse' -Path $empty
        $result.LinkCount | Should -Be 0
        Test-Path $empty | Should -BeTrue -Because 'the step must leave proof it ran even when nothing was found'
    }
}
