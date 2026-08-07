# ============================================================================
#  MANAGED FILE - DO NOT EDIT IN THE CUSTOMER WORKSPACE
#  Source: Templates\customer-repo\init.ps1 inside the
#          NKDAgility.AzureDevOps.AutomationTools module.
#  This file is overwritten from that template on every run. Edit it there.
# ============================================================================
<#
.SYNOPSIS
    Initialises this customer workspace: materialises every declared capability,
    refreshes the framework-owned files, and loads the session. Run at the start
    of every session, and dot-source it at the top of runbooks:

        . .\init.ps1

.DESCRIPTION
    capabilities.json declares which nkdAgility engines this workspace uses. For
    each one, init.ps1:

      1. Resolves the engine clone (see below), cloning it if missing and
         fast-forward pulling it if clean.
      2. COPIES system\<Module> out of that clone into .system\<Module> and
         records what it copied in .system\<Module>\.source.json.
      3. Scaffolds the engine's Templates\customer-repo\** into this workspace,
         only-if-missing, then overwrites the files listed in that template's
         .managed file.
      4. Renders the engine's Agents\CAPABILITY.md into the workspace's agent
         guidance files.
      5. Dot-sources <name>\init.ps1 if the engine shipped one.

    Finally it imports the automation tools module and calls
    Initialize-AutomationWorkspace against this folder.

    An engine clone is resolved in order:
      1. $env:AZDO_ENGINE_<NAME>            (e.g. AZDO_ENGINE_GOVERNANCE)
      2. $env:AZDO_AUTOMATION_TOOLS        (the 'automation' capability only)
      3. 'enginePaths.<name>' or 'toolsPath' in workspace.local.json (gitignored)
      4. %USERPROFILE%\source\repos\<repo-name>

    .system\ is GENERATED and read-only. Never edit it: the next run overwrites
    it, and init.ps1 stops with an error if it notices a hand-edit rather than
    discarding the work silently. Change the engine in its clone and re-run -
    the copy takes uncommitted edits, so that is the normal way to test an
    engine change against a real workspace.

.PARAMETER NoSync
    Skip the git clone/pull step (offline work, or when iterating on local
    engine changes). Everything is still materialised from whatever the local
    clones currently hold.
#>
[CmdletBinding()]
param(
    [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = $PSScriptRoot

# --- Local machine overrides ------------------------------------------------
$localFile = Join-Path $workspaceRoot 'workspace.local.json'
$local = if (Test-Path -LiteralPath $localFile) {
    Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json
}
else { $null }

# --- Which capabilities does this workspace use? ----------------------------
# The registry is the WORKSPACE's, not any engine's: that is what lets a workspace
# take on governance without the automation tools knowing governance exists.
$capabilitiesFile = Join-Path $workspaceRoot 'capabilities.json'
$capabilities = if (Test-Path -LiteralPath $capabilitiesFile) {
    @((Get-Content -LiteralPath $capabilitiesFile -Raw | ConvertFrom-Json).capabilities)
}
else {
    # A workspace scaffolded before capabilities.json existed still works.
    @([pscustomobject]@{
            name   = 'automation'
            module = 'NKDAgility.AzureDevOps.AutomationTools'
            repo   = 'https://github.com/nkdAgility/azure-devops-automation-tools.git'
        })
}

# --- Helpers ----------------------------------------------------------------
$sameContent = { param($a, $b)
    ((Get-Content -LiteralPath $a -Raw) -replace "`r`n", "`n") -eq
    ((Get-Content -LiteralPath $b -Raw) -replace "`r`n", "`n")
}

# Hash of a folder's contents: relative path + file hash for every file, sorted so the
# result is stable. Used to notice a hand-edited .system\ before it gets overwritten.
$treeHash = {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $rootLength = (Get-Item -LiteralPath $Root).FullName.Length + 1
    $lines = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.Name -ne '.source.json' } |
        ForEach-Object { "$($_.FullName.Substring($rootLength))|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" } |
        Sort-Object
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
    (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
}

$resolveEnginePath = { param($capability)
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension(($capability.repo -split '/')[-1])
    $envName = "AZDO_ENGINE_$($capability.name.ToUpperInvariant() -replace '[^A-Z0-9]', '_')"
    $candidates = @(@(
        [Environment]::GetEnvironmentVariable($envName)
        if ($capability.name -eq 'automation') { $env:AZDO_AUTOMATION_TOOLS }
        if ($local -and $local.PSObject.Properties['enginePaths'] -and $local.enginePaths.PSObject.Properties[$capability.name]) {
            $local.enginePaths.$($capability.name)
        }
        if ($capability.name -eq 'automation' -and $local -and $local.PSObject.Properties['toolsPath']) { $local.toolsPath }
        (Join-Path $env:USERPROFILE (Join-Path 'source\repos' $repoName))
    ) | Where-Object { $_ })
    # The @() around the whole pipeline matters: piping to Where-Object unwraps a
    # single survivor to a bare string, and [0] on a string is its first CHARACTER.
    # With no workspace.local.json - the normal case on a fresh clone - only the
    # default candidate survives, and the engine path resolved to 'C'.
    @{ Path = $candidates[0]; RepoName = $repoName }
}

$systemRoot = Join-Path $workspaceRoot '.system'
$selfUpdated = $false
$loadedCapabilities = [System.Collections.Generic.List[hashtable]]::new()

# --- Per capability: sync, materialise, scaffold ----------------------------
foreach ($capability in $capabilities) {
    $resolved = & $resolveEnginePath $capability
    $enginePath = $resolved.Path

    # 1. Clone or fast-forward pull. A dirty clone is left alone: the local edits are
    #    almost always the point, and clobbering them would be worse than being stale.
    if (-not $NoSync) {
        if (-not (Test-Path -LiteralPath $enginePath)) {
            Write-Host "==> Cloning $($capability.repo)" -ForegroundColor Cyan
            git clone $capability.repo $enginePath
            if ($LASTEXITCODE -ne 0) { Write-Warning "Clone failed for $($capability.repo); continuing." }
        }
        elseif (git -C $enginePath status --porcelain) {
            Write-Warning "$($resolved.RepoName) has local changes; skipping pull."
        }
        else {
            git -C $enginePath pull --ff-only 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "$($resolved.RepoName) pull failed (offline?); continuing with the existing clone." }
        }
    }

    $moduleSource = Join-Path $enginePath (Join-Path 'system' $capability.module)
    if (-not (Test-Path -LiteralPath $moduleSource)) {
        throw "Capability '$($capability.name)': module not found at '$moduleSource'. Expected a clone of $($capability.repo) at '$enginePath'."
    }
    $modulePath = Join-Path $systemRoot $capability.module

    # 2. Materialise. Refuse to discard a hand-edit silently.
    $recordPath = Join-Path $modulePath '.source.json'
    if ((Test-Path -LiteralPath $modulePath) -and (Test-Path -LiteralPath $recordPath)) {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($record.treeHash -and (& $treeHash $modulePath) -ne $record.treeHash) {
            throw ".system\$($capability.module) has been modified since it was copied. It is generated and must not be edited - move your change into '$moduleSource' and re-run. To discard the local edit, delete '$modulePath' and re-run."
        }
    }

    $sourceSha = (git -C $enginePath rev-parse HEAD 2>$null)
    $sourceDirty = [bool](git -C $enginePath status --porcelain 2>$null)
    if (Test-Path -LiteralPath $modulePath) {
        Get-ChildItem -LiteralPath $modulePath -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item -LiteralPath $modulePath -Recurse -Force
    }
    New-Item -Path $systemRoot -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $moduleSource -Destination $modulePath -Recurse
    Write-Host "==> $($capability.name): copied $($capability.module) into .system\" -ForegroundColor Cyan

    @{
        capability = $capability.name
        module     = $capability.module
        source     = $enginePath
        sha        = if ($sourceSha) { $sourceSha } else { 'unknown' }
        dirty      = $sourceDirty
        treeHash   = (& $treeHash $modulePath)
        copiedAt   = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $recordPath
    if ($sourceDirty) {
        Write-Warning "$($resolved.RepoName) has uncommitted changes; .system\ holds them. Commit them before relying on this run being reproducible."
    }
    # Read-only so an accidental save in the editor fails loudly instead of being lost.
    Get-ChildItem -LiteralPath $modulePath -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $true }

    # 3. Scaffold this capability's slice of the workspace. Every engine ships the same
    #    shape - Templates\customer-repo\** relative to the workspace root - so the
    #    automation tools land at the root and governance lands under governance\.
    $templateRoot = Join-Path $modulePath 'Templates\customer-repo'
    if (Test-Path -LiteralPath $templateRoot) {
        $managedList = @()
        $managedFile = Join-Path $templateRoot '.managed'
        if (Test-Path -LiteralPath $managedFile) {
            $managedList = @(Get-Content -LiteralPath $managedFile |
                    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                    ForEach-Object { $_.Trim() -replace '/', '\' })
        }
        # A real dot-file in the template would hide it from the engine repo, so
        # .gitignore ships under a neutral name and is renamed on the way out.
        $renameMap = @{ 'gitignore.template' = '.gitignore' }
        # Source material for rendered agent guidance; it stays in the module.
        $doNotScaffold = @('CLAUDE.managed.md', '.managed')

        $templateRootLength = (Get-Item -LiteralPath $templateRoot).FullName.Length + 1
        foreach ($template in (Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Force)) {
            $relative = $template.FullName.Substring($templateRootLength)
            if ($relative -in $doNotScaffold) { continue }
            $isManaged = $relative -in $managedList
            if ($renameMap.ContainsKey($relative)) { $relative = $renameMap[$relative] }
            $target = Join-Path $workspaceRoot $relative

            if (Test-Path -LiteralPath $target) {
                # Seeds are the workspace's own once copied; only managed files are refreshed.
                if (-not $isManaged) { continue }
                if (& $sameContent $template.FullName $target) { continue }
            }
            New-Item -Path (Split-Path -Parent $target) -ItemType Directory -Force | Out-Null
            if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).IsReadOnly = $false }
            Copy-Item -LiteralPath $template.FullName -Destination $target -Force
            # The template is read from .system\, which is read-only; the workspace's copy
            # is the workspace's own, so clear the attribute Copy-Item carried across.
            (Get-Item -LiteralPath $target).IsReadOnly = $false
            $verb = if ($isManaged) { 'Updated' } else { 'Created' }
            Write-Host "    $verb  $relative" -ForegroundColor $(if ($isManaged) { 'Cyan' } else { 'Green' })
            if ($relative -eq 'init.ps1') { $selfUpdated = $true }
        }
    }

    $loadedCapabilities.Add(@{
            Name       = $capability.name
            Module     = $capability.module
            ModulePath = $modulePath
            InitScript = Join-Path $workspaceRoot (Join-Path $capability.name 'init.ps1')
        })
}

# This running copy is now the stale one, so hand over to the new file. The
# env guard stops a bad template turning the handover into a loop.
if ($selfUpdated -and -not $env:AZDO_INIT_RELOADED) {
    $env:AZDO_INIT_RELOADED = '1'
    try { . $PSCommandPath -NoSync:$NoSync }
    finally { Remove-Item Env:\AZDO_INIT_RELOADED -ErrorAction SilentlyContinue }
    return
}

# --- Standard folders -------------------------------------------------------
foreach ($folder in 'data', 'exports', 'migrations', 'output', 'secrets') {
    New-Item -Path (Join-Path $workspaceRoot $folder) -ItemType Directory -Force | Out-Null
}

# --- Scaffold missing local files from their examples ----------------------
# Every committed '<name>.example.<ext>' has a gitignored '<name>.<ext>' sibling
# that each machine owns (secrets/secrets.json, and any per-migration equivalent).
# Create the missing ones from the example so a fresh clone has the right shape,
# with the placeholders left in - never a real value.
$examples = Get-ChildItem -LiteralPath $workspaceRoot -Recurse -File -Filter '*.example.*' -Force |
    Where-Object { $_.FullName -notmatch '\\(\.git|\.system|output)\\' }
$needsValues = [System.Collections.Generic.List[string]]::new()
foreach ($example in $examples) {
    $target = Join-Path $example.DirectoryName ($example.Name -replace '\.example(\.[^.]+)$', '$1')
    $relative = if ($target.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $target.Substring($workspaceRoot.Length).TrimStart('\', '/')
    }
    else { $target }
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

# --- Render agent guidance --------------------------------------------------
# Each engine ships Agents\CAPABILITY.md describing how to work that capability.
# It is RENDERED into the workspace's agent files rather than referenced, because
# the result is committed: a fresh clone then has full guidance before init.ps1 has
# ever run, and Copilot has no import mechanism at all. Files are co-owned - only
# the marked block is rewritten, so anything the workspace wrote above it survives.
$blockBody = @()
$blockBody += (Get-Content -LiteralPath (Join-Path $systemRoot 'NKDAgility.AzureDevOps.AutomationTools\Templates\customer-repo\CLAUDE.managed.md') -Raw -ErrorAction SilentlyContinue)
foreach ($loaded in $loadedCapabilities) {
    $capabilityDoc = Join-Path $loaded.ModulePath 'Agents\CAPABILITY.md'
    if (Test-Path -LiteralPath $capabilityDoc) {
        $blockBody += (Get-Content -LiteralPath $capabilityDoc -Raw)
    }
}
$blockBody = (($blockBody | Where-Object { $_ }) -join "`n`n").TrimEnd()

$blockStart = '<!-- BEGIN managed: nkdagility -->'
$blockEnd = '<!-- END managed: nkdagility -->'
$block = "$blockStart`n$blockBody`n$blockEnd"

$renderTargets = @(
    @{ Path = 'CLAUDE.md'; Skeleton = $null }
    @{ Path = 'AGENTS.md'; Skeleton = "# Agent guide`n`nSee CLAUDE.md for this workspace's own notes. The block below is generated.`n" }
    @{ Path = '.github\copilot-instructions.md'; Skeleton = "# Copilot instructions`n`nSee CLAUDE.md for this workspace's own notes. The block below is generated.`n" }
)
foreach ($target in $renderTargets) {
    $file = Join-Path $workspaceRoot $target.Path
    if (-not (Test-Path -LiteralPath $file)) {
        if (-not $target.Skeleton) { continue }
        New-Item -Path (Split-Path -Parent $file) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $file -Value $target.Skeleton
    }
    $current = Get-Content -LiteralPath $file -Raw
    # Spliced by index rather than regex: the block spans newlines and can contain '$'
    # and other regex-replacement metacharacters, both of which silently corrupt a
    # -replace here.
    $startAt = $current.IndexOf($blockStart)
    $endAt = $current.IndexOf($blockEnd)
    $updated = if ($startAt -ge 0 -and $endAt -gt $startAt) {
        $current.Substring(0, $startAt) + $block + $current.Substring($endAt + $blockEnd.Length)
    }
    else {
        $current.TrimEnd() + "`n`n" + $block + "`n"
    }
    if (($updated -replace "`r`n", "`n") -ne ($current -replace "`r`n", "`n")) {
        Set-Content -LiteralPath $file -Value $updated -NoNewline
        Write-Host "==> Rendered agent guidance into $($target.Path)" -ForegroundColor Cyan
    }
}

# --- Import the automation tools and initialise the workspace ---------------
# From .system\, never from a clone: the workspace runs the copy it recorded.
$automation = $loadedCapabilities | Where-Object { $_.Module -eq 'NKDAgility.AzureDevOps.AutomationTools' } | Select-Object -First 1
if (-not $automation) {
    throw "capabilities.json must include the 'NKDAgility.AzureDevOps.AutomationTools' module: it owns the workspace itself."
}
Import-Module $automation.ModulePath -Force
Initialize-AutomationWorkspace -Path $workspaceRoot | Out-Null

# --- Export the workspace secrets as environment variables ------------------
# One secrets file serves every capability: the migration tools bind them into .NET
# config, and a governance manifest.yaml names one as its accessToken. -NoClobber means
# a CI-provided secret or a deliberate per-shell override always wins over the file.
$secretsPath = (Get-AutomationWorkspace).SecretsPath
if (Test-Path -LiteralPath $secretsPath) {
    Set-AutomationSecrets -SecretsPath $secretsPath -NoClobber | Out-Null
}

# --- Load each capability ---------------------------------------------------
foreach ($loaded in $loadedCapabilities) {
    if (Test-Path -LiteralPath $loaded.InitScript) {
        . $loaded.InitScript -WorkspaceRoot $workspaceRoot
    }
}
