# Migrate the Team Project Data using the appropriate config file (work items, plans with or without, queries, etc.)
cls
$pathToConfig = Get-Item -Path ".\output\validus\projects\VCAPS2-Contract\workItemsOnly.json" -ErrorAction Stop 
$($pathToConfig.FullName)

. C:\tools\MigrationTools\devopsmigration.exe execute --config "$($pathToConfig.FullName)"

