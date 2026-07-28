function Add-ProcessConfigurationTypeField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [string]$Format,
        [hashtable[]]$Values
    )

    Write-FixStep "Setting TypeField type='$Type' to refname='$ReferenceName'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $root = $xml.ProjectProcessConfiguration
        $typeFields = $root.SelectSingleNode('TypeFields')
        if (-not $typeFields) {
            $typeFields = $xml.CreateElement('TypeFields')
            [void]$root.PrependChild($typeFields)
            Write-FixStep '  created missing TypeFields element'
        }
        $node = $typeFields.SelectSingleNode("TypeField[@type='$Type']")
        if (-not $node) {
            $node = $xml.CreateElement('TypeField')
            [void]$typeFields.AppendChild($node)
            Write-FixStep "  added TypeField type='$Type'"
        }
        else {
            Write-FixStep "  updating existing TypeField (was refname='$($node.GetAttribute('refname'))')"
        }
        $node.SetAttribute('refname', $ReferenceName)
        $node.SetAttribute('type', $Type)
        if ($Format) {
            Write-FixStep "  setting format='$Format'"
            $node.SetAttribute('format', $Format)
        }
        if ($Values) {
            Write-FixStep "  setting $($Values.Count) TypeFieldValue(s): $(($Values | ForEach-Object { "$($_.Type)=$($_.Value)" }) -join ', ')"
            $existingValues = $node.SelectSingleNode('TypeFieldValues')
            if ($existingValues) { [void]$node.RemoveChild($existingValues) }
            $valuesNode = $xml.CreateElement('TypeFieldValues')
            foreach ($value in $Values) {
                $valueNode = $xml.CreateElement('TypeFieldValue')
                $valueNode.SetAttribute('type', [string]$value.Type)
                $valueNode.SetAttribute('value', [string]$value.Value)
                [void]$valuesNode.AppendChild($valueNode)
            }
            [void]$node.AppendChild($valuesNode)
        }
    }
}
