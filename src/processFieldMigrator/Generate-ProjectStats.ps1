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
        Write-InfoLog "Skipping $($org.url)"
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
organisation,project,process base, process,workItems, sharedsteps,pipelines,plans,suites,repos, area, inlcude, priority`n
"@


    foreach ($project in $projects.value) {
        Write-InfoLog $project.name
        $Process = $null;
        $ProcessBase = $null;
        $WorkItemCount = $null;
        $WorkItemCount2 = $null;

        $propertiesURL = "$($org.url)/_apis/projects/$($project.id)/properties?keys=*process*&api-version=7.2-preview.1"
        Write-DebugLog $propertiesURL
        $queryResults = $null
        $queryResults = Invoke-RestMethod -Uri $propertiesURL -Method Get -ContentType "application/json" -Headers $header
        $ProcessBase = ($queryResults.value | Where-Object { $_.name -eq 'System.Process Template' } | select -Property value).value
        Write-InfoLog "    '$ProcessBase' base process"
        $ProcessTemplateId =  ($queryResults.value | Where-Object { $_.name -eq 'System.ProcessTemplateType' } | select -Property value).value
        $processURL = "$($org.url)/_apis/work/processes/$($ProcessTemplateId)?api-version=7.2-preview.2"
        $queryResults = $null
        $queryResults = Invoke-RestMethod -Uri $processURL -Method Get -ContentType "application/json" -Headers $header
        $Process = $queryResults.name
        Write-InfoLog "    '$Process' process"

        # POST https://dev.azure.com/{organization}?api-version=7.0
        $wiqlURL = "$($org.url)/$($project.id)/_apis/wit/wiql?$queryString"
        Write-DebugLog $wiqlURL

        $BODY = '{ "query": "Select [System.Id], [System.Title], [System.State], [System.Rev] From WorkItems where [System.TeamProject] = ''' + $($project.name) + ''' AND [System.WorkItemType] NOT IN (''Test Suite'', ''Test Plan'',''Shared Steps'',''Shared Parameter'',''Feedback Request'') ORDER BY [System.ChangedDate] desc"}' | ConvertFrom-Json -Depth 100
        $queryResults = $null
        $queryResults = Invoke-RestMethod -Uri $wiqlURL -Method Post -ContentType "application/json" -Headers $header -Body ($BODY | ConvertTo-Json -Depth 10)
        $WorkItemCount = 0
        if ($null -eq $queryResults.workItems) {
            Write-WarningLog "    $($queryResults.message)"
            [bool]$queryHasResults = $true;
            [int]$queryYear = Get-Date -Format "yyyy"
            while ($queryHasResults)
            {
                $BODY = '{ "query": "Select [System.Id], [System.Title], [System.State], [System.Rev] From WorkItems where [System.CreatedDate] >= ''01-01-' + $queryYear + ''' AND [System.CreatedDate] <= ''01-01-' + ($queryYear+1) + ''' AND [System.TeamProject] = ''' + $($project.name) + ''' AND [System.WorkItemType] NOT IN (''Test Suite'', ''Test Plan'',''Shared Steps'',''Shared Parameter'',''Feedback Request'') ORDER BY [System.ChangedDate] desc"}' | ConvertFrom-Json -Depth 100
                $queryResults = $null
                $queryResults = Invoke-RestMethod -Uri $wiqlURL -Method Post -ContentType "application/json" -Headers $header -Body ($BODY | ConvertTo-Json -Depth 10)
                $WorkItemCount += $queryResults.workItems.Count
                $queryYear--
                if ($queryResults.workItems.Count -eq 0) {
                    $queryHasResults = $false
                }
            }          
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
        $pipelinesResults = $null;
        $pipelinesResults = Invoke-RestMethod -Uri $pipelinesURL -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "    $($pipelinesResults.Count) Pipelines"

        #GET https://dev.azure.com/{organization}/{project}/_apis/testplan/plans?api-version=7.0
        $plansURL = "$($org.url)/$($project.id)/_apis/testplan/plans?$queryString"
        Write-DebugLog $plansURL
        $plansResults = $null;
        $plansResults = Invoke-RestMethod -Uri $plansURL -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "    $($plansResults.Count) Plans"

        #GET https://dev.azure.com/{organization}/{project}/_apis/git/repositories?api-version=7.1-preview.1
        $reposURL = "$($org.url)/$($project.id)/_apis/git/repositories?$queryString"
        Write-DebugLog $reposURL
        $reposResults = $null;
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



        $csv += "$($org.url),$($project.name),$ProcessBase, $Process,$WorkItemCount, $WorkItemCount2,$($pipelinesResults.Count),$($plansResults.Count),$totalSuits,$($reposResults.Count)`n"
    }

    $sanitisedOrgname = $($org.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
    $foldername = "./output/$sanitisedOrgname"
    New-item $foldername -ItemType Directory -force
    $filename = "$foldername/stats.xlsx"
    $data = $csv | ConvertFrom-Csv
    $data | Export-Excel $filename 
    
}
