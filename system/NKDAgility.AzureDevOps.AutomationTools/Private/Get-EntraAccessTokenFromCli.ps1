function Get-EntraAccessTokenFromCli {
    <#
    .SYNOPSIS
    An Azure DevOps access token from the signed-in Azure CLI, or $null.

    .DESCRIPTION
    Az PowerShell and the Azure CLI keep SEPARATE credential stores. Customer workspaces
    document 'az login' everywhere - runbooks, manifest.yaml, the CI setup guide - so an
    operator who has done exactly what they were told still had no context as far as
    Get-AzContext was concerned, and was prompted to sign in again. This reads the store
    they actually used.

    Returns a @{ Token; ExpiresOn } hashtable shaped for the caller's token cache, or
    $null when the CLI is absent, not signed in, has no account in the tenant, or cannot
    mint a token for any other reason. Never throws: it is one source among several, and
    an unavailable source is not an error.

    .PARAMETER TenantId
    The Entra tenant the token must come from.

    .PARAMETER Resource
    The resource (application ID) to request the token for.

    .PARAMETER AccountId
    Optional. The user principal name the organisation expects. When the CLI is signed in
    as somebody else, this returns $null rather than a token for the wrong identity - the
    caller then signs in properly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TenantId,
        [Parameter(Mandatory)] [string]$Resource,
        [string]$AccountId
    )

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { return $null }

    # Native command failures must stay inspectable rather than terminating, since 'not
    # signed in' and 'no account in this tenant' are ordinary outcomes here.
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'

    try {
        if ($AccountId) {
            # Only trust the CLI when it holds the identity this organisation asked for.
            $signedIn = & az account show --query 'user.name' -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $signedIn) { return $null }
            if (([string]$signedIn).Trim() -ine $AccountId) {
                Write-Verbose "Azure CLI is signed in as '$signedIn', not '$AccountId'; skipping the CLI."
                return $null
            }
        }

        $json = & az account get-access-token --resource $Resource --tenant $TenantId -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }

        $parsed = ($json -join '') | ConvertFrom-Json
        if (-not $parsed.accessToken) { return $null }

        $expiresOn = if ($parsed.expiresOn) {
            try { [datetime]::Parse($parsed.expiresOn) } catch { (Get-Date).AddMinutes(45) }
        }
        else { (Get-Date).AddMinutes(45) }

        Write-Verbose "Acquired an Azure DevOps token from the Azure CLI for tenant $TenantId."
        return @{ Token = [string]$parsed.accessToken; ExpiresOn = $expiresOn }
    }
    catch {
        Write-Verbose "Azure CLI token acquisition failed: $($_.Exception.Message)"
        return $null
    }
}
