function Get-AzureDevOpsTenantId {
    <#
    .SYNOPSIS
    Discovers the Entra tenant that backs an Azure DevOps collection, or $null.

    .DESCRIPTION
    Azure DevOps returns the tenant GUID in the 'X-VSS-ResourceTenant' response header,
    so no credential is needed to find it - but only on a response that actually
    challenges for authentication. Two probes are tried in order:

      1. connectionData, unauthenticated. Cheap, and enough on collections that answer
         it with the header.
      2. An endpoint that REQUIRES authentication (projects), with redirects not
         followed. Anonymous connectionData answers 203 with no tenant header at all on
         dev.azure.com today, so a collection is only proved non-Entra by the second
         probe coming back empty as well.

    Probe 1 alone reported EVERY organisation as non-Entra-backed - including ones that
    plainly are - which silently downgraded ambient Entra auth to the stored PAT
    everywhere. Hence the second probe: a false 'no tenant' is not a visible failure,
    it is a quiet fallback that only shows up as a missing-PAT error much later.

    Returns $null - never throws - when the collection is unreachable, or is an
    on-premises Azure DevOps Server collection with no Entra tenant behind it. The caller
    decides what that means; for Get-EntraAccessToken it means "use another auth method".

    Results are cached per collection for the session: this runs before every REST call
    that has not already resolved its auth.

    .PARAMETER Collection
    Collection or organisation URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection
    )

    $key = $Collection.TrimEnd('/').ToLowerInvariant()
    if (-not $script:TenantIdCache) { $script:TenantIdCache = @{} }
    if ($script:TenantIdCache.ContainsKey($key)) { return $script:TenantIdCache[$key] }

    $base = $Collection.TrimEnd('/')

    # The header can be an array and/or comma-separated, and an all-zero GUID means
    # 'no tenant' rather than a tenant - take the first real GUID, if any.
    $readTenant = {
        param($Response)
        if (-not $Response) { return $null }
        $raw = $null
        try { $raw = $Response.Headers['X-VSS-ResourceTenant'] } catch { return $null }
        if (-not $raw) { return $null }
        (($raw -join ',') -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -as [guid] -and $_ -ne [guid]::Empty } |
            Select-Object -First 1)
    }

    # ErrorAction is deliberately NOT 'Stop' on either probe. Refusing to follow the
    # sign-in redirect makes Invoke-WebRequest report an error, and under -ErrorAction
    # Stop that surfaces as an InvalidOperationException carrying NO .Response - the
    # headers are then unreachable and every collection looks non-Entra. Left
    # non-terminating, the 302 is returned normally and its headers can be read.
    $probes = @(
        # Anonymous connectionData.
        { Invoke-WebRequest -Uri ('{0}/_apis/connectionData?api-version=7.1-preview' -f $base) `
                -Method Get -SkipHttpErrorCheck -ErrorAction SilentlyContinue },
        # Authentication challenge: the sign-in redirect (or 401) names the tenant.
        # Redirects are NOT followed - following one lands on a login page that no
        # longer carries the header.
        { Invoke-WebRequest -Uri ('{0}/_apis/projects?api-version=7.1' -f $base) `
                -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue }
    )

    $tenantId = $null
    foreach ($probe in $probes) {
        try { $tenantId = & $readTenant (& $probe) }
        catch { Write-Verbose "Tenant discovery probe failed for '$Collection': $($_.Exception.Message)" }
        if ($tenantId) { break }
    }

    $script:TenantIdCache[$key] = $tenantId
    return $tenantId
}
