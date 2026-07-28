function Remove-WorkItemLinkType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [string]$WitAdminPath
    )

    Write-FixStep "Deleting custom link type '$ReferenceName' from the collection"
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('deletelinktype', "/collection:$Collection", "/n:$ReferenceName", '/noprompt')
}
