function Write-InfoLog {
    <#
    .SYNOPSIS
    Writes an information-level log entry via the module logger.

    .DESCRIPTION
    Delegates to PoShLog's Write-InfoLog when Initialize-AutomationLogging has started a logger;
    otherwise falls back to the console so scripts never fail just because logging was not set up.
    Signature matches the legacy src/_includes/logging.ps1 usage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$MessageTemplate,
        [Parameter(Position = 1)]
        [object[]]$PropertyValues
    )

    if ($script:LoggerInitialized) {
        PoShLog\Write-InfoLog @PSBoundParameters
    }
    else {
        Write-Host $MessageTemplate
    }
}
