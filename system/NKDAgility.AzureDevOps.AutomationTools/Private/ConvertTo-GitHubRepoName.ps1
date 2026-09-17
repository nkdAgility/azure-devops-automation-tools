function ConvertTo-GitHubRepoName {
    <#
    .SYNOPSIS
    Converts an Azure DevOps repository name into a valid GitHub repository name.

    .DESCRIPTION
    GitHub repository names may only contain alphanumerics, hyphens, underscores and
    periods, while Azure DevOps allows spaces and most punctuation. Every run of
    disallowed characters becomes a single hyphen, repeated hyphens collapse, and
    leading/trailing hyphens are trimmed. Case is preserved.

    This is a pure name transform: collision handling belongs to the caller
    (Export-GitRepoInventory), which sees the whole set of names.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $slug = $Name -replace '[^A-Za-z0-9._-]+', '-'
    $slug = $slug -replace '-{2,}', '-'
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq '.' -or $slug -eq '..') {
        throw "Repository name '$Name' cannot be converted to a valid GitHub repository name."
    }

    $slug
}
