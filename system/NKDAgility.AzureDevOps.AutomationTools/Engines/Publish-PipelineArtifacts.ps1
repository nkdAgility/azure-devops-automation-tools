<#
.SYNOPSIS
    Plans or publishes inventoried build files as Universal Packages.

.DESCRIPTION
    Uses BuildArtifact/File rows from the pipeline artifact inventory. Release
    rows refer to those same build files and are not published a second time.
    Checks the destination before writing the action-only plan, omitting
    versions that already exist. -Publish downloads one original file
    per remaining package, checks its length, and publishes without recompression.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InventoryPath,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$WorkPath,
    [Parameter(Mandatory)][string]$SourceOrg,
    [Parameter(Mandatory)][string]$SourceProject,
    [string]$SourcePat,
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$TargetProject,
    [Parameter(Mandatory)][object[]]$FeedMappings,
    [Parameter(Mandatory)][string[]]$FormatPrecedence,
    [string]$TargetPat,
    [switch]$Publish,
    [switch]$AllowPartial,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Publish -and $WhatIf) { throw 'Use -Publish for uploads or -WhatIf for a plan, not both.' }
if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) { throw "Inventory not found: $InventoryPath" }

function Convert-PackageVersion {
    param([string]$Version)
    $match = [regex]::Match($Version, '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:\.(?<revision>0|[1-9]\d*))?(?:-(?<suffix>[a-zA-Z0-9][a-zA-Z0-9.-]*))?$')
    if (-not $match.Success) { return $null }
    $revision = if ($match.Groups['revision'].Success) { [long]$match.Groups['revision'].Value } else { [long]-1 }
    $packageVersion = "$($match.Groups['major'].Value).$($match.Groups['minor'].Value).$($match.Groups['patch'].Value)"
    if ($match.Groups['suffix'].Success) { $packageVersion += '-' + $match.Groups['suffix'].Value.ToLowerInvariant() }
    [pscustomobject]@{
        PackageVersion = $packageVersion
        Revision = $revision
    }
}

$requiredColumns = @('Location', 'Status', 'RunId', 'Artifact', 'Path', 'FileName', 'Product', 'Version', 'Format', 'Bytes', 'Branch')
$compiledMappings = [Collections.Generic.List[object]]::new()
foreach ($mapping in $FeedMappings) {
    if (-not $mapping.ProductPattern -or -not $mapping.Feed) { throw 'Each feed mapping needs ProductPattern and Feed.' }
    $compiledMappings.Add([pscustomobject]@{
        Pattern = [Management.Automation.WildcardPattern]::new([string]$mapping.ProductPattern, [Management.Automation.WildcardOptions]::IgnoreCase)
        Feed = [string]$mapping.Feed
    })
}
if ($compiledMappings.Count -eq 0) { throw 'At least one product-to-feed mapping is required.' }
$inventory = @(Import-Csv -LiteralPath $InventoryPath)
if ($inventory.Count -eq 0) { throw "Inventory has no rows: $InventoryPath" }
foreach ($column in $requiredColumns) {
    if ($inventory[0].PSObject.Properties.Name -notcontains $column) { throw "Inventory is missing column '$column'. Rerun the inventory with the current engine." }
}
$buildRows = @($inventory | Where-Object { $_.Location -eq 'BuildArtifact' -and $_.Status -eq 'File' })
$formatPatterns = [Collections.Generic.List[object]]::new()
$seenPatterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
for ($index = 0; $index -lt $FormatPrecedence.Count; $index++) {
    $pattern = $FormatPrecedence[$index].TrimStart('.')
    if (-not $pattern -or -not $seenPatterns.Add($pattern)) { throw "Duplicate or empty format precedence entry: $($FormatPrecedence[$index])" }
    $formatPatterns.Add([Management.Automation.WildcardPattern]::new($pattern, [Management.Automation.WildcardOptions]::IgnoreCase))
}
if ($FormatPrecedence.Count -eq 0 -or $FormatPrecedence[-1] -ne '*') { throw 'FormatPrecedence must end with *.' }
function Get-FormatRank {
    param([string]$Format)
    for ($index = 0; $index -lt $formatPatterns.Count; $index++) {
        if ($formatPatterns[$index].IsMatch($Format)) { return $index }
    }
    throw "No format precedence pattern matches '$Format'."
}
$formatsByProduct = @{}
foreach ($row in $buildRows) {
    $productKey = $row.Product.ToLowerInvariant()
    if (-not $formatsByProduct.ContainsKey($productKey)) {
        $formatsByProduct[$productKey] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $null = $formatsByProduct[$productKey].Add($row.Format)
}
$primaryFormatByProduct = @{}
foreach ($productKey in $formatsByProduct.Keys) {
    $primaryFormatByProduct[$productKey] = @($formatsByProduct[$productKey] | Sort-Object `
        @{ Expression = { Get-FormatRank -Format $_ } }, `
        @{ Expression = { $_.ToLowerInvariant() } } | Select-Object -First 1)[0]
}
$plan = [Collections.Generic.List[object]]::new()
foreach ($row in $buildRows) {
    $feed = ''
    foreach ($mapping in $compiledMappings) {
        if ($mapping.Pattern.IsMatch($row.Product)) { $feed = $mapping.Feed; break }
    }
    $name = if ($row.Format -ieq $primaryFormatByProduct[$row.Product.ToLowerInvariant()]) { $row.Product } else { "$($row.Product).$($row.Format)" }
    $name = $name.ToLowerInvariant()
    $parsedVersion = Convert-PackageVersion -Version $row.Version
    $version = if ($parsedVersion) { $parsedVersion.PackageVersion } else { '' }
    $status = 'Ready'
    $detail = ''
    if (-not $feed) {
        $status = 'NoFeedMapping'; $detail = 'No product pattern maps this product to a feed.'
    } elseif ($name -notmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*$') {
        $status = 'InvalidPackageName'; $detail = 'Product and format do not form a valid Universal Package name.'
    } elseif (-not $parsedVersion) {
        $status = 'InvalidVersion'; $detail = 'Expected a three- or four-part numeric version with an optional prerelease label.'
    } elseif (-not $row.RunId -or -not $row.Artifact -or -not $row.Path -or -not $row.FileName) {
        $status = 'MissingSource'; $detail = 'Build ID, artifact, path, or filename is missing.'
    }
    $plan.Add([pscustomobject]@{
        Feed = $feed
        PackageName = $name
        PackageVersion = [string]$version
        Product = $row.Product
        SourceVersion = $row.Version
        Revision = if ($parsedVersion) { $parsedVersion.Revision } else { '' }
        Format = $row.Format
        FileName = $row.FileName
        Branch = $row.Branch
        BuildId = $row.RunId
        Artifact = $row.Artifact
        ArtifactPath = $row.Path
        Bytes = $row.Bytes
        Status = $status
        Detail = $detail
    })
}

foreach ($group in @($plan | Where-Object Status -eq 'Ready' | Group-Object Feed, PackageName, PackageVersion)) {
    $latestRevision = @($group.Group | Measure-Object -Property Revision -Maximum)[0].Maximum
    foreach ($row in $group.Group) {
        if ($row.Revision -lt $latestRevision) {
            $row.Status = 'SupersededByRevision'
            $row.Detail = "A later source revision maps to $($row.PackageVersion)."
        }
    }
    $latest = @($group.Group | Where-Object Status -eq 'Ready')
    if ($latest.Count -lt 2) { continue }
    $latestBuildId = @($latest | Measure-Object -Property BuildId -Maximum)[0].Maximum
    foreach ($row in $latest) {
        if ([long]$row.BuildId -lt [long]$latestBuildId) {
            $row.Status = 'SupersededByBuild'
            $row.Detail = "A later build contains the same source revision for $($row.PackageVersion)."
        }
    }
    $latest = @($group.Group | Where-Object Status -eq 'Ready')
    if ($latest.Count -lt 2) { continue }
    foreach ($row in $latest) {
        $row.Status = 'DuplicateSource'
        $row.Detail = 'Multiple files in the latest build share this package identity; select a source before publishing.'
    }
}
if (-not (Get-Command Resolve-AzureDevOpsAuth -ErrorAction SilentlyContinue)) { throw 'Load the automation module before publishing.' }

$targetUri = [Uri]$TargetOrg
$targetName = if ($targetUri.Host -match '^([^.]+)\.visualstudio\.com$') { $Matches[1] } else { ($targetUri.AbsolutePath.Trim('/') -split '/')[0] }
if (-not $targetName) { throw "Cannot determine target organization from '$TargetOrg'." }
$targetProjectPart = [Uri]::EscapeDataString($TargetProject)
$targetAuth = Resolve-AzureDevOpsAuth -Collection $TargetOrg -Pat $TargetPat -Label 'target'

function Invoke-TargetApi {
    param([string]$Uri)
    $params = @{ Uri = $Uri; ErrorAction = 'Stop' }
    if ($targetAuth.Mode -eq 'Windows') { $params.UseDefaultCredentials = $true } else { $params.Headers = $targetAuth.Headers }
    Invoke-RestMethod @params
}
function Get-ResponseStatus {
    param([Exception]$ErrorException)
    $response = $ErrorException.PSObject.Properties['Response']
    if ($null -ne $response -and $null -ne $response.Value) { return [int]$response.Value.StatusCode }
    $status = $ErrorException.PSObject.Properties['StatusCode']
    if ($null -ne $status -and $null -ne $status.Value) { return [int]$status.Value }
    0
}

function Test-TargetVersion {
    param($Row, [string]$PackageName)
    if (-not $PackageName) { $PackageName = $Row.PackageName }
    $targetFeedPart = [Uri]::EscapeDataString($Row.Feed)
    $packagePart = [Uri]::EscapeDataString($PackageName)
    $versionPart = [Uri]::EscapeDataString($Row.PackageVersion)
    $versionUrl = "https://pkgs.dev.azure.com/$targetName/$targetProjectPart/_apis/packaging/feeds/$targetFeedPart/upack/packages/$packagePart/versions/$versionPart`?api-version=7.1-preview.1"
    try {
        $null = Invoke-TargetApi -Uri $versionUrl
        return $true
    } catch {
        if ((Get-ResponseStatus -ErrorException $_.Exception) -eq 404) { return $false }
        throw "Could not check target version $PackageName $($Row.PackageVersion): $($_.Exception.Message)"
    }
}

function Write-PublishPlan {
    $planDirectory = Split-Path -Parent $PlanPath
    if ($planDirectory -and -not (Test-Path -LiteralPath $planDirectory)) { New-Item -ItemType Directory -Path $planDirectory -Force | Out-Null }
    $actions = @($plan | Where-Object Status -eq 'Ready' | Sort-Object PackageName, PackageVersion, BuildId)
    if ($actions.Count) {
        $actions | Export-Csv -LiteralPath $PlanPath -NoTypeInformation -Encoding utf8
    } else {
        # Keep an empty plan as a valid CSV with the same columns.
        $columns = @('Feed', 'PackageName', 'PackageVersion', 'Product', 'SourceVersion', 'Revision', 'Format', 'FileName', 'Branch', 'BuildId', 'Artifact', 'ArtifactPath', 'Bytes', 'Status', 'Detail')
        $header = ($columns | ForEach-Object { '"' + $_ + '"' }) -join ','
        [IO.File]::WriteAllText($PlanPath, "$header`r`n", [Text.UTF8Encoding]::new($false))
    }
}

$ready = @($plan | Where-Object Status -eq 'Ready')
foreach ($feedName in @($ready | Select-Object -ExpandProperty Feed -Unique)) {
    $feedPart = [Uri]::EscapeDataString($feedName)
    $feedUrl = "https://feeds.dev.azure.com/$targetName/$targetProjectPart/_apis/packaging/feeds/$feedPart`?api-version=7.1"
    try { $feed = Invoke-TargetApi -Uri $feedUrl }
    catch { throw "Target project feed '$feedName' could not be read in '$TargetProject': $($_.Exception.Message)" }
    Write-Host "Target feed: $($feed.name) ($TargetProject)."
}

foreach ($row in $ready) {
    if (Test-TargetVersion -Row $row) {
        $row.Status = 'AlreadyPublished'
        $row.Detail = 'This package version already exists in the target feed; skipped.'
    } elseif ($row.PackageName -eq $row.Product.ToLowerInvariant() -and
        (Test-TargetVersion -Row $row -PackageName ("$($row.Product).$($row.Format)".ToLowerInvariant()))) {
        $row.Status = 'LegacyPackageNameConflict'
        $row.Detail = 'This version was already published under a format-suffixed package name. Resolve that package before publishing under the product-only name.'
    }
}
Write-PublishPlan
$ready = @($plan | Where-Object Status -eq 'Ready')
$supersededRevision = @($plan | Where-Object Status -eq 'SupersededByRevision').Count
$supersededBuild = @($plan | Where-Object Status -eq 'SupersededByBuild').Count
$alreadyPublished = @($plan | Where-Object Status -eq 'AlreadyPublished').Count
$legacyConflicts = @($plan | Where-Object Status -eq 'LegacyPackageNameConflict').Count
$blocked = @($plan | Where-Object { $_.Status -ne 'Ready' -and $_.Status -ne 'SupersededByRevision' -and $_.Status -ne 'SupersededByBuild' -and $_.Status -ne 'AlreadyPublished' })
Write-Host "Plan: $($ready.Count) upload actions; $supersededRevision older revisions; $supersededBuild older builds; $alreadyPublished already published; $legacyConflicts legacy-name conflicts; $($blocked.Count) blocked."
Write-Host "Plan CSV: $PlanPath"
if ($blocked.Count) { Write-Warning 'Resolve blocked plan rows before a complete migration.' }
if (-not $Publish) { return }
if ($blocked.Count -and -not $AllowPartial) { throw 'Publishing stopped: the plan contains blocked rows. Resolve them or use -AllowPartial to publish only ready rows.' }
if (-not $ready.Count) { Write-Host 'All selected package versions are already published or intentionally skipped.'; return }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required for Universal Package publishing.' }

$sourceBase = $SourceOrg.TrimEnd('/')
$sourceProjectPart = [Uri]::EscapeDataString($SourceProject)
$sourceAuth = Resolve-AzureDevOpsAuth -Collection $SourceOrg -Pat $SourcePat -Label 'source'
function Invoke-SourceApi {
    param([string]$Uri)
    $params = @{ Uri = $Uri; ErrorAction = 'Stop' }
    if ($sourceAuth.Mode -eq 'Windows') { $params.UseDefaultCredentials = $true } else { $params.Headers = $sourceAuth.Headers }
    Invoke-RestMethod @params
}

$workRoot = [IO.Path]::GetFullPath($WorkPath)
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$artifactCache = @{}
$publishClock = [Diagnostics.Stopwatch]::StartNew()
$publishTotal = $ready.Count
$publishDone = 0
$publishSkipped = 0
function Write-PublishStatus {
    param([object]$Item, [string]$Action = 'Progress', [switch]$Final, [switch]$Stopped)
    $processed = $publishDone + $publishSkipped
    $remaining = $publishTotal - $processed
    $elapsed = $publishClock.Elapsed
    $eta = if ($processed -gt 0 -and $remaining -gt 0) {
        [TimeSpan]::FromSeconds($elapsed.TotalSeconds * $remaining / $processed).ToString('hh\:mm\:ss')
    } elseif ($remaining -eq 0) { '00:00:00' } else { 'calculating' }
    $status = "Done $publishDone | Skipped $publishSkipped | To go $remaining | Elapsed $($elapsed.ToString('hh\:mm\:ss')) | ETA $eta"
    $label = if ($Stopped) { 'Stopped' } else { $Action }
    if ($Final) {
        Write-Progress -Id 1 -Activity 'Publishing Universal Packages' -Completed
        Write-Host "${label}: $status"
        return
    }
    $operation = if ($Item) { "${label}: $($Item.PackageName) $($Item.PackageVersion) ($($Item.FileName))" } else { $label }
    Write-Progress -Id 1 -Activity 'Publishing Universal Packages' -Status $status -CurrentOperation $operation -PercentComplete ([math]::Floor(100 * $processed / $publishTotal))
}
Write-Host "Starting publish: $publishTotal packages to process."
$publishRunCompleted = $false
try {
foreach ($row in $ready) {
    if (Test-TargetVersion -Row $row) {
        $row.Status = 'AlreadyPublished'
        $row.Detail = 'This package version appeared in the target feed before upload; skipped.'
        Write-PublishPlan
        $publishSkipped++
        Write-PublishStatus -Item $row -Action 'Skipped'
        continue
    }
    Write-PublishStatus -Item $row -Action 'Downloading'
    $artifactKey = "$($row.BuildId)`n$($row.Artifact)"
    if (-not $artifactCache.ContainsKey($artifactKey)) {
        $artifactName = [Uri]::EscapeDataString($row.Artifact)
        $artifactUrl = "$sourceBase/$sourceProjectPart/_apis/build/builds/$($row.BuildId)/artifacts?artifactName=$artifactName&api-version=7.1"
        $artifact = Invoke-SourceApi -Uri $artifactUrl
        if ($artifact.resource.type -ne 'Container' -or $artifact.resource.data -notmatch '^#/(\d+)/(.+)$') {
            throw "Build $($row.BuildId) artifact '$($row.Artifact)' is not a Container artifact."
        }
        $containerId = $Matches[1]
        $rootItem = [Uri]::EscapeDataString($Matches[2])
        $itemsUrl = "$sourceBase/_apis/resources/Containers/$containerId`?itemPath=$rootItem&isShallow=false&api-version=7.1-preview.4"
        $items = Invoke-SourceApi -Uri $itemsUrl
        $artifactCache[$artifactKey] = @($items.value | Where-Object itemType -eq 'file')
    }
    $matches = @($artifactCache[$artifactKey] | Where-Object { $_.path -eq $row.ArtifactPath })
    if ($matches.Count -ne 1 -or -not $matches[0].contentLocation) { throw "Could not resolve one source Container file download URL for build $($row.BuildId): $($row.ArtifactPath)" }
    $contentUri = [Uri]$matches[0].contentLocation
    if ($contentUri.Scheme -ne 'https' -or $contentUri.Host -ne ([Uri]$SourceOrg).Host) {
        throw "Unexpected source Container file download host for build $($row.BuildId): $($row.ArtifactPath)"
    }
    # A fresh directory prevents an interrupted older revision from entering this package.
    $packageDir = Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    $filePath = Join-Path $packageDir $row.FileName
    $partPath = "$filePath.partial"
    $download = @{ Uri = $contentUri; OutFile = $partPath; ErrorAction = 'Stop' }
    if ($sourceAuth.Mode -eq 'Windows') { $download.UseDefaultCredentials = $true } else { $download.Headers = $sourceAuth.Headers }
    try {
        Invoke-WebRequest @download | Out-Null
        if ($row.Bytes -and (Get-Item -LiteralPath $partPath).Length -ne [int64]$row.Bytes) { throw "Downloaded byte count differs from inventory for $($row.FileName)." }
        Move-Item -LiteralPath $partPath -Destination $filePath -Force
    } finally {
        if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath }
    }
    $stagedFiles = @(Get-ChildItem -LiteralPath $packageDir -File)
    if ($stagedFiles.Count -ne 1 -or $stagedFiles[0].Name -ne $row.FileName) {
        throw "Staging directory must contain only the original file: $packageDir"
    }

    if (Test-TargetVersion -Row $row) {
        $row.Status = 'AlreadyPublished'
        $row.Detail = 'This package version appeared in the target feed during download; skipped.'
        Write-PublishPlan
        Remove-Item -LiteralPath $filePath
        Remove-Item -LiteralPath $packageDir
        $publishSkipped++
        Write-PublishStatus -Item $row -Action 'Skipped'
        continue
    }

    $previousPat = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT')
    try {
        Write-PublishStatus -Item $row -Action 'Publishing'
        if ($targetAuth.Token) { $env:AZURE_DEVOPS_EXT_PAT = $targetAuth.Token }
        $publishOutput = [Collections.Generic.Queue[string]]::new()
        & az artifacts universal publish --organization $TargetOrg --project $TargetProject --scope project --feed $row.Feed --name $row.PackageName --version $row.PackageVersion --path $packageDir --description "Original build artifact: $($row.FileName)" --only-show-errors --output none 2>&1 | ForEach-Object {
            if ($publishOutput.Count -ge 8) { $null = $publishOutput.Dequeue() }
            $publishOutput.Enqueue([string]$_)
        }
        if ($LASTEXITCODE -ne 0) {
            $detail = if ($publishOutput.Count) { ': ' + ($publishOutput.ToArray() -join ' ') } else { '' }
            throw "Universal Package publish failed: $($row.PackageName) $($row.PackageVersion)$detail"
        }
    } finally {
        [Environment]::SetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT', $previousPat)
    }
    $row.Status = 'Published'
    $row.Detail = 'Published by this run.'
    Write-PublishPlan
    $publishDone++
    Write-PublishStatus -Item $row -Action 'Published'
    Remove-Item -LiteralPath $filePath
    Remove-Item -LiteralPath $packageDir
}
$publishRunCompleted = $true
} finally {
    $publishClock.Stop()
    Write-PublishStatus -Action 'Finished' -Final -Stopped:(-not $publishRunCompleted)
}
