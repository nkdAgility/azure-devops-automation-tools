<#
.SYNOPSIS
    Runs the shared Migrate-Repos.ps1 engine for this migration using settings
    loaded from migrate-repos-config.json in this folder.

.DESCRIPTION
    Reads the JSON configuration next to this script, converts it into
    parameter splatting for the Migrate-Repos.ps1 engine in the automation
    module's own Engines\ folder and invokes it once per entry in the
    'Runs' array. Any config property whose value is null (or, for switches,
    false) is omitted so the engine falls back to its own defaults.

    Pass -WhatIf to preview the migration without making changes.

.PARAMETER ConfigPath
    Optional path to the configuration file. Defaults to
    migrate-repos-config.json alongside this script.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migrate-repos-config.json')
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
$migrateScript = Join-Path $moduleBase 'Engines\Migrate-Repos.ps1'
if (-not (Test-Path -LiteralPath $migrateScript)) {
    throw "Migrate-Repos.ps1 not found at: $migrateScript"
}

Write-Host "==> Loading config: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Expands "$ENV:NAME" / "${ENV:NAME}" placeholders in a config string using the
# process environment. JSON is not expanded by PowerShell, so we resolve any
# environment-variable references (tokens loaded by Set-AutomationSecrets)
# ourselves before splatting them into the engine. PATs are fallbacks behind
# ambient identity (Entra), so -AllowMissing returns $null for an unset
# variable instead of throwing.
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

# Switch parameters on Migrate-Repos.ps1: only include when set to $true.
$switchParams = @('ForceSegmented', 'KeepClones', 'SkipLfs')

# Builds a parameter hashtable from config properties: null/empty values are
# skipped so the engine keeps its own defaults, switches are only included when
# true, string values have environment-variable placeholders expanded.
function ConvertTo-MigrateParams {
    param([System.Collections.IDictionary]$Settings)

    $params = @{}
    foreach ($entry in $Settings.GetEnumerator()) {
        $name = $entry.Key
        $value = $entry.Value

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
$summaries = @()
foreach ($run in $runs) {
    $runIndex++

    # Merge shared settings with this run's overrides.
    $settings = [ordered]@{}
    foreach ($k in $shared.Keys) { $settings[$k] = $shared[$k] }
    foreach ($prop in $run.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }

    # Give each run its own working directory so mirror clones from different
    # projects never collide.
    if ($sharedWorkPath -and $settings['SourceProject']) {
        $settings['WorkPath'] = Join-Path (Join-Path $sharedWorkPath $settings['SourceProject']) 'repos'
    }

    $params = ConvertTo-MigrateParams -Settings $settings

    $label = if ($settings['SourceProject']) { $settings['SourceProject'] } else { '(default)' }
    Write-Host ("==> [{0}/{1}] Invoking Migrate-Repos.ps1 for source project '{2}'" -f $runIndex, $runCount, $label) -ForegroundColor Cyan
    $summaries += & $migrateScript @params
}

# Summary: list each repository processed and how big it was; persist as CSV
# in this migration's output folder (committed engagement evidence).
$summaries = @($summaries | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Repository' })
Write-Host ''
Write-Host '================ Migration summary ================' -ForegroundColor Cyan
if (-not $summaries) {
    Write-Host 'No repositories were processed.' -ForegroundColor Yellow
}
else {
    $summaries |
        Sort-Object SizeBytes -Descending |
        Format-Table -AutoSize @(
            @{ Label = 'Source Project'; Expression = { $_.SourceProject } }
            @{ Label = 'Repository';     Expression = { $_.Repository } }
            # Only worth a column when a rename actually happened; a blank cell
            # reads as 'landed under its own name'.
            @{ Label = 'Landed as';      Expression = { if ($_.TargetRepository -cne $_.Repository) { $_.TargetRepository } } }
            @{ Label = 'Size (GB)';      Expression = { '{0,8:N2}' -f $_.SizeGB }; Alignment = 'Right' }
            @{ Label = 'Strategy';       Expression = { $_.Strategy } }
            @{ Label = 'Status';         Expression = { $_.Status } }
        ) |
        Out-Host

    $repoCount = @($summaries).Count
    $totalBytes = ($summaries | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host ("Total: {0} repository(ies), {1:N2} GB." -f $repoCount, [math]::Round($totalBytes / 1GB, 2)) -ForegroundColor Green

    $csvPath = Join-Path (Join-Path $PSScriptRoot 'output') 'repomigration.csv'
    $csvDir = Split-Path -Parent $csvPath
    if (-not (Test-Path -LiteralPath $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }
    $summaries |
        Sort-Object SizeBytes -Descending |
        Select-Object @(
            @{ Name = 'project';     Expression = { $_.SourceProject } }
            @{ Name = 'repo';        Expression = { $_.Repository } }
            # Where it actually landed - the evidence that a governed rename was
            # applied, and the record a later audit is reconciled against.
            @{ Name = 'target_repo'; Expression = { $_.TargetRepository } }
            @{ Name = 'size_mb';     Expression = { [math]::Round($_.SizeBytes / 1MB, 2) } }
        ) |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Wrote summary CSV: {0}" -f $csvPath) -ForegroundColor Green
}
Write-Host '===================================================' -ForegroundColor Cyan
