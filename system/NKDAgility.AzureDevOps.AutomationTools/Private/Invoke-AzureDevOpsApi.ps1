function Invoke-AzureDevOpsApi {
    <#
    .SYNOPSIS
    Calls an Azure DevOps REST endpoint on a collection or organisation.

    .DESCRIPTION
    The REST counterpart of Invoke-WitAdminFix: every REST-based command in this module goes
    through here so that URL building, api-version, authentication and error surfacing are
    written once.

    Authentication is PAT when -Pat is supplied, otherwise the current Windows identity
    (-UseDefaultCredentials), which is what on-premises collections normally want. The PAT is
    never written to the URL, the log, or an exception message.

    ApiVersion defaults to 5.0 rather than 7.x because the sources the Data Import Tool runs
    against are Azure DevOps Server, and 5.0 is available on every supported server version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Path,
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')] [string]$Method = 'Get',
        [string]$ApiVersion = '5.0',
        [hashtable]$Query,
        $Body,
        [string]$Pat
    )

    $parameters = @{}
    if ($Query) { foreach ($key in $Query.Keys) { $parameters[$key] = $Query[$key] } }
    $parameters['api-version'] = $ApiVersion
    $queryString = ($parameters.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'

    $uri = '{0}/{1}?{2}' -f $Collection.TrimEnd('/'), $Path.TrimStart('/'), $queryString

    $arguments = @{
        Uri         = $uri
        Method      = $Method
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($Pat) { $arguments.Headers = Get-AzureDevOpsAuthHeader -Pat $Pat }
    else { $arguments.UseDefaultCredentials = $true }
    if ($null -ne $Body) {
        $arguments.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
    }

    Write-DebugLog "REST {method} {uri}" -PropertyValues $Method, $uri

    try {
        $response = Invoke-RestMethod @arguments
    }
    catch {
        # ErrorDetails carries the Azure DevOps error payload (message + typeKey), which is far
        # more useful than the bare status line.
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure DevOps REST call failed: $Method $uri`n$detail"
    }

    # An unauthenticated on-premises collection answers with the sign-in page rather than a 401,
    # which arrives here as an HTML string instead of an object.
    if ($response -is [string] -and $response -match '(?i)<html') {
        throw "Azure DevOps returned an HTML sign-in page for $uri. The request was not authenticated - pass -Pat, or run as an identity with access to the collection."
    }

    return $response
}
