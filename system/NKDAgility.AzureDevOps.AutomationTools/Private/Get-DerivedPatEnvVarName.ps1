function Get-DerivedPatEnvVarName {
    <#
    .SYNOPSIS
    Returns the predictable AZDO_PAT_<ORG> environment variable name for an organisation,
    or AZDO_PAT_<ORG>__<PROJECT> for a per-project PAT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Org,

        [string]$Project
    )

    $name = 'AZDO_PAT_' + ($Org.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
    if ($Project) { $name += '__' + ($Project.ToUpperInvariant() -replace '[^A-Z0-9]', '_') }
    $name
}
