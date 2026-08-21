function Get-GitHubRetryDelay {
    <#
    .SYNOPSIS
    Extracts the retry delay a rate-limited GitHub response asks for.

    .DESCRIPTION
    Reads Retry-After, or an exhausted x-ratelimit-remaining plus the x-ratelimit-reset
    epoch second, from the response headers and returns the delay in whole seconds,
    capped at 120. Returns 0 when the response carries no rate-limit signal, so
    Invoke-GitHubApi can tell a rate limit from a genuine 403 permission denial and
    only retry the former.
    #>
    param($Response)

    $delay = 0
    try {
        if ($Response -and $Response.Headers) {
            $values = $null
            if ($Response.Headers.TryGetValues('Retry-After', [ref]$values)) {
                $delay = [int](@($values)[0])
            }
            else {
                $remaining = $null
                $reset = $null
                if ($Response.Headers.TryGetValues('x-ratelimit-remaining', [ref]$remaining) -and
                    (@($remaining)[0] -eq '0') -and
                    $Response.Headers.TryGetValues('x-ratelimit-reset', [ref]$reset)) {
                    $delay = [int](@($reset)[0]) - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1
                }
            }
        }
    }
    catch {
        # A malformed header must not turn a rate-limit retry into a new failure.
        $delay = 0
    }

    if ($delay -lt 0) { $delay = 0 }
    [Math]::Min($delay, 120)
}
