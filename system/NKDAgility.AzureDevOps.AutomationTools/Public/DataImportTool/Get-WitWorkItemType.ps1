function Get-WitWorkItemType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "Listing work item types in '$Project'"
    $types = & $executable listwitd "/collection:$Collection" "/p:$Project"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listwitd failed with exit code $LASTEXITCODE." }
    $types | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
}
