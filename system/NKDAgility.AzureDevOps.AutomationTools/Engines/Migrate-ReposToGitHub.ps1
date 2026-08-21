<#
.SYNOPSIS
    Migrates approved Git repositories from an Azure DevOps organization to a
    GitHub organization, including full history, all branches and tags.

.DESCRIPTION
    Driven by the approved rows of an inventory CSV produced by
    Export-GitRepoInventory: for each row whose Approved column is yes, the
    repository named by SourceRepoId is migrated to a GitHub repository named by
    the row's TargetName. For each approved repository:
      1. Ensures the GitHub repository exists (creates it if missing).
      2. Mirror-clones the source repository into the work path, or fetches
         updates into the existing mirror when it is already cached.
      3. Scans the object graph for blobs over GitHub's hard 100 MB file limit;
         offending repositories are Blocked (with the object list written next
         to the clone) instead of failing mid-push.
      4. Transfers Git LFS objects the target is missing.
      5. Pushes all branches and tags, then sets the default branch to match
         the source.

    GitHub rejects a single push larger than 2 GB. Repositories whose size
    exceeds -MaxPushSizeGB (or when -ForceSegmented is used) are pushed in
    *segments*: the commit history of each branch is walked oldest-to-newest and
    intermediate commits are pushed in batches, so each individual push only
    transfers a slice of the history and stays under the limit.

    Git LFS objects are NOT part of the normal Git object graph: a mirror clone
    and push only copy the small LFS *pointer* files, not the binary content
    they reference. To migrate the actual content this script runs
    'git lfs fetch --all' against the source and 'git lfs push --all' against
    the target for every repository; re-running backfills objects the target is
    missing. Requires git-lfs on PATH; if it is missing (or -SkipLfs is
    supplied) LFS transfer is skipped with a warning.

    Authentication is ambient-identity first, stored token as the fallback:
      - Source: Entra by default. When the automation module is loaded (the
        binder guarantees it) the engine acquires an Entra access token via
        Get-AzureDevOpsAccessToken and uses it as a Bearer header for both REST
        and git - an Entra token works anywhere a PAT does. The token is
        re-resolved before every repository, so the module's cache renews it
        near expiry across a long run. -SourcePat is the fallback, used when
        Entra sign-in is unavailable or fails.
      - GitHub: the signed-in gh CLI ('gh auth token') by default;
        -GitHubToken, then GITHUB_TOKEN, as fallbacks. The credential needs
        permission to create repositories in the organization and push
        (classic 'repo' scope, or fine-grained Administration: write plus
        Contents: write).
    Credentials are passed per-invocation via http.extraheader so they never
    end up in the remote URL or reflog.

    Re-running is safe and is the intended way to pick up newly approved rows:
    an existing GitHub repository is reused, the cached mirror only fetches new
    refs, the push only transfers deltas, and LFS only uploads missing objects.
    A row whose TargetName changed AFTER its repository was migrated (detected
    via -PreviousSummaryCsv) is Blocked, so a rename in the CSV cannot silently
    strand the already-migrated repository - revert the CSV, or reconcile on
    GitHub and re-run with -AcceptRenames. Nothing is ever deleted on GitHub.

.PARAMETER SourceOrg
    Source organization URL, used verbatim - both https://dev.azure.com/<org>
    and https://<org>.visualstudio.com work.

.PARAMETER SourcePat
    Personal Access Token for the source organization (Code Read). Optional:
    Entra is the default; the PAT is only used when Entra sign-in is
    unavailable or fails. A PAT is worth supplying for unattended runs and for
    single repositories so large that one transfer outlives an Entra token.

.PARAMETER GitHubOrg
    Target GitHub organization name (the org slug, not a URL).

.PARAMETER GitHubToken
    GitHub token able to create repositories in the organization and push.
    Optional: the signed-in gh CLI is the default; this token (then
    GITHUB_TOKEN) is the fallback.

.PARAMETER InventoryCsv
    Path of the inventory/approval CSV (see Export-GitRepoInventory). Only rows
    whose Approved column matches yes/y/true/1 are migrated.

.PARAMETER PreviousSummaryCsv
    Optional path of a previous run's summary CSV. Used to detect rows whose
    TargetName changed after migration, which are Blocked instead of migrated
    to a second repository.

.PARAMETER ProjectFilter
    Optional wildcard filter on SourceProject.

.PARAMETER RepoFilter
    Optional wildcard filter on SourceRepo.

.PARAMETER Visibility
    Visibility for newly created GitHub repositories: Private (default),
    Internal (GitHub Enterprise Cloud only) or Public. Existing repositories
    are never changed.

.PARAMETER MaxPushSizeGB
    Size threshold (in GB) above which a repository is pushed in segments.
    Default: 2 (matches the GitHub single-push limit).

.PARAMETER CommitBatchSize
    Number of commits per segment when pushing large repositories. Lower this if
    individual segments still exceed the push limit (e.g. repos with very large
    blobs). Default: 2000.

.PARAMETER ForceSegmented
    Always use the segmented push path, regardless of reported repository size.

.PARAMETER WorkPath
    Optional. Working directory for mirror clones. Defaults to a temp dir.

.PARAMETER KeepClones
    Keep mirror clones after migration (default: cleaned up). Keeping them makes
    re-runs much faster for large repositories.

.PARAMETER SkipLfs
    Skip Git LFS object transfer entirely.

.PARAMETER SkipOversizeCheck
    Skip the scan for blobs over GitHub's 100 MB limit. The push of an
    offending repository will then fail on GitHub's side instead.

.PARAMETER AcceptRenames
    Allow a row whose TargetName differs from the name it was previously
    migrated under to migrate to the new name. The previously migrated
    repository is NOT deleted - reconcile it on GitHub yourself.

.EXAMPLE
    # Ambient identity: Entra for the source, the signed-in gh CLI for GitHub.
    .\Migrate-ReposToGitHub.ps1 `
        -SourceOrg https://compucal.visualstudio.com `
        -GitHubOrg CompuCal-Solutions `
        -InventoryCsv .\repo-inventory.csv -WhatIf

.EXAMPLE
    # Smoke-test one approved repository with explicit fallback tokens.
    .\Migrate-ReposToGitHub.ps1 `
        -SourceOrg https://compucal.visualstudio.com -SourcePat $srcPat `
        -GitHubOrg CompuCal-Solutions -GitHubToken $ghToken `
        -InventoryCsv .\repo-inventory.csv -RepoFilter 'smallest-repo'

.NOTES
    Requires Git 2.x on PATH; Git LFS (git-lfs) is required to migrate LFS
    objects. Run with -WhatIf first to preview.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$SourceOrg,

    [string]$SourcePat,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [string]$GitHubToken,

    [Parameter(Mandatory = $true)]
    [string]$InventoryCsv,

    [string]$PreviousSummaryCsv,

    [string]$ProjectFilter,

    [string]$RepoFilter,

    [ValidateSet('Private', 'Internal', 'Public')]
    [string]$Visibility = 'Private',

    [ValidateRange(1, 100)]
    [int]$MaxPushSizeGB = 2,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$CommitBatchSize = 2000,

    [switch]$ForceSegmented,

    [string]$WorkPath,

    [switch]$KeepClones,

    [switch]$SkipLfs,

    [switch]$SkipOversizeCheck,

    [switch]$AcceptRenames
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers ---------------------------------------------------------------

function Get-AdoAuthHeader {
    param([string]$Pat)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Pat")
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
}

function Get-AdoExtraHeader {
    param([string]$Pat)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$Pat"))
    "AUTHORIZATION: Basic $b64"
}

function Get-GitHubExtraHeader {
    # GitHub authenticates git-over-HTTPS as user 'x-access-token' with the token as
    # the password - NOT the ':<pat>' form Azure DevOps uses.
    param([string]$Token)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
    "AUTHORIZATION: Basic $b64"
}

function Initialize-SourceAuth {
    # Ambient identity first: an Entra access token works anywhere a PAT does (Bearer
    # for REST, http.extraheader for git), so Entra is the default and -SourcePat only
    # the fallback. Called before every repository, not just once: the module caches
    # the token and renews it shortly before expiry, so re-resolving per repo keeps a
    # long run authenticated. Announces the mode once - never the credential.
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
        $script:SourceHeaders = Get-AdoAuthHeader -Pat $SourcePat
        $script:SourceHeader = Get-AdoExtraHeader -Pat $SourcePat
        if ($script:SourceAuthMode -ne 'PAT') {
            Write-Warning ("Entra sign-in unavailable ({0}); falling back to the source PAT." -f $entraError)
            $script:SourceAuthMode = 'PAT'
        }
        return
    }

    throw ("No source credential available: Entra sign-in failed ({0}) and no -SourcePat was supplied. Sign in to Entra, or add the source PAT to secrets\secrets.json." -f $entraError)
}

function Resolve-GitHubToken {
    # Ambient identity first here too: the signed-in gh CLI, then the supplied token,
    # then GITHUB_TOKEN. Every candidate is VALIDATED against the target org before it
    # wins, because against a SAML/Entra-SSO org the gh CLI's OAuth token only works
    # while the user's SSO session is active - handing over a token that answers 403
    # 'SAML enforcement' would fail every repository, when an SSO-authorised PAT in the
    # fallbacks would have worked.
    $candidates = [System.Collections.Generic.List[object]]::new()

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        # A signed-out gh exits non-zero; that is the fallback path, not an error.
        $PSNativeCommandUseErrorActionPreference = $false
        $token = $null
        try { $token = @(& gh auth token 2>$null) | Select-Object -First 1 } catch { $token = $null }
        if ($LASTEXITCODE -ne 0) { $token = $null }
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $candidates.Add(@{ Source = 'gh CLI'; Token = $token })
        }
    }
    if ($GitHubToken) { $candidates.Add(@{ Source = 'supplied token'; Token = $GitHubToken }) }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $candidates.Add(@{ Source = 'GITHUB_TOKEN'; Token = $env:GITHUB_TOKEN })
    }

    $orgSeg = [uri]::EscapeDataString($GitHubOrg)
    $lastError = $null
    foreach ($candidate in $candidates) {
        try {
            $probe = @{
                Uri         = "https://api.github.com/orgs/$orgSeg"
                Headers     = @{
                    Authorization          = 'Bearer ' + $candidate.Token
                    Accept                 = 'application/vnd.github+json'
                    'X-GitHub-Api-Version' = '2022-11-28'
                    'User-Agent'           = 'NKDAgility.AzureDevOps.AutomationTools'
                }
                ErrorAction = 'Stop'
            }
            $null = Invoke-RestMethod @probe
            Write-Host ("==> GitHub auth: {0} (validated against {1})." -f $candidate.Source, $GitHubOrg) -ForegroundColor DarkGray
            return $candidate.Token
        }
        catch {
            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            $lastError = $detail
            Write-Warning ("The GitHub credential from the {0} cannot access '{1}'; trying the next credential. ({2})" -f `
                    $candidate.Source, $GitHubOrg, (@($detail -split "`n" | Where-Object { $_ -match '\S' })[0]))
        }
    }

    $message = "No usable GitHub credential for '$GitHubOrg'. Sign in with 'gh auth login', or supply -GitHubToken (add the token to secrets\secrets.json with EnvVars ['GITHUB_TOKEN']). " +
    "If the org enforces SAML/Entra SSO: refresh your session at https://github.com/orgs/$GitHubOrg/sso, or use a classic PAT authorised for the org (token settings -> Configure SSO -> Authorize) - an authorised PAT does not need an active SSO session."
    if ($lastError) { $message += "`nLast error: $lastError" }
    throw $message
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

function Invoke-GhApi {
    # Minimal GitHub REST helper: Bearer auth, JSON accept header, 404-as-$null for
    # existence probes, and a short retry when GitHub answers with a rate limit.
    param(
        [string]$Uri,
        [string]$Method = 'Get',
        [object]$Body,
        [switch]$AllowNotFound
    )

    $params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $script:GhHeaders
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            $response = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $response = $_.Exception.Response
                $status = [int]$response.StatusCode
            }

            if ($status -eq 404 -and $AllowNotFound) { return $null }

            # Rate-limited responses carry Retry-After or an exhausted
            # x-ratelimit-remaining plus the epoch second the window resets; a real
            # permission denial carries neither and is not retried.
            if ($attempt -le 3 -and ($status -eq 429 -or $status -eq 403)) {
                $delay = 0
                try {
                    if ($response -and $response.Headers) {
                        $values = $null
                        if ($response.Headers.TryGetValues('Retry-After', [ref]$values)) {
                            $delay = [int](@($values)[0])
                        }
                        else {
                            $remaining = $null
                            $reset = $null
                            if ($response.Headers.TryGetValues('x-ratelimit-remaining', [ref]$remaining) -and
                                (@($remaining)[0] -eq '0') -and
                                $response.Headers.TryGetValues('x-ratelimit-reset', [ref]$reset)) {
                                $delay = [int](@($reset)[0]) - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1
                            }
                        }
                    }
                }
                catch { $delay = 0 }
                if ($delay -gt 0) {
                    $delay = [Math]::Min($delay, 120)
                    Write-Warning ("    GitHub rate limit hit; retrying in {0}s (attempt {1}/3)." -f $delay, $attempt)
                    Start-Sleep -Seconds $delay
                    continue
                }
            }

            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            throw "GitHub REST call failed: $Method $Uri`n$detail"
        }
    }
}

function Invoke-Git {
    # Runs git with a scoped auth header so tokens never touch the remote URL.
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

#region Inventory and repo operations -----------------------------------------

function Import-ApprovedInventory {
    # Loads the approval CSV and returns the rows this run should migrate: approved,
    # matching the filters. Structural problems (missing file, missing columns) throw;
    # per-row problems are handled in Migrate-ApprovedRepo so one bad row cannot stop
    # the run.
    if (-not (Test-Path -LiteralPath $InventoryCsv)) {
        throw "Inventory CSV not found: $InventoryCsv. Run Export-GitRepoInventory (Run-Export-RepoInventory.ps1) first."
    }
    $rows = @(Import-Csv -LiteralPath $InventoryCsv)
    if (-not $rows) {
        throw "Inventory CSV is empty: $InventoryCsv"
    }
    $required = @('SourceProject', 'SourceRepo', 'SourceRepoId', 'TargetName', 'Approved')
    $present = $rows[0].PSObject.Properties.Name
    $missing = @($required | Where-Object { $_ -notin $present })
    if ($missing) {
        throw ("Inventory CSV is missing required column(s): {0}. Re-run Export-GitRepoInventory." -f ($missing -join ', '))
    }

    $approved = @($rows | Where-Object { $_.Approved -match '^(?i)(y|yes|true|1)$' })
    if ($ProjectFilter) { $approved = @($approved | Where-Object { $_.SourceProject -like $ProjectFilter }) }
    if ($RepoFilter) { $approved = @($approved | Where-Object { $_.SourceRepo -like $RepoFilter }) }

    Write-Step ("Inventory: {0} row(s), {1} approved{2}." -f $rows.Count, $approved.Count,
        $(if ($ProjectFilter -or $RepoFilter) { ' (after filters)' } else { '' }))
    $approved
}

function Import-PreviousTargets {
    # Maps SourceRepoId -> the TargetName each repository was previously migrated
    # under, from a prior run's summary CSV. The binder maintains that baseline in
    # the last_migrated_name column (it survives later Blocked/Failed rows); older
    # summaries without the column fall back to Migrated-status rows. A row that
    # never migrated claims no name.
    $map = @{}
    if (-not $PreviousSummaryCsv -or -not (Test-Path -LiteralPath $PreviousSummaryCsv)) { return $map }
    foreach ($row in @(Import-Csv -LiteralPath $PreviousSummaryCsv)) {
        if (-not ($row.PSObject.Properties['source_repo_id'] -and $row.source_repo_id)) { continue }
        if ($row.PSObject.Properties['last_migrated_name'] -and $row.last_migrated_name) {
            $map[[string]$row.source_repo_id] = [string]$row.last_migrated_name
        }
        elseif ($row.PSObject.Properties['status'] -and $row.status -eq 'Migrated' -and
            $row.PSObject.Properties['target_name'] -and $row.target_name) {
            $map[[string]$row.source_repo_id] = [string]$row.target_name
        }
    }
    $map
}

function Get-SourceRepo {
    # Re-resolves a row's repository by its id so the run works from live facts, not
    # the (possibly stale) inventory. $null when the repository no longer exists.
    param([string]$Project, [string]$RepoId)

    $projectSeg = [uri]::EscapeDataString($Project)
    $uri = '{0}/{1}/_apis/git/repositories/{2}?api-version=7.1' -f $script:SourceOrgBase, $projectSeg, $RepoId
    try {
        Invoke-AdoApi -Uri $uri -Headers $script:SourceHeaders
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 404) { return $null }
        throw
    }
}

function New-GitHubRepo {
    # Ensures the GitHub repository exists. Idempotent: an existing repository is
    # reused untouched (its visibility is never changed).
    param([string]$Name)

    $orgSeg = [uri]::EscapeDataString($GitHubOrg)
    $nameSeg = [uri]::EscapeDataString($Name)

    $existing = Invoke-GhApi -Uri "https://api.github.com/repos/$orgSeg/$nameSeg" -AllowNotFound
    if ($existing) {
        Write-Host "    GitHub repo '$GitHubOrg/$Name' already exists." -ForegroundColor DarkGray
        return $existing
    }
    if (-not $PSCmdlet.ShouldProcess("$GitHubOrg/$Name", 'Create GitHub repository')) {
        return $null
    }
    $body = @{
        name       = $Name
        private    = ($Visibility -ne 'Public')
        visibility = $Visibility.ToLowerInvariant()
    }
    Write-Host "    Creating GitHub repo '$GitHubOrg/$Name' ($($Visibility.ToLowerInvariant()))." -ForegroundColor Green
    Invoke-GhApi -Uri "https://api.github.com/orgs/$orgSeg/repos" -Method Post -Body $body
}

function Get-TargetRepoUrl {
    param([string]$Name)
    # TargetName is validated against GitHub's allowed character set, but encode
    # anyway so the URL can never be malformed.
    $orgSeg = [uri]::EscapeDataString($GitHubOrg)
    $nameSeg = [uri]::EscapeDataString($Name)
    "https://github.com/$orgSeg/$nameSeg.git"
}

function Set-GitHubDefaultBranch {
    # Aligns the GitHub default branch with the source's. Without this GitHub keeps
    # whichever branch the first push happened to land, which for a multi-branch
    # mirror push is effectively arbitrary. Runs after the push so the branch exists.
    param([string]$Name, [string]$SourceDefaultRef)

    if (-not $SourceDefaultRef) { return }
    $branch = $SourceDefaultRef -replace '^refs/heads/', ''

    $orgSeg = [uri]::EscapeDataString($GitHubOrg)
    $nameSeg = [uri]::EscapeDataString($Name)
    $repo = Invoke-GhApi -Uri "https://api.github.com/repos/$orgSeg/$nameSeg" -AllowNotFound
    if (-not $repo) { return }
    if ($repo.PSObject.Properties['default_branch'] -and $repo.default_branch -eq $branch) {
        return
    }
    try {
        Invoke-GhApi -Uri "https://api.github.com/repos/$orgSeg/$nameSeg" -Method Patch -Body @{ default_branch = $branch } | Out-Null
        Write-Host "    Default branch set to '$branch'." -ForegroundColor DarkGray
    }
    catch {
        # Not worth failing a completed migration over; the operator can set it by hand.
        Write-Warning ("    Could not set default branch to '{0}': {1}" -f $branch, $_.Exception.Message)
    }
}

function Test-OversizeBlobs {
    # GitHub hard-rejects any blob over 100 MB at push time (and warns from 50 MB).
    # Scanning the mirror up front turns what would be a mid-push failure into a
    # Blocked row with the offending objects listed, so the operator can decide on
    # 'git lfs migrate' (a history rewrite - an engagement decision, never automated
    # here) before any bytes move.
    param([string]$CloneDir, [string]$RepoLabel)

    Push-Location $CloneDir
    try {
        $lines = & git rev-list --objects --all |
            & git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)'
        if ($LASTEXITCODE -ne 0) { throw "git object scan failed for '$RepoLabel'" }

        $limit = 100MB
        $oversize = foreach ($line in $lines) {
            $parts = $line -split ' ', 4
            if ($parts.Count -ge 3 -and $parts[0] -eq 'blob' -and [int64]$parts[2] -gt $limit) {
                [pscustomobject]@{
                    Sha    = $parts[1]
                    SizeMB = [math]::Round([int64]$parts[2] / 1MB, 1)
                    Path   = if ($parts.Count -gt 3) { $parts[3] } else { '' }
                }
            }
        }
        @($oversize)
    }
    finally { Pop-Location }
}

#endregion Inventory and repo operations --------------------------------------

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

    Push-Location $CloneDir
    try {
        $lines = & git -c "http.extraheader=$script:TargetHeader" lfs push --all --dry-run $RemoteName 2>$null
        if ($LASTEXITCODE -ne 0) {
            # If the dry-run itself fails, fall back to attempting the transfer.
            return -1
        }
        @($lines | Where-Object { $_ -match '^\s*push\s' }).Count
    }
    finally { Pop-Location }
}

function Push-Lfs {
    # Transfers only the LFS objects the target is missing. First a dry-run
    # counts the objects the target lacks; when none are pending the fetch and
    # push are skipped so re-runs don't re-download from the source or
    # re-negotiate every object with the target. When some are pending, the
    # objects are fetched from the source into the local store and pushed to the
    # target. Run before the refs are pushed so the objects always exist before
    # a pointer that references them. This keeps re-runs an idempotent backfill.
    #
    # Note GitHub LFS storage is quota'd per organisation; a push that exceeds
    # the quota fails with an explicit quota message from the server.
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

        # GitHub advertises LFS locking, so git-lfs prints a
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
    # contains Azure DevOps server-managed refs (e.g. refs/pull/*) - and GitHub
    # manages its own refs/pull/* namespace, which rejects writes outright.
    # Restricting to heads and tags avoids those refs while --prune still
    # removes branches/tags on the target that no longer exist on the source.
    param([string]$CloneDir, [string]$TargetRemote)

    Write-Host "    Pushing all branches and tags..." -ForegroundColor Green
    Push-Location $CloneDir
    try {
        Invoke-Git -ExtraHeader $script:TargetHeader -GitArgs @(
            'push', '--prune', $TargetRemote,
            'refs/heads/*:refs/heads/*',
            'refs/tags/*:refs/tags/*')
    }
    finally { Pop-Location }
}

function Push-BranchSegmented {
    # Pushes one branch's history to the target in commit-count segments so no
    # single push exceeds the GitHub limit.
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
    # records are written to the pipeline so callers (Run-Migrate-ReposToGitHub.ps1)
    # can print an end-of-run report and persist it as engagement evidence - which
    # the next run's rename detection also reads.
    param(
        [string]$SourceProject,
        [string]$SourceRepo,
        [string]$SourceRepoId,
        [string]$TargetName,
        [int64]$SizeBytes,
        [double]$SizeGB,
        [string]$Strategy,
        [string]$Status
    )
    [pscustomobject]@{
        SourceProject = $SourceProject
        SourceRepo    = $SourceRepo
        SourceRepoId  = $SourceRepoId
        TargetName    = $TargetName
        TargetUrl     = if ($TargetName) { "https://github.com/$GitHubOrg/$TargetName" } else { '' }
        SizeBytes     = $SizeBytes
        SizeGB        = $SizeGB
        Strategy      = $Strategy
        Status        = $Status
    }
}

function Migrate-ApprovedRepo {
    param($Row, [string]$WorkRoot, [int]$Index, [int]$Total)

    $progress = if ($Total) { "[$Index/$Total] " } else { '' }
    Write-Step "${progress}$($Row.SourceProject)/$($Row.SourceRepo) => $GitHubOrg/$($Row.TargetName)"

    # Re-resolve the source credential so an Entra token nearing expiry is renewed
    # before this repository's REST calls and git transfers start.
    Initialize-SourceAuth

    $summaryArgs = @{
        SourceProject = $Row.SourceProject
        SourceRepo    = $Row.SourceRepo
        SourceRepoId  = $Row.SourceRepoId
        TargetName    = $Row.TargetName
    }

    # A TargetName the CSV editor mangled must fail here, not at repo-creation time.
    if (-not $Row.TargetName -or $Row.TargetName -notmatch '^[A-Za-z0-9._-]+$' -or $Row.TargetName -in @('.', '..')) {
        New-RepoSummary @summaryArgs -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' `
            -Status ("Failed: invalid TargetName '{0}' - only alphanumerics, '-', '_' and '.' are allowed" -f $Row.TargetName)
        return
    }
    if ($script:DuplicateTargets.Contains($Row.TargetName)) {
        New-RepoSummary @summaryArgs -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' `
            -Status ("Failed: duplicate TargetName '{0}' - another approved row claims the same name" -f $Row.TargetName)
        return
    }

    # A row renamed AFTER its repository migrated would silently migrate to a second
    # repository and strand the first. Block it until the operator reconciles.
    if ($script:PreviousTargets.ContainsKey([string]$Row.SourceRepoId)) {
        $previousName = $script:PreviousTargets[[string]$Row.SourceRepoId]
        if ($previousName -and -not [string]::Equals($previousName, $Row.TargetName, [System.StringComparison]::OrdinalIgnoreCase) -and -not $AcceptRenames) {
            New-RepoSummary @summaryArgs -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' `
                -Status ("Blocked: TargetName changed '{0}' -> '{1}' after migration; revert the CSV, or reconcile '{0}' on GitHub and re-run with -AcceptRenames" -f $previousName, $Row.TargetName)
            return
        }
    }

    $repo = Get-SourceRepo -Project $Row.SourceProject -RepoId $Row.SourceRepoId
    if (-not $repo) {
        New-RepoSummary @summaryArgs -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' -Status 'Skipped (missing from source)'
        return
    }
    if ($repo.PSObject.Properties['isDisabled'] -and $repo.isDisabled) {
        New-RepoSummary @summaryArgs -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' -Status 'Skipped (disabled on source)'
        return
    }

    $sizeBytes = if ($repo.PSObject.Properties.Name -contains 'size') { [int64]$repo.size } else { 0 }
    $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
    $thresholdBytes = [int64]$MaxPushSizeGB * 1GB
    $useSegmented = $ForceSegmented -or ($sizeBytes -gt $thresholdBytes)
    $strategy = if ($useSegmented) { 'segmented' } else { 'mirror' }

    Write-Host ("    Reported size: {0} GB. Strategy: {1}." -f $sizeGB, $strategy) -ForegroundColor DarkGray

    $ghRepo = New-GitHubRepo -Name $Row.TargetName
    if (-not $ghRepo -and -not $WhatIfPreference) {
        New-RepoSummary @summaryArgs -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Skipped (no target repo)'
        return
    }

    $targetUrl = Get-TargetRepoUrl -Name $Row.TargetName
    $cloneDir = Join-Path $WorkRoot ($Row.TargetName + '.git')

    $action = if ($useSegmented) { 'Mirror-clone and segmented push to GitHub' } else { 'Mirror-clone and mirror push to GitHub' }
    if (-not $PSCmdlet.ShouldProcess("$GitHubOrg/$($Row.TargetName)", $action)) {
        New-RepoSummary @summaryArgs -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'WhatIf (preview)'
        return
    }

    # Clone the source as a mirror, or update the existing cached mirror.
    Sync-SourceMirror -CloneDir $cloneDir -RemoteUrl $repo.remoteUrl

    # Refuse to start a push GitHub is guaranteed to reject: any blob over 100 MB.
    if (-not $SkipOversizeCheck) {
        $oversize = @(Test-OversizeBlobs -CloneDir $cloneDir -RepoLabel $Row.SourceRepo)
        if ($oversize.Count -gt 0) {
            $reportPath = Join-Path $WorkRoot ($Row.TargetName + '.oversize.txt')
            $oversize | ForEach-Object { '{0} {1,10} MB {2}' -f $_.Sha, $_.SizeMB, $_.Path } |
                Set-Content -LiteralPath $reportPath -Encoding UTF8
            Write-Warning ("    {0} blob(s) exceed GitHub's 100 MB limit; object list: {1}" -f $oversize.Count, $reportPath)
            New-RepoSummary @summaryArgs -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy `
                -Status ("Blocked: {0} blob(s) > 100MB (GitHub hard limit) - see {1}; consider 'git lfs migrate' on the source" -f $oversize.Count, (Split-Path -Leaf $reportPath))
            return
        }
    }

    # Ensure the clone has a 'target' remote pointing at the GitHub repo.
    # Done before the LFS step so it can query what the target is missing.
    Set-TargetRemote -CloneDir $cloneDir -TargetUrl $targetUrl -RemoteName 'target'

    # Transfer only the LFS objects the target is missing (fetched from source
    # on demand) before the refs are pushed so pointers never precede their
    # content. Also backfills repos migrated before with missing objects.
    Push-Lfs -CloneDir $cloneDir -SourceRemote 'source' -TargetRemote 'target'

    if ($useSegmented) {
        Push-Segmented -CloneDir $cloneDir -TargetRemote 'target' -BatchSize $CommitBatchSize
    }
    else {
        Push-Mirror -CloneDir $cloneDir -TargetRemote 'target'
    }

    $defaultBranch = if ($repo.PSObject.Properties['defaultBranch']) { [string]$repo.defaultBranch } else { '' }
    Set-GitHubDefaultBranch -Name $Row.TargetName -SourceDefaultRef $defaultBranch

    Write-Host "    Done: $($Row.SourceRepo) ${progress}".TrimEnd() -ForegroundColor Green
    New-RepoSummary @summaryArgs -SizeBytes $sizeBytes -SizeGB $sizeGB -Strategy $strategy -Status 'Migrated'
}

#region Main ------------------------------------------------------------------

# Verify git is available.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found on PATH. Install Git 2.x and try again.'
}

$script:SourceOrgBase = $SourceOrg.TrimEnd('/')

# Ambient-first credential resolution: Entra then -SourcePat for the source (renewed
# per repository), the gh CLI then -GitHubToken/GITHUB_TOKEN for the target.
$script:SourceAuthMode = $null
Initialize-SourceAuth
$resolvedGitHubToken = Resolve-GitHubToken
$script:TargetHeader = Get-GitHubExtraHeader -Token $resolvedGitHubToken
$script:GhHeaders = @{
    Authorization          = 'Bearer ' + $resolvedGitHubToken
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    # GitHub rejects requests that carry no User-Agent.
    'User-Agent'           = 'NKDAgility.AzureDevOps.AutomationTools'
}

# Lazily probed by Test-GitLfs on first use; cached for the rest of the run.
$script:GitLfsChecked = $false
$script:GitLfsAvailable = $false

$script:PreviousTargets = Import-PreviousTargets

if (-not $WorkPath) {
    $WorkPath = Join-Path ([System.IO.Path]::GetTempPath()) ("github-repo-migration-" + [Guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
Write-Step "Working directory: $WorkPath"

try {
    $rows = Import-ApprovedInventory
    if (-not $rows) {
        Write-Warning 'No approved repositories to migrate. Mark rows Approved=yes in the inventory CSV and re-run.'
        return
    }

    # TargetNames must be unique across the approved set (GitHub org names are a flat,
    # case-insensitive namespace). Both claimants of a duplicate are failed so neither
    # silently wins the name.
    $nameCounts = @{}
    foreach ($row in $rows) {
        if (-not $row.TargetName) { continue }
        $key = $row.TargetName.ToLowerInvariant()
        $nameCounts[$key] = 1 + $(if ($nameCounts.ContainsKey($key)) { $nameCounts[$key] } else { 0 })
    }
    $script:DuplicateTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $nameCounts.GetEnumerator()) {
        if ($entry.Value -gt 1) { [void]$script:DuplicateTargets.Add($entry.Key) }
    }

    $total = @($rows).Count
    $index = 0
    foreach ($row in $rows) {
        $index++
        # A failure in one repository must not abort the whole run. Surface it as a
        # warning, record it in the summary, and continue with the next repository so
        # the operator can reconcile it afterwards - the next run retries it.
        try {
            Migrate-ApprovedRepo -Row $row -WorkRoot $WorkPath -Index $index -Total $total
        }
        catch {
            Write-Warning ("    Migration FAILED for '{0}/{1}': {2}" -f $row.SourceProject, $row.SourceRepo, $_.Exception.Message)
            New-RepoSummary -SourceProject $row.SourceProject -SourceRepo $row.SourceRepo `
                -SourceRepoId $row.SourceRepoId -TargetName $row.TargetName `
                -SizeBytes 0 -SizeGB 0 -Strategy 'n/a' `
                -Status ("Failed: {0}" -f $_.Exception.Message)
        }
    }

    Write-Step 'Repository migration to GitHub complete.'
}
finally {
    if (-not $KeepClones -and (Test-Path $WorkPath)) {
        Write-Host "Cleaning up working directory $WorkPath" -ForegroundColor DarkGray
        Remove-Item -Path $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion Main ---------------------------------------------------------------
