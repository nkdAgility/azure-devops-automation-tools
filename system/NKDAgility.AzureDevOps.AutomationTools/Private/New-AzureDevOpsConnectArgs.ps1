function New-AzureDevOpsConnectArgs {
    <#
    .SYNOPSIS
    Builds the Connect-AzAccount arguments for signing in to Azure DevOps.

    .DESCRIPTION
    One place for the sign-in shape, because it is needed twice: before the first token,
    and again when an existing context turns out to be unable to mint one.

    -AuthScope is the important part. A tenant with conditional access can require MFA for
    the Azure DevOps resource SPECIFICALLY, so a perfectly good context - right account,
    right tenant, signed in minutes ago - still fails with 'Authentication failed against
    resource 499b84ac-... User interaction is required'. Az names the remedy in that
    message: sign in scoped to the resource. Passing it up front avoids the round trip.

    The parameter is only added when the installed Az.Accounts supports it, so an older
    version degrades to the previous behaviour rather than failing on an unknown argument.

    .PARAMETER TenantId
    Entra tenant to pin the sign-in to.

    .PARAMETER Resource
    Resource (application ID) the token is for - the Azure DevOps app.

    .PARAMETER AccountId
    Optional UPN to sign in as, so the sign-in does not land on an account picker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$Resource,
        [string]$AccountId
    )

    $connect = @{
        TenantId      = $TenantId
        ErrorAction   = 'Stop'
        WarningAction = 'SilentlyContinue'
    }
    if ($AccountId) { $connect.AccountId = $AccountId }

    $supportsAuthScope = $false
    try {
        $supportsAuthScope = (Get-Command Connect-AzAccount -ErrorAction Stop).Parameters.ContainsKey('AuthScope')
    }
    catch { $supportsAuthScope = $false }
    if ($supportsAuthScope) { $connect.AuthScope = $Resource }

    return $connect
}
