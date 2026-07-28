function Remove-WorkItemLinkType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [string]$WitAdminPath
    )

    Write-FixStep "Deleting custom link type '$ReferenceName' from the collection"
    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    $linkTypes = & $executable listlinktypes "/collection:$Collection"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listlinktypes failed with exit code $LASTEXITCODE. $(($linkTypes -join ' ').Trim())" }
    if (-not ($linkTypes | Where-Object { $_ -match [regex]::Escape($ReferenceName) })) {
        Write-FixStep "  link type '$ReferenceName' not found - no change"
        return
    }
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('deletelinktype', "/collection:$Collection", "/n:$ReferenceName", '/noprompt')
}
