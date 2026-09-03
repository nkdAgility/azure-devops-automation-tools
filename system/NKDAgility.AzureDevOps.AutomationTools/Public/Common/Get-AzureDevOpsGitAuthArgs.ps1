function Get-AzureDevOpsGitAuthArgs {
    <#
    .SYNOPSIS
    Builds the git '-c http.extraheader=<value>' argument pair, or nothing at all.

    .DESCRIPTION
    The companion to Resolve-AzureDevOpsAuth for the git half of a migration. Credentials
    reach git through http.extraheader rather than the remote URL, so they never land in
    the URL or the reflog.

    Under Windows integrated auth there is no header, and omitting the option is NOT the
    same as passing an empty one: 'http.extraheader=' makes git send a blank Authorization
    header, which suppresses the challenge/response that Windows auth depends on. This
    returns an empty array in that case so the option is absent rather than blank - which
    is why every call site should go through here instead of interpolating the option
    itself.

    .PARAMETER GitHeader
    The GitHeader from Resolve-AzureDevOpsAuth. Empty means Windows integrated auth.

    .OUTPUTS
    A string array: the two-element '-c', 'http.extraheader=...' pair, or empty.

    .EXAMPLE
    $authArgs = Get-AzureDevOpsGitAuthArgs -GitHeader $script:TargetHeader
    & git @authArgs push origin --all
    #>
    [CmdletBinding()]
    param([string]$GitHeader)

    if ($GitHeader) { return , @('-c', "http.extraheader=$GitHeader") }
    return , @()
}
