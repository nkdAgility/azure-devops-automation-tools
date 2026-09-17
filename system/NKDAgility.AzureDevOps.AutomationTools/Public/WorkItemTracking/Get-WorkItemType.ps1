function Get-WorkItemType {
    <#
    .SYNOPSIS
    Lists the work item types defined in a project, over REST.

    .DESCRIPTION
    The REST counterpart to Get-WitWorkItemType. Same question, different transport, and
    the plain noun is what says so: this one works against an Azure DevOps Services
    organisation and needs a token or an Entra sign-in, while Get-WitWorkItemType shells
    out to witadmin.exe against an on-premises collection.

    Names are returned verbatim, and the console listing quotes them, so trailing spaces
    and unexpected casing are visible. Both are common causes of a migration reporting
    "work item type does not exist in target system" for a type that looks present.

    Ported from the NKDAClient-United-Machine Get-WorkItemTypes.ps1 script. The
    hand-rolled auth and env-var placeholder expansion it carried are gone: auth is the
    module's own (-Pat, -UseDefaultCredentials, otherwise Entra), and tokens come from
    the workspace secrets file via Set-AutomationSecrets.

    .PARAMETER Collection
    Collection or organisation URL, e.g. https://dev.azure.com/contoso.

    .PARAMETER Project
    Project name to list work item types for.

    .PARAMETER Name
    Optional. One or more type names to check for (exact, case-sensitive match). Each is
    reported as present or missing, and the command throws when any is missing - so it
    can gate a migration step.

    .PARAMETER Pat
    Personal Access Token with at least 'Work Items (Read)'. Omit to use Entra.

    .PARAMETER UseDefaultCredentials
    Authenticate as the process identity instead of Entra.

    .PARAMETER ApiVersion
    REST API version. Defaults to 5.0, the module-wide default that every supported
    server version understands.

    .EXAMPLE
    Get-WorkItemType -Collection 'https://dev.azure.com/contoso' -Project 'Mammoth'

    .EXAMPLE
    Get-WorkItemType -Collection $target -Project 'Mammoth' -Name 'Bug', 'Feedback Request'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$Project,

        [string[]]$Name,

        [string]$Pat,

        [switch]$UseDefaultCredentials,

        [string]$ApiVersion = '5.0'
    )

    $response = Invoke-AzureDevOpsApi -Collection $Collection -UseDefaultCredentials:$UseDefaultCredentials `
        -Path ('{0}/_apis/wit/workitemtypes' -f [uri]::EscapeDataString($Project)) `
        -Pat $Pat -ApiVersion $ApiVersion

    # A failed or redirected sign-in returns an HTML page rather than JSON. Say that,
    # instead of letting it surface as "property 'value' cannot be found on this object".
    if ($response -is [string]) {
        throw "Received HTML instead of JSON from '$Collection'. The credential is likely wrong, expired, or missing the 'Work Items (Read)' scope."
    }

    $types = @($response.value) | Sort-Object name

    Write-FixStep ("'{0}' has {1} work item type(s):" -f $Project, $types.Count)
    foreach ($type in $types) {
        Write-Host ("    '{0}'" -f $type.name) -ForegroundColor DarkGray
    }

    if ($Name) {
        $present = @($types.name)
        $missing = @($Name | Where-Object { $_ -cnotin $present })
        foreach ($wanted in $Name) {
            $found = $wanted -cin $present
            $colour = if ($found) { 'Green' } else { 'Red' }
            Write-Host ("    [{0}] '{1}'" -f $(if ($found) { 'ok' } else { 'MISSING' }), $wanted) -ForegroundColor $colour
        }
        if ($missing.Count) {
            throw ("Project '{0}' is missing {1} work item type(s): {2}" -f $Project, $missing.Count, ($missing -join ', '))
        }
    }

    return $types.name
}
