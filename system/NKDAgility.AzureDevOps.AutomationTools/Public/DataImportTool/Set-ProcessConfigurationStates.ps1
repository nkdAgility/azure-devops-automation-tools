function Set-ProcessConfigurationStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$BacklogElement,
        [Parameter(Mandatory)] [hashtable[]]$States
    )

    Write-FixStep "Replacing States on '$BacklogElement' with $($States.Count) state(s): $(($States | ForEach-Object { "$($_.Type)=$($_.Value)" }) -join ', ')"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $backlog = $xml.ProjectProcessConfiguration.SelectSingleNode($BacklogElement)
        if (-not $backlog) { throw "Process configuration element '$BacklogElement' was not found." }
        $existing = $backlog.SelectSingleNode('States')
        if ($existing) {
            Write-FixStep "  removing $($existing.ChildNodes.Count) existing state(s)"
            [void]$backlog.RemoveChild($existing)
        }
        $statesNode = $xml.CreateElement('States')
        foreach ($state in $States) {
            $stateNode = $xml.CreateElement('State')
            $stateNode.SetAttribute('type', [string]$state.Type)
            $stateNode.SetAttribute('value', [string]$state.Value)
            [void]$statesNode.AppendChild($stateNode)
        }
        [void]$backlog.PrependChild($statesNode)
    }
}
