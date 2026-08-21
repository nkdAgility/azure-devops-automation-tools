function Get-TeamProject {
    <#
    .SYNOPSIS
    Lists the team projects in an Azure DevOps organisation or collection.

    .DESCRIPTION
    Reads _apis/projects with continuation-token paging, so organisations with more
    projects than one page returns are enumerated completely. The collection URL is used
    verbatim, so both https://dev.azure.com/<org> and the older
    https://<org>.visualstudio.com form work unchanged.

    .PARAMETER Collection
    Organisation or collection URL, e.g. https://dev.azure.com/contoso or
    https://contoso.visualstudio.com.

    .PARAMETER Name
    Return only the named project.

    .PARAMETER Pat
    Personal access token. Omit to authenticate via Entra (Services) or pass
    -UseDefaultCredentials for an on-premises collection.

    .PARAMETER UseDefaultCredentials
    Authenticate as the process identity instead of Entra. Required for on-premises
    Azure DevOps Server collections, which have no Entra tenant behind them.

    .EXAMPLE
    Get-TeamProject -Collection https://contoso.visualstudio.com -Pat $pat | Format-Table name, id
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Name,
        [string]$Pat,

        [switch]$UseDefaultCredentials,
        [string]$ApiVersion = '7.1'
    )

    $projects = @(Invoke-AzureDevOpsApi -Collection $Collection -Path '_apis/projects' `
            -ApiVersion $ApiVersion -Query @{ '$top' = 100 } -Pat $Pat `
            -UseDefaultCredentials:$UseDefaultCredentials -FollowContinuation)

    if ($Name) {
        $projects = @($projects | Where-Object { $_.name -eq $Name })
    }

    $projects
}
