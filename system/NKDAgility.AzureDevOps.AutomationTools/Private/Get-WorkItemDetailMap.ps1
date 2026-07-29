function Get-WorkItemDetailMap {
    <#
    .SYNOPSIS
    Reads work items by id (with their relations) and returns a hashtable keyed by id.

    .DESCRIPTION
    Used to turn the bare id pairs a WIQL link query returns into a human-readable inventory.
    Requests come in chunks of 200 - the maximum the work items endpoint accepts - and are
    expanded with relations so link comments come back in the same pass as the fields.

    A chunk that fails (typically because one of its work items has been destroyed) is warned
    about and skipped: an inventory with missing titles is still worth having, an aborted export
    before a destructive delete is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [int[]]$Id,
        [string]$Pat,
        [string]$ApiVersion = '5.0'
    )

    $map = @{}
    $ids = @($Id | Sort-Object -Unique)
    if ($ids.Count -eq 0) { return $map }

    $chunkSize = 200
    for ($offset = 0; $offset -lt $ids.Count; $offset += $chunkSize) {
        $chunk = @($ids[$offset..([Math]::Min($offset + $chunkSize - 1, $ids.Count - 1))])
        Write-FixStep "  reading work items $($offset + 1)-$($offset + $chunk.Count) of $($ids.Count)"
        try {
            $response = Invoke-AzureDevOpsApi -Collection $Collection -Pat $Pat -ApiVersion $ApiVersion `
                -Path '_apis/wit/workitems' -Query @{ ids = ($chunk -join ','); '$expand' = 'relations' }
        }
        catch {
            Write-Warning "Could not read work item details for ids $($chunk -join ','). Titles will be blank for these. $($_.Exception.Message)"
            continue
        }
        foreach ($workItem in @($response.value)) {
            $map[[int]$workItem.id] = $workItem
        }
    }

    return $map
}
