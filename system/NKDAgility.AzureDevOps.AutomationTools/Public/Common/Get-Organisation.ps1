function Get-Organisation {
    <#
    .SYNOPSIS
    Returns organisation entries from organisations.json with PATs resolved from secrets.

    .DESCRIPTION
    Reads the organisations.json data file (same shape as data\sample\organisations.json) and
    resolves each entry's PAT in this order:

      1. A non-empty inline 'pat' property in organisations.json (back-compat with standalone
         data files; customer repos commit organisations.json WITHOUT pats).
      2. A secrets.json entry matched by url (trailing-slash and case insensitive) or org name.
      3. The derived environment variable AZDO_PAT_<ORG>, where <ORG> comes from the secrets
         entry's Org or, failing that, the last path segment of the url.
      4. Otherwise pat stays empty and a warning names the url and the secrets file to fill in.

    Placeholder values ('somePat', '<...>', 'REPLACE_WITH_PAT') are treated as absent. Entries
    with a resolved PAT also get an 'authHeader' property (via Get-AzureDevOpsAuthHeader) ready
    for Invoke-RestMethod. Never log or print the returned pat/authHeader values.

    .PARAMETER Url
    Return only the organisation whose url matches (trailing-slash and case insensitive).

    .PARAMETER IncludeDisabled
    Include entries with enabled = false (default: enabled only).

    .PARAMETER Path
    Path to organisations.json. Defaults to <workspace DataFolder>\organisations.json when a
    workspace is initialised; legacy scripts can pass -Path "$dataFolder\organisations.json".

    .PARAMETER SecretsPath
    Path to secrets.json. Defaults to the workspace secrets path when initialised.

    .EXAMPLE
    $orgs = Get-Organisation
    foreach ($org in $orgs) { Invoke-RestMethod -Uri "$($org.url)/_apis/projects?$queryString" -Headers $org.authHeader }
    #>
    [CmdletBinding()]
    param(
        [string]$Url,
        [switch]$IncludeDisabled,
        [string]$Path,
        [string]$SecretsPath
    )

    if (-not $Path) {
        if (-not $script:Workspace) {
            throw "No -Path given and no workspace initialised. Run Initialize-AutomationWorkspace (or init.ps1) first, or pass -Path to organisations.json."
        }
        $Path = Join-Path $script:Workspace.DataFolder 'organisations.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Organisations file not found: $Path"
    }
    if (-not $SecretsPath -and $script:Workspace) {
        $SecretsPath = $script:Workspace.SecretsPath
    }

    $secrets = if ($SecretsPath) { Get-AutomationSecrets -SecretsPath $SecretsPath } else { @() }
    $organisations = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).organisations

    $normalise = { param([string]$value) if ($value) { $value.TrimEnd('/').ToLowerInvariant() } }
    $isPlaceholder = { param([string]$value) [string]::IsNullOrWhiteSpace($value) -or $value -like '<*>' -or $value -in 'somePat', 'REPLACE_WITH_PAT' }

    $results = foreach ($org in @($organisations)) {
        if (-not $IncludeDisabled -and -not $org.enabled) { continue }
        if ($Url -and (& $normalise $org.url) -ne (& $normalise $Url)) { continue }

        $secretsMatch = $secrets | Where-Object {
            (& $normalise $_.Url) -eq (& $normalise $org.url) -or
            ($_.Org -and $org.url -and (& $normalise $org.url).EndsWith('/' + $_.Org.ToLowerInvariant()))
        } | Select-Object -First 1

        $orgName = if ($secretsMatch -and $secretsMatch.Org) { $secretsMatch.Org }
        elseif ($org.url) { ([uri]$org.url).Segments[-1].Trim('/') }

        $inlinePat = if ($org.PSObject.Properties['pat']) { $org.pat }
        $pat = if (-not (& $isPlaceholder $inlinePat)) { $inlinePat }
        elseif ($secretsMatch -and $secretsMatch.AccessToken) { $secretsMatch.AccessToken }
        elseif ($orgName -and (Get-Item -Path ("Env:{0}" -f (Get-DerivedPatEnvVarName -Org $orgName)) -ErrorAction SilentlyContinue)) {
            (Get-Item -Path ("Env:{0}" -f (Get-DerivedPatEnvVarName -Org $orgName))).Value
        }

        $resolved = $org | Select-Object *
        if (-not $resolved.PSObject.Properties['pat']) {
            $resolved | Add-Member -NotePropertyName 'pat' -NotePropertyValue $null
        }
        $resolved.pat = $pat
        if ($pat) {
            $resolved | Add-Member -NotePropertyName 'authHeader' -NotePropertyValue (Get-AzureDevOpsAuthHeader -Pat $pat) -Force
        }
        else {
            $secretsHint = if ($SecretsPath) { $SecretsPath } else { 'secrets\secrets.json' }
            Write-Warning "No PAT resolved for $($org.url) - add it to $secretsHint or set AZDO_PAT_<ORG>."
        }
        $resolved
    }

    return $results
}
