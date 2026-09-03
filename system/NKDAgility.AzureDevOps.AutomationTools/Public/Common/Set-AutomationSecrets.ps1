function Set-AutomationSecrets {
    <#
    .SYNOPSIS
    Exports organisation PATs from the workspace secrets file as environment variables.

    .DESCRIPTION
    Generalisation of the NKDAClient-United-Machine Set-MigrationSecrets.ps1 script. For every
    organisation entry in secrets.json two kinds of environment variables are set:

      * A derived, predictable name of the form AZDO_PAT_<ORG> (org upper-cased, non-alphanumeric
        characters replaced with underscores).
      * Every explicit name listed in the entry's EnvVars array. This is how .NET Options binding
        feeds tools like the Azure DevOps Migration Tools / Migration Platform, whose committed
        JSON configs leave AccessToken empty and bind names such as
        MigrationTools__Endpoints__Source__Authentication__AccessToken from the environment.

    An entry whose AccessToken is still a placeholder is skipped WITH a warning; one with no
    AccessToken at all is skipped quietly, because ambient identity is the intended state
    rather than a misconfiguration. Only variable NAMES are
    printed and returned - values are never written to the console or logs.

    .PARAMETER SecretsPath
    Path to the secrets JSON file. Defaults to the initialised workspace's secrets path
    (<workspace>\secrets\secrets.json).

    .PARAMETER Scope
    Where to set the variables: Process (default), User, or Machine (Machine requires elevation).
    User/Machine also set the current process so values are usable immediately.

    .PARAMETER NoClobber
    Leave any variable that is already set. This is what init.ps1 uses, so a CI-provided
    secret or a deliberate per-shell override always wins over the workspace secrets file.

    .EXAMPLE
    Set-AutomationSecrets

    .EXAMPLE
    Set-AutomationSecrets -NoClobber
    #>
    [CmdletBinding()]
    param(
        [string]$SecretsPath,

        [ValidateSet('Process', 'User', 'Machine')]
        [string]$Scope = 'Process',

        [switch]$NoClobber
    )

    if (-not $SecretsPath) {
        if (-not $script:Workspace) {
            throw "No -SecretsPath given and no workspace initialised. Run Initialize-AutomationWorkspace (or init.ps1) first, or pass -SecretsPath."
        }
        $SecretsPath = $script:Workspace.SecretsPath
    }
    if (-not (Test-Path -LiteralPath $SecretsPath)) {
        throw "Secrets file not found: $SecretsPath. Copy secrets\secrets.example.json to secrets\secrets.json and fill in the PATs."
    }

    $entries = Get-AutomationSecrets -SecretsPath $SecretsPath
    $scopeEnum = [System.EnvironmentVariableTarget]::$Scope
    $setNames = [System.Collections.Generic.List[string]]::new()
    $keptNames = [System.Collections.Generic.List[string]]::new()

    $entraOrgs = [System.Collections.Generic.List[string]]::new()
    $ambientOrgs = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $entries) {
        if (-not $entry.Org) { continue }
        if (-not $entry.AccessToken) {
            # No token is usually the INTENDED state, not a misconfiguration - ambient
            # identity is the doctrine and a PAT only the fallback. Warning about it
            # trains people to ignore warnings, and a real missing token then goes
            # unnoticed. Only a leftover placeholder is worth interrupting for.
            if ($entry.IsPlaceholder) {
                Write-Warning "Skipping org '$($entry.Org)': its AccessToken is still the '<...>' placeholder. Fill it in, or remove the AccessToken line entirely if this organisation authenticates with Entra or your Windows identity."
            }
            elseif ($entry.SignInAs) {
                $entraOrgs.Add(('{0} (as {1})' -f $entry.Org, $entry.SignInAs))
            }
            else {
                # No token, no placeholder, no named identity: whatever the process is
                # already signed in as. Entra where the collection is Entra-backed, the
                # current Windows identity on an on-premises Azure DevOps Server - which
                # is exactly how a domain-joined engineer reaches their own server.
                $ambientOrgs.Add([string]$entry.Org)
            }
            continue
        }

        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($explicit in $entry.EnvVars) {
            if (-not $names.Contains([string]$explicit)) { $names.Add([string]$explicit) }
        }
        $derived = Get-DerivedPatEnvVarName -Org $entry.Org
        if (-not $names.Contains($derived)) { $names.Add($derived) }

        foreach ($name in $names) {
            if ($NoClobber -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
                if (-not $keptNames.Contains($name)) { $keptNames.Add($name) }
                continue
            }
            Set-Item -Path ("Env:{0}" -f $name) -Value $entry.AccessToken
            if ($Scope -ne 'Process') {
                [System.Environment]::SetEnvironmentVariable($name, $entry.AccessToken, $scopeEnum)
            }
            if (-not $setNames.Contains($name)) { $setNames.Add($name) }
        }
    }

    if ($entraOrgs.Count) {
        Write-FixStep "Entra sign-in (no PAT needed): $($entraOrgs -join ', ')"
    }
    if ($ambientOrgs.Count) {
        Write-FixStep "Ambient identity (no PAT needed): $($ambientOrgs -join ', ')"
    }
    if ($keptNames.Count) {
        Write-FixStep "Left $($keptNames.Count) environment variable(s) already set (CI secrets and shell overrides win): $($keptNames -join ', ')"
    }
    Write-FixStep "Loaded $($setNames.Count) environment variable(s) from secrets (scope: $Scope)."
    $setNames | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    return $setNames
}
