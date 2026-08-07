function New-Migration {
    <#
    .SYNOPSIS
    Scaffolds a new numbered migration folder in the customer workspace from a template.

    .DESCRIPTION
    Creates migrations\NN-<Name>\ (NN = next free number) in the workspace and copies the
    matching template from the module's own Templates\migrations\<type>\ folder:

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
    # Templates ship inside the module so they travel with it when it is copied into a
    # client workspace, and stay locked to the engine version that consumes them. Never
    # resolve them by walking up from the module root - above it is the client's repo.
    $templatePath = Join-Path $script:ModuleRoot (Join-Path 'Templates\migrations' $templateFolderNames[$Type])
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

    # Seed provenance. Engagement folders are copied once and then owned and edited by
    # the engagement, so template improvements never reach them. Recording what produced
    # this one is what lets you tell, years later, why it does not match today's template.
    @{
        type          = $Type
        template      = $templateFolderNames[$Type]
        moduleVersion = [string]$MyInvocation.MyCommand.Module.Version
        scaffoldedAt  = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $migrationFolder '.template.json')

    Write-FixStep "Created $migrationFolder ($Type)"
    Get-ChildItem -Path $migrationFolder -Recurse -File -Name | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }

    return Get-Item -LiteralPath $migrationFolder
}
