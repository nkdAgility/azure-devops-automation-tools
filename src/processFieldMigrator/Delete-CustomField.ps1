# Woops I made a mistake and need to delete a field.
clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1

$config = Get-Content "$dataFolder\organisations.json" | Out-String | ConvertFrom-Json

# Update this for the field refanme to remove
$FieldToDeleteRefname = "Custom.8e5b713b-c669-4cf2-ad63-edc8ee797cb7"

foreach ($org in $config.organisations)
{
    if ($org.enabled -eq $false)
    {
        Write-InfoLog "Skipping {org} as it is disabled" -PropertyValues $org.url
        continue
    }
    $token = $null
    $token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($org.pat)"))
    $header = @{authorization = "Basic $token" }
    
    Write-InfoLog  "Deleting Field {Field} from {org}" -PropertyValues $FieldToDeleteRefname, $org.url
    # DELETE https://dev.azure.com/{organization}/{fieldNameOrRefName}
    $deleteFiledURL = "$($org.url)/_apis/wit/fields/$FieldToDeleteRefname/?$queryString"
    Write-InfoLog $deleteFiledURL
    $DeletedField = Invoke-RestMethod -Uri $deleteFiledURL -Method Delete -ContentType "application/json" -Headers $header
}



