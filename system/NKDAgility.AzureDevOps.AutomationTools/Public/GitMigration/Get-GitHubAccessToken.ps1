function Get-GitHubAccessToken {
    <#
    .SYNOPSIS
    Resolves a GitHub token: the signed-in GitHub CLI first, then GITHUB_TOKEN.

    .DESCRIPTION
    The GitHub counterpart of Get-AzureDevOpsAccessToken: ambient identity first, stored
    token as the fallback. Resolution order:

      1. The GitHub CLI ('gh auth token') when gh is on PATH and signed in - the
         interactive-identity default, so day-to-day runs need no stored token at all.
      2. The GITHUB_TOKEN environment variable (exported from secrets.json by
         Set-AutomationSecrets).

    Throws with guidance when neither yields a token. The returned token works for both
    the REST API (Bearer header) and git-over-HTTPS (Basic, user 'x-access-token').

    Never log or echo the returned token.

    .EXAMPLE
    $token = Get-GitHubAccessToken
    #>
    [CmdletBinding()]
    param()

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # A signed-out gh exits non-zero; that is the fallback path, not an error.
        $PSNativeCommandUseErrorActionPreference = $false
        $token = $null
        try { $token = @(& gh auth token 2>$null) | Select-Object -First 1 } catch { $token = $null }
        if ($LASTEXITCODE -ne 0) { $token = $null }
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            Write-DebugLog 'GitHub auth: token from the gh CLI'
            return $token
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        Write-DebugLog 'GitHub auth: token from GITHUB_TOKEN'
        return $env:GITHUB_TOKEN
    }

    throw "No GitHub credential available. Sign in with 'gh auth login', or set GITHUB_TOKEN (add the token to secrets\secrets.json with EnvVars ['GITHUB_TOKEN'] and run Set-AutomationSecrets)."
}
