function New-ExportSnapshot {
    <#
    .SYNOPSIS
    Creates a dated export-snapshot folder pair (xml/ and json/) for a source under exports\.

    .DESCRIPTION
    Exports from client servers are stored as pristine, dated snapshots:
    exports\<Source>\<yyyyMMdd>\xml\ for old-style exports (witadmin work item types,
    categories, process configuration, global lists, process templates) and ...\json\ for
    new-style exports (inherited process JSON via process-migrator or the REST APIs).
    Returns the snapshot folder so export commands can write straight into it.

    .PARAMETER Source
    The collection or organisation name the export comes from.

    .PARAMETER Date
    Snapshot date (defaults to today); folder name is yyyyMMdd.

    .PARAMETER Path
    Workspace root. Defaults to the initialised workspace's exports folder.

    .EXAMPLE
    $snapshot = New-ExportSnapshot -Source 'BlueMountain'
    witadmin exportprocessconfig /collection:$collection /p:$project /f:"$snapshot\xml\$project.ProcessConfiguration.xml"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [datetime]$Date = (Get-Date),

        [string]$Path
    )

    $exportsFolder = if ($Path) { Join-Path $Path 'exports' } else { (Get-AutomationWorkspace).ExportsFolder }

    $snapshotFolder = Join-Path $exportsFolder (Join-Path $Source $Date.ToString('yyyyMMdd'))
    foreach ($format in 'xml', 'json') {
        New-Item -Path (Join-Path $snapshotFolder $format) -ItemType Directory -Force | Out-Null
    }

    Write-FixStep "Export snapshot ready: $snapshotFolder"
    return Get-Item -LiteralPath $snapshotFolder
}
