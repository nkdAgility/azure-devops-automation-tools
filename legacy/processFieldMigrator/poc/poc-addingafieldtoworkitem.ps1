


#POST https://dev.azure.com/{organization}/_apis/wit/fields?api-version=7.0

$createBody = '{
    "name": "New Customer Field",
    "referenceName": "Custom.NewCustomerField",
    "description": null,
    "type": "string",
    "usage": "workItem",
    "readOnly": false,
    "canSortBy": true,
    "isQueryable": true,
    "supportedOperations": [
      {
        "referenceName": "SupportedOperations.Equals",
        "name": "="
      }
    ],
    "isIdentity": true,
    "isPicklist": false,
    "isPicklistSuggested": false,
    "url": null
  }' 
  $fieldCreateURL = "$($process.orgUrl)/_apis/wit/fields?$queryString"
  $CreatedField = Invoke-RestMethod -Uri $fieldCreateURL -Method Post -ContentType "application/json" -Headers $header -Body $createBody
  
  $fieldAddBody = '{
    "referenceName": "Custom.NewCustomerField",
    "defaultValue": "",
    "allowGroups": false
  }'
  $fieldAddURL = "$($process.orgUrl)/_apis/work/processes/$($process.ProcessID)/workItemTypes/$($process.WorkItemType)/fields?$queryString"
  $addedField = Invoke-RestMethod -Uri $fieldAddURL -Method Post -ContentType "application/json" -Headers $header -Body $fieldAddBody
  
  $ControlCreateBody = '{
    "id": "Custom.NewCustomerField",
    "order": 0,
    "label": "Customer Stuff",
    "readOnly": false,
    "visible": true,
    "controlType": "FieldControl",
    "inherited": false,
    "watermark": "",
    "metadata": "",
    "isContribution": false
  }'
  $ControlCreateURL = "$($process.orgUrl)/_apis/work/processes/$($process.ProcessID)/workItemTypes/$($process.WorkItemType)/layout/groups/Scrum.Epic.Epic.Details/controls?$queryString"
  $createdControl = Invoke-RestMethod -Uri $ControlCreateURL -Method Post -ContentType "application/json" -Headers $header -Body $ControlCreateBody