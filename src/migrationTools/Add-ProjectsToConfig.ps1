clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1
. .\src\_includes\ImportExcel.ps1

BeginLoggerTitle "Add-ProjectsToConfig XXX"

# Define organization base url, PAT and API version variables
$configFile = "$dataFolder\organisations.json"
$config = Get-Content $configFile | Out-String | ConvertFrom-Json

for ($orgNum = 0 ; $orgNum -le $config.organisations.Count - 1 ; $orgNum++) {
    $org = $config.organisations[$orgNum]
    if ($org.enabled -eq $false) {
        Write-InfoLog "Skipping $($org.url)"
        continue
    }
    Write-InfoLog "Processing $($org.url)"
    # Create header with PAT
    $token = $null
    $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($org.pat)"))
    $header = $null
    $header = @{authorization = "Basic $token" }
    $queryString = "api-version=7.0"


    # GET https://dev.azure.com/{organization}


    Write-DebugLog "$($org.url) $header" 
    $projectsURL = "$($org.url)/_apis/projects?$queryString"
    Write-DebugLog $projectsURL
    $projects = Invoke-RestMethod -Uri $projectsURL -Method Get -ContentType "application/json" -Headers $header

    Write-InfoLog "Processing $($org.url) with $($projects.value.count) projects"

    # Ensure the organisation has a 'projects' collection we can append to
    if (-not ($org.PSObject.Properties.Name -contains 'projects') -or -not $org.projects) {
        # Use an ArrayList for efficient appends
        $org | Add-Member -NotePropertyName projects -NotePropertyValue (New-Object System.Collections.ArrayList) -Force
    }

    foreach ($project in $projects.value) {
        Write-DebugLog "$project"
        $IsThereAlready = $org.projects | Where-Object { $_.name -eq $project.name }
        if ($null -ne $IsThereAlready) {
            Write-InfoLog "Skipping {project} as already in list" -PropertyValues $project.name
        }
        else {
            Write-InfoLog "Checking {project}" -PropertyValues $project.name
            $obj = [PSCustomObject]@{
                enabled = $true;
                name    = $project.name
                id      = $project.id
            }
            # Add new project entry
            [void]$org.projects.Add($obj)
            Write-InfoLog "Adding {project}" -PropertyValues $project.name
        }
    }
    $config.organisations[$orgNum] = $org;
}

Write-InfoLog "=============="
Write-InfoLog "DONE"
Write-InfoLog "=============="

$json = $config | ConvertTo-Json -Depth 100
Out-file -FilePath $configFile -InputObject $json
Write-InfoLog "Saving $configFile"

