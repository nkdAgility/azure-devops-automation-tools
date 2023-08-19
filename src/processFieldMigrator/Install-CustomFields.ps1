clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1
. .\src\_includes\methods.ps1

BeginLoggerTitle "Install-CustomFields.ps1"

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

foreach ($organisation in $config.organisations) {
  if ($organisation.enabled -eq $false) {
    Write-WarningLog "Skipping {org}: set to false" -PropertyValues $($organisation.url)
    continue
  }
  $sanitisedOrgName = $($organisation.url).Replace("https://dev.azure.com/", "").Replace("visualstudio.com/", "").Replace("/", "")
  $token = $null
  $header = $null
  Write-InfoLog "=============="
  Write-InfoLog "\\{orgname}" -PropertyValues $sanitisedOrgName
  Write-InfoLog "=============="
  $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($organisation.pat)"))
  $header = @{authorization = "Basic $token" }

  foreach ($process in $organisation.processMatch) {
    Write-InfoLog "=============="
    Write-InfoLog "\\{orgname}\\{process}" -PropertyValues $sanitisedOrgName, $($process.ProcessName)
    if ($process.enabled -eq $false) {
      Write-WarningLog "{orgname} - Skipping {process}: set to false" -PropertyValues $sanitisedOrgName, $($process.ProcessName)
      continue
    }

    Write-InfoLog "{orgname}::{ProcessName} - Running for {workItemType}" -PropertyValues $sanitisedOrgName, $process.ProcessName, $process.workItemType
    # GET https://dev.azure.com/{organization}/_apis/wit/fields?api-version=7.1-preview.3
    $witfieldsURL = "$($organisation.url)/_apis/wit/fields?$queryString"
    Write-DebugLog "{orgname}::{ProcessName} - Calling {witfieldsURL}" -PropertyValues $sanitisedOrgName, $process.ProcessName, $witfieldsURL
    $witfields = Invoke-RestMethod -Uri $witfieldsURL -Method Get -ContentType "application/json" -Headers $header
    Write-DebugLog "{orgname}::{ProcessName} - Returned {count}" -PropertyValues $sanitisedOrgName, $process.ProcessName, $witfields.count

    $fieldsToCheck = $null
    $fieldsToCheck = Get-Content "$dataFolder\fields.json" | Out-String | ConvertFrom-Json
    foreach ($fieldItem in $fieldsToCheck.fields) {
      if ($fieldItem.enabled -eq $false) {
        Write-WarningLog "{orgname}::{ProcessName}::{field} - Skipping {field}: set to false" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($fieldItem.refname)
        continue
      }
      $fieldItemFile = "$dataFolder\fields\$($fieldItem.refname).json"
      if ((Test-Path -Path $fieldItemFile) -eq $false) {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - File not found! Check that the refname in fields.json matches the file name in \fields\*.json! Looking for {filename}" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($fieldItem.refname), $fieldItemFile
        continue
      }
      $FieldToCheck = $null
      $FieldToCheck = Get-Content $fieldItemFile | Out-String | ConvertFrom-Json
      # -------------------------------------------
      # ------------ JSON VALIDATION CHECKS ------
      # -------------------------------------------
      Write-InfoLog "{orgname}::{ProcessName}::{field} -[[Validating  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName)
      $isValid = $true
      if ($FieldToCheck.referenceName -ne $FieldToCheck.createFieldPOST.referenceName)
      {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - VALIDATION FAILED: referenceName {field} and createFieldPOST.referenceName {createFieldPOST} do not match !  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName), $FieldToCheck.createFieldPOST.referenceName
        $isValid = $false
      }
      if ($FieldToCheck.referenceName -ne $FieldToCheck.addFieldPOST.referenceName)
      {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - VALIDATION FAILED: referenceName {field} and addFieldPOST.referenceName {addFieldPOST} do not match !  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName), $FieldToCheck.addFieldPOST.referenceName
        $isValid = $false
      }
      if ($FieldToCheck.referenceName -ne $FieldToCheck.createControlPOST.id)
      {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - VALIDATION FAILED: referenceName {field} and createControlPOST.id {createControlPOST} do not match !  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName), $FieldToCheck.createControlPOST.id
        $isValid = $false
      }
      if ($FieldToCheck.createPicklistPOST.name -contains ".")
      {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - VALIDATION FAILED: referenceName {field} and createControlPOST.id {createControlPOST} do not match !  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName), $FieldToCheck.createControlPOST.id
        $isValid = $false
      }
      if ($isValid -eq $false)
      {
        Write-ErrorLog "{orgname}::{ProcessName}::{field} - VALIDATION FAILED]]" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName)
        continue
      } else {
        Write-InfoLog "{orgname}::{ProcessName}::{field} - VALIDATION OK]] (but that does not mean its right)  " -PropertyValues $sanitisedOrgName, $process.ProcessName, $($FieldToCheck.referenceName)
      }    
      #- -------------------------------------------
      #- ------------ FIELD ------------------------
      $field = $null;
      $field = $witfields.value | Where-Object { $_.referenceName -eq $FieldToCheck.referenceName }
       # -------------------------------------------
      # ------------ PICKLIST ----------------------
      # -------------------------------------------
      if ($FieldToCheck.createFieldPOST.isPicklist -eq $true)
      {
        # Add or Update the picklist
        $picklists = $null
        
        $getPicklistUrl = "$($organisation.url)/_apis/work/processes/lists/?$queryString"
        
        Write-DebugLog "{orgname}::{ProcessName}::{field} - {getPicklistUrl}"  -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $getPicklistUrl
        $picklists = Invoke-RestMethod -Uri $getPicklistUrl -Method Get -ContentType "application/json" -Headers $header
        # 
        $picklist = $null
        if ($field.picklistId -ne $null)
        {
          $picklist = $picklists.value | Where-Object { $_.id -eq $field.picklistId }
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Using existing Picklist from field" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
        } else {
          $picklist = $picklists.value | Where-Object { $_.name -eq $FieldToCheck.createPicklistPOST.name }
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Using existing Picklist with our special name" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
        }

        if ($null -eq $picklist)
        {
          # There is no picklist!!
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Picklist not found" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
            $picklistPOSTbody = $null
            $picklistPOSTbody = $FieldToCheck.createPicklistPOST | ConvertTo-Json -Depth 100
            $picklistPOSTURL = "$($organisation.url)/_apis/work/processes/lists/?$queryString"
            $picklist = Invoke-RestMethod -Uri $picklistPOSTURL -Method Post -ContentType "application/json" -Headers $header -Body $picklistPOSTbody
            if ($null -eq $picklist) {
              Write-ErrorLog "{orgname}::{ProcessName}::{field} - Failed to create picklist" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
              continue
            }
        } else {
          # There is a picklist!!
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Picklist found" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
          $picklistPOSTbody = $null
          $FieldToCheck.createPicklistPOST.name = $null
          $FieldToCheck.createPicklistPOST.type = $null
          $picklistPOSTbody = $FieldToCheck.createPicklistPOST | ConvertTo-Json -Depth 100
          Write-DebugLog "{orgname}::{ProcessName}::{field} - {picklistPOSTbody}"  -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $picklistPOSTbody
          $picklistPOSTURL = $null
          $picklistPOSTURL = "$($organisation.url)/_apis/work/processes/lists/$($picklist.id)?$queryString"
          Write-DebugLog "{orgname}::{ProcessName}::{field} - {picklistPOSTURL}"  -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $picklistPOSTURL
          $picklist = Invoke-RestMethod -Uri $picklistPOSTURL -Method PUT -ContentType "application/json" -Headers $header -Body $picklistPOSTbody
          if ($null -eq $picklist) {
            Write-ErrorLog "{orgname}::{ProcessName}::{field} - failed to create picklist" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName
            continue
          }
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Updated Picklist {picklist}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $picklist.name
        }
        $FieldToCheck.createFieldPOST.picklistId = $picklist.id
        $picklist = $null
      }
      # -------------------------------------------
      # ------------ WIT Field Check --------------
      # -------------------------------------------
      
      if ($null -ne $field) {
        Write-InfoLog "{orgname}::{ProcessName}::{field} - WIT-Field Found - Check that Sucker is valid" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($field.referenceName)
        If ($field.type -eq $FieldToCheck.createFieldPOST.type) {
          Write-InfoLog "{orgname}::{ProcessName}::{field} - WIT-Field Found - Type is correct" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($field.referenceName)
        }
        else {
          Write-ErrorLog "{orgname}::{ProcessName}::{field} - WIT-Field Found - Type is NOT correct" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($field.referenceName)
          continue
        }
        if ( $field.picklistId -eq $FieldToCheck.createFieldPOST.picklistId) {
          Write-InfoLog "{orgname}::{ProcessName}::{field} - WIT-Field Found - Picklist is correct" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($field.referenceName)
        }
        else {
          Write-WarningLog "{orgname}::{ProcessName}::{field} - WIT-Field Found - Picklist is NOT correct \\ Patching" -PropertyValues $sanitisedOrgName, $process.ProcessName, $($field.referenceName)
          continue
          # # TODO: Waiting for Product Team || Cant update picklistId
          # #PATCH https://dev.azure.com/{organization}/{project}/_apis/wit/fields/{fieldNameOrRefName}?api-version=7.1-preview.3
          # $patchForIncorrectPicklist = @{
          #   "isLocked"= $true
          #   #"picklistId"= $FieldToCheck.createFieldPOST.picklistId
          # }
          # $patchForIncorrectPicklist = $patchForIncorrectPicklist | ConvertTo-Json -Depth 100
          # $patchFieldUrl = "$($organisation.url)/_apis/wit/fields/$($field.referenceName)?$queryStringPreview"
          # Write-InfoLog "{orgname}::{ProcessName}::{field} - {patchFieldUrl}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName,  $patchFieldUrl
          # $addedField = Invoke-RestMethod -Uri $patchFieldUrl -Method patch -ContentType "application/json" -Headers $header -Body $patchForIncorrectPicklist
          # Write-ErrorLog "{orgname}::{ProcessName}::{field} - Locked field as it has the wrong picklist | Stantervention required" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($addedField.name)
          # $addedField = $null;
        }
      }
      else {
        # Add the WIT-field to the wit system
        $fieldCreateURL = "$($organisation.url)/_apis/wit/fields?$queryString"
        if ($null -ne $FieldToCheck.createFieldPOST) {
          $body = $null
          $body = $FieldToCheck.createFieldPOST | ConvertTo-Json -Depth 100
          $CreatedField = Invoke-RestMethod -Uri $fieldCreateURL -Method Post -ContentType "application/json" -Headers $header -Body $body
          if ($null -eq $CreatedField) {
            Write-ErrorLog "{orgname}::{ProcessName}::{field} - Failed to create field {fieldToCheck}! Check that refname matches" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name)
            continue
          }
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Created new WIT Field as {createdField} " -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($CreatedField.name)
          $CreatedField = $null;
        }
        else {
          Write-WarningLog "{orgname}::{ProcessName}::{field} - No POST createFieldPOST for {fieldToCheck}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name)
        }
      }
      # -------------------------------------------
      # ------------ Form Field Check -------------
      # -------------------------------------------
      $processEpicLayoutURL = "$($organisation.url)/_apis/work/processes/$($process.ProcessID)/workItemTypes/$($process.workItemType)/layout?$queryString"
      $processEpicLayout = Invoke-RestMethod -Uri $processEpicLayoutURL -Method Get -ContentType "application/json" -Headers $header
      $layoutAsJSON = $processEpicLayout | ConvertTo-Json -Depth 100
      if ($layoutAsJSON.Contains($FieldToCheck.referenceName)) {
        Write-InfoLog "{orgname}::{ProcessName}::{field} - Form-Field Found as {fieldToCheck} - Nothing to do here" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name)
      }
      else {
        # Add the Form-field to the wit system
        Write-InfoLog "{orgname}::{ProcessName}::{field} - Form-Field NOT Found: {fieldToCheck} - Add it to form" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name)
        if ($null -ne $FieldToCheck.addFieldPOST) {
          $addFieldPOSTbody = $FieldToCheck.addFieldPOST | ConvertTo-Json -Depth 100
          $addFieldPOSTURL = "$($organisation.url)/_apis/work/processes/$($process.ProcessID)/workItemTypes/$($process.WorkItemType)/fields?$queryString"
          $addedField = Invoke-RestMethod -Uri $addFieldPOSTURL -Method Post -ContentType "application/json" -Headers $header -Body $addFieldPOSTbody
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Added new Epic Field as {addedField}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($addedField.name)
          $addedField = $null;
        }
        else {
          Write-WarningLog "{orgname}::{ProcessName}::{field} - No POST addFieldPOST for {fieldToCheck}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name)
        }
      
        if ($null -ne $FieldToCheck.createControlPOST) {

          # Find GroupID
          $group = $null
          $group = FindGroup -groupLabel $FieldToCheck.defaultGroupLabel -orgUrl $organisation.url -ProcessID $process.ProcessID -workItemType $process.WorkItemType -queryString $queryString -header $header
          if ($null -eq $group) {
            Write-ErrorLog "{orgname}::{ProcessName}::{field} - GroupID not found for {FieldToCheck} on {WorkItemType}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name), $($process.WorkItemType)
            continue
          } 
          $ControlInGroup = $group.controls | Where-Object { $_.id -eq $FieldToCheck.referenceName }
          if ($null -ne $ControlInGroup) {
            Write-ErrorLog "{orgname}::{ProcessName}::{field} - Control for {FieldToCheck} is already added to group {group}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName, $($FieldToCheck.name), $($group.label)
            continue
          } 
          $createControlPOSTbody = $null;
          $createControlPOSTbody = $FieldToCheck.createControlPOST | ConvertTo-Json -Depth 100
          $createControlPOSTURL = "$($organisation.url)/_apis/work/processes/$($process.ProcessID)/workItemTypes/$($process.WorkItemType)/layout/groups/$($group.id)/controls?$queryString"
          $addedField = Invoke-RestMethod -Uri $createControlPOSTURL -Method Post -ContentType "application/json" -Headers $header -Body $createControlPOSTbody
          Write-InfoLog "{orgname}::{ProcessName}::{field} - Added new Epic Control {addedField}" -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName,$($addedField.name)
          $addedField = $null;
        }
        else {
          Write-WarningLog "{orgname}::{ProcessName}::{field} - No POST addFieldPOST for {fieldToCheck} " -PropertyValues $sanitisedOrgName, $process.ProcessName,$field.referenceName,$($FieldToCheck.name)
        }
      
      }

    }

    
  }

}

Write-InfoLog "Finished"



