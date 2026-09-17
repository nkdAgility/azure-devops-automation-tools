function New-AutomationWorkspace {
    <#
    .SYNOPSIS
    Scaffolds a customer workspace from the templates shipped inside this module.

    .DESCRIPTION
    Creates the client repo shape - init.ps1, workspace.json, CLAUDE.md, the data,
    exports, migrations, output and secrets folders, and .gitignore - from the module's
    own Templates\customer-repo folder.

    Files are SEEDS: each one is copied only if it does not already exist, so re-running
    never overwrites work. The exception is the framework-owned set that the client's
    init.ps1 refreshes from this same template folder on every session (see $managedFiles
    there); those are seeded here and then kept current from the module.

    bootstrap.ps1 calls this after cloning and importing the module, so that the module
    is the single source of every scaffold - bootstrap itself knows nothing about
    templates, and this command works identically from a client workspace's .system\ copy.

    .PARAMETER Path
    Target workspace root. Defaults to the current directory.

    .PARAMETER InitialiseGit
    Run 'git init' in the target when it is not already a repository.

    .EXAMPLE
    New-AutomationWorkspace -Path 'C:\source\repos\NKDAClient-Contoso' -InitialiseGit
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path = (Get-Location).Path,
        [switch]$InitialiseGit
    )

    $ErrorActionPreference = 'Stop'

    $templateRoot = Join-Path $script:ModuleRoot 'Templates\customer-repo'
    if (-not (Test-Path -LiteralPath $templateRoot)) {
        throw "Customer-repo template not found at '$templateRoot'. The module copy looks incomplete."
    }

    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $Path = (Resolve-Path -LiteralPath $Path).Path
    Write-FixSection "Scaffolding customer workspace in $Path"

    # A real dot-file in the template folder would hide the template from the tools repo,
    # so it ships under a neutral name and is renamed on the way out.
    $renameMap = @{ 'gitignore.template' = '.gitignore' }

    # Source material for the managed block that init.ps1 writes into the workspace's
    # CLAUDE.md. It stays in the module - copying it into the workspace would put a
    # second, immediately-stale copy of the same guidance in the customer's repo.
    $doNotScaffold = @('CLAUDE.managed.md', '.managed')

    $templateRootLength = (Get-Item -LiteralPath $templateRoot).FullName.Length + 1
    foreach ($template in (Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Force)) {
        $relative = $template.FullName.Substring($templateRootLength)
        if ($relative -in $doNotScaffold) { continue }
        if ($renameMap.ContainsKey($relative)) { $relative = $renameMap[$relative] }
        $destination = Join-Path $Path $relative

        if (Test-Path -LiteralPath $destination) {
            Write-Host "    Skipped  $relative (already exists)" -ForegroundColor DarkGray
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($destination, 'Create from template')) { continue }
        New-Item -Path (Split-Path -Parent $destination) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $template.FullName -Destination $destination
        # When this module is itself running from a workspace's read-only .system\ copy,
        # Copy-Item carries the attribute across; the scaffolded file is the workspace's own.
        (Get-Item -LiteralPath $destination).IsReadOnly = $false
        Write-Host "    Created  $relative" -ForegroundColor Green
    }

    foreach ($folder in 'data', 'exports', 'migrations', 'output', 'secrets') {
        New-Item -Path (Join-Path $Path $folder) -ItemType Directory -Force | Out-Null
    }

    if ($InitialiseGit -and -not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        if ($PSCmdlet.ShouldProcess($Path, 'git init')) {
            Write-FixStep 'Initialising git repository'
            git -C $Path init | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning 'git init failed; initialise the repository by hand.' }
        }
    }

    return Get-Item -LiteralPath $Path
}
