# Migrate the Team Project Data using the appropriate config file (work items, plans with or without, queries, etc.)

$pathToConfig = Get-Item -Path ".\output\validus\projects\ADB\workItemsOnly.json" -ErrorAction Stop 
$($pathToConfig.FullName)

. C:\tools\MigrationTools\devopsmigration.exe execute --config "$($pathToConfig.FullName)"

