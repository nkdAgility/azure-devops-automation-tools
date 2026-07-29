function Get-WorkItemLinkType {
    <#
    .SYNOPSIS
    Lists the work item link types defined in a collection, flagging which are custom.

    .DESCRIPTION
    Reads _apis/wit/workitemrelationtypes and returns one object per link type END. A directional
    link type appears twice - 'Custom.Affects-Forward' and 'Custom.Affects-Reverse' - describing
    the same underlying links from each side, so enumerating links should use the forward ends
    only (IsReverse = $false) to avoid reporting every link twice.

    A link type is treated as custom when its reference name is not in the System or Microsoft
    namespace. Those are the ones the Data Import Tool rejects and Remove-WorkItemLinkType
    deletes, taking every link of that type with them.

    Only relation types whose usage is 'workItemLink' are returned; attachment, hyperlink and
    artifact relations are excluded.

    .PARAMETER ReferenceName
    Return only this link type. Accepts either the bare link type reference name
    ('Custom.Affects', which matches both ends) or a specific end ('Custom.Affects-Forward').

    .PARAMETER CustomOnly
    Return only custom (non-System, non-Microsoft) link types.

    .PARAMETER Pat
    Personal access token. Omit to authenticate as the current Windows identity, which is the
    normal case for an on-premises collection.

    .EXAMPLE
    Get-WorkItemLinkType -Collection $collection -CustomOnly | Format-Table Name, ReferenceName, Topology

    .EXAMPLE
    Get-WorkItemLinkType -Collection $collection -ReferenceName 'Custom.Affects'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$ReferenceName,
        [switch]$CustomOnly,
        [string]$Pat,
        [string]$ApiVersion = '5.0'
    )

    $response = Invoke-AzureDevOpsApi -Collection $Collection -Path '_apis/wit/workitemrelationtypes' -Pat $Pat -ApiVersion $ApiVersion

    foreach ($type in @($response.value)) {
        if ($type.attributes.usage -ne 'workItemLink') { continue }

        $isCustom = $type.referenceName -notmatch '^(System|Microsoft)\.'
        if ($CustomOnly -and -not $isCustom) { continue }

        if ($ReferenceName -and $type.referenceName -notin @($ReferenceName, "$ReferenceName-Forward", "$ReferenceName-Reverse")) {
            continue
        }

        [pscustomobject]@{
            Name          = $type.name
            ReferenceName = $type.referenceName
            Topology      = $type.attributes.topology
            IsCustom      = $isCustom
            IsReverse     = $type.referenceName.EndsWith('-Reverse')
            IsEditable    = [bool]$type.attributes.editable
            IsEnabled     = [bool]$type.attributes.enabled
        }
    }
}
