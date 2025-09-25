clear-host
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
Get-ChildItem .\src\_includes\ | Unblock-File

. .\src\_includes\setup.ps1


<#
 .SYNOPSIS
     Migrate Git repositories from source Azure DevOps organisations/projects to a target organisation using full working clones.

 .DESCRIPTION
    Reads organisations & projects from organisations.json (source) and for every enabled source repo ensures a destination
    repository (same project name) exists in the target organisation (projects must already exist) then performs a push of all branches and tags.
    This script has no runtime parameters. It loads:
        - Source organisations/projects from organisations.json in the current data environment.
        - Target settings (targetOrgUrl, targetPat) from target.json in the same data folder.
    All cloning is done to the configured output folder using the structure:
        output/<org>/<project>/repos/<repoName>

EXAMPLE
    pwsh ./src/migrationTools/Migrate-GitRepos.ps1

.NOTES
    Does NOT create target projects; they must already exist.
    PAT values NEVER logged.
    Uses standard working clones so you can add or modify branches locally before pushing. Push sends all branches & tags (does not delete removed refs).
#>

# No parameters: configuration is file based
$ConfigFile = "$dataFolder\organisations.json"
$targetConfigFile = Join-Path $dataFolder 'target.json'
$TargetOrgUrl = $null
$TargetPat = $null

BeginLoggerTitle "Migrate-GitRepos"

if (Test-Path $targetConfigFile) {
    try {
        $targetConfig = Get-Content $targetConfigFile | Out-String | ConvertFrom-Json
        if ($targetConfig.targetOrgUrl) { $TargetOrgUrl = $targetConfig.targetOrgUrl }
        if ($targetConfig.targetPat) { $TargetPat = $targetConfig.targetPat }
        Write-InfoLog "Loaded target settings from target.json"
    }
    catch { Write-WarningLog "Failed to parse target.json: {err}" -PropertyValues $_.Exception.Message }
}

if ([string]::IsNullOrWhiteSpace($TargetOrgUrl)) { Write-Error "TargetOrgUrl missing in target.json"; exit 1 }
if ([string]::IsNullOrWhiteSpace($TargetPat)) { Write-Error "TargetPat missing in target.json"; exit 1 }

# Resolve config file
if (-not (Test-Path $ConfigFile)) { Write-Error "Config file not found: $ConfigFile"; exit 1 }
Write-InfoLog "Using source config {file}" -PropertyValues $ConfigFile
$sourceConfig = Get-Content $ConfigFile | Out-String | ConvertFrom-Json

if (-not (Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null }
# Normalize target URL
$TargetOrgUrl = ($TargetOrgUrl.TrimEnd('/')) + '/'
# Target auth header
$destToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$TargetPat"))
$destHeader = @{ authorization = "Basic $destToken" }

# Pull destination projects once (name -> id)
function Get-TargetProjects {
    param([hashtable]$Header, [string]$OrgUrl)
    $all = @{}
    $projUrl = "$OrgUrl/_apis/projects?api-version=7.0"
    Write-DebugLog "Fetching destination projects {url}" -PropertyValues $projUrl
    $resp = Invoke-RestMethod -Uri $projUrl -Headers $Header -Method Get -ContentType 'application/json'
    foreach ($p in $resp.value) { $all[$p.name] = $p.id }
    return $all
}

$destProjects = Get-TargetProjects -Header $destHeader -OrgUrl $TargetOrgUrl.TrimEnd('/')

function Get-SourceReposForProject {
    param(
        [string]$OrgUrl,
        [string]$ProjectId,
        [hashtable]$Header
    )
    $url = "$OrgUrl/$ProjectId/_apis/git/repositories?$queryString"
    Write-DebugLog "SRC GET {url}" -PropertyValues $url
    return Invoke-RestMethod -Uri $url -Method Get -Headers $Header -ContentType 'application/json'
}

function Get-TargetRepoOrCreate {
    param(
        [string]$DestOrgUrl,
        [string]$DestProjectId,
        [string]$RepoName,
        [hashtable]$Header,
        [switch]$ListOnly
    )
    $listUrl = "$DestOrgUrl/$DestProjectId/_apis/git/repositories?$queryString"
    Write-DebugLog "DEST GET {url}" -PropertyValues $listUrl
    $existing = Invoke-RestMethod -Uri $listUrl -Method Get -Headers $Header -ContentType 'application/json'
    $match = $existing.value | Where-Object { $_.name -eq $RepoName }
    if ($match) { return $match }
    if ($ListOnly) { Write-InfoLog "Would create destination repo {repo}" -PropertyValues $RepoName; return $null }
    Write-InfoLog "Creating destination repo {repo}" -PropertyValues $RepoName
    $body = @{ name = $RepoName } | ConvertTo-Json
    $createUrl = "$DestOrgUrl/$DestProjectId/_apis/git/repositories?$queryString"
    $created = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $Header -ContentType 'application/json' -Body $body
    return $created
}

function Get-LocalRepoPath {
    param(
        [string]$TargetRoot,
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$RepoName
    )
    $orgNameSan = ($OrgUrl -replace 'https://dev.azure.com/', '') -replace 'visualstudio.com/', '' -replace '/', ''
    $projFolder = Join-Path -Path $TargetRoot -ChildPath $orgNameSan
    $projFolder = Join-Path -Path $projFolder -ChildPath $ProjectName
    $reposFolder = Join-Path -Path $projFolder -ChildPath 'repos'
    if (-not (Test-Path $reposFolder)) { New-Item -ItemType Directory -Path $reposFolder -Force | Out-Null }
    return Join-Path -Path $reposFolder -ChildPath ($RepoName.Replace(' ', '_'))
}

function Get-SourceClone {
    param(
        [string]$RemoteUrl,
        [string]$LocalPath,
        [string]$Pat,
        [switch]$Force,
        [switch]$NoBare,
        [switch]$ListOnly
    )
    if ($ListOnly) { Write-InfoLog "Would ensure local clone {path}" -PropertyValues $LocalPath; return }
    if (Test-Path $LocalPath) {
        if ($Force) {
            Write-WarningLog "Removing existing local clone {path}" -PropertyValues $LocalPath
            Remove-Item -Recurse -Force -Path $LocalPath
        }
        else {
            Write-InfoLog "Using existing local clone {path}" -PropertyValues $LocalPath
            return
        }
    }
    $parent = Split-Path -Path $LocalPath -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $uriBuilder = [System.UriBuilder]::new($RemoteUrl)
    $uriBuilder.UserName = 'migration'
    $uriBuilder.Password = $Pat
    $authUrl = $uriBuilder.Uri.AbsoluteUri
    $gitCloneArgs = @('clone', $authUrl, $LocalPath)
    Write-InfoLog "Cloning source repo -> {path}" -PropertyValues $LocalPath
    $env:GIT_TERMINAL_PROMPT = 0
    $res = & git @gitCloneArgs 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Error "git clone failed: $res" } else { Write-InfoLog "Clone complete {path}" -PropertyValues $LocalPath }
    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue | Out-Null
}

function Push-ToTarget {
    param(
        [string]$LocalPath,
        [string]$DestUrl,
        [string]$DestPat
    )
    Write-InfoLog "Pushing -> target"
    $uriBuilder = [System.UriBuilder]::new($DestUrl)
    $uriBuilder.UserName = 'migration'
    $uriBuilder.Password = $DestPat
    $pushUrl = $uriBuilder.Uri.AbsoluteUri
    Push-Location $LocalPath
    try {
        $existing = (& git remote) -split "`n" | Where-Object { $_ -eq 'target' }
        if ($existing) { & git remote set-url target $pushUrl } else { & git remote add target $pushUrl }
        Write-InfoLog "Pushing branches"; $res1 = & git push target --all 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error "git push branches failed: $res1"; return }
        Write-InfoLog "Pushing tags"; $res2 = & git push target --tags 2>&1
        if ($LASTEXITCODE -ne 0) { Write-WarningLog "git push tags failed: $res2" } else { Write-InfoLog "Push complete" }
    }
    finally { Pop-Location }
}

$stats = [ordered]@{
    ReposExamined               = 0
    ReposCreatedTarget          = 0
    ReposPushed                 = 0
    ReposSkippedNoTargetProject = 0
    Errors                      = 0
}

foreach ($org in $sourceConfig.organisations) {
    if (-not $org.enabled) { continue }
    if (-not $org.pat) { Write-WarningLog "Skipping org missing PAT {org}" -PropertyValues $org.url; continue }
    $srcToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($org.pat)"))
    $srcHeader = @{ authorization = "Basic $srcToken" }
    Write-InfoLog "Organisation {org}" -PropertyValues $org.url

    foreach ($project in $org.projects) {
        if (-not $project.enabled) { continue }
        $destProjectName = $project.name
        if (-not $destProjects.ContainsKey($destProjectName)) {
            Write-WarningLog "Target project missing {project}" -PropertyValues $destProjectName
            $stats.ReposSkippedNoTargetProject++
            continue
        }
        $destProjectId = $destProjects[$destProjectName]
        Write-InfoLog "  Project {project} -> {dest}" -PropertyValues $project.name, $destProjectName
        try { $srcRepos = Get-SourceReposForProject -OrgUrl $org.url -ProjectId $project.id -Header $srcHeader } catch { Write-Error "Failed to list repos for $($project.name): $($_.Exception.Message)"; $stats.Errors++; continue }
        if (-not $srcRepos.value) { continue }

        foreach ($repo in $srcRepos.value) {
            $stats.ReposExamined++
            Write-InfoLog "    Repo {repo}" -PropertyValues $repo.name
            $localPath = Get-LocalRepoPath -TargetRoot $outputFolder -OrgUrl $org.url -ProjectName $project.name -RepoName $repo.name
            Get-SourceClone -RemoteUrl $repo.remoteUrl -LocalPath $localPath -Pat $org.pat

            # Ensure destination repo exists
            $destRepo = $null
            try { $destRepo = Get-TargetRepoOrCreate -DestOrgUrl $TargetOrgUrl.TrimEnd('/') -DestProjectId $destProjectId -RepoName $repo.name -Header $destHeader } catch { Write-Error "Failed to ensure target repo $($repo.name): $($_.Exception.Message)"; $stats.Errors++; continue }
            if ($destRepo) { $stats.ReposCreatedTarget++ }

            # Construct destination repo clone URL pattern: https://dev.azure.com/org/project/_git/repo
            $destRepoUrl = "$TargetOrgUrl$destProjectName/_git/$($repo.name)"
            Push-ToTarget -LocalPath $localPath -DestUrl $destRepoUrl -DestPat $TargetPat
            $stats.ReposPushed++
        }
    }
}

Write-InfoLog "=============="
Write-InfoLog "MIGRATION COMPLETE"
Write-InfoLog "=============="
Write-InfoLog "Examined: $($stats.ReposExamined)  CreatedTarget: $($stats.ReposCreatedTarget)  Pushed: $($stats.ReposPushed)  SkippedNoTargetProject: $($stats.ReposSkippedNoTargetProject)  Errors: $($stats.Errors)"
