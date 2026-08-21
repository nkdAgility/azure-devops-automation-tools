<#
.SYNOPSIS
    Runs the shared Migrate-Artifacts.ps1 engine for this migration using
    settings loaded from migrate-repos-config.json in this folder (the same
    config file the repository migration uses).

.DESCRIPTION
    Reads the JSON configuration next to this script, converts it into
    parameter splatting for the Migrate-Artifacts.ps1 engine in the automation
    module's own Engines\ folder and invokes it once per entry in the
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
# Proven on the United-Machine engagement: strict mode turns a typo'd or unset
# variable into an error instead of a silent empty string mid-migration.
Set-StrictMode -Version Latest

if (-not (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools')) {
    . "$PSScriptRoot\..\..\init.ps1"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

# The engine ships INSIDE the module, so it travels with it into .system\ and stays
# locked to the module version that drives it. Resolve it from ModuleBase - never
# by walking up, because above the module is the customer's own repo.
$moduleBase = (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools').ModuleBase
$migrateScript = Join-Path $moduleBase 'Engines\Migrate-Artifacts.ps1'
if (-not (Test-Path -LiteralPath $migrateScript)) {
    throw "Migrate-Artifacts.ps1 not found at: $migrateScript"
}

Write-Host "==> Loading config: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Discover the parameters the engine actually accepts so repository-only
# settings in the shared config are dropped instead of erroring.
$validParams = (Get-Command -Name $migrateScript).Parameters.Keys

# Expands "$ENV:NAME" / "${ENV:NAME}" placeholders in a config string using the
# process environment (tokens loaded by Set-AutomationSecrets). PATs are
# fallbacks behind ambient identity (Entra), so -AllowMissing returns $null for
# an unset variable instead of throwing.
function Expand-EnvPlaceholder {
    param([string]$Value, [switch]$AllowMissing)
    try {
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
    catch {
        if ($AllowMissing) { return $null }
        throw
    }
}

# The engine prefers ambient identity (Entra) and only uses these as fallbacks -
# so a missing token is not an error here.
$fallbackTokenParams = @('SourcePat', 'TargetPat')

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
            $value = Expand-EnvPlaceholder -Value $value -AllowMissing:($fallbackTokenParams -contains $name)
            if ($null -eq $value) { continue }
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
