<#
.SYNOPSIS
    Bootstraps an nkdAgility customer workspace: clones the automation tools
    and scaffolds the customer repo in the current directory.

.DESCRIPTION
    Run from the root of an empty (or existing) customer repo:

        irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex

    What it does:
      1. Checks prerequisites (PowerShell 7+, git on PATH).
      2. Clones (or fast-forward pulls) the azure-devops-automation-tools repo
         and Microsoft's process-customization-scripts repo into the repos root
         (%USERPROFILE%\source\repos by default).
      3. Scaffolds the customer workspace in the current directory from the
         tools repo's templates\customer-repo - copying each file ONLY if it
         does not already exist, so re-running never overwrites your work.
      4. Prints the next steps.

    Safe to re-run at any time: it updates the tools clones and reports every
    scaffold file as Created or Skipped.

    To pass parameters (the plain irm|iex form runs with defaults):

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1))) -ReposRoot 'D:\repos'
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [string]$ReposRoot = (Join-Path $env:USERPROFILE 'source\repos'),
    [string]$ToolsRepoUrl = 'https://github.com/nkdAgility/azure-devops-automation-tools.git',
    [string]$ToolsBranch = 'main',
    [string]$ProcessScriptsRepoUrl = 'https://github.com/microsoft/process-customization-scripts.git',
    [switch]$SkipProcessScripts
)

function Invoke-AutomationToolsBootstrap {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path,
        [string]$ReposRoot = (Join-Path $env:USERPROFILE 'source\repos'),
        [string]$ToolsRepoUrl = 'https://github.com/nkdAgility/azure-devops-automation-tools.git',
        [string]$ToolsBranch = 'main',
        [string]$ProcessScriptsRepoUrl = 'https://github.com/microsoft/process-customization-scripts.git',
        [switch]$SkipProcessScripts
    )

    $ErrorActionPreference = 'Stop'

    function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

    # --- 1. Prerequisites ---------------------------------------------------
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7+ is required (you are on $($PSVersionTable.PSVersion)). Install it from https://aka.ms/powershell and re-run in pwsh."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git was not found on PATH. Install it from https://git-scm.com/download/win and re-run."
    }

    # --- 2. Clone-or-update the system repos --------------------------------
    New-Item -Path $ReposRoot -ItemType Directory -Force | Out-Null

    function Sync-Repo {
        param([string]$Url, [string]$TargetPath, [string]$Branch)

        $name = Split-Path -Leaf $TargetPath
        if (-not (Test-Path -LiteralPath $TargetPath)) {
            Write-Step "Cloning $Url -> $TargetPath"
            $cloneArgs = @('clone')
            if ($Branch) { $cloneArgs += @('--branch', $Branch) }
            $cloneArgs += @($Url, $TargetPath)
            git @cloneArgs
            if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Url." }
        }
        elseif (git -C $TargetPath status --porcelain) {
            Write-Warning "$name has local changes; skipping pull."
        }
        else {
            Write-Step "Updating $name"
            git -C $TargetPath pull --ff-only
            if ($LASTEXITCODE -ne 0) { Write-Warning "$name pull failed (offline?); continuing with the existing clone." }
        }
    }

    $toolsPath = Join-Path $ReposRoot 'azure-devops-automation-tools'
    Sync-Repo -Url $ToolsRepoUrl -TargetPath $toolsPath -Branch $ToolsBranch
    if (-not $SkipProcessScripts) {
        Sync-Repo -Url $ProcessScriptsRepoUrl -TargetPath (Join-Path $ReposRoot 'process-customization-scripts')
    }

    # --- 3. Scaffold the customer workspace ---------------------------------
    $templateRoot = Join-Path $toolsPath 'templates\customer-repo'
    if (-not (Test-Path -LiteralPath $templateRoot)) {
        throw "Templates not found at $templateRoot - the tools clone looks incomplete."
    }

    $Path = (Resolve-Path -LiteralPath $Path).Path
    Write-Step "Scaffolding customer workspace in $Path"

    # gitignore.template is renamed to .gitignore on copy (a real dot-file in
    # the templates folder would hide the template files from the tools repo).
    $renameMap = @{ 'gitignore.template' = '.gitignore' }

    foreach ($template in (Get-ChildItem -Path $templateRoot -Recurse -File)) {
        $relative = $template.FullName.Substring((Get-Item -LiteralPath $templateRoot).FullName.Length + 1)
        if ($renameMap.ContainsKey($relative)) { $relative = $renameMap[$relative] }
        $destination = Join-Path $Path $relative

        if (Test-Path -LiteralPath $destination) {
            Write-Host "    Skipped  $relative (already exists)" -ForegroundColor DarkGray
            continue
        }
        New-Item -Path (Split-Path -Parent $destination) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $template.FullName -Destination $destination
        Write-Host "    Created  $relative" -ForegroundColor Green
    }

    foreach ($folder in 'data', 'exports', 'migrations', 'output', 'secrets') {
        New-Item -Path (Join-Path $Path $folder) -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        Write-Step 'Initialising git repository'
        git -C $Path init | Out-Null
    }

    # --- 4. Record a non-default tools location ------------------------------
    $defaultReposRoot = Join-Path $env:USERPROFILE 'source\repos'
    if ((Resolve-Path -LiteralPath $ReposRoot).Path -ne $defaultReposRoot) {
        $localFile = Join-Path $Path 'workspace.local.json'
        $local = if (Test-Path -LiteralPath $localFile) {
            $existing = @{}
            foreach ($property in (Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json).PSObject.Properties) {
                $existing[$property.Name] = $property.Value
            }
            $existing
        }
        else { @{} }
        $local['toolsPath'] = $toolsPath
        $local | ConvertTo-Json | Set-Content -LiteralPath $localFile
        Write-Step "Recorded toolsPath in workspace.local.json (gitignored)"
    }

    # --- 5. Next steps -------------------------------------------------------
    Write-Host ''
    Write-Host 'Bootstrap complete. Next steps:' -ForegroundColor Green
    Write-Host '  1. Copy secrets\secrets.example.json to secrets\secrets.json and fill in the PATs (it is gitignored).'
    Write-Host '  2. Edit data\organisations.json with this customer''s organisation URLs (no PATs).'
    Write-Host '  3. Run:  . .\init.ps1'
    Write-Host '  4. Scaffold an engagement:  New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform'
    Write-Host '  5. Review, commit and push.'
}

Invoke-AutomationToolsBootstrap @PSBoundParameters
