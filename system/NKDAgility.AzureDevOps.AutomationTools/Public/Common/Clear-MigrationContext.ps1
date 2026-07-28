function Clear-MigrationContext {
    <#
    .SYNOPSIS
    Clears the migration context and removes the defaults it added to $Global:PSDefaultParameterValues.
    #>
    [CmdletBinding()]
    param()

    $commandNames = (Get-Command -Module 'NKDAgility.AzureDevOps.AutomationTools' -CommandType Function).Name
    $keys = @($Global:PSDefaultParameterValues.Keys | Where-Object { ($_ -split ':')[0] -in $commandNames })
    foreach ($key in $keys) {
        $Global:PSDefaultParameterValues.Remove($key)
    }
    $script:MigrationContext = @{}
    Write-FixStep 'Migration context cleared'
}
