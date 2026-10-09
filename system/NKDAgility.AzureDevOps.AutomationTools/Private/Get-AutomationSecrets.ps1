function Get-AutomationSecrets {
    <#
    .SYNOPSIS
    Loads organisation secrets from a secrets.json file, normalised and cached.

    .DESCRIPTION
    Returns one object per organisation entry with Org, Url, AccessToken, EnvVars,
    SignInAs and Projects properties. Projects is an ordered map of project name to PAT,
    empty unless the entry carries per-project tokens.
    Accepts both the canonical PascalCase shape (Organisations / Org / Url / AccessToken /
    EnvVars / SignInAs) and camelCase or legacy variants (organisations / org / url / token /
    envVars / EnvVar / signInAs).

    SignInAs is the user principal name to authenticate as for that organisation - the
    Entra identity, not a secret. It sits here because this is already the per-organisation
    answer to 'how do I authenticate', and because it is per-user: one consultant's
    account must not be committed into another's workspace.
    Empty and placeholder tokens ('<...>' or 'REPLACE_WITH_PAT') both normalise AccessToken to
    $null, but are distinguished by the AmbientAuth and IsPlaceholder flags: no token means the
    organisation uses ambient identity (intended), a placeholder means somebody has not filled
    it in (worth warning about).
    Returns an empty array when the file does not exist. Never log the returned values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SecretsPath,

        [switch]$Refresh
    )

    if (-not $script:AutomationSecretsCache) { $script:AutomationSecretsCache = @{} }
    $cacheKey = $SecretsPath.ToLowerInvariant()
    if (-not $Refresh -and $script:AutomationSecretsCache.ContainsKey($cacheKey)) {
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

        # Two very different reasons for an organisation to carry no token, and callers
        # have to tell them apart:
        #
        #   ambient      no AccessToken at all - the organisation authenticates with Entra
        #                or the current Windows identity. The DESIRED state for most
        #                organisations, and nothing to report.
        #   placeholder  '<something>' still sitting there - somebody meant to fill it in
        #                and did not. Worth a warning.
        #
        # Collapsing both to $null made the workspace warn on every single run about
        # organisations that were correctly configured for ambient auth, which trains
        # people to scroll past the warning that actually matters.
        $isPlaceholder = ($token -like '<*>' -or $token -eq 'REPLACE_WITH_PAT')
        $isAmbient = -not $isPlaceholder -and [string]::IsNullOrWhiteSpace($token)
        if ($isPlaceholder -or [string]::IsNullOrWhiteSpace($token)) {
            $token = $null
        }
        # Per-project PATs, for customers who issue one token per source project rather
        # than one per organisation. Accepts a map ({ "Project": "<pat>" }) or a list of
        # { Project, AccessToken } objects. Placeholders are dropped, never exported.
        $projects = [ordered]@{}
        # Read the property directly: returning it through $prop would unroll a
        # one-element list into a bare object that looks like a map.
        $rawProjects = ($entry.PSObject.Properties | Where-Object { $_.Name -in @('Projects', 'projects') } | Select-Object -First 1).Value
        if ($rawProjects -is [System.Management.Automation.PSCustomObject]) {
            $pairs = @($rawProjects.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) })
        }
        else {
            $pairs = @(@($rawProjects) | Where-Object { $_ } | ForEach-Object {
                    , @((& $prop $_ @('Project', 'project', 'Name', 'name')), (& $prop $_ @('AccessToken', 'accessToken', 'Token', 'token')))
                })
        }
        foreach ($pair in $pairs) {
            $projectName = [string]$pair[0]
            $projectToken = [string]$pair[1]
            if ([string]::IsNullOrWhiteSpace($projectName) -or [string]::IsNullOrWhiteSpace($projectToken)) { continue }
            if ($projectToken -like '<*>' -or $projectToken -eq 'REPLACE_WITH_PAT') { continue }
            $projects[$projectName] = $projectToken
        }

        $envVars = @(& $prop $entry @('EnvVars', 'envVars')) + @(& $prop $entry @('EnvVar', 'envVar'))
        $entries += [pscustomobject]@{
            Org           = & $prop $entry @('Org', 'org', 'Name', 'name')
            Url           = & $prop $entry @('Url', 'url')
            AccessToken   = $token
            AmbientAuth   = $isAmbient
            IsPlaceholder = $isPlaceholder
            EnvVars       = @($envVars | Where-Object { $_ })
            SignInAs    = & $prop $entry @('SignInAs', 'signInAs', 'Account', 'account', 'Upn', 'upn')
            Projects      = $projects
        }
    }

    $script:AutomationSecretsCache[$cacheKey] = $entries
    return $entries
}
