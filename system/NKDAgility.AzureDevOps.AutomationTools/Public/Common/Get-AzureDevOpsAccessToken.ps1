function Get-AzureDevOpsAccessToken {
    <#
    .SYNOPSIS
    Acquires an Entra access token for an Azure DevOps organisation or collection.

    .DESCRIPTION
    The public face of the module's Entra sign-in: discovers the collection's tenant,
    signs in pinned to it (once per session at most - tokens are cached and renewed
    shortly before expiry), and returns the access token string.

    An Entra access token works anywhere a PAT does: as a 'Bearer' Authorization header
    on REST calls, and as a git http.extraheader for clone/fetch/push against
    dev.azure.com or *.visualstudio.com. Engines and runbooks that prefer Entra over a
    stored PAT call this first and fall back to the PAT only when it throws - which it
    does, with guidance, for collections that are not Entra-backed (on-premises Azure
    DevOps Server).

    Never log or echo the returned token.

    .PARAMETER Collection
    Collection or organisation URL, e.g. https://dev.azure.com/contoso or
    https://contoso.visualstudio.com.

    .PARAMETER Force
    Re-acquire even when a cached token exists.

    .EXAMPLE
    $token = Get-AzureDevOpsAccessToken -Collection https://compucal.visualstudio.com

    .EXAMPLE
    # Entra first, PAT fallback:
    try { $token = Get-AzureDevOpsAccessToken -Collection $org } catch { $token = $null }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [switch]$Force
    )

    Get-EntraAccessToken -Collection $Collection -Force:$Force
}
