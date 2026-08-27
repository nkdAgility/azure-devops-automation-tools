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

      1. Materialises the engine, from ONE OF TWO SOURCES (see below).
      2. COPIES system\<Module> into .system\<Module> and records what it copied
         in .system\<Module>\.source.json.
      3. Scaffolds the engine's Templates\customer-repo\** into this workspace,
         only-if-missing, then overwrites the files listed in that template's
         .managed file.
      4. Renders the engine's Agents\CAPABILITY.md into the workspace's agent
         guidance files.
      5. Dot-sources <name>\init.ps1 if the engine shipped one.

    Finally it imports the automation tools module and calls
    Initialize-AutomationWorkspace against this folder.

    THE TWO SOURCES
    ---------------
    gallery (the default)
        Installs the published module from the PowerShell Gallery at a ring:
        'production' for stable releases, 'preview' for prereleases. Versioned
        and reproducible - this is what a scheduled audit should always run.

    clone
        Uses a git clone's WORKING TREE, uncommitted edits included, so an engine
        change takes effect in this workspace immediately with no publish step.
        The clone can be of the upstream repo or of your own fork; init.ps1 only
        ever reads the working tree, so a fork is just a clone with a different
        remote. NOT reproducible: two machines can differ.

    Switching between them, at any time:

        . .\init.ps1                                     # whatever is configured
        . .\init.ps1 -Source gallery -Ring preview       # gallery, prereleases
        . .\init.ps1 -Source gallery -Ring production    # gallery, stable
        . .\init.ps1 -Source clone -Engine governance    # your clone
        . .\init.ps1 -Source clone -Engine governance -Path C:\src\my-fork
        . .\init.ps1 -Source clone -Engine governance -Repo https://github.com/me/fork.git

    WHERE THE CHOICE IS REMEMBERED
    ------------------------------
    capabilities.json     committed, shared: the workspace's default 'source',
                          'ring' and optional exact 'version' per engine.
    workspace.local.json  gitignored, yours alone: per-engine clone paths and
                          ring overrides written by the switches above.

    That split is deliberate. Pointing an engine at your clone must never follow
    you into the shared repo, or your teammates and CI would silently run an
    engine that exists on one laptop.

    Resolution order per engine, first match wins:
      1. $env:AZDO_ENGINE_<NAME>          -> clone at that path (CI override)
      2. $env:AZDO_AUTOMATION_TOOLS       -> clone ('automation' only)
      3. enginePaths.<name> in workspace.local.json  -> clone
      4. capabilities.json 'source'       -> gallery (default) or clone
      5. nothing set at all               -> gallery, production ring

    .system\ is GENERATED and read-only. Never edit it: the next run overwrites
    it, and init.ps1 stops with an error if it notices a hand-edit rather than
    discarding the work silently. Change the engine in its clone and re-run -
    the copy takes uncommitted edits, so that is the normal way to test an
    engine change against a real workspace.

.PARAMETER Source
    'gallery' or 'clone'. Persisted, so it holds until you change it again.
    Without -Engine, applies to every declared engine.

.PARAMETER Ring
    'production' (stable) or 'preview' (prereleases). Gallery source only.

.PARAMETER Engine
    Limit -Source / -Ring to one capability, e.g. 'governance'.

.PARAMETER Path
    With '-Source clone': the clone to use. Defaults to
    %USERPROFILE%\source\repos\<repo-name>.

.PARAMETER Repo
    With '-Source clone': the URL to clone from if -Path does not exist yet.
    Point this at your fork. Defaults to the upstream repo in capabilities.json.

.PARAMETER NoSync
    Skip the network step - no git pull, no gallery check. Everything is still
    materialised from whatever is already local.
#>
[CmdletBinding()]
param(
    [ValidateSet('gallery', 'clone')]
    [string]$Source,

    [ValidateSet('production', 'preview')]
    [string]$Ring,

    [string]$Engine,
    [string]$Path,
    [string]$Repo,

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
    # A workspace scaffolded before capabilities.json existed still works, and a
    # bare folder bootstrapped by downloading this file gets a working default.
    @([pscustomobject]@{
            name   = 'automation'
            module = 'NKDAgility.AzureDevOps.AutomationTools'
            repo   = 'https://github.com/nkdAgility/azure-devops-automation-tools.git'
        })
}

# --- Apply and persist a -Source / -Ring switch -----------------------------
# Written to workspace.local.json, which is gitignored: choosing to run against
# your own clone is a per-machine decision and must not reach the shared repo.
if ($Source -or $Ring) {
    $targets = if ($Engine) {
        $match = @($capabilities | Where-Object { $_.name -eq $Engine })
        if (-not $match) {
            throw "No capability named '$Engine' in capabilities.json. Declared: $(($capabilities.name) -join ', ')."
        }
        $match
    }
    else { $capabilities }

    if (-not $local) { $local = [pscustomobject]@{} }
    foreach ($property in 'enginePaths', 'engineRings') {
        if (-not $local.PSObject.Properties[$property]) {
            $local | Add-Member -NotePropertyName $property -NotePropertyValue ([pscustomobject]@{})
        }
    }

    foreach ($target in $targets) {
        $name = $target.name

        if ($Source -eq 'clone') {
            $repoName = [System.IO.Path]::GetFileNameWithoutExtension(($target.repo -split '/')[-1])
            $clonePath = if ($Path) { $Path } else { Join-Path $env:USERPROFILE (Join-Path 'source\repos' $repoName) }
            $entry = [pscustomobject]@{ path = $clonePath }
            if ($Repo) { $entry | Add-Member -NotePropertyName 'repo' -NotePropertyValue $Repo }
            $local.enginePaths | Add-Member -NotePropertyName $name -NotePropertyValue $entry -Force
            Write-Host "==> $name : development mode, from '$clonePath'" -ForegroundColor Yellow
        }
        elseif ($Source -eq 'gallery') {
            if ($local.enginePaths.PSObject.Properties[$name]) {
                $local.enginePaths.PSObject.Properties.Remove($name)
            }
            Write-Host "==> $name : consumption mode, from the PowerShell Gallery" -ForegroundColor Cyan
        }

        if ($Ring) {
            $local.engineRings | Add-Member -NotePropertyName $name -NotePropertyValue $Ring -Force
            Write-Host "    ring: $Ring" -ForegroundColor Cyan
        }
    }

    $local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $localFile
    Write-Host "    remembered in workspace.local.json (gitignored)" -ForegroundColor DarkGray
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

# Decide where one engine comes from. A clone override always wins: it is only ever
# set deliberately, by an env var or by -Source clone.
$resolveEngine = { param($capability)
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension(($capability.repo -split '/')[-1])
    $envName = "AZDO_ENGINE_$($capability.name.ToUpperInvariant() -replace '[^A-Z0-9]', '_')"
    $name = $capability.name

    $clonePath = $null
    $cloneRepo = $capability.repo

    $fromEnv = [Environment]::GetEnvironmentVariable($envName)
    if ($fromEnv) { $clonePath = $fromEnv }
    elseif ($name -eq 'automation' -and $env:AZDO_AUTOMATION_TOOLS) { $clonePath = $env:AZDO_AUTOMATION_TOOLS }
    elseif ($local -and $local.PSObject.Properties['enginePaths'] -and $local.enginePaths.PSObject.Properties[$name]) {
        $entry = $local.enginePaths.$name
        # Accept the historical plain-string form as a bare path.
        if ($entry -is [string]) { $clonePath = $entry }
        else {
            $clonePath = $entry.path
            if ($entry.repo) { $cloneRepo = $entry.repo }
        }
    }
    elseif ($name -eq 'automation' -and $local -and $local.PSObject.Properties['toolsPath']) { $clonePath = $local.toolsPath }

    # capabilities.json can ask for clone mode without naming a path.
    if (-not $clonePath -and $capability.source -eq 'clone') {
        $clonePath = Join-Path $env:USERPROFILE (Join-Path 'source\repos' $repoName)
    }

    if ($clonePath) {
        return @{ Source = 'clone'; Path = $clonePath; Repo = $cloneRepo; RepoName = $repoName }
    }

    # Otherwise the gallery. Nothing configured at all means production.
    $resolvedRing =
        if ($local -and $local.PSObject.Properties['engineRings'] -and $local.engineRings.PSObject.Properties[$name]) { $local.engineRings.$name }
        elseif ($capability.ring) { $capability.ring }
        else { 'production' }

    @{ Source = 'gallery'; Ring = $resolvedRing; Version = $capability.version; RepoName = $repoName }
}

# Install (or update) the published module and hand back where it landed.
$materialiseFromGallery = { param($capability, $resolved)
    $module = $capability.module
    $allowPrerelease = ($resolved.Ring -eq 'preview')

    $findArgs = @{ Name = $module; Repository = 'PSGallery'; ErrorAction = 'SilentlyContinue' }
    if ($allowPrerelease) { $findArgs['AllowPrerelease'] = $true }
    if ($resolved.Version) { $findArgs['RequiredVersion'] = $resolved.Version }

    $wanted = if ($NoSync) { $null } else { Find-Module @findArgs }

    if (-not $wanted -and -not $NoSync) {
        # Say what IS there rather than leaving a bare "no match found".
        $available = @(Find-Module -Name $module -Repository PSGallery -AllVersions -AllowPrerelease -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Version -First 10)
        $detail = if ($available) { "Available versions: $($available -join ', ')." }
                  else { "No versions of '$module' are published to the PowerShell Gallery yet." }
        $hint = if ($resolved.Ring -eq 'production') {
            "The '$($capability.name)' engine has no stable release on the production ring. Use a prerelease with '. .\init.ps1 -Source gallery -Ring preview -Engine $($capability.name)', or work from a clone with '. .\init.ps1 -Source clone -Engine $($capability.name)'."
        }
        else {
            "Nothing matched on the '$($resolved.Ring)' ring$(if ($resolved.Version) { " for version '$($resolved.Version)'" })."
        }
        throw "$hint $detail"
    }

    $installed = @(Get-Module -ListAvailable -Name $module)
    $have = $installed | Sort-Object Version -Descending | Select-Object -First 1

    if ($wanted -and (-not $have -or $have.Version -ne $wanted.Version)) {
        Write-Host "==> $($capability.name): installing $module $($wanted.Version) ($($resolved.Ring) ring)" -ForegroundColor Cyan
        # -AllowClobber because these modules export generically-named helpers
        # (Write-InfoLog and friends) that collide with whatever else is loaded.
        # The workspace runs the .system\ copy anyway, so what lands in the user
        # module path is only a staging area.
        $installArgs = @{ Name = $module; Repository = 'PSGallery'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; RequiredVersion = $wanted.Version }
        if ($allowPrerelease) { $installArgs['AllowPrerelease'] = $true }
        Install-Module @installArgs
        $have = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    }

    if (-not $have) {
        throw "Capability '$($capability.name)': '$module' is not installed and could not be fetched$(if ($NoSync) { ' (-NoSync)' }). Remove -NoSync, or switch to a clone with '. .\init.ps1 -Source clone -Engine $($capability.name)'."
    }

    # Get-Module reports ModuleVersion only, so the prerelease tag has to be put
    # back on: '0.1.0' and '0.1.0-Preview1' are different builds, and .source.json
    # is what an audit result is attributed to.
    $tag = $have.PrivateData.PSData.Prerelease
    $full = "$($have.Version)" + $(if ($tag) { "-$($tag.TrimStart('-'))" } else { '' })

    @{ ModuleBase = $have.ModuleBase; Version = $full }
}

$systemRoot = Join-Path $workspaceRoot '.system'
$selfUpdated = $false
$loadedCapabilities = [System.Collections.Generic.List[hashtable]]::new()

# --- Per capability: sync, materialise, scaffold ----------------------------
foreach ($capability in $capabilities) {
    $resolved = & $resolveEngine $capability
    $modulePath = Join-Path $systemRoot $capability.module

    $provenance = @{
        capability = $capability.name
        module     = $capability.module
        mode       = $resolved.Source
    }

    if ($resolved.Source -eq 'clone') {
        $enginePath = $resolved.Path

        # 1. Clone or fast-forward pull. A dirty clone is left alone: the local edits are
        #    almost always the point, and clobbering them would be worse than being stale.
        if (-not $NoSync) {
            if (-not (Test-Path -LiteralPath $enginePath)) {
                Write-Host "==> Cloning $($resolved.Repo)" -ForegroundColor Cyan
                git clone $resolved.Repo $enginePath
                if ($LASTEXITCODE -ne 0) { Write-Warning "Clone failed for $($resolved.Repo); continuing." }
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
            throw "Capability '$($capability.name)': module not found at '$moduleSource'. Expected a clone of $($resolved.Repo) at '$enginePath'."
        }

        $provenance['source'] = $enginePath
        $provenance['sha'] = $(if ($sha = git -C $enginePath rev-parse HEAD 2>$null) { $sha } else { 'unknown' })
        $provenance['dirty'] = [bool](git -C $enginePath status --porcelain 2>$null)
    }
    else {
        $gallery = & $materialiseFromGallery $capability $resolved
        $moduleSource = $gallery.ModuleBase
        $provenance['source'] = 'PSGallery'
        $provenance['ring'] = $resolved.Ring
        $provenance['version'] = $gallery.Version
        $provenance['dirty'] = $false
    }

    # 2. Materialise. Refuse to discard a hand-edit silently.
    $recordPath = Join-Path $modulePath '.source.json'
    if ((Test-Path -LiteralPath $modulePath) -and (Test-Path -LiteralPath $recordPath)) {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($record.treeHash -and (& $treeHash $modulePath) -ne $record.treeHash) {
            throw ".system\$($capability.module) has been modified since it was copied. It is generated and must not be edited - move your change into '$moduleSource' and re-run. To discard the local edit, delete '$modulePath' and re-run."
        }
    }

    if (Test-Path -LiteralPath $modulePath) {
        Get-ChildItem -LiteralPath $modulePath -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item -LiteralPath $modulePath -Recurse -Force
    }
    New-Item -Path $systemRoot -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $moduleSource -Destination $modulePath -Recurse
    $from = if ($resolved.Source -eq 'clone') { "clone $($resolved.Path)" } else { "gallery $($provenance['version']) ($($resolved.Ring))" }
    Write-Host "==> $($capability.name): copied $($capability.module) into .system\ from $from" -ForegroundColor Cyan

    $provenance['treeHash'] = (& $treeHash $modulePath)
    $provenance['copiedAt'] = (Get-Date).ToString('o')
    $provenance | ConvertTo-Json | Set-Content -LiteralPath $recordPath

    if ($provenance['dirty']) {
        Write-Warning "$($resolved.RepoName) has uncommitted changes; .system\ holds them. This run is NOT reproducible - commit them, or switch to the gallery with '. .\init.ps1 -Source gallery -Engine $($capability.name)', before treating its output as evidence."
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
# env guard stops a bad template turning the handover into a loop. The switches
# have already been persisted, so the handover does not need to repeat them.
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
# From .system\, never from a clone or the module path: the workspace runs the
# copy it recorded.
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
