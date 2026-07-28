function Rename-Field {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$ReferenceName,

        [Parameter(Mandatory)]
        [string]$NewName,

        [string]$WitAdminPath
    )

    Write-FixStep "Renaming field '$ReferenceName' to '$NewName' in $Collection"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @(
        'changefield',
        "/collection:$Collection",
        "/n:$ReferenceName",
        "/name:$NewName",
        '/noprompt'
    )
}
