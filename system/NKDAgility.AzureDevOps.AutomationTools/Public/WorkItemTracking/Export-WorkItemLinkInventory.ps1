function Export-WorkItemLinkInventory {
    <#
    .SYNOPSIS
    Writes a file recording every work item link of the given link types, before they are deleted.

    .DESCRIPTION
    Deleting a custom link type with witadmin deletelinktype also deletes every link of that
    type, and the links cannot be recovered afterwards. Run this first: it captures the full
    relationship set so the links can be reviewed with the customer, re-created as related links
    after the migration, or simply evidenced as "this is what was lost".

    Two files are written from the same data: a .json record carrying the collection, the link
    types covered and every link (the restoration source of truth), and a sibling .csv of the
    same rows for reading and sharing.

    A file is written even when there are no links, so a runbook step always leaves proof that
    the check ran.

    .PARAMETER ReferenceName
    Link types to record. Omit to record every custom link type in the collection.

    .PARAMETER Project
    Scope the query to one team project. Use when a collection-wide query trips the WIQL limit.

    .PARAMETER Path
    Destination .json file. Defaults to WorkItemLinks.json in today's export snapshot for the
    collection (see New-ExportSnapshot), which needs an initialised workspace.

    .PARAMETER Pat
    Personal access token. Omit to authenticate as the current Windows identity.

    .EXAMPLE
    Export-WorkItemLinkInventory -Collection $collection

    .EXAMPLE
    Export-WorkItemLinkInventory -Collection $collection -ReferenceName 'Custom.Affects' -Path 'C:\work\affects-links.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string[]]$ReferenceName,
        [string]$Project,
        [string]$Path,
        [string]$Pat,
        [string]$ApiVersion = '5.0'
    )

    Write-FixStep "Recording work item links before custom link types are deleted"

    $types = @(
        if ($ReferenceName) {
            foreach ($name in $ReferenceName) {
                Get-WorkItemLinkType -Collection $Collection -ReferenceName $name -Pat $Pat -ApiVersion $ApiVersion
            }
        }
        else {
            Get-WorkItemLinkType -Collection $Collection -CustomOnly -Pat $Pat -ApiVersion $ApiVersion
        }
    )

    $links = @(Get-WorkItemLink -Collection $Collection -ReferenceName $ReferenceName -Project $Project -Pat $Pat -ApiVersion $ApiVersion)

    if (-not $Path) {
        $source = ([uri]$Collection).Segments[-1].Trim('/')
        $snapshot = New-ExportSnapshot -Source $source
        $name = if ($ReferenceName -and $ReferenceName.Count -eq 1) { "WorkItemLinks.$($ReferenceName[0]).json" } else { 'WorkItemLinks.json' }
        $Path = Join-Path $snapshot.FullName (Join-Path 'json' $name)
    }
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
    $csvPath = [System.IO.Path]::ChangeExtension($Path, '.csv')

    $record = [ordered]@{
        collection  = $Collection
        project     = $Project
        exportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        linkTypes   = @($types | Select-Object Name, ReferenceName, Topology, IsCustom, IsReverse)
        linkCount   = $links.Count
        links       = $links
    }

    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
    $links | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

    Write-FixStep "  wrote $($links.Count) link(s) to $Path"
    Write-FixStep "  wrote $csvPath"
    if ($links.Count -eq 0) {
        Write-FixStep "  no links of these types exist - deleting them loses no relationships"
    }

    return [pscustomobject]@{
        Collection = $Collection
        LinkTypes  = @($types.ReferenceName)
        LinkCount  = $links.Count
        JsonPath   = $Path
        CsvPath    = $csvPath
    }
}
