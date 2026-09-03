function Resolve-AzureDevOpsAuth {
    <#
    .SYNOPSIS
    Resolves how to authenticate to one Azure DevOps collection or organisation.

    .DESCRIPTION
    The single answer to "which credential do I use here", shared by every engine so the
    six of them cannot drift apart. Resolution order, and why it is this order:

      1. A PAT that was actually supplied. An explicit credential is an INSTRUCTION, not
         a fallback: the caller named the identity to use for this organisation, so
         signing them in as somebody else first is wrong on its own terms. Once Entra
         sign-in became interactive, trying it first meant a browser prompt for an
         organisation whose credential was already sitting in the config, on a run that
         was meant to be unattended.

      2. Windows integrated, when the host is not the hosted service. Which ambient
         mechanism an organisation uses is decided by its HOST, and only two hosts are
         the cloud:

             https://dev.azure.com/<org>       cloud
             https://<org>.visualstudio.com    cloud (legacy)
             anything else                     Azure DevOps Server, on-premises

         On-premises means Windows integrated auth, which is not a credential to fetch
         and attach - it is the ABSENCE of one. Send no Authorization header and let the
         stack negotiate. Entra cannot succeed against such a host, so it is not tried:
         attempting it only produces a sign-in prompt for a server that never wanted one.

      3. Entra, for the hosted service. An Entra token works anywhere a PAT does - Bearer
         for REST, http.extraheader for git.

    Ambient identity is still the default whenever no PAT is supplied; 2 and 3 are both
    ambient. What this adds is that "ambient" means the right mechanism for the host,
    rather than Entra everywhere.

    Nothing is announced and nothing is cached here: the caller owns both, because an
    engine announces its mode once and re-resolves per repository so a long run can renew
    a near-expiry token.

    .PARAMETER Collection
    Collection or organisation URL, e.g. https://dev.azure.com/contoso or
    https://tfs.corp/DefaultCollection.

    .PARAMETER Pat
    Optional. When supplied it wins outright.

    .PARAMETER Label
    Used only in the error text, to say WHICH end could not authenticate: 'source',
    'target', or omitted for a single-endpoint engine.

    .OUTPUTS
    An object with:
      Mode       'PAT' | 'Windows' | 'Entra'
      Headers    hashtable for REST. EMPTY under Windows - that is the signal to the
                 caller to use default credentials rather than send a header.
      GitHeader  string for 'git -c http.extraheader=<value>'. EMPTY under Windows -
                 pass it through Get-AzureDevOpsGitAuthArgs, which then emits no option
                 at all. An empty option is not the same as an absent one: it makes git
                 send a blank Authorization header, which suppresses the negotiation
                 Windows auth depends on.
      Token      the raw credential, for tools that take one as a basic-auth password
                 rather than a header (nuget, npm, twine). EMPTY under Windows, because
                 there is no token - those tools cannot use Windows integrated auth and
                 the caller has to say so rather than send an empty password.

    .EXAMPLE
    $auth = Resolve-AzureDevOpsAuth -Collection $TargetOrg -Pat $TargetPat -Label 'target'
    $script:TargetHeaders = $auth.Headers
    $script:TargetHeader = $auth.GitHeader
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Pat,
        [string]$Label
    )

    if ($Pat) {
        return [pscustomobject]@{
            Mode      = 'PAT'
            Headers   = Get-AzureDevOpsAuthHeader -Pat $Pat
            GitHeader = 'AUTHORIZATION: Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
            Token     = $Pat
        }
    }

    if (-not (Test-AzureDevOpsHosted -Collection $Collection)) {
        return [pscustomobject]@{
            Mode      = 'Windows'
            Headers   = @{}
            GitHeader = ''
            Token     = ''
        }
    }

    $entraError = $null
    if (Get-Command Get-AzureDevOpsAccessToken -ErrorAction SilentlyContinue) {
        try {
            $token = Get-AzureDevOpsAccessToken -Collection $Collection
            if ($token) {
                return [pscustomobject]@{
                    Mode      = 'Entra'
                    Headers   = @{ Authorization = 'Bearer ' + $token }
                    GitHeader = "AUTHORIZATION: Bearer $token"
                    Token     = $token
                }
            }
        }
        catch { $entraError = $_.Exception.Message }
    }
    else {
        $entraError = 'the NKDAgility.AzureDevOps.AutomationTools module is not loaded'
    }

    $which = if ($Label) { "$Label " } else { '' }
    throw ("No {0}credential available for '{1}': no PAT was supplied and Entra sign-in failed ({2}). Add the PAT to secrets\secrets.json, or sign in to Entra." -f $which, $Collection, $entraError)
}
