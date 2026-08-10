function Remove-WitWorkItemLinkType {
    <#
    .SYNOPSIS
    Deletes a custom work item link type from the collection, recording its links first.

    .DESCRIPTION
    Azure DevOps Services does not accept custom link types, so the Data Import Tool requires
    them to be removed from the source collection before import. witadmin deletelinktype deletes
    every link of that type along with the definition, and those relationships cannot be
    recovered - so this command exports an inventory of them first and refuses to delete if that
    export fails. Pass -NoExport to delete without a record.

    Idempotent: a link type that is already absent reports "no change" and skips both the export
    and the delete.

    .PARAMETER ReferenceName
    The link type reference name, without an end suffix - e.g. 'Custom.Affects', not
    'Custom.Affects-Forward'.

    .PARAMETER ExportPath
    Destination .json file for the link inventory. Defaults to today's export snapshot for the
    collection (see Export-WorkItemLinkInventory).

    .PARAMETER NoExport
    Skip the inventory and delete the link type outright. The relationships are unrecoverable.

    .PARAMETER Pat
    Personal access token for the inventory's REST calls. Omit to use the current Windows
    identity, which is the normal case on-premises.

    .EXAMPLE
    Remove-WitWorkItemLinkType -Collection $collection -ReferenceName 'Custom.Affects'

    .EXAMPLE
    Remove-WitWorkItemLinkType -Collection $collection -ReferenceName 'Custom.Affects' -ExportPath "$snapshot\json\affects-links.json"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [string]$ExportPath,
        [switch]$NoExport,
        [string]$Pat,
        [string]$ApiVersion = '5.0',
        [string]$WitAdminPath
    )

    Write-FixStep "Deleting custom link type '$ReferenceName' from the collection"
    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    $linkTypes = & $executable listlinktypes "/collection:$Collection"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listlinktypes failed with exit code $LASTEXITCODE. $(($linkTypes -join ' ').Trim())" }
    # Anchored on word boundaries: a substring match would treat 'Custom.Affects'
    # as present when only 'Custom.AffectsMore' exists, and go on to export and
    # delete a link type that is not there.
    $pattern = '(^|\s)' + [regex]::Escape($ReferenceName) + '(\s|$)'
    if (-not ($linkTypes | Where-Object { $_ -match $pattern })) {
        Write-FixStep "  link type '$ReferenceName' not found - no change"
        return
    }

    if ($NoExport) {
        Write-Warning "Deleting link type '$ReferenceName' without an inventory (-NoExport). Its links will be unrecoverable."
    }
    else {
        try {
            $inventory = Export-WorkItemLinkInventory -Collection $Collection -ReferenceName $ReferenceName `
                -Path $ExportPath -Pat $Pat -ApiVersion $ApiVersion
        }
        catch {
            throw "Refusing to delete link type '$ReferenceName': its links could not be recorded first. Fix the export, or pass -NoExport to accept losing them. $_"
        }
        Write-FixStep "  $($inventory.LinkCount) link(s) recorded in $($inventory.JsonPath)"
    }

    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('deletelinktype', "/collection:$Collection", "/n:$ReferenceName", '/noprompt')
}
