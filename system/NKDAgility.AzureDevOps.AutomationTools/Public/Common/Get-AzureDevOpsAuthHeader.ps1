function Get-AzureDevOpsAuthHeader {
    <#
    .SYNOPSIS
    Builds a Basic-auth header hashtable from an Azure DevOps PAT.

    .DESCRIPTION
    Returns @{ Authorization = 'Basic <base64>' } suitable for Invoke-RestMethod -Headers.
    Never log or print the returned value.

    .EXAMPLE
    $headers = Get-AzureDevOpsAuthHeader -Pat $org.pat
    Invoke-RestMethod -Uri "$($org.url)_apis/projects?$queryString" -Headers $headers
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$Pat
    )

    process {
        @{ Authorization = 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$Pat")) }
    }
}
