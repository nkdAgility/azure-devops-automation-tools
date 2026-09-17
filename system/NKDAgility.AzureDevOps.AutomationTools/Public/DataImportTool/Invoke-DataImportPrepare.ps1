function Invoke-DataImportPrepare {
    <#
    .SYNOPSIS
    Runs the Azure DevOps Data Import Tool 'Migrator.exe Prepare' command to generate the
    import specification and validation log for a collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$TenantDomainName,
        [string]$Region = 'CUS',
        [Parameter(Mandatory)] [string]$OutputPath,
        [string]$ConnectionString = 'Data Source=localhost;Initial Catalog=Tfs_Configuration;Integrated Security=True',
        [string]$MigratorPath
    )

    $executable = Resolve-MigratorPath -MigratorPath $MigratorPath
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-FixStep "Migrator Prepare /collection:$Collection /tenantDomainName:$TenantDomainName /region:$Region"
    & $executable Prepare "/collection:$Collection" "/tenantDomainName:$TenantDomainName" "/region:$Region" "/connectionString:$ConnectionString" "/output:$OutputPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Migrator Prepare failed with exit code $LASTEXITCODE. Check the logs under '$OutputPath'."
    }
}
