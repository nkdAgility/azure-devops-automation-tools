<#
.SYNOPSIS
    Runs this migration end-to-end in order: repositories, then pipelines,
    then artifact feeds, then work items.

.DESCRIPTION
    Fail-fast orchestrator: each step must succeed before the next runs. Pass
    -WhatIf to preview - it is forwarded to the Run-Migrate-*.ps1 steps and
    turns the devopsmigration.exe calls into print-only no-ops.

    Always run `.\Sync.ps1 -WhatIf` first.

.PARAMETER SkipArtifacts
    Forwarded to Run-Migrate-Artifacts.ps1: feed-only sync (feeds, upstreams,
    permissions) without moving packages.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipArtifacts
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$here = $PSScriptRoot
. "$here\..\..\init.ps1"

# Load PATs from secrets\secrets.json into the environment: $ENV:AZDO_PAT_<ORG>
# for the Run-Migrate-*.ps1 configs, plus the MigrationTools__...__AccessToken
# names that devopsmigration.exe binds over its JSON configs.
Set-AutomationSecrets | Out-Null

# Resolve devopsmigration.exe from PATH so a missing tool fails fast with an
# actionable message instead of a cryptic execution error mid-run.
$devopsMigration = Get-Command devopsmigration.exe -ErrorAction SilentlyContinue
if (-not $devopsMigration) {
    throw "devopsmigration.exe was not found on PATH. Install the Azure DevOps Migration Tools (https://devopsmigration.io) and ensure devopsmigration.exe is on PATH."
}

# devopsmigration.exe steps: label + config file (relative to this folder).
$pipelineSteps = @(
    @{ Label = 'Pipelines'; Config = 'configuration-pipelines.json' }
)
$workItemsConfig = 'configuration-workitems.json'

$stepNumber = 0
$totalSteps = $pipelineSteps.Count + 3

function Invoke-DevOpsMigration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Label, [string]$ConfigFile)

    $script:stepNumber++
    $configPath = Join-Path $here $ConfigFile
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    Write-Host ("==> [{0}/{1}] devopsmigration: {2}" -f $stepNumber, $totalSteps, $Label) -ForegroundColor Cyan
    if (-not $PSCmdlet.ShouldProcess($ConfigFile, 'devopsmigration.exe execute')) {
        return
    }
    & $devopsMigration.Source execute --config $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "devopsmigration.exe failed (exit $LASTEXITCODE) for config '$ConfigFile'."
    }
}

function Invoke-RunScript {
    param([string]$Label, [string]$ScriptName, [hashtable]$Arguments = @{})

    $script:stepNumber++
    Write-Host ("==> [{0}/{1}] {2}" -f $stepNumber, $totalSteps, $Label) -ForegroundColor Cyan
    & (Join-Path $here $ScriptName) @Arguments
}

try {
    $runArgs = @{}
    if ($WhatIfPreference) { $runArgs['WhatIf'] = $true }

    # 1. Repositories.
    Invoke-RunScript -Label 'Repositories (Run-Migrate-Repos.ps1)' -ScriptName 'Run-Migrate-Repos.ps1' -Arguments $runArgs

    # 2. Pipelines via devopsmigration.exe.
    foreach ($step in $pipelineSteps) {
        Invoke-DevOpsMigration -Label $step.Label -ConfigFile $step.Config
    }

    # 3. Artifact feeds (and packages, unless -SkipArtifacts).
    $artifactArgs = @{} + $runArgs
    if ($SkipArtifacts) { $artifactArgs['SkipArtifacts'] = $true }
    Invoke-RunScript -Label 'Artifacts (Run-Migrate-Artifacts.ps1)' -ScriptName 'Run-Migrate-Artifacts.ps1' -Arguments $artifactArgs

    # 4. Work items last, after repos, pipelines and artifacts.
    Invoke-DevOpsMigration -Label 'Work items' -ConfigFile $workItemsConfig

    Write-Host '==> Sync complete.' -ForegroundColor Green
}
catch {
    Write-Host ("==> Sync FAILED at step {0}/{1}: {2}" -f $stepNumber, $totalSteps, $_.Exception.Message) -ForegroundColor Red
    throw
}
