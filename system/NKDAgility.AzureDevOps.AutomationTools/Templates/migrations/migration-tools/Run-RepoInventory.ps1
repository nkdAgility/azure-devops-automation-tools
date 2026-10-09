<#
.SYNOPSIS
    Writes output\repo-inventory.csv: every source git repository with its size,
    default branch, disabled flag and migration status.

.DESCRIPTION
    Read-only against the source. The source organisation and project come from
    the Runs in migrate-repos-config.json, so the inventory covers exactly what
    Run-Migrate-Repos.ps1 would migrate (one row per repository, whole project,
    whatever RepoName filters the runs carry). Migration status is joined from
    output\repomigration.csv when it exists. Commit the CSV as engagement
    evidence.

    Disabled repositories are listed because they cannot be cloned: the repo
    migration skips them, and someone has to decide whether to re-enable or
    leave each one behind.

.PARAMETER ConfigPath
    Optional path to the repo config. Defaults to migrate-repos-config.json here.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'migrate-repos-config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# init.ps1 is dot-sourced and declares -Source and -Repo, so never name a variable
# $source or $repo here: assigning to them is validated/coerced as those parameters.
# Read-only, so a Sync.ps1 -WhatIf must not suppress it (or its local CSV).
$WhatIfPreference = $false

. "$PSScriptRoot\..\..\init.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function Get-ConfigValue {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value }
}

# Expands "$ENV:NAME" placeholders; an unset token is fine (Entra is tried first).
function Expand-EnvPlaceholder {
    param([string]$Value)
    if (-not $Value) { return $null }
    $expanded = [regex]::Replace($Value, '\$(?:ENV:(?<n>\w+)|\{ENV:(?<n>\w+)\})', {
            param($m) [Environment]::GetEnvironmentVariable($m.Groups['n'].Value)
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ([string]::IsNullOrWhiteSpace($expanded)) { $null } else { $expanded }
}

# One inventory per distinct source org + project across the runs.
$sources = [ordered]@{}
foreach ($run in @(Get-ConfigValue $config 'Runs')) {
    $org = Get-ConfigValue $run 'SourceOrg'; if (-not $org) { $org = Get-ConfigValue $config 'SourceOrg' }
    $project = Get-ConfigValue $run 'SourceProject'; if (-not $project) { $project = Get-ConfigValue $config 'SourceProject' }
    $pat = Get-ConfigValue $run 'SourcePat'; if (-not $pat) { $pat = Get-ConfigValue $config 'SourcePat' }
    if ($org -and $project) { $sources["$org|$project"] = @{ Org = $org; Project = $project; Pat = (Expand-EnvPlaceholder $pat) } }
}
if (-not $sources.Count) { throw "No SourceOrg/SourceProject found in $ConfigPath." }

$status = @{}
$summaryCsv = Join-Path $PSScriptRoot 'output\repomigration.csv'
if (Test-Path -LiteralPath $summaryCsv) {
    foreach ($row in Import-Csv -LiteralPath $summaryCsv) { $status["$($row.project)|$($row.repo)"] = $row.status }
}

$rows = foreach ($repoSource in $sources.Values) {
    Write-Host "==> Listing repositories in $($repoSource.Org) / $($repoSource.Project)" -ForegroundColor Cyan
    $params = @{ Collection = $repoSource.Org; Project = $repoSource.Project; IncludeDisabled = $true }
    if ($repoSource.Pat) { $params['Pat'] = $repoSource.Pat }
    foreach ($gitRepo in @(Get-GitRepository @params)) {
        $key = "$($repoSource.Project)|$($gitRepo.name)"
        [pscustomobject][ordered]@{
            SourceProject   = $repoSource.Project
            Repository      = $gitRepo.name
            SizeMB          = [math]::Round([double]$(if ($gitRepo.PSObject.Properties['size']) { $gitRepo.size } else { 0 }) / 1MB, 1)
            DefaultBranch   = $(if ($gitRepo.PSObject.Properties['defaultBranch']) { $gitRepo.defaultBranch -replace '^refs/heads/', '' } else { '' })
            IsDisabled      = [bool]($gitRepo.PSObject.Properties['isDisabled'] -and $gitRepo.isDisabled)
            MigrationStatus = $(if ($status.ContainsKey($key)) { $status[$key] } else { 'Not yet' })
            WebUrl          = $(if ($gitRepo.PSObject.Properties['webUrl']) { $gitRepo.webUrl } else { '' })
        }
    }
}
$rows = @($rows | Sort-Object SizeMB -Descending)

$outDir = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$outPath = Join-Path $outDir 'repo-inventory.csv'
$rows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8

$totalGB = [math]::Round(($rows | Measure-Object SizeMB -Sum).Sum / 1024, 2)
$disabled = @($rows | Where-Object IsDisabled)
$migrated = @($rows | Where-Object MigrationStatus -ne 'Not yet')
Write-Host ''
Write-Host ("Repositories: {0}  Total: {1} GB  Empty: {2}  Disabled: {3}  Migrated: {4}" -f `
        $rows.Count, $totalGB, @($rows | Where-Object SizeMB -eq 0).Count, $disabled.Count, $migrated.Count) -ForegroundColor Green
foreach ($band in @(@('> 1 GB', 1024, [double]::MaxValue), @('100 MB - 1 GB', 100, 1024), @('10 - 100 MB', 10, 100), @('<= 10 MB', -1, 10))) {
    $set = @($rows | Where-Object { $_.SizeMB -gt $band[1] -and $_.SizeMB -le $band[2] })
    Write-Host ("  {0,-14} {1,4} repos {2,8:N1} GB" -f $band[0], $set.Count, (($set | Measure-Object SizeMB -Sum).Sum / 1024))
}
foreach ($gitRepo in $disabled) {
    Write-Warning "Disabled in source, will NOT migrate: $($gitRepo.Repository) ($($gitRepo.SizeMB) MB). Re-enable it or record the decision to leave it behind."
}
Write-Host "==> Wrote $outPath - commit it." -ForegroundColor Green
