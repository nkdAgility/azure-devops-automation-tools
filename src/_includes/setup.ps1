enum dataEnvironments {
    debug
    sample
    release
}
. .\src\_includes\logging.ps1

$setupConfigFile = ".\config.json"
if ((Test-Path $setupConfigFile) -eq $false) {

    $setupConfig = @{
        dataEnvironment    = [dataEnvironments]::debug
        queryString        = "api-version=7.0"
        queryStringPreview = "api-version=7.1-preview.3"
        outputFolder       = "C:\temp\output"
        dataFolder         = ".\data\"
    }
    Out-File -FilePath ".\config.json" -InputObject ($setupConfig | ConvertTo-Json -Depth 100 -EnumsAsStrings) -Encoding ascii
}

$setupConfig = Get-Content -Path $setupConfigFile | ConvertFrom-Json

# VALRIABLES
$queryString = $setupConfig.queryString
$queryStringPreview = $setupConfig.queryStringPreview
$dataEnvironment = $setupConfig.dataEnvironment
$outputFolder = $setupConfig.outputFolder
$dataFolder = "$($setupConfig.dataFolder)\$dataEnvironment\"

# Create any folders that don't exist
if (Test-Path $outputFolder) {
    Write-DebugLog "Output folder {outputFolder} exists" -PropertyValues $outputFolder
}
else {
    Write-DebugLog "Output folder {outputFolder} does not exist" -PropertyValues $outputFolder
    $outputFolderCreated = New-item $outputFolder -ItemType Directory -force
    Write-DebugLog "Created {outputFolder}" -PropertyValues $outputFolderCreated
}
Write-InfoLog "Output folder {outputFolder}" -PropertyValues $outputFolder
# Data Folder

if (Test-Path $dataFolder) {
    Write-DebugLog "Data folder {dataFolder} exists" -PropertyValues $dataFolder
}
else {
    Write-DebugLog "Data folder {dataFolder} does not exist" -PropertyValues $dataFolder
    $dataFolderCreated = New-item $dataFolder -ItemType Directory -force
    Write-DebugLog "Created {dataFolder}" -PropertyValues $dataFolder
}
Write-InfoLog "Data folder {dataFolder}" -PropertyValues $dataFolder