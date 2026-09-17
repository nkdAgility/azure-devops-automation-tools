function Invoke-DataImportValidate {
    <#
    .SYNOPSIS
    Runs the Azure DevOps Data Import Tool 'Migrator.exe Validate' command against a collection.

    .DESCRIPTION
    TenantDomainName and Region are optional; when supplied the migrator also performs the
    identity (Entra ID) validation checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$TenantDomainName,
        [string]$Region,
        [string]$ConnectionString,
        [string]$MigratorPath
    )

    $executable = Resolve-MigratorPath -MigratorPath $MigratorPath
    $arguments = @('Validate', "/collection:$Collection")
    if ($TenantDomainName) { $arguments += "/tenantDomainName:$TenantDomainName" }
    if ($Region) { $arguments += "/region:$Region" }
    if ($ConnectionString) { $arguments += "/connectionString:$ConnectionString" }

    Write-FixStep "Migrator $($arguments -join ' ')"
    & $executable @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Migrator Validate failed with exit code $LASTEXITCODE."
    }
}
