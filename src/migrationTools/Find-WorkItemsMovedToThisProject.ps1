param (

    [Parameter(Position = 0, mandatory = $false)]
    [string]  $PAT = "PAT" ,

    [Parameter(Position = 1, mandatory = $false)]
    [string]  $orgURL = "ORGANIZATIONURL",

    [Parameter(Position = 2, mandatory = $false)]
    [string]  $projectName = "PROJECT",

    [Parameter(Position = 3, mandatory = $false)]
    [string]  $workItemType = "WORKITEMTYPE",

    [Parameter(Position = 4, mandatory = $false)]
    [string]  $filePath = "PATH"
)

$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)"))
$header = @{authorization = "Basic $token" }
$query = "Select [System.Id], [System.Title] From WorkItems Where [System.WorkItemType] = '$workItemType' and [System.TeamProject] = '$projectName'"
$body = @{query = $query} | ConvertTo-Json

$url = "$orgURL/$projectName/_apis/wit/wiql?api-version=7.0"

$response = Invoke-RestMethod -Uri $url -Method POST -ContentType "application/json" -Headers $header -Body $body

# Loop through each item and check revisions for changes in team project

$movedItems = @()

foreach ($item in $response.workItems) {
    
    $itemUrl = $item.url
    $itemResponse = Invoke-RestMethod -Uri $itemUrl -Method Get -Headers $header

    $currentTeamProject = $itemResponse.fields."System.TeamProject"

    $id = $item.id

    $revisionsUrl = "$orgURL/$projectName/_apis/wit/workitems/$id/revisions?api-version=7.0"
    $revisions = Invoke-RestMethod -Uri $revisionsUrl -Method Get -Headers $header

    foreach ($revision in $revisions.value) {
        $oldTeamProject = $revision.fields."System.TeamProject"
        if ($oldTeamProject -ne $currentTeamProject) {
            $movedItems += $revision.id
            $movedItems = "$movedItems, "
            Write-Host "This item: $id has been moved from $oldTeamProject to $currentTeamProject"
            break
        }
    }
}


# Check if any items have changed team project
if ($movedItems.Count -eq 0) {
    Write-Host "No items have been moved from another project."
}
else {
    # Trim the , in the end
    $movedItems = $movedItems.TrimEnd(', ')
    # Output array of changed items IDs to a file
    $outputFileName = "Moved-$workItemType.txt"
    $outputFilePath = Join-Path -Path $filePath -ChildPath $outputFileName
    $movedItems | Out-File -FilePath $outputFilePath -Encoding utf8

    # Display a message indicating where the output file was written
    Write-Host "The moved items have been written to '$outputFilePath'."
}