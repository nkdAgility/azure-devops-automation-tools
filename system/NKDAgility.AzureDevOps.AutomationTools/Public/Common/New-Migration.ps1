function New-Migration {
    <#
    .SYNOPSIS
    Scaffolds a new numbered migration folder in the customer workspace from a template.

    .DESCRIPTION
    Creates migrations\NN-<Name>\ (NN = next free number) in the workspace and copies the
    matching template from the tools repo's templates\migrations\<type>\ folder:

      DataImport        - Microsoft Data Import Tool (Migrator.exe) collection lift-and-shift:
                          DataImport-Scratchbook.ps1 + DataImport-Cleanup.ps1
      MigrationTools    - Azure DevOps Migration Tools engagement: Sync.ps1 orchestrator,
                          Run-Migrate-Repos/Artifacts binders, configuration-*.json
      MigrationPlatform - Azure DevOps Migration Platform engagement: Sync.ps1 + platform-config.json

    .PARAMETER Name
    Migration name; becomes the folder suffix (e.g. 'CollectionImport' -> '01-CollectionImport').

    .PARAMETER Type
    Which template to scaffold: DataImport, MigrationTools or MigrationPlatform.

    .PARAMETER Path
    Workspace root. Defaults to the initialised workspace.

    .EXAMPLE
    New-Migration -Name 'CollectionImport' -Type DataImport
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('DataImport', 'MigrationTools', 'MigrationPlatform')]
        [string]$Type,

        [string]$Path
    )

    if (-not $Path) {
        $Path = (Get-AutomationWorkspace).Root
    }

    $templateFolderNames = @{
        DataImport        = 'data-import'
        MigrationTools    = 'migration-tools'
        MigrationPlatform = 'migration-platform'
    }
    # templates\migrations\<type> lives in the tools repo root, two levels above the module
    # base (<tools>\system\<module>).
    $moduleBase = (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools').ModuleBase
    $toolsRoot = Split-Path -Parent (Split-Path -Parent $moduleBase)
    $templatePath = Join-Path $toolsRoot (Join-Path 'templates\migrations' $templateFolderNames[$Type])
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Migration template not found: $templatePath"
    }

    $migrationsFolder = Join-Path $Path 'migrations'
    New-Item -Path $migrationsFolder -ItemType Directory -Force | Out-Null

    # Next free NN- prefix across existing migration folders.
    $existingNumbers = Get-ChildItem -Path $migrationsFolder -Directory |
        Where-Object { $_.Name -match '^(\d+)-' } |
        ForEach-Object { [int]$Matches[1] }
    $next = if ($existingNumbers) { [int]($existingNumbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $migrationFolder = Join-Path $migrationsFolder ('{0:D2}-{1}' -f $next, $Name)
    if (Test-Path -LiteralPath $migrationFolder) {
        throw "Migration folder already exists: $migrationFolder"
    }

    Copy-Item -Path $templatePath -Destination $migrationFolder -Recurse
    Write-FixStep "Created $migrationFolder ($Type)"
    Get-ChildItem -Path $migrationFolder -Recurse -File -Name | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }

    return Get-Item -LiteralPath $migrationFolder
}
