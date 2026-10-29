<#
.SYNOPSIS
    Moves the SOURCE project's classic build definitions from one major version of a task
    to another, so they migrate to a target organisation that only has the newer version.

.DESCRIPTION
    Writes to the SOURCE organisation's build definitions. Run with -WhatIf first, always.

    Thin wrapper over Update-BuildTaskVersion (module). ONE source project per run: -Project
    picks the single configuration-pipelines*.json whose Source.Project matches, and the
    organisation comes from it. Every definition is backed up as JSON before it is written
    (output\build-task-backup\<project>\), and every step changed or planned is listed in
    output\update-build-task-version-<project>[-whatif].csv.

.PARAMETER Project
    The source project. Exactly one pipeline config in this folder must name it.

.PARAMETER TaskId
    The task's id, as in the "A task is missing" error.

.PARAMETER ToMajor
    The major version to move to.

.EXAMPLE
    .\migrations\NN-Name\Update-BuildTaskVersion.ps1 -Project <SourceProject> -TaskId <task id> -ToMajor 3 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$Project,

    [Parameter(Mandatory)]
    [guid]$TaskId,

    [Parameter(Mandatory)]
    [int]$ToMajor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\..\..\init.ps1"
# Record this run's whole console to output\runs\ (committed engagement history).
Start-AutomationRunLog -Name 'Update-BuildTaskVersion'
try {

# One source project per run: find the one pipeline config for it.
$matched = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'configuration-pipelines*.json' | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).MigrationTools.Endpoints.Source.Project -eq $Project
    })
if ($matched.Count -ne 1) {
    throw "Expected exactly one configuration-pipelines*.json with Source.Project '$Project' in $PSScriptRoot; found $($matched.Count)."
}
$source = (Get-Content -LiteralPath $matched[0].FullName -Raw | ConvertFrom-Json).MigrationTools.Endpoints.Source
# Work item configs name it Collection, pipeline configs Organisation.
$collection = "$(if ($source.PSObject.Properties['Collection']) { $source.Collection } else { $source.Organisation })".TrimEnd('/')
if (-not $collection) { throw "$($matched[0].Name) names no Source Collection or Organisation." }
Write-Host "==> $Project in $collection (from $($matched[0].Name)): task $TaskId -> $ToMajor.*" -ForegroundColor Cyan

# Load the PATs, selecting this project so a per-project PAT is used.
Set-AutomationSecrets -Project $Project | Out-Null
$org = (([uri]$collection).AbsolutePath.Trim('/').Split('/')[-1] -replace '^$', ([uri]$collection).Host.Split('.')[0]).ToUpperInvariant() -replace '[^A-Z0-9]', '_'
$proj = $Project.ToUpperInvariant() -replace '[^A-Z0-9]', '_'
$pat = foreach ($name in "AZDO_PAT_${org}__${proj}", "AZDO_PAT_$org") {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $value; break }
}

$outDir = Join-Path $PSScriptRoot 'output'
$params = @{
    Collection = $collection
    Project    = $Project
    TaskId     = $TaskId
    ToMajor    = $ToMajor
    BackupPath = Join-Path $outDir (Join-Path 'build-task-backup' ($Project -replace '[^\w.-]', '_'))
    WhatIf     = $WhatIfPreference
}
if ($pat) { $params.Pat = $pat }

$results = @(Update-BuildTaskVersion @params)
$results | Format-Table Id, Definition, Step, From, To, InputsDefaulted -AutoSize | Out-String -Width 300 | Write-Host

# Committed evidence of what was (or would be) changed. A local file, so it is written
# under -WhatIf too - the preview CSV is the point of a -WhatIf run.
New-Item -ItemType Directory -Path $outDir -Force -WhatIf:$false | Out-Null
$csv = Join-Path $outDir ('update-build-task-version-{0}{1}.csv' -f ($Project -replace '[^\w.-]', '_'), $(if ($WhatIfPreference) { '-whatif' } else { '' }))
$results | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 -WhatIf:$false
Write-Host ("==> {0} step(s) in {1} definition(s). Wrote {2} - commit it." -f $results.Count, @($results.Id | Select-Object -Unique).Count, $csv) -ForegroundColor Green
}
finally { Stop-AutomationRunLog }
