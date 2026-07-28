function Add-ProcessConfigurationElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$ParentXPath,
        [Parameter(Mandatory)] [string]$ElementName
    )

    Write-FixStep "Ensuring element '$ElementName' exists under '$ParentXPath'"
    Update-ProcessConfigurationFixFile -Path $Path -Mutation {
        param($xml)
        $parent = $xml.SelectSingleNode($ParentXPath)
        if (-not $parent) { throw "Process configuration node '$ParentXPath' was not found." }
        if ($parent.SelectSingleNode($ElementName)) {
            Write-FixStep "  '$ElementName' already present - no change"
        }
        else {
            [void]$parent.AppendChild($xml.CreateElement($ElementName))
            Write-FixStep "  added '$ElementName'"
        }
    }
}
