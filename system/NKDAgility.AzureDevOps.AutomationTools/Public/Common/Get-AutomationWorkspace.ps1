function Get-AutomationWorkspace {
    <#
    .SYNOPSIS
    Returns the initialised workspace context (root, data/output/exports folders, query strings).

    .DESCRIPTION
    Throws when no workspace has been initialised in this session - run init.ps1 (customer repo)
    or Initialize-AutomationWorkspace first. Returns a copy, so callers cannot mutate the
    module's context.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Workspace) {
        throw "No workspace initialised. Run Initialize-AutomationWorkspace (or the customer repo's init.ps1) first."
    }

    return [pscustomobject]$script:Workspace.Clone()
}
