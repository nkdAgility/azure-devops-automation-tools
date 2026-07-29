# Legacy logging helper.
#
# The logger itself is now started by Initialize-AutomationLogging (called by
# Initialize-AutomationWorkspace), which writes into the CLIENT workspace's
# output\log folder. This file used to start its own logger against .\output\log
# relative to the current directory, which created folders inside whichever repo
# you happened to be standing in - exactly what the client-workspace model exists
# to avoid. All that remains here is the title banner the older src\** scripts
# call, plus the PoShLog availability check.

if ((Get-Module -Name PoShLog -ListAvailable).Count -eq 0) {
    Write-Warning -Message 'Module PoShLog missing; installing for the current user.'
    Install-Module -Name PoShLog -AllowClobber -Scope CurrentUser -Force
}
if ((Get-Module -Name PoShLog.Enrichers -ListAvailable).Count -eq 0) {
    Write-Warning -Message 'Module PoShLog.Enrichers missing; installing for the current user.'
    Install-Module -Name PoShLog.Enrichers -AllowClobber -Scope CurrentUser -Force
}

function BeginLoggerTitle {
    param (
        [Parameter(Mandatory = $true)]
        [string]$title
    )
    Write-InfoLog "==============================="
    Write-InfoLog "// $title"
    Write-InfoLog "==============================="
}
