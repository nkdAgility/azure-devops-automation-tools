<#
.SYNOPSIS
    Runs the shared Migrate-Artifacts.ps1 engine for this migration using
    settings loaded from migrate-repos-config.json in this folder (the same
    config file the repository migration uses).

.DESCRIPTION
    Reads the JSON configuration next to this script, converts it into
    parameter splatting for the Migrate-Artifacts.ps1 engine in the automation
    tools repo (src\migrationTools) and invokes it once per entry in the
    'Runs' array. Only properties that map to a parameter on the engine are
    forwarded, so repository-only settings in the shared config (e.g.
    KeepClones) are ignored. Null/empty values are omitted so the engine falls
    back to its own defaults.

    Pass -WhatIf to preview the migration without making changes.

.PARAMETER ConfigPath
    Optional path to the configuration file. Defaults to
    migrate-repos-config.json alongside this script.

.PARAMETER Inventory
    Read-only discovery: report what would move (feeds, packages, sizes)
    without migrating anything.

.PARAMETER SkipArtifacts
    Only create/sync the feeds (upstream sources and permissions) without
    downloading or publishing any packages.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migrate-repos-config.json'),

    [switch]$Inventory,

    [switch]$SkipArtifacts,

    [string]$CsvPath = (Join-Path $PSScriptRoot 'output\artifacts-inventory.csv')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools')) {
    . "$PSScriptRoot\..\..\init.ps1"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

# The engine lives in the automation tools repo; locate it from the imported
# module (<tools>\system\<module> -> <tools>\src\migrationTools).
$toolsRoot = Split-Path -Parent (Split-Path -Parent (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools').ModuleBase)
$migrateScript = Join-Path $toolsRoot 'src\migrationTools\Migrate-Artifacts.ps1'
if (-not (Test-Path -LiteralPath $migrateScript)) {
    throw "Migrate-Artifacts.ps1 not found at: $migrateScript"
}

Write-Host "==> Loading config: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Discover the parameters the engine actually accepts so repository-only
# settings in the shared config are dropped instead of erroring.
$validParams = (Get-Command -Name $migrateScript).Parameters.Keys

# Expands "$ENV:NAME" / "${ENV:NAME}" placeholders in a config string using the
# process environment (tokens loaded by Set-AutomationSecrets).
function Expand-EnvPlaceholder {
    param([string]$Value)
    [regex]::Replace($Value, '\$(?:ENV:(?<n>\w+)|\{ENV:(?<n>\w+)\})', {
        param($m)
        $name = $m.Groups['n'].Value
        $resolved = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($resolved)) {
            throw "Environment variable '$name' referenced in config is not set. Run Set-AutomationSecrets first (Sync.ps1 does this automatically)."
        }
        $resolved
    }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Switch parameters on Migrate-Artifacts.ps1: only include when set to $true.
$switchParams = @('KeepDownloads')

function ConvertTo-MigrateParams {
    param([System.Collections.IDictionary]$Settings)

    $params = @{}
    foreach ($entry in $Settings.GetEnumerator()) {
        $name = $entry.Key
        $value = $entry.Value

        if ($validParams -notcontains $name) { continue }
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            continue
        }

        if ($switchParams -contains $name) {
            if ($value) { $params[$name] = [switch]::Present }
            continue
        }

        if ($value -is [string]) {
            $value = Expand-EnvPlaceholder -Value $value
        }

        $params[$name] = $value
    }
    $params
}

# Collect shared settings (everything except the per-run 'Runs' array) so they
# can be applied to every run and overridden by per-run properties.
$shared = [ordered]@{}
$runs = @()
foreach ($prop in $config.PSObject.Properties) {
    if ($prop.Name -eq 'Runs') {
        $runs = @($prop.Value)
        continue
    }
    $shared[$prop.Name] = $prop.Value
}
if (-not $runs) {
    $runs = @([pscustomobject]@{})
}

# Default the working root under the workspace output folder (machine-local,
# gitignored) instead of a hardcoded absolute path.
$sharedWorkPath = $shared['WorkPath']
if (-not $sharedWorkPath) {
    $sharedWorkPath = Join-Path (Get-AutomationWorkspace).OutputFolder "work\$(Split-Path -Leaf $PSScriptRoot)"
    $shared['WorkPath'] = $sharedWorkPath
}

$runIndex = 0
$runCount = @($runs).Count

# The engine appends to the CSV so multiple runs accumulate into one file;
# remove any previous report first so each invocation starts clean. A feed-only
# sync (-SkipArtifacts) produces no package summary, so leave any existing
# inventory CSV untouched rather than wiping it.
if (-not $SkipArtifacts -and $CsvPath -and (Test-Path -LiteralPath $CsvPath)) {
    Remove-Item -LiteralPath $CsvPath -Force
}

foreach ($run in $runs) {
    $runIndex++

    # Merge shared settings with this run's overrides.
    $settings = [ordered]@{}
    foreach ($k in $shared.Keys) { $settings[$k] = $shared[$k] }
    foreach ($prop in $run.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }

    # Give each run its own working directory so downloads from different
    # projects never collide.
    if ($sharedWorkPath -and $settings['SourceProject']) {
        $settings['WorkPath'] = Join-Path (Join-Path $sharedWorkPath $settings['SourceProject']) 'artifacts'
    }

    $params = ConvertTo-MigrateParams -Settings $settings
    if ($Inventory) { $params['Inventory'] = [switch]::Present }
    if ($SkipArtifacts) { $params['SkipArtifacts'] = [switch]::Present }
    # A feed-only sync has no package summary to write, so don't hand the CSV
    # to the engine (it would otherwise overwrite the inventory report).
    if ($CsvPath -and -not $SkipArtifacts) { $params['CsvPath'] = $CsvPath }

    $label = if ($settings['SourceProject']) { $settings['SourceProject'] } else { '(default)' }
    Write-Host ("==> [{0}/{1}] Invoking Migrate-Artifacts.ps1 for source project '{2}'" -f $runIndex, $runCount, $label) -ForegroundColor Cyan
    & $migrateScript @params
}
