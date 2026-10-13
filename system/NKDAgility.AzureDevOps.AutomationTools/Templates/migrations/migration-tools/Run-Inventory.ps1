<#
.SYNOPSIS
    Pulls the source inventory for this migration with the Azure DevOps Migration
    Platform, using platform-config.json (Mode = Inventory) in this folder.

.DESCRIPTION
    Read-only against the source: counts work items, revisions, repos and pipelines
    per project (and per area path). Run it before anything else - Sync.ps1 does,
    even under -WhatIf, because nothing is written to either organisation.

    The platform writes its package under Package.WorkingDirectory; the root
    inventory.csv / inventory.json are copied into output\ here as committed
    engagement evidence.

    The Migration Platform CLI is resolved as 'devopsmigrationdev' (the shim
    build.ps1 -Mode Install writes in the azure-devops-migration-platform repo).
    'devopsmigration.exe' on PATH is usually the Migration Tools, not the platform.

.PARAMETER ConfigPath
    Optional path to the platform config. Defaults to platform-config.json here.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'platform-config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Read-only against both organisations, so a Sync.ps1 -WhatIf must not suppress it
# (or the local copy of its results).
$WhatIfPreference = $false
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

. "$PSScriptRoot\..\..\init.ps1"
# Record this run's whole console to output\runs\ (committed engagement history).
# Called from another runbook, it writes into the caller's log instead.
Start-AutomationRunLog -Name 'Run-Inventory'
try {

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($config.MigrationPlatform.Mode -ne 'Inventory') {
    throw "Run-Inventory.ps1 only runs Inventory mode; $ConfigPath has Mode '$($config.MigrationPlatform.Mode)'."
}

$platform = Get-Command devopsmigrationdev -ErrorAction SilentlyContinue
if (-not $platform) {
    throw "The Migration Platform CLI ('devopsmigrationdev') was not found on PATH. In the azure-devops-migration-platform repo run: ./build.ps1 -Mode Install -Fast"
}

Write-Host "==> devopsmigrationdev queue --config $ConfigPath --follow" -ForegroundColor Cyan
# Read each line to find the platform's own log folder, and keep a copy of it with this
# run's console log.
$toolLogDir = $null
try {
    & $platform.Source queue --config $ConfigPath --follow 2>&1 | ForEach-Object {
        $line = "$_"
        if ($line -match '(?:Logpath|Check the logs for errors):\s*(.+?)\s*$') { $toolLogDir = $Matches[1] }
        Write-Host $line
    }
}
finally {
    if ($toolLogDir) { Copy-AutomationRunLogArtifact -Path $toolLogDir -As 'devopsmigrationdev-inventory' }
}
if ($LASTEXITCODE -ne 0) {
    throw "Migration Platform inventory failed (exit $LASTEXITCODE) for config '$ConfigPath'."
}

# Copy the package-level inventory into this engagement's committed output.
$workDir = [Environment]::ExpandEnvironmentVariables([string]$config.MigrationPlatform.Package.WorkingDirectory)
$outDir = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$copied = 0
foreach ($name in 'inventory.csv', 'inventory.json') {
    $inventoryFile = Join-Path $workDir $name
    if (Test-Path -LiteralPath $inventoryFile) {
        Copy-Item -LiteralPath $inventoryFile -Destination (Join-Path $outDir $name) -Force
        $copied++
    }
}
if ($copied) {
    Write-Host "==> Inventory copied to $outDir - commit it." -ForegroundColor Green
}
else {
    Write-Warning "No inventory.csv/json found under '$workDir'; check the platform package output."
}

# Repositories and their sizes, from the source (read-only).
& (Join-Path $PSScriptRoot 'Run-RepoInventory.ps1')
}
finally { Stop-AutomationRunLog }
