function Write-ErrorLog {
    <#
    .SYNOPSIS
    Writes an error-level log entry via the module logger.

    .DESCRIPTION
    Delegates to PoShLog's Write-ErrorLog when Initialize-AutomationLogging has started a logger;
    otherwise falls back to Write-Warning (non-terminating) so scripts control their own flow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$MessageTemplate,
        [Parameter(Position = 1)]
        [object[]]$PropertyValues
    )

    if ($script:LoggerInitialized) {
        PoShLog\Write-ErrorLog @PSBoundParameters
    }
    else {
        Write-Warning $MessageTemplate
    }
}
