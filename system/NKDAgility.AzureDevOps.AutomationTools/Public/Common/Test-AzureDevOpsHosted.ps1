function Test-AzureDevOpsHosted {
    <#
    .SYNOPSIS
    Says whether a collection URL is the hosted Azure DevOps service or an on-premises server.

    .DESCRIPTION
    The one place the host rule is written down, used by Resolve-AzureDevOpsAuth to pick
    the ambient credential mechanism and by the engines to pick URL shapes. Only two hosts
    are the cloud service:

        https://dev.azure.com/<org>       hosted
        https://<org>.visualstudio.com    hosted (legacy)
        anything else                     Azure DevOps Server, on-premises

    The distinction matters twice over. Authentication: on-premises means Windows
    integrated - send nothing and let the stack negotiate; Entra cannot succeed there.
    URLs: the hosted service splits functionality across subdomains (feeds., pkgs.,
    vssps.) that simply do not exist on-premises, where everything is served from the
    collection base - so any URL built for the wrong answer here lands on the wrong
    machine entirely.

    .PARAMETER Collection
    Collection or organisation URL.

    .EXAMPLE
    Test-AzureDevOpsHosted -Collection 'https://dev.azure.com/contoso'          # True
    Test-AzureDevOpsHosted -Collection 'https://tfs.corp/DefaultCollection'     # False
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection
    )

    $hostName = try { ([uri]$Collection).Host } catch { '' }
    return ($hostName -eq 'dev.azure.com' -or $hostName -like '*.visualstudio.com')
}
