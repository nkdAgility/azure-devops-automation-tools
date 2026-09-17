function Update-ProcessConfigurationFixFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [scriptblock]$Mutation
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Process configuration fix file '$Path' does not exist. Export it first." }
    $xml = [xml](Get-Content -LiteralPath $Path -Raw)
    & $Mutation $xml
    $xml.Save($Path)
    Write-FixStep "Saved '$Path'"
}
