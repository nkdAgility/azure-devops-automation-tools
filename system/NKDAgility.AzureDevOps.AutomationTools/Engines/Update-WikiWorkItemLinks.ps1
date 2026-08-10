<#
.SYNOPSIS
    Repoints Azure DevOps work item links inside a migrated project wiki from the
    source org/project (and source work item IDs) to the target's.

.DESCRIPTION
    The work item migration assigns NEW IDs in the target organisation, so a wiki
    link such as
        https://dev.azure.com/<srcOrg>/<srcProject>/_workitems/edit/<srcId>
    cannot simply have its org/project swapped: the ID changes too. Each target
    work item records its original source reference in Custom.ReflectedWorkItemId,
    absolute URLs of the form
        https://dev.azure.com/<srcOrg>/<srcProject>/_workitems/edit/<srcId>
    are rewritten (both org/project and the numeric id) to the target, and, by
    default, bare '#<srcId>' work item mentions are also remapped to
    '#<targetId>'. To avoid false positives (hex colours like #666666, heading
    anchors, discussion-thread fragments such as ...edit/123#16612706), a
    '#<id>' is only rewritten when <id> is a known source work item in the map.
    Any '#<discussion>' anchor on a URL is preserved. Links whose target work
    item cannot be resolved (e.g. the wiki is processed before the work items
    are migrated) are left unchanged.

    The rewrite is applied inside a temporary git worktree of the wiki's bare
    mirror so the full history is preserved. By DEFAULT the script runs in
    PREVIEW mode: it reports every change (and any unresolved links), shows a
    'git diff --stat', and then discards the edits WITHOUT committing or pushing,
    so the result can be validated first. Pass -Commit to instead commit the
    rewrite onto the wiki branch (Migrate-Repos.ps1 pushes it afterwards). This
    script never pushes.

.PARAMETER SourceOrg
    Source organization URL, e.g. https://dev.azure.com/georgfischer.

.PARAMETER SourceProject
    Source project name (used to match work item links in the wiki).

.PARAMETER TargetOrg
    Target organization URL, e.g. https://dev.azure.com/machining.

.PARAMETER TargetPat
    Personal Access Token for the target organization (Work Items Read).

.PARAMETER TargetProject
    Target project name.

.PARAMETER CloneDir
    Path to the wiki's bare Git mirror (the '<Project>.wiki.git' directory that
    Migrate-Repos.ps1 creates; kept when -KeepClones is used).

.PARAMETER Branch
    Wiki branch to rewrite. Default: wikiMaster.

.PARAMETER Commit
    Commit the rewrite onto the branch. Omit (the default) to preview only:
    changes are reported and then discarded without committing or pushing.

.PARAMETER ShowDiff
    Also print the full unified diff of the pending changes (in addition to the
    summary table and --stat).

.PARAMETER SkipMentions
    Do not rewrite bare '#<id>' work item mentions; only rewrite full
    '_workitems/edit/<id>' URLs.

.PARAMETER LogDir
    Directory to write CSV logs of the run to. Two timestamped files are
    written: '<ts>-wiki-link-changes.csv' (every rewritten link) and, when any
    exist, '<ts>-wiki-link-unresolved.csv' (source ids with no target work
    item). The directory is created if missing. When omitted no logs are
    written.

.EXAMPLE
    # Preview only (no commit, no push) against an already-cloned wiki mirror.
    . .\scripts\Set-MigrationSecrets.ps1
    .\scripts\Update-WikiWorkItemLinks.ps1 `
        -SourceOrg https://dev.azure.com/georgfischer -SourceProject GF.MS.S3R.Kebnekaise `
        -TargetOrg https://dev.azure.com/machining -TargetPat $env:AZDO_PAT_MACHINING -TargetProject UM-S3R-WSM `
        -CloneDir 'C:\Users\default-admin\source\export\georgfischer\GF.MS.S3R.Kebnekaise\repos\GF.MS.S3R.Kebnekaise.wiki.git'

.OUTPUTS
    One object per rewritten link: Page, SourceId, TargetId, OldUrl, NewUrl.

.NOTES
    Requires Git 2.5+ (git worktree). Called by Migrate-Repos.ps1 with -Commit as
    part of a wiki migration; can be run standalone to validate the rewrite.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$SourceOrg,

    [Parameter(Mandatory = $true)]
    [string]$SourceProject,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$TargetOrg,

    [Parameter(Mandatory = $true)]
    [string]$TargetPat,

    [Parameter(Mandatory = $true)]
    [string]$TargetProject,

    [Parameter(Mandatory = $true)]
    [string]$CloneDir,

    [string]$Branch = 'wikiMaster',

    [switch]$Commit,

    [switch]$ShowDiff,

    [switch]$SkipMentions,

    [string]$LogDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-OrgName {
    param([string]$OrgUrl)
    ($OrgUrl.TrimEnd('/') -split '/')[-1]
}

function Get-AuthHeader {
    param([string]$Pat)
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat")) }
}

function Invoke-AdoApi {
    param([string]$Uri, [hashtable]$Headers, [string]$Method = 'Get', [object]$Body)
    $params = @{ Uri = $Uri; Headers = $Headers; Method = $Method }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}

function Get-TargetWorkItemIdMap {
    # Builds source work item ID -> target work item ID from the target project's
    # Custom.ReflectedWorkItemId field. The trailing integer of that field is the
    # original source ID; System.Id is the new target ID (they differ).
    param([hashtable]$Headers)

    $reflectedField = 'Custom.ReflectedWorkItemId'
    $org = Get-OrgName -OrgUrl $TargetOrg
    $projSeg = [uri]::EscapeDataString($TargetProject)

    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$TargetProject' AND [$reflectedField] <> ''" }
    $wiqlUrl = "https://dev.azure.com/$org/$projSeg/_apis/wit/wiql?api-version=7.1"

    $map = @{}
    $result = Invoke-AdoApi -Uri $wiqlUrl -Headers $Headers -Method Post -Body $wiql
    $ids = @($result.workItems | ForEach-Object { $_.id })
    if (-not $ids) { return $map }

    # The work items API caps at 200 IDs per request.
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $batch = $ids[$i..([math]::Min($i + 199, $ids.Count - 1))]
        $idList = $batch -join ','
        $detailUrl = "https://dev.azure.com/$org/_apis/wit/workitems?ids=$idList&fields=System.Id,$reflectedField&api-version=7.1"
        $details = Invoke-AdoApi -Uri $detailUrl -Headers $Headers
        foreach ($wi in $details.value) {
            $reflected = $wi.fields.$reflectedField
            if (-not $reflected) { continue }
            $m = [regex]::Match([string]$reflected, '(\d+)\s*$')
            if ($m.Success) {
                $map[[int]$m.Groups[1].Value] = [int]$wi.fields.'System.Id'
            }
        }
    }
    $map
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# Verify prerequisites.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git was not found on PATH. Install Git 2.x and try again.'
}
if (-not (Test-Path -LiteralPath (Join-Path $CloneDir 'HEAD'))) {
    throw "CloneDir does not look like a git repository (no HEAD): $CloneDir"
}

$headers = Get-AuthHeader -Pat $TargetPat
$srcOrg = Get-OrgName -OrgUrl $SourceOrg
$tgtOrg = Get-OrgName -OrgUrl $TargetOrg

Write-Host "==> Building source -> target work item ID map from '$TargetProject'..." -ForegroundColor Cyan
$idMap = Get-TargetWorkItemIdMap -Headers $headers
if (-not $idMap.Count) {
    Write-Warning 'No migrated work items found in target (Custom.ReflectedWorkItemId is empty everywhere). Links left unchanged; re-run after work items are migrated.'
    return
}
Write-Host ("    Loaded {0} work item ID mapping(s)." -f $idMap.Count) -ForegroundColor DarkGray

# Match source work item links, capturing the numeric ID. The project segment is
# matched in raw or URL-encoded form.
$srcProjPattern = [regex]::Escape($SourceProject) + '|' + [regex]::Escape([uri]::EscapeDataString($SourceProject))
$linkPattern = "https://dev\.azure\.com/$([regex]::Escape($srcOrg))/(?:$srcProjPattern)/_workitems/edit/(\d+)"
$targetBase = "https://dev.azure.com/$tgtOrg/$([uri]::EscapeDataString($TargetProject))/_workitems/edit/"

$changes = [System.Collections.Generic.List[object]]::new()
$unresolved = [System.Collections.Generic.List[object]]::new()
$script:CurrentPage = ''
$evaluator = {
    param($m)
    $srcId = [int]$m.Groups[1].Value
    if ($idMap.ContainsKey($srcId)) {
        $newUrl = $targetBase + $idMap[$srcId]
        $changes.Add([pscustomobject]@{
                Page     = $script:CurrentPage
                Kind     = 'url'
                SourceId = $srcId
                TargetId = $idMap[$srcId]
                OldUrl   = $m.Value
                NewUrl   = $newUrl
            })
        return $newUrl
    }
    # Leave unresolved links pointing at the source so they don't 404.
    $unresolved.Add([pscustomobject]@{ Page = $script:CurrentPage; SourceId = $srcId; Url = $m.Value })
    return $m.Value
}

# Bare '#<id>' work item mentions. Only ids present in the map are rewritten,
# which excludes hex colours, heading anchors and discussion-thread fragments.
# A negative lookbehind for '/' avoids touching the fragment part of a URL
# (e.g. '_workitems/edit/123#16612706'), and a lookbehind for word characters
# avoids matching inside identifiers.
$mentionPattern = '(?<![\w/])#(\d+)\b'
$mentionEvaluator = {
    param($m)
    $srcId = [int]$m.Groups[1].Value
    if ($idMap.ContainsKey($srcId)) {
        $changes.Add([pscustomobject]@{
                Page     = $script:CurrentPage
                Kind     = 'mention'
                SourceId = $srcId
                TargetId = $idMap[$srcId]
                OldUrl   = $m.Value
                NewUrl   = '#' + $idMap[$srcId]
            })
        return '#' + $idMap[$srcId]
    }
    # Not a known work item id (hex colour, anchor, other project) -> leave as-is.
    return $m.Value
}

$worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("wiki-links-" + [Guid]::NewGuid().ToString('N'))
Invoke-Git -C $CloneDir worktree add --quiet $worktree $Branch
try {
    $pagesChanged = 0
    Get-ChildItem -LiteralPath $worktree -Recurse -File -Filter *.md | ForEach-Object {
        $script:CurrentPage = $_.FullName.Substring($worktree.Length).TrimStart('\', '/')
        $content = [System.IO.File]::ReadAllText($_.FullName)
        $updated = [regex]::Replace($content, $linkPattern, $evaluator)
        if (-not $SkipMentions) {
            $updated = [regex]::Replace($updated, $mentionPattern, $mentionEvaluator)
        }
        if ($updated -ne $content) {
            [System.IO.File]::WriteAllText($_.FullName, $updated)
            $pagesChanged++
        }
    }

    Write-Host ''
    Write-Host '================ Work item link rewrite ================' -ForegroundColor Cyan
    if ($changes.Count -eq 0) {
        Write-Host 'No work item links needed updating.' -ForegroundColor Yellow
    }
    else {
        $changes |
            Sort-Object Page, SourceId |
            Format-Table -AutoSize @(
                @{ Label = 'Page';       Expression = { $_.Page } }
                @{ Label = 'Kind';       Expression = { $_.Kind } }
                @{ Label = 'Source ID';  Expression = { $_.SourceId }; Alignment = 'Right' }
                @{ Label = 'Target ID';  Expression = { $_.TargetId }; Alignment = 'Right' }
            ) |
            Out-Host
        Write-Host ("{0} link(s) across {1} page(s) will be repointed." -f $changes.Count, $pagesChanged) -ForegroundColor Green
    }

    if ($unresolved.Count -gt 0) {
        Write-Warning ("{0} link(s) had no matching target work item and were left unchanged:" -f $unresolved.Count)
        $unresolved | Sort-Object SourceId -Unique | ForEach-Object {
            Write-Host ("    - source id {0}  ({1})" -f $_.SourceId, $_.Page) -ForegroundColor DarkYellow
        }
    }

    if ($pagesChanged -gt 0) {
        Write-Host ''
        Invoke-Git -C $worktree --no-pager diff --stat | Out-Host
        if ($ShowDiff) {
            Write-Host ''
            & git -C $worktree --no-pager diff | Out-Host
        }
    }

    if ($Commit) {
        if ($pagesChanged -gt 0) {
            Invoke-Git -C $worktree add -A
            Invoke-Git -C $worktree -c user.name=Migration -c user.email=migration@localhost `
                commit --quiet -m 'Migration: repoint work item links to target work items'
            Write-Host 'Committed rewrite onto branch (not pushed).' -ForegroundColor Green
        }
        else {
            Write-Host 'Nothing to commit.' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host ''
        Write-Host 'PREVIEW only: changes were NOT committed or pushed. Re-run with -Commit to apply.' -ForegroundColor Yellow
    }
    Write-Host '=======================================================' -ForegroundColor Cyan

    # Write CSV logs of the run when a log directory is supplied.
    if ($LogDir) {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $changesLog = Join-Path $LogDir "$ts-wiki-link-changes.csv"
        $changes |
            Select-Object Page, Kind, SourceId, TargetId, OldUrl, NewUrl |
            Export-Csv -LiteralPath $changesLog -NoTypeInformation -Encoding UTF8
        Write-Host ("Wrote change log: {0}" -f $changesLog) -ForegroundColor Green
        if ($unresolved.Count -gt 0) {
            $unresolvedLog = Join-Path $LogDir "$ts-wiki-link-unresolved.csv"
            $unresolved |
                Select-Object Page, SourceId, Url |
                Export-Csv -LiteralPath $unresolvedLog -NoTypeInformation -Encoding UTF8
            Write-Host ("Wrote unresolved log: {0}" -f $unresolvedLog) -ForegroundColor Green
        }
    }

    # Emit change objects for scripted validation.
    $changes
}
finally {
    # Remove the worktree. In preview mode this discards the uncommitted edits;
    # any committed change lives on the branch in the bare mirror and is
    # unaffected by worktree removal.
    & git -C $CloneDir worktree remove --force $worktree 2>$null
}
