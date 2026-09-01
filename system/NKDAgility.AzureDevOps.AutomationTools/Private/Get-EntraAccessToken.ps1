function Get-EntraAccessToken {
    <#
    .SYNOPSIS
    Acquires an Entra (Azure AD) access token for an Azure DevOps collection.

    .DESCRIPTION
    Entra is the default authentication for REST calls: a PAT or -UseDefaultCredentials is
    an explicit opt-out, not the other way round. Tokens are cached per tenant for the life
    of the session, so a run makes one interactive sign-in at most.

    The tenant is discovered from the collection itself. Azure DevOps returns the tenant
    GUID in the 'X-VSS-ResourceTenant' response header, so an unauthenticated probe is
    enough. Pinning sign-in to that tenant stops Az enumerating - and failing MFA on -
    every other tenant the signed-in user can see.

    An on-premises Azure DevOps Server collection is not Entra-backed and returns no such
    header. That is not an error here: the caller is told to pass -UseDefaultCredentials
    (the normal on-premises case) or a -Pat.

    Lifted from the NKDAClient-United-Machine Set-WorkItemStartId.ps1 script, generalised
    to work from a collection URL rather than a dev.azure.com organisation name.

    .PARAMETER Collection
    Collection or organisation URL, e.g. https://dev.azure.com/contoso.

    .PARAMETER Force
    Re-acquire even when a cached token exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Collection,

        [switch]$Force
    )

    $tenantId = Get-AzureDevOpsTenantId -Collection $Collection
    if (-not $tenantId) {
        throw "'$Collection' is not Entra-backed (no X-VSS-ResourceTenant), so Entra sign-in cannot be used. Pass -UseDefaultCredentials for an on-premises collection, or supply a -Pat."
    }

    if (-not $script:EntraTokenCache) { $script:EntraTokenCache = @{} }
    if (-not $Force -and $script:EntraTokenCache.ContainsKey($tenantId)) {
        $cached = $script:EntraTokenCache[$tenantId]
        # Renew a little before expiry rather than on it, so a long run does not fail mid-call.
        if ($cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) { return $cached.Token }
    }

    # 499b84ac-1321-427f-aa17-267ca6975798 is the well-known Azure DevOps application ID.
    $adoResource = '499b84ac-1321-427f-aa17-267ca6975798'

    # Which identity this organisation wants, when the engagement has said so.
    $account = Get-AzureDevOpsSignInAccount -Collection $Collection

    # The Azure CLI is a first-class source, not an afterthought: every runbook and doc in
    # a customer workspace says 'az login', and az keeps its own credential store that
    # Az PowerShell cannot see. Reading it first means a signed-in operator is never
    # prompted a second time for an identity they already have.
    $fromCli = Get-EntraAccessTokenFromCli -TenantId $tenantId -Resource $adoResource -AccountId $account
    if ($fromCli) {
        $script:EntraTokenCache[$tenantId] = $fromCli
        return $fromCli.Token
    }

    Initialize-AzAccounts

    # A context only counts when it is BOTH the right tenant and, where the organisation
    # named one, the right account - otherwise a token gets minted for whichever identity
    # happened to be current, which fails as a 403 much later and looks like a permissions
    # problem rather than a sign-in one.
    $isMatch = {
        param($Candidate)
        $Candidate -and $Candidate.Tenant.Id -eq $tenantId -and
        (-not $account -or $Candidate.Account.Id -ieq $account)
    }

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not (& $isMatch $context)) {
        # Prefer a context already signed in for this tenant/account over prompting again.
        $existing = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue |
                Where-Object { & $isMatch $_ }) | Select-Object -First 1
        if ($existing) {
            try {
                Set-AzContext -Context $existing -ErrorAction Stop | Out-Null
                $context = Get-AzContext -ErrorAction SilentlyContinue
            }
            catch { Write-Verbose "Could not select existing context: $($_.Exception.Message)" }
        }
    }

    if (-not (& $isMatch $context)) {
        $as = if ($account) { " as $account" } else { '' }
        Write-FixStep "Signing in to Entra tenant $tenantId$as ..."
        $connect = @{ TenantId = $tenantId; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        # Pins the sign-in to the intended identity instead of an account picker.
        if ($account) { $connect.AccountId = $account }
        Connect-AzAccount @connect | Out-Null
    }

    $token = Get-AzAccessToken -ResourceUrl $adoResource -TenantId $tenantId -ErrorAction Stop
    # AsSecureString became the default in newer Az.Accounts versions.
    $value = if ($token.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $token.Token).Password
    }
    else { $token.Token }

    $expiresOn = if ($token.ExpiresOn) { ([datetimeoffset]$token.ExpiresOn).LocalDateTime } else { (Get-Date).AddMinutes(45) }
    $script:EntraTokenCache[$tenantId] = @{ Token = $value; ExpiresOn = $expiresOn }
    return $value
}
