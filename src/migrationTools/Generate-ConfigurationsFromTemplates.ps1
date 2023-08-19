# Generate Team Project migration configuration files for enabled collections in processFieldMigrator\data\organisations.json
clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

Write-InfoLog "\\Generate-MigrationToolsConfigurations"
foreach ($organisation in $config.organisations) {
    if ($organisation.enabled -eq $false) {
        Write-InfoLog "Skipping $($organisation.url)"
        continue
    }
    $sanitisedOrgname = $($organisation.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
    $configLocation = "$dataFolder\templates\"

    $temptoken = $null
    $header = $null
    $temptoken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($organisation.pat)"))
    $header = @{authorization = "Basic $temptoken" }

    #GET https://dev.azure.com/{organization}/_apis/projects?api-version=7.0
    $callUrl = "$($organisation.url)/_apis/projects?$queryString"
    $projects = Invoke-RestMethod -Uri $callUrl -Method Get -ContentType "application/json" -Headers $header
    Write-InfoLog "Found $($projects.count) projects"
    foreach ($project in $projects.value) {
        $filepath = "$outputFolder\$sanitisedOrgname\projects\$($project.name)"
        New-item $filepath -ItemType Directory -force

        $configFiles = Get-ChildItem -Path $configLocation -Filter "*.json"
        Write-InfoLog "Found $($configFiles.count) config files"
        foreach ($configFile in $configFiles) {
        
            $migrationConfig = $null
            $migrationConfig = Get-Content $configFile.FullName | ConvertFrom-Json -Depth 100
            if ($null -eq $migrationConfig.Endpoints) {
                $migrationConfig.Source.Project = $project.name
                $migrationConfig.Source.Collection = $organisation.url
                $migrationConfig.Source.PersonalAccessToken = $organisation.pat
                $migrationConfig.Target.Project = $project.name
            }
            else {

                $migrationConfig.Endpoints[0].TfsEndpoints[0].Project = $project.name
                $migrationConfig.Endpoints[0].TfsEndpoints[0].Organisation = $organisation.url
                $migrationConfig.Endpoints[0].TfsEndpoints[0].AccessToken = $organisation.pat
                $migrationConfig.Endpoints[0].TfsEndpoints[1].Project = $project.name
            }
        
            $filename = "$filepath\$($configFile.Name)"

            Out-File -FilePath $filename -InputObject ($migrationConfig | ConvertTo-Json -Depth 100) -Encoding ascii
        }
    }

}

Write-InfoLog "Done"

