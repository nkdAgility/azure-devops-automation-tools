function Set-ProcessConfigurationAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$XPath,
        [Parameter(Mandatory)] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Value
    )

    Write-FixStep "Setting @$AttributeName='$Value' on '$XPath'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $node = $xml.SelectSingleNode($XPath)
        if (-not $node) { throw "Process configuration node '$XPath' was not found." }
        Write-FixStep "  previous value: '$($node.GetAttribute($AttributeName))'"
        $node.SetAttribute($AttributeName, $Value)
    }
}
