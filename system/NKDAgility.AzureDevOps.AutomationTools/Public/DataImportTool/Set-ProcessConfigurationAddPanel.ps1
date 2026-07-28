function Set-ProcessConfigurationAddPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [string[]]$Fields
    )

    Write-FixStep "Replacing AddPanel on '$BacklogElement' with field(s): $($Fields -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('AddPanel')
        if ($existing) {
            Write-FixStep '  removing existing AddPanel'
            [void]$backlog.RemoveChild($existing)
        }
        $panel = $xml.CreateElement('AddPanel')
        $fieldsNode = $xml.CreateElement('Fields')
        foreach ($field in $Fields) {
            $fieldNode = $xml.CreateElement('Field')
            $fieldNode.SetAttribute('refname', $field)
            [void]$fieldsNode.AppendChild($fieldNode)
        }
        [void]$panel.AppendChild($fieldsNode)
        [void]$backlog.AppendChild($panel)
    }
}
