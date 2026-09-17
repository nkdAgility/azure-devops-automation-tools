<#
.SYNOPSIS
    Removes work item links that a repository migration created through Azure DevOps'
    commit mention linking, across every project in an organisation.

.DESCRIPTION
    Azure DevOps creates repositories with 'Commit mention linking' enabled. A migration
    pushes an entire history in one operation, so every historical '#1234' in every commit
    message is processed as a new mention and linked. Work item ids are unique per
    ORGANISATION rather than per project, so the links land wherever those ids happen to
    live - on one engagement, 6,798 work items across unrelated projects, from a single
    repository push.

    This undoes that. It is deliberately narrow: it removes only ArtifactLink relations
    that point at commits in the named repository AND were added by the matching revisions
    inside the window. Commit links that predate the window, belong to other repositories,
    or were made by anyone else are left alone - those are somebody's real history.

    Ordering matters if mentions also transitioned work items. Removing a link does NOT
    revert a state change, so restore states FIRST; this script reports transitions it
    sees and refuses to treat them as its business.

    Two phases, always in this order:

      1. DISCOVER (read-only). Query the organisation for work items changed in the window,
         read each one's revision history, and record every qualifying link in an evidence
         CSV. Written BEFORE anything is removed, so the removal is auditable and could be
         reversed by re-adding exactly what is listed.
      2. REMOVE. Per work item, re-read its current relations, resolve the indexes of the
         recorded links, and remove them in DESCENDING index order - a JSON Patch 'remove'
         renumbers everything after it, so ascending order deletes the wrong relations.

    Re-running is safe: a checkpoint records completed work items, and a link already gone
    is skipped rather than failed.

.PARAMETER Collection
    Organisation URL holding the work items, e.g. https://dev.azure.com/contoso.

.PARAMETER Project
    Project containing the repository whose links are being removed.

.PARAMETER RepoName
    Repositories whose commit links are to be removed. Only links pointing at commits in
    these repositories are touched.

    Pass every repository from the same migration together. A work item mentioned by
    commits in two of them would otherwise be edited twice, once per run, gaining two
    revisions in its history for what is one correction - and the expensive part, reading
    the revision history of every candidate work item, would be repeated per run.

.PARAMETER SinceDays
    How far back to look, in days. Default 30. Links added before this are left alone.

.PARAMETER ChangedBy
    Optional. Restrict to links added by this identity (the account that ran the
    migration). Omit to consider any identity within the window - wider, and worth
    thinking about before using, since it can catch genuine links made by real people.

.PARAMETER EvidencePath
    Where the evidence CSV is written. Defaults to 'commit-mention-links.csv' beside the
    checkpoint. Commit it: it is the record of what was removed.

.PARAMETER CheckpointPath
    Where progress is recorded so a re-run resumes. Defaults beside the evidence file.

.PARAMETER Pat
    Personal access token (Work Items Read & Write). Omit to use Entra - the default.

.PARAMETER Force
    Remove without confirming each work item. By default every work item is shown - id,
    project, type, state, title and the individual commit links - and confirmed one at a
    time, so the first few can be checked against the real thing before committing to
    thousands. 'Yes to All' switches to continuous from that point. Use -Force for
    unattended runs, where there is nobody to answer the prompt.

    Each work item takes exactly ONE edit, however many links it carries: all of its
    removals go in a single JSON Patch, so a work item with 15 links gains one revision
    in its history rather than 15.

.EXAMPLE
    # ALWAYS do this first: discovers and writes the evidence CSV, removes nothing.
    .\Remove-CommitMentionLinks.ps1 -Collection https://dev.azure.com/contoso `
        -Project Subsurface -RepoName PTL-AllInOne -ChangedBy someone@contoso.com -WhatIf

.EXAMPLE
    .\Remove-CommitMentionLinks.ps1 -Collection https://dev.azure.com/contoso `
        -Project Subsurface -RepoName PTL-AllInOne -ChangedBy someone@contoso.com -SinceDays 30

.NOTES
    Run with -WhatIf first, always, and read the evidence CSV before committing to the
    removal. This writes to work items across the whole organisation, most of them owned
    by teams with no connection to the migration.
#>
# ConfirmImpact is deliberately NOT High. High makes ShouldProcess raise its own
# confirmation, and this script already confirms every work item through ShouldContinue -
# which shows the commit ids, the repository and when each link was added. Both together
# asked twice per work item, and answering the first one looked like it had done nothing,
# because the second prompt was still waiting. One prompt, with the detail on it.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$Collection,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string[]]$RepoName,

    [ValidateRange(1, 3650)]
    [int]$SinceDays = 30,

    [string]$ChangedBy,

    [string]$EvidencePath,

    [string]$CheckpointPath,

    [string]$Pat,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The collection URL IS the API base - hosted and on-premises alike. It is never
# rebuilt against a hardcoded dev.azure.com, which would aim an on-premises run at
# a same-named PUBLIC organisation.
$collectionBase = $Collection.TrimEnd('/')

#region Auth and helpers -------------------------------------------------------

function Initialize-Auth {
    # Credential resolution lives in the module (Resolve-AzureDevOpsAuth) so every engine
    # answers "which credential here" identically: a supplied PAT wins, an on-premises
    # host uses Windows integrated auth (no header at all - see Invoke-Ado), the hosted
    # service uses Entra. Re-resolved per batch so a long run can renew a near-expiry
    # token; announced once.
    $auth = Resolve-AzureDevOpsAuth -Collection $Collection -Pat $Pat
    if ($script:AuthMode -ne $auth.Mode) {
        Write-Host "==> Auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:AuthMode = $auth.Mode
    }
    if ($auth.Headers.Count) {
        $script:Headers = @{ Accept = 'application/json' } + $auth.Headers
    }
    else {
        # Windows integrated: EMPTY headers are the signal to use default credentials.
        $script:Headers = @{}
    }
}

function Invoke-Ado {
    # Retries on throttling. Removing thousands of links WILL hit rate limits, and a
    # 429 treated as a failure would leave the run half-done for no reason.
    param([string]$Uri, [string]$Method = 'Get', [object]$Body, [string]$ContentType = 'application/json')

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $params = @{ Uri = $Uri; Method = $Method; SkipHttpErrorCheck = $true }
        # Empty headers mean Windows integrated auth: send nothing and let the stack
        # negotiate, rather than a blank Authorization header that suppresses it.
        if ($script:Headers.Count) { $params.Headers = $script:Headers }
        else { $params.UseDefaultCredentials = $true }
        if ($PSBoundParameters.ContainsKey('Body')) { $params.Body = $Body; $params.ContentType = $ContentType }

        # A dropped socket is an exception, not a status code, so it has to be caught
        # rather than checked for.
        $response = $null
        try { $response = Invoke-WebRequest @params -ErrorAction Stop }
        catch {
            if ($attempt -eq 5) { throw "Transport failure calling $Uri : $($_.Exception.Message)" }
            Start-Sleep -Seconds ([math]::Min(30, 2 * $attempt))
            continue
        }

        if ($response.StatusCode -eq 429 -or $response.StatusCode -ge 500) {
            $wait = [int]($response.Headers['Retry-After'] | Select-Object -First 1)
            if (-not $wait) { $wait = [math]::Min(30, [math]::Pow(2, $attempt)) }
            Write-Host ("      throttled ({0}); waiting {1}s" -f $response.StatusCode, $wait) -ForegroundColor DarkGray
            Start-Sleep -Seconds $wait
            continue
        }
        if ($response.StatusCode -ge 400) {
            throw "HTTP $($response.StatusCode) from $Uri : $($response.Content)"
        }
        if (-not $response.Content) { return $null }

        # Azure DevOps answers a sign-in redirect, and some throttling responses, with an
        # HTML page carrying a 2xx status. Handing that to ConvertFrom-Json produces
        # 'Unexpected character encountered while parsing value: <', which says nothing
        # about the real problem. Detected, retried, and finally reported for what it is.
        $content = [string]$response.Content
        if ($content.TrimStart().StartsWith('<')) {
            if ($attempt -lt 5) {
                Write-Host ("      non-JSON (HTML) response; retrying in {0}s" -f (2 * $attempt)) -ForegroundColor DarkGray
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
            throw ("Received an HTML response instead of JSON from $Uri. " +
                'That is normally an authentication redirect (the token was rejected or has expired) ' +
                'or heavy throttling. Re-run after signing in again, or with fewer concurrent runs.')
        }

        try { return ($content | ConvertFrom-Json) }
        catch { throw "Could not parse the response from $Uri as JSON: $($_.Exception.Message)" }
    }
    throw "Gave up after repeated failures: $Uri"
}

#endregion Auth and helpers ----------------------------------------------------

#region Discovery --------------------------------------------------------------

function Get-TargetRepositoryId {
    # id -> name, for every named repository. Resolved up front so a typo fails now
    # rather than after several minutes of scanning.
    param([string[]]$Name)

    $projectSeg = [uri]::EscapeDataString($Project)
    $map = [ordered]@{}
    foreach ($one in $Name) {
        $nameSeg = [uri]::EscapeDataString($one)
        $repo = Invoke-Ado -Uri "$collectionBase/$projectSeg/_apis/git/repositories/$nameSeg`?api-version=7.1"
        if (-not $repo.id) { throw "Repository '$one' was not found in project '$Project'." }
        $map[[string]$repo.id] = $repo.name
    }
    return $map
}

function Get-CandidateWorkItemId {
    <# Work items changed in the window, organisation-wide.

       Deliberately NOT driven from the repository's commits: that would mean querying
       artifact uris for every commit in the history (119,694 on the engagement that
       prompted this), where one identity-and-window query returns the same set directly
       and is scoped to what the migration actually did. #>
    $where = @("[System.ChangedDate] >= @today-$SinceDays")
    if ($ChangedBy) { $where += "[System.ChangedBy] = '$ChangedBy'" }
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE " + ($where -join ' AND ')

    Write-Host "==> Finding work items changed in the last $SinceDays day(s)$(if ($ChangedBy) { " by $ChangedBy" })..." -ForegroundColor Cyan
    $result = Invoke-Ado -Uri "$collectionBase/_apis/wit/wiql?api-version=7.1" -Method Post `
        -Body (@{ query = $wiql } | ConvertTo-Json)
    $ids = @($result.workItems | ForEach-Object { $_.id })
    Write-Host "    $($ids.Count) candidate work item(s)." -ForegroundColor DarkGray
    return $ids
}

function Get-WorkItemSummary {
    <# Project, type, title and state for a set of ids, in batches of 200.

       Only used to make the preview readable: 'work item 1735710' says nothing, while
       'sliic / Task / editable file location...' tells the operator whose data this is
       about to touch. #>
    param([int[]]$Ids)

    $summary = @{}
    for ($offset = 0; $offset -lt $Ids.Count; $offset += 200) {
        # Renew a near-expiry Entra token before each batch (cache hit otherwise).
        Initialize-Auth
        $batch = @($Ids[$offset..([math]::Min($offset + 199, $Ids.Count - 1))])
        $body = @{
            ids    = $batch
            fields = @('System.TeamProject', 'System.WorkItemType', 'System.Title', 'System.State')
        } | ConvertTo-Json -Depth 4
        $result = Invoke-Ado -Uri "$collectionBase/_apis/wit/workitemsbatch?api-version=7.1" -Method Post -Body $body
        foreach ($item in @($result.value)) {
            $summary[[int]$item.id] = [pscustomobject]@{
                Project = $item.fields.'System.TeamProject'
                Type    = $item.fields.'System.WorkItemType'
                Title   = $item.fields.'System.Title'
                State   = $item.fields.'System.State'
            }
        }
    }
    return $summary
}

function Get-CurrentArtifactLink {
    <# The ArtifactLink urls each work item CURRENTLY has, id -> set of urls.

       Discovery reads revision history, and a revision that added a link stays in that
       history forever - removing the link does not erase the event that added it. So
       history alone reports every link this migration ever created, including the ones
       already cleaned up: after a completed run it still claimed 12,018 links to remove
       when the true answer was none.

       Reconciling against current relations is what makes the counts, the preview and
       the prompting describe reality, and what lets a finished job say so. Batched 200
       at a time, so it costs a handful of calls rather than one per work item. #>
    param([int[]]$Ids)

    $current = @{}
    for ($offset = 0; $offset -lt $Ids.Count; $offset += 200) {
        # Renew a near-expiry Entra token before each batch (cache hit otherwise).
        Initialize-Auth
        $batch = @($Ids[$offset..([math]::Min($offset + 199, $Ids.Count - 1))])
        $body = @{ ids = $batch; '$expand' = 'relations' } | ConvertTo-Json -Depth 4
        $result = Invoke-Ado -Uri "$collectionBase/_apis/wit/workitemsbatch?api-version=7.1" -Method Post -Body $body
        foreach ($item in @($result.value)) {
            $urls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            # Absent entirely when the work item has no relations - see Remove-WorkItemLink.
            if (($item.PSObject.Properties.Name -contains 'relations') -and $item.relations) {
                foreach ($rel in @($item.relations)) {
                    if ($rel.rel -eq 'ArtifactLink' -and $rel.url) { [void]$urls.Add([string]$rel.url) }
                }
            }
            $current[[int]$item.id] = $urls
        }
    }
    return $current
}

function Write-WhatIfReport {
    <# The preview. Deliberately a REPORT rather than one ShouldProcess line per item:
       6,796 near-identical lines cannot be reviewed, and this change is spread across
       other teams' projects, so the operator needs to see the shape of it - which
       projects, how many each, over what window, and anything the script will not fix. #>
    param($Links, $StateChanges, $Summary, $EvidencePath)

    $byItem = @($Links | Group-Object WorkItemId)
    $projects = @{}
    foreach ($group in $byItem) {
        $project = if ($Summary.ContainsKey([int]$group.Name)) { $Summary[[int]$group.Name].Project } else { '(unknown)' }
        if (-not $projects.ContainsKey($project)) { $projects[$project] = [pscustomobject]@{ Items = 0; Links = 0 } }
        $projects[$project].Items++
        $projects[$project].Links += $group.Count
    }

    $dates = @($Links | ForEach-Object { $_.AddedOn }) | Sort-Object
    $authors = @($Links | ForEach-Object { $_.AddedBy } | Sort-Object -Unique)

    Write-Host ''
    Write-Host '================ WHAT WOULD BE REMOVED ================' -ForegroundColor Yellow
    Write-Host ("  work items      : {0:N0}" -f $byItem.Count)
    Write-Host ("  links           : {0:N0}" -f @($Links).Count)
    Write-Host ("  projects        : {0:N0}" -f $projects.Count)
    Write-Host ("  repositories    : {0}" -f ($RepoName -join ', '))
    $perRepo = @($Links | Group-Object Repo | Sort-Object Count -Descending)
    if ($perRepo.Count -gt 1) {
        foreach ($r in $perRepo) { Write-Host ("      {0,-42} {1,6:N0} link(s)" -f $r.Name, $r.Count) }
    }
    if ($dates.Count) {
        Write-Host ("  links added     : {0:yyyy-MM-dd HH:mm} .. {1:yyyy-MM-dd HH:mm}" -f $dates[0], $dates[-1])
    }
    Write-Host ("  window          : last {0} day(s)" -f $SinceDays)
    Write-Host ("  added by        : {0}" -f ($authors -join ', '))

    Write-Host ''
    Write-Host '  Affected projects (most affected first):' -ForegroundColor Yellow
    $projects.GetEnumerator() | Sort-Object { $_.Value.Links } -Descending | Select-Object -First 25 | ForEach-Object {
        Write-Host ("    {0,-45} {1,6:N0} link(s) on {2,6:N0} work item(s)" -f $_.Key, $_.Value.Links, $_.Value.Items)
    }
    if ($projects.Count -gt 25) { Write-Host ("    ... and {0} more project(s)" -f ($projects.Count - 25)) }

    Write-Host ''
    Write-Host '  Sample of what would be removed:' -ForegroundColor Yellow
    foreach ($group in ($byItem | Select-Object -First 10)) {
        $id = [int]$group.Name
        $info = if ($Summary.ContainsKey($id)) { $Summary[$id] } else { $null }
        $title = if ($info) { $info.Title } else { '' }
        if ($title.Length -gt 48) { $title = $title.Substring(0, 45) + '...' }
        Write-Host ("    #{0,-9} {1,-28} {2,-14} {3} link(s)  {4}" -f
            $id, ($(if ($info) { $info.Project } else { '?' })), ($(if ($info) { $info.State } else { '?' })), $group.Count, $title)
    }
    if ($byItem.Count -gt 10) { Write-Host ("    ... and {0:N0} more work item(s)" -f ($byItem.Count - 10)) }

    # Surfaced loudly: this script does not revert transitions, and removing a link
    # will not put a wrongly-closed work item back. Only transitions Azure DevOps
    # attributes to mention resolution are called out - the operator's own corrective
    # edits are separated, because a remediation list that includes the remediation
    # is one nobody can act on.
    $byMention = @($StateChanges | Where-Object { $_.ByMention })
    $other = @($StateChanges | Where-Object { -not $_.ByMention })

    if ($byMention.Count -gt 0) {
        Write-Host ''
        Write-Host '  *** STATE CHANGES CAUSED BY MENTION RESOLUTION - NOT FIXED BY THIS SCRIPT ***' -ForegroundColor Red
        Write-Host '  Removing a link does not revert a transition. Restore these by hand FIRST:' -ForegroundColor Red
        foreach ($change in ($byMention | Sort-Object WorkItemId)) {
            $info = if ($Summary.ContainsKey([int]$change.WorkItemId)) { $Summary[[int]$change.WorkItemId] } else { $null }
            $now = if ($info) { $info.State } else { 'unknown' }
            $flag = if ($info -and $info.State -eq $change.OldState) { '  [already restored]' } else { '' }
            Write-Host ("    #{0,-9} {1,-28} {2} -> {3}   (now: {4}){5}" -f
                $change.WorkItemId, ($(if ($info) { $info.Project } else { '?' })), $change.OldState, $change.NewState,
                $now, $flag) -ForegroundColor Red
        }
    }

    if ($other.Count -gt 0) {
        Write-Host ''
        Write-Host ("  Other state changes by this identity in the window ({0}) - informational, not caused by mentions:" -f $other.Count) -ForegroundColor DarkGray
        foreach ($change in ($other | Sort-Object WorkItemId)) {
            $info = if ($Summary.ContainsKey([int]$change.WorkItemId)) { $Summary[[int]$change.WorkItemId] } else { $null }
            Write-Host ("    #{0,-9} {1,-28} {2} -> {3}" -f
                $change.WorkItemId, ($(if ($info) { $info.Project } else { '?' })),
                ($(if ($change.OldState) { $change.OldState } else { '(new)' })), $change.NewState) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host ("  Evidence CSV (every link listed): {0}" -f $EvidencePath) -ForegroundColor Green
    Write-Host '  Nothing has been changed. Re-run without -WhatIf to remove.' -ForegroundColor Yellow
    Write-Host '=======================================================' -ForegroundColor Yellow
}

#endregion Discovery -----------------------------------------------------------

#region Removal ----------------------------------------------------------------

function Remove-WorkItemLink {
    <# Removes the given relation urls from one work item.

       Indexes are resolved against the CURRENT relations - never against what discovery
       saw, which may be stale - and removed in DESCENDING order, because each JSON Patch
       'remove' renumbers every relation after it. Ascending order silently deletes the
       wrong ones. #>
    param([int]$WorkItemId, [string[]]$Urls)

    # Renew a near-expiry Entra token per work item (cache hit otherwise) - the removal
    # loop can run for hours over thousands of items.
    Initialize-Auth
    $item = Invoke-Ado -Uri "$collectionBase/_apis/wit/workitems/$WorkItemId`?`$expand=relations&api-version=7.1"

    # A work item with NO relations comes back without a 'relations' property at all, and
    # under Set-StrictMode reading a missing property throws - so an item whose links have
    # already gone failed as 'The property relations cannot be found on this object'
    # instead of being the no-op it is. That happens routinely on a re-run, and on any
    # item somebody has tidied up by hand in the meantime.
    $relations = @()
    if ($item -and ($item.PSObject.Properties.Name -contains 'relations') -and $item.relations) {
        $relations = @($item.relations)
    }
    $indexes = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $relations.Count; $i++) {
        if ($relations[$i].rel -eq 'ArtifactLink' -and $Urls -contains $relations[$i].url) { $indexes.Add($i) }
    }
    if ($indexes.Count -eq 0) { return 0 }   # already gone - a re-run, not a failure

    $patch = @($indexes | Sort-Object -Descending | ForEach-Object {
            @{ op = 'remove'; path = "/relations/$_" }
        })

    Invoke-Ado -Uri "$collectionBase/_apis/wit/workitems/$WorkItemId`?api-version=7.1" `
        -Method Patch -Body (ConvertTo-Json @($patch) -Depth 5) -ContentType 'application/json-patch+json' | Out-Null

    # Verified by re-reading: the removal is the whole point, so it is proven, not assumed.
    $after = Invoke-Ado -Uri "$collectionBase/_apis/wit/workitems/$WorkItemId`?`$expand=relations&api-version=7.1"
    # Same guard: removing the last relation leaves the property absent entirely, which is
    # the SUCCESS case here and must not throw.
    $afterRelations = @()
    if ($after -and ($after.PSObject.Properties.Name -contains 'relations') -and $after.relations) {
        $afterRelations = @($after.relations)
    }
    $remaining = @($afterRelations | Where-Object { $_.rel -eq 'ArtifactLink' -and $Urls -contains $_.url })
    if ($remaining.Count -gt 0) {
        throw "work item $WorkItemId still has $($remaining.Count) of the targeted link(s) after the patch"
    }
    return $indexes.Count
}

#endregion Removal -------------------------------------------------------------

#region Main -------------------------------------------------------------------

$script:AuthMode = $null
Initialize-Auth

$since = (Get-Date).Date.AddDays(-$SinceDays)
$repoMap = Get-TargetRepositoryId -Name $RepoName
$repoIds = @($repoMap.Keys)
foreach ($id in $repoIds) { Write-Host "==> Repository '$($repoMap[$id])' = $id" -ForegroundColor DarkGray }

if (-not $EvidencePath) {
    # The workspace output folder when there is one - machine-local and gitignored -
    # rather than whatever directory the operator happened to be standing in.
    $root = $null
    if (Get-Command Get-AutomationWorkspace -ErrorAction SilentlyContinue) {
        try { $root = (Get-AutomationWorkspace).OutputFolder } catch { $root = $null }
    }
    if (-not $root) { $root = (Get-Location).Path }
    $tag = ($RepoName -join '-') -replace '[^\w\.-]', '-'
    if ($tag.Length -gt 60) { $tag = "{0}-and-{1}-more" -f (@($RepoName)[0] -replace '[^\w\.-]', '-'), (@($RepoName).Count - 1) }
    $EvidencePath = Join-Path $root ("commit-mention-links-{0}.csv" -f $tag)
}
$evidenceDir = Split-Path -Parent $EvidencePath
if ($evidenceDir -and -not (Test-Path -LiteralPath $evidenceDir)) {
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
}
if (-not $CheckpointPath) { $CheckpointPath = [System.IO.Path]::ChangeExtension($EvidencePath, '.checkpoint.txt') }

$candidates = Get-CandidateWorkItemId
if ($candidates.Count -eq 0) { Write-Host 'Nothing to do.' -ForegroundColor Green; return }

Write-Host "==> Reading revision history (read-only)..." -ForegroundColor Cyan
# Renew before capturing: the parallel runspaces cannot re-resolve, so they get the
# freshest token available at capture time.
Initialize-Auth
$headersForParallel = $script:Headers

$scanBlock = {
    $id = $_
    $h = $using:headersForParallel
    $who = $using:ChangedBy
    $rids = $using:repoMap
    $since = $using:since
    $base = $using:collectionBase

    # Six attempts, because a long scan WILL hit both throttling and dropped sockets.
    # A transport failure ('connection forcibly closed') is an EXCEPTION, not a status
    # code, so -SkipHttpErrorCheck does not cover it - without this try/catch a single
    # dropped connection out of thousands aborts the whole run.
    $u = $null
    for ($try = 1; $try -le 6; $try++) {
        try {
            # Empty headers mean Windows integrated auth - default credentials, no header.
            $reqArgs = @{ Uri = "$base/_apis/wit/workitems/$id/updates?api-version=7.1"; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
            if ($h -and $h.Count) { $reqArgs.Headers = $h } else { $reqArgs.UseDefaultCredentials = $true }
            $r = Invoke-WebRequest @reqArgs
            if ($r.StatusCode -eq 429 -or $r.StatusCode -ge 500) { Start-Sleep -Seconds ([math]::Min(30, 2 * $try)); continue }
            if ($r.StatusCode -ne 200) {
                return [pscustomobject]@{ Kind = 'error'; WorkItemId = $id; Reason = "HTTP $($r.StatusCode)" }
            }
            $u = $r.Content | ConvertFrom-Json
            break
        }
        catch {
            if ($try -eq 6) {
                # Surfaced, never swallowed: an item that could not be read is an item
                # whose links are unknown, and silently dropping it would make an
                # incomplete scan look complete.
                return [pscustomobject]@{ Kind = 'error'; WorkItemId = $id; Reason = $_.Exception.Message }
            }
            Start-Sleep -Seconds ([math]::Min(30, 2 * $try))
        }
    }
    if (-not $u) { return [pscustomobject]@{ Kind = 'error'; WorkItemId = $id; Reason = 'no response' } }

        foreach ($rev in @($u.value)) {
            $by = $rev.revisedBy.uniqueName
            if ($who -and $by -ne $who) { continue }
            $when = $rev.fields.'System.ChangedDate'.newValue -as [datetime]
            if (-not $when -or $when -lt $since) { continue }

            # Recorded so the preview can warn about it. This script never acts on a
            # state change - removing a link does not revert one.
            $st = $rev.fields.'System.State'
            if ($st -and $st.newValue -and $st.oldValue -ne $st.newValue) {
                # Azure DevOps stamps its own comment when mention resolution transitions
                # an item. Without this, the operator's OWN restores - and new work items
                # being created - are reported back to them as damage, which is worse than
                # useless on a list they are meant to act on.
                $note = $rev.fields.'System.History'.newValue
                [pscustomobject]@{
                    Kind        = 'state'
                    WorkItemId  = $id
                    OldState    = $st.oldValue
                    NewState    = $st.newValue
                    OldReason   = $rev.fields.'System.Reason'.oldValue
                    AddedOn     = $when
                    AddedBy     = $by
                    Note        = $note
                    ByMention   = [bool]($note -and $note -match 'mentioned work items')
                }
            }

            if (-not $rev.relations) { continue }
            foreach ($rel in @($rev.relations.added)) {
                if ($rel.rel -ne 'ArtifactLink') { continue }
                # Which of the named repositories this link points at, if any. Recorded
                # so the evidence says where each link came from when several
                # repositories are cleaned in one pass.
                $matched = $null
                foreach ($candidate in $rids.Keys) {
                    if ($rel.url -like "*$candidate*") { $matched = $rids[$candidate]; break }
                }
                if (-not $matched) { continue }
                [pscustomobject]@{
                    Kind       = 'link'
                    WorkItemId = $id
                    Repo       = $matched
                    Rev        = $rev.rev
                    AddedOn    = $when
                    AddedBy    = $by
                    Commit     = ($rel.url -split '%2F')[-1]
                    Url        = $rel.url
                }
            }
        }
}

# Chunked so progress is visible. The first version printed nothing for several minutes
# while it read thousands of work items, which is indistinguishable from a hang - the
# same fault that made the LFS scan look locked up, and the reason a run got abandoned
# as broken when it was working.
$discovered = [System.Collections.Generic.List[object]]::new()
$chunkSize = 500
for ($offset = 0; $offset -lt $candidates.Count; $offset += $chunkSize) {
    $upper = [math]::Min($offset + $chunkSize - 1, $candidates.Count - 1)
    $chunk = @($candidates[$offset..$upper])
    foreach ($row in @($chunk | ForEach-Object -ThrottleLimit 8 -Parallel $scanBlock)) {
        if ($row) { $discovered.Add($row) }
    }
    Write-Host ("    {0,6:N0}/{1:N0} read; {2:N0} link(s) found" -f
        ($upper + 1), $candidates.Count,
        @($discovered | Where-Object { $_.Kind -eq 'link' }).Count) -ForegroundColor DarkGray
}

$all = @($discovered | Where-Object { $_ })
$historic = @($all | Where-Object { $_.Kind -eq 'link' })
$stateChanges = @($all | Where-Object { $_.Kind -eq 'state' })
$readErrors = @($all | Where-Object { $_.Kind -eq 'error' })

# History says which links this migration CREATED; it cannot say which still exist,
# because the revision that added a link remains in the history after the link is gone.
# Everything downstream - the counts, the preview, the prompts - has to describe what is
# actually there now, or a finished job reports its whole workload as still outstanding.
$links = $historic
if ($historic.Count -gt 0) {
    Write-Host '==> Checking which of those links are still present...' -ForegroundColor Cyan
    $currentLinks = Get-CurrentArtifactLink -Ids @($historic | ForEach-Object { [int]$_.WorkItemId } | Sort-Object -Unique)
    $links = @($historic | Where-Object {
            $set = $currentLinks[[int]$_.WorkItemId]
            $set -and $set.Contains([string]$_.Url)
        })
    $goneAlready = $historic.Count - $links.Count
    if ($goneAlready -gt 0) {
        Write-Host ("    {0:N0} of {1:N0} already removed; {2:N0} still present." -f
            $goneAlready, $historic.Count, $links.Count) -ForegroundColor DarkGray
    }
}

$items = @($links | Group-Object WorkItemId)
Write-Host "    $($links.Count) link(s) on $($items.Count) work item(s); $($stateChanges.Count) state change(s); $($readErrors.Count) unreadable." -ForegroundColor DarkGray

# An item that could not be read is an item whose links are UNKNOWN. Removing what was
# found while pretending the scan was complete would leave links behind and report
# success, so this refuses to mutate anything until the scan is clean. -WhatIf still
# reports, because seeing the shape of the problem is exactly what it is for.
if ($readErrors.Count -gt 0) {
    Write-Warning ("{0} work item(s) could not be read - the scan is INCOMPLETE." -f $readErrors.Count)
    $readErrors | Select-Object -First 5 | ForEach-Object { Write-Warning "    $($_.WorkItemId): $($_.Reason)" }
    if (-not $WhatIfPreference) {
        throw "Refusing to remove links from an incomplete scan. Re-run: reads are retried, and a clean scan is required before anything is changed."
    }
}

# Evidence is written BEFORE any mutation, so what was removed is recoverable from it.
#
# Written even when there is nothing to record. Piping an empty result to Export-Csv
# creates NO FILE, which makes 'no links found' and 'the run died' look identical to
# whoever comes looking for the evidence afterwards.
#
# -WhatIf:$false on every write below is deliberate. Export-Csv and Set-Content honour
# ShouldProcess, so under -WhatIf they silently write NOTHING - which would make the
# preview useless precisely when it matters most, since reviewing 11,000 links means
# reading the file, not the console. These write to the operator's own output folder
# and change nothing in Azure DevOps, so they are not what -WhatIf is protecting.
# An incomplete scan gets its own filename. A run that could read only 742 of 6,799 work
# items produced a 21-row CSV that looks exactly like a complete one - and these files are
# committed as engagement evidence, so a partial list mistaken for the full picture is a
# worse outcome than no list at all.
if ($readErrors.Count -gt 0) {
    $EvidencePath = [System.IO.Path]::ChangeExtension($EvidencePath, '.INCOMPLETE.csv')
    Write-Warning "Scan incomplete - evidence will be written to $EvidencePath and must not be treated as the full set."
}

$evidenceRows = @($links | Sort-Object WorkItemId, Commit |
        Select-Object WorkItemId, Repo, Rev, AddedOn, AddedBy, Commit, Url)
if ($evidenceRows.Count) {
    $evidenceRows | Export-Csv -LiteralPath $EvidencePath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
}
else {
    Set-Content -LiteralPath $EvidencePath -Value '"WorkItemId","Repo","Rev","AddedOn","AddedBy","Commit","Url"' -Encoding UTF8 -WhatIf:$false
}
Write-Host "==> Evidence written: $EvidencePath ($($evidenceRows.Count) row(s))" -ForegroundColor Green

if ($stateChanges.Count) {
    $statePath = [System.IO.Path]::ChangeExtension($EvidencePath, '.state-changes.csv')
    $stateChanges | Sort-Object WorkItemId |
        Select-Object WorkItemId, OldState, NewState, OldReason, AddedOn, AddedBy, ByMention, Note |
        Export-Csv -LiteralPath $statePath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "==> State changes recorded separately: $statePath" -ForegroundColor Yellow
}

if ($links.Count -eq 0) {
    if ($historic.Count -gt 0) {
        # The difference worth stating: the job is done, rather than there having been
        # nothing to do. Both end here, and confusing them is how someone re-runs a
        # completed cleanup looking for work that no longer exists.
        Write-Host ("All {0:N0} link(s) this migration created have already been removed. Nothing left to do." -f $historic.Count) -ForegroundColor Green
    }
    else {
        Write-Host 'No qualifying links found.' -ForegroundColor Green
    }
    return
}

# The preview is a report, not thousands of ShouldProcess lines. Everything above this
# point is read-only, so -WhatIf reaches here having changed nothing.
# State-changed items are included even when they carry no links, otherwise they render
# as '?' in the very section the operator is meant to act on.
$summary = Get-WorkItemSummary -Ids @(
    @($items | ForEach-Object { [int]$_.Name }) + @($stateChanges | ForEach-Object { [int]$_.WorkItemId }) |
        Sort-Object -Unique)
if ($WhatIfPreference) {
    Write-WhatIfReport -Links $links -StateChanges $stateChanges -Summary $summary -EvidencePath $EvidencePath
    return
}

if ($stateChanges.Count) {
    Write-Warning ("{0} work item(s) were also STATE-CHANGED. This script does not revert those - restore them first, then re-run." -f $stateChanges.Count)
}

$done = @{}
if (Test-Path -LiteralPath $CheckpointPath) {
    Get-Content -LiteralPath $CheckpointPath | Where-Object { $_ } | ForEach-Object { $done[[int]$_] = $true }
    if ($done.Count) { Write-Host "==> Resuming: $($done.Count) work item(s) already done." -ForegroundColor DarkGray }
}

$removed = 0
$failed = [System.Collections.Generic.List[string]]::new()
$index = 0

# Stepped through one work item at a time by default, so the first few can be checked
# against the real thing before committing to thousands. 'Yes to All' switches to
# continuous once they look right; -Force skips prompting entirely for unattended runs.
$yesToAll = [bool]$Force
$noToAll = $false
if (-not $yesToAll) {
    Write-Host ''
    Write-Host 'Each work item is confirmed individually. [Y] this one  [A] yes to all  [N] skip  [L] no to all' -ForegroundColor Yellow
    Write-Host 'Each work item takes ONE edit, however many links it has.' -ForegroundColor DarkGray
}

foreach ($group in $items) {
    $index++
    $workItemId = [int]$group.Name
    if ($done.ContainsKey($workItemId)) { continue }

    $urls = @($group.Group | ForEach-Object { $_.Url })

    # The ShouldProcess target names the links themselves, not just how many. 'work item
    # 84191 (3 link(s))' is not something anyone can check; the commit ids, their
    # repository and when they were added are.
    $describe = if ($summary.ContainsKey($workItemId)) {
        $i = $summary[$workItemId]
        "work item $workItemId [$($i.Project) / $($i.Type) / $($i.State)] $($i.Title)"
    }
    else { "work item $workItemId" }
    $what = $describe + [Environment]::NewLine + (@($group.Group | Sort-Object AddedOn | ForEach-Object {
                "    {0}  {1}  added {2:yyyy-MM-dd HH:mm} by {3}" -f
                $_.Commit.Substring(0, [math]::Min(8, $_.Commit.Length)), $_.Repo, $_.AddedOn, $_.AddedBy
            }) -join [Environment]::NewLine)

    if (-not $PSCmdlet.ShouldProcess($what, 'Remove commit mention link(s)')) { continue }

    if (-not $yesToAll) {
        if ($noToAll) { Write-Host '==> Stopped at your request.' -ForegroundColor Yellow; break }

        $info = if ($summary.ContainsKey($workItemId)) { $summary[$workItemId] } else { $null }
        $title = if ($info) { $info.Title } else { '' }
        if ($title.Length -gt 70) { $title = $title.Substring(0, 67) + '...' }

        $detail = @($group.Group | Sort-Object AddedOn | ForEach-Object {
                "      {0}  {1}  added {2:yyyy-MM-dd HH:mm} by {3}" -f $_.Commit.Substring(0, [math]::Min(8, $_.Commit.Length)), $_.Repo, $_.AddedOn, $_.AddedBy
            }) -join [Environment]::NewLine

        $query = @"
  [$index of $($items.Count)]  #$workItemId  $(if ($info) { "$($info.Project) / $($info.Type) / $($info.State)" } else { '' })
  $title
    removing $($urls.Count) commit link(s) in ONE edit:
$detail
"@
        if (-not $PSCmdlet.ShouldContinue($query, "Remove commit mention link(s) from #$workItemId", [ref]$yesToAll, [ref]$noToAll)) {
            if ($noToAll) { Write-Host '==> Stopped at your request.' -ForegroundColor Yellow; break }
            Write-Host "    skipped #$workItemId" -ForegroundColor DarkGray
            continue
        }
    }

    try {
        $count = Remove-WorkItemLink -WorkItemId $workItemId -Urls $urls
        $removed += $count
        Add-Content -LiteralPath $CheckpointPath -Value $workItemId
        if ($index % 50 -eq 0) {
            Write-Host ("    [{0}/{1}] {2} link(s) removed so far" -f $index, $items.Count, $removed) -ForegroundColor DarkGray
        }
    }
    catch {
        # One work item must not stop thousands of others; it is recorded and reported.
        $failed.Add("$workItemId : $($_.Exception.Message)")
        Write-Warning "    $workItemId : $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host '================ Summary ================' -ForegroundColor Cyan
Write-Host ("work items : {0}" -f $items.Count)
Write-Host ("links removed: {0}" -f $removed)
Write-Host ("failed     : {0}" -f $failed.Count)
if ($failed.Count) { $failed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
Write-Host ("evidence   : {0}" -f $EvidencePath)
Write-Host '=========================================' -ForegroundColor Cyan

#endregion Main ----------------------------------------------------------------
