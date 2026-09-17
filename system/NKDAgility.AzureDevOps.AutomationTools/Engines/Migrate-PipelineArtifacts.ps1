<#
.SYNOPSIS
    Inventories build, pipeline, and release artifacts in an Azure DevOps project.

.DESCRIPTION
    Read-only. Enumerates all build runs and release records with continuation
    tokens. The candidate CSV includes only files with a version in the name
    and an allowed extension. Classic Container files can be listed directly.
    Pipeline artifacts and other non-Container resources are recorded in a
    coverage CSV because the build API does not expose their file trees.
    Build-backed releases link to qualifying files in their source builds.
    No files are downloaded and no remote state is changed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceOrg,
    [Parameter(Mandatory)][string]$SourceProject,
    [string]$SourcePat,
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)][string]$CoveragePath,
    [Parameter(Mandatory)][string]$ErrorsPath,
    [string[]]$ExtensionInclude = @('.zip', '.nspec', '.nuspec', '.nupkg'),
    [string[]]$ExtensionExclude,
    [string]$FilePattern = '^(?<product>.+?)[.-](?<version>\d+\.\d+\.\d+(?:\.\d+)*(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?)\.(?<format>[A-Za-z0-9]+)$',
    [string[]]$BranchInclude,
    [string[]]$BranchExclude,
    [int]$MaxBuilds = 0,
    [int]$MaxReleases = 0,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($MaxBuilds -lt 0 -or $MaxReleases -lt 0) { throw 'Limits must be zero or positive.' }
if (-not (Get-Command Resolve-AzureDevOpsAuth -ErrorAction SilentlyContinue)) {
    throw 'Load NKDAgility.AzureDevOps.AutomationTools before invoking this engine.'
}

$orgBase = $SourceOrg.TrimEnd('/')
$projectPart = [Uri]::EscapeDataString($SourceProject)
$orgUri = [Uri]$orgBase
$orgName = if ($orgUri.Host -match '^([^.]+)\.visualstudio\.com$') {
    $Matches[1]
} else {
    ($orgUri.AbsolutePath.Trim('/') -split '/')[0]
}
if (-not $orgName) { throw "Could not resolve organisation name from '$SourceOrg'." }
$releaseBase = if (Test-AzureDevOpsHosted -Collection $SourceOrg) {
    "https://vsrm.dev.azure.com/$orgName/$projectPart"
} else {
    "$orgBase/$projectPart"
}

function Initialize-SourceAuth {
    $auth = Resolve-AzureDevOpsAuth -Collection $SourceOrg -Pat $SourcePat -Label 'source'
    $script:authHeaders = $auth.Headers
    $script:useDefaultCredentials = $auth.Mode -eq 'Windows'
    if ($script:authMode -ne $auth.Mode) {
        Write-Host "==> Source auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:authMode = $auth.Mode
    }
}

function Invoke-InventoryRequest {
    param([string]$Uri, [switch]$Raw)
    $params = @{ Uri = $Uri; ErrorAction = 'Stop' }
    if ($script:useDefaultCredentials) { $params.UseDefaultCredentials = $true }
    else { $params.Headers = $script:authHeaders }
    if ($Raw) { return Invoke-WebRequest @params }
    Invoke-RestMethod @params
}

function Write-CsvRow {
    param([IO.StreamWriter]$Writer, [object]$Row)
    $line = $Row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
    $Writer.WriteLine($line)
}

$fileRegex = [regex]::new($FilePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromSeconds(1))
foreach ($group in @('product', 'version', 'format')) {
    if ($fileRegex.GetGroupNames() -notcontains $group) { throw "FilePattern must contain a named '$group' capture." }
}
$extensionIncludes = [Collections.Generic.List[Management.Automation.WildcardPattern]]::new()
$extensionExcludes = [Collections.Generic.List[Management.Automation.WildcardPattern]]::new()
foreach ($pattern in $ExtensionInclude) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Extension include patterns cannot be empty.' }
    $extensionIncludes.Add([Management.Automation.WildcardPattern]::new($pattern, [Management.Automation.WildcardOptions]::IgnoreCase))
}
foreach ($pattern in $ExtensionExclude) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Extension exclude patterns cannot be empty.' }
    $extensionExcludes.Add([Management.Automation.WildcardPattern]::new($pattern, [Management.Automation.WildcardOptions]::IgnoreCase))
}
$includeGlobs = [Collections.Generic.List[Management.Automation.WildcardPattern]]::new()
$excludeGlobs = [Collections.Generic.List[Management.Automation.WildcardPattern]]::new()
foreach ($pattern in $BranchInclude) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Branch include patterns cannot be empty.' }
    $includeGlobs.Add([Management.Automation.WildcardPattern]::new($pattern, [Management.Automation.WildcardOptions]::IgnoreCase))
}
foreach ($pattern in $BranchExclude) {
    if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Branch exclude patterns cannot be empty.' }
    $excludeGlobs.Add([Management.Automation.WildcardPattern]::new($pattern, [Management.Automation.WildcardOptions]::IgnoreCase))
}
function Test-SelectedBranch {
    param([string]$Branch)
    $value = if ([string]::IsNullOrWhiteSpace($Branch)) { '<none>' } else { $Branch }
    $included = $includeGlobs.Count -eq 0
    foreach ($glob in $includeGlobs) { if ($glob.IsMatch($value)) { $included = $true; break } }
    if (-not $included) { return $false }
    foreach ($glob in $excludeGlobs) { if ($glob.IsMatch($value)) { return $false } }
    $true
}
function Test-SelectedExtension {
    param([string]$Extension)
    $included = $extensionIncludes.Count -eq 0
    foreach ($glob in $extensionIncludes) { if ($glob.IsMatch($extension)) { $included = $true; break } }
    if (-not $included) { return $false }
    foreach ($glob in $extensionExcludes) { if ($glob.IsMatch($extension)) { return $false } }
    $true
}
function Get-CandidateMetadata {
    param([string]$Path)
    if (-not $Path) { return $null }
    $name = [IO.Path]::GetFileName($Path)
    $extension = [IO.Path]::GetExtension($name)
    if (-not (Test-SelectedExtension -Extension $extension)) { return $null }
    $match = $fileRegex.Match($name)
    if (-not $match.Success) { return $null }
    $product = $match.Groups['product'].Value
    $version = $match.Groups['version'].Value
    $format = $match.Groups['format'].Value
    if (-not $product -or -not $version -or -not $format) { return $null }
    if ($extension -ine '.' + $format) { return $null }
    [pscustomobject]@{ Product = $product; Version = $version; Format = $format }
}

function Write-ArtifactRow {
    param(
        [string]$Location, $RunId, [string]$RunName, [string]$Definition,
        [string]$CreatedOn, [string]$Branch, [string]$Artifact,
        [string]$ArtifactType, [string]$SourceProjectName, $SourceRunId,
        [string]$SourceVersion, [string]$Path, $Bytes, [string]$Status
    )
    if (-not (Test-SelectedBranch -Branch $Branch)) { return }
    $candidate = if ($Status -eq 'File' -or $Status -eq 'ReleaseFileReference') { Get-CandidateMetadata -Path $Path } else { $null }
    if ($Status -eq 'File' -and $null -eq $candidate) {
        if (-not (Test-SelectedExtension -Extension ([IO.Path]::GetExtension($Path)))) { return }
        $Status = 'FilePatternNotMatched'
    }
    if ($Status -eq 'ReleaseFileReference' -and $null -eq $candidate) { return }
    $row = [pscustomobject]@{
        Location = $Location
        RunId = $RunId
        RunName = $RunName
        Definition = $Definition
        CreatedOn = $CreatedOn
        Branch = $Branch
        Artifact = $Artifact
        ArtifactType = $ArtifactType
        SourceProject = $SourceProjectName
        SourceRunId = $SourceRunId
        SourceVersion = $SourceVersion
        Path = $Path
        FileName = if ($Path) { [IO.Path]::GetFileName($Path) } else { '' }
        Product = if ($candidate) { $candidate.Product } else { '' }
        Version = if ($candidate) { $candidate.Version } else { '' }
        Format = if ($candidate) { $candidate.Format } else { '' }
        Bytes = $Bytes
        Status = $Status
    }
    if ($Status -eq 'File' -or $Status -eq 'ReleaseFileReference') {
        Write-CsvRow $script:csvWriter $row
        $script:rowCount++
        $script:fileCount++
        $productKey = $candidate.Product
        if (-not $script:productSummary.ContainsKey($productKey)) {
            $script:productSummary[$productKey] = [pscustomobject]@{
                Versions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                Files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                Formats = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                BuildRows = 0
                ReleaseRows = 0
            }
        }
        $summary = $script:productSummary[$productKey]
        [void]$summary.Versions.Add($candidate.Version)
        [void]$summary.Files.Add($row.FileName)
        [void]$summary.Formats.Add($candidate.Format)
        if ($Location -eq 'BuildArtifact') { $summary.BuildRows++ }
        elseif ($Location -eq 'ReleaseArtifact') { $summary.ReleaseRows++ }
        if ($Location -eq 'BuildArtifact') {
            $key = [string]$RunId
            if (-not $script:candidatesByBuild.ContainsKey($key)) {
                $script:candidatesByBuild[$key] = [Collections.Generic.List[object]]::new()
            }
            $script:candidatesByBuild[$key].Add([pscustomobject]@{ Path = $Path; Bytes = $Bytes; Artifact = $Artifact; ArtifactType = $ArtifactType })
        }
    } else {
        Write-CsvRow $script:coverageWriter $row
        $script:rowCount++
        $script:metadataCount++
    }
}

function Write-InventoryError {
    param([string]$Location, $RunId, [string]$Artifact, [string]$Message)
    Write-CsvRow $script:errorWriter ([pscustomobject]@{
        Location = $Location
        RunId = $RunId
        Artifact = $Artifact
        Error = $Message
    })
    $script:errorCount++
}

foreach ($path in @($CsvPath, $SummaryPath, $CoveragePath, $ErrorsPath)) {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}
$script:csvWriter = [IO.StreamWriter]::new([IO.Path]::GetFullPath($CsvPath), $false, [Text.UTF8Encoding]::new($true))
$script:summaryWriter = [IO.StreamWriter]::new([IO.Path]::GetFullPath($SummaryPath), $false, [Text.UTF8Encoding]::new($true))
$script:coverageWriter = [IO.StreamWriter]::new([IO.Path]::GetFullPath($CoveragePath), $false, [Text.UTF8Encoding]::new($true))
$script:errorWriter = [IO.StreamWriter]::new([IO.Path]::GetFullPath($ErrorsPath), $false, [Text.UTF8Encoding]::new($true))
$columns = 'Location,RunId,RunName,Definition,CreatedOn,Branch,Artifact,ArtifactType,SourceProject,SourceRunId,SourceVersion,Path,FileName,Product,Version,Format,Bytes,Status'
$script:csvWriter.WriteLine($columns)
$script:summaryWriter.WriteLine('Product,Versions,UniqueFiles,Formats,BuildRows,ReleaseRows')
$script:coverageWriter.WriteLine($columns)
$script:errorWriter.WriteLine('Location,RunId,Artifact,Error')
$script:candidatesByBuild = @{}
$script:productSummary = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$script:branchByBuild = @{}
$script:authMode = ''
$script:rowCount = 0
$script:fileCount = 0
$script:metadataCount = 0
$script:errorCount = 0
$buildCount = 0
$releaseCount = 0

Write-Host 'Inventory only: listing build, pipeline, and release artifacts. No files will be downloaded or published.'
try {
    Initialize-SourceAuth
    $continuation = $null
    do {
        $query = 'api-version=7.1&%24top=100&queryOrder=finishTimeDescending'
        if ($continuation) { $query += '&continuationToken=' + [Uri]::EscapeDataString($continuation) }
        $pageResponse = Invoke-InventoryRequest -Uri "$orgBase/$projectPart/_apis/build/builds?$query" -Raw
        $page = $pageResponse.Content | ConvertFrom-Json
        $continuation = [string]$pageResponse.Headers['x-ms-continuationtoken']
        if ([string]::IsNullOrWhiteSpace($continuation)) { $continuation = $null }
        foreach ($build in @($page.value)) {
            if ($MaxBuilds -gt 0 -and $buildCount -ge $MaxBuilds) { break }
            $buildCount++
            $script:branchByBuild[[string]$build.id] = [string]$build.sourceBranch
            Initialize-SourceAuth
            try {
                $artifacts = Invoke-InventoryRequest -Uri "$orgBase/$projectPart/_apis/build/builds/$($build.id)/artifacts?api-version=7.1"
                foreach ($artifact in @($artifacts.value)) {
                    $location = if ($artifact.resource.type -eq 'PipelineArtifact') { 'PipelineArtifact' } else { 'BuildArtifact' }
                    if ($artifact.resource.type -ne 'Container') {
                        Write-ArtifactRow $location $build.id $build.buildNumber $build.definition.name $build.finishTime $build.sourceBranch $artifact.name $artifact.resource.type $SourceProject $build.id $build.buildNumber '' $null 'ArtifactMetadataOnly'
                        continue
                    }
                    if ($artifact.resource.data -notmatch '^#/(\d+)/(.+)$') {
                        Write-InventoryError $location $build.id $artifact.name 'Unexpected Container resource identifier.'
                        continue
                    }
                    $containerId = $Matches[1]
                    $itemPath = [Uri]::EscapeDataString($Matches[2])
                    try {
                        $items = Invoke-InventoryRequest -Uri "$orgBase/_apis/resources/Containers/$containerId`?itemPath=$itemPath&isShallow=false&api-version=7.1-preview.4"
                        $files = @($items.value | Where-Object { $_.itemType -eq 'file' })
                        if ($files.Count -eq 0) {
                            Write-ArtifactRow $location $build.id $build.buildNumber $build.definition.name $build.finishTime $build.sourceBranch $artifact.name $artifact.resource.type $SourceProject $build.id $build.buildNumber '' $null 'EmptyArtifact'
                        }
                        foreach ($item in $files) {
                            Write-ArtifactRow $location $build.id $build.buildNumber $build.definition.name $build.finishTime $build.sourceBranch $artifact.name $artifact.resource.type $SourceProject $build.id $build.buildNumber ([string]$item.path) $item.fileLength 'File'
                        }
                    } catch {
                        Write-InventoryError $location $build.id $artifact.name $_.Exception.Message
                    }
                }
            } catch {
                Write-InventoryError 'BuildArtifact' $build.id '' $_.Exception.Message
            }
            if ($buildCount % 100 -eq 0) { Write-Host "Builds: $buildCount; files: $script:fileCount; metadata rows: $script:metadataCount; errors: $script:errorCount." }
        }
    } while ($continuation -and ($MaxBuilds -eq 0 -or $buildCount -lt $MaxBuilds))

    $continuation = $null
    do {
        Initialize-SourceAuth
        $query = 'api-version=7.1&%24top=100&%24expand=artifacts'
        if ($continuation) { $query += '&continuationToken=' + [Uri]::EscapeDataString($continuation) }
        $pageResponse = Invoke-InventoryRequest -Uri "$releaseBase/_apis/release/releases?$query" -Raw
        $page = $pageResponse.Content | ConvertFrom-Json
        $continuation = [string]$pageResponse.Headers['x-ms-continuationtoken']
        if ([string]::IsNullOrWhiteSpace($continuation)) { $continuation = $null }
        foreach ($release in @($page.value)) {
            if ($MaxReleases -gt 0 -and $releaseCount -ge $MaxReleases) { break }
            $releaseCount++
            foreach ($artifact in @($release.artifacts)) {
                $sourceProject = [string]$artifact.definitionReference.project.name
                $sourceRunId = [string]$artifact.definitionReference.version.id
                $sourceVersion = [string]$artifact.definitionReference.version.name
                $sourceBuildScanned = $sourceProject -eq $SourceProject -and $script:branchByBuild.ContainsKey($sourceRunId)
                $sourceBranch = if ($sourceBuildScanned) { $script:branchByBuild[$sourceRunId] } else { '<unknown>' }
                if ($artifact.type -eq 'Build' -and $script:candidatesByBuild.ContainsKey($sourceRunId) -and $sourceProject -eq $SourceProject) {
                    foreach ($candidate in $script:candidatesByBuild[$sourceRunId]) {
                        Write-ArtifactRow 'ReleaseArtifact' $release.id $release.name $release.releaseDefinition.name $release.createdOn $sourceBranch $artifact.alias $artifact.type $sourceProject $sourceRunId $sourceVersion $candidate.Path $candidate.Bytes 'ReleaseFileReference'
                    }
                } else {
                    $status = if ($artifact.type -eq 'Build' -and -not $sourceBuildScanned) { 'ReferencedBuildNotScanned' } elseif ($artifact.type -eq 'Build') { 'ReferencedBuildHasNoCandidate' } else { 'ArtifactMetadataOnly' }
                    Write-ArtifactRow 'ReleaseArtifact' $release.id $release.name $release.releaseDefinition.name $release.createdOn $sourceBranch $artifact.alias $artifact.type $sourceProject $sourceRunId $sourceVersion '' $null $status
                }
            }
            if ($releaseCount % 100 -eq 0) { Write-Host "Releases: $releaseCount; total rows: $script:rowCount; errors: $script:errorCount." }
        }
    } while ($continuation -and ($MaxReleases -eq 0 -or $releaseCount -lt $MaxReleases))
}
finally {
    foreach ($product in @($script:productSummary.Keys | Sort-Object)) {
        $summary = $script:productSummary[$product]
        Write-CsvRow $script:summaryWriter ([pscustomobject]@{
            Product = $product
            Versions = $summary.Versions.Count
            UniqueFiles = $summary.Files.Count
            Formats = (@($summary.Formats | Sort-Object) -join ',')
            BuildRows = $summary.BuildRows
            ReleaseRows = $summary.ReleaseRows
        })
    }
    $script:csvWriter.Dispose()
    $script:summaryWriter.Dispose()
    $script:coverageWriter.Dispose()
    $script:errorWriter.Dispose()
}

Write-Host "Scan finished: $buildCount builds, $releaseCount releases, $script:fileCount candidate rows, $script:metadataCount coverage rows, $script:errorCount errors."
Write-Host "Candidates: $CsvPath"
Write-Host "Products: $SummaryPath"
Write-Host "Coverage: $CoveragePath"
Write-Host "Errors: $ErrorsPath"
if ($script:errorCount -gt 0) {
    Write-Warning 'Some artifact lookups failed; review the errors CSV. Other inventory rows remain available.'
}
