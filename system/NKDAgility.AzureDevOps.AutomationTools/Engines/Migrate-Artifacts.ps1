<#
.SYNOPSIS
    Migrates Azure DevOps Artifact feeds (and their packages) from a source
    organization to a target organization.

.DESCRIPTION
    Enumerates feeds in the source Azure DevOps organization/project, creates
    matching feeds in the target (if they do not already exist), then downloads
    every package version from the source feed and re-publishes it to the target
    feed.

    Feed upstream sources and explicitly-granted feed permissions are copied to
    the target on a best-effort basis and kept in sync on re-runs. Permissions
    whose identities do not resolve in the target organization are skipped
    without failing the migration.

    Supported package types: NuGet, npm, Python (PyPI), Maven, Universal Packages.

    Authentication is ambient-identity first, stored token as the fallback:
    Entra by default for BOTH organizations. When the automation module is
    loaded (the binder guarantees it) the engine acquires an Entra access token
    per organization via Get-AzureDevOpsAccessToken - used as a Bearer header
    for REST, and as the basic-auth password for the packaging tools (nuget,
    npm, twine), which Azure Artifacts accepts anywhere a PAT works. Tokens are
    re-resolved before every feed and package, so the module's cache renews
    them near expiry across a long run. -SourcePat and -TargetPat are the
    fallbacks, used when Entra sign-in is unavailable or fails; the source
    credential needs Packaging (Read), the target Packaging (Read & Write) and
    feed creation rights. Universal Packages go through the az CLI, which
    carries its own ambient identity (az login, or AZURE_DEVOPS_EXT_PAT).

    Required external tooling (only for the package types you actually migrate):
      - dotnet SDK / nuget   -> NuGet
      - npm                  -> npm
      - twine + pip          -> Python
      - mvn (Maven)          -> Maven
      - az CLI + azure-devops extension -> Universal Packages & feed creation

.PARAMETER SourceOrg
    Source organization URL, e.g. https://dev.azure.com/contoso-source

.PARAMETER SourcePat
    Personal Access Token for the source organization (Packaging Read).
    Optional: Entra is the default; the PAT is only used when Entra sign-in is
    unavailable or fails.

.PARAMETER TargetOrg
    Target organization URL, e.g. https://dev.azure.com/contoso-target

.PARAMETER TargetPat
    Personal Access Token for the target organization (Packaging Read & Write).
    Optional: Entra is the default; the PAT is only used when Entra sign-in is
    unavailable or fails.

.PARAMETER SourceProject
    Optional. Project name when migrating project-scoped feeds. Omit for
    organization-scoped feeds.

.PARAMETER TargetProject
    Optional. Target project name for project-scoped feeds. Defaults to
    SourceProject when not supplied.

.PARAMETER FeedName
    Optional. Migrate only the named feed. Omit to migrate all feeds.

.PARAMETER PackageType
    Optional. Restrict migration to specific package types. Defaults to all
    supported types.

.PARAMETER WorkPath
    Optional. Working directory for downloaded packages. Defaults to a temp dir.

.PARAMETER KeepDownloads
    Keep downloaded package files after migration (default: cleaned up).

.PARAMETER Inventory
    Discover and report what would be migrated (feeds, package and version
    counts, and best-effort sizes) without creating feeds or moving any
    packages. Nothing is written to the target and no packaging tooling is
    required. A summary of feeds ('channels'), counts and sizes is printed.

.PARAMETER SkipArtifacts
    Only create/sync the feeds themselves - their upstream sources and
    permissions - without downloading or publishing any packages. Useful for a
    fast feed-only sync when the package contents are handled separately (or not
    yet needed). No packaging tooling is required.

.PARAMETER BuildServiceRole
    Feed role granted to the target project's build service identity
    ("{project} Build Service ({org})") so pipelines can publish packages.
    Defaults to 'contributor', shown as "Feed Publisher (Contributor)" in the
    Azure Artifacts UI. One of reader, collaborator, contributor, administrator.

.PARAMETER ContributorsRole
    Feed role granted to the target project's Contributors group
    ("[{project}]\Contributors"). Defaults to 'collaborator', shown as
    "Feed and Upstream Reader (Collaborator)" in the Azure Artifacts UI. One of
    reader, collaborator, contributor, administrator.

.PARAMETER IncludeUpstream
    Include package versions that were cached from an upstream source (e.g.
    nuget.org, npmjs.com) rather than published directly to the feed. By
    default these are excluded because they are not owned by the feed and can
    be restored on the target by configuring the same upstream sources. Use
    this switch to migrate cached upstream versions as well.

.PARAMETER CsvPath
    Optional path to write the summary as a CSV file (one row per feed and
    protocol, with package/version counts and total bytes). The parent
    directory is created if needed. Works for both inventory and migration.

.EXAMPLE
    # Ambient identity: Entra for both organizations, no PATs.
    .\Migrate-Artifacts.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source `
        -TargetOrg https://dev.azure.com/contoso-target

.EXAMPLE
    # Explicit fallback PATs (e.g. unattended runs).
    .\Migrate-Artifacts.ps1 `
        -SourceOrg https://dev.azure.com/contoso-source -SourcePat $srcPat `
        -TargetOrg https://dev.azure.com/contoso-target -TargetPat $tgtPat `
        -FeedName "shared-libs" -PackageType NuGet,npm -WhatIf

.NOTES
    Run with -WhatIf first to preview what would be migrated without making
    changes. Re-running is safe: existing target feeds are reused and packages
    that already exist are skipped by the target service.

    Fallback PATs: in a customer workspace, run Set-AutomationSecrets (from the
    NKDAgility.AzureDevOps.AutomationTools module) first and reference tokens
    as $ENV:AZDO_PAT_<ORG> in the per-migration config. Entra is tried first
    either way.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$SourceOrg,

    [string]$SourcePat,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$TargetOrg,

    [string]$TargetPat,

    [string]$SourceProject,

    [string]$TargetProject,

    [string]$FeedName,

    [ValidateSet('NuGet', 'Npm', 'PyPi', 'Maven', 'Upack')]
    [string[]]$PackageType = @('NuGet', 'Npm', 'PyPi', 'Maven', 'Upack'),

    [string]$WorkPath,

    [switch]$KeepDownloads,

    [switch]$Inventory,

    [switch]$SkipArtifacts,

    [ValidateSet('reader', 'collaborator', 'contributor', 'administrator')]
    [string]$BuildServiceRole = 'contributor',

    [ValidateSet('reader', 'collaborator', 'contributor', 'administrator')]
    [string]$ContributorsRole = 'collaborator',

    [switch]$IncludeUpstream,

    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Map friendly names to the protocol identifiers used by the Packaging APIs.
$script:ProtocolMap = @{
    NuGet = 'nuget'
    Npm   = 'npm'
    PyPi  = 'pypi'
    Maven = 'maven'
    Upack = 'upack'
}
$script:WantedProtocols = $PackageType | ForEach-Object { $script:ProtocolMap[$_] }

if (-not $TargetProject) { $TargetProject = $SourceProject }

# Caches resolved identities (descriptor -> friendly details) per org so repeated
# lookups across feeds do not re-hit the Identities API.
$script:IdentityCache = @{}
$script:TargetDescriptorCache = @{}
$script:TargetGraphGroups = $null
$script:SubjectToIdentityCache = @{}

#region Helpers ---------------------------------------------------------------

function Get-AuthHeader {
    param([string]$Pat)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Pat")
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
}

function Get-OrgName {
    param([string]$OrgUrl)
    ($OrgUrl.TrimEnd('/') -split '/')[-1]
}

function Initialize-SourceAuth {
    # Credential resolution lives in the module (Resolve-AzureDevOpsAuth) so every engine
    # answers "which credential here" identically: a supplied PAT wins, an on-premises
    # host uses Windows integrated auth, the hosted service uses Entra. Kept here is only
    # what is per-engine - announcing the mode once, and the raw token the packaging
    # tools need as a basic-auth password. Re-resolved per feed so a long run can renew.
    $auth = Resolve-AzureDevOpsAuth -Collection $SourceOrg -Pat $SourcePat -Label 'source'
    if ($script:SourceAuthMode -ne $auth.Mode) {
        Write-Host "==> Source auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:SourceAuthMode = $auth.Mode
    }
    $script:SourceHeaders = $auth.Headers
    $script:SourceToken = $auth.Token
}

function Initialize-TargetAuth {
    # Credential resolution lives in the module (Resolve-AzureDevOpsAuth) so every engine
    # answers "which credential here" identically: a supplied PAT wins, an on-premises
    # host uses Windows integrated auth, the hosted service uses Entra. Kept here is only
    # what is per-engine - announcing the mode once, and the raw token the packaging
    # tools need as a basic-auth password. Re-resolved per feed so a long run can renew.
    $auth = Resolve-AzureDevOpsAuth -Collection $TargetOrg -Pat $TargetPat -Label 'target'
    if ($script:TargetAuthMode -ne $auth.Mode) {
        Write-Host "==> Target auth: $($auth.Mode)." -ForegroundColor DarkGray
        $script:TargetAuthMode = $auth.Mode
    }
    $script:TargetHeaders = $auth.Headers
    $script:TargetToken = $auth.Token
}

# The hosted service splits packaging and identity across subdomains (feeds., pkgs.,
# vssps.) that DO NOT EXIST on an Azure DevOps Server - there, everything is served
# from the collection base. Every URL builder below branches on
# Test-AzureDevOpsHosted, because a subdomain URL built for an on-premises collection
# does not fail; it resolves to the cloud and lands on the wrong machine entirely.

function Get-VssPsBaseUrl {
    # Identity/graph APIs: the vssps.dev.azure.com host in the cloud, the collection
    # itself on-premises.
    param([string]$OrgUrl)
    if (Test-AzureDevOpsHosted -Collection $OrgUrl) {
        $org = Get-OrgName -OrgUrl $OrgUrl
        return "https://vssps.dev.azure.com/$org/_apis"
    }
    "$($OrgUrl.TrimEnd('/'))/_apis"
}

function Get-PackagingBaseUrl {
    # Package REST APIs: the pkgs.dev.azure.com host in the cloud, the collection
    # itself on-premises.
    param([string]$OrgUrl, [string]$Project)
    $projSeg = if ($Project) { "/$Project" } else { '' }
    if (Test-AzureDevOpsHosted -Collection $OrgUrl) {
        $org = Get-OrgName -OrgUrl $OrgUrl
        return "https://pkgs.dev.azure.com/$org$projSeg/_apis/packaging"
    }
    "$($OrgUrl.TrimEnd('/'))$projSeg/_apis/packaging"
}

function Get-FeedsBaseUrl {
    # Feed management: the feeds.dev.azure.com host in the cloud, the collection
    # itself on-premises (where feeds and packages share the collection host).
    param([string]$OrgUrl, [string]$Project)
    $projSeg = if ($Project) { "/$Project" } else { '' }
    if (Test-AzureDevOpsHosted -Collection $OrgUrl) {
        $org = Get-OrgName -OrgUrl $OrgUrl
        return "https://feeds.dev.azure.com/$org$projSeg/_apis/packaging"
    }
    "$($OrgUrl.TrimEnd('/'))$projSeg/_apis/packaging"
}

function Get-PackagingWebBase {
    # The web '_packaging' endpoints the package clients speak to (nuget v3 index,
    # npm registry, pypi simple/upload). Returns a prefix ending in '/' so call
    # sites append '_packaging/...'.
    param([string]$OrgUrl, [string]$Project)
    $proj = if ($Project) { "$Project/" } else { '' }
    if (Test-AzureDevOpsHosted -Collection $OrgUrl) {
        $org = Get-OrgName -OrgUrl $OrgUrl
        return "https://pkgs.dev.azure.com/$org/$proj"
    }
    "$($OrgUrl.TrimEnd('/'))/$proj"
}

function Invoke-AdoApi {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = 'Get',
        [object]$Body,
        [string]$ContentType = 'application/json'
    )
    $params = @{
        Uri     = $Uri
        Headers = $Headers
        Method  = $Method
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = $ContentType
    }
    # An empty header set is how Windows integrated auth is expressed: there is no
    # credential to attach, so ask the stack to negotiate one. Without this the request
    # goes out anonymous and an on-premises collection answers 401.
    if (-not $Headers -or $Headers.Count -eq 0) {
        $params.Remove('Headers')
        $params.UseDefaultCredentials = $true
    }
    Invoke-RestMethod @params
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N2} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N2} KB' -f ($Bytes / 1KB) }
    else { "$Bytes B" }
}

function Get-HttpContentLength {
    # Best-effort artifact size. The packaging content endpoints do not return a
    # Content-Length on HEAD (they report 0) and only set it on a full GET, so a
    # HEAD probe is useless and a full GET would download every package. Instead
    # we issue a ranged GET ('bytes=0-0'): the server responds 206 with a
    # 'Content-Range: bytes 0-0/<total>' header, giving the full size while
    # transferring a single byte. Falls back to Content-Length, then 0.
    param([string]$Uri, [hashtable]$Headers)
    $h = @{}
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    $h['Range'] = 'bytes=0-0'
    try {
        $resp = Invoke-WebRequest -Uri $Uri -Headers $h -Method Get -ErrorAction Stop
        $range = $resp.Headers['Content-Range']
        if ($range) {
            $total = ("$range" -split '/')[-1]
            if ($total -and $total -ne '*') { return [int64]$total }
        }
        $len = $resp.Headers['Content-Length']
        if ($len) { return [int64]($len | Select-Object -First 1) }
    }
    catch { }
    [int64]0
}

# Resolves how to invoke twine on this machine and caches the result. Prefers a
# 'twine' executable on PATH; otherwise falls back to 'python -m twine' (or
# 'py -m twine'). Throws with install guidance when twine cannot be found so the
# migration fails fast with an actionable message instead of a cryptic
# "'twine' is not recognized" per package.
function Resolve-Twine {
    if ($script:TwineInvoker) { return $script:TwineInvoker }

    if (Get-Command twine -ErrorAction SilentlyContinue) {
        $script:TwineInvoker = @{ Exe = 'twine'; Prefix = @() }
        return $script:TwineInvoker
    }
    foreach ($py in @('python', 'py')) {
        $cmd = Get-Command $py -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        & $py -m twine --version *> $null
        if ($LASTEXITCODE -eq 0) {
            $script:TwineInvoker = @{ Exe = $py; Prefix = @('-m', 'twine') }
            return $script:TwineInvoker
        }
    }
    throw "twine was not found. Install it with 'pip install twine' (or 'python -m pip install twine') and ensure python/twine is on PATH."
}

function Invoke-Twine {
    param([string[]]$Arguments)
    $t = Resolve-Twine
    & $t.Exe @($t.Prefix + $Arguments)
}

#endregion Helpers ------------------------------------------------------------

#region Feed operations -------------------------------------------------------

function Get-SourceFeeds {
    $url = (Get-FeedsBaseUrl -OrgUrl $SourceOrg -Project $SourceProject) +
        '/feeds?api-version=7.1-preview.1'
    $feeds = (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value
    if ($FeedName) {
        $feeds = $feeds | Where-Object { $_.name -eq $FeedName }
    }
    $feeds
}

function Get-TargetFeed {
    param([string]$Name)
    $url = (Get-FeedsBaseUrl -OrgUrl $TargetOrg -Project $TargetProject) +
        '/feeds?api-version=7.1-preview.1'
    (Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value |
        Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function New-TargetFeed {
    param($SourceFeed)

    $existing = Get-TargetFeed -Name $SourceFeed.name
    if ($existing) {
        Write-Host "    Target feed '$($SourceFeed.name)' already exists." -ForegroundColor DarkGray
        Sync-TargetFeedUpstreams -SourceFeed $SourceFeed -TargetFeed $existing
        Sync-TargetFeedPermissions -SourceFeed $SourceFeed -TargetFeed $existing
        return $existing
    }

    if (-not $PSCmdlet.ShouldProcess($SourceFeed.name, 'Create target feed')) {
        return $null
    }

    $url = (Get-FeedsBaseUrl -OrgUrl $TargetOrg -Project $TargetProject) +
        '/feeds?api-version=7.1-preview.1'
    $body = @{
        name        = $SourceFeed.name
        description = $SourceFeed.description
    }
    # Carry over the upstream sources (public registries and other feed views)
    # so the new feed resolves the same externals as the source.
    $upstreams = @(Get-UpstreamSourceBody -SourceFeed $SourceFeed)
    if ($upstreams.Count -gt 0) {
        $body.upstreamEnabled = $true
        $body.upstreamSources = $upstreams
    }
    Write-Host "    Creating target feed '$($SourceFeed.name)' with $($upstreams.Count) upstream source(s)." -ForegroundColor Green
    $created = Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders -Method Post -Body $body

    # Copy the source feed's explicit permissions onto the brand-new feed
    # (best-effort; identities that do not resolve in the target org are skipped).
    if ($created -and $created.PSObject.Properties['id']) {
        Sync-TargetFeedPermissions -SourceFeed $SourceFeed -TargetFeed $created
    }
    $created
}

function Get-UpstreamSourceBody {
    # Projects a source feed's upstreamSources down to just the settable
    # properties the create/update APIs accept (the source objects carry
    # read-only fields like id/status that the API rejects).
    #
    # Only PUBLIC upstreams (npmjs, nuget.org, pypi.org, Maven Central, ...) are
    # carried over. INTERNAL upstreams point at other Azure DevOps feeds in the
    # source organisation via a 'host'/feed GUID that does not exist in the
    # target org, so recreating them fails with InvalidUpstreamSourceException.
    param($SourceFeed)

    if (-not ($SourceFeed.PSObject.Properties['upstreamSources'] -and $SourceFeed.upstreamSources)) {
        return @()
    }
    @($SourceFeed.upstreamSources |
        Where-Object { "$($_.upstreamSourceType)".ToLowerInvariant() -eq 'public' } |
        ForEach-Object { ConvertTo-UpstreamHashtable -Source $_ })
}

function ConvertTo-UpstreamHashtable {
    # Normalizes a single upstream source object (PSCustomObject or hashtable)
    # into a plain hashtable of just the settable properties. Keeping every
    # element the same type avoids a PowerShell quirk where @() over a list that
    # mixes hashtables and PSCustomObjects throws 'Argument types do not match'.
    # Internal-upstream identity fields are preserved when present so re-sending
    # a target feed's existing upstreams during a sync does not corrupt them.
    param($Source)

    $u = @{
        name               = $Source.name
        protocol           = $Source.protocol
        location           = $Source.location
        upstreamSourceType = $Source.upstreamSourceType
    }
    $optional = @(
        'displayLocation'
        'internalUpstreamCollectionId'
        'internalUpstreamFeedId'
        'internalUpstreamViewId'
        'serviceEndpointId'
        'serviceEndpointProjectId'
    )
    foreach ($name in $optional) {
        if ($Source.PSObject.Properties[$name] -and $Source.$name) {
            $u[$name] = $Source.$name
        }
    }
    $u
}

function Sync-TargetFeedUpstreams {
    # Retro-adds any upstream sources present on the source feed but missing on
    # an already-existing target feed, via PATCH. Existing upstreams are matched
    # by location (case-insensitive) so re-runs are idempotent.
    param($SourceFeed, $TargetFeed)

    $desired = @(Get-UpstreamSourceBody -SourceFeed $SourceFeed)
    if ($desired.Count -eq 0) { return }

    $existingLocations = @()
    if ($TargetFeed.PSObject.Properties['upstreamSources'] -and $TargetFeed.upstreamSources) {
        $existingLocations = @($TargetFeed.upstreamSources | ForEach-Object { "$($_.location)".ToLowerInvariant() })
    }

    $missing = @($desired | Where-Object { $existingLocations -notcontains "$($_.location)".ToLowerInvariant() })
    if ($missing.Count -eq 0) {
        Write-Host "    Upstream sources already in sync." -ForegroundColor DarkGray
        return
    }

    if (-not $PSCmdlet.ShouldProcess($SourceFeed.name, "Add $($missing.Count) upstream source(s)")) {
        return
    }

    # Preserve any upstreams already on the target and append the missing ones.
    # Everything is normalized to hashtables so building the array below is safe.
    $merged = New-Object System.Collections.Generic.List[hashtable]
    if ($TargetFeed.PSObject.Properties['upstreamSources'] -and $TargetFeed.upstreamSources) {
        foreach ($u in $TargetFeed.upstreamSources) { $merged.Add((ConvertTo-UpstreamHashtable -Source $u)) }
    }
    foreach ($u in $missing) { $merged.Add($u) }

    $url = (Get-FeedsBaseUrl -OrgUrl $TargetOrg -Project $TargetProject) +
        "/feeds/$($TargetFeed.id)?api-version=7.1-preview.1"
    $body = @{
        upstreamEnabled = $true
        upstreamSources = $merged.ToArray()
    }
    Write-Host "    Adding $($missing.Count) missing upstream source(s) to '$($SourceFeed.name)'." -ForegroundColor Green
    # Suppress the PATCH response so it does not leak into New-TargetFeed's
    # output (which must return only the feed object).
    Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders -Method Patch -Body $body | Out-Null
}

function Get-FeedPermissions {
    # Returns the permission entries for a feed. Each entry carries an
    # identityDescriptor, a role (reader/collaborator/contributor/administrator)
    # and an isInheritedRole flag (true when the role comes from a project/org
    # level assignment rather than being granted directly on the feed).
    param([string]$OrgUrl, [string]$Project, [string]$FeedId, [hashtable]$Headers)
    $url = (Get-FeedsBaseUrl -OrgUrl $OrgUrl -Project $Project) +
        "/feeds/$FeedId/permissions?api-version=7.1-preview.1"
    @((Invoke-AdoApi -Uri $url -Headers $Headers).value)
}

function Get-IdentityPropertyValue {
    # Reads a named value out of an Identities API identity's 'properties' bag.
    # Each property is a { '$type', '$value' } pair; returns the first non-empty
    # match from the supplied candidate names (StrictMode-safe).
    param($Identity, [string[]]$Names)
    if (-not ($Identity.PSObject.Properties['properties'] -and $Identity.properties)) { return $null }
    foreach ($n in $Names) {
        if ($Identity.properties.PSObject.Properties[$n]) {
            $entry = $Identity.properties.$n
            if ($entry -and $entry.PSObject.Properties['$value'] -and $entry.'$value') {
                return [string]$entry.'$value'
            }
        }
    }
    $null
}

function Resolve-AdoIdentity {
    # Resolves a legacy identity descriptor to friendly details (display name and
    # a sign-in address / account name usable to find the same identity in
    # another org). Results are cached per org+descriptor. Falls back to parsing
    # the descriptor itself when the Identities API cannot resolve it.
    param([string]$OrgUrl, [string]$Descriptor, [hashtable]$Headers)

    $cacheKey = "$OrgUrl|$Descriptor"
    if ($script:IdentityCache.ContainsKey($cacheKey)) { return $script:IdentityCache[$cacheKey] }

    $displayName = $null
    $signIn = $null
    $scopeName = $null
    $schemaClass = $null

    try {
        $base = Get-VssPsBaseUrl -OrgUrl $OrgUrl
        $enc = [uri]::EscapeDataString($Descriptor)
        $url = "$base/identities?descriptors=$enc&queryMembership=None&api-version=7.1-preview.1"
        $id = @((Invoke-AdoApi -Uri $url -Headers $Headers).value) | Select-Object -First 1
        if ($id) {
            if ($id.PSObject.Properties['providerDisplayName'] -and $id.providerDisplayName) {
                $displayName = $id.providerDisplayName
            }
            $signIn = Get-IdentityPropertyValue -Identity $id -Names @('Mail', 'Account', 'DirectoryAlias')
            $scopeName = Get-IdentityPropertyValue -Identity $id -Names @('ScopeName')
            $schemaClass = Get-IdentityPropertyValue -Identity $id -Names @('SchemaClassName')
        }
    }
    catch { }

    # Group detection: TFS/AAD groups resolve to SID-based TeamFoundation
    # identity descriptors; users and service accounts do not.
    $isGroup = ($schemaClass -eq 'Group') -or ($Descriptor -like 'Microsoft.TeamFoundation.Identity;S-1-9-*')

    # Fallbacks parsed straight from the descriptor when the API is unhelpful.
    if (-not $signIn -and $Descriptor -match '\\([^\\]+@[^\\]+)$') { $signIn = $Matches[1] }
    if (-not $displayName) {
        if ($signIn) { $displayName = $signIn }
        elseif ($Descriptor -match '\\([^\\]+)$') { $displayName = $Matches[1] }
        else { $displayName = $Descriptor }
    }

    # Split a scoped group display ("[Scope]\Group Name") into its parts, and
    # build a friendly scoped display name for groups that only reported a bare
    # group name plus a separate ScopeName property.
    $groupName = $displayName
    if ($displayName -match '^\[(?<s>[^\]]+)\]\\(?<g>.+)$') {
        if (-not $scopeName) { $scopeName = $Matches['s'] }
        $groupName = $Matches['g']
    }
    elseif ($isGroup -and $scopeName) {
        $displayName = "[$scopeName]\$displayName"
    }

    $result = [pscustomobject]@{
        DisplayName   = $displayName
        SignInAddress = $signIn
        IsGroup       = $isGroup
        ScopeName     = $scopeName
        GroupName     = $groupName
    }
    $script:IdentityCache[$cacheKey] = $result
    $result
}

function Resolve-TargetIdentityDescriptor {
    # Finds the identity descriptor in the TARGET org that matches a source
    # identity, searching by sign-in address first and then display name. Returns
    # the target-org descriptor (usable with the feed permissions API) or $null
    # when the identity does not exist in the target org. Cached per filter value.
    param([string[]]$FilterValues)

    $base = Get-VssPsBaseUrl -OrgUrl $TargetOrg
    foreach ($filter in $FilterValues) {
        if ([string]::IsNullOrWhiteSpace($filter)) { continue }
        if ($script:TargetDescriptorCache.ContainsKey($filter)) {
            $cached = $script:TargetDescriptorCache[$filter]
            if ($cached) { return $cached }
            continue
        }
        $found = $null
        try {
            $enc = [uri]::EscapeDataString($filter)
            $url = "$base/identities?searchFilter=General&filterValue=$enc&queryMembership=None&api-version=7.1-preview.1"
            $match = @((Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value) |
                Where-Object { $_.PSObject.Properties['descriptor'] -and $_.descriptor } |
                Select-Object -First 1
            if ($match) { $found = $match.descriptor }
        }
        catch { }
        $script:TargetDescriptorCache[$filter] = $found
        if ($found) { return $found }
    }
    $null
}

function Get-TargetGraphGroups {
    # Lists every group in the TARGET org via the Graph API and caches the
    # result. Unlike the Identities search, each group carries a 'principalName'
    # in the exact "[Scope]\Group Name" form (e.g. "[MyProject]\Contributors"),
    # which lets us match a specific project's group unambiguously instead of a
    # same-named group in the wrong project. Paged via the X-MS-ContinuationToken
    # response header.
    if ($null -ne $script:TargetGraphGroups) { return $script:TargetGraphGroups }

    $base = "$(Get-VssPsBaseUrl -OrgUrl $TargetOrg)/graph/groups?api-version=7.1-preview.1"
    $all = New-Object System.Collections.Generic.List[object]
    $token = $null
    try {
        do {
            $uri = if ($token) { "$base&continuationToken=$([uri]::EscapeDataString($token))" } else { $base }
            $resp = Invoke-WebRequest -Uri $uri -Headers $script:TargetHeaders -Method Get -ErrorAction Stop
            $token = $resp.Headers['X-MS-ContinuationToken']
            if ($token -is [array]) { $token = $token | Select-Object -First 1 }
            $data = $resp.Content | ConvertFrom-Json
            if ($data.PSObject.Properties['value'] -and $data.value) {
                foreach ($g in $data.value) { $all.Add($g) }
            }
        } while ($token)
    }
    catch {
        Write-Warning "    Could not list target org groups (Graph API): $($_.Exception.Message)"
    }
    $script:TargetGraphGroups = $all
    $all
}

function ConvertTo-TargetIdentityDescriptor {
    # Converts a Graph subject descriptor (e.g. 'vssgp.Uxxxx') to the legacy
    # identity descriptor the feed permissions API expects. Cached per subject.
    param([string]$SubjectDescriptor)

    if ([string]::IsNullOrWhiteSpace($SubjectDescriptor)) { return $null }
    if ($script:SubjectToIdentityCache.ContainsKey($SubjectDescriptor)) {
        return $script:SubjectToIdentityCache[$SubjectDescriptor]
    }
    $legacy = $null
    try {
        $b = Get-VssPsBaseUrl -OrgUrl $TargetOrg
        $enc = [uri]::EscapeDataString($SubjectDescriptor)
        $url = "$b/identities?subjectDescriptors=$enc&queryMembership=None&api-version=7.1-preview.1"
        $id = @((Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value) | Select-Object -First 1
        if ($id -and $id.PSObject.Properties['descriptor'] -and $id.descriptor) { $legacy = $id.descriptor }
    }
    catch { }
    $script:SubjectToIdentityCache[$SubjectDescriptor] = $legacy
    $legacy
}

function Resolve-TargetGroupDescriptor {
    # Resolves a target-org group to its legacy identity descriptor by matching
    # the Graph group's 'principalName' exactly against "[Scope]\Group Name".
    # With -AllowSuffixMatch, falls back to matching on the "\Group Name" suffix
    # only (used for collection-level groups such as "Project Collection
    # Administrators" that are unique by name across the org). Returns $null when
    # no group matches. Cached per principal.
    param([string]$PrincipalName, [switch]$AllowSuffixMatch)

    if ([string]::IsNullOrWhiteSpace($PrincipalName)) { return $null }
    $cacheKey = "grp|$PrincipalName|$($AllowSuffixMatch.IsPresent)"
    if ($script:TargetDescriptorCache.ContainsKey($cacheKey)) {
        return $script:TargetDescriptorCache[$cacheKey]
    }

    $groups = Get-TargetGraphGroups
    $match = $groups |
        Where-Object { $_.PSObject.Properties['principalName'] -and $_.principalName -and ($_.principalName -ieq $PrincipalName) } |
        Select-Object -First 1
    if (-not $match -and $AllowSuffixMatch -and ($PrincipalName -match '\\(?<g>.+)$')) {
        $suffix = ('\' + $Matches['g']).ToLowerInvariant()
        $match = $groups |
            Where-Object { $_.PSObject.Properties['principalName'] -and "$($_.principalName)".ToLowerInvariant().EndsWith($suffix) } |
            Select-Object -First 1
    }

    $desc = $null
    if ($match -and $match.PSObject.Properties['descriptor'] -and $match.descriptor) {
        $desc = ConvertTo-TargetIdentityDescriptor -SubjectDescriptor $match.descriptor
    }
    $script:TargetDescriptorCache[$cacheKey] = $desc
    $desc
}

function Set-FeedPermission {
    # Grants a single identity a role on the target feed. The permissions API
    # expects a JSON array body, so the single entry is wrapped and serialized
    # explicitly (ConvertTo-Json collapses a one-element array to an object,
    # which the API rejects).
    param([string]$FeedId, [string]$IdentityDescriptor, [string]$Role)
    $url = (Get-FeedsBaseUrl -OrgUrl $TargetOrg -Project $TargetProject) +
        "/feeds/$FeedId/permissions?api-version=7.1-preview.1"
    $item = @{ identityDescriptor = $IdentityDescriptor; role = $Role }
    $json = '[' + ($item | ConvertTo-Json -Depth 5 -Compress) + ']'
    Invoke-RestMethod -Uri $url -Headers $script:TargetHeaders -Method Patch `
        -Body $json -ContentType 'application/json'
}

function Remove-FeedPermission {
    # Removes an identity's explicit permission from the target feed. The Set
    # Feed Permissions API removes an assignment when the entry's role is set to
    # 'none'.
    param([string]$FeedId, [string]$IdentityDescriptor)
    Set-FeedPermission -FeedId $FeedId -IdentityDescriptor $IdentityDescriptor -Role 'none'
}

function Sync-TargetFeedPermissions {
    # Best-effort copy of the source feed's explicitly-granted permissions onto
    # the target feed. Inherited roles are skipped (they flow from the target
    # project/org, not from the feed). Because identity descriptors are
    # org-specific, each source identity is resolved to a friendly name +
    # sign-in address and then re-resolved to the matching descriptor in the
    # TARGET org before granting. Identities that do not exist in the target org
    # (e.g. build service accounts, org-scoped groups) are skipped with a warning
    # by their friendly name. Re-runs are idempotent.
    param($SourceFeed, $TargetFeed)

    # Snapshot existing target permissions (keyed by target descriptor + role)
    # so already-granted roles are skipped.
    $existing = @{}
    try {
        foreach ($p in (Get-FeedPermissions -OrgUrl $TargetOrg -Project $TargetProject `
                    -FeedId $TargetFeed.id -Headers $script:TargetHeaders)) {
            $existing[("{0}|{1}" -f $p.identityDescriptor, $p.role).ToLowerInvariant()] = $true
        }
    }
    catch { }

    $applied = 0
    $present = 0
    $skipped = 0

    # Always ensure the target project's build service can publish packages,
    # regardless of what the source feed granted (its build service identity is
    # org-specific and will not resolve in the target).
    $bs = Add-TargetBuildServicePublisher -TargetFeed $TargetFeed -Existing $existing
    $applied += $bs.Applied
    $present += $bs.Present
    $skipped += $bs.Skipped

    # Always give the target project's Contributors group read access to the feed
    # and its upstreams (the "Feed and Upstream Reader (Collaborator)" role).
    $co = Add-TargetContributorsReader -TargetFeed $TargetFeed -Existing $existing
    $applied += $co.Applied
    $present += $co.Present
    $skipped += $co.Skipped

    $sourcePerms = @()
    try {
        $sourcePerms = @(Get-FeedPermissions -OrgUrl $SourceOrg -Project $SourceProject `
                -FeedId $SourceFeed.id -Headers $script:SourceHeaders |
            Where-Object { -not $_.isInheritedRole })
    }
    catch {
        Write-Warning "    Could not read source feed permissions for '$($SourceFeed.name)': $($_.Exception.Message)"
        $sourcePerms = @()
    }

    foreach ($perm in $sourcePerms) {
        # Resolve the source identity to friendly details.
        $identity = Resolve-AdoIdentity -OrgUrl $SourceOrg -Descriptor $perm.identityDescriptor -Headers $script:SourceHeaders
        $who = $identity.DisplayName
        $targetDescriptor = $null

        if ($identity.IsGroup) {
            # Group descriptors are scoped to a specific project/collection in the
            # SOURCE org and must be re-pointed at the equivalent group in the
            # TARGET project, otherwise a same-named group in the wrong project is
            # matched. Resolution goes through the Graph API by principal name.
            $grpName = $identity.GroupName
            if ($grpName -like 'Project Collection*') {
                # Collection-scoped group: unique by name across the org.
                $who = "\$grpName (collection)"
                $targetDescriptor = Resolve-TargetGroupDescriptor -PrincipalName "\$grpName" -AllowSuffixMatch
            }
            elseif ($identity.ScopeName -and $SourceProject -and ($identity.ScopeName -ieq $SourceProject)) {
                # Project-scoped group: remap the scope to the target project.
                $who = "[$TargetProject]\$grpName"
                $targetDescriptor = Resolve-TargetGroupDescriptor -PrincipalName $who
            }
            else {
                Write-Warning "    Group '$($identity.DisplayName)' is scoped to another project; skipped."
                $skipped++
                continue
            }
        }
        else {
            # User / service identity: match by sign-in address then display name.
            $targetDescriptor = Resolve-TargetIdentityDescriptor -FilterValues @($identity.SignInAddress, $identity.DisplayName)
        }

        if (-not $targetDescriptor) {
            Write-Warning "    No matching identity in target org for $who ($($perm.role)); skipped."
            $skipped++
            continue
        }

        $key = ("{0}|{1}" -f $targetDescriptor, $perm.role).ToLowerInvariant()
        if ($existing.ContainsKey($key)) { $present++; continue }

        if (-not $PSCmdlet.ShouldProcess("$who -> $($perm.role)", "Grant feed permission on '$($SourceFeed.name)'")) {
            continue
        }
        try {
            Set-FeedPermission -FeedId $TargetFeed.id -IdentityDescriptor $targetDescriptor -Role $perm.role | Out-Null
            Write-Host "    Granted '$($perm.role)' to $who." -ForegroundColor Green
            $applied++
        }
        catch {
            Write-Warning "    Skipped permission for $who ($($perm.role)): $($_.Exception.Message)"
            $skipped++
        }
    }

    # Remove any previously-added project group permissions that point at the
    # wrong project (e.g. a Contributors/Project Administrators group from a
    # different project matched by an earlier, ambiguous lookup).
    $removed = Remove-MismatchedGroupPermissions -TargetFeed $TargetFeed

    Write-Host ("    Feed permissions: {0} granted, {1} already present, {2} skipped, {3} removed." -f $applied, $present, $skipped, $removed) -ForegroundColor DarkGray
}

function Add-TargetBuildServicePublisher {
    # Ensures the target project's build service identity is granted the
    # publisher role on the target feed so pipelines in the target project can
    # push packages. In the Azure Artifacts UI this role is shown as
    # "Feed Publisher (Contributor)"; the API value is 'contributor' (overridable
    # via -BuildServiceRole). The build service display name follows the pattern
    # "{project} Build Service ({org})". Returns a small tally so the caller can
    # fold it into the overall permission summary.
    param(
        $TargetFeed,
        [hashtable]$Existing = @{}
    )

    $result = [pscustomobject]@{ Applied = 0; Present = 0; Skipped = 0 }

    if (-not $TargetProject) {
        Write-Host "    No target project; skipping build service publisher grant." -ForegroundColor DarkGray
        return $result
    }

    $orgName = Get-OrgName -OrgUrl $TargetOrg
    $displayName = "$TargetProject Build Service ($orgName)"

    $descriptor = Resolve-TargetIdentityDescriptor -FilterValues @($displayName)
    if (-not $descriptor) {
        Write-Warning "    Build service identity '$displayName' not found in target org; skipped."
        $result.Skipped++
        return $result
    }

    $key = ("{0}|{1}" -f $descriptor, $BuildServiceRole).ToLowerInvariant()
    if ($Existing.ContainsKey($key)) {
        $result.Present++
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess("$displayName -> $BuildServiceRole", 'Grant build service feed publisher permission')) {
        return $result
    }
    try {
        Set-FeedPermission -FeedId $TargetFeed.id -IdentityDescriptor $descriptor -Role $BuildServiceRole | Out-Null
        Write-Host "    Granted '$BuildServiceRole' to $displayName (build service)." -ForegroundColor Green
        $result.Applied++
    }
    catch {
        Write-Warning "    Could not grant '$BuildServiceRole' to $displayName : $($_.Exception.Message)"
        $result.Skipped++
    }
    $result
}

function Add-TargetContributorsReader {
    # Ensures the target project's Contributors group is granted read access to
    # the feed and its upstreams. In the Azure Artifacts UI this role is shown as
    # "Feed and Upstream Reader (Collaborator)"; the API value is 'collaborator'
    # (overridable via -ContributorsRole). The group is identified by the target
    # project's Contributors group, e.g. "[{project}]\Contributors". Returns a
    # small tally so the caller can fold it into the overall permission summary.
    param(
        $TargetFeed,
        [hashtable]$Existing = @{}
    )

    $result = [pscustomobject]@{ Applied = 0; Present = 0; Skipped = 0 }

    if (-not $TargetProject) {
        Write-Host "    No target project; skipping Contributors reader grant." -ForegroundColor DarkGray
        return $result
    }

    # Identify the target project's Contributors group by its exact principal
    # name so a same-named group in another project is never matched.
    $displayName = "[$TargetProject]\Contributors"
    $descriptor = Resolve-TargetGroupDescriptor -PrincipalName $displayName
    if (-not $descriptor) {
        Write-Warning "    Contributors group '$displayName' not found in target org; skipped."
        $result.Skipped++
        return $result
    }

    $key = ("{0}|{1}" -f $descriptor, $ContributorsRole).ToLowerInvariant()
    if ($Existing.ContainsKey($key)) {
        $result.Present++
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess("$displayName -> $ContributorsRole", 'Grant Contributors feed reader permission')) {
        return $result
    }
    try {
        Set-FeedPermission -FeedId $TargetFeed.id -IdentityDescriptor $descriptor -Role $ContributorsRole | Out-Null
        Write-Host "    Granted '$ContributorsRole' to $displayName." -ForegroundColor Green
        $result.Applied++
    }
    catch {
        Write-Warning "    Could not grant '$ContributorsRole' to $displayName : $($_.Exception.Message)"
        $result.Skipped++
    }
    $result
}

function Remove-MismatchedGroupPermissions {
    # Removes explicit permissions on the target feed for the well-known project
    # groups ("Contributors" / "Project Administrators") whose scope is NOT the
    # target project. These are left over from earlier runs that resolved a
    # same-named group in the wrong project. The correctly-scoped target-project
    # groups are kept. Returns the number of permissions removed.
    param($TargetFeed)

    $removed = 0
    $managed = @('Contributors', 'Project Administrators')

    $perms = @()
    try {
        $perms = @(Get-FeedPermissions -OrgUrl $TargetOrg -Project $TargetProject `
                -FeedId $TargetFeed.id -Headers $script:TargetHeaders |
            Where-Object { -not $_.isInheritedRole })
    }
    catch { return $removed }

    foreach ($p in $perms) {
        $id = Resolve-AdoIdentity -OrgUrl $TargetOrg -Descriptor $p.identityDescriptor -Headers $script:TargetHeaders
        if (-not $id.IsGroup) { continue }
        if ($managed -notcontains $id.GroupName) { continue }
        # Keep the correctly-scoped target-project group.
        if ($id.ScopeName -and $TargetProject -and ($id.ScopeName -ieq $TargetProject)) { continue }

        $label = if ($id.ScopeName) { "[$($id.ScopeName)]\$($id.GroupName)" } else { $id.GroupName }
        if (-not $PSCmdlet.ShouldProcess("$label -> $($p.role)", 'Remove mismatched feed permission')) {
            continue
        }
        try {
            Remove-FeedPermission -FeedId $TargetFeed.id -IdentityDescriptor $p.identityDescriptor | Out-Null
            Write-Host "    Removed mismatched permission '$($p.role)' for $label." -ForegroundColor Yellow
            $removed++
        }
        catch {
            Write-Warning "    Could not remove mismatched permission for $label : $($_.Exception.Message)"
        }
    }
    $removed
}

#endregion Feed operations ----------------------------------------------------

#region Package enumeration ---------------------------------------------------

function Get-FeedPackages {
    param([string]$FeedId)
    # Package *metadata* enumeration lives on the feeds.dev.azure.com host. The
    # pkgs.dev.azure.com host only serves package *content* (download/upload)
    # and returns 401 for listing packages.
    $base = Get-FeedsBaseUrl -OrgUrl $SourceOrg -Project $SourceProject
    $top = 100
    $skip = 0
    do {
        $url = "$base/feeds/$FeedId/packages?api-version=7.1-preview.1" +
            "&includeAllVersions=true&`$top=$top&`$skip=$skip"
        $page = (Invoke-AdoApi -Uri $url -Headers $script:SourceHeaders).value
        foreach ($pkg in $page) { $pkg }
        $skip += $top
    } while ($page.Count -eq $top)
}

function Get-TargetVersionLookup {
    # Builds a set of the versions already present in a target feed so migration
    # can skip anything that's been uploaded before, avoiding re-download and a
    # wasted upload attempt. Keys are "<name>|<version>" (lower-cased). Returns
    # an empty set for a brand-new feed. Enumeration uses the feeds host.
    param([string]$FeedId)

    $lookup = @{}
    if (-not $FeedId) { return $lookup }
    $base = Get-FeedsBaseUrl -OrgUrl $TargetOrg -Project $TargetProject
    $top = 100
    $skip = 0
    do {
        $url = "$base/feeds/$FeedId/packages?api-version=7.1-preview.1" +
            "&includeAllVersions=true&`$top=$top&`$skip=$skip"
        $page = @((Invoke-AdoApi -Uri $url -Headers $script:TargetHeaders).value)
        foreach ($pkg in $page) {
            if (-not ($pkg.PSObject.Properties['versions'] -and $pkg.versions)) { continue }
            foreach ($v in $pkg.versions) {
                $key = ("{0}|{1}" -f $pkg.name, $v.version).ToLowerInvariant()
                $lookup[$key] = $true
            }
        }
        $skip += $top
    } while ($page.Count -eq $top)
    $lookup
}

function Test-TargetHasVersion {
    param($Lookup, [string]$Name, [string]$Version)
    $Lookup.ContainsKey(("{0}|{1}" -f $Name, $Version).ToLowerInvariant())
}

function Test-LocalVersion {
    # True when a package version was published directly to the feed rather than
    # cached from an upstream source. Upstream-sourced versions carry a
    # non-empty 'directUpstreamSourceId'; locally published ones do not.
    param($Version)
    $prop = $Version.PSObject.Properties['directUpstreamSourceId']
    -not ($prop -and -not [string]::IsNullOrEmpty($prop.Value))
}

function Select-MigratableVersions {
    # Applies the upstream filter unless -IncludeUpstream was supplied.
    param($Versions)
    if ($IncludeUpstream) { return @($Versions) }
    @($Versions | Where-Object { Test-LocalVersion $_ })
}

function Get-VersionSizeBytes {
    # Best-effort total byte size for a single package version, used by the
    # read-only inventory. Sizes are probed over HTTP (a ranged GET that
    # transfers a single byte) WITHOUT downloading the package, so inventory
    # stays fast and never fills the cache. NuGet/npm expose one content
    # endpoint; PyPI can have several files. Maven/Universal sizes are not
    # reliably exposed by the feed API and are reported as 0 (unknown).
    param($Feed, $Package, $Version, [string]$Protocol)

    $base = Get-PackagingBaseUrl -OrgUrl $SourceOrg -Project $SourceProject
    $name = $Package.name
    $ver = $Version.version
    switch ($Protocol) {
        'nuget' {
            $u = "$base/feeds/$($Feed.id)/nuget/packages/$name/versions/$ver/content?api-version=7.1-preview.1"
            Get-HttpContentLength -Uri $u -Headers $script:SourceHeaders
        }
        'npm' {
            $u = "$base/feeds/$($Feed.id)/npm/packages/$name/versions/$ver/content?api-version=7.1-preview.1"
            Get-HttpContentLength -Uri $u -Headers $script:SourceHeaders
        }
        'pypi' {
            $sum = [int64]0
            foreach ($dl in (Get-PyPiFileUrls -Feed $Feed -Package $name -Version $ver)) {
                $sum += Get-HttpContentLength -Uri $dl -Headers $script:SourceHeaders
            }
            $sum
        }
        default { [int64]0 }
    }
}

function Get-CacheDir {
    # Persistent per-feed/per-protocol cache directory under WorkPath. Created on
    # demand. The same layout is used for inventory sizing and for migration so
    # files downloaded once are reused by both.
    param($Feed, [string]$Protocol)
    $dir = Join-Path $script:CacheRoot ($Feed.name + '_' + $Protocol)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dir
}

function Save-VersionToCache {
    # Downloads all file(s) for a package version into the persistent cache,
    # skipping any already present, and returns their local paths. This is the
    # single download path shared by inventory (for sizing) and migration (for
    # upload) so a package is fetched at most once across runs.
    param($Feed, $Package, $Version, [string]$Protocol)

    $dir = Get-CacheDir -Feed $Feed -Protocol $Protocol
    $base = Get-PackagingBaseUrl -OrgUrl $SourceOrg -Project $SourceProject
    $name = $Package.name
    $ver = $Version.version
    $paths = New-Object System.Collections.Generic.List[string]

    switch ($Protocol) {
        'nuget' {
            $file = Join-Path $dir "$name.$ver.nupkg"
            if (-not (Test-Path -LiteralPath $file)) {
                $url = "$base/feeds/$($Feed.id)/nuget/packages/$name/versions/$ver/content?api-version=7.1-preview.1"
                Invoke-WebRequest -Uri $url -Headers $script:SourceHeaders -OutFile $file
            }
            $paths.Add($file)
        }
        'npm' {
            $safe = $name -replace '[/@]', '_'
            $file = Join-Path $dir "$safe-$ver.tgz"
            if (-not (Test-Path -LiteralPath $file)) {
                $url = "$base/feeds/$($Feed.id)/npm/packages/$name/versions/$ver/content?api-version=7.1-preview.1"
                Invoke-WebRequest -Uri $url -Headers $script:SourceHeaders -OutFile $file
            }
            $paths.Add($file)
        }
        'pypi' {
            foreach ($dl in (Get-PyPiFileUrls -Feed $Feed -Package $name -Version $ver)) {
                $fileName = ($dl -split '/')[-1]
                $file = Join-Path $dir $fileName
                if (-not (Test-Path -LiteralPath $file)) {
                    Invoke-WebRequest -Uri $dl -Headers $script:SourceHeaders -OutFile $file
                }
                $paths.Add($file)
            }
        }
        'upack' {
            $pkgDir = Join-Path $dir "$name-$ver"
            $hasFiles = (Test-Path -LiteralPath $pkgDir) -and
                @(Get-ChildItem -LiteralPath $pkgDir -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $hasFiles) {
                New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
                & az artifacts universal download `
                    --organization $SourceOrg `
                    --feed $Feed.name `
                    --name $name `
                    --version $ver `
                    --path $pkgDir `
                    $(if ($SourceProject) { @('--project', $SourceProject) }) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "az universal download failed for $name $ver" }
            }
            foreach ($f in (Get-ChildItem -LiteralPath $pkgDir -File -Recurse)) { $paths.Add($f.FullName) }
        }
        'maven' {
            $parts = $name -split ':'
            if ($parts.Count -ge 2) {
                $groupId = $parts[0]
                $artifactId = $parts[1]
                $groupPath = $groupId -replace '\.', '/'
                foreach ($ext in @('jar', 'pom')) {
                    $file = Join-Path $dir "$artifactId-$ver.$ext"
                    if (-not (Test-Path -LiteralPath $file)) {
                        $url = "$base/feeds/$($Feed.id)/maven/$groupPath/$artifactId/$ver/$artifactId-$ver.$ext?api-version=7.1-preview.1"
                        try { Invoke-WebRequest -Uri $url -Headers $script:SourceHeaders -OutFile $file }
                        catch { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }; continue }
                    }
                    if (Test-Path -LiteralPath $file) { $paths.Add($file) }
                }
            }
        }
    }
    $paths
}


function Get-PyPiFileUrls {
    # Returns the download URLs for every distribution file of a PyPI package
    # version by scraping the feed's Simple index. Both the package name and the
    # distribution filenames are normalized per PEP 503 (lower-cased, with runs
    # of '.', '-' and '_' collapsed to a single '-') before matching, because
    # PyPI/Azure Artifacts store files under the normalized name (e.g.
    # 'GF.MS.Milling.Cenower.Messages.PY' becomes
    # 'gf_ms_milling_cenower_messages_py-0.3.1-...'). Version matching is done on
    # a boundary so that, e.g., version '0.1.1' does not also match '0.1.10'.
    param($Feed, [string]$Package, [string]$Version)

    $normalize = { param([string]$s) ($s -replace '[-_.]+', '-').ToLowerInvariant().Trim('-') }
    $nameNorm = & $normalize $Package
    $verNorm = & $normalize $Version

    $indexUrl = "$(Get-PackagingWebBase -OrgUrl $SourceOrg -Project $SourceProject)_packaging/$($Feed.name)/pypi/simple/$nameNorm/"
    try {
        $html = (Invoke-WebRequest -Uri $indexUrl -Headers $script:SourceHeaders -ErrorAction Stop).Content
    }
    catch { return @() }

    # Match "<name>-<version>" at the start of the normalized filename, followed
    # by a separator (another '-' segment, e.g. a wheel tag or file extension)
    # or the end of the string.
    $pattern = "^$([regex]::Escape($nameNorm))-$([regex]::Escape($verNorm))(-|$)"
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($html, 'href="([^"#]+)')) {
        $url = $m.Groups[1].Value
        $file = ($url -split '/')[-1]
        $fileNorm = & $normalize $file
        if ($fileNorm -match $pattern) {
            $urls.Add($url)
        }
    }
    $urls
}


#endregion Package enumeration ------------------------------------------------

#region Per-protocol migration ------------------------------------------------

function Get-TargetFeedSourceUrl {
    # The NuGet/npm/etc. source URL for the target feed.
    param([string]$FeedName, [string]$Protocol)
    $base = Get-PackagingWebBase -OrgUrl $TargetOrg -Project $TargetProject
    switch ($Protocol) {
        'nuget' { "${base}_packaging/$FeedName/nuget/v3/index.json" }
        'npm'   { "${base}_packaging/$FeedName/npm/registry/" }
        'pypi'  { "${base}_packaging/$FeedName/pypi/upload/" }
        'upack' { "$TargetOrg" }
        default { $null }
    }
}

function Get-NuGetConfig {
    # Writes a nuget.config into the cache that registers the target feed as
    # source 'target' with the resolved credential (Entra token or fallback PAT)
    # as the basic-auth password, so 'dotnet nuget push' can authenticate. Azure
    # DevOps ignores the --api-key for auth and requires real source
    # credentials. Rewritten on every push so a renewed Entra token is always
    # the one on disk. Returns the config path.
    param($Feed, [string]$TargetSource)

    $dir = Get-CacheDir -Feed $Feed -Protocol 'nuget'
    $config = Join-Path $dir 'nuget.config'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="target" value="$TargetSource" />
  </packageSources>
  <packageSourceCredentials>
    <target>
      <add key="Username" value="ado" />
      <add key="ClearTextPassword" value="$script:TargetToken" />
    </target>
  </packageSourceCredentials>
</configuration>
"@
    Set-Content -LiteralPath $config -Value $xml -Encoding UTF8
    $config
}

function Migrate-NuGetPackage {
    param($Feed, $Package, $Version, [string]$Download, [string]$TargetSource)

    $name = $Package.name
    $ver = $Version.version
    # Download into the persistent cache (skipped if already present) and push
    # the cached file. Azure DevOps ignores --api-key for auth, so credentials
    # are supplied via a per-feed nuget.config holding the target PAT.
    $file = @(Save-VersionToCache -Feed $Feed -Package $Package -Version $Version -Protocol 'nuget')[0]
    $script:LastPackageBytes = (Get-Item -LiteralPath $file).Length

    $config = Get-NuGetConfig -Feed $Feed -TargetSource $TargetSource
    & dotnet nuget push $file --source 'target' --api-key 'az' --configfile $config --skip-duplicate
    if ($LASTEXITCODE -ne 0) { throw "dotnet nuget push failed for $name $ver" }
}

function Migrate-NpmPackage {
    param($Feed, $Package, $Version, [string]$Download, [string]$TargetSource)

    $name = $Package.name
    $ver = $Version.version
    $file = @(Save-VersionToCache -Feed $Feed -Package $Package -Version $Version -Protocol 'npm')[0]
    $script:LastPackageBytes = (Get-Item -LiteralPath $file).Length

    # Configure a scoped .npmrc for the target registry with the resolved
    # credential (Entra token or fallback PAT) as the basic-auth password.
    $registry = $TargetSource -replace '^https:', ''
    $b64Pat = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($script:TargetToken))
    $npmrc = Join-Path (Get-CacheDir -Feed $Feed -Protocol 'npm') '.npmrc'
    @(
        "registry=$TargetSource"
        "${registry}:_password=$b64Pat"
        "${registry}:username=ado"
        "${registry}:email=ado@migration.local"
        "${registry}:always-auth=true"
    ) | Set-Content -Path $npmrc -Encoding ascii

    # npm refuses to publish a prerelease version (one with a semver '-suffix',
    # e.g. 0.18.3-rc.3) unless an explicit dist-tag is given, because it will
    # not move the 'latest' tag onto a prerelease. Derive a tag from the
    # prerelease label (e.g. 'rc' from 'rc.3'), falling back to 'prerelease', so
    # these versions publish without clobbering 'latest'. Stable versions keep
    # the default 'latest' tag.
    $publishArgs = @($file, '--userconfig', $npmrc, '--registry', $TargetSource)
    if ($ver -match '-') {
        $prerelease = ($ver -split '-', 2)[1]
        $tag = ($prerelease -split '[.\d]' | Where-Object { $_ })[0]
        if (-not $tag) { $tag = 'prerelease' }
        $publishArgs += @('--tag', $tag)
    }

    & npm publish @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "npm publish failed for $name $ver" }
}

function Migrate-PyPiPackage {
    param($Feed, $Package, $Version, [string]$Download, [string]$TargetSource)

    $name = $Package.name
    $ver = $Version.version

    # Download all distribution files into the persistent cache (skipped if
    # already present), then upload the cached files with twine.
    $files = @(Save-VersionToCache -Feed $Feed -Package $Package -Version $Version -Protocol 'pypi')
    if ($files.Count -eq 0) {
        throw "No distribution files found on the source Simple index for PyPI $name $ver."
    }
    $script:LastPackageBytes = @($files | Where-Object { Test-Path -LiteralPath $_ } |
        Get-Item | Measure-Object Length -Sum).Sum

    $env:TWINE_USERNAME = 'ado'
    $env:TWINE_PASSWORD = $script:TargetToken
    # Note: Azure Artifacts' PyPI upload endpoint does not support twine's
    # --skip-existing flag ('UnsupportedConfiguration'). Versions already present
    # on the target are filtered out earlier by Test-TargetHasVersion, so a plain
    # upload is normally sufficient. If a duplicate still slips through, the
    # endpoint returns a 409/'already exists' error; we treat that as success so
    # re-runs are idempotent.
    $output = Invoke-Twine -Arguments (@('upload', '--repository-url', $TargetSource) + $files) 2>&1
    $output | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String)
        if ($text -match '(?i)409|already exists|Conflict') {
            Write-Host "      Already exists on target: $name $ver" -ForegroundColor DarkGray
        }
        else {
            throw "twine upload failed for $name $ver`n$text"
        }
    }
}

function Migrate-UpackPackage {
    param($Feed, $Package, $Version, [string]$Download)

    $name = $Package.name
    $ver = $Version.version

    # Download into the persistent cache (skipped if already present).
    $files = @(Save-VersionToCache -Feed $Feed -Package $Package -Version $Version -Protocol 'upack')
    $pkgDir = Join-Path (Get-CacheDir -Feed $Feed -Protocol 'upack') "$name-$ver"
    $script:LastPackageBytes = @($files | Where-Object { Test-Path -LiteralPath $_ } |
        Get-Item | Measure-Object Length -Sum).Sum

    & az artifacts universal publish `
        --organization $TargetOrg `
        --feed $Feed.name `
        --name $name `
        --version $ver `
        --path $pkgDir `
        --description "Migrated from $SourceOrg" `
        $(if ($TargetProject) { @('--project', $TargetProject) }) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az universal publish failed for $name $ver" }
}

function Migrate-MavenPackage {
    param($Feed, $Package, $Version, [string]$Download, [string]$TargetSource)

    $name = $Package.name      # groupId:artifactId
    $ver = $Version.version
    $parts = $name -split ':'
    if ($parts.Count -lt 2) {
        Write-Warning "    Skipping Maven package with unexpected name '$name'."
        return
    }
    $groupId = $parts[0]
    $artifactId = $parts[1]

    # Download the jar + pom into the persistent cache (skipped if present).
    $files = @(Save-VersionToCache -Feed $Feed -Package $Package -Version $Version -Protocol 'maven')
    $jar = $files | Where-Object { $_ -like '*.jar' } | Select-Object -First 1
    $pom = $files | Where-Object { $_ -like '*.pom' } | Select-Object -First 1

    if (-not $jar -and -not $pom) {
        Write-Warning "    No jar/pom found for Maven $name $ver; skipping."
        return
    }

    $deployArgs = @(
        'deploy:deploy-file'
        "-DrepositoryId=target-feed"
        "-Durl=$TargetSource"
        "-DgroupId=$groupId"
        "-DartifactId=$artifactId"
        "-Dversion=$ver"
    )
    if ($pom) { $deployArgs += "-DpomFile=$pom" }
    if ($jar) { $deployArgs += "-Dfile=$jar" } else { $deployArgs += "-Dfile=$pom"; $deployArgs += '-Dpackaging=pom' }

    $script:LastPackageBytes = @(@($pom, $jar) |
        Where-Object { $_ -and (Test-Path $_) } |
        Get-Item | Measure-Object Length -Sum).Sum

    & mvn @deployArgs
    if ($LASTEXITCODE -ne 0) { throw "mvn deploy failed for $name $ver" }
}

#endregion Per-protocol migration ---------------------------------------------

#region Summary & inventory ---------------------------------------------------

# Per-feed / per-protocol tallies collected during inventory or migration. Keyed
# by "feed|protocol" so a feed ('channel') can carry several package types.
$script:Summary = [ordered]@{}
$script:LastPackageBytes = [int64]0
$script:TwineInvoker = $null

function Add-SummaryRow {
    param(
        [string]$Feed,
        [string]$Protocol,
        [int]$Packages = 0,
        [int]$Versions = 0,
        [int64]$Bytes = 0
    )
    $key = "$Feed|$Protocol"
    if (-not $script:Summary.Contains($key)) {
        $script:Summary[$key] = [pscustomobject]@{
            Feed     = $Feed
            Protocol = $Protocol
            Packages = 0
            Versions = 0
            Bytes    = [int64]0
        }
    }
    $row = $script:Summary[$key]
    $row.Packages += $Packages
    $row.Versions += $Versions
    $row.Bytes    += $Bytes
}

function Write-MigrationSummary {
    param([string]$Title = 'Summary')

    Write-Step $Title
    if ($script:Summary.Count -eq 0) {
        Write-Host '    Nothing to report.' -ForegroundColor DarkGray
        return
    }

    $rows = $script:Summary.Values | Sort-Object Feed, Protocol
    $feedGroups = $rows | Group-Object Feed

    foreach ($feedGroup in $feedGroups) {
        $fBytes = ($feedGroup.Group | Measure-Object Bytes -Sum).Sum
        $fPkgs  = ($feedGroup.Group | Measure-Object Packages -Sum).Sum
        $fVers  = ($feedGroup.Group | Measure-Object Versions -Sum).Sum
        Write-Host ("  Feed '{0}': {1} package(s), {2} version(s), {3}" -f `
                $feedGroup.Name, $fPkgs, $fVers, (Format-Bytes $fBytes)) -ForegroundColor Cyan
        foreach ($r in $feedGroup.Group) {
            Write-Host ("      {0,-6} {1,4} pkg  {2,4} ver  {3,12}" -f `
                    $r.Protocol, $r.Packages, $r.Versions, (Format-Bytes $r.Bytes)) -ForegroundColor Gray
        }
    }

    $totalBytes = ($rows | Measure-Object Bytes -Sum).Sum
    $totalPkgs  = ($rows | Measure-Object Packages -Sum).Sum
    $totalVers  = ($rows | Measure-Object Versions -Sum).Sum
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    Write-Host ("  TOTAL: {0} feed(s), {1} package(s), {2} version(s), {3}" -f `
            @($feedGroups).Count, $totalPkgs, $totalVers, (Format-Bytes $totalBytes)) -ForegroundColor Green
}

function Export-MigrationSummaryCsv {
    # Writes the collected summary as a CSV: one row per feed/protocol plus a
    # human-readable size column. The parent directory is created if needed.
    param([string]$Path)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $rows = $script:Summary.Values | Sort-Object Feed, Protocol | ForEach-Object {
        [pscustomobject]@{
            SourceProject = $SourceProject
            Feed          = $_.Feed
            Protocol      = $_.Protocol
            Packages      = $_.Packages
            Versions      = $_.Versions
            Bytes         = $_.Bytes
            Size          = Format-Bytes $_.Bytes
        }
    }
    # Append when the file already exists so multiple invocations (e.g. one per
    # source project) accumulate into a single report.
    if (Test-Path -LiteralPath $Path) {
        $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Append
    }
    else {
        $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
    Write-Step "Summary CSV written: $Path"
}

function Invoke-FeedInventory {
    # Read-only discovery of a single feed's complete contents. This reports the
    # FULL state of the source feed - every package and every version, including
    # upstream-cached versions - regardless of what any migration run did or
    # would skip. It is a snapshot of the source, not a record of this run.
    param($Feed)

    Write-Step "Feed: $($Feed.name)"
    # Renew a near-expiry Entra token before this feed's probes (cache hit otherwise).
    Initialize-SourceAuth
    $packages = Get-FeedPackages -FeedId $Feed.id
    foreach ($pkg in $packages) {
        $protocol = "$($pkg.protocolType)".ToLowerInvariant()
        if ($script:WantedProtocols -notcontains $protocol) { continue }

        $versions = @($pkg.versions)
        if ($versions.Count -eq 0) { continue }
        $bytes = [int64]0
        foreach ($v in $versions) {
            $bytes += Get-VersionSizeBytes -Feed $Feed -Package $pkg -Version $v -Protocol $protocol
        }
        Add-SummaryRow -Feed $Feed.name -Protocol $protocol -Packages 1 -Versions $versions.Count -Bytes $bytes
        Write-Host ("    {0} [{1}] - {2} version(s) ({3})" -f `
                $pkg.name, $protocol, $versions.Count, (Format-Bytes $bytes)) -ForegroundColor Gray
    }
}

#endregion Summary & inventory ------------------------------------------------

function Migrate-Feed {
    param($Feed, [string]$WorkRoot)

    Write-Step "Feed: $($Feed.name)"
    # Renew near-expiry Entra tokens before this feed's sync (cache hits otherwise).
    Initialize-SourceAuth
    Initialize-TargetAuth
    $targetFeed = New-TargetFeed -SourceFeed $Feed
    # Defend against a function accidentally emitting extra objects: keep only
    # the actual feed (the one carrying an 'id').
    if ($targetFeed -is [array]) {
        $targetFeed = $targetFeed | Where-Object { $_.PSObject.Properties['id'] } | Select-Object -Last 1
    }
    if (-not $targetFeed -and -not $WhatIfPreference) { return }

    # Feed-only sync: the feed, its upstream sources and permissions have been
    # created/synced by New-TargetFeed above; skip all package movement.
    if ($SkipArtifacts) {
        Write-Host "    Skipping package artifacts (feed-only sync)." -ForegroundColor DarkGray
        return
    }

    # Snapshot the versions already in the target feed so we skip re-uploading
    # (and re-downloading) anything that's been migrated on a previous run.
    $existing = @{}
    if ($targetFeed -and $targetFeed.PSObject.Properties['id']) {
        $existing = Get-TargetVersionLookup -FeedId $targetFeed.id
        Write-Step ("Target feed has {0} existing version(s); these will be skipped." -f $existing.Count)
    }

    # Enumerate once, then keep only packages whose protocol we're migrating so
    # the progress counter reflects the real amount of work (and not protocols
    # that will be skipped).
    $packages = @(Get-FeedPackages -FeedId $Feed.id | Where-Object {
            $script:WantedProtocols -contains "$($_.protocolType)".ToLowerInvariant()
        })
    $totalPackages = $packages.Count
    Write-Step ("Feed '{0}': {1} package(s) to process." -f $Feed.name, $totalPackages)

    $pkgIndex = 0
    foreach ($pkg in $packages) {
        $pkgIndex++
        # Re-resolve both credentials so an Entra token nearing expiry is
        # renewed before this package's downloads and publishes start.
        Initialize-SourceAuth
        Initialize-TargetAuth
        $protocol = "$($pkg.protocolType)".ToLowerInvariant()

        Write-Host ("    [{0}/{1}] {2} [{3}]" -f $pkgIndex, $totalPackages, $pkg.name, $protocol) -ForegroundColor Cyan
        Write-Progress -Activity ("Migrating feed '{0}'" -f $Feed.name) `
            -Status ("Package {0} of {1}: {2}" -f $pkgIndex, $totalPackages, $pkg.name) `
            -PercentComplete (($pkgIndex / [math]::Max($totalPackages, 1)) * 100)

        $targetSource = Get-TargetFeedSourceUrl -FeedName $Feed.name -Protocol $protocol
        $feedDownload = Join-Path $WorkRoot ($Feed.name + '_' + $protocol)

        $migratable = @(Select-MigratableVersions -Versions $pkg.versions)
        if ($migratable.Count -eq 0) { continue }

        $verIndex = 0
        $verTotal = $migratable.Count
        $pkgVersions = 0
        $pkgBytes = [int64]0
        foreach ($v in $migratable) {
            $verIndex++
            $label = "$($pkg.name) $($v.version) [$protocol] ($verIndex/$verTotal)"
            if (Test-TargetHasVersion -Lookup $existing -Name $pkg.name -Version $v.version) {
                # Already in the target: it was migrated by a previous run, so it
                # still counts toward the total migrated state. Size is probed
                # over HTTP (no download) so the summary stays accurate.
                Write-Host "    Skipped (already in target) $label" -ForegroundColor DarkGray
                $pkgVersions++
                $pkgBytes += Get-VersionSizeBytes -Feed $Feed -Package $pkg -Version $v -Protocol $protocol
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($label, "Migrate to $($Feed.name)")) {
                $pkgVersions++   # Counted as planned under -WhatIf.
                continue
            }
            New-Item -ItemType Directory -Path $feedDownload -Force | Out-Null
            $script:LastPackageBytes = [int64]0
            try {
                switch ($protocol) {
                    'nuget' { Migrate-NuGetPackage -Feed $Feed -Package $pkg -Version $v -Download $feedDownload -TargetSource $targetSource }
                    'npm'   { Migrate-NpmPackage   -Feed $Feed -Package $pkg -Version $v -Download $feedDownload -TargetSource $targetSource }
                    'pypi'  { Migrate-PyPiPackage  -Feed $Feed -Package $pkg -Version $v -Download $feedDownload -TargetSource $targetSource }
                    'maven' { Migrate-MavenPackage -Feed $Feed -Package $pkg -Version $v -Download $feedDownload -TargetSource $targetSource }
                    'upack' { Migrate-UpackPackage -Feed $Feed -Package $pkg -Version $v -Download $feedDownload }
                    default { Write-Warning "    Unsupported protocol '$protocol' for $($pkg.name); skipping." }
                }
                Write-Host "    Migrated $label" -ForegroundColor Green
                $pkgVersions++
                $pkgBytes += $script:LastPackageBytes
            }
            catch {
                Write-Warning "    FAILED $label : $($_.Exception.Message)"
            }
        }

        if ($pkgVersions -gt 0) {
            Add-SummaryRow -Feed $Feed.name -Protocol $protocol -Packages 1 -Versions $pkgVersions -Bytes $pkgBytes
        }
    }

    Write-Progress -Activity ("Migrating feed '{0}'" -f $Feed.name) -Completed
}

#region Main ------------------------------------------------------------------

# Ambient-first credential resolution: Entra then the -SourcePat/-TargetPat
# fallbacks, renewed per feed and package (see Initialize-SourceAuth). Inventory
# is read-only against the source, so the target credential is only resolved for
# a real migration run.
$script:SourceAuthMode = $null
$script:TargetAuthMode = $null
Initialize-SourceAuth
if (-not $Inventory) { Initialize-TargetAuth }

# Establish the persistent download cache. Files are fetched into here once and
# reused across runs (inventory sizing and migration upload share it), so the
# cache must survive between invocations. When no WorkPath is supplied we fall
# back to a stable, named folder under TEMP rather than a random one so a bare
# run can still benefit from caching.
$script:UsingTempCache = $false
if (-not $WorkPath) {
    $WorkPath = Join-Path ([System.IO.Path]::GetTempPath()) 'ado-artifact-migration-cache'
    $script:UsingTempCache = $true
}
New-Item -ItemType Directory -Path $WorkPath -Force | Out-Null
$script:CacheRoot = $WorkPath
Write-Step "Cache directory: $WorkPath"

# Inventory is read-only: skip target auth requirements.
if ($Inventory) {
    $feeds = Get-SourceFeeds
    if (-not $feeds) {
        Write-Warning "No feeds found in source (FeedName filter: '$FeedName')."
        return
    }
    Write-Step ("Inventory: found {0} feed(s) to inspect." -f @($feeds).Count)
    foreach ($feed in $feeds) {
        Invoke-FeedInventory -Feed $feed
    }
    Write-MigrationSummary -Title 'Inventory - artifacts to be migrated'
    if ($CsvPath) { Export-MigrationSummaryCsv -Path $CsvPath }
    return
}

try {
    $feeds = Get-SourceFeeds
    if (-not $feeds) {
        Write-Warning "No feeds found in source (FeedName filter: '$FeedName')."
        return
    }
    Write-Step ("Found {0} feed(s) to process." -f @($feeds).Count)

    foreach ($feed in $feeds) {
        Migrate-Feed -Feed $feed -WorkRoot $WorkPath
    }

    Write-MigrationSummary -Title 'Migration summary'
    if ($CsvPath) { Export-MigrationSummaryCsv -Path $CsvPath }
    Write-Step $(if ($SkipArtifacts) { 'Feed sync complete.' } else { 'Artifact migration complete.' })
}
finally {
    # Only remove the download cache when it lives in a throwaway TEMP folder and
    # the caller did not ask to keep it. A caller-supplied WorkPath is treated as
    # a persistent cache and is never deleted.
    if ($script:UsingTempCache -and -not $KeepDownloads -and (Test-Path $WorkPath)) {
        Write-Host "Cleaning up cache directory $WorkPath" -ForegroundColor DarkGray
        Remove-Item -Path $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion Main ---------------------------------------------------------------
