<#
.SYNOPSIS
    Runs the Azure DevOps Migration Platform for this migration using
    platform-config.json in this folder.

.DESCRIPTION
    Loads secrets into the environment, resolves the Migration Platform CLI
    from PATH and executes it against platform-config.json. Pass -WhatIf to
    print the command without running it.

    The template config starts in Inventory mode (read-only discovery); change
    Mode when ready to execute a real migration.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$here = $PSScriptRoot
. "$here\..\..\init.ps1"

# Load PATs from secrets\secrets.json into the environment ($ENV:AZDO_PAT_<ORG>
# and any explicit EnvVars names the platform binds).
Set-AutomationSecrets | Out-Null

# Resolve the Migration Platform CLI from PATH so a missing tool fails fast.
$migration = Get-Command migration -ErrorAction SilentlyContinue
if (-not $migration) {
    throw "The Azure DevOps Migration Platform CLI ('migration') was not found on PATH. Install it (see the azure-devops-migration-platform repo) and ensure it is on PATH."
}

$configPath = Join-Path $here 'platform-config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Configuration file not found: $configPath"
}

Write-Host "==> migration execute --config $configPath" -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess($configPath, 'migration execute')) {
    & $migration.Source execute --config $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "migration execute failed (exit $LASTEXITCODE) for config '$configPath'."
    }
}
