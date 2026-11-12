<#
.SYNOPSIS
    Advances an Azure DevOps organisation's work item ID counter so that the
    next work item created will have an ID of at least -MinId.

.DESCRIPTION
    Azure DevOps assigns work item IDs from a single sequence that is shared by
    every project in the organisation, and the sequence can only ever move
    forward. When migrating work items into a fresh organisation it is often
    desirable for the new IDs to line up with (or sit above) the IDs used in the
    source organisation. There is no API to set the counter directly, so the
    only way to advance it is to consume IDs by creating work items.

    This script repeatedly creates throwaway work items and immediately destroys
    them (permanently, so they do not linger in the recycle bin) until a created
    work item reaches ID (MinId - 1). At that point the counter is positioned so
    the next *real* work item created anywhere in the organisation will have an
    ID of at least -MinId.

    Because each work item creation only advances the counter by one, closing a
    large gap takes many work items. Each batch of -BatchSize (1 to 200) is ONE
    create call through the work item $batch endpoint and ONE bulk destroy
    call, and the batch is trimmed automatically as the target is approached so
    the counter is not overshot. Throwaway items left by a run stopped between
    those two calls are found by title and destroyed at the start of the next.

    Authentication is ambient-identity first, stored token as the fallback:
    Entra by default. When the automation module is loaded the script acquires
    an Entra access token via Get-AzureDevOpsAccessToken, re-resolved before
    every batch so the module's cache renews it near expiry across a long run.
    The fallbacks are -Pat, then the AZDO_PAT_<ORG> environment variable
    populated by Set-AutomationSecrets. Whichever identity is used needs Work
    Items (Read, Write & Manage) so it can both create and permanently destroy
    work items.

.PARAMETER OrgUrl
    Organisation URL, e.g. https://dev.azure.com/contoso.

.PARAMETER Project
    Project in which the throwaway work items are created. Any project works;
    the ID sequence is organisation-wide.

.PARAMETER MinId
    The minimum ID the next created work item should have. The script advances
    the counter until a throwaway work item reaches (MinId - 1).

.PARAMETER Pat
    Fallback Personal Access Token with Work Items (Read, Write & Manage), used
    when Entra sign-in is unavailable or fails. Defaults to the AZDO_PAT_<ORG>
    environment variable derived from the organisation name.

.PARAMETER TenantId
    Deprecated and ignored: the module's Get-AzureDevOpsAccessToken discovers
    the organisation's tenant automatically and pins the sign-in to it. Kept so
    existing runbook lines that pass it keep working.

.PARAMETER WorkItemType
    Work item type to create for the throwaway items. Default: Task.

.PARAMETER Title
    Title used for the throwaway work items. Default marks them as temporary.

.PARAMETER BatchSize
    Work items per create request and per destroy request, 1 to 200 (the $batch
    limit). 1 behaves like the old one-at-a-time loop. The batch is trimmed near
    the target. Default: 200.

.PARAMETER MaxRetries
    Maximum number of times a single throttled request (HTTP 429/5xx or the
    Azure DevOps CircuitBreakerExceededConcurrency exception) is retried before
    the run aborts. Default: 8.

.PARAMETER MaxBackoffSeconds
    Upper bound, in seconds, for the exponential backoff delay between retries.
    A server-provided Retry-After header is honoured when present but still
    capped by this value. Default: 60.

.PARAMETER LogEveryMinutes
    How often a plain progress line (counter, rate, ETA, finish time) is written
    to the console, so the run log records progress; the progress bar itself
    is not recorded. Default: 5.

.EXAMPLE
    # Ambient identity: Entra, no PAT.
    .\Set-WorkItemStartId.ps1 -OrgUrl https://dev.azure.com/machining -Project Milling -MinId 100000

.EXAMPLE
    # Fallback PAT from the workspace secrets (Set-AutomationSecrets exports
    # AZDO_PAT_<ORG>), previewed first.
    Set-AutomationSecrets
    .\Set-WorkItemStartId.ps1 -OrgUrl https://dev.azure.com/machining -Project Milling -MinId 100000 -WhatIf

.OUTPUTS
    The highest work item ID that was consumed. The next work item created will
    have an ID greater than this value (i.e. >= MinId).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$OrgUrl,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MinId,

    [string]$Pat,

    [string]$TenantId,

    [string]$WorkItemType = 'Task',

    [string]$Title = 'TEMP - ID reservation (safe to delete)',

    [ValidateRange(1, 200)]
    [int]$BatchSize = 200,

    [ValidateRange(0, 20)]
    [int]$MaxRetries = 8,

    [ValidateRange(1, 600)]
    [double]$MaxBackoffSeconds = 60,

    [ValidateRange(1, 1440)]
    [int]$LogEveryMinutes = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers ---------------------------------------------------------------

function Get-OrgName {
    param([string]$Url)
    ($Url.TrimEnd('/') -split '/')[-1]
}

function Get-DerivedEnvVarName {
    param([string]$Org)
    'AZDO_PAT_' + ($Org.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
}

function Get-BasicAuthHeader {
    param([string]$Token)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Token")
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
}

function Initialize-Auth {
    # Credential resolution lives in the module (Resolve-AzureDevOpsAuth) so every engine
    # answers "which credential here" identically: a supplied PAT wins, an on-premises
    # host uses Windows integrated auth, the hosted service uses Entra.
    #
    # The derived AZDO_PAT_<ORG> variable that Set-AutomationSecrets exports counts as a
    # supplied PAT, so it is resolved BEFORE the call - running Set-AutomationSecrets is
    # naming a credential just as deliberately as passing -Pat.
    #
    # Called before every batch, not just once: the module caches the Entra token and
    # renews it near expiry, so a long ID-consuming run stays authenticated.
    $pat = $Pat
    if ([string]::IsNullOrWhiteSpace($pat)) {
        $pat = [System.Environment]::GetEnvironmentVariable((Get-DerivedEnvVarName -Org $org))
    }

    $auth = Resolve-AzureDevOpsAuth -Collection $OrgUrl -Pat $pat
    if ($script:AuthMode -ne $auth.Mode) {
        Write-Host "==> Auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:AuthMode = $auth.Mode
    }
    $script:Headers = $auth.Headers
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# $org names things (messages, the AZDO_PAT_<ORG> variable); $collectionBase is
# what URLs are built from. The organisation URL IS the API base - hosted and
# on-premises alike - so it is never rebuilt against a hardcoded dev.azure.com,
# which would aim an on-premises run at a same-named PUBLIC organisation.
$org = Get-OrgName -Url $OrgUrl
$collectionBase = $OrgUrl.TrimEnd('/')

if ($TenantId) {
    Write-Warning '-TenantId is deprecated and ignored: the tenant is discovered automatically by Get-AzureDevOpsAccessToken.'
}

# Ambient-first credential resolution: Entra then the -Pat / AZDO_PAT_<ORG>
# fallbacks, renewed per batch (see Initialize-Auth).
$script:AuthMode = $null
Initialize-Auth

$apiVersion = '7.1'
$projectSegment = [Uri]::EscapeDataString($Project)

function Invoke-AdoRestWithRetry {
    # Wraps Invoke-RestMethod with exponential backoff so transient Azure DevOps
    # throttling (HTTP 429, HTTP 503, or the CircuitBreakerExceededConcurrency
    # exception) is retried instead of aborting the run. Honours a Retry-After
    # header when present, otherwise backs off exponentially with jitter up to
    # -MaxBackoffSeconds. Non-transient errors are rethrown immediately.
    param([hashtable]$RequestArgs)

    # An empty header set is how Windows integrated auth is expressed: there is no
    # credential to attach, so ask the stack to negotiate one. Without this the request
    # goes out anonymous and an on-premises collection answers 401. Applied here, once,
    # so every call site inherits it.
    if ($RequestArgs.ContainsKey('Headers') -and
        (-not $RequestArgs.Headers -or $RequestArgs.Headers.Count -eq 0)) {
        $RequestArgs.Remove('Headers')
        $RequestArgs.UseDefaultCredentials = $true
    }

    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod @RequestArgs
        }
        catch {
            $attempt++
            # Not every exception carries a Response (only web errors do); under
            # StrictMode reading a missing property throws and hides the real error.
            $respProp = $_.Exception.PSObject.Properties['Response']
            $resp = if ($respProp) { $respProp.Value } else { $null }
            $status = $null
            if ($resp -and ($resp.PSObject.Properties.Name -contains 'StatusCode')) {
                $status = [int]$resp.StatusCode
            }
            $isThrottle = ($status -in 429, 500, 502, 503, 504) -or
                ($_.Exception.Message -match 'CircuitBreaker|currently unavailable|TF10216|throttl')

            if (-not $isThrottle -or $attempt -gt $MaxRetries) { throw }

            # Prefer the server-provided Retry-After when available.
            $retryAfter = $null
            if ($resp -and ($resp.PSObject.Properties.Name -contains 'Headers')) {
                try { $retryAfter = [double]$resp.Headers['Retry-After'] } catch { }
            }
            if ($retryAfter -and $retryAfter -gt 0) {
                $delay = [Math]::Min($retryAfter, $MaxBackoffSeconds)
            }
            else {
                # Exponential backoff (2^attempt) with random jitter, capped.
                $base = [Math]::Min([Math]::Pow(2, $attempt), $MaxBackoffSeconds)
                $delay = [Math]::Min($base + (Get-Random -Minimum 0.0 -Maximum 1.0), $MaxBackoffSeconds)
            }

            Write-Warning ("Azure DevOps throttled the request (attempt {0}/{1}). Backing off {2:n1}s..." -f `
                    $attempt, $MaxRetries, $delay)
            Start-Sleep -Seconds $delay
        }
    }
}

function New-ThrowawayWorkItemBatch {
    # Creates -Count work items in ONE request through the work item $batch
    # endpoint (up to 200 operations per call) and returns the IDs it assigned.
    # One round trip per batch instead of one per work item: creating one at a
    # time ran at ~23 IDs a minute against slb-swt (2026-11-12).
    # Errors for individual operations come back per item; they are returned,
    # not thrown, so the caller can destroy whatever was created first.
    param([int]$Count)
    # Every new work item in one $batch needs its own temporary ID (-1, -2, ...);
    # without it they all default to -1 and the batch is refused (VS403357).
    $requests = foreach ($n in 1..$Count) {
        @{
            method  = 'PATCH'
            uri     = "/$projectSegment/_apis/wit/workitems/`$$WorkItemType`?suppressNotifications=true&api-version=$apiVersion"
            headers = @{ 'Content-Type' = 'application/json-patch+json' }
            body    = @(
                @{ op = 'add'; path = '/id'; value = -$n }
                @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
            )
        }
    }
    $resp = Invoke-AdoRestWithRetry -RequestArgs @{
        Uri         = "$collectionBase/_apis/wit/`$batch?api-version=$apiVersion"
        Headers     = $script:Headers
        Method      = 'Post'
        Body        = (ConvertTo-Json -InputObject @($requests) -Depth 8)
        ContentType = 'application/json'
    }
    $ids = [System.Collections.Generic.List[int]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($resp.value)) {
        $code = [int]$r.code
        $body = if ($r.body -is [string]) { $r.body | ConvertFrom-Json } else { $r.body }
        if ($code -ge 200 -and $code -lt 300 -and $body.id) { $ids.Add([int]$body.id) }
        else { $errors.Add("HTTP $code $($r.body)") }
    }
    @{ Ids = @($ids); Errors = @($errors) }
}

function Remove-WorkItemBatch {
    # Permanently destroys work items in one request (Work Items - Delete Work
    # Items, destroy=true), so they do not sit in the recycle bin. Falls back to
    # destroying one at a time if the bulk call is refused.
    param([int[]]$Ids)
    if (-not $Ids -or $Ids.Count -eq 0) { return }
    try {
        Invoke-AdoRestWithRetry -RequestArgs @{
            Uri         = "$collectionBase/$projectSegment/_apis/wit/workitemsdelete?api-version=7.1-preview.1"
            Headers     = $script:Headers
            Method      = 'Post'
            Body        = (@{ ids = @($Ids); destroy = $true; skipNotifications = $true } | ConvertTo-Json -Depth 4)
            ContentType = 'application/json'
        } | Out-Null
    }
    catch {
        Write-Warning "Bulk destroy refused ($($_.Exception.Message)); destroying $($Ids.Count) work item(s) one at a time."
        foreach ($id in $Ids) {
            try { Remove-WorkItem -Id $id }
            catch { Write-Warning "Failed to destroy work item $id ($($_.Exception.Message)). It may need to be removed manually." }
        }
    }
}

function Remove-LeftoverThrowawayWorkItem {
    # A run stopped between a create batch and its destroy leaves up to
    # -BatchSize throwaway items behind. Find them by their title and destroy
    # them before starting.
    $titleLiteral = $Title.Replace("'", "''")
    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Title] = '$titleLiteral'" } |
        ConvertTo-Json
    $result = Invoke-AdoRestWithRetry -RequestArgs @{
        Uri         = "$collectionBase/$projectSegment/_apis/wit/wiql?api-version=$apiVersion"
        Headers     = $script:Headers
        Method      = 'Post'
        Body        = $wiql
        ContentType = 'application/json'
    }
    $ids = @(@($result.workItems) | Where-Object { $_ } | ForEach-Object { [int]$_.id })
    if ($ids.Count -eq 0) { return }
    Write-Step "Destroying $($ids.Count) throwaway work item(s) left by an earlier run."
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        Remove-WorkItemBatch -Ids $ids[$i..([Math]::Min($i + 199, $ids.Count - 1))]
    }
}

function Test-StopRequested {
    # True when Ctrl+C was pressed since the last check. Only meaningful while
    # Ctrl+C is being read as input (see the main loop); anywhere without a
    # console it is simply never true.
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
        }
    }
    catch { }
    $false
}

function Remove-WorkItem {
    # Permanently destroys a work item so it does not sit in the recycle bin.
    param([int]$Id)
    $uri = "$collectionBase/$Project/_apis/wit/workitems/$Id`?destroy=true&api-version=$apiVersion"
    Invoke-AdoRestWithRetry -RequestArgs @{
        Uri     = $uri
        Headers = $script:Headers
        Method  = 'Delete'
    } | Out-Null
}

#endregion Helpers ------------------------------------------------------------

# We advance the counter until a created item reaches (MinId - 1); the next real
# work item then gets an ID >= MinId.
$target = $MinId - 1

if (-not $PSCmdlet.ShouldProcess(
        "org '$org' / project '$Project'",
        "Create and permanently destroy work items until an ID of $target is reached (next work item >= $MinId)")) {
    return
}

Write-Step "Advancing work item counter in '$org' so the next ID is >= $MinId."

Remove-LeftoverThrowawayWorkItem

$lastId = 0
$consumed = 0
$startTime = Get-Date
$startId = 0
$stopped = $false
$lastLogged = Get-Date

# Ctrl+C must not cut a batch in half: up to -BatchSize created items would be
# left behind. Read it as a key press instead, and stop only after the current
# batch has been destroyed. Restored in the finally block.
$ctrlCWasInput = $null
try { $ctrlCWasInput = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { }
if ($null -ne $ctrlCWasInput) { Write-Step 'Press Ctrl+C to stop cleanly after the current batch.' }

try {
while ($lastId -lt $target) {
    # Renew a near-expiry Entra token before each batch (cache hit otherwise).
    Initialize-Auth

    # First iteration probes the current position with a single item; afterwards
    # create as many as needed, capped by BatchSize and trimmed near the target.
    if ($lastId -eq 0) {
        $count = 1
    }
    else {
        $remaining = $target - $lastId
        $count = [Math]::Min($BatchSize, $remaining)
    }

    # One create call and one destroy call per batch. Whatever the create call
    # managed is destroyed before any failure is raised.
    $created = New-ThrowawayWorkItemBatch -Count $count
    $ids = @($created.Ids)
    $consumed += $ids.Count
    Remove-WorkItemBatch -Ids $ids
    if (@($created.Errors).Count -gt 0) {
        throw "Creating throwaway work items failed for $(@($created.Errors).Count) of ${count}: $(@($created.Errors)[0])"
    }
    if ($ids.Count -eq 0) { throw 'The create batch returned no work item IDs.' }

    $batchMax = ($ids | Measure-Object -Maximum).Maximum
    if ($batchMax -gt $lastId) { $lastId = [int]$batchMax }
    # Anchor the ID-gap measurement to the first observed ID so throughput
    # reflects actual counter movement, not the initial jump to $startId.
    if ($startId -eq 0) {
        $startId = $lastId
        # The very first created item reveals where the counter currently
        # sits: the next real work item would have had ID ($lastId + 1).
        Write-Step "Current work item counter is at $lastId (next new ID would be $($lastId + 1))."
        if ($lastId -ge $target) {
            Write-Step "Counter is already >= $MinId; nothing to advance."
        }
        else {
            Write-Step "Need to consume $($target - $lastId) more ID(s) to reach $MinId, in batches of $BatchSize."
        }
    }

    $elapsed = (Get-Date) - $startTime
    $rate = if ($elapsed.TotalMinutes -gt 0) { $consumed / $elapsed.TotalMinutes } else { 0 }
    $idsToGo = [Math]::Max(0, $target - $lastId)
    $spanTotal = [Math]::Max(1, $target - $startId)
    $spanDone = [Math]::Max(0, $lastId - $startId)
    $percent = [Math]::Min(100, [int](($spanDone / $spanTotal) * 100))

    if ($rate -gt 0 -and $idsToGo -gt 0) {
        $eta = [TimeSpan]::FromMinutes($idsToGo / $rate)
        # Days included: hh:mm:ss alone dropped them (a 29-day run read 22:25:15).
        $etaText = if ($eta.Days -gt 0) { '{0}d{1}h{2:00}m' -f $eta.Days, $eta.Hours, $eta.Minutes } else { '{0}h{1:00}m' -f $eta.Hours, $eta.Minutes }
        $finish = (Get-Date).Add($eta)
        $finishText = if ($finish.Date -eq (Get-Date).Date) { $finish.ToString('HH:mm') } else { $finish.ToString('ddd dd MMM HH:mm') }
    }
    else {
        $etaText = '--'
        $finishText = '--'
    }

    # Kept short, most useful first: the console cuts a progress line at its
    # width with an ellipsis, and the finish time used to be what was lost.
    $status = '{0:n0} -> {1:n0}  |  {2:n0}/min  |  ETA {3}, ~{4}  |  {5:n0} done' -f `
        $lastId, $target, $rate, $etaText, $finishText, $consumed
    Write-Progress -Activity $org -Status $status -PercentComplete $percent

    # The progress bar is not recorded by the run log, so write a plain line
    # every -LogEveryMinutes: the committed log then shows how the run went.
    if (((Get-Date) - $lastLogged).TotalMinutes -ge $LogEveryMinutes) {
        Write-Host ("==> [{0:HH:mm}] {1}  ({2}%)" -f (Get-Date), $status, $percent)
        $lastLogged = Get-Date
    }

    if ($lastId -lt $target -and (Test-StopRequested)) { $stopped = $true; break }
}
}
finally {
    if ($null -ne $ctrlCWasInput) { [Console]::TreatControlCAsInput = $ctrlCWasInput }
}

Write-Progress -Activity "Advancing work item ID counter in '$org'" -Completed

$totalElapsed = (Get-Date) - $startTime
if ($stopped) {
    Write-Step ("Stopped by Ctrl+C after a complete batch, in {0:hh\:mm\:ss}. Counter is at {1} ({2} created and destroyed); {3} ID(s) still to go to reach {4}. Run again to continue." -f `
            $totalElapsed, $lastId, $consumed, ($target - $lastId), $MinId)
}
else {
    Write-Step ("Done in {0:hh\:mm\:ss}. Highest ID consumed: {1} ({2} created). The next work item will have ID >= {3}." -f `
            $totalElapsed, $lastId, $consumed, $MinId)
}
$lastId

