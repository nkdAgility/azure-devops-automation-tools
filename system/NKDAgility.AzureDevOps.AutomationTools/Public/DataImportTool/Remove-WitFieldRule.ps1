function Remove-WitFieldRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [Parameter(Mandatory)] [ValidateSet('NOTSAMEAS', 'PROHIBITEDVALUES', 'CANNOTLOSEVALUE', 'MATCH')] [string]$Rule,
        [string]$WitAdminPath
    )

    Write-FixStep "Removing all <$Rule> rules from work item type '$WorkItemType' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $nodes = @($xml.SelectNodes("//$Rule"))
        if ($nodes.Count -eq 0) {
            Write-FixStep "  no <$Rule> rules found - no change"
            return
        }
        foreach ($node in $nodes) {
            $field = $node.SelectSingleNode('ancestor::*[@refname]')
            Write-FixStep "  removing <$Rule> from field '$(if ($field) { $field.GetAttribute('refname') } else { 'unknown' })'"
            [void]$node.ParentNode.RemoveChild($node)
        }
        Write-FixStep "  removed $($nodes.Count) rule(s)"
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
