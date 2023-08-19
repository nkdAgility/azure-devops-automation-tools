# Migrate the Team Project Data using the appropriate config file (work items, plans with or without, queries, etc.)

$pathToConfig = Get-Item -Path ".\output\nkdagility-learn\Projects\Fabrikam\workItemsOnly.json" -ErrorAction Stop 


. C:\tools\MigrationTools\migration.exe execute --config "$($pathToConfig.FullName)"

