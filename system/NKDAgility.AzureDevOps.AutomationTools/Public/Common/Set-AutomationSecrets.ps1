function Set-AutomationSecrets {
    <#
    .SYNOPSIS
    Exports organisation credentials from the workspace secrets file as environment variables.

    .DESCRIPTION
    Generalisation of the NKDAClient-United-Machine Set-MigrationSecrets.ps1 script. For every
    organisation entry in secrets.json two kinds of environment variables are set:

      * A derived, predictable name of the form AZDO_PAT_<ORG> (org upper-cased, non-alphanumeric
        characters replaced with underscores).
      * Every explicit name listed in the entry's EnvVars array. This is how .NET Options binding
        feeds tools like the Azure DevOps Migration Tools / Migration Platform, whose committed
        JSON configs leave AccessToken empty and bind names such as
        MigrationTools__Endpoints__Source__Authentication__AccessToken from the environment.

    For Azure DevOps Services entries without a PAT, obtains an Entra token. Existing
    process values are refreshed unless -NoClobber is explicitly requested. Both flat
    and nested endpoint bindings are populated when either is configured. Only variable
    names and credential sources are printed - never values.

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

        [switch]$NoClobber,

        [switch]$ClearMissing
    )

    if (-not $SecretsPath) {
        if (-not $script:Workspace) {
            throw "No -SecretsPath given and no workspace initialised. Run Initialize-AutomationWorkspace (or init.ps1) first, or pass -SecretsPath."
        }
        $SecretsPath = $script:Workspace.SecretsPath
    }
    if (-not (Test-Path -LiteralPath $SecretsPath) -and -not $ClearMissing) {
        throw "Secrets file not found: $SecretsPath. Copy secrets\secrets.example.json to secrets\secrets.json and fill in the PATs."
    }

    # Interactive initialization owns these process bindings. Clear first so a
    # removed organisation, binding, or secrets file cannot leave an old token live.
    $previousNames = @{}
    if (-not $NoClobber) {
        foreach ($variable in (Get-ChildItem Env:)) {
            if ($variable.Name -match '^AZDO_PAT_[A-Z0-9_]+$|^MigrationTools__Endpoints__(?:Source|Target)__(?:Authentication__)?AccessToken$') {
                $previousNames[$variable.Name] = $true
                [Environment]::SetEnvironmentVariable($variable.Name, $null, 'Process')
            }
        }
    }

    $entries = Get-AutomationSecrets -SecretsPath $SecretsPath -Refresh
    $scopeEnum = [System.EnvironmentVariableTarget]::$Scope
    $setNames = [System.Collections.Generic.List[string]]::new()
    $keptNames = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $entries) {
        if (-not $entry.Org) { continue }
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($explicit in $entry.EnvVars) {
            if (-not $names.Contains([string]$explicit)) { $names.Add([string]$explicit) }
            if ($explicit -match '^(MigrationTools__Endpoints__(?:Source|Target))__(?:Authentication__)?AccessToken$') {
                foreach ($binding in @("$($Matches[1])__AccessToken", "$($Matches[1])__Authentication__AccessToken")) {
                    if (-not $names.Contains($binding)) { $names.Add($binding) }
                }
            }
        }
        $derived = Get-DerivedPatEnvVarName -Org $entry.Org
        if (-not $names.Contains($derived)) { $names.Add($derived) }

        $credential = $entry.AccessToken
        $method = 'PAT'
        if ($NoClobber) {
            $existingValues = @($names | ForEach-Object { [Environment]::GetEnvironmentVariable($_) } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            if ($existingValues.Count -gt 1) {
                throw "Org '$($entry.Org)' has conflicting pre-existing credential bindings; align CI values before initialization."
            }
            if ($existingValues.Count -eq 1) {
                $credential = $existingValues[0]
                $method = 'existing CI credential'
            }
        }
        if (-not $credential) {
            if ($entry.IsPlaceholder) {
                Write-Warning "Org '$($entry.Org)' has a placeholder AccessToken; no credential was loaded."
            }
            elseif ($entry.Url -match '^https://(?:dev\.azure\.com/|[^/]+\.visualstudio\.com(?:/|$))') {
                try {
                    $credential = Get-AzureDevOpsAccessToken -Collection $entry.Url
                    $method = 'Entra'
                }
                catch {
                    Write-Warning "Org '$($entry.Org)': Entra sign-in failed; credential bindings remain absent. Sign in or configure a PAT, then rerun init.ps1."
                }
            }
        }

        if (-not $credential) {
            foreach ($name in $names) {
                if (-not $NoClobber) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
                Write-FixStep "$($entry.Org): $name absent"
            }
            continue
        }

        foreach ($name in $names) {
            if ($NoClobber -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
                if (-not $keptNames.Contains($name)) { $keptNames.Add($name) }
                Write-FixStep "$($entry.Org): $name kept (existing value)"
                continue
            }
            $action = if ($previousNames.ContainsKey($name) -or -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { 'refreshed' } else { 'loaded' }
            Set-Item -Path ("Env:{0}" -f $name) -Value $credential
            if ($Scope -ne 'Process') {
                [System.Environment]::SetEnvironmentVariable($name, $credential, $scopeEnum)
            }
            if (-not $setNames.Contains($name)) { $setNames.Add($name) }
            Write-FixStep "$($entry.Org): $name $action ($method)"
        }
    }

    foreach ($name in $previousNames.Keys) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            Write-FixStep "$name cleared (absent from current secrets)"
        }
    }

    return $setNames
}
