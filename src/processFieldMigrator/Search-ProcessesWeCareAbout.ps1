clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1

BeginLoggerTitle "Search-ProcessesWeCareAbout.ps1"

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

for ($orgNum = 0 ; $orgNum -le $config.organisations.Count - 1 ; $orgNum++) {
    $organisation = $config.organisations[$orgNum]
    if ($organisation.enabled -eq $false) {
        Write-InfoLog "Skipping {org}: set to false" -PropertyValues $($organisation.url)
        continue
    }
    $token = $null
    $header = $null
    Write-InfoLog "=============="
    Write-InfoLog $organisation.url
    Write-InfoLog "=============="

    if ( $null -eq (Get-Member -Name "processMatch" -InputObject $organisation)) {
        $newArray = [System.Collections.ArrayList]@()
        Add-Member -InputObject $organisation -MemberType NoteProperty -Name "processMatch" -Value $newArray
        Write-InfoLog "Adding processMatch to {orgurl}" -PropertyValues $($organisation.url)
    }
    $orgUrl = $organisation.url
    $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($organisation.pat)"))
    $header = @{authorization = "Basic $token" }
    # Find Processes that we care about
    $projectsUrl = "$orgUrl/_apis/work/processes?$queryString"
    $processes = Invoke-RestMethod -Uri $projectsUrl -Method Get -ContentType "application/json" -Headers $header
    $processes.value | ForEach-Object {
        $processID = $_.typeId
        $processName = $_.name
        Write-DebugLog "$processID $processName"

        $IsThereAlready = $organisation.processMatch | Where-Object { $_.ProcessID -eq $processID }
        if ($IsThereAlready -ne $null) {
            Write-InfoLog "Skipping {processID}:{processName} as already in list" -PropertyValues $processID, $processName
        }
        else {
            Write-InfoLog "Checking {processID}:{processName}" -PropertyValues $processID, $processName
            # Get the list of all projects in the organization
            $callUrl = "$orgUrl/_apis/work/processes/$processID/workItemTypes/?$queryString"
            $witypes = Invoke-RestMethod -Uri $callUrl -Method Get -ContentType "application/json" -Headers $header
            $witypes.value | Where-Object { $_.referenceName.EndsWith("Epic") } | ForEach-Object {
                Write-DebugLog "$($_.referenceName) $($_.name)"
                $workItemType = $_.referenceName
                # Get the list of all projects in the organization
                $fieldsURL = "$orgUrl/_apis/work/processes/$processID/workItemTypes/$workItemType/fields?$queryString"
                $fields = Invoke-RestMethod -Uri $fieldsURL -Method Get -ContentType "application/json" -Headers $header
                $fields.value | Where-Object { $_.referenceName.StartsWith("Custom.ITReport") } |  ForEach-Object {
                    Write-DebugLog "$($_.referenceName) $($_.name)"
                    $obj = [PSCustomObject]@{
                        enabled      = $true;
                        ProcessName  = $processName
                        WorkItemType = $workItemType
                        ProcessID    = $processID
                    }
                    $Collection = {$organisation.processMatch}.Invoke()
                    $Collection.Add($obj)
                    $organisation.processMatch = $Collection
                    Write-InfoLog "Adding {processID}:{processName}:{workItemType}" -PropertyValues $processID, $processName, $workItemType
                }
            }
        }
    }
}
Write-InfoLog "=============="
Write-InfoLog "DONE"
Write-InfoLog "=============="

$json = $config | ConvertTo-Json -Depth 100
Out-file -FilePath $configFile -InputObject $json
Write-InfoLog "Saving $configFile"

