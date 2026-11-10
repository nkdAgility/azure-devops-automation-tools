<#
.SYNOPSIS
    Read-only inventory of one source project's pipelines and process, with an optional process
    comparison against one or more target projects.

.DESCRIPTION
    Writes, under output\:
      pipeline-inventory-<Project>.csv   build (YAML/classic) and release definitions
      process-inventory-<Project>.csv    work item types and fields per process
      process-match-<Project>.csv        one row per source type/field, with each target's match
    The source is reached with the project's PAT (AZDO_PAT_<ORG>__<PROJECT>, then AZDO_PAT_<ORG>);
    targets go through Get-AzureDevOpsAccessToken (Entra). Nothing is written to either organisation.

.PARAMETER Project
    The ONE source project to inventory.

.PARAMETER TargetProject
    Target project(s) whose process to compare against.

.EXAMPLE
    .\migrations\NN-Name\Run-ProjectInventory.ps1 -Project <SourceProject> -TargetProject <TargetProject>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$SourceOrg,
    [string[]]$TargetProject = @(),
    [string]$TargetOrg
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$WhatIfPreference = $false

. "$PSScriptRoot\..\..\init.ps1"
Start-AutomationRunLog -Name 'Run-ProjectInventory'
try {

function Get-OrgName([string]$Url) { ($Url.TrimEnd('/') -split '/')[-1] }

function Get-SourceHeader {
    $org = (Get-OrgName $SourceOrg).ToUpperInvariant()
    $proj = ($Project -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
    $pat = [Environment]::GetEnvironmentVariable("AZDO_PAT_${org}__${proj}")
    if (-not $pat) { $pat = [Environment]::GetEnvironmentVariable("AZDO_PAT_$org") }
    if (-not $pat) { throw "No PAT for $SourceOrg / $Project in the environment." }
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
}

function Get-Rest([string]$Url, [hashtable]$Headers) {
    $items = @(); $token = $null
    do {
        $u = if ($token) { "$Url&continuationToken=$token" } else { $Url }
        $resp = Invoke-WebRequest -Uri $u -Headers $Headers -UseBasicParsing
        $body = $resp.Content | ConvertFrom-Json
        if ($body.PSObject.Properties['value']) { $items += @($body.value) } else { $items += $body }
        $token = $resp.Headers['x-ms-continuationtoken'] | Select-Object -First 1
    } while ($token)
    $items
}

function Get-ProcessShape([string]$Org, [string]$Proj, [hashtable]$Headers) {
    $p = Get-Rest "$Org/_apis/projects/$([uri]::EscapeDataString($Proj))?includeCapabilities=true&api-version=7.1" $Headers
    $procId = $p.capabilities.processTemplate.templateTypeId
    $proc = Get-Rest "$Org/_apis/work/processes/$procId`?api-version=7.1" $Headers
    $types = @{}
    foreach ($t in Get-Rest "$Org/_apis/work/processes/$procId/workitemtypes?api-version=7.1" $Headers) {
        if ($t.isDisabled) { continue }
        $fields = Get-Rest "$Org/_apis/work/processes/$procId/workitemtypes/$($t.referenceName)/fields?api-version=7.1" $Headers
        $states = Get-Rest "$Org/_apis/work/processes/$procId/workitemtypes/$($t.referenceName)/states?api-version=7.1" $Headers
        $types[$t.name] = @{ Fields = @($fields.referenceName); States = @($states | Where-Object { -not ($_.PSObject.Properties['hidden'] -and $_.hidden) } | ForEach-Object name) }
    }
    [pscustomobject]@{ Project = $Proj; Process = $proc.name; ProcessType = $proc.customizationType; Types = $types }
}

$outDir = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$src = Get-SourceHeader
$base = "$SourceOrg/$([uri]::EscapeDataString($Project))"

# Pipelines
Write-Host "==> Pipelines in $SourceOrg / $Project" -ForegroundColor Cyan
$rows = foreach ($d in Get-Rest "$base/_apis/build/definitions?includeLatestBuilds=true&queryOrder=definitionNameAscending&api-version=7.1" $src) {
    $full = Get-Rest "$base/_apis/build/definitions/$($d.id)?api-version=7.1" $src
    [pscustomobject]@{
        Project = $Project; Kind = 'Build'; Name = $d.name; Path = $d.path
        Type = if ($full.process.type -eq 2) { 'YAML' } else { 'Classic' }
        YamlFile = if ($full.process.type -eq 2) { $full.process.yamlFilename } else { '' }
        Repo = $full.repository.name; RepoType = $full.repository.type
        QueueStatus = $d.queueStatus
        LastRun = if ($d.PSObject.Properties['latestBuild'] -and $d.latestBuild -and $d.latestBuild.PSObject.Properties['finishTime']) { $d.latestBuild.finishTime } else { '' }
    }
}
$rmBase = "https://vsrm.dev.azure.com/$(Get-OrgName $SourceOrg)/$([uri]::EscapeDataString($Project))"
$rows += foreach ($r in Get-Rest "$rmBase/_apis/release/definitions?`$expand=lastRelease&api-version=7.1" $src) {
    [pscustomobject]@{
        Project = $Project; Kind = 'Release'; Name = $r.name; Path = $r.path; Type = 'Classic'; YamlFile = ''
        Repo = ''; RepoType = ''; QueueStatus = ''
        LastRun = if ($r.PSObject.Properties['lastRelease'] -and $r.lastRelease) { $r.lastRelease.createdOn } else { '' }
    }
}
$pipeCsv = Join-Path $outDir "pipeline-inventory-$Project.csv"
@($rows) | Export-Csv -LiteralPath $pipeCsv -NoTypeInformation
@($rows) | Group-Object Kind, Type | ForEach-Object { '  {0,-18} {1,4}' -f $_.Name, $_.Count } | Write-Host
Write-Host "==> Wrote $pipeCsv - commit it." -ForegroundColor Green

# Process
$shapes = @(Get-ProcessShape $SourceOrg $Project $src)
foreach ($tp in $TargetProject) {
    $tok = Get-AzureDevOpsAccessToken -Collection $TargetOrg
    $shapes += Get-ProcessShape $TargetOrg $tp @{ Authorization = "Bearer $tok" }
}
foreach ($s in $shapes) { Write-Host ("  {0,-24} {1} ({2}), {3} types" -f $s.Project, $s.Process, $s.ProcessType, $s.Types.Count) }

$procRows = foreach ($s in $shapes) { foreach ($t in $s.Types.Keys | Sort-Object) {
    foreach ($f in $s.Types[$t].Fields) { [pscustomobject]@{ Project = $s.Project; Process = $s.Process; Type = $t; Kind = 'Field'; Name = $f } }
    foreach ($st in $s.Types[$t].States) { [pscustomobject]@{ Project = $s.Project; Process = $s.Process; Type = $t; Kind = 'State'; Name = $st } }
} }
$procCsv = Join-Path $outDir "process-inventory-$Project.csv"
@($procRows) | Export-Csv -LiteralPath $procCsv -NoTypeInformation
Write-Host "==> Wrote $procCsv - commit it." -ForegroundColor Green

if ($shapes.Count -gt 1) {
    $match = foreach ($r in $procRows | Where-Object Project -eq $Project) {
        $o = [ordered]@{ Type = $r.Type; Kind = $r.Kind; Name = $r.Name }
        foreach ($t in $shapes | Select-Object -Skip 1) {
            $o[$t.Project] = if (-not $t.Types.ContainsKey($r.Type)) { 'missing type' }
                elseif (($r.Kind -eq 'Field' -and $t.Types[$r.Type].Fields -contains $r.Name) -or
                        ($r.Kind -eq 'State' -and $t.Types[$r.Type].States -contains $r.Name)) { 'ok' } else { 'missing' }
        }
        [pscustomobject]$o
    }
    $matchCsv = Join-Path $outDir "process-match-$Project.csv"
    @($match) | Export-Csv -LiteralPath $matchCsv -NoTypeInformation
    foreach ($t in $shapes | Select-Object -Skip 1) {
        $gaps = @($match | Where-Object { $_.($t.Project) -ne 'ok' })
        Write-Host ("  vs {0}: {1} gaps of {2}" -f $t.Project, $gaps.Count, @($match).Count)
    }
    Write-Host "==> Wrote $matchCsv - commit it." -ForegroundColor Green
}

}
finally { Stop-AutomationRunLog }
