function Get-WorkItemTypeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$WorkItemType,
        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    $types = if ($WorkItemType) { @($WorkItemType) } else { Get-WorkItemType -Collection $Collection -Project $Project -WitAdminPath $executable }
    foreach ($type in $types) {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
        try {
            Invoke-WitAdminFix -WitAdminPath $executable -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$type", "/f:$file")
            $xml = [xml](Get-Content -LiteralPath $file -Raw)
            foreach ($state in $xml.SelectNodes('//WORKFLOW/STATES/STATE')) {
                [pscustomobject]@{
                    Project      = $Project
                    WorkItemType = $type
                    State        = $state.GetAttribute('value')
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}
