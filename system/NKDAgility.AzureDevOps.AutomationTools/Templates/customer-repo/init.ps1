# ============================================================================
#  MANAGED FILE - DO NOT EDIT IN THE CUSTOMER WORKSPACE
#  Source: Templates\customer-repo\init.ps1 inside the
#          NKDAgility.AzureDevOps.AutomationTools module.
#  This file is overwritten from that template on every run. Edit it there.
# ============================================================================
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

    Framework-owned files ($managedFiles below - init.ps1 and the secrets
    example) are refreshed from templates\customer-repo on every run, so they
    must be edited in the tools repo rather than in the customer workspace.
    When init.ps1 itself is refreshed it hands over to the new copy.

.PARAMETER NoSync
    Skip the git clone/pull step (offline work, or when iterating on local
    tools changes). Framework-owned files are still refreshed from whatever
    the local tools clone currently holds.
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

# --- Refresh framework-owned files from the module -------------------------
# These files belong to Templates\customer-repo INSIDE the module, not to the
# customer: edit them THERE, never here, or the next session overwrites them.
# Copying them down every session is what keeps every workspace in step.
$modulePath = Join-Path $toolsPath 'system\NKDAgility.AzureDevOps.AutomationTools'
$managedFiles = @('init.ps1', 'secrets\secrets.example.json')
$templateRoot = Join-Path $modulePath 'Templates\customer-repo'
$selfUpdated = $false
$sameContent = { param($a, $b)
    ((Get-Content -LiteralPath $a -Raw) -replace "`r`n", "`n") -eq
    ((Get-Content -LiteralPath $b -Raw) -replace "`r`n", "`n")
}
if (-not (Test-Path -LiteralPath $templateRoot)) {
    Write-Warning "No customer-repo template at $templateRoot; skipping the refresh."
}
else {
    foreach ($relative in $managedFiles) {
        $source = Join-Path $templateRoot $relative
        $target = Join-Path $workspaceRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "Template has no $relative; leaving the local copy alone."
            continue
        }
        if ((Test-Path -LiteralPath $target) -and (& $sameContent $source $target)) { continue }
        New-Item -Path (Split-Path -Parent $target) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host "==> Updated $relative from the tools repo template" -ForegroundColor Cyan
        if ($relative -eq 'init.ps1') { $selfUpdated = $true }
    }
}
# --- Refresh the managed block inside CLAUDE.md ----------------------------
# CLAUDE.md is CO-owned: the prose above the markers is the customer's and is never
# touched, while the block between them is framework guidance refreshed from the module
# every session. That is why it is a block and not a managed file - a whole-file refresh
# would delete the customer's own notes.
$blockSource = Join-Path $templateRoot 'CLAUDE.managed.md'
$claudeFile = Join-Path $workspaceRoot 'CLAUDE.md'
$blockStart = '<!-- BEGIN managed: automation-tools -->'
$blockEnd = '<!-- END managed: automation-tools -->'
if ((Test-Path -LiteralPath $blockSource) -and (Test-Path -LiteralPath $claudeFile)) {
    $blockBody = (Get-Content -LiteralPath $blockSource -Raw).TrimEnd()
    $block = "$blockStart`n$blockBody`n$blockEnd"
    $current = Get-Content -LiteralPath $claudeFile -Raw
    $pattern = [regex]::Escape($blockStart) + '.*?' + [regex]::Escape($blockEnd)
    $updated = if ($current -match $pattern) {
        [regex]::Replace($current, $pattern, { $block }, 'Singleline')
    }
    else {
        # No markers yet (a workspace scaffolded before this mechanism existed): append
        # the block rather than rewriting the file, so nothing the customer wrote is lost.
        $current.TrimEnd() + "`n`n" + $block + "`n"
    }
    if (($updated -replace "`r`n", "`n") -ne ($current -replace "`r`n", "`n")) {
        Set-Content -LiteralPath $claudeFile -Value $updated -NoNewline
        Write-Host '==> Refreshed the managed block in CLAUDE.md' -ForegroundColor Cyan
    }
}

# This running copy is now the stale one, so hand over to the new file. The
# env guard stops a bad template turning the handover into a loop.
if ($selfUpdated -and -not $env:AZDO_INIT_RELOADED) {
    $env:AZDO_INIT_RELOADED = '1'
    try { . $PSCommandPath -NoSync }
    finally { Remove-Item Env:\AZDO_INIT_RELOADED -ErrorAction SilentlyContinue }
    return
}

# --- Scaffold missing local files from their examples ----------------------
# Every committed '<name>.example.<ext>' has a gitignored '<name>.<ext>' sibling
# that each machine owns (secrets/secrets.json, and any per-migration equivalent).
# Create the missing ones from the example so a fresh clone has the right shape,
# with the placeholders left in - never a real value.
$examples = Get-ChildItem -LiteralPath $workspaceRoot -Recurse -File -Filter '*.example.*' -Force |
    Where-Object { $_.FullName -notmatch '\\(\.git|output)\\' }
$needsValues = [System.Collections.Generic.List[string]]::new()
foreach ($example in $examples) {
    $target = Join-Path $example.DirectoryName ($example.Name -replace '\.example(\.[^.]+)$', '$1')
    $relative = if ($target.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $target.Substring($workspaceRoot.Length).TrimStart('\', '/')
    } else { $target }
    if (-not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath $example.FullName -Destination $target
        Write-Host "==> Created $relative from $($example.Name)" -ForegroundColor Yellow
    }
    # Unedited '<placeholder>' markers mean the file has no real values yet.
    if ((Get-Content -LiteralPath $target -Raw) -match '"<[^">\r\n]+>"') { $needsValues.Add($relative) }
}
if ($needsValues.Count) {
    Write-Warning "Placeholders still to fill in: $($needsValues -join ', ')"
}

# --- Import the module and initialise the workspace ------------------------
# $modulePath was resolved above, alongside the template root it ships.
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Automation tools not found at '$toolsPath'. Bootstrap this machine with: irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex"
}
Import-Module $modulePath -Force
Initialize-AutomationWorkspace -Path $workspaceRoot | Out-Null
