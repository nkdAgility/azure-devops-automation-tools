<#
.SYNOPSIS
    Builds or refreshes this migration's repository inventory/approval CSV from
    the source Azure DevOps organisation named in github-repos-config.json.

.DESCRIPTION
    Enumerates every project and every git repository in the source organisation
    and merges the result into the inventory CSV next to this script (see
    Export-GitRepoInventory for the merge rules: customer-edited TargetName,
    Approved and Notes columns are always preserved; fact columns are
    refreshed; vanished repositories are marked MissingFromSource, never
    deleted).

    The CSV is the engagement's approval record: commit it, have the customer
    mark the repositories to migrate with Approved = yes (editing TargetName
    where the pre-filled name is not wanted), and commit their edits. Then run
    Run-Migrate-ReposToGitHub.ps1 (or Sync.ps1) to migrate the approved rows.

.PARAMETER ConfigPath
    Optional path to the configuration file. Defaults to
    github-repos-config.json alongside this script.

.PARAMETER IncludeDisabled
    Also add rows for disabled source repositories (existing rows are always
    refreshed regardless).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'github-repos-config.json'),
    [switch]$IncludeDisabled
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Module -Name 'NKDAgility.AzureDevOps.AutomationTools')) {
    . "$PSScriptRoot\..\..\init.ps1"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

Write-Host "==> Loading config: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Expands "$ENV:NAME" / "${ENV:NAME}" placeholders in a config string using the
# process environment. JSON is not expanded by PowerShell, so we resolve any
# environment-variable references (tokens loaded by Set-AutomationSecrets)
# ourselves before use.
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

$inventoryPath = $config.InventoryCsv
if (-not [System.IO.Path]::IsPathRooted($inventoryPath)) {
    $inventoryPath = Join-Path $PSScriptRoot $inventoryPath
}

$params = @{
    Collection = Expand-EnvPlaceholder -Value $config.SourceOrg
    Pat        = Expand-EnvPlaceholder -Value $config.SourcePat
    Path       = $inventoryPath
}
# The GitHub side is optional here: with it, pre-filled TargetNames are also
# collision-checked against repositories that already exist in the target org.
if ($config.PSObject.Properties['GitHubOrg'] -and $config.GitHubOrg) {
    $params.GitHubOrg = Expand-EnvPlaceholder -Value $config.GitHubOrg
    $params.GitHubToken = Expand-EnvPlaceholder -Value $config.GitHubToken
}
if ($IncludeDisabled) { $params.IncludeDisabled = $true }

Export-GitRepoInventory @params

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  1. Commit $(Split-Path -Leaf $inventoryPath) - it is the engagement's approval record." -ForegroundColor Gray
Write-Host '  2. Have the customer mark rows Approved = yes (and adjust TargetName where wanted).' -ForegroundColor Gray
Write-Host '  3. Commit their edits, then run .\Sync.ps1 -WhatIf to preview the migration.' -ForegroundColor Gray
