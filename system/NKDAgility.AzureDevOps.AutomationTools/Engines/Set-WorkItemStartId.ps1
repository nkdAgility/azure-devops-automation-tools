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
    large gap can take many requests. Creations are issued in batches of
    -BatchSize to reduce overhead, and the batch is trimmed automatically as the
    target is approached so the counter is not overshot by more than one.

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
    Number of work items to create before re-evaluating progress. The batch is
    automatically trimmed near the target. Default: 50.

.PARAMETER MaxRetries
    Maximum number of times a single throttled request (HTTP 429/5xx or the
    Azure DevOps CircuitBreakerExceededConcurrency exception) is retried before
    the run aborts. Default: 8.

.PARAMETER MaxBackoffSeconds
    Upper bound, in seconds, for the exponential backoff delay between retries.
    A server-provided Retry-After header is honoured when present but still
    capped by this value. Default: 60.

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
    [int]$BatchSize = 50,

    [ValidateRange(0, 20)]
    [int]$MaxRetries = 8,

    [ValidateRange(1, 600)]
    [double]$MaxBackoffSeconds = 60
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
$createUri = "$collectionBase/$Project/_apis/wit/workitems/`$$WorkItemType`?api-version=$apiVersion"

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
            $resp = $_.Exception.Response
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

function New-ThrowawayWorkItem {
    # Creates a single work item and returns its assigned ID.
    $body = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
    ) | ConvertTo-Json -Depth 5 -AsArray
    $wi = Invoke-AdoRestWithRetry -RequestArgs @{
        Uri         = $createUri
        Headers     = $script:Headers
        Method      = 'Post'
        Body        = $body
        ContentType = 'application/json-patch+json'
    }
    [int]$wi.id
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

$lastId = 0
$consumed = 0
$startTime = Get-Date
$startId = 0

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

    for ($i = 0; $i -lt $count; $i++) {
        $id = New-ThrowawayWorkItem
        $consumed++
        try {
            Remove-WorkItem -Id $id
        }
        catch {
            Write-Warning "Failed to destroy work item $id ($($_.Exception.Message)). It may need to be removed manually from the recycle bin."
        }
        if ($id -gt $lastId) { $lastId = $id }
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
                Write-Step "Need to consume $($target - $lastId) more ID(s) to reach $MinId."
            }
        }

        $elapsed = (Get-Date) - $startTime
        $rate = if ($elapsed.TotalMinutes -gt 0) { $consumed / $elapsed.TotalMinutes } else { 0 }
        $idsToGo = [Math]::Max(0, $target - $lastId)
        $spanTotal = [Math]::Max(1, $target - $startId)
        $spanDone = [Math]::Max(0, $lastId - $startId)
        $percent = [Math]::Min(100, [int](($spanDone / $spanTotal) * 100))

        if ($rate -gt 0 -and $idsToGo -gt 0) {
            $etaMin = $idsToGo / $rate
            $eta = [TimeSpan]::FromMinutes($etaMin)
            $etaText = '{0:hh\:mm\:ss}' -f $eta
            $finishText = (Get-Date).Add($eta).ToString('HH:mm:ss')
        }
        else {
            $etaText = '--:--:--'
            $finishText = '--:--:--'
        }

        Write-Progress -Activity "Advancing work item ID counter in '$org'" `
            -Status ("ID {0} / {1}  |  {2:n0}/min  |  {3} consumed  |  ETA {4} (~{5})" -f `
                $lastId, $target, $rate, $consumed, $etaText, $finishText) `
            -PercentComplete $percent

        if ($lastId -ge $target) { break }
    }
}

Write-Progress -Activity "Advancing work item ID counter in '$org'" -Completed

$totalElapsed = (Get-Date) - $startTime
Write-Step ("Done in {0:hh\:mm\:ss}. Highest ID consumed: {1} ({2} created). The next work item will have ID >= {3}." -f `
        $totalElapsed, $lastId, $consumed, $MinId)
$lastId

