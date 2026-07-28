function Add-WorkItemCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$ReferenceName,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$DefaultWorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Ensuring category '$ReferenceName' ('$Name') exists in '$Project' with default type '$DefaultWorkItemType'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Categories.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $category = $xml.SelectSingleNode("//*[local-name()='CATEGORY'][@refname='$ReferenceName']")
        if ($category) {
            Write-FixStep "  category '$ReferenceName' already exists - no change"
        }
        else {
            Write-FixStep "  category '$ReferenceName' missing - adding it"
            $category = $xml.CreateElement('CATEGORY')
            $category.SetAttribute('refname', $ReferenceName)
            $category.SetAttribute('name', $Name)
            $default = $xml.CreateElement('DEFAULTWORKITEMTYPE')
            $default.SetAttribute('name', $DefaultWorkItemType)
            [void]$category.AppendChild($default)
            [void]$xml.DocumentElement.AppendChild($category)
            $xml.Save($file)
            Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importcategories', "/collection:$Collection", "/p:$Project", "/f:$file")
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
