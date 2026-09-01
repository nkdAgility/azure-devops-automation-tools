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

    Authentication is ambient-identity first, stored token as the fallback:
    Entra by default for BOTH organizations. When the automation module is
    loaded (the binder guarantees it) the engine acquires an Entra access token
    per organization via Get-AzureDevOpsAccessToken and uses it as a Bearer
    header for both REST and git - an Entra token works anywhere a PAT does.
    Tokens are re-resolved before every repository and wiki, so the module's
    cache renews them near expiry across a long run. -SourcePat and -TargetPat
    are the fallbacks, used when Entra sign-in is unavailable or fails.
    Credentials are passed per-invocation via http.extraheader so they never
    end up in the remote URL or reflog.

.PARAMETER SourceOrg
    Source organization URL, e.g. https://dev.azure.com/contoso-source

.PARAMETER SourcePat
    Personal Access Token for the source organization (Code Read). Optional:
    Entra is the default; the PAT is only used when Entra sign-in is
    unavailable or fails. Worth supplying for unattended runs and for single
    repositories so large that one transfer outlives an Entra token.

.PARAMETER SourceProject
    Source project name.

.PARAMETER TargetOrg
    Target organization URL, e.g. https://dev.azure.com/contoso-target

.PARAMETER TargetPat
    Personal Access Token for the target organization (Code Read & Write).
    Optional: Entra is the default; the PAT is only used when Entra sign-in is
    unavailable or fails.

.PARAMETER TargetProject
    Target project name. Defaults to SourceProject when not supplied.

.PARAMETER RepoName
    Optional. Migrate only the named repository. Omit to migrate all repos in
    the source project.

.PARAMETER TargetRepoName
    Optional. The name the repository takes in the target - it is renamed in
    transit, created and pushed under this name rather than its source one.
    Omitted, the repository keeps its source name.

    This is what reconciles a migration with a GOVERNED target, where the
    destination names repositories by convention rather than by history (e.g.
    governance-as-code prefixes every repo with its hierarchy code). Without it
    the migrated repository and the governed one are two different repositories
    in the same project, and the migrated one reads as an audit exception.

    Renaming one repository requires naming it, so -TargetRepoName is only valid
    together with -RepoName; supplying it for a whole-project run is an error
    rather than a rename applied to an arbitrary repository. Migrate several
    renamed repositories as several single-repo runs (the per-migration config's
    'Runs' array is exactly this).

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

.PARAMETER SkipWiki
    Skip migrating the source project's provisioned project wiki. By default the
    wiki is migrated: a project wiki is backed by its own Git repository that is
    NOT returned by the repositories API, so it is discovered via the Wiki API
    and provisioned on the target the same way (which creates its backing repo).
    Its history is force-pushed to replace the placeholder home page that
    provisioning creates. Code wikis (published from an existing code repo) are
    migrated as ordinary repos and are not affected by this switch.

.PARAMETER SkipWikiLinkRewrite
    Skip rewriting Azure DevOps work item URLs inside the wiki. By default, when
    a project wiki is migrated its markdown is scanned for work item links of
    the form 'https://dev.azure.com/<org>/<project>/_workitems/edit/<id>'
    pointing at the source. Because the work item migration assigns NEW ids in
    the target, each source id is resolved to its target id via the target work
    items' Custom.ReflectedWorkItemId field (which records the original source
    reference), and both the org/project and the id are rewritten. Links whose
    target work item cannot be resolved (e.g. the wiki is migrated before the
    work items) are left unchanged so a later re-run can fix them. Use this
    switch to migrate the wiki verbatim without touching its links.

    Fallback PATs: in a customer workspace, run Set-AutomationSecrets (from the
    NKDAgility.AzureDevOps.AutomationTools module) first and reference tokens
    as $ENV:AZDO_PAT_<ORG> in the per-migration config. Entra is tried first
    either way.

.EXAMPLE
    # Ambient identity: Entra for both organizations, no PATs.
    .\Migrate-Repos.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourceProject "Payments" `
        -TargetOrg https://dev.azure.com/contoso-target -TargetProject "Payments" -WhatIf

.EXAMPLE
    # Explicit fallback PATs (e.g. unattended runs).
    .\Migrate-Repos.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourcePat $srcPat -SourceProject "Payments" `
        -TargetOrg https://dev.azure.com/contoso-target -TargetPat $tgtPat -TargetProject "Payments"

.EXAMPLE
    # Rename in transit so the repo lands under the target's governed name.
    .\Migrate-Repos.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourceProject "Payments" `
        -TargetOrg https://dev.azure.com/contoso-target -TargetProject "Platform" `
        -RepoName "PaymentsAllInOne" -TargetRepoName "PAY-PaymentsAllInOne" -WhatIf

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
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$SourceOrg,

    [string]$SourcePat,

    [Parameter(Mandatory = $true)]
    [string]$SourceProject,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$TargetOrg,

    [string]$TargetPat,

    [string]$TargetProject,

    [string]$RepoName,

    [string]$TargetRepoName,

    [ValidateRange(1, 100)]
    [int]$MaxPushSizeGB = 5,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$CommitBatchSize = 2000,

    [switch]$ForceSegmented,

    [string]$WorkPath,

    [switch]$KeepClones,

    [switch]$SkipLfs,

    [switch]$SkipWiki,

    [switch]$SkipWikiLinkRewrite
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $TargetProject) { $TargetProject = $SourceProject }

# A rename applies to ONE named repository. Without -RepoName the run covers the
# whole project, and there is no defensible repository to apply the new name to -
# so this is refused up front rather than renaming an arbitrary one.
if ($TargetRepoName -and -not $RepoName) {
    throw "-TargetRepoName renames a single repository, so it requires -RepoName. For several renames, use one single-repo run each."
}

function Resolve-TargetRepoName {
    # The name a source repository takes in the target: the requested one, or its
    # own when no rename was asked for.
    param([string]$Name)
    if ($TargetRepoName) { return $TargetRepoName }
    $Name
}

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

function Initialize-SourceAuth {
    # Ambient identity first: an Entra access token works anywhere a PAT does (Bearer
    # for REST, http.extraheader for git), so Entra is the default and -SourcePat only
    # the fallback. Called before every repository and wiki, not just once: the module
    # caches the token and renews it shortly before expiry, so re-resolving per repo
    # keeps a long run authenticated. Announces the mode once - never the credential.
    $token = $null
    $entraError = $null
    if (Get-Command Get-AzureDevOpsAccessToken -ErrorAction SilentlyContinue) {
        try { $token = Get-AzureDevOpsAccessToken -Collection $SourceOrg }
        catch { $entraError = $_.Exception.Message }
    }
    else {
        $entraError = 'the NKDAgility.AzureDevOps.AutomationTools module is not loaded'
    }

    if ($token) {
        $script:SourceHeaders = @{ Authorization = 'Bearer ' + $token }
        $script:SourceHeader = "AUTHORIZATION: Bearer $token"
        if ($script:SourceAuthMode -ne 'Entra') {
            Write-Host '==> Source auth: Entra.' -ForegroundColor DarkGray
            $script:SourceAuthMode = 'Entra'
        }
        return
    }

    if ($SourcePat) {
        $script:SourceHeaders = Get-AuthHeader -Pat $SourcePat
        $script:SourceHeader = Get-GitExtraHeader -Pat $SourcePat
        if ($script:SourceAuthMode -ne 'PAT') {
            Write-Warning ("Entra sign-in unavailable ({0}); falling back to the source PAT." -f $entraError)
            $script:SourceAuthMode = 'PAT'
        }
        return
    }

    throw ("No source credential available: Entra sign-in failed ({0}) and no -SourcePat was supplied. Sign in to Entra, or add the source PAT to secrets\secrets.json." -f $entraError)
}

function Initialize-TargetAuth {
    # Same ambient-first resolution as Initialize-SourceAuth, for the target
    # organization. -TargetPat is the fallback.
    $token = $null
    $entraError = $null
    if (Get-Command Get-AzureDevOpsAccessToken -ErrorAction SilentlyContinue) {
        try { $token = Get-AzureDevOpsAccessToken -Collection $TargetOrg }
        catch { $entraError = $_.Exception.Message }
    }
    else {
        $entraError = 'the NKDAgility.AzureDevOps.AutomationTools module is not loaded'
    }

    if ($token) {
        $script:TargetHeaders = @{ Authorization = 'Bearer ' + $token }
        $script:TargetHeader = "AUTHORIZATION: Bearer $token"
        if ($script:TargetAuthMode -ne 'Entra') {
            Write-Host '==> Target auth: Entra.' -ForegroundColor DarkGray
            $script:TargetAuthMode = 'Entra'
        }
        return
    }

    if ($TargetPat) {
        $script:TargetHeaders = Get-AuthHeader -Pat $TargetPat
        $script:TargetHeader = Get-GitExtraHeader -Pat $TargetPat
        if ($script:TargetAuthMode -ne 'PAT') {
            Write-Warning ("Entra sign-in unavailable ({0}); falling back to the target PAT." -f $entraError)
            $script:TargetAuthMode = 'PAT'
        }
        return
    }

    throw ("No target credential available: Entra sign-in failed ({0}) and no -TargetPat was supplied. Sign in to Entra, or add the target PAT to secrets\secrets.json." -f $entraError)
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

function Get-SourceWikis {
    # Project wikis are backed by a dedicated Git repository that the git
    # repositories API does NOT list, so they are discovered here via the Wiki
    # API. Only 'projectWiki' entries have their own repo to migrate; a
    # 'codeWiki' is published from an existing code repo that is already
    # migrated as an ordinary repository.
    $org = Get-OrgName -OrgUrl $SourceOrg
    $url = "https://dev.azure.com/$org/$SourceProject/_apis/wiki/wikis?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value |
        Where-Object { $_.type -eq 'projectWiki' }
}

function Get-ProjectId {
    param([string]$OrgUrl, [hashtable]$Headers, [string]$Project)
    $org = Get-OrgName -OrgUrl $OrgUrl
    $seg = [uri]::EscapeDataString($Project)
    $url = "https://dev.azure.com/$org/_apis/projects/$seg`?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $Headers).id
}

function New-TargetWiki {
    # Ensures a project wiki exists in the target project, provisioning its
    # backing Git repository. Returns the wiki object (with remoteUrl) so its
    # repo can be pushed to. Idempotent: an existing project wiki is reused.
    $org = Get-OrgName -OrgUrl $TargetOrg
    $listUrl = "https://dev.azure.com/$org/$TargetProject/_apis/wiki/wikis?api-version=7.1"
    $existing = (Invoke-AdoApi -Uri $listUrl -Headers $script:TargetHeaders).value |
        Where-Object { $_.type -eq 'projectWiki' } | Select-Object -First 1
    if ($existing) {
        Write-Host "    Target project wiki already exists." -ForegroundColor DarkGray
        return $existing
    }
    if (-not $PSCmdlet.ShouldProcess("$TargetProject wiki", 'Create target project wiki')) {
        return $null
    }
    $projectId = Get-ProjectId -OrgUrl $TargetOrg -Headers $script:TargetHeaders -Project $TargetProject
    $createUrl = "https://dev.azure.com/$org/_apis/wiki/wikis?api-version=7.1"
    $body = @{ type = 'projectWiki'; name = "$TargetProject.wiki"; projectId = $projectId }
    Write-Host "    Creating target project wiki." -ForegroundColor Green
    Invoke-AdoApi -Uri $createUrl -Headers $script:TargetHeaders -Method Post -Body $body
}

function Get-WikiGitUrl {
    # Builds the git-cloneable URL for a project wiki's backing repository. The
    # Wiki API's remoteUrl is a '_wiki/wikis/<id>' REST endpoint that git cannot
    # clone; the backing repo lives at '_git/<wikiName>' instead. Path segments
    # are URL-encoded so wiki names containing '.' or spaces stay valid.
    param([string]$OrgUrl, [string]$Project, [string]$WikiName)
    $org = Get-OrgName -OrgUrl $OrgUrl
    $projectSeg = [uri]::EscapeDataString($Project)
    $nameSeg = [uri]::EscapeDataString($WikiName)
    "https://dev.azure.com/$org/$projectSeg/_git/$nameSeg"
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

function Invoke-GitWithHeartbeat {
    <# Runs git and prints an 'still working' line every few seconds while it does.

       Some git steps are silent for MINUTES - 'lfs push --all --dry-run' walks every
       object in every ref - and a console whose last line is a completed action reads
       as a lock-up, not as work in progress. Nothing here changes what git does; it
       guarantees the console never goes quiet, and says how long the step has taken.

       stdout is captured to a file and returned line by line so callers can still parse
       it; stderr goes to its own file and is surfaced only when git fails, so progress
       chatter cannot corrupt the parse. #>
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$Activity = 'git',
        [int]$HeartbeatSeconds = 15
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $started = Get-Date

    try {
        $process = Start-Process -FilePath 'git' -ArgumentList $GitArgs `
            -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $lastBeat = $started
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            $now = Get-Date
            if (($now - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
                $lastBeat = $now
                $elapsed = $now - $started
                # CPU time is the evidence that it is working rather than blocked -
                # worth showing, because 'it has used 743 seconds of CPU' answers the
                # 'is this hung?' question outright.
                $cpu = try { [math]::Round($process.TotalProcessorTime.TotalSeconds) } catch { $null }
                $cpuText = if ($null -ne $cpu) { ", {0}s CPU" -f $cpu } else { '' }
                Write-Host ("      still working: {0} - {1:mm\:ss} elapsed{2}" -f $Activity, $elapsed, $cpuText) -ForegroundColor DarkGray
            }
        }
        $process.WaitForExit()

        $script:LastHeartbeatExitCode = $process.ExitCode
        $script:LastHeartbeatDuration = (Get-Date) - $started
        $script:LastHeartbeatStdErr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        return @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PendingLfsCount {
    # Returns how many LFS objects the target is still missing, using a dry-run
    # push that negotiates with the target's LFS store but transfers nothing.
    # 'git lfs push --all --dry-run' prints one 'push <oid> => <path>' line per
    # object that WOULD be uploaded (i.e. that the target lacks); objects the
    # target already has are omitted. This lets the migration skip the fetch and
    # push entirely on re-runs where nothing is new, instead of re-scanning and
    # re-negotiating every object each time.
    param([string]$CloneDir, [string]$RemoteName = 'target')

    $PSNativeCommandUseErrorActionPreference = $false

    # Announced BEFORE it starts, and with the reason it is slow: this walks every
    # object in every ref, which on a large mirror is minutes of silent CPU. A console
    # left showing the previous, completed step reads as a lock-up.
    Write-Host '    Checking which LFS objects the target is missing (walks every ref - minutes on a large repo)...' -ForegroundColor Green

    $lines = Invoke-GitWithHeartbeat -WorkingDirectory $CloneDir -Activity 'LFS scan' -GitArgs @(
        '-c', "http.extraheader=$script:TargetHeader", 'lfs', 'push', '--all', '--dry-run', $RemoteName
    )

    if ($script:LastHeartbeatExitCode -ne 0) {
        # If the dry-run itself fails, fall back to attempting the transfer.
        Write-Host '      LFS check could not complete; assuming objects need transferring.' -ForegroundColor DarkYellow
        return -1
    }

    $count = @($lines | Where-Object { $_ -match '^\s*push\s' }).Count
    Write-Host ("      LFS check finished in {0:mm\:ss}." -f $script:LastHeartbeatDuration) -ForegroundColor DarkGray
    return $count
}

function Push-Lfs {
    # Transfers only the LFS objects the target is missing. First a dry-run
    # counts the objects the target lacks; when none are pending the fetch and
    # push are skipped so re-runs don't re-download from the source or
    # re-negotiate every object with the target. When some are pending, the
    # objects are fetched from the source into the local store and pushed to the
    # target. Run before the refs are pushed so the objects always exist before
    # a pointer that references them. This keeps re-runs an idempotent backfill.
    param(
        [string]$CloneDir,
        [string]$SourceRemote = 'source',
        [string]$TargetRemote = 'target'
    )

    if ($SkipLfs -or -not (Test-GitLfs)) { return }

    # See Sync-SourceLfs: keep native exit codes inspectable instead of letting
    # PowerShell 7.4+ turn them into terminating errors that abort the run.
    $PSNativeCommandUseErrorActionPreference = $false

    $pending = Get-PendingLfsCount -CloneDir $CloneDir -RemoteName $TargetRemote
    if ($pending -eq 0) {
        Write-Host '    All LFS objects already present on target; skipping LFS transfer.' -ForegroundColor DarkGray
        return
    }
    if ($pending -gt 0) {
        Write-Host ("    {0} LFS object(s) missing on target." -f $pending) -ForegroundColor DarkGray
    }

    # Fetch (only) the objects needed from the source into the local store.
    Sync-SourceLfs -CloneDir $CloneDir -RemoteName $SourceRemote

    Write-Host '    Pushing missing LFS objects to target...' -ForegroundColor Green
    Push-Location $CloneDir
    try {
        & git -c "http.extraheader=$script:TargetHeader" lfs push --all $TargetRemote
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

        # Azure DevOps advertises LFS locking, so git-lfs prints a
        # "Locking support detected on remote ... Consider enabling it with
        # git config lfs.<url>/info/lfs.locksverify true" hint on every push.
        # Set the flag explicitly (once) so the hint is not repeated for every
        # LFS push/segment. 'true' keeps lock verification enabled; the value is
        # scoped to this clone only.
        Invoke-Git -GitArgs @('config', 'lfs.locksverify', 'true')
    }
    finally { Pop-Location }
}

function Push-Mirror {
    # Pushes all branches and tags for repositories under the size threshold.
    # We deliberately do NOT use 'git push --mirror' because a mirror clone also
    # contains Azure DevOps server-managed refs (e.g. refs/pull/*) which the
    # target rejects. Restricting to heads and tags avoids those refs while
    # --prune still removes branches/tags on the target that no longer exist.
    #
    # -Force is used for provisioned targets whose history diverges from the
    # source (e.g. a freshly created project wiki already has a placeholder
    # home-page commit on wikiMaster), where a fast-forward-only push would be
    # rejected.
    param([string]$CloneDir, [string]$TargetRemote, [switch]$Force)

    Write-Host "    Pushing all branches and tags..." -ForegroundColor Green
    Push-Location $CloneDir
    try {
        $pushArgs = @('push', '--prune', $TargetRemote,
            'refs/heads/*:refs/heads/*',
            'refs/tags/*:refs/tags/*')
        if ($Force) { $pushArgs = @('push', '--force') + $pushArgs[1..($pushArgs.Count - 1)] }
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs $pushArgs
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
        [string]$Status,
        [string]$TargetName
    )
    [pscustomobject]@{
        SourceProject    = $SourceProject
        Repository       = $Name
        # Always populated, so the summary records where every repository landed,
        # not only the renamed ones.
        TargetRepository = if ($TargetName) { $TargetName } else { $Name }
        SizeBytes        = $SizeBytes
        SizeGB           = $SizeGB
        Strategy         = $Strategy
        Status           = $Status
    }
}

function Migrate-Repo {
    param($Repo, [string]$WorkRoot, [int]$Index, [int]$Total)

    $progress = if ($Total) { "[$Index/$Total] " } else { '' }
    $targetName = Resolve-TargetRepoName -Name $Repo.name
    $label = if ($targetName -cne $Repo.name) { "$($Repo.name) -> $targetName" } else { $Repo.name }
    Write-Step "${progress}$SourceProject == Repository: $label"

    # Re-resolve both credentials so an Entra token nearing expiry is renewed
    # before this repository's REST calls and git transfers start.
    Initialize-SourceAuth
    Initialize-TargetAuth

    $sizeBytes = if ($Repo.PSObject.Properties.Name -contains 'size') { [int64]$Repo.size } else { 0 }
    $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
    $thresholdBytes = [int64]$MaxPushSizeGB * 1GB
    $useSegmented = $ForceSegmented -or ($sizeBytes -gt $thresholdBytes)
    $strategy = if ($useSegmented) { 'segmented' } else { 'mirror' }

    Write-Host ("    Reported size: {0} GB. Strategy: {1}." -f $sizeGB, $strategy) -ForegroundColor DarkGray

    $targetRepo = New-TargetRepo -Name $targetName
    if (-not $targetRepo -and -not $WhatIfPreference) {
        New-RepoSummary -Name $Repo.name -TargetName $targetName -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Skipped (no target repo)'
        return
    }

    $targetUrl = Get-TargetRepoUrl -Name $targetName
    # The clone is a mirror of the SOURCE, so it stays keyed on the source name: a
    # rename must not orphan the cached mirror and force a re-clone.
    $cloneDir = Join-Path $WorkRoot ($Repo.name + '.git')

    $action = if ($useSegmented) { 'Mirror-clone and segmented push' } else { 'Mirror-clone and mirror push' }
    if ($targetName -cne $Repo.name) { $action += " as '$targetName'" }
    if (-not $PSCmdlet.ShouldProcess($Repo.name, $action)) {
        New-RepoSummary -Name $Repo.name -TargetName $targetName -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'WhatIf (preview)'
        return
    }

    # Clone the source as a mirror, or update the existing cached mirror.
    Sync-SourceMirror -CloneDir $cloneDir -RemoteUrl $Repo.remoteUrl

    # Ensure the clone has a 'target' remote pointing at the destination repo.
    # Done before the LFS step so it can query what the target is missing.
    Set-TargetRemote -CloneDir $cloneDir -TargetUrl $targetUrl -RemoteName 'target'

    # Transfer only the LFS objects the target is missing (fetched from source
    # on demand) before the refs are pushed so pointers never precede their
    # content. Also backfills repos migrated before LFS support was added.
    Push-Lfs -CloneDir $cloneDir -SourceRemote 'source' -TargetRemote 'target'

    if ($useSegmented) {
        Push-Segmented -CloneDir $cloneDir -TargetRemote 'target' -BatchSize $CommitBatchSize
    }
    else {
        Push-Mirror -CloneDir $cloneDir -TargetRemote 'target'
    }

    Write-Host "    Done: $label ${progress}".TrimEnd() -ForegroundColor Green
    New-RepoSummary -Name $Repo.name -TargetName $targetName -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Migrated'
}

function Migrate-Wiki {
    # Migrates a provisioned project wiki. The wiki's backing repo is cloned
    # from the source and pushed into the target wiki repo, which is provisioned
    # first via the Wiki API. The push is forced because provisioning seeds the
    # target wiki with a placeholder home page whose history diverges from the
    # source's.
    param($Wiki, [string]$WorkRoot, [int]$Index, [int]$Total)

    $progress = if ($Total) { "[$Index/$Total] " } else { '' }
    Write-Step "${progress}$SourceProject == Wiki: $($Wiki.name)"

    # Re-resolve both credentials so an Entra token nearing expiry is renewed
    # before this wiki's REST calls and git transfers start.
    Initialize-SourceAuth
    Initialize-TargetAuth

    $targetWiki = New-TargetWiki
    if (-not $targetWiki -and -not $WhatIfPreference) {
        New-RepoSummary -Name $Wiki.name -SizeBytes 0 -SizeGB 0 -Strategy 'wiki' -Status 'Skipped (no target wiki)'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Wiki.name, 'Mirror-clone and push wiki')) {
        New-RepoSummary -Name $Wiki.name -SizeBytes 0 -SizeGB 0 -Strategy 'wiki' -Status 'WhatIf (preview)'
        return
    }

    # The Wiki API's remoteUrl points at the '_wiki/wikis/<id>' REST endpoint,
    # which is NOT a git-cloneable URL (git clone fails with 'not valid: is this
    # a git repository?'). A project wiki's backing repo is instead cloned from
    # '_git/<wikiName>', so build that URL from the org/project/name for both
    # sides. Names are URL-encoded so '.'/space-containing wiki names stay valid.
    $sourceUrl = Get-WikiGitUrl -OrgUrl $SourceOrg -Project $SourceProject -WikiName $Wiki.name
    $targetUrl = Get-WikiGitUrl -OrgUrl $TargetOrg -Project $TargetProject -WikiName $targetWiki.name
    $cloneDir = Join-Path $WorkRoot ($Wiki.name + '.git')

    Sync-SourceMirror -CloneDir $cloneDir -RemoteUrl $sourceUrl
    Set-TargetRemote -CloneDir $cloneDir -TargetUrl $targetUrl -RemoteName 'target'
    Push-Lfs -CloneDir $cloneDir -SourceRemote 'source' -TargetRemote 'target'

    # Repoint work item links in the wiki content to the target work items
    # before pushing, unless suppressed. Delegated to the standalone
    # Update-WikiWorkItemLinks.ps1 (run with -Commit here; without -Commit it
    # previews only, which is how the rewrite can be validated before a push).
    if (-not $SkipWikiLinkRewrite) {
        $linkScript = Join-Path $PSScriptRoot 'Update-WikiWorkItemLinks.ps1'
        # The link rewriter resolves its own credential Entra-first; the target
        # PAT is only forwarded when this run actually has one to fall back on.
        $linkArgs = @{
            SourceOrg     = $SourceOrg
            SourceProject = $SourceProject
            TargetOrg     = $TargetOrg
            TargetProject = $TargetProject
            CloneDir      = $cloneDir
            Branch        = 'wikiMaster'
            Commit        = $true
        }
        if ($TargetPat) { $linkArgs.TargetPat = $TargetPat }
        & $linkScript @linkArgs | Out-Null
    }

    Push-Mirror -CloneDir $cloneDir -TargetRemote 'target' -Force

    Write-Host "    Done: $($Wiki.name) ${progress}".TrimEnd() -ForegroundColor Green
    New-RepoSummary -Name $Wiki.name -SizeBytes 0 -SizeGB 0 -Strategy 'wiki' -Status 'Migrated'
}

#region Main ------------------------------------------------------------------

# Verify git is available.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found on PATH. Install Git 2.x and try again.'
}

# Ambient-first credential resolution: Entra then the -SourcePat/-TargetPat
# fallbacks, renewed per repository and wiki (see Initialize-SourceAuth).
$script:SourceAuthMode = $null
$script:TargetAuthMode = $null
Initialize-SourceAuth
Initialize-TargetAuth

# Lazily probed by Test-GitLfs on first use; cached for the rest of the run.
$script:GitLfsChecked = $false
$script:GitLfsAvailable = $false

if (-not $WorkPath) {
    $WorkPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ado-repo-migration-" + [Guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
Write-Step "Working directory: $WorkPath"

try {
    # Migrate the project wiki first so its content is in place before the
    # (typically longer) repository transfers run.
    if (-not $SkipWiki) {
        $wikis = @(Get-SourceWikis)
        if (-not $wikis) {
            Write-Warning 'No project wiki found in source; nothing to migrate (use -SkipWiki to suppress this warning).'
        }
        else {
            Write-Step ("Found {0} project wiki(s) to process." -f $wikis.Count)
            $wikiTotal = $wikis.Count
            $wikiIndex = 0
            foreach ($wiki in $wikis) {
                $wikiIndex++
                # As with repositories, a single wiki failure must not abort the
                # run; surface it and continue.
                try {
                    Migrate-Wiki -Wiki $wiki -WorkRoot $WorkPath -Index $wikiIndex -Total $wikiTotal
                }
                catch {
                    Write-Warning ("    Wiki migration FAILED for '{0}': {1}" -f $wiki.name, $_.Exception.Message)
                    New-RepoSummary -Name $wiki.name -SizeBytes 0 -SizeGB 0 -Strategy 'wiki' `
                        -Status ("Failed: {0}" -f $_.Exception.Message)
                }
            }
        }
    }

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
            New-RepoSummary -Name $repo.name -TargetName (Resolve-TargetRepoName -Name $repo.name) `
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
