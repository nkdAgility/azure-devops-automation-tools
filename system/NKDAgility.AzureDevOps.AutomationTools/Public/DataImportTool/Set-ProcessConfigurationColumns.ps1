function Set-ProcessConfigurationColumns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [hashtable[]]$Columns
    )

    Write-FixStep "Replacing Columns on '$BacklogElement' with $($Columns.Count) column(s): $(($Columns | ForEach-Object { $_.ReferenceName }) -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('Columns')
        if ($existing) {
            Write-FixStep "  removing $($existing.ChildNodes.Count) existing column(s)"
            [void]$backlog.RemoveChild($existing)
        }
        $columnsNode = $xml.CreateElement('Columns')
        foreach ($column in $Columns) {
            $columnNode = $xml.CreateElement('Column')
            $columnNode.SetAttribute('refname', [string]$column.ReferenceName)
            $columnNode.SetAttribute('width', [string]$column.Width)
            [void]$columnsNode.AppendChild($columnNode)
        }
        [void]$backlog.AppendChild($columnsNode)
    }
}
