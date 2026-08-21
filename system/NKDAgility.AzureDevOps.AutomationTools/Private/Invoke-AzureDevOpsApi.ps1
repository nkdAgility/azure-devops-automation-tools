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
        [string]$Pat,

        # Explicit opt-out of Entra, for on-premises Azure DevOps Server collections that
        # authenticate the process identity. Without it, and without -Pat, Entra is used.
        [switch]$UseDefaultCredentials,

        # Follow continuation-token paging and return the aggregated .value array instead
        # of the raw response envelope. Azure DevOps signals a further page via the
        # x-ms-continuationtoken RESPONSE HEADER (which Invoke-RestMethod normally
        # discards) or, on some endpoints, a continuationToken property on the body; both
        # are honoured. Only list endpoints page, so callers that want a whole collection
        # (e.g. every project in an organisation) opt in here.
        [switch]$FollowContinuation
    )

    $arguments = @{
        Method      = $Method
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    # Auth precedence: an explicit PAT, then an explicit -UseDefaultCredentials, then
    # Entra. Entra is the DEFAULT - the other two are opt-outs. When Entra sign-in is
    # unavailable (the collection is not Entra-backed, or acquisition fails) a PAT
    # resolved from the workspace secrets for this collection is the fallback, so a
    # runbook line needs no -Pat as long as secrets.json knows the organisation.
    # On-premises Server collections authenticate the process identity instead and
    # must pass -UseDefaultCredentials; the Entra error says exactly that.
    if ($Pat) {
        $arguments.Headers = Get-AzureDevOpsAuthHeader -Pat $Pat
    }
    elseif ($UseDefaultCredentials) {
        $arguments.UseDefaultCredentials = $true
    }
    else {
        try {
            $arguments.Headers = @{ Authorization = 'Bearer ' + (Get-EntraAccessToken -Collection $Collection) }
        }
        catch {
            $fallbackPat = Resolve-CollectionPat -Collection $Collection
            if (-not $fallbackPat) { throw }
            # Warn once per collection, not once per call - an enumeration makes many.
            if (-not $script:EntraPatFallbackWarned) { $script:EntraPatFallbackWarned = @{} }
            $warnKey = $Collection.TrimEnd('/').ToLowerInvariant()
            if (-not $script:EntraPatFallbackWarned.ContainsKey($warnKey)) {
                Write-Warning ("Entra sign-in unavailable for {0}; using the PAT from secrets. ({1})" -f $Collection, $_.Exception.Message)
                $script:EntraPatFallbackWarned[$warnKey] = $true
            }
            $arguments.Headers = Get-AzureDevOpsAuthHeader -Pat $fallbackPat
        }
    }
    if ($null -ne $Body) {
        $arguments.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
    }

    $values = @()
    $continuationToken = $null
    do {
        $parameters = @{}
        if ($Query) { foreach ($key in $Query.Keys) { $parameters[$key] = $Query[$key] } }
        if ($continuationToken) { $parameters['continuationToken'] = $continuationToken }
        $parameters['api-version'] = $ApiVersion
        $queryString = ($parameters.GetEnumerator() | ForEach-Object {
                '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
            }) -join '&'

        $uri = '{0}/{1}?{2}' -f $Collection.TrimEnd('/'), $Path.TrimStart('/'), $queryString
        $arguments.Uri = $uri

        Write-DebugLog "REST {method} {uri}" -PropertyValues $Method, $uri

        try {
            $responseHeaders = $null
            $response = Invoke-RestMethod @arguments -ResponseHeadersVariable responseHeaders
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

        if (-not $FollowContinuation) { return $response }

        $values += @($response.value)
        $continuationToken = $null
        if ($responseHeaders) {
            # The header dictionary's key comparer is not guaranteed case-insensitive.
            $tokenKey = @($responseHeaders.Keys | Where-Object { $_ -ieq 'x-ms-continuationtoken' }) | Select-Object -First 1
            if ($tokenKey) { $continuationToken = @($responseHeaders[$tokenKey])[0] }
        }
        if (-not $continuationToken -and
            $response.PSObject.Properties['continuationToken'] -and
            $response.continuationToken) {
            $continuationToken = $response.continuationToken
        }
    } while ($continuationToken)

    return $values
}
