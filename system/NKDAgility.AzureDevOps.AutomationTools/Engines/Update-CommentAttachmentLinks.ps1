<#
.SYNOPSIS
    Migrates attachments referenced by MARKDOWN links inside work item comments
    and rewrites those links to point at the target organisation.

.DESCRIPTION
    The work item migration rewrites HTML attachment references in comments
    (<a href>/<img src>), but a markdown-format comment carries its links as
    plain text - ![name](url) / [name](url) or a bare URL - and those were left
    pointing at the source organisation. After the source is decommissioned
    every one of them is a dead link, and until then they leak source content
    into the target.

    This script walks every work item in the target project (only those with
    comments, via System.CommentCount), reads each comment, and finds
    attachment URLs that still point at the source organisation
    (.../_apis/wit/attachments/<guid>?fileName=...). For each distinct source
    attachment it downloads the content from the source, uploads it to the
    target project (which assigns a NEW attachment guid), and rewrites the
    comment text - markdown links and bare URLs alike - to the new URL. An
    attachment referenced from several comments is migrated once and the new
    URL reused.

    By DEFAULT the script runs in PREVIEW mode: it scans, reports every link it
    would rewrite, and writes the change/unresolved CSVs WITHOUT uploading
    anything or editing any comment. Pass -Commit to perform the migration.
    Comments are updated via the comments REST API, which preserves the
    original author but stamps the comment as modified by the identity behind
    the token - the same trade the migration itself already made. The comment's
    format (markdown or html) is preserved via the API's format QUERY parameter;
    the update body only carries text, and PATCHing without the parameter saves
    the comment as html regardless of what it was.

    Attachments whose download fails (deleted at source, source already gone,
    permissions) are reported in the unresolved CSV and their links are left
    unchanged, so a later re-run can pick them up.

    PROGRESS: a live progress bar shows [n/total], work items per minute and
    ETA, and a heartbeat line lands in the console every 60 seconds with the
    running totals. CHECKPOINTS: a committed full scan records the last
    completed work item after every item, so an interrupted run resumes where
    it stopped ('Resuming after WI <id>...'); -Restart starts over. Preview and
    -WorkItemId runs never checkpoint, and a completed run clears its
    checkpoint. The file is <output>\comment-attachment-links-<project>
    .checkpoint.json - gitignored by the workspace's *.checkpoint.json rule.

    The scan also HEALS comments damaged by earlier states of this problem,
    detected without any CSV, so pointing the engine at a work item fixes it
    whatever state it is in and a second run converges to a no-op:

      * Half-fixed: links already rewritten but the comment saved as html, so
        its markdown renders literally (format html, no HTML tags, carries a
        markdown attachment link). Re-marked as markdown.
      * Escaped: converted through the ADO convert-to-markdown button, which
        escapes what it sees as literal punctuation - !\[image.png\](...\_apis)
        - markdown turned into text ABOUT markdown. Detected by the escaped
        attachment link signature, which never occurs naturally; the whole
        comment is unescaped (the button escaped the whole comment) and saved
        as markdown.

    PATs: in a customer workspace, run Set-AutomationSecrets (from the
    NKDAgility.AzureDevOps.AutomationTools module) first; -SourcePat and
    -TargetPat then default from the derived AZDO_PAT_<ORG> variables. The
    source PAT needs Work Items (Read); the target PAT needs Work Items
    (Read & Write).

.PARAMETER SourceOrgUrl
    Source organisation URL, e.g. https://dev.azure.com/georgfischer. Only
    attachment URLs under this organisation are touched.

.PARAMETER TargetOrgUrl
    Target organisation URL, e.g. https://dev.azure.com/machining.

.PARAMETER TargetProject
    Target project whose work item comments are scanned, e.g. UM-MIKRON-Milling.

.PARAMETER SourcePat
    PAT for the source organisation. Defaults from AZDO_PAT_<SOURCEORG>.

.PARAMETER TargetPat
    PAT for the target organisation. Defaults from AZDO_PAT_<TARGETORG>.

.PARAMETER WorkItemId
    Optional. Restrict the scan to these work item ids - use this to validate
    the rewrite on a handful of known-affected items before a full run.

.PARAMETER Commit
    Perform the migration: upload attachments and PATCH comments. Without it
    the script only reports and writes CSVs.

.PARAMETER Restart
    Clear the checkpoint left by an interrupted commit run and start the scan
    from the beginning. Safe: the scan is idempotent, a full re-run converges.

.PARAMETER OutputFolder
    Where the evidence CSVs are written. Defaults to .\output. Two files per
    run, timestamped: *-comment-attachment-changes.csv and
    *-comment-attachment-unresolved.csv.

.PARAMETER RepairFormatCsv
    Remedial mode for runs made BEFORE the format fix, which saved markdown
    comments back as html (text intact, but the UI renders the markdown syntax
    literally). Pass that run's *-comment-attachment-changes.csv: each comment
    it lists is re-marked as markdown with its current text. Comments whose
    text contains HTML tags are skipped for hand review - they may genuinely
    have been html. Preview by default; -Commit applies. No links are scanned
    or attachments moved in this mode.

.EXAMPLE
    .\Update-CommentAttachmentLinks.ps1 -SourceOrgUrl https://dev.azure.com/georgfischer `
        -TargetOrgUrl https://dev.azure.com/machining -TargetProject UM-MIKRON-Milling

    Preview: report every markdown attachment link still pointing at the source.

.EXAMPLE
    .\Update-CommentAttachmentLinks.ps1 -SourceOrgUrl https://dev.azure.com/georgfischer `
        -TargetOrgUrl https://dev.azure.com/machining -TargetProject UM-MIKRON-Milling `
        -WorkItemId 1204, 1381 -Commit

    Migrate and rewrite on two known-affected work items first.

.EXAMPLE
    .\Update-CommentAttachmentLinks.ps1 -SourceOrgUrl https://dev.azure.com/georgfischer `
        -TargetOrgUrl https://dev.azure.com/machining -TargetProject UM-S3R-WSM `
        -RepairFormatCsv .\output\20260810-120000-comment-attachment-changes.csv -Commit

    Restore markdown format on comments a pre-fix run saved as html.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$SourceOrgUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$TargetOrgUrl,

    [Parameter(Mandatory)]
    [string]$TargetProject,

    [string]$SourcePat,
    [string]$TargetPat,

    [int[]]$WorkItemId,

    [switch]$Commit,

    # Ignore (and clear) the checkpoint from an interrupted run and start over.
    [switch]$Restart,

    [string]$OutputFolder = (Join-Path (Get-Location).Path 'output'),

    # Remedial mode: a changes CSV from a run made BEFORE the format fix, whose comment
    # edits saved markdown comments back as html. Re-marks those comments as markdown
    # (same text, format=markdown) instead of scanning for links. See .PARAMETER help.
    [string]$RepairFormatCsv
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Get-OrgName {
    param([string]$Url)
    ($Url.TrimEnd('/') -split '/')[-1]
}

function Get-DerivedPatName {
    param([string]$Org)
    'AZDO_PAT_' + ($Org.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
}

function Resolve-Pat {
    # An explicit value wins; otherwise fall back to the AZDO_PAT_<ORG> variable
    # that Set-AutomationSecrets exports from the workspace secrets file.
    param([string]$Explicit, [string]$Org, [string]$Side)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    $name = Get-DerivedPatName -Org $Org
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "No $Side PAT. Pass -${Side}Pat, or run Set-AutomationSecrets so `$ENV:$name is populated."
    }
    return $value
}

function Get-AuthHeader {
    param([string]$Token)
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token")) }
}

function Invoke-AdoRest {
    # One retry wrapper for every call: 429/5xx back off and retry, everything
    # else surfaces immediately with the failing URI in the message.
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = 'Get',
        $Body,
        [string]$ContentType = 'application/json',
        [string]$OutFile,
        [int]$MaxAttempts = 4
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $arguments = @{ Uri = $Uri; Headers = $Headers; Method = $Method; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $arguments.Body = $Body; $arguments.ContentType = $ContentType }
            if ($OutFile) { $arguments.OutFile = $OutFile }
            return Invoke-RestMethod @arguments
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            $retryable = $status -in 429, 500, 502, 503, 504
            if (-not $retryable -or $attempt -eq $MaxAttempts) {
                throw "ADO call failed ($Method $Uri): $($_.Exception.Message)"
            }
            $delay = [math]::Min(30, [math]::Pow(2, $attempt))
            Write-Warning "HTTP $status from $Uri - retrying in ${delay}s ($attempt/$MaxAttempts)."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CommentFormat {
    # The comment's format as the API reports it (markdown | html). Comments predating
    # the markdown feature may not carry the property; they are html.
    param($Comment)
    if ($Comment.PSObject.Properties['format'] -and $Comment.format) { [string]$Comment.format } else { 'html' }
}

function Set-TargetComment {
    # PATCH a comment preserving its format. The CommentUpdate body carries ONLY text;
    # format goes as a QUERY parameter ('Update Work Item Comment'), and omitting it
    # saves the comment as html - which is precisely the bug this engine exists to fix,
    # re-inflicted on the comment's own rendering.
    param(
        [int]$Id,
        [int]$CommentId,
        [string]$Text,
        [ValidateSet('markdown', 'html')] [string]$Format
    )
    $uri = "$targetBase/_apis/wit/workItems/$Id/comments/$CommentId`?format=$Format&api-version=7.1-preview.4"
    Invoke-AdoRest -Uri $uri -Headers $targetHeaders -Method Patch -Body (@{ text = $Text } | ConvertTo-Json) | Out-Null
}

# ─── Setup ───────────────────────────────────────────────────────────────────

$sourceOrg = Get-OrgName -Url $SourceOrgUrl
$targetOrg = Get-OrgName -Url $TargetOrgUrl
$sourceHeaders = Get-AuthHeader -Token (Resolve-Pat -Explicit $SourcePat -Org $sourceOrg -Side 'Source')
$targetHeaders = Get-AuthHeader -Token (Resolve-Pat -Explicit $TargetPat -Org $targetOrg -Side 'Target')
$targetBase = '{0}/{1}' -f $TargetOrgUrl.TrimEnd('/'), [uri]::EscapeDataString($TargetProject)

# Attachment URLs under the SOURCE org, wherever they sit in the comment text -
# inside ![name](url) / [name](url) markdown or bare. The guid is the attachment
# id; fileName arrives as a query parameter. [^)\s"'<>\]] stops the match at a
# markdown closing paren, whitespace, or an HTML delimiter.
$sourceRoot = [regex]::Escape($SourceOrgUrl.TrimEnd('/'))
$attachmentPattern = "(?i)$sourceRoot/[^)\s`"'<>\]]*_apis/wit/attachments/(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[^)\s`"'<>\]]*"

# A real html comment references attachments as <a href>/<img>; the presence of these
# tags is what separates genuine html from markdown mis-flagged or mangled as html.
$htmlTagPattern = '(?i)<(?:div|p|br|span|a|img|table|ul|ol|li)\b'

# ADO's convert-to-markdown button escapes what it sees as literal punctuation, so a
# comment converted through the UI ends up as !\[image.png\](...\_apis/...): markdown
# syntax turned into text ABOUT markdown syntax, rendering as literal characters. An
# ESCAPED image/link wrapped around an attachments URL never occurs naturally.
$escapedSignature = '!\\\[[^\]]*\\\]\([^)]*(?:\\_|_)apis/wit/attachments/[^)]*\)'

New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$changesCsv = Join-Path $OutputFolder "$stamp-comment-attachment-changes.csv"
$unresolvedCsv = Join-Path $OutputFolder "$stamp-comment-attachment-unresolved.csv"

$mode = if ($Commit) { 'COMMIT' } else { 'PREVIEW (no uploads, no comment edits - pass -Commit to apply)' }
Write-Host "==> Comment attachment link fix: $sourceOrg -> $targetOrg/$TargetProject  [$mode]" -ForegroundColor Cyan

# ─── Remedial mode: restore markdown format flipped by a pre-fix run ─────────
# An earlier version of this engine PATCHed comments without the format query
# parameter, which saves a markdown comment back as html: the text is fine but the
# UI renders the markdown syntax literally until someone clicks convert-to-markdown.
# Given that run's changes CSV, re-mark those comments. Guard: a comment whose text
# contains HTML tags is skipped - it may genuinely have been html, and re-marking it
# markdown would mangle it; those few are for eyes, not automation.
if ($RepairFormatCsv) {
    if (-not (Test-Path -LiteralPath $RepairFormatCsv)) { throw "Changes CSV not found: $RepairFormatCsv" }
    $rows = Import-Csv -LiteralPath $RepairFormatCsv |
        Where-Object { $_.WorkItemId -and $_.CommentId } |
        Group-Object WorkItemId, CommentId | ForEach-Object { $_.Group[0] }
    Write-Host "==> Format repair: $(@($rows).Count) comment(s) from $RepairFormatCsv" -ForegroundColor Cyan

    $repaired = 0; $skipped = 0; $done = 0
    foreach ($row in $rows) {
        $wi = [int]$row.WorkItemId; $cid = [int]$row.CommentId
        $done++
        Write-Progress -Activity 'Comment format repair' -Status ("[{0}/{1}] WI {2} comment {3}" -f $done, @($rows).Count, $wi, $cid) -PercentComplete ([math]::Min(100, 100 * $done / [math]::Max(1, @($rows).Count)))
        $comment = Invoke-AdoRest -Uri "$targetBase/_apis/wit/workItems/$wi/comments/$cid`?api-version=7.1-preview.4" -Headers $targetHeaders
        $format = Get-CommentFormat $comment
        if ($format -eq 'markdown') {
            Write-Host "  WI $wi comment ${cid}: already markdown - nothing to do" -ForegroundColor DarkGray
            continue
        }
        if ([string]$comment.text -match $htmlTagPattern) {
            $skipped++
            Write-Warning "WI $wi comment ${cid}: text contains HTML tags; may genuinely be html - review it by hand."
            continue
        }
        $repaired++
        Write-Host "  WI $wi comment ${cid}: html -> markdown" -ForegroundColor DarkGray
        if ($Commit) {
            Set-TargetComment -Id $wi -CommentId $cid -Text ([string]$comment.text) -Format 'markdown'
        }
    }
    $verb = if ($Commit) { 're-marked' } else { 'would re-mark' }
    Write-Host "==> Format repair: $verb $repaired comment(s) as markdown; $skipped skipped for hand review." -ForegroundColor $(if ($skipped) { 'Yellow' } else { 'Green' })
    if (-not $Commit -and $repaired) {
        Write-Host '    Preview only - re-run with -Commit to apply.' -ForegroundColor Yellow
    }
    return
}

# ─── 1. Work items with comments ─────────────────────────────────────────────

$ids = if ($WorkItemId) {
    @($WorkItemId)
}
else {
    # WIQL caps a query at 20000 results, so page on [System.Id] rather than
    # trusting one query to see everything.
    $collected = [System.Collections.Generic.List[int]]::new()
    $lastId = 0
    while ($true) {
        $wiql = "Select [System.Id] From WorkItems Where [System.TeamProject] = '$TargetProject' And [System.CommentCount] > 0 And [System.Id] > $lastId Order By [System.Id]"
        $result = Invoke-AdoRest -Uri "$targetBase/_apis/wit/wiql?`$top=19999&api-version=7.1" -Headers $targetHeaders -Method Post -Body (@{ query = $wiql } | ConvertTo-Json)
        $batch = @($result.workItems | ForEach-Object { [int]$_.id })
        if (-not $batch.Count) { break }
        $batch | ForEach-Object { $collected.Add($_) }
        $lastId = $batch[-1]
        if ($batch.Count -lt 19999) { break }
    }
    $collected
}
Write-Host "==> $(@($ids).Count) work item(s) with comments to scan." -ForegroundColor Cyan

# ─── Checkpoint: resume an interrupted commit run ────────────────────────────
# WIQL returns ids ascending, so a high-water mark of the last COMPLETED work item is
# enough to resume. Only a committed full scan checkpoints: preview writes nothing (a
# preview 'completed' id must never make a later commit skip it), and a -WorkItemId run
# is a targeted test. The file lives in the output folder as *.checkpoint.json, which
# workspace .gitignores already exclude, and is deleted when a run completes - the scan
# is idempotent, so a fresh full run is always safe.
$useCheckpoint = $Commit -and -not $WorkItemId
$checkpointPath = Join-Path $OutputFolder ("comment-attachment-links-{0}.checkpoint.json" -f ($TargetProject -replace '[^A-Za-z0-9.\-]', '_'))
if ($useCheckpoint -and $Restart -and (Test-Path -LiteralPath $checkpointPath)) {
    Remove-Item -LiteralPath $checkpointPath -Force
    Write-Host '==> -Restart: checkpoint cleared, starting over.' -ForegroundColor Yellow
}
if ($useCheckpoint -and (Test-Path -LiteralPath $checkpointPath)) {
    $cp = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    if ($cp.sourceOrg -eq $SourceOrgUrl.TrimEnd('/') -and $cp.targetOrg -eq $TargetOrgUrl.TrimEnd('/') -and $cp.targetProject -eq $TargetProject) {
        $before = @($ids).Count
        $ids = @($ids | Where-Object { $_ -gt [int]$cp.lastCompletedId })
        Write-Host ("==> Resuming after WI {0} (checkpoint {1}): {2} of {3} work item(s) remain. -Restart to start over." -f `
                $cp.lastCompletedId, $cp.updatedAt, @($ids).Count, $before) -ForegroundColor Yellow
    }
    else {
        Write-Warning "Checkpoint at $checkpointPath belongs to a different source/target; ignoring it."
    }
}

# ─── 2. Scan comments, migrate attachments, rewrite links ────────────────────

# One source attachment can be referenced from many comments; migrate it once.
$attachmentMap = @{}     # source guid -> new target URL (or $null when unresolved)
$changes = [System.Collections.Generic.List[object]]::new()
$unresolved = [System.Collections.Generic.List[object]]::new()
$scannedComments = 0
$editedComments = 0
$formatRepairs = 0

# Progress: a live bar with rate and ETA, plus a console heartbeat every 60 seconds so
# a transcript (or a glance at a scrolled-away window) still shows movement.
$total = @($ids).Count
$processed = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$lastBeat = [TimeSpan]::Zero

foreach ($id in $ids) {
    $processed++
    $rate = if ($stopwatch.Elapsed.TotalMinutes -gt 0) { $processed / $stopwatch.Elapsed.TotalMinutes } else { 0 }
    $eta = if ($rate -gt 0 -and $total -gt $processed) { [TimeSpan]::FromMinutes(($total - $processed) / $rate).ToString('hh\:mm\:ss') } else { '--:--:--' }
    if ($total -gt 0) {
        Write-Progress -Activity "Comment attachment link fix: $TargetProject" `
            -Status ("[{0}/{1}] WI {2}   {3:N1} wi/min   ETA {4}" -f $processed, $total, $id, $rate, $eta) `
            -PercentComplete ([math]::Min(100, 100 * $processed / $total))
    }
    if (($stopwatch.Elapsed - $lastBeat).TotalSeconds -ge 60) {
        $lastBeat = $stopwatch.Elapsed
        Write-Host ("  [{0}/{1}] WI {2} | {3:N1} wi/min | elapsed {4} | ETA {5} | {6} comment(s) scanned, {7} edited, {8} healed, {9} unresolved" -f `
                $processed, $total, $id, $rate, $stopwatch.Elapsed.ToString('hh\:mm\:ss'), $eta, $scannedComments, $editedComments, $formatRepairs, $unresolved.Count) -ForegroundColor Cyan
    }
    # Comments API pages with a continuation token.
    $comments = [System.Collections.Generic.List[object]]::new()
    $continuation = $null
    do {
        $uri = "$targetBase/_apis/wit/workItems/$id/comments?`$top=200&api-version=7.1-preview.4"
        if ($continuation) { $uri += "&continuationToken=$continuation" }
        $page = Invoke-AdoRest -Uri $uri -Headers $targetHeaders
        if ($page.comments) { $page.comments | ForEach-Object { $comments.Add($_) } }
        $continuation = if ($page.PSObject.Properties['continuationToken']) { $page.continuationToken } else { $null }
    } while ($continuation)

    foreach ($comment in $comments) {
        $scannedComments++
        $text = [string]$comment.text
        $newText = $text

        # Escaped-markdown healing: undo the convert-to-markdown button's escaping when
        # the comment carries the escaped-attachment signature. The button escaped the
        # whole comment, so the whole comment is unescaped - the standard CommonMark
        # inverse, backslash before any ASCII punctuation. A comment that mixes the
        # signature with real HTML tags is a hybrid for eyes, not automation.
        $unescaped = $false
        if ($newText -match $escapedSignature) {
            if ($newText -match $htmlTagPattern) {
                Write-Warning "WI ${id} comment $($comment.id): escaped markdown AND html tags together - review by hand."
            }
            else {
                $newText = [regex]::Replace($newText, '\\([!-/:-@\[-`{-~])', '$1')
                $unescaped = $true
            }
        }

        # Not named $matches: -match above writes the automatic $Matches variable,
        # and shadowing it invites exactly that collision. Matched against the
        # UNESCAPED text, so an escaped source link is found and rewritten too.
        $linkMatches = @([regex]::Matches($newText, $attachmentPattern))

        # NO early continue when nothing matches: a half-fixed comment has no source
        # links left by definition - its links were already rewritten - and skipping
        # here is exactly how the format-repair detection below never ran.
        $rewrittenHere = 0
        foreach ($match in ($linkMatches | Sort-Object { $_.Value } -Unique)) {
            $sourceUrl = $match.Value
            $guid = $match.Groups['guid'].Value

            # File name from the source URL's query string; the guid failing that.
            $fileName = $guid
            if ($sourceUrl -match '(?i)[?&]fileName=(?<f>[^&)\s]+)') {
                $fileName = [uri]::UnescapeDataString($Matches['f'])
            }

            if (-not $attachmentMap.ContainsKey($guid)) {
                $attachmentMap[$guid] = $null
                if ($Commit) {
                    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("caf-" + $guid)
                    try {
                        Invoke-AdoRest -Uri $sourceUrl -Headers $sourceHeaders -OutFile $temp | Out-Null
                        $uploadUri = "$targetBase/_apis/wit/attachments?fileName=$([uri]::EscapeDataString($fileName))&api-version=7.1"
                        $uploaded = Invoke-AdoRest -Uri $uploadUri -Headers $targetHeaders -Method Post `
                            -Body ([System.IO.File]::ReadAllBytes($temp)) -ContentType 'application/octet-stream'
                        $attachmentMap[$guid] = $uploaded.url
                    }
                    catch {
                        Write-Warning "WI ${id}: could not migrate attachment '$fileName' ($guid): $($_.Exception.Message)"
                    }
                    finally {
                        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    # Preview: the new guid does not exist yet, record the shape.
                    $attachmentMap[$guid] = "$targetBase/_apis/wit/attachments/<new-guid>?fileName=$([uri]::EscapeDataString($fileName))"
                }
            }

            $newUrl = $attachmentMap[$guid]
            if ($null -eq $newUrl) {
                $unresolved.Add([pscustomobject]@{
                        WorkItemId = $id; CommentId = $comment.id; FileName = $fileName
                        SourceUrl = $sourceUrl; Reason = 'download or upload failed'
                    })
                continue
            }

            $newText = $newText.Replace($sourceUrl, $newUrl)
            $rewrittenHere++
            $changes.Add([pscustomobject]@{
                    WorkItemId = $id; CommentId = $comment.id; FileName = $fileName
                    SourceUrl = $sourceUrl; TargetUrl = $newUrl
                    CommentFormat = (Get-CommentFormat $comment)
                    Applied = [bool]$Commit
                })
        }

        # Half-fixed detection: a run made before the format fix rewrote this comment's
        # links (so nothing above matched) but saved it as html, leaving markdown syntax
        # rendering literally. The state is unambiguous without any CSV: format says html,
        # the text has NO html tags, but it DOES carry a markdown-syntax attachment link -
        # genuine html comments reference attachments as <a href>/<img>, never as ![](...).
        $format = Get-CommentFormat $comment
        $formatRepair = $unescaped -or ($format -eq 'html' -and
            $newText -notmatch $htmlTagPattern -and
            $newText -match '!?\[[^\]]*\]\([^)]*_apis/wit/attachments/[^)]*\)')

        if ($newText -ne $text -or $formatRepair) {
            $editedComments++
            $writeFormat = if ($formatRepair) { 'markdown' } else { $format }
            $note = if ($unescaped) { $formatRepairs++; '; unescaping mangled markdown' }
            elseif ($formatRepair) { $formatRepairs++; '; re-marking html -> markdown' }
            else { '' }
            Write-Host ("  WI {0} comment {1}: {2} link(s){3}" -f $id, $comment.id, $rewrittenHere, $note) -ForegroundColor DarkGray
            if ($formatRepair) {
                $changes.Add([pscustomobject]@{
                        WorkItemId = $id; CommentId = $comment.id
                        FileName = if ($unescaped) { '(markdown unescape)' } else { '(format repair)' }
                        SourceUrl = ''; TargetUrl = ''
                        CommentFormat = "$format -> markdown"
                        Applied = [bool]$Commit
                    })
            }
            if ($Commit) {
                Set-TargetComment -Id $id -CommentId $comment.id -Text $newText -Format $writeFormat
            }
        }
    }

    # This work item is fully processed - move the high-water mark. Written per item:
    # the whole point is surviving a crash mid-run.
    if ($useCheckpoint) {
        @{
            sourceOrg       = $SourceOrgUrl.TrimEnd('/')
            targetOrg       = $TargetOrgUrl.TrimEnd('/')
            targetProject   = $TargetProject
            lastCompletedId = $id
            completed       = $processed
            updatedAt       = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $checkpointPath
    }
}

Write-Progress -Activity "Comment attachment link fix: $TargetProject" -Completed
# A completed run clears its checkpoint: the scan is idempotent, so the next full run
# starting from scratch is correct - only an INTERRUPTED run should resume.
if ($useCheckpoint -and (Test-Path -LiteralPath $checkpointPath)) {
    Remove-Item -LiteralPath $checkpointPath -Force
}

# ─── 3. Report ───────────────────────────────────────────────────────────────

$changes | Export-Csv -LiteralPath $changesCsv -NoTypeInformation
$unresolved | Export-Csv -LiteralPath $unresolvedCsv -NoTypeInformation

$verb = if ($Commit) { 'rewrote' } else { 'would rewrite' }
$repairVerb = if ($Commit) { 're-marked' } else { 'would re-mark' }
$linkCount = @($changes | Where-Object { $_.FileName -notin '(format repair)', '(markdown unescape)' }).Count
Write-Host ''
$avgRate = if ($stopwatch.Elapsed.TotalMinutes -gt 0) { $processed / $stopwatch.Elapsed.TotalMinutes } else { 0 }
Write-Host ("==> Scanned {0} comment(s) across {1} work item(s) in {2} ({3:N1} wi/min); {4} {5} link(s) in {6} comment(s); {7} distinct attachment(s); {8} {9} half-fixed comment(s) as markdown; {10} unresolved." -f `
        $scannedComments, $processed, $stopwatch.Elapsed.ToString('hh\:mm\:ss'), $avgRate, $verb, $linkCount, $editedComments, $attachmentMap.Count, $repairVerb, $formatRepairs, $unresolved.Count) -ForegroundColor $(if ($unresolved.Count) { 'Yellow' } else { 'Green' })
Write-Host "    changes    : $changesCsv"
Write-Host "    unresolved : $unresolvedCsv"
if (-not $Commit -and $changes.Count) {
    Write-Host '    Preview only - nothing was uploaded or edited. Re-run with -Commit to apply.' -ForegroundColor Yellow
}
if ($unresolved.Count) {
    Write-Warning 'Some attachments could not be migrated; their links were left unchanged so a re-run can retry them.'
}
