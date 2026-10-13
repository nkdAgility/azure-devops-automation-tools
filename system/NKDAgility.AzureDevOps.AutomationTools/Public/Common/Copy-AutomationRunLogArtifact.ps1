function Copy-AutomationRunLogArtifact {
    <#
    .SYNOPSIS
    Copies a file or folder that belongs to the current run next to its console log.

    .DESCRIPTION
    The copy lands in <log-basename>\<As>, beside the .log Start-AutomationRunLog opened,
    so a tool's own logs (devopsmigration.exe writes its log folder beside its exe, deep in
    the WinGet package folder) are committed with the run that produced them.

    Does nothing when no run log is active or -Path does not exist, so a runbook can call
    it unconditionally.

    .EXAMPLE
    Copy-AutomationRunLogArtifact -Path $toolLogDir -As 'devopsmigration-configuration-workitems'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$As
    )

    if (-not $env:NKDA_RUNLOG -or -not (Test-Path -LiteralPath $Path)) { return }

    $base = Join-Path (Split-Path $env:NKDA_RUNLOG -Parent) ([IO.Path]::GetFileNameWithoutExtension($env:NKDA_RUNLOG))
    $dest = Join-Path $base $(if ($As) { $As } else { Split-Path $Path -Leaf })
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    if (Test-Path -LiteralPath $Path -PathType Container) {
        # Copy the folder's contents into $dest, so a re-copy refreshes rather than nests.
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        # Literal enumeration: a tool log path can hold [ ] (WinGet package folders can),
        # which -Path would read as a wildcard and match nothing.
        Get-ChildItem -LiteralPath $Path -Force | Copy-Item -Destination $dest -Recurse -Force
    }
    else {
        Copy-Item -LiteralPath $Path -Destination $dest -Force
    }
    Write-Host "==> Copied $Path -> $dest" -ForegroundColor DarkGray
}
