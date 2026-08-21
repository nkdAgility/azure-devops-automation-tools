function Invoke-GitHubApi {
    <#
    .SYNOPSIS
    Calls a GitHub REST endpoint.

    .DESCRIPTION
    The GitHub counterpart of Invoke-AzureDevOpsApi: every GitHub-facing command in this
    module goes through here so that URL building, authentication, pagination, rate-limit
    handling and error surfacing are written once.

    Authentication is a Bearer token: -Token when supplied, otherwise resolved by
    Get-GitHubAccessToken (the signed-in gh CLI first, then GITHUB_TOKEN) - ambient
    identity is the default and a stored token is the fallback, mirroring the Entra
    default on the Azure DevOps side. The token is never written to the URL, the log,
    or an exception message.

    GitHub pages list endpoints with an RFC-5988 'Link' response header rather than a
    continuation token; -AllPages follows rel="next" links and returns the aggregated
    array. Rate-limited responses (403/429 carrying Retry-After or an exhausted
    x-ratelimit-remaining) are retried after the server-indicated delay, capped at two
    minutes, up to three times.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')] [string]$Method = 'Get',
        [hashtable]$Query,
        $Body,
        [string]$Token,

        # Follow 'Link: rel="next"' pagination and return the aggregated array.
        [switch]$AllPages,

        # Return $null on 404 instead of throwing, for existence probes.
        [switch]$AllowNotFound
    )

    if (-not $Token) { $Token = Get-GitHubAccessToken }

    $parameters = @{}
    if ($Query) { foreach ($key in $Query.Keys) { $parameters[$key] = $Query[$key] } }
    if ($AllPages -and -not $parameters.ContainsKey('per_page')) { $parameters['per_page'] = 100 }

    $uri = 'https://api.github.com/{0}' -f $Path.TrimStart('/')
    if ($parameters.Count) {
        $queryString = ($parameters.GetEnumerator() | ForEach-Object {
                '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
            }) -join '&'
        $uri = '{0}?{1}' -f $uri, $queryString
    }

    $headers = @{
        Authorization          = 'Bearer ' + $Token
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        # GitHub rejects requests that carry no User-Agent.
        'User-Agent'           = 'NKDAgility.AzureDevOps.AutomationTools'
    }

    $bodyJson = $null
    if ($null -ne $Body) {
        $bodyJson = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
    }

    $results = @()
    $nextUri = $uri
    while ($nextUri) {
        $arguments = @{
            Uri         = $nextUri
            Method      = $Method
            Headers     = $headers
            ContentType = 'application/json'
            ErrorAction = 'Stop'
        }
        if ($bodyJson) { $arguments.Body = $bodyJson }

        $response = $null
        $responseHeaders = $null
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Write-DebugLog "GitHub REST {method} {uri}" -PropertyValues $Method, $nextUri
                $response = Invoke-RestMethod @arguments -ResponseHeadersVariable responseHeaders
                break
            }
            catch {
                $status = $null
                $exceptionResponse = $null
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                    $exceptionResponse = $_.Exception.Response
                    $status = [int]$exceptionResponse.StatusCode
                }

                if ($status -eq 404 -and $AllowNotFound) { return $null }

                # Primary and secondary rate limits answer 403/429 with either a
                # Retry-After delay or an exhausted x-ratelimit-remaining plus the epoch
                # second the window resets. Anything else (a real permission denial) has
                # neither and is not retried.
                if ($attempt -le 3 -and ($status -eq 429 -or $status -eq 403)) {
                    $delay = Get-GitHubRetryDelay -Response $exceptionResponse
                    if ($delay -gt 0) {
                        Write-Warning ("GitHub rate limit hit; retrying in {0}s (attempt {1}/3)." -f $delay, $attempt)
                        Start-Sleep -Seconds $delay
                        continue
                    }
                }

                # ErrorDetails carries the GitHub error payload (message +
                # documentation_url), which is far more useful than the bare status line.
                $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                throw "GitHub REST call failed: $Method $nextUri`n$detail"
            }
        }

        if (-not $AllPages) { return $response }

        $results += @($response)
        $nextUri = $null
        if ($responseHeaders) {
            # The header dictionary's key comparer is not guaranteed case-insensitive.
            $linkKey = @($responseHeaders.Keys | Where-Object { $_ -ieq 'Link' }) | Select-Object -First 1
            if ($linkKey) {
                $link = @($responseHeaders[$linkKey]) -join ', '
                if ($link -match '<([^>]+)>;\s*rel="next"') { $nextUri = $Matches[1] }
            }
        }
    }

    return $results
}
