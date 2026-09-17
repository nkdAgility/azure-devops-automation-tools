function Get-AzureDevOpsSignInAccount {
    <#
    .SYNOPSIS
    The user principal name to sign in as for a collection, or $null.

    .DESCRIPTION
    Which identity to use is per ORGANISATION, not per machine: a consultant routinely
    holds one account per customer tenant (martin@nkdagility.com here, mhinshelwood@slb.com
    there) and the right one cannot be guessed from whichever happens to be signed in.
    Naming it up front also stops the Entra sign-in landing on an account picker, or
    silently minting a token for the wrong identity.

    Resolved in order:

      1. AZDO_SIGNIN_<ORG> - org upper-cased, non-alphanumeric characters replaced with
         underscores, matching the AZDO_PAT_<ORG> convention. CI sets this; a shell
         override wins over the file.
      2. The 'SignInAs' property of the matching entry in secrets.json, by Url
         (trailing-slash and case insensitive) or by Org name.

    Returns $null when nothing is configured, which means "sign in with whatever account
    the user picks" - the previous behaviour.

    A UPN is not a secret, but it lives beside the tokens because that is where
    'how do I authenticate to this organisation' already lives, and because it is
    per-user: secrets.json is gitignored, so one engagement's committed config does not
    pin a colleague to someone else's identity.

    .PARAMETER Collection
    Collection or organisation URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection
    )

    $trimmed = $Collection.TrimEnd('/')
    $org = ($trimmed -split '/')[-1]

    # 1. Environment override.
    if ($org) {
        $envName = 'AZDO_SIGNIN_{0}' -f ($org.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
        $fromEnv = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv.Trim() }
    }

    # 2. secrets.json. Absent file, absent workspace and malformed entries are all just
    #    "not configured" - resolving an identity must never break a PAT-only run.
    try {
        if (-not $script:Workspace) { return $null }
        $secretsPath = $script:Workspace.SecretsPath
        if (-not $secretsPath -or -not (Test-Path -LiteralPath $secretsPath)) { return $null }

        foreach ($entry in @(Get-AutomationSecrets -SecretsPath $secretsPath)) {
            $signIn = $null
            try { $signIn = $entry.SignInAs } catch { continue }
            if ([string]::IsNullOrWhiteSpace($signIn)) { continue }

            $urlMatch = $entry.Url -and ([string]$entry.Url).TrimEnd('/') -ieq $trimmed
            $orgMatch = $entry.Org -and $org -and ([string]$entry.Org) -ieq $org
            if ($urlMatch -or $orgMatch) { return ([string]$signIn).Trim() }
        }
    }
    catch {
        Write-Verbose "Sign-in account lookup failed for '$Collection': $($_.Exception.Message)"
    }

    return $null
}
