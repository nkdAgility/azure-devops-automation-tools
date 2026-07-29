# Legacy shim - this repo holds no customer data and no config.json.
#
# Every engagement now runs from its own client workspace repo, scaffolded by
# bootstrap.ps1 (see the README). This file used to create .\data\<environment>\
# inside the tools repo and generate config.json; it no longer does either.
# Instead it resolves the session variables the older src\** scripts expect from
# the initialised workspace, so those scripts read the CLIENT repo's data folder.
#
# Dot-source it after the client repo's init.ps1:
#
#     cd <client repo>
#     . .\init.ps1
#     . $env:USERPROFILE\source\repos\azure-devops-automation-tools\src\_includes\setup.ps1

$modulePath = Join-Path $PSScriptRoot '..\..\system\NKDAgility.AzureDevOps.AutomationTools\NKDAgility.AzureDevOps.AutomationTools.psd1'
if (-not (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools')) {
    Import-Module $modulePath -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'logging.ps1')

# Throws with instructions when no workspace is initialised, so a legacy script
# can never silently fall back to a data folder inside the tools repo.
$workspace = Get-AutomationWorkspace

$queryString = $workspace.QueryString
$queryStringPreview = $workspace.QueryStringPreview
$dataFolder = $workspace.DataFolder
$outputFolder = $workspace.OutputFolder

Write-InfoLog "Data folder {dataFolder}" -PropertyValues $dataFolder
Write-InfoLog "Output folder {outputFolder}" -PropertyValues $outputFolder
