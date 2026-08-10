function Find-WitGlobalWorkflowRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Project,
        [string]$WitAdminPath
    )

    $scope = if ($Project) { "project '$Project'" } else { 'the collection' }
    Write-FixStep "Scanning the global workflow for $scope"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).GlobalWorkflow.xml"
    try {
        $arguments = @('exportglobalworkflow', "/collection:$Collection")
        if ($Project) { $arguments += "/p:$Project" }
        $arguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $arguments

        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        foreach ($node in $xml.SelectNodes('//*[@for or @not]')) {
            $field = $node.SelectSingleNode('ancestor::*[@refname]')
            [pscustomobject]@{
                Scope = if ($Project) { $Project } else { 'Collection' }
                Rule  = $node.Name
                Field = if ($field) { $field.GetAttribute('refname') } else { '' }
                For   = $node.GetAttribute('for')
                Not   = $node.GetAttribute('not')
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
