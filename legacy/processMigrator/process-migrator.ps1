# Migrate a process template

$pathToConfig = Get-Item -Path ".\configuration.json" -ErrorAction Stop 

. process-migrator --config="$($pathToConfig.FullName)"

