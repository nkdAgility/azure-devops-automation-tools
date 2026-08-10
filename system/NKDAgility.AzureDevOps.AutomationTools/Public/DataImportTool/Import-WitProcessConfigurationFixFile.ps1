function Import-WitProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    Write-FixStep "Importing process configuration '$Path' into '$Project'"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importprocessconfig', "/collection:$Collection", "/p:$Project", "/f:$Path")
}
