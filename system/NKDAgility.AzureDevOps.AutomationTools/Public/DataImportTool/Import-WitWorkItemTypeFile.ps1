function Import-WitWorkItemTypeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Path,
        [string]$WitAdminPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Work item type definition '$Path' does not exist." }
    Write-FixStep "Importing work item type definition '$Path' into '$Project'"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$Path")
}
