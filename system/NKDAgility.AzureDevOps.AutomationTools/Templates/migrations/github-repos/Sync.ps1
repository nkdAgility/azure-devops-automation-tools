<#
.SYNOPSIS
    Runs this migration end-to-end in order: refresh the repository inventory,
    then migrate the approved repositories to GitHub.

.DESCRIPTION
    Fail-fast orchestrator: each step must succeed before the next runs. Pass
    -WhatIf to preview - the inventory refresh still runs (it is read-only
    against the source and only rewrites the local CSV), and the migration
    step reports what WOULD move without touching GitHub.

    Always run `.\Sync.ps1 -WhatIf` first.

    Re-running is the intended workflow: as the customer approves more rows in
    the inventory CSV, each run migrates the newly approved repositories and
    idempotently re-syncs the ones already migrated.

.PARAMETER RepoFilter
    Forwarded to Run-Migrate-ReposToGitHub.ps1: wildcard filter on SourceRepo,
    for a single-repository smoke test before the full run.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepoFilter
)

$ErrorActionPreference = 'Stop'
# Proven on the United-Machine engagement: strict mode turns a typo'd or unset
# variable into an error instead of a silent empty string mid-migration.
Set-StrictMode -Version Latest
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$here = $PSScriptRoot
. "$here\..\..\init.ps1"

# Load tokens from secrets\secrets.json into the environment: $ENV:AZDO_PAT_<ORG>
# and $ENV:GITHUB_TOKEN for the github-repos-config.json placeholders.
Set-AutomationSecrets | Out-Null

$stepNumber = 0
$totalSteps = 2

function Invoke-RunScript {
    param([string]$Label, [string]$ScriptName, [hashtable]$Arguments = @{})

    $script:stepNumber++
    Write-Host ("==> [{0}/{1}] {2}" -f $stepNumber, $totalSteps, $Label) -ForegroundColor Cyan
    $scriptPath = Join-Path $here $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Step script not found: $scriptPath"
    }
    & $scriptPath @Arguments
}

try {
    $runArgs = @{}
    if ($WhatIfPreference) { $runArgs['WhatIf'] = $true }

    # 1. Refresh the inventory so the run sees new repos, vanished repos and the
    #    latest approvals. Runs even under -WhatIf: it reads the source and only
    #    rewrites the local CSV, preserving every customer-owned column.
    Invoke-RunScript -Label 'Inventory (Run-Export-RepoInventory.ps1)' -ScriptName 'Run-Export-RepoInventory.ps1'

    # 2. Migrate the approved rows.
    $migrateArgs = @{} + $runArgs
    if ($RepoFilter) { $migrateArgs['RepoFilter'] = $RepoFilter }
    Invoke-RunScript -Label 'Repositories (Run-Migrate-ReposToGitHub.ps1)' -ScriptName 'Run-Migrate-ReposToGitHub.ps1' -Arguments $migrateArgs

    Write-Host '==> Sync complete.' -ForegroundColor Green
}
catch {
    Write-Host ("==> Sync FAILED at step {0}/{1}: {2}" -f $stepNumber, $totalSteps, $_.Exception.Message) -ForegroundColor Red
    throw
}
