function Initialize-AzAccounts {
    <#
    .SYNOPSIS
    Ensures the Az.Accounts module is installed and imported.

    .DESCRIPTION
    Entra sign-in needs Az.Accounts. It is not declared in RequiredModules because the
    module must stay usable for witadmin and PAT work on a machine that has never signed
    in to Azure - a hard dependency would make every command need it.

    Installs for the current user only, so no elevation is required.

    Lifted from the NKDAClient-United-Machine Set-WorkItemStartId.ps1 script.
    #>
    [CmdletBinding()]
    param()

    if (Get-Module -Name Az.Accounts) { return }

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-FixStep 'Az.Accounts not found; installing it for the current user (needed for Entra sign-in).'
        # PowerShell Gallery requires TLS 1.2 on older configurations.
        try {
            [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch { Write-Verbose "Could not raise the TLS protocol: $($_.Exception.Message)" }

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
