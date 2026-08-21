function Get-GitHubRepository {
    <#
    .SYNOPSIS
    Lists the repositories in a GitHub organisation, or probes for one by name.

    .DESCRIPTION
    Without -Name, enumerates every repository in the organisation, following GitHub's
    Link-header pagination. With -Name, probes for that single repository and returns
    $null when it does not exist - which is how migration code decides between creating
    and reusing a target repository - rather than throwing.

    .PARAMETER Org
    GitHub organisation name (the org slug, not a URL), e.g. CompuCal-Solutions.

    .PARAMETER Name
    Repository name to probe for. Omit to list the whole organisation.

    .PARAMETER Token
    GitHub token. Omit to use the signed-in gh CLI, then GITHUB_TOKEN (see
    Get-GitHubAccessToken). Reading private organisation repositories requires the repo
    scope (classic) or Contents: read (fine-grained).

    .EXAMPLE
    Get-GitHubRepository -Org 'CompuCal-Solutions' | Format-Table name, visibility

    .EXAMPLE
    if (-not (Get-GitHubRepository -Org $org -Name 'payments')) { 'needs creating' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Org,
        [string]$Name,
        [string]$Token
    )

    $orgSeg = [uri]::EscapeDataString($Org)

    if ($Name) {
        $nameSeg = [uri]::EscapeDataString($Name)
        return Invoke-GitHubApi -Path "repos/$orgSeg/$nameSeg" -Token $Token -AllowNotFound
    }

    Invoke-GitHubApi -Path "orgs/$orgSeg/repos" -Token $Token -AllPages
}
