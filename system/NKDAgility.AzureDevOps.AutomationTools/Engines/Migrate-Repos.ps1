<#
.SYNOPSIS
    Migrates Git repositories from a source Azure DevOps organization/project to
    a target organization/project, including full history, all branches and tags.

.DESCRIPTION
    For each repository:
      1. Mirror-clones the source repository (all refs) into the work path, or
         fetches updates into the existing mirror when it is already cached.
      2. Ensures the target repository exists (creates it if missing).
      3. Adds a 'target' remote to the clone (or updates its URL) if needed.
      4. Pushes the repository to the target.

    Azure DevOps rejects a single push larger than ~5 GB. To work around this,
    repositories whose size exceeds -MaxPushSizeGB (or when -ForceSegmented is
    used) are pushed in *segments*: the commit history of each branch is walked
    oldest-to-newest and intermediate commits are pushed in batches, so each
    individual push only transfers a slice of the history and stays under the
    limit. Tags and remaining refs are pushed at the end.

    Git LFS objects are NOT part of the normal Git object graph: a mirror clone
    and push only copy the small LFS *pointer* files, not the binary content
    they reference. To migrate the actual content this script runs
    'git lfs fetch --all' against the source and 'git lfs push --all' against the
    target for every repository. Because 'git lfs push --all' only uploads
    objects the target is missing, re-running the migration is also the way to
    *backfill* LFS objects into repositories that were migrated before LFS
    support was added. Requires git-lfs on PATH; if it is missing (or -SkipLfs
    is supplied) LFS transfer is skipped with a warning.

    Authentication uses Personal Access Tokens (PATs) passed as parameters. The
    source PAT needs Code (Read); the target PAT needs Code (Read & Write) and
    permission to create repositories. PATs are passed per-invocation via
    http.extraheader so they never end up in the remote URL or reflog.

.PARAMETER SourceOrg
    Source organization URL, e.g. https://dev.azure.com/contoso-source

.PARAMETER SourcePat
    Personal Access Token for the source organization (Code Read).

.PARAMETER SourceProject
    Source project name.

.PARAMETER TargetOrg
    Target organization URL, e.g. https://dev.azure.com/contoso-target

.PARAMETER TargetPat
    Personal Access Token for the target organization (Code Read & Write).

.PARAMETER TargetProject
    Target project name. Defaults to SourceProject when not supplied.

.PARAMETER RepoName
    Optional. Migrate only the named repository. Omit to migrate all repos in
    the source project.

.PARAMETER MaxPushSizeGB
    Size threshold (in GB) above which a repository is pushed in segments.
    Default: 5 (matches the Azure DevOps single-push limit).

.PARAMETER CommitBatchSize
    Number of commits per segment when pushing large repositories. Lower this if
    individual segments still exceed the push limit (e.g. repos with very large
    blobs). Default: 2000.

.PARAMETER ForceSegmented
    Always use the segmented push path, regardless of reported repository size.

.PARAMETER WorkPath
    Optional. Working directory for mirror clones. Defaults to a temp dir.

.PARAMETER KeepClones
    Keep mirror clones after migration (default: cleaned up).

.PARAMETER SkipLfs
    Skip Git LFS object transfer entirely. By default the script fetches all
    LFS objects from the source and pushes them to the target (which also
    backfills previously migrated repos). Use this to migrate refs only.

.EXAMPLE
    .\Migrate-Repos.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourcePat $srcPat -SourceProject "Payments" `
        -TargetOrg https://dev.azure.com/contoso-target -TargetPat $tgtPat -TargetProject "Payments"

.EXAMPLE
    # Preview a single large repo, forcing the segmented path with small batches.
    .\Migrate-Repos.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourcePat $srcPat -SourceProject "Payments" `
        -TargetOrg https://dev.azure.com/contoso-target -TargetPat $tgtPat `
        -RepoName "monolith" -ForceSegmented -CommitBatchSize 500 -WhatIf

.NOTES
    Requires Git 2.x on PATH; Git LFS (git-lfs) is required to migrate LFS
    objects. Run with -WhatIf first to preview. Re-running is safe: each
    segment fast-forwards the target ref and already-pushed Git objects are
    skipped, while 'git lfs push --all' only uploads LFS objects the target is
    missing, so re-running backfills LFS content for already-migrated repos.

    PATs: in a customer workspace, run Set-AutomationSecrets (from the
    NKDAgility.AzureDevOps.AutomationTools module) first and reference tokens
    as $ENV:AZDO_PAT_<ORG> in the per-migration config.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$SourceOrg,

    [Parameter(Mandatory = $true)]
    [string]$SourcePat,

    [Parameter(Mandatory = $true)]
    [string]$SourceProject,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$TargetOrg,

    [Parameter(Mandatory = $true)]
    [string]$TargetPat,

    [string]$TargetProject,

    [string]$RepoName,

    [ValidateRange(1, 100)]
    [int]$MaxPushSizeGB = 5,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$CommitBatchSize = 2000,

    [switch]$ForceSegmented,

    [string]$WorkPath,

    [switch]$KeepClones,

    [switch]$SkipLfs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $TargetProject) { $TargetProject = $SourceProject }

#region Helpers ---------------------------------------------------------------

function Get-AuthHeader {
    param([string]$Pat)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Pat")
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
}

function Get-GitExtraHeader {
    param([string]$Pat)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$Pat"))
    "AUTHORIZATION: Basic $b64"
}

function Get-OrgName {
    param([string]$OrgUrl)
    ($OrgUrl.TrimEnd('/') -split '/')[-1]
}

function Invoke-AdoApi {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = 'Get',
        [object]$Body,
        [string]$ContentType = 'application/json'
    )
    $params = @{ Uri = $Uri; Headers = $Headers; Method = $Method }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = $ContentType
    }
    Invoke-RestMethod @params
}

function Invoke-Git {
    # Runs git with a scoped auth header so PATs never touch the remote URL.
    param(
        [string]$ExtraHeader,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$GitArgs
    )
    $allArgs = @()
    if ($ExtraHeader) { $allArgs += @('-c', "http.extraheader=$ExtraHeader") }
    $allArgs += $GitArgs
    & git @allArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-GitLfs {
    # Returns $true when git-lfs is available (checked once and cached). Warns
    # once when it is missing so LFS objects are visibly skipped rather than
    # silently dropped.
    if ($script:GitLfsChecked) { return $script:GitLfsAvailable }
    $script:GitLfsChecked = $true
    & git lfs version 2>$null | Out-Null
    $script:GitLfsAvailable = ($LASTEXITCODE -eq 0)
    if (-not $script:GitLfsAvailable) {
        Write-Warning 'git-lfs was not found on PATH. LFS objects will NOT be migrated. Install Git LFS (https://git-lfs.com) and re-run to backfill.'
    }
    return $script:GitLfsAvailable
}

#endregion Helpers ------------------------------------------------------------

#region Repo operations -------------------------------------------------------

function Get-SourceRepos {
    $org = Get-OrgName -OrgUrl $SourceOrg
    $url = "https://dev.azure.com/$org/$SourceProject/_apis/git/repositories?api-version=7.1"
    $repos = (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value
    if ($RepoName) {
        $repos = $repos | Where-Object { $_.name -eq $RepoName }
    }
    # Skip disabled or empty repositories.
    $repos | Where-Object { -not $_.isDisabled }
}

function Get-TargetRepo {
    param([string]$Name)
    $org = Get-OrgName -OrgUrl $TargetOrg
    $url = "https://dev.azure.com/$org/$TargetProject/_apis/git/repositories?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value |
        Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function New-TargetRepo {
    param([string]$Name)

    $existing = Get-TargetRepo -Name $Name
    if ($existing) {
        Write-Host "    Target repo '$Name' already exists." -ForegroundColor DarkGray
        return $existing
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create target repository')) {
        return $null
    }
    $org = Get-OrgName -OrgUrl $TargetOrg
    $url = "https://dev.azure.com/$org/$TargetProject/_apis/git/repositories?api-version=7.1"
    $body = @{ name = $Name }
    Write-Host "    Creating target repo '$Name'." -ForegroundColor Green
    Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders -Method Post -Body $body
}

function Get-TargetRepoUrl {
    param([string]$Name)
    $org = Get-OrgName -OrgUrl $TargetOrg
    # URL-encode path segments so names containing spaces or other reserved
    # characters (e.g. 'DEPRECATED GF.MS.Milling.RTPM.Analytics') produce a
    # valid URL. An unescaped space makes curl/git reject the remote with
    # 'Malformed input to a URL function'.
    $projectSeg = [uri]::EscapeDataString($TargetProject)
    $nameSeg = [uri]::EscapeDataString($Name)
    "https://dev.azure.com/$org/$projectSeg/_git/$nameSeg"
}

#endregion Repo operations ----------------------------------------------------

#region Push strategies --------------------------------------------------------

function Sync-SourceMirror {
    # Clones the source as a mirror if not present, otherwise fetches updates
    # into the existing cached mirror so re-runs stay in sync. The source remote
    # is named 'source' (rather than the default 'origin') for clarity.
    param([string]$CloneDir, [string]$RemoteUrl, [string]$RemoteName = 'source')

    if (Test-Path (Join-Path $CloneDir 'HEAD')) {
        Write-Host "    Updating existing mirror (fetch)..." -ForegroundColor Green
        Push-Location $CloneDir
        try {
            # Handle mirrors previously cloned with the default 'origin' remote.
            $remotes = @(& git remote)
            if ($remotes -contains 'origin' -and $remotes -notcontains $RemoteName) {
                Invoke-Git -GitArgs @('remote', 'rename', 'origin', $RemoteName)
            }
            # Fetch only branches and tags with an explicit refspec. A --mirror
            # clone configures fetch as '+refs/*:refs/*', which would make
            # --prune delete unrelated tracking refs (e.g. refs/remotes/target/*)
            # and would also pull server-managed refs/pull/* refs. Restricting to
            # heads and tags keeps prune scoped to the source's own refs.
            Invoke-Git -ExtraHeader $script:SourceHeader -GitArgs @(
                'fetch', '--prune', $RemoteName,
                '+refs/heads/*:refs/heads/*',
                '+refs/tags/*:refs/tags/*'
            )
        }
        finally { Pop-Location }
    }
    else {
        Write-Host "    Mirror-cloning source..." -ForegroundColor Green
        if (Test-Path $CloneDir) { Remove-Item -Path $CloneDir -Recurse -Force }
        Invoke-Git -ExtraHeader $script:SourceHeader -GitArgs @('clone', '--mirror', $RemoteUrl, $CloneDir)
        # Rename the default 'origin' remote to 'source' for clarity.
        Push-Location $CloneDir
        try { Invoke-Git -GitArgs @('remote', 'rename', 'origin', $RemoteName) }
        finally { Pop-Location }
    }
}

function Sync-SourceLfs {
    # Downloads every LFS object referenced by any ref from the source into the
    # mirror's local LFS store. A mirror clone/fetch only copies LFS pointer
    # files, so without this step the target would receive pointers with no
    # backing content ('LFS objects not found' at checkout time). Failures are
    # non-fatal: they are surfaced as warnings so one repo with missing objects
    # on the source does not abort the whole migration.
    param([string]$CloneDir, [string]$RemoteName = 'source')

    if ($SkipLfs -or -not (Test-GitLfs)) { return }

    # A non-zero exit from git must be inspected via $LASTEXITCODE, not thrown.
    # Under PowerShell 7.4+ the default $PSNativeCommandUseErrorActionPreference
    # combined with $ErrorActionPreference = 'Stop' turns a non-zero native exit
    # into a terminating NativeCommandExitException, which would abort the whole
    # migration when the source is merely missing some LFS objects. Disable it
    # locally so the warning path below is reachable.
    $PSNativeCommandUseErrorActionPreference = $false

    Write-Host '    Fetching all LFS objects from source...' -ForegroundColor Green
    Push-Location $CloneDir
    try {
        & git -c "http.extraheader=$script:SourceHeader" lfs fetch --all $RemoteName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    'git lfs fetch --all' reported errors; some LFS objects may be missing on the source."
        }
    }
    finally { Pop-Location }
}

function Push-Lfs {
    # Uploads all LFS objects in the local store to the target. Run before the
    # refs are pushed so the objects always exist before a pointer that
    # references them. 'git lfs push --all' only transfers objects the target is
    # missing, which makes re-running the migration an idempotent backfill for
    # repositories that were migrated before LFS support existed.
    param([string]$CloneDir, [string]$RemoteName = 'target')

    if ($SkipLfs -or -not (Test-GitLfs)) { return }

    # See Sync-SourceLfs: keep native exit codes inspectable instead of letting
    # PowerShell 7.4+ turn them into terminating errors that abort the run.
    $PSNativeCommandUseErrorActionPreference = $false

    Write-Host '    Pushing all LFS objects to target...' -ForegroundColor Green
    Push-Location $CloneDir
    try {
        & git -c "http.extraheader=$script:TargetHeader" lfs push --all $RemoteName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    'git lfs push --all' reported errors; some LFS objects may not have been uploaded."
        }
    }
    finally { Pop-Location }
}

function Set-TargetRemote {
    # Adds the target remote if missing, otherwise refreshes its URL.
    param([string]$CloneDir, [string]$TargetUrl, [string]$RemoteName = 'target')

    Push-Location $CloneDir
    try {
        $existing = @(& git remote)
        if ($existing -contains $RemoteName) {
            Write-Host "    Target remote '$RemoteName' already exists; refreshing URL." -ForegroundColor DarkGray
            Invoke-Git -GitArgs @('remote', 'set-url', $RemoteName, $TargetUrl)
        }
        else {
            Write-Host "    Adding target remote '$RemoteName'." -ForegroundColor Green
            Invoke-Git -GitArgs @('remote', 'add', $RemoteName, $TargetUrl)
        }
    }
    finally { Pop-Location }
}

function Push-Mirror {
    # Pushes all branches and tags for repositories under the size threshold.
    # We deliberately do NOT use 'git push --mirror' because a mirror clone also
    # contains Azure DevOps server-managed refs (e.g. refs/pull/*) which the
    # target rejects. Restricting to heads and tags avoids those refs while
    # --prune still removes branches/tags on the target that no longer exist.
    param([string]$CloneDir, [string]$TargetRemote)

    Write-Host "    Pushing all branches and tags..." -ForegroundColor Green
    Push-Location $CloneDir
    try {
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs @(
            'push', '--prune', $TargetRemote,
            'refs/heads/*:refs/heads/*',
            'refs/tags/*:refs/tags/*'
        )
    }
    finally { Pop-Location }
}

function Push-BranchSegmented {
    # Pushes one branch's history to the target in commit-count segments so no
    # single push exceeds the Azure DevOps limit.
    param([string]$Branch, [string]$TargetRemote, [int]$BatchSize)

    # All commits on the branch, oldest first.
    $commits = @(& git rev-list --reverse --first-parent $Branch)
    if ($LASTEXITCODE -ne 0) { throw "git rev-list failed for branch '$Branch'" }
    $total = $commits.Count
    if ($total -eq 0) { return }

    $segment = 0
    for ($i = $BatchSize - 1; $i -lt $total; $i += $BatchSize) {
        $sha = $commits[$i]
        $segment++
        $refspec = "$sha`:refs/heads/$Branch"
        Write-Host ("      [{0}] segment {1}: pushing through commit {2} ({3}/{4})" -f $Branch, $segment, $sha.Substring(0, 8), ($i + 1), $total) -ForegroundColor DarkCyan
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs @('push', $TargetRemote, $refspec)
    }

    # Final push to advance the branch to its actual tip.
    $tipRefspec = "$Branch`:refs/heads/$Branch"
    Write-Host "      [$Branch] final: pushing branch tip" -ForegroundColor DarkCyan
    Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs @('push', $TargetRemote, $tipRefspec)
}

function Push-Segmented {
    # Segmented push path for large repositories.
    param([string]$CloneDir, [string]$TargetRemote, [int]$BatchSize)

    Push-Location $CloneDir
    try {
        $branches = @(& git for-each-ref --format='%(refname:short)' refs/heads)
        if ($LASTEXITCODE -ne 0) { throw 'git for-each-ref failed' }

        Write-Host ("    Segmented push of {0} branch(es), batch size {1} commits." -f $branches.Count, $BatchSize) -ForegroundColor Green
        foreach ($branch in $branches) {
            if (-not $branch) { continue }
            Push-BranchSegmented -Branch $branch -TargetRemote $TargetRemote -BatchSize $BatchSize
        }

        # Push all tags (typically small) once history is in place.
        Write-Host "    Pushing tags..." -ForegroundColor Green
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs @('push', $TargetRemote, '--tags')
    }
    finally { Pop-Location }
}

#endregion Push strategies -----------------------------------------------------

function New-RepoSummary {
    # Builds one summary record describing what happened to a repository. These
    # records are written to the pipeline so callers (e.g. Run-Migrate-Repos.ps1)
    # can print an end-of-run report of repos and their sizes.
    param(
        [string]$Name,
        [int64]$SizeBytes,
        [double]$SizeGB,
        [string]$Strategy,
        [string]$Status
    )
    [pscustomobject]@{
        SourceProject = $SourceProject
        Repository    = $Name
        SizeBytes     = $SizeBytes
        SizeGB        = $SizeGB
        Strategy      = $Strategy
        Status        = $Status
    }
}

function Migrate-Repo {
    param($Repo, [string]$WorkRoot, [int]$Index, [int]$Total)

    $progress = if ($Total) { "[$Index/$Total] " } else { '' }
    Write-Step "${progress}$SourceProject == Repository: $($Repo.name)"

    $sizeBytes = if ($Repo.PSObject.Properties.Name -contains 'size') { [int64]$Repo.size } else { 0 }
    $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
    $thresholdBytes = [int64]$MaxPushSizeGB * 1GB
    $useSegmented = $ForceSegmented -or ($sizeBytes -gt $thresholdBytes)
    $strategy = if ($useSegmented) { 'segmented' } else { 'mirror' }

    Write-Host ("    Reported size: {0} GB. Strategy: {1}." -f $sizeGB, $strategy) -ForegroundColor DarkGray

    $targetRepo = New-TargetRepo -Name $Repo.name
    if (-not $targetRepo -and -not $WhatIfPreference) {
        New-RepoSummary -Name $Repo.name -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Skipped (no target repo)'
        return
    }

    $targetUrl = Get-TargetRepoUrl -Name $Repo.name
    $cloneDir = Join-Path $WorkRoot ($Repo.name + '.git')

    $action = if ($useSegmented) { 'Mirror-clone and segmented push' } else { 'Mirror-clone and mirror push' }
    if (-not $PSCmdlet.ShouldProcess($Repo.name, $action)) {
        New-RepoSummary -Name $Repo.name -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'WhatIf (preview)'
        return
    }

    # Clone the source as a mirror, or update the existing cached mirror.
    Sync-SourceMirror -CloneDir $cloneDir -RemoteUrl $Repo.remoteUrl

    # Pull all LFS objects from the source into the local store so they can be
    # pushed to the target (mirror clone only copies the pointer files).
    Sync-SourceLfs -CloneDir $cloneDir -RemoteName 'source'

    # Ensure the clone has a 'target' remote pointing at the destination repo.
    Set-TargetRemote -CloneDir $cloneDir -TargetUrl $targetUrl -RemoteName 'target'

    # Upload LFS objects before the refs so pointers never precede their content.
    # Also backfills repos migrated before LFS support was added.
    Push-Lfs -CloneDir $cloneDir -RemoteName 'target'

    if ($useSegmented) {
        Push-Segmented -CloneDir $cloneDir -TargetRemote 'target' -BatchSize $CommitBatchSize
    }
    else {
        Push-Mirror -CloneDir $cloneDir -TargetRemote 'target'
    }

    Write-Host "    Done: $($Repo.name) ${progress}".TrimEnd() -ForegroundColor Green
    New-RepoSummary -Name $Repo.name -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Migrated'
}

#region Main ------------------------------------------------------------------

# Verify git is available.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found on PATH. Install Git 2.x and try again.'
}

$script:SourceHeaders = Get-AuthHeader -Pat $SourcePat
$script:TargetHeaders = Get-AuthHeader -Pat $TargetPat
$script:SourceHeader = Get-GitExtraHeader -Pat $SourcePat
$script:TargetHeader = Get-GitExtraHeader -Pat $TargetPat

# Lazily probed by Test-GitLfs on first use; cached for the rest of the run.
$script:GitLfsChecked = $false
$script:GitLfsAvailable = $false

if (-not $WorkPath) {
    $WorkPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ado-repo-migration-" + [Guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
Write-Step "Working directory: $WorkPath"

try {
    $repos = Get-SourceRepos
    if (-not $repos) {
        Write-Warning "No repositories found in source (RepoName filter: '$RepoName')."
        return
    }
    Write-Step ("Found {0} repository(ies) to process." -f @($repos).Count)

    $total = @($repos).Count
    $index = 0
    foreach ($repo in $repos) {
        $index++
        # A failure in one repository (e.g. a push rejected because the target
        # branch has diverged from the source) must not abort the whole run.
        # Surface it as a warning, record it in the summary, and continue with
        # the next repository so the operator can reconcile it afterwards.
        try {
            Migrate-Repo -Repo $repo -WorkRoot $WorkPath -Index $index -Total $total
        }
        catch {
            Write-Warning ("    Migration FAILED for '{0}': {1}" -f $repo.name, $_.Exception.Message)
            New-RepoSummary -Name $repo.name `
                -SizeBytes $(if ($repo.PSObject.Properties.Name -contains 'size') { [int64]$repo.size } else { 0 }) `
                -SizeGB $(if ($repo.PSObject.Properties.Name -contains 'size') { [math]::Round([int64]$repo.size / 1GB, 2) } else { 0 }) `
                -Strategy 'n/a' `
                -Status ("Failed: {0}" -f $_.Exception.Message)
        }
    }

    Write-Step 'Repository migration complete.'
}
finally {
    if (-not $KeepClones -and (Test-Path $WorkPath)) {
        Write-Host "Cleaning up working directory $WorkPath" -ForegroundColor DarkGray
        Remove-Item -Path $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion Main ---------------------------------------------------------------
