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

    Authentication uses a Personal Access Token (PAT). The token needs Work
    Items (Read, Write & Manage) so it can both create and permanently destroy
    work items. Provide it with -Pat, or let the script fall back to the
    AZDO_PAT_<ORG> environment variable populated by Set-MigrationSecrets.ps1.
    When no PAT is available the script falls back to an Entra (Azure AD) access
    token: it installs the Az.Accounts module for the current user if needed,
    prompts for an interactive sign-in when no Azure context exists, and uses
    Get-AzAccessToken. Ensure the signed-in identity has the same Work Items
    permissions.

.PARAMETER OrgUrl
    Organisation URL, e.g. https://dev.azure.com/contoso.

.PARAMETER Project
    Project in which the throwaway work items are created. Any project works;
    the ID sequence is organisation-wide.

.PARAMETER MinId
    The minimum ID the next created work item should have. The script advances
    the counter until a throwaway work item reaches (MinId - 1).

.PARAMETER Pat
    Personal Access Token with Work Items (Read, Write & Manage). Defaults to
    the AZDO_PAT_<ORG> environment variable derived from the organisation name,
    and then to an Entra (Azure AD) access token when neither is available.

.PARAMETER TenantId
    Entra tenant (directory) ID to authenticate against when falling back to an
    Entra token. Set this to the tenant that backs the Azure DevOps organisation
    to avoid cross-tenant sign-in warnings/failures (e.g. from MFA or
    conditional access on unrelated tenants).

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
    .\scripts\Set-WorkItemStartId.ps1 -OrgUrl https://dev.azure.com/machining -Project Milling -MinId 100000

.EXAMPLE
    . .\scripts\Set-MigrationSecrets.ps1
    .\scripts\Set-WorkItemStartId.ps1 -OrgUrl https://dev.azure.com/machining -Project Milling -MinId 100000 -WhatIf

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

function Get-AdoTenantId {
    # Discovers the Entra tenant that backs an Azure DevOps organisation. ADO
    # returns the tenant GUID in the 'X-VSS-ResourceTenant' response header, so
    # an unauthenticated probe is enough. Pinning sign-in to this tenant avoids
    # Az enumerating (and failing MFA on) every other tenant the user can see.
    param([string]$Org)
    try {
        $resp = Invoke-WebRequest -Uri "https://dev.azure.com/$Org/_apis/connectionData?api-version=7.1-preview" `
            -Method Get -SkipHttpErrorCheck -ErrorAction Stop
        $raw = $resp.Headers['X-VSS-ResourceTenant']
        if ($raw) {
            # Header can be an array and/or comma-separated; take the first GUID.
            $tenant = (($raw -join ',') -split ',' | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -as [guid] } | Select-Object -First 1)
            return $tenant
        }
    }
    catch {
        Write-Verbose "Tenant discovery failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-BasicAuthHeader {
    param([string]$Token)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Token")
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
}

function Initialize-AzAccounts {
    # Ensures the Az.Accounts module is installed and imported. Installs it for
    # the current user (no elevation) when missing.
    if (Get-Module -Name Az.Accounts) { return }

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Step 'Az.Accounts module not found. Installing it for the current user...'
        # PowerShell Gallery requires TLS 1.2 on older configurations.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module Az.Accounts -ErrorAction Stop
}

function Get-EntraAccessToken {
    # Acquires an Entra (Azure AD) access token scoped to the Azure DevOps
    # resource using the Az.Accounts module, installing it on demand and
    # prompting for an interactive sign-in when no context exists.
    # 499b84ac-1321-427f-aa17-267ca6975798 is the well-known Azure DevOps app ID.
    $adoResource = '499b84ac-1321-427f-aa17-267ca6975798'

    Initialize-AzAccounts

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $needsConnect = -not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)
    if ($needsConnect) {
        Write-Step 'Signing in to Azure...'
        $connectArgs = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($TenantId) { $connectArgs.TenantId = $TenantId }
        Connect-AzAccount @connectArgs | Out-Null
    }

    Write-Verbose 'Acquiring Entra token via Get-AzAccessToken.'
    $tokenArgs = @{ ResourceUrl = $adoResource; ErrorAction = 'Stop' }
    if ($TenantId) { $tokenArgs.TenantId = $TenantId }
    $token = Get-AzAccessToken @tokenArgs
    # AsSecureString became the default in newer Az.Accounts versions.
    if ($token.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $token.Token).Password
    }
    return $token.Token
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$org = Get-OrgName -Url $OrgUrl

# Resolve authentication. Preference order:
#   1. Explicit -Pat.
#   2. AZDO_PAT_<ORG> environment variable (Set-MigrationSecrets.ps1).
#   3. Entra (Azure AD) access token from Az PowerShell / Azure CLI.
if ([string]::IsNullOrWhiteSpace($Pat)) {
    $envName = Get-DerivedEnvVarName -Org $org
    $Pat = [System.Environment]::GetEnvironmentVariable($envName)
    if ([string]::IsNullOrWhiteSpace($Pat)) {
        Write-Verbose "No PAT supplied and '$envName' is not set; falling back to an Entra token."
    }
    else {
        Write-Verbose "Using PAT from environment variable '$envName'."
    }
}

if ([string]::IsNullOrWhiteSpace($Pat)) {
    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        $TenantId = Get-AdoTenantId -Org $org
        if ($TenantId) {
            Write-Verbose "Discovered Entra tenant '$TenantId' for org '$org'."
        }
        else {
            Write-Warning "Could not auto-discover the tenant for org '$org'. Sign-in may enumerate all your tenants; pass -TenantId to avoid this."
        }
    }
    $entraToken = Get-EntraAccessToken
    $headers = @{ Authorization = "Bearer $entraToken" }
    Write-Verbose 'Authenticating with an Entra bearer token.'
}
else {
    $headers = Get-BasicAuthHeader -Token $Pat
}

$apiVersion = '7.1'
$createUri = "https://dev.azure.com/$org/$Project/_apis/wit/workitems/`$$WorkItemType`?api-version=$apiVersion"

function Invoke-AdoRestWithRetry {
    # Wraps Invoke-RestMethod with exponential backoff so transient Azure DevOps
    # throttling (HTTP 429, HTTP 503, or the CircuitBreakerExceededConcurrency
    # exception) is retried instead of aborting the run. Honours a Retry-After
    # header when present, otherwise backs off exponentially with jitter up to
    # -MaxBackoffSeconds. Non-transient errors are rethrown immediately.
    param([hashtable]$RequestArgs)

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
        Headers     = $headers
        Method      = 'Post'
        Body        = $body
        ContentType = 'application/json-patch+json'
    }
    [int]$wi.id
}

function Remove-WorkItem {
    # Permanently destroys a work item so it does not sit in the recycle bin.
    param([int]$Id)
    $uri = "https://dev.azure.com/$org/$Project/_apis/wit/workitems/$Id`?destroy=true&api-version=$apiVersion"
    Invoke-AdoRestWithRetry -RequestArgs @{
        Uri     = $uri
        Headers = $headers
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

