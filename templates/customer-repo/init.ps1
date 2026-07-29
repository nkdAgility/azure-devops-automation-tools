<#
.SYNOPSIS
    Initialises this customer workspace: syncs the nkdAgility automation tools,
    imports the module and sets the session context. Run at the start of every
    session, and dot-source it at the top of runbooks:

        . .\init.ps1

.DESCRIPTION
    Keeps the two supporting repos current (clone if missing, fast-forward pull
    if clean, warn-and-continue if dirty or offline), then imports the
    NKDAgility.AzureDevOps.AutomationTools module and calls
    Initialize-AutomationWorkspace against this folder.

    The tools location is resolved in order:
      1. $env:AZDO_AUTOMATION_TOOLS
      2. 'toolsPath' in workspace.local.json (gitignored)
      3. %USERPROFILE%\source\repos\azure-devops-automation-tools

.PARAMETER NoSync
    Skip the git clone/pull step (offline work, or when iterating on local
    tools changes).
#>
[CmdletBinding()]
param(
    [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = $PSScriptRoot

# --- Resolve where the automation tools live -------------------------------
$toolsPath = $env:AZDO_AUTOMATION_TOOLS
$localFile = Join-Path $workspaceRoot 'workspace.local.json'
if (-not $toolsPath -and (Test-Path -LiteralPath $localFile)) {
    $local = Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json
    if ($local.PSObject.Properties['toolsPath'] -and $local.toolsPath) { $toolsPath = $local.toolsPath }
}
if (-not $toolsPath) {
    $toolsPath = Join-Path $env:USERPROFILE 'source\repos\azure-devops-automation-tools'
}
$reposRoot = Split-Path -Parent $toolsPath

# --- Sync the system repos (clone-or-pull) ---------------------------------
$systemRepos = @(
    @{ Path = $toolsPath; Url = 'https://github.com/nkdAgility/azure-devops-automation-tools.git' }
    @{ Path = (Join-Path $reposRoot 'process-customization-scripts'); Url = 'https://github.com/microsoft/process-customization-scripts.git' }
)
if (-not $NoSync) {
    foreach ($repo in $systemRepos) {
        $name = Split-Path -Leaf $repo.Path
        if (-not (Test-Path -LiteralPath $repo.Path)) {
            Write-Host "==> Cloning $($repo.Url)" -ForegroundColor Cyan
            git clone $repo.Url $repo.Path
            if ($LASTEXITCODE -ne 0) { Write-Warning "Clone failed for $($repo.Url); continuing." }
        }
        elseif (git -C $repo.Path status --porcelain) {
            Write-Warning "$name has local changes; skipping pull."
        }
        else {
            git -C $repo.Path pull --ff-only
            if ($LASTEXITCODE -ne 0) { Write-Warning "$name pull failed (offline?); continuing with the existing clone." }
        }
    }
}

# --- Import the module and initialise the workspace ------------------------
$modulePath = Join-Path $toolsPath 'system\NKDAgility.AzureDevOps.AutomationTools'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Automation tools not found at '$toolsPath'. Bootstrap this machine with: irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex"
}
Import-Module $modulePath -Force
Initialize-AutomationWorkspace -Path $workspaceRoot | Out-Null
