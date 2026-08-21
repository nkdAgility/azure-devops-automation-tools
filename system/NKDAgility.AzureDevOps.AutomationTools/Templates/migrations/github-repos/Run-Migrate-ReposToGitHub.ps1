<#
.SYNOPSIS
    Runs the shared Migrate-ReposToGitHub.ps1 engine for this migration using
    settings loaded from github-repos-config.json in this folder.

.DESCRIPTION
    Reads the JSON configuration next to this script, converts it into
    parameter splatting for the Migrate-ReposToGitHub.ps1 engine in the
    automation module's own Engines\ folder and invokes it over the approved
    rows of the inventory CSV. Any config property whose value is null (or, for
    switches, false) is omitted so the engine falls back to its own defaults.

    The previous run's summary CSV (output\github-repomigration.csv) is passed
    to the engine automatically so a TargetName edited AFTER its repository
    migrated is Blocked instead of silently migrating to a second repository.

    Pass -WhatIf to preview the migration without making changes.

.PARAMETER ConfigPath
    Optional path to the configuration file. Defaults to
    github-repos-config.json alongside this script.

.PARAMETER ProjectFilter
    Optional wildcard filter on SourceProject, forwarded to the engine.

.PARAMETER RepoFilter
    Optional wildcard filter on SourceRepo, forwarded to the engine. Use this
    for a single-repository smoke test before the full run.

.PARAMETER AcceptRenames
    Forwarded to the engine: allow rows whose TargetName changed after
    migration to migrate to the new name.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'github-repos-config.json'),
    [string]$ProjectFilter,
    [string]$RepoFilter,
    [switch]$AcceptRenames
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
$migrateScript = Join-Path $moduleBase 'Engines\Migrate-ReposToGitHub.ps1'
if (-not (Test-Path -LiteralPath $migrateScript)) {
    throw "Migrate-ReposToGitHub.ps1 not found at: $migrateScript"
}

Write-Host "==> Loading config: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Expands "$ENV:NAME" / "${ENV:NAME}" placeholders in a config string using the
# process environment. JSON is not expanded by PowerShell, so we resolve any
# environment-variable references (tokens loaded by Set-AutomationSecrets)
# ourselves before splatting them into the engine. Tokens are fallbacks behind
# ambient identity (Entra / the gh CLI), so -AllowMissing returns $null for an
# unset variable instead of throwing.
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

# The engine prefers ambient identity (Entra for the source, the gh CLI for GitHub)
# and only uses these as fallbacks - so a missing token is not an error here.
$fallbackTokenParams = @('SourcePat', 'GitHubToken')

# Switch parameters on Migrate-ReposToGitHub.ps1: only include when set to $true.
$switchParams = @('ForceSegmented', 'KeepClones', 'SkipLfs', 'SkipOversizeCheck', 'LfsMigrateOversize', 'AcceptRenames')

# Builds a parameter hashtable from config properties: null/empty values are
# skipped so the engine keeps its own defaults, switches are only included when
# true, string values have environment-variable placeholders expanded.
$settings = [ordered]@{}
foreach ($prop in $config.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }

$params = @{}
foreach ($entry in $settings.GetEnumerator()) {
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

# The inventory CSV lives next to this script unless the config gives a rooted path.
if ($params.ContainsKey('InventoryCsv') -and -not [System.IO.Path]::IsPathRooted($params['InventoryCsv'])) {
    $params['InventoryCsv'] = Join-Path $PSScriptRoot $params['InventoryCsv']
}

# Default the working root under the workspace output folder (machine-local,
# gitignored) instead of a hardcoded absolute path.
if (-not $params.ContainsKey('WorkPath')) {
    $params['WorkPath'] = Join-Path (Get-AutomationWorkspace).OutputFolder "work\$(Split-Path -Leaf $PSScriptRoot)\repos"
}

# The previous run's committed summary is the rename-detection baseline.
$csvPath = Join-Path (Join-Path $PSScriptRoot 'output') 'github-repomigration.csv'
if ((Test-Path -LiteralPath $csvPath) -and -not $params.ContainsKey('PreviousSummaryCsv')) {
    $params['PreviousSummaryCsv'] = $csvPath
}

if ($ProjectFilter) { $params['ProjectFilter'] = $ProjectFilter }
if ($RepoFilter) { $params['RepoFilter'] = $RepoFilter }
if ($AcceptRenames) { $params['AcceptRenames'] = [switch]::Present }

Write-Host ("==> Invoking Migrate-ReposToGitHub.ps1 for '{0}' -> '{1}'" -f $settings['SourceOrg'], $settings['GitHubOrg']) -ForegroundColor Cyan
$summaries = @(& $migrateScript @params)

# Summary: list each repository processed and what happened to it; persist as CSV
# in this migration's output folder (committed engagement evidence, and the next
# run's rename-detection input).
$summaries = @($summaries | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'SourceRepo' })
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
            @{ Label = 'Repository';     Expression = { $_.SourceRepo } }
            @{ Label = 'Target';         Expression = { $_.TargetName } }
            @{ Label = 'Size (GB)';      Expression = { '{0,8:N2}' -f $_.SizeGB }; Alignment = 'Right' }
            @{ Label = 'Strategy';       Expression = { $_.Strategy } }
            @{ Label = 'Status';         Expression = { $_.Status } }
        ) |
        Out-Host

    $repoCount = @($summaries).Count
    $migrated = @($summaries | Where-Object { $_.Status -eq 'Migrated' }).Count
    $totalBytes = ($summaries | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host ("Total: {0} repository(ies) processed, {1} migrated, {2:N2} GB." -f $repoCount, $migrated, [math]::Round($totalBytes / 1GB, 2)) -ForegroundColor Green

    # The summary table truncates long statuses; repeat every not-migrated repo with
    # its FULL reason so nothing has to be fished out of the CSV.
    $needsAttention = @($summaries | Where-Object { $_.Status -ne 'Migrated' -and $_.Status -notlike 'WhatIf*' })
    if ($needsAttention) {
        Write-Host ''
        Write-Host ('---- Needs attention ({0}) - full reasons ----' -f $needsAttention.Count) -ForegroundColor Yellow
        foreach ($item in ($needsAttention | Sort-Object SourceProject, SourceRepo)) {
            Write-Host ('  {0}/{1} -> {2}' -f $item.SourceProject, $item.SourceRepo, $item.TargetName) -ForegroundColor Yellow
            Write-Host ('    {0}' -f $item.Status) -ForegroundColor DarkYellow
        }
    }

    # Under -WhatIf nothing moved: keep the last real run's evidence CSV intact.
    if (-not $WhatIfPreference) {
        $csvDir = Split-Path -Parent $csvPath
        if (-not (Test-Path -LiteralPath $csvDir)) {
            New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
        }

        $newRecords = $summaries |
            Select-Object @(
                @{ Name = 'project';            Expression = { $_.SourceProject } }
                @{ Name = 'repo';               Expression = { $_.SourceRepo } }
                @{ Name = 'source_repo_id';     Expression = { $_.SourceRepoId } }
                @{ Name = 'target_name';        Expression = { $_.TargetName } }
                @{ Name = 'target_url';         Expression = { $_.TargetUrl } }
                @{ Name = 'size_mb';            Expression = { [math]::Round($_.SizeBytes / 1MB, 2) } }
                @{ Name = 'strategy';           Expression = { $_.Strategy } }
                @{ Name = 'status';             Expression = { $_.Status } }
                # The name this repo actually lives under on GitHub - the engine's
                # rename-detection baseline. Set below: this run's name when it
                # migrated, otherwise inherited from the previous summary so a later
                # Blocked/Failed row cannot erase it.
                @{ Name = 'last_migrated_name'; Expression = { '' } }
            )

        # Merge into the existing summary rather than overwrite it: a filtered run
        # only touches some repos, and the untouched rows carry the rename-detection
        # baseline (and the evidence) for everything migrated in earlier runs.
        $merged = [ordered]@{}
        if (Test-Path -LiteralPath $csvPath) {
            foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
                if ($row.PSObject.Properties['source_repo_id'] -and $row.source_repo_id) {
                    $merged[[string]$row.source_repo_id] = $row
                }
            }
        }
        foreach ($record in $newRecords) {
            $id = [string]$record.source_repo_id
            if ($record.status -eq 'Migrated') {
                $record.last_migrated_name = $record.target_name
            }
            elseif ($merged.Contains($id)) {
                $previous = $merged[$id]
                if ($previous.PSObject.Properties['last_migrated_name'] -and $previous.last_migrated_name) {
                    $record.last_migrated_name = $previous.last_migrated_name
                }
                elseif ($previous.PSObject.Properties['status'] -and $previous.status -eq 'Migrated') {
                    # Summary written before this column existed.
                    $record.last_migrated_name = $previous.target_name
                }
            }
            $merged[$id] = $record
        }

        @($merged.Values) |
            Sort-Object { [double]$_.size_mb } -Descending |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host ("Wrote summary CSV: {0}" -f $csvPath) -ForegroundColor Green

        # One committed place for every repository that has NOT migrated: the full
        # reason per repo, with oversize object lists inlined so nothing has to be
        # fished out of the gitignored work folder. Built from the MERGED summary, so
        # it reflects the latest known state across runs, not just this run.
        $attention = @($merged.Values | Where-Object {
                $_.PSObject.Properties['status'] -and $_.status -and
                $_.status -ne 'Migrated' -and $_.status -notlike 'WhatIf*'
            })
        $attentionPath = Join-Path (Split-Path -Parent $csvPath) 'github-attention.md'
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('# GitHub migration - needs attention')
        $lines.Add('')
        $lines.Add(('Generated {0} by Run-Migrate-ReposToGitHub.ps1 after each committing run. Latest' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
        $lines.Add('known state of every approved repository that has not migrated; re-running')
        $lines.Add('Sync.ps1 refreshes this file.')
        if (-not $attention) {
            $lines.Add('')
            $lines.Add('**Nothing outstanding - every processed repository is Migrated.**')
        }
        foreach ($group in ($attention | Group-Object { ($_.status -split ':')[0] } | Sort-Object Name)) {
            $lines.Add('')
            $lines.Add(('## {0} ({1})' -f $group.Name, $group.Count))
            foreach ($item in ($group.Group | Sort-Object project, repo)) {
                $lines.Add('')
                $lines.Add(('### {0} / {1} -> {2}' -f $item.project, $item.repo, $item.target_name))
                $lines.Add('')
                $lines.Add($item.status)
                # Inline the offending-object list for oversize blocks.
                $oversizePath = Join-Path $params['WorkPath'] ($item.target_name + '.oversize.txt')
                if ($item.status -like '*100MB*' -and (Test-Path -LiteralPath $oversizePath)) {
                    $lines.Add('')
                    $lines.Add('```')
                    foreach ($reportLine in (Get-Content -LiteralPath $oversizePath)) { $lines.Add($reportLine) }
                    $lines.Add('```')
                }
            }
        }
        Set-Content -LiteralPath $attentionPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
        Write-Host ("Wrote attention report: {0}" -f $attentionPath) -ForegroundColor Green
    }
}
Write-Host '===================================================' -ForegroundColor Cyan
