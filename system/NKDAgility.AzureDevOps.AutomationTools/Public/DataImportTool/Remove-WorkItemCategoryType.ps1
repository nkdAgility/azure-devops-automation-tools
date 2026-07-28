function Remove-WorkItemCategoryType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Removing work item type '$WorkItemType' from category '$ReferenceName' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if (-not $category) { throw "Category '$ReferenceName' was not found in '$Project'." }

        $default = $category.SelectSingleNode("*[local-name()='DEFAULTWORKITEMTYPE'][@name='$WorkItemType']")
        if ($default) { throw "'$WorkItemType' is the DEFAULTWORKITEMTYPE of '$ReferenceName' and cannot be removed." }

        $node = $category.SelectSingleNode("*[local-name()='WORKITEMTYPE'][@name='$WorkItemType']")
        if (-not $node) {
            Write-FixStep "  '$WorkItemType' is not a member of '$ReferenceName' - no change"
            return
        }
        [void]$category.RemoveChild($node)
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
