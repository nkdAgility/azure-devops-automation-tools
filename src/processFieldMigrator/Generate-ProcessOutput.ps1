# generate process field definitions into output folder to checking and validation
clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1

BeginLoggerTitle "Generate-ProcessOutput"

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

Write-InfoLog "Found $($config.organisations.count) organisations"
    foreach ($organisation in $config.organisations) {
        if ($organisation.enabled -eq $false) {
            Write-InfoLog "Skipping {org}" -PropertyValues $organisation.url
            continue
        }
        $sanitisedOrgname = $($organisation.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
        $orgOut =  "$outputFolder\$sanitisedOrgname\"
        $orgfolder = New-item $orgOut -ItemType Directory -force
        Write-DebugLog "Created {orgOut}" -PropertyValues $orgfolder

        $temptoken = $null
        $header = $null
        $temptoken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($organisation.pat)"))
        $header = @{authorization = "Basic $temptoken" }
        Write-DebugLog "Header: {header}" -PropertyValues $header
        
        # Get Org Fields
        $callUrl = "$($organisation.url)/_apis/wit/fields?$queryString"
        $layout = Invoke-RestMethod -Uri $callUrl -Method Get -ContentType "application/json" -Headers $header
        $filename = "$orgOut\fields.json"
        Out-File -FilePath $filename -InputObject ($layout | ConvertTo-Json -Depth 100) -Encoding ascii
        Write-InfoLog "Saved {filename}" -PropertyValues $filename
        # Get Picklists
        $callUrl = "$($organisation.url)/_apis/work/processes/lists?$queryString"
        $lists = Invoke-RestMethod -Uri $callUrl -Method Get -ContentType "application/json" -Headers $header
        $filename = "$orgOut\lists.json"
        Out-File -FilePath $filename -InputObject ($lists | ConvertTo-Json -Depth 100) -Encoding ascii
        Write-InfoLog "Saved {filename}" -PropertyValues $filename
        $listOut =  "$orgOut\lists\"
        $listfolder = New-item $listOut -ItemType Directory -force
        Write-DebugLog "Created {orgOut}" -PropertyValues $listfolder
        foreach ($list in $lists.value)
        {
            $listDetail = Invoke-RestMethod -Uri $list.url -Method Get -ContentType "application/json" -Headers $header
            $filename = "$listOut\lists-$($list.id).json"
            Out-File -FilePath $filename -InputObject ($listDetail | ConvertTo-Json -Depth 100) -Encoding ascii
            Write-InfoLog "Saved {filename}" -PropertyValues $filename
        }
        # Get Processes
        $processUrl = "$($organisation.url)/_apis/work/processes/?$queryString"
        $processes = Invoke-RestMethod -Uri $processUrl -Method Get -ContentType "application/json" -Headers $header
        $filename = "$orgOut\processes.json"
        Out-File -FilePath $filename -InputObject ($processes | ConvertTo-Json -Depth 100) -Encoding ascii
        foreach ($process in $processes.value ) {
            if ($process.customizationType -eq "system") {
                Write-InfoLog "Skipping {processname} as its a SYSTEM process" -PropertyValues $process.name
                continue
            }
            $processOut =  "$orgOut\processes\$($process.name)"
            $processfolder = New-item $processOut -ItemType Directory -force
            Write-DebugLog "Created {processfolder}" -PropertyValues $processfolder
            $witsUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes?$queryString"
            $wits = Invoke-RestMethod -Uri $witsUrl -Method Get -ContentType "application/json" -Headers $header
            foreach ($wit in $wits.value) {
                if ($wit.customization -eq "system") {
                    Write-InfoLog "Skipping {witname} as its a SYSTEM WIT" -PropertyValues $wit.name
                    continue
                }
                # Get the layout
                $witLayoutUrl = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/layout?$queryString"
                $witLayout = $null
                $witLayout = Invoke-RestMethod -Uri $witLayoutUrl -Method Get -ContentType "application/json" -Headers $header
                $filename = "$processOut\$($wit.referenceName)-LAYOUT.json"
                Out-File -FilePath $filename -InputObject ($witLayout | ConvertTo-Json -Depth 100) -Encoding ascii
                Write-InfoLog "Saved {filename}" -PropertyValues $filename
                # Get the fields
                $witFieldsURL = "$($organisation.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/fields?$queryString"
                $witFields = Invoke-RestMethod -Uri $witFieldsURL -Method Get -ContentType "application/json" -Headers $header
                $filename = "$processOut\$($wit.referenceName)-fields.json"
                Out-File -FilePath $filename -InputObject ($witFields | ConvertTo-Json -Depth 100) -Encoding ascii
                Write-InfoLog "Saved {filename}" -PropertyValues $filename

            }
            
        }

    }
Write-InfoLog "Finished"
