clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1 

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json
$fieldConfig = Get-Content "$dataFolder\ReflectedWorkItemId.json" | Out-String | ConvertFrom-Json

foreach ($org in $config.organisations) {
  if ($org.enabled -eq $false) {
    Write-InfoLog "Skipping $($org.url)"
    continue
  }
  $token = $null
  $header = $null

  $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($org.pat)"))
  $header = @{authorization = "Basic $token" }
  Write-InfoLog "=========================================="
  Write-InfoLog "------------------------------------------"
  Write-InfoLog "Running $($org.url)" 
  Write-InfoLog "------------------------------------------"

  # GET https://dev.azure.com/{organization}/_apis/wit/fields?api-version=7.1-preview.3
  $orgFieldsUrl = "$($org.url)/_apis/wit/fields?$queryString"
  Write-DebugLog $orgFieldsUrl
  $orgFields = Invoke-RestMethod -Uri $orgFieldsUrl -Method Get -ContentType "application/json" -Headers $header
  Write-InfoLog "    Found $($orgFields.count)" 
  Write-InfoLog "Field to Check: $($fieldConfig.fieldName)"
  $orgfield = $null;
  $orgfield = $orgFields.value | Where-Object { $_.name -eq $($fieldConfig.fieldName) }

  if ($null -eq $orgfield) {
    # Add the WIT-field to the wit system
    $fieldCreateURL = "$($org.url)/_apis/wit/fields?$queryString"
    if ($null -ne $fieldConfig.createFieldPOST) {
      $body = $fieldConfig.createFieldPOST | ConvertTo-Json -Depth 100
      #Write-DebugLog $body
      $orgfield = Invoke-RestMethod -Uri $fieldCreateURL -Method Post -ContentType "application/json" -Headers $header -Body $body
      Write-InfoLog "Created new WIT Field: $($orgfield.name)"
    }
    else {
      Write-WarningLog "FAILD: $($fieldConfig.fieldName) - Not Found and no createFieldPOST"
    }
  }
  else {
    Write-InfoLog "------------------------------------------"
    Write-InfoLog "Field found as $($orgfield.referenceName)"
    if ($orgfield.referenceName.Contains("Custom") -eq $false) {
      Write-WarningLog "FAILD MISSMATCH $($orgfield.referenceName)"
      continue
    }
    Write-InfoLog "------------------------------------------"      
  }
  #Get list of proceses
  Write-InfoLog "Getting list of processes"
  $processesUrl = "$($org.url)/_apis/work/processes?$queryString"
  $processes = Invoke-RestMethod -Uri $processesUrl -Method Get -ContentType "application/json" -Headers $header
  Write-InfoLog "Found $($processes.count) processes"
  foreach ($process in $processes.value) {
    Write-InfoLog "Running on $($process.name)"
    if ($process.customizationType -eq "system") {
      Write-InfoLog "Skipping Default Process"
      continue
    }    
    #Get list of WITs
    $witsUrl = "$($org.url)/_apis/work/processes/$($process.typeId)/workItemTypes"
    Write-DebugLog $witsUrl
    $wits = Invoke-RestMethod -Uri $witsUrl -Method Get -ContentType "application/json" -Headers $header
    Write-InfoLog "Found $($wits.count) WITs"
    foreach ($wit in $wits.value) {
      Write-InfoLog "Running on $($wit.name) [ $($wit.referenceName) ]"
      # -------------------------------------------
      # ------------ WIT Field Check --------------
      $witFieldsUrl = "$($org.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/fields?$queryString"
      $witFields = Invoke-RestMethod -Uri $witFieldsUrl -Method Get -ContentType "application/json" -Headers $header
      $witField = $witFields.value | Where-Object { $_.name -eq $($fieldConfig.fieldName) }
      if ($null -eq $witField) {
        Write-InfoLog "    $($wit.name) does not have  $($fieldConfig.fieldName)"
        if ($($wit.referenceName).Contains("Microsoft.VSTS") -eq $true) {
          Write-InfoLog "    Create Custom WIT: START"
          #POST https://dev.azure.com/{organization}/_apis/work/processes/{processId}/workitemtypes?api-version=7.0
          $witCreateURL = "$($org.url)/_apis/work/processes/$($process.typeId)/workitemtypes?$queryString"
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
        #Add the Form-field to the wit system
        if ($null -ne $fieldConfig.addFieldPOST) {
          $addFieldPOSTbody = $fieldConfig.addFieldPOST | ConvertTo-Json -Depth 100
          $addFieldPOSTURL = "$($org.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/fields?$queryString"
          $addedField = Invoke-RestMethod -Uri $addFieldPOSTURL -Method Post -ContentType "application/json" -Headers $header -Body $addFieldPOSTbody
          Write-InfoLog "Added new Epic Field: $($fieldConfig.fieldName)"
        }
        else {
          Write-WarningLog "No POST addFieldPOST for $($fieldConfig.fieldName)"
        }
        # # Add control in the most mental way posible!
        # # Get Parent Process to get the name, then add to the "parenatname.witname.witname.Status" group
        # #GET https://dev.azure.com/{organization}/_apis/work/processes/{processTypeId}?api-version=7.0
        # $parentProcessUrl = "$($org.url)/_apis/work/processes/$($process.parentProcessTypeId)?$queryString"
        # $parentProcess = Invoke-RestMethod -Uri $parentProcessUrl -Method Get -ContentType "application/json" -Headers $header
        # Write-InfoLog " Looked up Parent $($parentProcess.name) has been updated"

        # if ($null -ne $fieldConfig.createControlPOST)
        # {
        #   $WitRefShortBits = $wit.referenceName.Split(".");
        #   $GroupName = "$($parentProcess.name).$($WitRefShortBits[1]).$($WitRefShortBits[1]).Details"
        #   Write-InfoLog "Adding to Group: $($GroupName)"
        #   $createControlPOSTbody = $fieldConfig.createControlPOST | ConvertTo-Json -Depth 100
        #   $createControlPOSTURL = "$($org.url)/_apis/work/processes/$($process.typeId)/workItemTypes/$($wit.referenceName)/layout/groups/$GroupName/controls?$queryString"
        #   $addedControl = Invoke-RestMethod -Uri $createControlPOSTURL -Method Post -ContentType "application/json" -Headers $header -Body $createControlPOSTbody
        #   Write-InfoLog "Added new Epic Control: $($fieldConfig.fieldName)"
        # } else {
        #   Write-WarningLog "No POST addFieldPOST for $($fieldConfig.fieldName)"
        # }
      }
      else {
        Write-InfoLog "Form-Field Found on WIT: $($fieldConfig.fieldName)"
      }
    }
  }
}
Write-InfoLog "===============THE=END================="