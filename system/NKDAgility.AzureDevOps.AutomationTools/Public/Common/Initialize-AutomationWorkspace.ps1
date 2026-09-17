function Initialize-AutomationWorkspace {
    <#
    .SYNOPSIS
    Initialises a customer workspace: config, folders, logging and secrets awareness.

    .DESCRIPTION
    Loads workspace.json from the workspace root (a customer repo scaffolded by bootstrap.ps1)
    and deep-merges the gitignored workspace.local.json over it when present. Resolves the data,
    output and exports folders to absolute paths against the root, creates the output and log
    folders, stores the result in module scope (see Get-AutomationWorkspace) and starts logging
    under <outputFolder>\log. Warns - without throwing - when secrets\secrets.json is missing so
    read-only flows still work.

    The banner and all log output contain paths only, never secrets.

    .PARAMETER Path
    Workspace root: the folder containing workspace.json. Defaults to the current directory.

    .PARAMETER NoLogging
    Skip starting the file logger (useful for tests and quick sessions).

    .EXAMPLE
    Initialize-AutomationWorkspace -Path $PSScriptRoot
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [switch]$NoLogging
    )

    $Path = (Resolve-Path -LiteralPath $Path).Path
    $configFile = Join-Path $Path 'workspace.json'
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "No workspace.json found in '$Path'. Is this a customer workspace? Bootstrap one with: irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex"
    }

    $config = @{}
    foreach ($property in (Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json).PSObject.Properties) {
        $config[$property.Name] = $property.Value
    }
    $localFile = Join-Path $Path 'workspace.local.json'
    if (Test-Path -LiteralPath $localFile) {
        foreach ($property in (Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json).PSObject.Properties) {
            $config[$property.Name] = $property.Value
        }
    }

    $resolveFolder = {
        param([string]$value, [string]$default)
        if (-not $value) { $value = $default }
        if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $Path $value }
    }

    $script:Workspace = @{
        Root               = $Path
        DataFolder         = & $resolveFolder $config['dataFolder'] 'data'
        OutputFolder       = & $resolveFolder $config['outputFolder'] 'output'
        ExportsFolder      = & $resolveFolder $config['exportsFolder'] 'exports'
        SecretsPath        = Join-Path $Path 'secrets\secrets.json'
        QueryString        = if ($config['queryString']) { $config['queryString'] } else { 'api-version=7.0' }
        QueryStringPreview = if ($config['queryStringPreview']) { $config['queryStringPreview'] } else { 'api-version=7.1-preview.3' }
    }

    New-Item -Path $script:Workspace.OutputFolder -ItemType Directory -Force | Out-Null
    if (-not $NoLogging) {
        Initialize-AutomationLogging -LogFolder (Join-Path $script:Workspace.OutputFolder 'log')
    }

    Write-FixSection "Workspace: $Path"
    Write-FixStep "Data:    $($script:Workspace.DataFolder)"
    Write-FixStep "Output:  $($script:Workspace.OutputFolder)"
    Write-FixStep "Exports: $($script:Workspace.ExportsFolder)"

    if (-not (Test-Path -LiteralPath $script:Workspace.SecretsPath)) {
        Write-Warning "No secrets file at $($script:Workspace.SecretsPath). Copy secrets\secrets.example.json to secrets\secrets.json and fill in the PATs."
    }
    elseif (-not (Get-AutomationSecrets -SecretsPath $script:Workspace.SecretsPath | Where-Object AccessToken)) {
        Write-Warning "Secrets file $($script:Workspace.SecretsPath) has no usable tokens (all empty or placeholders)."
    }

    return Get-AutomationWorkspace
}
