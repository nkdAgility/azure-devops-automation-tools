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
            $parent = $node.ParentNode
            [void]$parent.RemoveChild($node)
            # Inside a WORKFLOW, a FIELD reference must carry at least one rule and
            # a FIELDS block at least one FIELD - leaving one empty fails schema
            # validation on re-import (TF237070), so prune emptied ancestors.
            while ($parent -and $parent.LocalName -in @('FIELD', 'FIELDS') -and
                -not $parent.HasChildNodes -and $parent.SelectSingleNode('ancestor::WORKFLOW')) {
                $label = if ($parent.LocalName -eq 'FIELD') { " '$($parent.GetAttribute('refname'))'" } else { '' }
                Write-FixStep "  removing now-empty <$($parent.LocalName)>$label"
                $grandparent = $parent.ParentNode
                [void]$grandparent.RemoveChild($parent)
                $parent = $grandparent
            }
        }
        Write-FixStep "  removed $($nodes.Count) rule(s)"
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")

        # Verify the server actually took the change - witadmin has been observed
        # reporting success while the import did not stick.
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $remaining = @(([xml](Get-Content -LiteralPath $file -Raw)).SelectNodes("//$Rule")).Count
        if ($remaining -gt 0) {
            throw "Verification failed: $remaining <$Rule> rule(s) still present in '$WorkItemType' after import."
        }
        Write-FixStep "  verified: no <$Rule> rules remain in '$WorkItemType'"
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
