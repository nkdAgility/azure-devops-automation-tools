function Get-MigrationContext {
    <#
    .SYNOPSIS
    Returns the current migration context set by Set-MigrationContext.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:MigrationContext) { $script:MigrationContext = @{} }
    [pscustomobject]@{
        Collection     = $script:MigrationContext['Collection']
        Project        = $script:MigrationContext['Project']
        WitAdminPath   = $script:MigrationContext['WitAdminPath']
        MigratorPath   = $script:MigrationContext['MigratorPath']
        CheckpointPath = $script:MigrationContext['CheckpointPath']
    }
}
