function Set-MigrationContext {
    <#
    .SYNOPSIS
    Sets session-wide defaults (collection, project, tool paths) for all module commands.

    .DESCRIPTION
    Values are applied via $Global:PSDefaultParameterValues so runbook lines do not need to
    repeat -Collection etc. on every call. -Project is only defaulted on commands where it
    is mandatory, so commands with an optional -Project (e.g. Find-GlobalWorkflowRuleScope)
    keep their collection-scope behaviour unless -Project is passed explicitly.

    .EXAMPLE
    Set-MigrationContext -Collection 'http://tfs:8080/tfs/DefaultCollection/' -MigratorPath 'C:\tools\DataMigrationTool\Migrator.exe'
    Rename-Field -ReferenceName 'System.AreaId' -NewName 'Area ID'
    #>
    [CmdletBinding()]
    param(
        [string]$Collection,
        [string]$Project,
        [string]$WitAdminPath,
        [string]$MigratorPath,
        [string]$CheckpointPath
    )

    if (-not $script:MigrationContext) { $script:MigrationContext = @{} }

    foreach ($name in 'Collection', 'Project', 'WitAdminPath', 'MigratorPath', 'CheckpointPath') {
        if ($PSBoundParameters.ContainsKey($name)) {
            $script:MigrationContext[$name] = $PSBoundParameters[$name]
        }
    }

    $commands = Get-Command -Module 'NKDAgility.AzureDevOps.AutomationTools' -CommandType Function
    foreach ($command in $commands) {
        foreach ($name in @($script:MigrationContext.Keys)) {
            if (-not $command.Parameters.ContainsKey($name)) { continue }
            if ($name -eq 'Project') {
                $isMandatory = $command.Parameters[$name].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
                if (-not $isMandatory) { continue }
            }
            $Global:PSDefaultParameterValues["$($command.Name):$name"] = $script:MigrationContext[$name]
        }
    }

    Write-FixStep "Migration context set: $(($script:MigrationContext.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')"
}
