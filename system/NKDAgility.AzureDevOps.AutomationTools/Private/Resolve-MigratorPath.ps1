function Resolve-MigratorPath {
    [CmdletBinding()]
    param([string]$MigratorPath)

    if ($MigratorPath) {
        if (Test-Path -LiteralPath $MigratorPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $MigratorPath).Path
        }
        throw "Unable to find Migrator.exe at '$MigratorPath'."
    }

    $command = Get-Command 'Migrator.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'Unable to find Migrator.exe. Pass -MigratorPath or set it with Set-MigrationContext.'
}
