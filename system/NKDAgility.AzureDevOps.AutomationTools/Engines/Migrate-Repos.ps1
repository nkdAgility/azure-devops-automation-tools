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

.PARAMETER ForceDivergedBranches
    Overwrite target branches that have diverged from the source, so they match the
    source again. Off by default.

    Divergence here does not mean somebody edited the target. It means the branch was
    REWRITTEN at the source - rebased, amended or force-pushed - after an earlier
    migration run copied it. The target then holds commits the source has discarded,
    while missing the ones that replaced them. Seen on this engagement: a target branch
    one orphaned commit ahead and 59 real commits behind.

    Without this, such a branch is reported and skipped, and never migrates - which is
    the right default for a repository people work in, and the wrong one for a migration
    target where the source is the truth and the target is a copy. With it, the branch is
    force-updated to the source, and every commit that only existed on the target is
    listed first so there is a record of exactly what was overwritten.

    Do not use it against a target anyone actually commits to.

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

    COMMIT MENTION LINKING, AND AN UNDOCUMENTED DEPENDENCY.
    Azure DevOps creates every repository with 'Commit mention linking' and
    'Commit mention work item resolution' enabled, and a migration pushes the
    entire history in one operation - so every historical '#1234' in every commit
    message is processed as a new mention. One migration created links across
    6,800 work items organisation-wide before this was handled. Both options are
    therefore turned off before anything is pushed and restored afterwards, in a
    finally, so an interrupted run does not leave them changed.

    Microsoft documents those toggles as web-portal only; there is no supported
    REST or az CLI equivalent. This script uses the INTERNAL endpoint the settings
    page itself calls - legacy '_api/_versioncontrol/...' with '__v=5', not
    versioned REST - which MAY CHANGE OR BE REMOVED WITHOUT NOTICE. Its body is
    double-encoded, and a wrong shape returns HTTP 200 while doing nothing, so
    every write is verified by re-reading the option. A mismatch is a hard failure
    that refuses the push: if that endpoint changes, migrations stop rather than
    silently repeating the incident.
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

    [switch]$SkipWikiLinkRewrite,

    [switch]$ForceDivergedBranches
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

function Get-CollectionBase {
    # The organisation URL IS the base - nothing needs rebuilding.
    #
    #   Azure DevOps Services   https://dev.azure.com/<org>
    #   Azure DevOps Server     https://<host>/<collection>   (or .../tfs/<collection>)
    #
    # Both address REST as <base>/_apis/..., the internal endpoints as
    # <base>/<project>/_api/... and repositories as <base>/<project>/_git/<repo>, so
    # passing the URL straight through serves either.
    #
    # This used to take the LAST PATH SEGMENT and reassemble it against a hardcoded
    # https://dev.azure.com/. For a cloud organisation that was an expensive no-op; for
    # an on-premises collection it silently addressed a same-named PUBLIC organisation
    # instead of the customer's server - the worst kind of failure, because it succeeds
    # against the wrong system rather than failing against the right one.
    param([string]$OrgUrl)
    $OrgUrl.TrimEnd('/')
}

function Initialize-SourceAuth {
    # Credential resolution lives in the module (Resolve-AzureDevOpsAuth) so all six
    # engines answer "which credential here" identically and cannot drift: a supplied
    # PAT wins, an on-premises host uses Windows integrated auth, the hosted service
    # uses Entra. What stays here is what is genuinely per-engine - announcing the mode
    # ONCE, and holding the resolved credential in the two shapes this engine consumes
    # (a header set for REST, a header string for git).
    #
    # Called before every repository and wiki rather than once: the module caches the
    # Entra token and renews it near expiry, so re-resolving per repo keeps a long run
    # authenticated. Never announces the credential itself.
    $auth = Resolve-AzureDevOpsAuth -Collection $SourceOrg -Pat $SourcePat -Label 'source'
    if ($script:SourceAuthMode -ne $auth.Mode) {
        Write-Host "==> Source auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:SourceAuthMode = $auth.Mode
    }
    $script:SourceHeaders = $auth.Headers
    $script:SourceHeader = $auth.GitHeader
}

function Initialize-TargetAuth {
    # Same resolution as Initialize-SourceAuth, for the target organization.
    $auth = Resolve-AzureDevOpsAuth -Collection $TargetOrg -Pat $TargetPat -Label 'target'
    if ($script:TargetAuthMode -ne $auth.Mode) {
        Write-Host "==> Target auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:TargetAuthMode = $auth.Mode
    }
    $script:TargetHeaders = $auth.Headers
    $script:TargetHeader = $auth.GitHeader
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
    # An empty header set is how Windows integrated auth is expressed: there is no
    # credential to attach, so ask the stack to negotiate one. Without this the request
    # goes out anonymous and an on-premises collection answers 401.
    if (-not $Headers -or $Headers.Count -eq 0) {
        $params.Remove('Headers')
        $params.UseDefaultCredentials = $true
    }
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
    $allArgs += Get-AzureDevOpsGitAuthArgs -GitHeader $ExtraHeader
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
    $base = Get-CollectionBase -OrgUrl $SourceOrg
    $url = "$base/$SourceProject/_apis/git/repositories?api-version=7.1"
    $repos = (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value
    if ($RepoName) {
        $repos = $repos | Where-Object { $_.name -eq $RepoName }
    }
    # Skip disabled or empty repositories.
    $repos | Where-Object { -not $_.isDisabled }
}

function Get-TargetRepo {
    param([string]$Name)
    $base = Get-CollectionBase -OrgUrl $TargetOrg
    $url = "$base/$TargetProject/_apis/git/repositories?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value |
        Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Get-SourceWikis {
    # Project wikis are backed by a dedicated Git repository that the git
    # repositories API does NOT list, so they are discovered here via the Wiki
    # API. Only 'projectWiki' entries have their own repo to migrate; a
    # 'codeWiki' is published from an existing code repo that is already
    # migrated as an ordinary repository.
    $base = Get-CollectionBase -OrgUrl $SourceOrg
    $url = "$base/$SourceProject/_apis/wiki/wikis?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value |
        Where-Object { $_.type -eq 'projectWiki' }
}

function Get-ProjectId {
    param([string]$OrgUrl, [hashtable]$Headers, [string]$Project)
    $base = Get-CollectionBase -OrgUrl $OrgUrl
    $seg = [uri]::EscapeDataString($Project)
    $url = "$base/_apis/projects/$seg`?api-version=7.1"
    (Invoke-AdoApi -Uri $url -Headers $Headers).id
}

function New-TargetWiki {
    # Ensures a project wiki exists in the target project, provisioning its
    # backing Git repository. Returns the wiki object (with remoteUrl) so its
    # repo can be pushed to. Idempotent: an existing project wiki is reused.
    $base = Get-CollectionBase -OrgUrl $TargetOrg
    $listUrl = "$base/$TargetProject/_apis/wiki/wikis?api-version=7.1"
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
    $createUrl = "$base/_apis/wiki/wikis?api-version=7.1"
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
    $base = Get-CollectionBase -OrgUrl $OrgUrl
    $projectSeg = [uri]::EscapeDataString($Project)
    $nameSeg = [uri]::EscapeDataString($WikiName)
    "$base/$projectSeg/_git/$nameSeg"
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
    $base = Get-CollectionBase -OrgUrl $TargetOrg
    $url = "$base/$TargetProject/_apis/git/repositories?api-version=7.1"
    $body = @{ name = $Name }
    Write-Host "    Creating target repo '$Name'." -ForegroundColor Green
    Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders -Method Post -Body $body
}

#region Repository options (UNDOCUMENTED API) ---------------------------------
# Azure DevOps creates every repository with 'Commit mention linking' and 'Commit
# mention work item resolution' ON. Pushing a migration then makes the server read
# EVERY commit message in the entire history as if it were a new mention: one
# migration on this engagement created links across 6,800 work items, organisation
# wide, because work item ids are unique per organisation rather than per project.
# The settings must therefore be off for the push and restored afterwards.
#
# ==> THESE ENDPOINTS ARE NOT DOCUMENTED BY MICROSOFT. <==
#
# There is no supported REST or az CLI surface for these two toggles: the product
# documents them as web-portal only. What is used below is the internal endpoint
# the settings page itself calls, identified by watching that page:
#
#   GET  {org}/{projectId}/_api/_versioncontrol/RepositoryOptions?__v=5&repositoryId={id}
#   POST {org}/{projectId}/_api/_versioncontrol/UpdateRepositoryOption?__v=5&repositoryId={id}
#
# It is legacy WebAccess ('_api', '__v=5', types named ...WebAccess.VersionControl),
# not versioned REST ('_apis', 'api-version='), so Microsoft may change or remove it
# without notice or deprecation. Two observed quirks make that dangerous:
#
#   * The body is DOUBLE-ENCODED - 'option' is a JSON *string*, not an object.
#   * A wrong body shape returns HTTP 200 and changes nothing.
#
# So the status code is worthless as proof. Every write is verified by RE-READING
# the option, and a mismatch is a hard failure that stops the push. If Microsoft
# changes this endpoint the migration must stop, never quietly repeat the incident.

function Get-RepositoryOption {
    # All options for a repository, as an ordered hashtable of key -> value.
    param([string]$RepoId)

    $base = Get-CollectionBase -OrgUrl $TargetOrg
    if (-not $script:TargetProjectId) {
        $script:TargetProjectId = Get-ProjectId -OrgUrl $TargetOrg -Headers $script:TargetHeaders -Project $TargetProject
    }
    $url = "$base/$($script:TargetProjectId)/_api/_versioncontrol/RepositoryOptions?__v=5&repositoryId=$RepoId"
    $response = Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders

    $options = [ordered]@{}
    foreach ($entry in @($response.__wrappedArray)) {
        if ($entry.key) { $options[[string]$entry.key] = $entry.value }
    }
    return $options
}

function Set-RepositoryOption {
    <# Sets one repository option and PROVES it took.

       The endpoint answers 200 for a body it does not understand, so the response is
       ignored entirely: the option is read back and compared. Anything else - a
       changed contract, a permissions problem, a silent no-op - surfaces here as a
       throw rather than as a migration that pushes with mentions still live. #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][bool]$Value
    )

    $base = Get-CollectionBase -OrgUrl $TargetOrg
    if (-not $script:TargetProjectId) {
        $script:TargetProjectId = Get-ProjectId -OrgUrl $TargetOrg -Headers $script:TargetHeaders -Project $TargetProject
    }
    $url = "$base/$($script:TargetProjectId)/_api/_versioncontrol/UpdateRepositoryOption?__v=5&repositoryId=$RepoId"

    # Double-encoded on purpose: 'option' is a JSON STRING. An object here is
    # accepted with a 200 and silently ignored.
    #
    # [ordered] matters: a plain hashtable serialises its keys in an arbitrary order
    # that varies between runs, and a request body to an undocumented endpoint should
    # be byte-for-byte reproducible when someone has to debug it against a capture.
    $inner = ([ordered]@{ key = $Key; value = $Value } | ConvertTo-Json -Compress)
    $body = ([ordered]@{ option = $inner } | ConvertTo-Json -Compress)

    try {
        Invoke-RestMethod -Uri $url -Headers $script:TargetHeaders -Method Post `
            -Body $body -ContentType 'application/json' | Out-Null
    }
    catch {
        throw "Could not set repository option '$Key' (this endpoint is undocumented and may have changed): $($_.Exception.Message)"
    }

    # Reads can lag a write briefly, so give it a couple of attempts before failing.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Start-Sleep -Milliseconds ($attempt * 400)
        $current = Get-RepositoryOption -RepoId $RepoId
        if ($current.Contains($Key) -and [bool]$current[$Key] -eq $Value) { return }
    }

    throw ("Repository option '{0}' did not change to {1} - it still reads {2}. The undocumented options endpoint may have changed; refusing to continue." -f
        $Key, $Value, (Get-RepositoryOption -RepoId $RepoId)[$Key])
}

# Off for the duration of a migration; restored to whatever they were before.
$script:CommitMentionKeys = @('WitMentionsEnabled', 'WitResolutionMentionsEnabled')

function Disable-CommitMention {
    <# Turns commit mention linking and resolution off, returning what they were so
       they can be put back. A failure THROWS: pushing history with these enabled is
       the incident this exists to prevent, so it must never be a warning. #>
    param([Parameter(Mandatory)][string]$RepoId, [string]$RepoName)

    $before = Get-RepositoryOption -RepoId $RepoId
    $captured = [ordered]@{}
    foreach ($key in $script:CommitMentionKeys) {
        if ($before.Contains($key)) { $captured[$key] = [bool]$before[$key] }
    }
    if ($captured.Count -eq 0) {
        throw "Could not read the commit mention options for '$RepoName'. The undocumented options endpoint may have changed; refusing to push."
    }

    foreach ($key in $captured.Keys) {
        if (-not $captured[$key]) { continue }   # already off; leave it alone
        Set-RepositoryOption -RepoId $RepoId -Key $key -Value $false
    }
    Write-Host ("    Commit mention linking/resolution disabled for the push (was: {0})." -f
        (($captured.Keys | ForEach-Object { "$_=$($captured[$_])" }) -join ', ')) -ForegroundColor DarkGray

    return $captured
}

function Restore-CommitMention {
    # Puts the options back exactly as they were, including leaving off what was off.
    # Never throws: the migration has finished by this point, and failing here must
    # not turn a completed migration into a failed one - but it is warned about
    # loudly, because a repository left with mentions disabled is a live change.
    param([string]$RepoId, [System.Collections.IDictionary]$Captured, [string]$RepoName)

    if (-not $Captured -or $Captured.Count -eq 0) { return }
    foreach ($key in $Captured.Keys) {
        if (-not $Captured[$key]) { continue }   # it was off before; leave it off
        try {
            Set-RepositoryOption -RepoId $RepoId -Key $key -Value $true
        }
        catch {
            Write-Warning ("    Could not restore '{0}' on '{1}': {2}. Re-enable it by hand in Project Settings > Repositories." -f
                $key, $RepoName, $_.Exception.Message)
        }
    }
}

#endregion Repository options -------------------------------------------------

function Get-TargetRefCount {
    # How many refs the TARGET repository actually holds. Compared against the mirror
    # after a push so the run states what landed rather than assuming the absence of an
    # error means success - a push can complete server-side while the client hangs, and
    # 'it finished' is worth proving, not inferring.
    param([string]$Name)
    try {
        $base = Get-CollectionBase -OrgUrl $TargetOrg
        $projectSeg = [uri]::EscapeDataString($TargetProject)
        $nameSeg = [uri]::EscapeDataString($Name)
        $url = "$base/$projectSeg/_apis/git/repositories/$nameSeg/refs?api-version=7.1&`$top=5000"
        $refs = Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders
        return [int]$refs.count
    }
    catch {
        Write-Verbose "Could not read target refs for '$Name': $($_.Exception.Message)"
        return -1
    }
}

function Get-LocalRefCount {
    param([string]$CloneDir)
    try {
        $refs = @(& git -C $CloneDir for-each-ref --format='%(refname)' refs/heads refs/tags 2>$null)
        return $refs.Count
    }
    catch { return -1 }
}

function Get-TargetRepoUrl {
    param([string]$Name)
    $base = Get-CollectionBase -OrgUrl $TargetOrg
    # URL-encode path segments so names containing spaces or other reserved
    # characters (e.g. 'DEPRECATED GF.MS.Milling.RTPM.Analytics') produce a
    # valid URL. An unescaped space makes curl/git reject the remote with
    # 'Malformed input to a URL function'.
    $projectSeg = [uri]::EscapeDataString($TargetProject)
    $nameSeg = [uri]::EscapeDataString($Name)
    "$base/$projectSeg/_git/$nameSeg"
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

    Write-CommitGraph -CloneDir $CloneDir
}

function Write-CommitGraph {
    # Precomputes commit reachability once, so every later traversal reads it instead
    # of walking commits again. Worth doing here because everything downstream traverses
    # repeatedly: git-lfs runs a rev-list PER REF, and a mirror holds every branch and
    # tag - 681 on one repository in this engagement, 2,892 on the next - so the same
    # shared history is walked over and over.
    #
    # Best-effort: a failure here costs speed, never correctness, so it must never stop
    # a migration.
    param([string]$CloneDir)

    $PSNativeCommandUseErrorActionPreference = $false
    Write-Host '    Building commit-graph (speeds up every later history walk)...' -ForegroundColor DarkGray
    $started = Get-Date
    & git -C $CloneDir commit-graph write --reachable 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '      commit-graph unavailable; continuing without it.' -ForegroundColor DarkGray
        return
    }
    Write-Host ("      commit-graph written in {0:n1}s." -f ((Get-Date) - $started).TotalSeconds) -ForegroundColor DarkGray
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
        $authArgs = Get-AzureDevOpsGitAuthArgs -GitHeader $script:SourceHeader
        & git @authArgs lfs fetch --all $RemoteName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    'git lfs fetch --all' reported errors; some LFS objects may be missing on the source."
        }
    }
    finally { Pop-Location }
}

function Format-Elapsed {
    <# 'mm:ss' on a TimeSpan is minutes-WITHIN-the-hour, so a push that ran for an hour
       and three minutes reported '03:23 elapsed' and looked like it had restarted. On a
       repository whose server-side ref update legitimately runs past the hour that is
       exactly the wrong thing to tell someone deciding whether to kill the run. #>
    param([Parameter(Mandatory)][timespan]$Span)
    if ($Span.TotalHours -ge 1) { return ('{0}:{1:mm\:ss}' -f [math]::Floor($Span.TotalHours), $Span) }
    return ('{0:mm\:ss}' -f $Span)
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
        # ArgumentList on ProcessStartInfo, never Start-Process -ArgumentList: that joins
        # the array with spaces and quotes nothing, which splits
        # 'http.extraheader=AUTHORIZATION: Bearer <token>' and makes git read 'Bearer' as
        # a command. Latent here only because the LFS path is skipped when a repository
        # has no LFS.
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'git'
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($a in $GitArgs) { [void]$psi.ArgumentList.Add([string]$a) }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        # Read both streams asynchronously to files: a full pipe buffer would deadlock a
        # process that is still being waited on.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

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
                Write-Host ("      still working: {0} - {1} elapsed{2}" -f $Activity, (Format-Elapsed -Span $elapsed), $cpuText) -ForegroundColor DarkGray
            }
        }
        $process.WaitForExit()

        $script:LastHeartbeatExitCode = $process.ExitCode
        $script:LastHeartbeatDuration = (Get-Date) - $started
        $script:LastHeartbeatStdErr = $errTask.GetAwaiter().GetResult()
        $stdout = $outTask.GetAwaiter().GetResult()
        if (-not $stdout) { return @() }
        return @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        if ($process) { $process.Dispose() }
    }
}

function Get-ProcessTreeId {
    # A process and everything below it. Used to judge a push by the whole tree:
    # 'git push' delegates to git-remote-https, which delegates to git send-pack,
    # and it is the descendants that hold the network connections and burn the CPU.
    param([int]$RootId)

    $ids = [System.Collections.Generic.List[int]]::new()
    $ids.Add($RootId)
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId)
        $frontier = @($RootId)
        while ($frontier.Count -gt 0) {
            $children = @($all | Where-Object { $_.ParentProcessId -in $frontier } | Select-Object -ExpandProperty ProcessId)
            $children = @($children | Where-Object { -not $ids.Contains([int]$_) })
            foreach ($c in $children) { $ids.Add([int]$c) }
            $frontier = $children
        }
    }
    catch { Write-Verbose "Could not enumerate the process tree: $($_.Exception.Message)" }
    return $ids
}

function Test-TreeHasConnection {
    # Does any process in the tree still hold a network connection? This is what
    # separates 'the server is thinking' from 'nothing is going to happen'. A push
    # waiting on Azure DevOps keeps an ESTABLISHED connection; a push deadlocked on
    # a broken helper pipe holds none at all.
    param([int[]]$ProcessIds)
    try {
        $conns = @(Get-NetTCPConnection -ErrorAction Stop |
                Where-Object { $_.OwningProcess -in $ProcessIds -and $_.State -eq 'Established' })
        return ($conns.Count -gt 0)
    }
    catch {
        # No way to tell (not Windows, or the cmdlet is unavailable) - assume there IS
        # a connection, so uncertainty never kills a healthy push.
        return $true
    }
}

function Invoke-GitWatched {
    <# Runs git with its output going straight to the console - progress bars and all -
       while watching for the process to wedge.

       Deliberately NOT Invoke-GitWithHeartbeat: this is for pushes, where git's own
       'Writing objects: 45%' progress is the thing worth seeing, and capturing it to
       parse would take that away.

       A push can legitimately sit at zero CPU for minutes while the server analyses,
       validates and stores - so idleness alone means nothing. What distinguishes a
       genuine stall is idleness AND the whole process tree holding no network
       connection: nothing is being waited for. That is the state a broken
       push -> remote-https -> send-pack pipe leaves behind, where every process waits
       on a pipe that will never deliver and the run hangs indefinitely.

       On a stall the tree is killed and a non-zero exit reported, so the repository is
       recorded as failed and the run carries on to the next one instead of stopping
       for the night. #>
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$Activity = 'git',
        [int]$HeartbeatSeconds = 30,
        [int]$StallSeconds = 180
    )

    $started = Get-Date

    # ProcessStartInfo.ArgumentList, NOT Start-Process -ArgumentList. The latter JOINS the
    # array with spaces and quotes nothing, so the auth argument
    # 'http.extraheader=AUTHORIZATION: Bearer <token>' was split at its spaces and git read
    # 'Bearer' as a command: "git: 'Bearer' is not a git command". Every push through here
    # failed, silently falling back to per-branch pushes that happened to work because they
    # go through a different invoker. ArgumentList escapes each argument individually.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    foreach ($a in $GitArgs) { [void]$psi.ArgumentList.Add([string]$a) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    $lastBeat = $started
    $lastBusy = $started
    $lastCpu = 0.0
    $stalled = $false

    while (-not $process.HasExited) {
        Start-Sleep -Seconds 2
        if ($process.HasExited) { break }

        $tree = Get-ProcessTreeId -RootId $process.Id
        $cpu = 0.0
        foreach ($id in $tree) {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p) { $cpu += $p.CPU }
        }

        $now = Get-Date
        $busy = ($cpu - $lastCpu) -gt 0.5 -or (Test-TreeHasConnection -ProcessIds $tree)
        if ($busy) { $lastBusy = $now }
        $lastCpu = $cpu

        if (($now - $lastBusy).TotalSeconds -ge $StallSeconds) {
            $stalled = $true
            Write-Warning ("    {0} appears STALLED: {1} elapsed, no CPU and no network connection for {2}s. Killing it - the repository will be reported as failed and the run continues." -f
                $Activity, (Format-Elapsed -Span ($now - $started)), $StallSeconds)
            foreach ($id in $tree) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            break
        }

        if (($now - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastBeat = $now
            $idleFor = [math]::Round(($now - $lastBusy).TotalSeconds)
            $idleNote = if ($idleFor -ge $HeartbeatSeconds) { ", idle {0}s of {1}s before it is called stalled" -f $idleFor, $StallSeconds } else { '' }
            Write-Host ("      still working: {0} - {1} elapsed, {2}s CPU{3}" -f
                $Activity, (Format-Elapsed -Span ($now - $started)), [math]::Round($cpu), $idleNote) -ForegroundColor DarkGray
        }
    }

    if (-not $stalled) { $process.WaitForExit() }
    $script:LastWatchedStalled = $stalled
    $script:LastWatchedDuration = (Get-Date) - $started
    $script:LastWatchedExitCode = if ($stalled) { 1 } else { $process.ExitCode }
    return $script:LastWatchedExitCode
}

function Test-RepoUsesLfs {
    <# Does this repository use Git LFS anywhere in its history?

       Worth answering BEFORE any LFS work, because 'git lfs push --all' is not
       "push the LFS objects" - it walks every ref's history looking for pointers,
       spawning a rev-list/cat-file pair per ref. On a MIRROR that means every branch
       and tag: 681 refs x 122k objects on one 294 MB repository, and 2,892 refs on
       the next. A repository with no LFS pays that in full to find nothing, twice
       (once for the dry-run pre-check, once for the push).

       This costs one object walk instead of one per ref - about a second and a half
       on that same repository. 'rev-list --objects --all' lists every reachable
       object WITH its path, so .gitattributes at any depth in any commit is found,
       not just the one at the root of the default branch. Only those blobs are read.

       Fails SAFE: any error returns $true, so an unreadable repository does the full
       LFS transfer rather than silently shipping pointers with no content behind them.
       A migration missing its LFS files is not a copy. #>
    [CmdletBinding()]
    param([string]$CloneDir)

    $PSNativeCommandUseErrorActionPreference = $false

    try {
        # An existing LFS object store settles it without any walking.
        if (Test-Path (Join-Path $CloneDir 'lfs\objects')) {
            $stored = @(Get-ChildItem (Join-Path $CloneDir 'lfs\objects') -Recurse -File -ErrorAction SilentlyContinue)
            if ($stored.Count -gt 0) { return $true }
        }

        $objects = & git -C $CloneDir rev-list --objects --all 2>$null
        if ($LASTEXITCODE -ne 0) { return $true }

        # '<oid> <path>' - keep the .gitattributes blobs at any depth, deduplicated.
        $oids = @($objects |
                Where-Object { $_ -match '\s(.*/)?\.gitattributes$' } |
                ForEach-Object { ($_ -split '\s+')[0] } |
                Sort-Object -Unique)
        if ($oids.Count -eq 0) { return $false }

        foreach ($oid in $oids) {
            $content = & git -C $CloneDir cat-file -p $oid 2>$null
            if ($LASTEXITCODE -ne 0) { return $true }
            if ($content -match 'filter\s*=\s*lfs') { return $true }
        }
        return $false
    }
    catch {
        Write-Warning "    Could not determine whether '$CloneDir' uses LFS ($($_.Exception.Message)); assuming it does."
        return $true
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
        (Get-AzureDevOpsGitAuthArgs -GitHeader $script:TargetHeader) + @('lfs', 'push', '--all', '--dry-run', $RemoteName)
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

    # One object walk decides whether any of the per-ref walking below is worth
    # doing at all. Everything past this point is proportional to REF COUNT, and a
    # mirror has every branch and tag.
    $lfsCheckStarted = Get-Date
    if (-not (Test-RepoUsesLfs -CloneDir $CloneDir)) {
        Write-Host ("    No LFS in this repository (checked every ref in {0:n1}s); skipping LFS transfer." -f `
            ((Get-Date) - $lfsCheckStarted).TotalSeconds) -ForegroundColor DarkGray
        return
    }
    Write-Host '    Repository uses LFS; its objects will be transferred.' -ForegroundColor Green

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
        $authArgs = Get-AzureDevOpsGitAuthArgs -GitHeader $script:TargetHeader
        & git @authArgs lfs push --all $TargetRemote
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
    $pushArgs = @('push', '--prune', $TargetRemote,
        'refs/heads/*:refs/heads/*',
        'refs/tags/*:refs/tags/*')
    if ($Force) { $pushArgs = @('push', '--force') + $pushArgs[1..($pushArgs.Count - 1)] }

    $exit = Invoke-GitWatched -WorkingDirectory $CloneDir -Activity 'push' -GitArgs (
        (Get-AzureDevOpsGitAuthArgs -GitHeader $script:TargetHeader) + $pushArgs)
    if ($exit -ne 0) {
        if ($script:LastWatchedStalled) { throw "push stalled and was killed after $([math]::Round($script:LastWatchedDuration.TotalMinutes,1)) minute(s)" }
        throw "git push failed with exit code $exit"
    }
}

function Measure-PushPayload {
    <# Bytes a push of this branch would actually send, or -1 if it cannot be measured.

       The ~5 GB limit is about BYTES, and the bytes sent are only the objects the target
       does not already have - which is what '--not --remotes/<target>' excludes. That
       makes this both correct and cheap: the first branch of a shared history measures
       the bulk of the repository, every branch after it measures almost nothing.

       Commit count, which this replaces as the basis for segmenting, was a poor proxy.
       On this engagement one branch of 22,173 commits carried 4.97 GB - at the limit -
       while branches of similar length that shared its history carried almost nothing.
       The default of 2,000 commits split the first into twelve pushes and every other
       branch into ten or more, re-offering objects the target already had. #>
    param([string]$Branch, [string]$TargetRemote)

    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $bytes = 0L
        $oids = & git rev-list --objects $Branch --not "--remotes=$TargetRemote" 2>$null
        if ($LASTEXITCODE -ne 0) { return -1 }
        if (-not $oids) { return 0 }
        $sizes = $oids | ForEach-Object { ($_ -split ' ')[0] } | & git cat-file --batch-check='%(objectsize:disk)' 2>$null
        if ($LASTEXITCODE -ne 0) { return -1 }
        foreach ($s in $sizes) { if ($s -match '^\d+$') { $bytes += [int64]$s } }
        return $bytes
    }
    catch { return -1 }
}

function Push-BranchSegmented {
    <# Pushes one branch's history to the target in commit-count segments so no single
       push exceeds the Azure DevOps limit.

       Only the commits the target does NOT already have. Segmenting from a branch's
       first commit means pushing an intermediate commit over a branch that is already
       further ahead, which git rejects as a non-fast-forward - so a repository that was
       partly migrated could never be finished, and the first rejected branch aborted the
       whole repository. #>
    param([string]$Branch, [string]$TargetRemote, [int]$BatchSize)

    # What the target already has for this branch, from the refs fetched by Push-Segmented.
    $targetRef = "refs/remotes/$TargetRemote/$Branch"
    $targetSha = (& git rev-parse --verify --quiet $targetRef) 2>$null
    $localSha = (& git rev-parse --verify --quiet $Branch) 2>$null

    $forcePush = $false
    $from = $targetSha

    if ($targetSha) {
        if ($targetSha -eq $localSha) {
            Write-Host "      [$Branch] already up to date" -ForegroundColor DarkGray
            return
        }

        & git merge-base --is-ancestor $targetSha $Branch 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Diverged. Not because anyone edited the target - because the branch was
            # REWRITTEN at the source after an earlier run copied it, leaving the target
            # holding commits the source has since discarded.
            if (-not $ForceDivergedBranches) {
                Write-Warning "      [$Branch] target has commits this mirror does not; left alone (use -ForceDivergedBranches to overwrite)."
                return
            }

            # Everything about to be discarded is recorded BEFORE it goes, so the run
            # can say exactly what was overwritten rather than 'some branches were forced'.
            $mergeBase = (& git merge-base $targetSha $Branch 2>$null)
            $orphans = @(& git rev-list "$mergeBase..$targetSha" 2>$null)
            $script:ForcedBranches.Add([pscustomobject]@{
                    Branch        = $Branch
                    TargetWas     = $targetSha
                    NowMatches    = $localSha
                    OrphanCommits = $orphans.Count
                    OrphanSample  = (@($orphans | Select-Object -First 5) -join ' ')
                })
            Write-Warning ("      [{0}] diverged - overwriting; {1} commit(s) exist only on the target and will be discarded." -f $Branch, $orphans.Count)

            # From the common ancestor, because the target's tip is not in this history.
            $from = $mergeBase
            $forcePush = $true
        }
    }

    # Oldest first, and only what the target is missing.
    $range = if ($from) { "$from..$Branch" } else { $Branch }
    $commits = @(& git rev-list --reverse --first-parent $range)
    if ($LASTEXITCODE -ne 0) { throw "git rev-list failed for branch '$Branch'" }
    $total = $commits.Count
    if ($total -eq 0) { return }

    # How many segments this branch ACTUALLY needs, measured rather than assumed.
    #
    # The ~5 GB limit is about bytes, and the bytes a push sends are only the objects the
    # target lacks. Once the first branch of a shared history is in, later branches send
    # nothing at all - their pushes report 'Total 0 (delta 0), reused 0' and are pure ref
    # updates. Segmenting those by commit count turned 2,908 branches into tens of
    # thousands of pushes of nothing, seconds apiece.
    #
    # 0.8 of the limit leaves room for the packing overhead a push adds over the on-disk
    # sizes measured here.
    $limitBytes = [int64]($MaxPushSizeGB * 1GB * 0.8)
    $payload = Measure-PushPayload -Branch $Branch -TargetRemote $TargetRemote
    $effectiveBatch = $BatchSize

    if ($payload -ge 0) {
        $mb = [math]::Round($payload / 1MB, 1)
        if ($payload -le $limitBytes) {
            $tipOnly = "$Branch`:refs/heads/$Branch"
            $oneShot = @('push') + $(if ($forcePush) { @('--force') } else { @() }) + @($TargetRemote, $tipOnly)
            Write-Host ("      [{0}] {1} MB to send; one push ({2} commit(s))" -f $Branch, $mb, $total) -ForegroundColor DarkGray
            Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs $oneShot
            return
        }
        # Enough segments to keep each push under the limit, and no more.
        $needed = [math]::Ceiling($payload / $limitBytes)
        $effectiveBatch = [math]::Max(1, [math]::Ceiling($total / $needed))
        Write-Host ("      [{0}] {1} MB to send; {2} segment(s) of ~{3:N0} commits" -f
            $Branch, $mb, $needed, $effectiveBatch) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("      [{0}] payload could not be measured; falling back to {1}-commit segments" -f
            $Branch, $BatchSize) -ForegroundColor DarkYellow
    }

    $segment = 0
    for ($i = $effectiveBatch - 1; $i -lt $total; $i += $effectiveBatch) {
        $sha = $commits[$i]
        $segment++
        $refspec = "$sha`:refs/heads/$Branch"
        Write-Host ("      [{0}] segment {1}: pushing through commit {2} ({3}/{4})" -f $Branch, $segment, $sha.Substring(0, 8), ($i + 1), $total) -ForegroundColor DarkCyan
        # A diverged branch needs --force on every segment, not only the last: the first
        # one already fails as a non-fast-forward against the target's discarded tip.
        # Not $args - that is an automatic variable holding a function's unbound arguments.
        $segmentArgs = @('push') + $(if ($forcePush) { @('--force') } else { @() }) + @($TargetRemote, $refspec)
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs $segmentArgs
    }

    # Final push to advance the branch to its actual tip.
    $tipRefspec = "$Branch`:refs/heads/$Branch"
    Write-Host "      [$Branch] final: pushing branch tip" -ForegroundColor DarkCyan
    $tipArgs = @('push') + $(if ($forcePush) { @('--force') } else { @() }) + @($TargetRemote, $tipRefspec)
    Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs $tipArgs
}

function Push-Segmented {
    # Segmented push path for large repositories.
    param([string]$CloneDir, [string]$TargetRemote, [int]$BatchSize)

    Push-Location $CloneDir
    try {
        $branches = @(& git for-each-ref --format='%(refname:short)' refs/heads)
        if ($LASTEXITCODE -ne 0) { throw 'git for-each-ref failed' }

        # One fetch tells us what the target already holds, so each branch pushes only
        # the commits it is missing. Without this a re-run - or a repository partly
        # migrated by an earlier attempt - tries to rewind branches and is rejected.
        Write-Host '    Reading what the target already has...' -ForegroundColor Green
        $PSNativeCommandUseErrorActionPreference = $false
        $authArgs = Get-AzureDevOpsGitAuthArgs -GitHeader $script:TargetHeader
        & git @authArgs fetch --quiet $TargetRemote "+refs/heads/*:refs/remotes/$TargetRemote/*" 2>$null
        if ($LASTEXITCODE -ne 0) {
            # An empty target has no refs to fetch; that is normal on a first migration.
            Write-Host '      (nothing to read - treating the target as empty)' -ForegroundColor DarkGray
        }

        # Segmenting is for ONE case: more than a single push can carry. That is a
        # property of the whole outstanding payload, not of any branch - so it is
        # measured once, for everything, and if it fits the entire repository goes in a
        # single push of every ref.
        #
        # Branch-by-branch was the wrong unit. Most of these branches share their history,
        # so once the bulk is on the target each one has nothing left to send: its pushes
        # report 'Total 0 (delta 0), reused 0' and cost a second apiece for a ref update.
        # Across 2,908 branches at a dozen segments each that is tens of thousands of
        # pushes of nothing.
        $limitBytes = [int64]($MaxPushSizeGB * 1GB * 0.8)
        $outstanding = Measure-PushPayload -Branch '--all' -TargetRemote $TargetRemote

        if ($outstanding -ge 0) {
            Write-Host ("    {0:N0} MB outstanding across every ref." -f ($outstanding / 1MB)) -ForegroundColor Green
            if ($outstanding -le $limitBytes) {
                Write-Host '    Fits in one push; sending every branch and tag together.' -ForegroundColor Green
                try {
                    Push-Mirror -CloneDir $CloneDir -TargetRemote $TargetRemote
                    return
                }
                catch {
                    # A diverged branch rejects the batch. Per-branch can force those.
                    Write-Host "      single push rejected ($($_.Exception.Message)); falling back to per-branch" -ForegroundColor DarkYellow
                }
            }
        }

        Write-Host ("    Per-branch push of {0} branch(es)." -f $branches.Count) -ForegroundColor Green

        # A branch that cannot be pushed must not cost the other 2,907. Each is tried on
        # its own, failures are collected, and the repository is failed at the END - so
        # the run reports everything wrong at once instead of one branch per attempt.
        $branchFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($branch in $branches) {
            if (-not $branch) { continue }
            try { Push-BranchSegmented -Branch $branch -TargetRemote $TargetRemote -BatchSize $BatchSize }
            catch {
                $branchFailures.Add("$branch : $($_.Exception.Message)")
                Write-Warning "      [$branch] $($_.Exception.Message)"
            }
        }
        if ($script:ForcedBranches.Count -gt 0) {
            Write-Host ''
            Write-Host ("    {0} branch(es) were force-updated to match the source:" -f $script:ForcedBranches.Count) -ForegroundColor Yellow
            foreach ($forced in $script:ForcedBranches) {
                Write-Host ("      {0}  ({1} commit(s) discarded, was {2})" -f
                    $forced.Branch, $forced.OrphanCommits, $forced.TargetWas.Substring(0, 8)) -ForegroundColor Yellow
            }
        }

        if ($branchFailures.Count -gt 0) {
            throw ("{0} of {1} branch(es) failed to push; first: {2}" -f
                $branchFailures.Count, $branches.Count, $branchFailures[0])
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

    # Commit mention linking is ON by default on every new repository, and a push of
    # full history is read as thousands of new mentions. Disabled BEFORE anything is
    # pushed, and restored in the finally below. A failure to disable throws, so the
    # push cannot happen with them live.
    $mentionsBefore = $null
    $targetRepoId = if ($targetRepo) { $targetRepo.id } else { (Get-TargetRepo -Name $targetName).id }
    if (-not $targetRepoId) {
        throw "Could not resolve the target repository id for '$targetName'; refusing to push without disabling commit mention linking."
    }
    $mentionsBefore = Disable-CommitMention -RepoId $targetRepoId -RepoName $targetName

    try {

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

    # Verify rather than assume. Comparing the mirror's refs against the target's costs
    # one API call and turns 'no error was raised' into 'n of n refs are on the target'.
    $localRefs = Get-LocalRefCount -CloneDir $cloneDir
    $targetRefs = Get-TargetRefCount -Name $targetName
    $status = 'Migrated'
    if ($targetRefs -lt 0) {
        Write-Host "    Pushed; could not read the target's refs to verify." -ForegroundColor DarkYellow
    }
    elseif ($localRefs -ge 0 -and $targetRefs -lt $localRefs) {
        # Not fatal - the push reported success - but it must be visible, not buried.
        Write-Warning ("    Verified {0} of {1} ref(s) on the target. Re-run to reconcile." -f $targetRefs, $localRefs)
        $status = "Migrated (verified $targetRefs/$localRefs refs)"
    }
    else {
        Write-Host ("    Verified: {0} ref(s) on the target." -f $targetRefs) -ForegroundColor DarkGray
    }

    Write-Host "    Done: $label ${progress}".TrimEnd() -ForegroundColor Green
    New-RepoSummary -Name $Repo.name -TargetName $targetName -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status $status

    }
    finally {
        # Restored however the push ended - success, failure, or Ctrl+C - so a run
        # never leaves the repository with its settings altered.
        Restore-CommitMention -RepoId $targetRepoId -Captured $mentionsBefore -RepoName $targetName
    }
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

# Declared before anything reads it. Get-RepositoryOption caches the target project id
# here on first use and tests it with 'if (-not $script:TargetProjectId)' - and under
# Set-StrictMode reading a variable that has never been assigned is an error, not $null,
# so every repository failed with 'the variable cannot be retrieved because it has not
# been set' before a single option could be read.
$script:TargetProjectId = $null

# Branches force-updated because they had diverged, recorded so the run can say exactly
# what was discarded rather than only that something was overwritten.
$script:ForcedBranches = [System.Collections.Generic.List[object]]::new()
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
