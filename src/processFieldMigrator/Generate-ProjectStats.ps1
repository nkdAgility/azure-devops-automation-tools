clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1
. .\src\_includes\ImportExcel.ps1

BeginLoggerTitle "Generate-ProjectStats"

# Define organization base url, PAT and API version variables

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

foreach ($org in $config.organisations) {
    if ($org.enabled -eq $false) {
        Write-InfoLog "Skipping $($organisation.url)"
        continue
    }
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

    $csv = @"
organisation,project,workItems, sharedsteps,pipelines,plans,suites,repos, area, inlcude, priority`n
"@


    foreach ($project in $projects.value) {
        Write-InfoLog $project.name
        # POST https://dev.azure.com/{organization}?api-version=7.0
        $wiqlURL = "$($org.url)/$($project.id)/_apis/wit/wiql?$queryString"
        Write-DebugLog $wiqlURL

        $BODY = '{ "query": "Select [System.Id], [System.Title], [System.State] From WorkItems where [System.TeamProject] = ''' + $($project.name) + ''' order by [System.CreatedDate] desc"}' | ConvertFrom-Json -Depth 100
        $queryResults = $null
        $queryResults = Invoke-RestMethod -Uri $wiqlURL -Method Post -ContentType "application/json" -Headers $header -Body ($BODY | ConvertTo-Json -Depth 10)
        $WorkItemCount = 0
        if ($null -eq $queryResults.workItems) {
            Write-WarningLog "    $($queryResults.message)"
            $WorkItemCount = 20000
        }
        else {
            $WorkItemCount = $queryResults.workItems.Count
            
        }
        Write-InfoLog "    $WorkItemCount Work Items"


        $BODY2 = '{ "query": "Select [System.Id], [System.Title], [System.State] From WorkItems where [System.TeamProject] = ''' + $($project.name) + ''' AND [System.WorkItemType] = ''Shared Steps'' order by [System.CreatedDate] desc"}' | ConvertFrom-Json -Depth 100
        $queryResults2 = $null
        $queryResults2 = Invoke-RestMethod -Uri $wiqlURL -Method Post -ContentType "application/json" -Headers $header -Body ($BODY2 | ConvertTo-Json -Depth 10)
        $WorkItemCount2 = $queryResults2.workItems.Count
        Write-InfoLog "    $WorkItemCount2 Shared Step Work Items"
        

        #GET https://dev.azure.com/{organization}/{project}/_apis/pipelines?api-version=7.0
        $pipelinesURL = "$($org.url)/$($project.id)/_apis/pipelines?$queryString"
        Write-DebugLog $pipelinesURL
        $pipelinesResults = Invoke-RestMethod -Uri $pipelinesURL -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "    $($pipelinesResults.Count) Pipelines"

        #GET https://dev.azure.com/{organization}/{project}/_apis/testplan/plans?api-version=7.0
        $plansURL = "$($org.url)/$($project.id)/_apis/testplan/plans?$queryString"
        Write-DebugLog $plansURL
        $plansResults = Invoke-RestMethod -Uri $plansURL -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "    $($plansResults.Count) Plans"

        #GET https://dev.azure.com/{organization}/{project}/_apis/git/repositories?api-version=7.1-preview.1
        $reposURL = "$($org.url)/$($project.id)/_apis/git/repositories?$queryString"
        Write-DebugLog $reposURL
        $reposResults = Invoke-RestMethod -Uri $reposURL -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "    $($reposResults.Count) Repos"

        $totalSuits = 0;
        foreach ($plan in $plansResults.value) {
            #GET https://dev.azure.com/{organization}/{project}/_apis/testplan/Plans/{planId}/suites?api-version=7.0
            #GET https://dev.azure.com/fabrikam/{project}/_apis/testplan/Plans/{planId}/suites?asTreeView=True&api-version=7.0
            $suitesURL = "$($org.url)/{$($project.id)}/_apis/testplan/plans/$($plan.id)/suites?asTreeView=True&$queryString"
            Write-DebugLog $suitesURL
            $suitesResults = Invoke-RestMethod -Uri $suitesURL -Method Get -ContentType "application/json" -Headers $header
            Write-InfoLog "        $($suitesResults.Count) Suites"
            $totalSuits = $totalSuits + $suitesResults.count
        }
        #GET https://dev.azure.com/{organization}/{project}/_apis/testplan/Plans/{planId}/suites?api-version=7.0



        $csv += "$($org.url),$($project.name),$WorkItemCount, $WorkItemCount2,$($pipelinesResults.Count),$($plansResults.Count),$totalSuits,$($reposResults.Count)`n"
    }

    $sanitisedOrgname = $($org.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
    $filename = "./output/$sanitisedOrgname/stats.xlsx"
    New-item $filename -ItemType Directory -force
    $data = $csv | ConvertFrom-Csv
    $data | Export-Excel $filename 
    
}
