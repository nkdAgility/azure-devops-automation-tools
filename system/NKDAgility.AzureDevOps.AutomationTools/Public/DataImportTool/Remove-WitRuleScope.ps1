function Remove-WitRuleScope {
    <#
    .SYNOPSIS
    Removes for=/not= identity scoping from the rules and workflow transitions of a work item type.

    .DESCRIPTION
    Azure DevOps Services cannot resolve identity scoping during ProcessValidation: a single
    for= or not= attribute anywhere in a type definition fails the import with the bare message
    "Invalid process template: <Type>.xml:: Object reference not set to an instance of an object."
    Both field rules (VS237302) and workflow TRANSITION elements are affected.

    Pass -Identity with -AttributeName to strip one specific scope, or -All to strip every
    for= and not= in the type in a single export/import round trip. -All is the right choice
    when clearing a type for import, and avoids re-importing the same type once per identity.

    Removing scope from a TRANSITION is a behaviour change: a state change that was restricted
    to a group becomes available to everyone with write access.

    .EXAMPLE
    Remove-WitRuleScope -Project 'Mammoth' -WorkItemType 'Release' -AttributeName 'both' -Identity '[global]\Project Collection Administrators'

    .EXAMPLE
    Remove-WitRuleScope -Project 'Whistler' -WorkItemType 'Bug' -All
    #>
    [CmdletBinding(DefaultParameterSetName = 'Identity')]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [Parameter(Mandatory, ParameterSetName = 'Identity')] [ValidateSet('for', 'not', 'both')] [string]$AttributeName,
        [Parameter(Mandatory, ParameterSetName = 'Identity')] [string]$Identity,
        [Parameter(Mandatory, ParameterSetName = 'All')] [switch]$All,
        [string]$WitAdminPath
    )

    if ($All) {
        Write-FixStep "Removing ALL rule and transition scoping from work item type '$WorkItemType' in '$Project'"
        $attributes = @('for', 'not')
    }
    else {
        Write-FixStep "Removing rule scope '$Identity' ($AttributeName) from work item type '$WorkItemType' in '$Project'"
        $attributes = if ($AttributeName -eq 'both') { @('for', 'not') } else { @($AttributeName) }
    }

    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $changeCount = 0
        foreach ($attribute in $attributes) {
            $nodes = @($xml.SelectNodes("//*[@$attribute]"))
            if (-not $All) { $nodes = @($nodes | Where-Object { $_.GetAttribute($attribute) -eq $Identity }) }
            foreach ($node in $nodes) {
                # A TRANSITION is identified by its from/to states; a field rule by the
                # refname of the FIELD it sits under. Log whichever applies.
                $context = if ($node.LocalName -eq 'TRANSITION') {
                    "'$($node.GetAttribute('from'))' -> '$($node.GetAttribute('to'))'"
                }
                else {
                    $field = $node.SelectSingleNode('ancestor-or-self::*[@refname]')
                    if ($field) { "field '$($field.GetAttribute('refname'))'" } else { "under $($node.ParentNode.LocalName)" }
                }
                Write-FixStep "  removing @$attribute='$($node.GetAttribute($attribute))' from <$($node.LocalName)> $context"
                [void]$node.RemoveAttribute($attribute)
                $changeCount++
            }
        }
        if ($changeCount -eq 0) {
            if ($All) {
                Write-FixStep "  '$WorkItemType' has no scoped rules or transitions - no change."
                return
            }
            $scopes = @($xml.SelectNodes('//*[@for or @not]') | ForEach-Object { "<$($_.LocalName)> for='$($_.GetAttribute('for'))' not='$($_.GetAttribute('not'))'" } | Sort-Object -Unique)
            $detail = if ($scopes) { " Scoped rules present: $($scopes -join '; ')" } else { ' No scoped rules exist in this work item type.' }
            Write-FixStep "  no matching scope for '$Identity' in '$WorkItemType' - no change.$detail"
            return
        }
        Write-FixStep "  removed $changeCount scope attribute(s)"
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")

        # Verify the server actually took the change - witadmin has been observed
        # reporting success while the import did not stick.
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $verify = [xml](Get-Content -LiteralPath $file -Raw)
        $remaining = if ($All) {
            @($verify.SelectNodes('//*[@for or @not]'))
        }
        else {
            @(foreach ($attribute in $attributes) {
                    $verify.SelectNodes("//*[@$attribute]") | Where-Object { $_.GetAttribute($attribute) -eq $Identity }
                })
        }
        if ($remaining.Count -gt 0) {
            $what = if ($All) { 'scope attribute(s)' } else { "scope(s) for '$Identity'" }
            throw "Verification failed: $($remaining.Count) $what still present in '$WorkItemType' after import."
        }
        Write-FixStep "  verified: no $(if ($All) { 'scoping' } else { "'$Identity' scoping" }) remains in '$WorkItemType'"
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
