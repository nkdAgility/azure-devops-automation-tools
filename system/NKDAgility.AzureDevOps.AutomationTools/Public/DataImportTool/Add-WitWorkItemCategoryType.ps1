function Add-WitWorkItemCategoryType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Adding work item type '$WorkItemType' to category '$ReferenceName' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if (-not $category) { throw "Category '$ReferenceName' was not found in '$Project'." }

        $member = $category.SelectSingleNode("*[@name='$WorkItemType']")
        if ($member) {
            Write-FixStep "  '$WorkItemType' is already a member of '$ReferenceName' - no change"
            return
        }
        $node = $xml.CreateElement('WORKITEMTYPE')
        $node.SetAttribute('name', $WorkItemType)
        [void]$category.AppendChild($node)
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
