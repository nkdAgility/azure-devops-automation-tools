function Resolve-CollectionPat {
    <#
    .SYNOPSIS
    Resolves a PAT for a collection URL from the workspace secrets or the environment.

    .DESCRIPTION
    The fallback half of Entra-first authentication: when Entra sign-in is unavailable
    for a collection, Invoke-AzureDevOpsApi asks here for a stored PAT before giving up.

    Resolution order:
      1. A secrets.json organisation entry matched by URL (trailing-slash and case
         insensitive), by Org name, or by org-name suffix of the URL.
      2. The derived AZDO_PAT_<ORG> environment variable, where <ORG> is the last URL
         segment for dev.azure.com/<org> style URLs or the subdomain for
         <org>.visualstudio.com style URLs.

    Returns $null - never throws - when nothing matches. Cached per collection for the
    session. Never log the returned value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection
    )

    $key = $Collection.TrimEnd('/').ToLowerInvariant()
    if (-not $script:CollectionPatCache) { $script:CollectionPatCache = @{} }
    if ($script:CollectionPatCache.ContainsKey($key)) { return $script:CollectionPatCache[$key] }

    # The org name lives in a different URL segment per hosting style.
    $orgName = $null
    try {
        $uri = [uri]$Collection
        $orgName = if ($uri.Host -match '^(?<org>[^.]+)\.visualstudio\.com$') { $Matches['org'] }
        else { ($Collection.TrimEnd('/') -split '/')[-1] }
    }
    catch {
        $orgName = ($Collection.TrimEnd('/') -split '/')[-1]
    }

    $normalise = { param($value) if ($value) { $value.TrimEnd('/').ToLowerInvariant() } }

    $pat = $null
    if ($script:Workspace -and $script:Workspace.SecretsPath) {
        $secrets = @(Get-AutomationSecrets -SecretsPath $script:Workspace.SecretsPath)
        $match = $secrets | Where-Object {
            $_.AccessToken -and (
                (& $normalise $_.Url) -eq (& $normalise $Collection) -or
                ($_.Org -and $orgName -and $_.Org -ieq $orgName) -or
                ($_.Org -and (& $normalise $Collection).EndsWith('/' + $_.Org.ToLowerInvariant()))
            )
        } | Select-Object -First 1
        if ($match) { $pat = $match.AccessToken }
    }

    if (-not $pat -and $orgName) {
        $envName = Get-DerivedPatEnvVarName -Org $orgName
        $envValue = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) { $pat = $envValue }
    }

    $script:CollectionPatCache[$key] = $pat
    return $pat
}
