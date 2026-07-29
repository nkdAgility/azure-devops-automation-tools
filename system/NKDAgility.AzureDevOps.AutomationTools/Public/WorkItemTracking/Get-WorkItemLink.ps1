function Get-WorkItemLink {
    <#
    .SYNOPSIS
    Enumerates every work item link of the given link types, with both endpoints resolved.

    .DESCRIPTION
    Runs a WIQL WorkItemLinks query per link type end, then reads the work items involved so the
    result carries titles, types, states and projects rather than bare ids. Link comments are
    recovered from the source work item's relations in the same pass.

    Defaults to every CUSTOM link type in the collection, which is exactly the set
    Remove-WorkItemLinkType destroys. Only forward ends are queried, so each link is reported
    once.

    .PARAMETER ReferenceName
    Link types to enumerate. Accepts bare reference names ('Custom.Affects') or specific ends
    ('Custom.Affects-Forward'). Omit to enumerate all custom link types.

    .PARAMETER Project
    Scope the query to one team project. Use this when the collection-wide query trips the WIQL
    result limit.

    .PARAMETER Pat
    Personal access token. Omit to authenticate as the current Windows identity.

    .EXAMPLE
    Get-WorkItemLink -Collection $collection | Format-Table LinkType, SourceId, TargetId

    .EXAMPLE
    Get-WorkItemLink -Collection $collection -ReferenceName 'Custom.Affects' -Project 'Mammoth'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string[]]$ReferenceName,
        [string]$Project,
        [string]$Pat,
        [string]$ApiVersion = '5.0'
    )

    # Resolve the requested names to concrete link type ends, and keep the forward ends only so
    # a link is not reported once from each side.
    $ends = if ($ReferenceName) {
        foreach ($name in $ReferenceName) {
            $matched = @(Get-WorkItemLinkType -Collection $Collection -ReferenceName $name -Pat $Pat -ApiVersion $ApiVersion)
            if (-not $matched) { throw "No work item link type in '$Collection' matches reference name '$name'." }
            $matched | Where-Object { -not $_.IsReverse }
        }
    }
    else {
        Get-WorkItemLinkType -Collection $Collection -CustomOnly -Pat $Pat -ApiVersion $ApiVersion |
            Where-Object { -not $_.IsReverse }
    }
    $ends = @($ends)

    if ($ends.Count -eq 0) {
        if ($ReferenceName) {
            # Every match was a reverse end, so the forward filter emptied the set.
            Write-FixStep "'$($ReferenceName -join ', ')' matched only reverse link type ends - the forward end carries the links, so there is nothing to enumerate"
        }
        else {
            Write-FixStep "No custom work item link types found in the collection - nothing to enumerate"
        }
        return
    }

    $wiqlPath = if ($Project) { "$([uri]::EscapeDataString($Project))/_apis/wit/wiql" } else { '_apis/wit/wiql' }

    $relations = foreach ($end in $ends) {
        Write-FixStep "Querying links of type '$($end.Name)' ($($end.ReferenceName))"
        $wiql = "SELECT [System.Id] FROM WorkItemLinks WHERE [System.Links.LinkType] = '$($end.ReferenceName)' MODE (MustContain)"
        try {
            $response = Invoke-AzureDevOpsApi -Collection $Collection -Path $wiqlPath -Method Post -Pat $Pat -ApiVersion $ApiVersion -Body @{ query = $wiql }
        }
        catch {
            if ("$_" -match 'VS402337') {
                throw "The link query for '$($end.ReferenceName)' exceeded the WIQL result limit. Re-run per project with -Project. $_"
            }
            throw
        }

        # MustContain returns a seed row per source work item with rel = null alongside the real
        # link rows; only the latter describe a relationship.
        foreach ($relation in @($response.workItemRelations)) {
            if (-not $relation.rel) { continue }
            if (-not $relation.source -or -not $relation.target) { continue }
            [pscustomobject]@{
                End      = $end
                SourceId = [int]$relation.source.id
                TargetId = [int]$relation.target.id
            }
        }
    }
    $relations = @($relations)

    Write-FixStep "Found $($relations.Count) link(s) across $($ends.Count) link type(s)"
    if ($relations.Count -eq 0) { return }

    # Both sides wrapped in @() first: with a single relation the property accessors return
    # scalars, and int + int would add rather than concatenate.
    $details = Get-WorkItemDetailMap -Collection $Collection -Pat $Pat -ApiVersion $ApiVersion `
        -Id (@($relations.SourceId) + @($relations.TargetId))

    foreach ($relation in $relations) {
        $source = $details[$relation.SourceId]
        $target = $details[$relation.TargetId]

        # The comment lives on the source work item's matching relation, identified by the link
        # type end plus the id at the tail of the relation url.
        $comment = ''
        if ($source) {
            $match = @($source.relations | Where-Object {
                    $_.rel -eq $relation.End.ReferenceName -and ($_.url -split '/')[-1] -eq "$($relation.TargetId)"
                }) | Select-Object -First 1
            if ($match -and $match.attributes.comment) { $comment = $match.attributes.comment }
        }

        [pscustomobject]@{
            LinkType          = $relation.End.Name
            LinkTypeReference = $relation.End.ReferenceName
            Topology          = $relation.End.Topology
            SourceId          = $relation.SourceId
            SourceProject     = if ($source) { $source.fields.'System.TeamProject' } else { '' }
            SourceType        = if ($source) { $source.fields.'System.WorkItemType' } else { '' }
            SourceTitle       = if ($source) { $source.fields.'System.Title' } else { '' }
            SourceState       = if ($source) { $source.fields.'System.State' } else { '' }
            TargetId          = $relation.TargetId
            TargetProject     = if ($target) { $target.fields.'System.TeamProject' } else { '' }
            TargetType        = if ($target) { $target.fields.'System.WorkItemType' } else { '' }
            TargetTitle       = if ($target) { $target.fields.'System.Title' } else { '' }
            TargetState       = if ($target) { $target.fields.'System.State' } else { '' }
            Comment           = $comment
        }
    }
}
