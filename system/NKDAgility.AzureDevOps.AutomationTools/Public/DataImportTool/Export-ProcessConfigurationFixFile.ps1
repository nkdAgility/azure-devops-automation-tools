function Export-ProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    Write-FixStep "Exporting process configuration for '$Project' to '$Path'"
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportprocessconfig', "/collection:$Collection", "/p:$Project", "/f:$Path")
}
