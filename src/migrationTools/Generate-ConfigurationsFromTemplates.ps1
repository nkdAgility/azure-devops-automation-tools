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

    # Determine template folder with fallbacks:
    # 1. Environment specific (current data folder)
    # 2. 'sample' environment
    # 3. 'debug' environment
    # 4. Root data folder 'templates' (if ever added later)
    $candidateTemplatePaths = @(
        (Join-Path $dataFolder 'templates'),
        (Join-Path (Join-Path (Split-Path -Path $dataFolder -Parent) 'sample') 'templates'),
        (Join-Path (Join-Path (Split-Path -Path $dataFolder -Parent) 'debug') 'templates')
    ) | Select-Object -Unique

    $configLocation = $null
    foreach ($candidate in $candidateTemplatePaths) {
        if (Test-Path $candidate) {
            $configLocation = $candidate
            Write-InfoLog "Using template directory {templateDir}" -PropertyValues $configLocation
            break
        }
        else {
            Write-DebugLog "Template directory missing: {candidate}" -PropertyValues $candidate
        }
    }

    if (-not $configLocation) {
        Write-InfoLog "No template directory found in candidates. Skipping organisation {org}" -PropertyValues $organisation.url
        continue
    }

    # PAT available as $organisation.pat if future template logic needs it

    #GET https://dev.azure.com/{organization}/_apis/projects?api-version=7.0
    #$callUrl = "$($organisation.url)/_apis/projects?$queryString"
    #$projects = Invoke-RestMethod -Uri $callUrl -Method Get -ContentType "application/json" -Headers $header
    if (-not $organisation.projects -or $organisation.projects.Count -eq 0) {
        Write-InfoLog "Organisation {org} has no projects configured. Skipping." -PropertyValues $organisation.url
        continue
    }
    Write-InfoLog "Found $($organisation.projects.count) projects"
    foreach ($project in $organisation.projects) {
        $filepath = "$outputFolder\$sanitisedOrgname\projects\$($project.name)"
        New-item $filepath -ItemType Directory -force

        $templateFiles = Get-ChildItem -Path $configLocation -Filter "*.json" -ErrorAction SilentlyContinue
        if (-not $templateFiles -or $templateFiles.Count -eq 0) {
            Write-InfoLog "No template json files found in {templateDir} for project {project}." -PropertyValues @($configLocation, $project.name)
            continue
        }
        Write-InfoLog "Found $($templateFiles.count) config files"
        foreach ($templateFile in $templateFiles) {
            Write-InfoLog "Running $templateFile"
            $migrationConfig = $null
            $migrationConfig = Get-Content $templateFile.FullName | ConvertFrom-Json -Depth 100
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
        
            $filename = "$filepath\$($templateFile.Name)"
            Write-InfoLog "Saving $filename"
            Out-File -FilePath $filename -InputObject ($migrationConfig | ConvertTo-Json -Depth 100) -Encoding ascii
        }
    }

}

Write-InfoLog "Done"

