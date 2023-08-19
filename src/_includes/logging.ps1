if ((Get-Module -Name PoShLog -ListAvailable).count -eq 0) {
    Write-Warning -Message ('Module PoshLog Missing.')
    Install-Module -Name PoShLog -AllowClobber -Scope CurrentUser -force
} else {
   Write-Information -Message ('Module PoshLog Detected.')
}
if ((Get-Module -Name PoShLog.Enrichers -ListAvailable).count -eq 0) {
    Write-Warning -Message ('Module PoShLog.Enrichers Missing.')
    Install-Module PoShLog.Enrichers -AllowClobber -Scope CurrentUser -force
} else {
   Write-Information -Message ('Module PoShLog.Enrichers Detected.')
}
If ($logger -eq $null)
{
    $orgfolder = New-item "./output/log/" -ItemType Directory -force
    Write-DebugLog "Created {orgOut}" -PropertyValues $orgfolder

    $date = Get-Date
    $DateStr = $Date.ToString("yyyyMMddHms")
    Import-Module PoShLog
    Import-Module PoShLog.Enrichers
    # Create new logger
    $logger = New-Logger |
        Set-MinimumLevel -Value Debug |
        Add-SinkFile -Path "./output/log/$DateStr.txt" |
        Add-SinkConsole -RestrictedToMinimumLevel Information  |
        Start-Logger

    Write-InfoLog "LOGGER: Started"
    Write-DebugLog "Debug Test"
} else {
    Write-InfoLog "LOGGER: Running"
}

#Close-Logger

function BeginLoggerTitle {
    param (
        [Parameter(Mandatory=$true)]
        [string]$title
    )
    Write-InfoLog "==============================="
    Write-InfoLog "// $title"
    Write-InfoLog "==============================="
}