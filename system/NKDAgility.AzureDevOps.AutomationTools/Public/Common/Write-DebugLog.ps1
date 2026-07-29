function Write-DebugLog {
    <#
    .SYNOPSIS
    Writes a debug-level log entry via the module logger.

    .DESCRIPTION
    Delegates to PoShLog's Write-DebugLog when Initialize-AutomationLogging has started a logger;
    otherwise falls back to the standard debug stream. Signature matches the legacy
    src/_includes/logging.ps1 usage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$MessageTemplate,
        [Parameter(Position = 1)]
        [object[]]$PropertyValues
    )

    if ($script:LoggerInitialized) {
        PoShLog\Write-DebugLog @PSBoundParameters
    }
    else {
        Write-Debug $MessageTemplate
    }
}
