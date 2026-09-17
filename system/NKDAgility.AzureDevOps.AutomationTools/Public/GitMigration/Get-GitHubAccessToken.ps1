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

    With -Org, each candidate is validated against the organisation before it is
    returned, and an unusable one is skipped with a warning instead of being handed to
    the caller. This matters for SAML/Entra-SSO organisations: the gh CLI's OAuth token
    only works while the user has an ACTIVE SSO session with the org, so a token that
    worked an hour ago can answer 403 'Resource protected by organization SAML
    enforcement' now - in which case an SSO-authorised PAT in GITHUB_TOKEN quietly takes
    over.

    Throws with guidance when nothing usable remains. The returned token works for both
    the REST API (Bearer header) and git-over-HTTPS (Basic, user 'x-access-token').

    Never log or echo the returned token.

    .PARAMETER Org
    Organisation to validate candidates against (GET /orgs/<org> must succeed).
    Omit to return the first credential found, unvalidated.

    .EXAMPLE
    $token = Get-GitHubAccessToken -Org 'CompuCal-Solutions'
    #>
    [CmdletBinding()]
    param(
        [string]$Org
    )

    $candidates = [System.Collections.Generic.List[object]]::new()

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # A signed-out gh exits non-zero; that is the fallback path, not an error.
        $PSNativeCommandUseErrorActionPreference = $false
        $token = $null
        try { $token = @(& gh auth token 2>$null) | Select-Object -First 1 } catch { $token = $null }
        if ($LASTEXITCODE -ne 0) { $token = $null }
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $candidates.Add(@{ Source = 'the gh CLI'; Token = $token })
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $candidates.Add(@{ Source = 'GITHUB_TOKEN'; Token = $env:GITHUB_TOKEN })
    }

    $lastError = $null
    foreach ($candidate in $candidates) {
        if (-not $Org) {
            Write-DebugLog "GitHub auth: token from {source}" -PropertyValues $candidate.Source
            return $candidate.Token
        }
        try {
            $null = Invoke-GitHubApi -Path ('orgs/{0}' -f [uri]::EscapeDataString($Org)) -Token $candidate.Token
            Write-DebugLog "GitHub auth: token from {source}, validated against {org}" -PropertyValues $candidate.Source, $Org
            return $candidate.Token
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Warning ("The GitHub credential from {0} cannot access '{1}'; trying the next credential. ({2})" -f `
                    $candidate.Source, $Org, (($lastError -split "`n")[0]))
        }
    }

    $guidance = "No usable GitHub credential. Sign in with 'gh auth login', or set GITHUB_TOKEN (add the token to secrets\secrets.json with EnvVars ['GITHUB_TOKEN'] and run Set-AutomationSecrets)."
    if ($Org) {
        $guidance += " If '$Org' enforces SAML/Entra SSO: refresh your session at https://github.com/orgs/$Org/sso, or use a classic PAT authorised for the org (token settings -> Configure SSO -> Authorize) - unlike the gh CLI's OAuth token, an authorised PAT does not need an active SSO session."
    }
    if ($lastError) { $guidance += "`nLast error: $lastError" }
    throw $guidance
}
