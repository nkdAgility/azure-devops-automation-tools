<#
.SYNOPSIS
    Adds to the target project's process what the source project's work items need
    (work item types, fields, picklist values, states, backlog levels), using the
    source and target named in this folder's work item configuration for -Project.

.DESCRIPTION
    Writes to the TARGET organisation's process. Run with -WhatIf first, always.

    Thin wrapper over Sync-InheritedProcess (module): nothing about any project is
    written here. The organisations and projects come from the work item config's
    Source and Target endpoints. It runs for ONE source project per invocation, never
    more: -Project picks the single configuration-workitems*.json whose Source.Project
    matches, and the run stops if there is not exactly one.

    It only adds. It refuses a target process other projects share unless
    -AllowSharedProcess is given, and stops with instructions when the target project
    is on a system process (Agile, Scrum, CMMI, Basic), which cannot be customised.

.PARAMETER Project
    The source project to align for. Exactly one work item config in this folder must
    name it as Source.Project.

.PARAMETER WorkItemType
    Optional. Only these source work item types.

.PARAMETER AllowSharedProcess
    Write to a target process that other projects also use.

.EXAMPLE
    .\migrations\NN-Name\Align-TargetProcess.ps1 -Project <SourceProject> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$Project,

    [string[]]$WorkItemType,

    [switch]$AllowSharedProcess
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\..\..\init.ps1"
# Record this run's whole console to output\runs\ (committed engagement history).
Start-AutomationRunLog -Name 'Align-TargetProcess'
try {

# One source project per run: find the one work item config for it.
$matched = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'configuration-workitems*.json' | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).MigrationTools.Endpoints.Source.Project -eq $Project
    })
if ($matched.Count -ne 1) {
    throw "Expected exactly one configuration-workitems*.json with Source.Project '$Project' in $PSScriptRoot; found $($matched.Count)."
}
$Config = $matched[0].Name
$endpoints = (Get-Content -LiteralPath $matched[0].FullName -Raw | ConvertFrom-Json).MigrationTools.Endpoints
Write-Host "==> $Project -> $($endpoints.Target.Project) (from $Config)" -ForegroundColor Cyan

# Load the PATs, selecting this config's projects so any per-project PAT is used.
Set-AutomationSecrets -Project @($endpoints.Source.Project, $endpoints.Target.Project) | Out-Null

$orgName = { param($url) ([uri]$url).AbsolutePath.Trim('/').Split('/')[-1] -replace '^$', ([uri]$url).Host.Split('.')[0] }
$tokenFor = { param($url, $project)
    $org = (& $orgName $url).ToUpperInvariant() -replace '[^A-Z0-9]', '_'
    $proj = $project.ToUpperInvariant() -replace '[^A-Z0-9]', '_'
    foreach ($name in "AZDO_PAT_${org}__${proj}", "AZDO_PAT_$org") {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    $null
}

$params = @{
    SourceCollection   = $endpoints.Source.Collection.TrimEnd('/')
    SourceProject      = $endpoints.Source.Project
    TargetCollection   = $endpoints.Target.Collection.TrimEnd('/')
    TargetProject      = $endpoints.Target.Project
    AllowSharedProcess = $AllowSharedProcess
    WhatIf             = $WhatIfPreference
}
$sourcePat = & $tokenFor $endpoints.Source.Collection $endpoints.Source.Project
$targetPat = & $tokenFor $endpoints.Target.Collection $endpoints.Target.Project
if ($sourcePat) { $params.SourcePat = $sourcePat }
if ($targetPat) { $params.TargetPat = $targetPat }
if ($WorkItemType) { $params.WorkItemType = $WorkItemType }

$results = @(Sync-InheritedProcess @params)

# Committed evidence of what was (or would be) changed.
$outDir = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$csv = Join-Path $outDir ('align-target-process-{0}{1}.csv' -f [IO.Path]::GetFileNameWithoutExtension($Config), $(if ($WhatIfPreference) { '-whatif' } else { '' }))
$results | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Host "==> Wrote $csv - commit it." -ForegroundColor Green
}
finally { Stop-AutomationRunLog }
