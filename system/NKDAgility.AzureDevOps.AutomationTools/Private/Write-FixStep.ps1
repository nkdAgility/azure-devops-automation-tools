function Write-FixStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)

    Write-Host "[fix] $Message" -ForegroundColor Cyan
}
