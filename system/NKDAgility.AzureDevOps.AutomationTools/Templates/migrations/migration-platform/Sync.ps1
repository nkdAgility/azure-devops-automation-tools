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
# Record this run's whole console to output\runs\ (committed engagement history).
# Called from another runbook, it writes into the caller's log instead.
Start-AutomationRunLog -Name 'Sync'
try {

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
    # Read each line to find the tool's own log folder, and keep a copy of it with this
    # run's console log.
    $toolLogDir = $null
    try {
        & $migration.Source execute --config $configPath 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match '(?:Logpath|Check the logs for errors):\s*(.+?)\s*$') { $toolLogDir = $Matches[1] }
            Write-Host $line
        }
    }
    finally {
        if ($toolLogDir) { Copy-AutomationRunLogArtifact -Path $toolLogDir -As 'migration-platform' }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "migration execute failed (exit $LASTEXITCODE) for config '$configPath'."
    }
}
}
finally { Stop-AutomationRunLog }
