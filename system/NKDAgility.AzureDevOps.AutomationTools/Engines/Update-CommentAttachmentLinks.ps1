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
    the token - the same trade the migration itself already made.

    Attachments whose download fails (deleted at source, source already gone,
    permissions) are reported in the unresolved CSV and their links are left
    unchanged, so a later re-run can pick them up.

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

.PARAMETER OutputFolder
    Where the evidence CSVs are written. Defaults to .\output. Two files per
    run, timestamped: *-comment-attachment-changes.csv and
    *-comment-attachment-unresolved.csv.

.EXAMPLE
    .\Update-CommentAttachmentLinks.ps1 -SourceOrgUrl https://dev.azure.com/georgfischer `
        -TargetOrgUrl https://dev.azure.com/machining -TargetProject UM-MIKRON-Milling

    Preview: report every markdown attachment link still pointing at the source.

.EXAMPLE
    .\Update-CommentAttachmentLinks.ps1 -SourceOrgUrl https://dev.azure.com/georgfischer `
        -TargetOrgUrl https://dev.azure.com/machining -TargetProject UM-MIKRON-Milling `
        -WorkItemId 1204, 1381 -Commit

    Migrate and rewrite on two known-affected work items first.
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

    [string]$OutputFolder = (Join-Path (Get-Location).Path 'output')
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

New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$changesCsv = Join-Path $OutputFolder "$stamp-comment-attachment-changes.csv"
$unresolvedCsv = Join-Path $OutputFolder "$stamp-comment-attachment-unresolved.csv"

$mode = if ($Commit) { 'COMMIT' } else { 'PREVIEW (no uploads, no comment edits - pass -Commit to apply)' }
Write-Host "==> Comment attachment link fix: $sourceOrg -> $targetOrg/$TargetProject  [$mode]" -ForegroundColor Cyan

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

# ─── 2. Scan comments, migrate attachments, rewrite links ────────────────────

# One source attachment can be referenced from many comments; migrate it once.
$attachmentMap = @{}     # source guid -> new target URL (or $null when unresolved)
$changes = [System.Collections.Generic.List[object]]::new()
$unresolved = [System.Collections.Generic.List[object]]::new()
$scannedComments = 0
$editedComments = 0

foreach ($id in $ids) {
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
        # Not named $matches: -match below writes the automatic $Matches variable,
        # and shadowing it invites exactly that collision.
        $linkMatches = @([regex]::Matches($text, $attachmentPattern))
        if (-not $linkMatches.Count) { continue }

        $newText = $text
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
                    Applied = [bool]$Commit
                })
        }

        if ($rewrittenHere -and $newText -ne $text) {
            $editedComments++
            Write-Host ("  WI {0} comment {1}: {2} link(s)" -f $id, $comment.id, $rewrittenHere) -ForegroundColor DarkGray
            if ($Commit) {
                # format is preserved when the API reports it (markdown comments do).
                $body = @{ text = $newText }
                if ($comment.PSObject.Properties['format'] -and $comment.format) { $body.format = $comment.format }
                Invoke-AdoRest -Uri "$targetBase/_apis/wit/workItems/$id/comments/$($comment.id)?api-version=7.1-preview.4" `
                    -Headers $targetHeaders -Method Patch -Body ($body | ConvertTo-Json) | Out-Null
            }
        }
    }
}

# ─── 3. Report ───────────────────────────────────────────────────────────────

$changes | Export-Csv -LiteralPath $changesCsv -NoTypeInformation
$unresolved | Export-Csv -LiteralPath $unresolvedCsv -NoTypeInformation

$verb = if ($Commit) { 'rewrote' } else { 'would rewrite' }
Write-Host ''
Write-Host ("==> Scanned {0} comment(s) across {1} work item(s); {2} {3} link(s) in {4} comment(s); {5} distinct attachment(s); {6} unresolved." -f `
        $scannedComments, @($ids).Count, $verb, $changes.Count, $editedComments, $attachmentMap.Count, $unresolved.Count) -ForegroundColor $(if ($unresolved.Count) { 'Yellow' } else { 'Green' })
Write-Host "    changes    : $changesCsv"
Write-Host "    unresolved : $unresolvedCsv"
if (-not $Commit -and $changes.Count) {
    Write-Host '    Preview only - nothing was uploaded or edited. Re-run with -Commit to apply.' -ForegroundColor Yellow
}
if ($unresolved.Count) {
    Write-Warning 'Some attachments could not be migrated; their links were left unchanged so a re-run can retry them.'
}
