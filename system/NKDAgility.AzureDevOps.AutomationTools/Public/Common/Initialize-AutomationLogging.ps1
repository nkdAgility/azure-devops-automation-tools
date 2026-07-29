function Initialize-AutomationLogging {
    <#
    .SYNOPSIS
    Starts PoShLog-based logging with a file sink rooted at the given folder.

    .DESCRIPTION
    Module replacement for the legacy src/_includes/logging.ps1 (which hard-codes ./output/log/
    relative to the current directory). The log folder is a parameter, so customer workspaces can
    log under their own output folder. Installs PoShLog and PoShLog.Enrichers for the current user
    if missing. Safe to call repeatedly: once a logger is running, subsequent calls report
    "no change" and return.

    PoShLog is imported into module scope only; use the module's Write-InfoLog / Write-DebugLog /
    Write-ErrorLog wrappers, which delegate to the running logger (or fall back to the console when
    logging was never initialised).

    .EXAMPLE
    Initialize-AutomationLogging -LogFolder 'C:\repos\NKDAClient-Contoso\output\log'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFolder,
        [string]$MinimumLevel = 'Debug'
    )

    if ($script:LoggerInitialized) {
        Write-FixStep "Logging already initialised (no change)."
        return
    }

    foreach ($moduleName in 'PoShLog', 'PoShLog.Enrichers') {
        if ((Get-Module -Name $moduleName -ListAvailable).Count -eq 0) {
            Write-Warning "Module $moduleName missing; installing for current user."
            Install-Module -Name $moduleName -AllowClobber -Scope CurrentUser -Force
        }
    }
    Import-Module PoShLog
    Import-Module PoShLog.Enrichers

    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    $logFile = Join-Path $LogFolder "$(Get-Date -Format 'yyyyMMddHHmmss').txt"

    $script:Logger = New-Logger |
        Set-MinimumLevel -Value $MinimumLevel |
        Add-SinkFile -Path $logFile |
        Add-SinkConsole -RestrictedToMinimumLevel Information |
        Start-Logger
    $script:LoggerInitialized = $true

    PoShLog\Write-InfoLog "LOGGER: Started ($logFile)"
}
