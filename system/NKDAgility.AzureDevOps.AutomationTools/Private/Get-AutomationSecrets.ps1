function Get-AutomationSecrets {
    <#
    .SYNOPSIS
    Loads organisation secrets from a secrets.json file, normalised and cached.

    .DESCRIPTION
    Returns one object per organisation entry with Org, Url, AccessToken and EnvVars properties.
    Accepts both the canonical PascalCase shape (Organisations / Org / Url / AccessToken / EnvVars)
    and camelCase or legacy variants (organisations / org / url / token / envVars / EnvVar).
    Empty or placeholder tokens ('<...>' or 'REPLACE_WITH_PAT') are normalised to $null.
    Returns an empty array when the file does not exist. Never log the returned values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SecretsPath
    )

    if (-not $script:AutomationSecretsCache) { $script:AutomationSecretsCache = @{} }
    $cacheKey = $SecretsPath.ToLowerInvariant()
    if ($script:AutomationSecretsCache.ContainsKey($cacheKey)) {
        return $script:AutomationSecretsCache[$cacheKey]
    }

    if (-not (Test-Path -LiteralPath $SecretsPath)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $SecretsPath -Raw | ConvertFrom-Json

    $prop = {
        param($object, [string[]]$names)
        foreach ($name in $names) {
            $match = $object.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($match -and $null -ne $match.Value) { return $match.Value }
        }
        return $null
    }

    $organisations = & $prop $raw @('Organisations', 'organisations')
    $entries = @()
    foreach ($entry in @($organisations)) {
        if ($null -eq $entry) { continue }
        $token = & $prop $entry @('AccessToken', 'accessToken', 'Token', 'token')
        if ([string]::IsNullOrWhiteSpace($token) -or $token -like '<*>' -or $token -eq 'REPLACE_WITH_PAT') {
            $token = $null
        }
        $envVars = @(& $prop $entry @('EnvVars', 'envVars')) + @(& $prop $entry @('EnvVar', 'envVar'))
        $entries += [pscustomobject]@{
            Org         = & $prop $entry @('Org', 'org', 'Name', 'name')
            Url         = & $prop $entry @('Url', 'url')
            AccessToken = $token
            EnvVars     = @($envVars | Where-Object { $_ })
        }
    }

    $script:AutomationSecretsCache[$cacheKey] = $entries
    return $entries
}
