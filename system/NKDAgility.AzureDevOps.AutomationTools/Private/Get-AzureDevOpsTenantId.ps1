function Get-AzureDevOpsTenantId {
    <#
    .SYNOPSIS
    Discovers the Entra tenant that backs an Azure DevOps collection, or $null.

    .DESCRIPTION
    Azure DevOps returns the tenant GUID in the 'X-VSS-ResourceTenant' response header of
    an unauthenticated connectionData probe, so no credential is needed to find it.

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

    $tenantId = $null
    try {
        $uri = '{0}/_apis/connectionData?api-version=7.1-preview' -f $Collection.TrimEnd('/')
        $response = Invoke-WebRequest -Uri $uri -Method Get -SkipHttpErrorCheck -ErrorAction Stop
        $raw = $response.Headers['X-VSS-ResourceTenant']
        if ($raw) {
            # The header can be an array and/or comma-separated; take the first GUID.
            $tenantId = (($raw -join ',') -split ',' |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -as [guid] -and $_ -ne [guid]::Empty } |
                    Select-Object -First 1)
        }
    }
    catch {
        Write-Verbose "Tenant discovery failed for '$Collection': $($_.Exception.Message)"
    }

    $script:TenantIdCache[$key] = $tenantId
    return $tenantId
}
