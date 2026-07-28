function Resolve-WitAdminPath {
    [CmdletBinding()]
    param([string]$WitAdminPath)

    if ($WitAdminPath) {
        if (Test-Path -LiteralPath $WitAdminPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $WitAdminPath).Path
        }
        throw "Unable to find witadmin at '$WitAdminPath'."
    }

    $command = Get-Command 'witadmin.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $visualStudioRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio'
    $match = Get-ChildItem -Path $visualStudioRoot -Filter 'witadmin.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($match) {
        return $match.FullName
    }

    throw 'Unable to find witadmin.exe on PATH or under the Visual Studio installation directory.'
}
