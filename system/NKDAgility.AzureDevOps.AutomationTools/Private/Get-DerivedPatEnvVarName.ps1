function Get-DerivedPatEnvVarName {
    <#
    .SYNOPSIS
    Returns the predictable AZDO_PAT_<ORG> environment variable name for an organisation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Org
    )

    'AZDO_PAT_' + ($Org.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
}
