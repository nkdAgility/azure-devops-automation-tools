<#
.SYNOPSIS
    Adds to the target project's process what the source project's work items need
    (work item types, fields, picklist values, states, backlog levels), using the
    source and target named in a work item configuration in this folder.

.DESCRIPTION
    Writes to the TARGET organisation's process. Run with -WhatIf first, always.

    Thin wrapper over Sync-InheritedProcess (module): nothing about any project is
    written here. The organisations and projects come from the work item config's
    Source and Target endpoints, so one script serves every config in the folder.

    It only adds. It refuses a target process other projects share unless
    -AllowSharedProcess is given, and stops with instructions when the target project
    is on a system process (Agile, Scrum, CMMI, Basic), which cannot be customised.

.PARAMETER Config
    Work item configuration file in this folder, e.g. configuration-workitems.json.

.PARAMETER WorkItemType
    Optional. Only these source work item types.

.PARAMETER AllowSharedProcess
    Write to a target process that other projects also use.

.EXAMPLE
    .\migrations\NN-Name\Align-TargetProcess.ps1 -Config configuration-workitems.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$Config,

    [string[]]$WorkItemType,

    [switch]$AllowSharedProcess
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\..\..\init.ps1"
# Record this run's whole console to output\runs\ (committed engagement history).
Start-AutomationRunLog -Name 'Align-TargetProcess'
try {

$configPath = Join-Path $PSScriptRoot $Config
if (-not (Test-Path -LiteralPath $configPath)) { throw "Configuration file not found: $configPath" }
$endpoints = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).MigrationTools.Endpoints

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
