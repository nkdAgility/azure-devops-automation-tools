function Test-MigrationToolsEndpointTokens {
    <#
    .SYNOPSIS
    Fails fast when a devopsmigration.exe config has an endpoint with no token bound.

    .DESCRIPTION
    devopsmigration.exe leaves AccessToken empty in its committed configuration-*.json and
    binds it from MigrationTools__Endpoints__<Endpoint>__Authentication__AccessToken (or the
    flat MigrationTools__Endpoints__<Endpoint>__AccessToken). Set-AutomationSecrets fills
    those names ONLY for secrets.json entries that list them under EnvVars, and clears them
    otherwise. Without this check the gap shows up only on the real run, as a validation
    failure from the tool, because -WhatIf never starts it.

    For every endpoint whose AuthenticationMode is AccessToken and whose config AccessToken
    is empty, the bound variable must be present. Each missing one is reported with the
    secrets.json organisation matching the endpoint's Collection, so the message says which
    entry needs which EnvVars name. Only names and presence are reported, never values.

    Runs under -WhatIf too: it reads nothing remote.

    .PARAMETER ConfigPath
    The devopsmigration.exe configuration file the next step will execute.

    .EXAMPLE
    Test-MigrationToolsEndpointTokens -ConfigPath .\configuration-workitems.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $endpoints = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).MigrationTools.Endpoints
    if (-not $endpoints) { return }

    # Only used to name the org in the message, so a missing workspace or secrets file
    # degrades the wording, never the check. Always pass -SecretsPath: it is mandatory,
    # and omitting it makes PowerShell prompt mid-run.
    $entries = @()
    if ($script:Workspace -and $script:Workspace.SecretsPath -and (Test-Path -LiteralPath $script:Workspace.SecretsPath)) {
        try { $entries = @(Get-AutomationSecrets -SecretsPath $script:Workspace.SecretsPath) } catch { $entries = @() }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($endpoint in $endpoints.PSObject.Properties) {
        $name = $endpoint.Name
        $value = $endpoint.Value
        $auth = $value.PSObject.Properties['Authentication']
        if (-not $auth -or -not $auth.Value) { continue }
        if ([string]$auth.Value.AuthenticationMode -ne 'AccessToken') { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$auth.Value.AccessToken)) { continue }

        $nested = "MigrationTools__Endpoints__${name}__Authentication__AccessToken"
        $flat = "MigrationTools__Endpoints__${name}__AccessToken"
        $bound = @($nested, $flat | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
        if ($bound.Count) { continue }

        $collection = ([string]$value.Collection).TrimEnd('/')
        $entry = $entries | Where-Object { $_.Url -and ([string]$_.Url).TrimEnd('/') -ieq $collection } | Select-Object -First 1
        $org = if ($entry) { "'$($entry.Org)'" } else { "the organisation for $collection (no secrets.json entry has that Url)" }
        $problems.Add("$name endpoint ($collection): no token bound. Add `"$nested`" to EnvVars on the secrets.json entry for $org, then re-run.")
    }

    if ($problems.Count) {
        throw ("devopsmigration.exe would start without a token for {0} endpoint(s) in {1}:`n  - {2}" -f $problems.Count, (Split-Path -Leaf $ConfigPath), ($problems -join "`n  - "))
    }
}
