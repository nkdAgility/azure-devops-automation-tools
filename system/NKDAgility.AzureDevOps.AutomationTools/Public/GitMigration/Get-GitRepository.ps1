function Get-GitRepository {
    <#
    .SYNOPSIS
    Lists the git repositories in an Azure DevOps project.

    .DESCRIPTION
    Reads <project>/_apis/git/repositories. Disabled repositories are excluded by default
    because they cannot be cloned; pass -IncludeDisabled to see them anyway (e.g. for an
    inventory that records their existence). The collection URL is used verbatim, so both
    https://dev.azure.com/<org> and the older https://<org>.visualstudio.com form work.

    .PARAMETER Collection
    Organisation or collection URL.

    .PARAMETER Project
    Project name.

    .PARAMETER Name
    Return only the named repository.

    .PARAMETER IncludeDisabled
    Include disabled repositories in the result.

    .PARAMETER Pat
    Personal access token. Omit to authenticate via Entra (Services) or pass
    -UseDefaultCredentials for an on-premises collection.

    .PARAMETER UseDefaultCredentials
    Authenticate as the process identity instead of Entra. Required for on-premises
    Azure DevOps Server collections, which have no Entra tenant behind them.

    .EXAMPLE
    Get-TeamProject -Collection $org -Pat $pat |
        ForEach-Object { Get-GitRepository -Collection $org -Project $_.name -Pat $pat }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$Name,
        [switch]$IncludeDisabled,
        [string]$Pat,

        [switch]$UseDefaultCredentials,
        [string]$ApiVersion = '7.1'
    )

    $path = '{0}/_apis/git/repositories' -f [uri]::EscapeDataString($Project)
    $response = Invoke-AzureDevOpsApi -Collection $Collection -Path $path `
        -ApiVersion $ApiVersion -Pat $Pat -UseDefaultCredentials:$UseDefaultCredentials

    $repos = @($response.value)
    if (-not $IncludeDisabled) {
        $repos = @($repos | Where-Object { -not ($_.PSObject.Properties['isDisabled'] -and $_.isDisabled) })
    }
    if ($Name) {
        $repos = @($repos | Where-Object { $_.name -eq $Name })
    }

    $repos
}
