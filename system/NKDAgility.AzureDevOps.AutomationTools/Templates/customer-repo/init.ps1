# MANAGED FILE - edit the automation tools customer-repo template.
# Bootstrap only: the module owns workspace initialisation.
[CmdletBinding()]
param(
    [ValidateSet('gallery', 'clone')][string]$Source,
    [ValidateSet('production', 'preview')][string]$Ring,
    [string]$Engine, [string]$Path, [string]$Repo, [switch]$NoSync
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$module = 'NKDAgility.AzureDevOps.AutomationTools'
$capFile = Join-Path $root 'capabilities.json'
$cap = if (Test-Path $capFile) { @( (Get-Content $capFile -Raw | ConvertFrom-Json).capabilities | Where-Object module -eq $module | Select-Object -First 1 )[0] }
if ((Test-Path $capFile) -and -not $cap) { throw "capabilities.json must include '$module'." }
$localFile = Join-Path $root 'workspace.local.json'
$local = if (Test-Path $localFile) { Get-Content $localFile -Raw | ConvertFrom-Json }
$url = if ($cap -and $cap.PSObject.Properties['repo']) { $cap.repo } else { 'https://github.com/nkdAgility/azure-devops-automation-tools.git' }
$default = Join-Path $env:USERPROFILE (Join-Path 'source\repos' ([IO.Path]::GetFileNameWithoutExtension(($url -split '/')[-1])))
$entry = if ($local -and $local.PSObject.Properties['enginePaths'] -and $local.enginePaths.PSObject.Properties['automation']) { $local.enginePaths.automation }
$localPath = if ($entry -is [string]) { $entry } elseif ($entry) { $entry.path } elseif ($local -and $local.PSObject.Properties['toolsPath']) { $local.toolsPath }
$selected = -not $Engine -or $Engine -eq 'automation'
$clone = if ($env:AZDO_ENGINE_AUTOMATION) { $env:AZDO_ENGINE_AUTOMATION } elseif ($env:AZDO_AUTOMATION_TOOLS) { $env:AZDO_AUTOMATION_TOOLS } elseif ($selected -and $Source -eq 'clone') { if ($Path) { $Path } else { $default } } elseif ($selected -and $Source -eq 'gallery') { $null } elseif ($localPath) { $localPath } elseif ($cap -and $cap.PSObject.Properties['source'] -and $cap.source -eq 'clone') { $default }
if ($clone) {
    $moduleFile = Join-Path $clone (Join-Path 'system' (Join-Path $module "$module.psd1"))
    if (-not (Test-Path $moduleFile) -and -not $NoSync) {
        $cloneUrl = if ($selected -and $Repo) { $Repo } elseif ($entry -and $entry -isnot [string] -and $entry.PSObject.Properties['repo']) { $entry.repo } else { $url }
        git clone $cloneUrl $clone
        if ($LASTEXITCODE -ne 0) { throw "Could not clone automation tools from '$cloneUrl'." }
    }
    if (-not (Test-Path $moduleFile)) { throw "Automation tools module not found at '$moduleFile'." }
} else {
    # A recorded workspace copy can bootstrap the resolver even when the user module
    # path holds an older release. The module then decides whether to keep or replace it.
    $existing = Join-Path $root (Join-Path '.system' (Join-Path $module "$module.psd1"))
    if ((Test-Path $existing) -and (Select-String -LiteralPath $existing -SimpleMatch "'Invoke-AutomationWorkspaceInit'" -Quiet)) { $moduleFile = $existing }
    else {
    $installed = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $NoSync) {
        $chosenRing = if ($selected -and $Ring) { $Ring } elseif ($local -and $local.PSObject.Properties['engineRings'] -and $local.engineRings.PSObject.Properties['automation']) { $local.engineRings.automation } elseif ($cap -and $cap.PSObject.Properties['ring']) { $cap.ring } else { 'production' }
        $find = @{ Name = $module; Repository = 'PSGallery'; ErrorAction = 'SilentlyContinue' }
        if ($chosenRing -eq 'preview') { $find.AllowPrerelease = $true }
        if ($cap -and $cap.PSObject.Properties['version']) { $find.RequiredVersion = $cap.version }
        $wanted = Find-Module @find
        $installedTag = if ($installed) { $installed.PrivateData.PSData.Prerelease }
        $installedVersion = if ($installed) { "$($installed.Version)" + $(if ($installedTag) { "-$($installedTag.TrimStart('-'))" } else { '' }) }
        if ($wanted -and (-not $installed -or $installedVersion -ne "$($wanted.Version)")) {
            $install = @{ Name = $module; Repository = 'PSGallery'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; RequiredVersion = $wanted.Version }
            if ($chosenRing -eq 'preview') { $install.AllowPrerelease = $true }
            Install-Module @install
            $installed = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
        }
    }
    $moduleFile = if ($installed) { $installed.Path } else { $existing }
    }
    if (-not (Test-Path $moduleFile)) { throw 'Automation tools is unavailable locally. Select a clone or install the module.' }
}
Import-Module $moduleFile -Force
if (-not (Get-Command Invoke-AutomationWorkspaceInit -ErrorAction SilentlyContinue)) { throw "Automation tools at '$moduleFile' predates the thin init entry point. Update it first." }
Invoke-AutomationWorkspaceInit -WorkspaceRoot $root -InitScriptPath $PSCommandPath @PSBoundParameters
