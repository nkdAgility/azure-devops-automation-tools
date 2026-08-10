function Rename-WitField {
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
    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    $details = & $executable listfields "/collection:$Collection" "/n:$ReferenceName"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listfields failed with exit code $LASTEXITCODE. $(($details -join ' ').Trim())" }
    $currentName = foreach ($line in $details) {
        if ($line -match '^\s*Name:\s*(.+)$') { $Matches[1].Trim(); break }
    }
    if ($currentName -ceq $NewName) {
        Write-FixStep "  field is already named '$NewName' - no change"
        return
    }
    Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @(
        'changefield',
        "/collection:$Collection",
        "/n:$ReferenceName",
        "/name:$NewName",
        '/noprompt'
    )
}
