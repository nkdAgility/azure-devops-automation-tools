clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\processFieldMigrator\ | Unblock-File

. .\src\_includes\setup.ps1

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

# Get Pages into a collection
$pagesFiles = Get-ChildItem -Path "$dataFolder\pages" -Filter *.json -Recurse

$pages = @()
foreach ($pageFile in $pagesFiles) {
    $page = Get-Content $pageFile.FullName | Out-String | ConvertFrom-Json
    $pages += $page
}

# Run Through each Org and each Process and each WIT and add pages where required
foreach ($organisation in $config.organisations) {
    if ($organisation.enabled -eq $false) {
        Write-InfoLog "Skipping {org}" -PropertyValues $($organisation.url)
        continue
    }
    $sanitisedOrgName = $($organisation.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
    $token = $null
    $header = $null

    $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($organisation.pat)"))
    $header = @{authorization = "Basic $token" }
    Write-InfoLog "=========================================="
    Write-InfoLog "------------------------------------------"
    Write-InfoLog "Running $($organisation.url) <<-" 
    Write-InfoLog "------------------------------------------"
    #Get list of proceses
    Write-InfoLog "Getting list of processes"
    $processesUrl = "$($organisation.url)/_apis/work/processes?$queryString"
    Write-DebugLog $processesUrl
    $processes = Invoke-RestMethod -Uri $processesUrl -Method Get -ContentType "application/json" -Headers $header
    Write-InfoLog "Found $($processes.count) processes"
    foreach ($process in $processes.value) {
        Write-InfoLog "Running on $($process.name)"
        if ($process.customizationType -eq "system") {
            Write-InfoLog "Skipping Default Process"
            continue
        }    
        #Get list of WITs
        $witsUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes"
        Write-DebugLog $witsUrl
        $wits = Invoke-RestMethod -Uri $witsUrl -Method Get -ContentType "application/json" -Headers $header
        Write-InfoLog "Found $($wits.count) WITs"
        foreach ($wit in $wits.value) {
            Write-InfoLog "Running on $($wit.name) [ $($wit.referenceName) ]"
            $pagesToProcess = $pages | Where-Object { $_.workItemTypes -contains $wit.name }
            if ($pagesToProcess.count -eq 0) {
                Write-InfoLog "No pages to process"
                continue
            }
            if ($wit.customization -eq "system") {
                Write-InfoLog "    Create Custom WIT: START"
                #POST https://dev.azure.com/{organization}/_apis/work/processes/{processId}/workitemtypes?api-version=7.0
                $witCreateURL = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workitemtypes?$queryString"
                $witCreateBody = '{
                  "name": "' + $($wit.name) + '",
                  "description": "' + $($wit.description) + '",
                  "color": "' + $($wit.color) + '",
                  "icon": "' + $($wit.icon) + '",
                  "isDisabled": false,
                  "inheritsFrom": "' + $($wit.referenceName) + '"
                }'
                $wit = Invoke-RestMethod -Uri $witCreateURL -Method Post -ContentType "application/json" -Headers $header -Body $witCreateBody
                Write-InfoLog "    Create Custom WIT: END"
              }
            Write-WarningLog "Found $($pagesToProcess.count) pages to process"
            # Get the layout
            $layoutUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/layout?$queryString"
            Write-DebugLog $layoutUrl
            $layout = Invoke-RestMethod -Uri $layoutUrl -Method Get -ContentType "application/json" -Headers $header
            Write-InfoLog "Found $($layout.pages.count) pages in layout"
            foreach ($page in $pagesToProcess ) {
                if ($page.enabled -eq $false) {
                    Write-WarningLog "{orgname}::{wit}::{page} - Skipping {field}: set to false" -PropertyValues $sanitisedOrgName, $wit.referenceName, $page.name
                    continue
                  }
                $foundPage = $layout.pages | Where-Object { $_.label -contains $page.PagePOST.label }

                if ($null -eq $foundPage) {
                    Write-WarningLog "Page $($page.name) needs added to $($wit.name)"
                    # Add the Page
                    #POST https://dev.azure.com/{organization}/_apis/work/processes/{processId}/workItemTypes/{witRefName}/layout/pages?api-version=7.1-preview.1
                    $addPageUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/layout/pages?$queryString"
                    Write-DebugLog $addPageUrl
                    $addPageBody = $page.PagePOST | ConvertTo-Json -Depth 100
                    Write-DebugLog $addPageBody
                    $addPage = Invoke-RestMethod -Uri $addPageUrl -Method Post -ContentType "application/json" -Headers $header -Body $addPageBody
                    Write-InfoLog "Page $($page.name) added to $($wit.name)"       
                    $foundPage = $addPage             
                }
                # Check the Groups
                Write-InfoLog "Page $($foundPage.name) exists in $($wit.name): proceed to checking groups"
                ## Add Groups
                foreach ($section in $page.PagePOST.sections) {
                    Write-InfoLog "$($section.id) Adding Groups to $($page.name) in $($wit.name)"
                    Write-InfoLog "$($section.id) $($section.groups.count) Groups to add"
                    foreach ($group in $section.groups) {
                        $foundSection = $foundPage.sections | where-object { $_.id -eq $section.id }
                        $foundGroup = $foundSection.groups | where-object { $_.label -eq $group.label } # TODO: Does not take care of moved groups
                        if ($null -ne $foundGroup) {
                            Write-InfoLog "$($section.id) Group $($group.label) already exists in $($page.name) in $($wit.name)"
                            continue
                        }
                        $addGroupUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/layout/pages/$($foundPage.id)/sections/$($section.id)/groups?$queryString"
                        Write-DebugLog $addGroupUrl
                        
                        $addGroupBody = $group | ConvertTo-Json -Depth 100
                        Write-DebugLog $addGroupBody
                        $addGroup = Invoke-RestMethod -Uri $addGroupUrl -Method Post -ContentType "application/json" -Headers $header -Body $addGroupBody
                        Write-InfoLog "Group $($group.label) added to $($page.name) in $($wit.name)"
                    }
                }
            }
        }
    }
}




