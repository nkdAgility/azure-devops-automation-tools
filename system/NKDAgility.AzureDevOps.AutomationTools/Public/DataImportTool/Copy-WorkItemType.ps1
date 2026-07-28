function Copy-WorkItemType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$SourceProject,
        [Parameter(Mandatory)] [string]$TargetProject,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [string]$WitAdminPath
    )

    Write-FixStep "Copying work item type '$WorkItemType' from '$SourceProject' to '$TargetProject'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$SourceProject", "/n:$WorkItemType", "/f:$file")
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$TargetProject", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
