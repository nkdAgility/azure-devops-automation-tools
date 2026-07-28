function Remove-WitRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$WorkItemType,
        [Parameter(Mandatory)] [ValidateSet('for', 'not', 'both')] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Identity,
        [string]$WitAdminPath
    )

    Write-FixStep "Removing rule scope '$Identity' ($AttributeName) from work item type '$WorkItemType' in '$Project'"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
    try {
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$WorkItemType", "/f:$file")
        $xml = [xml](Get-Content -LiteralPath $file -Raw)
        $attributes = if ($AttributeName -eq 'both') { @('for', 'not') } else { @($AttributeName) }
        $changeCount = 0
        foreach ($attribute in $attributes) {
            $nodes = @($xml.SelectNodes("//*[@$attribute]") | Where-Object { $_.GetAttribute($attribute) -eq $Identity })
            foreach ($node in $nodes) {
                Write-FixStep "  removing @$attribute from <$($node.Name)> under $($node.ParentNode.Name)"
                [void]$node.RemoveAttribute($attribute)
                $changeCount++
            }
        }
        if ($changeCount -eq 0) {
            $scopes = @($xml.SelectNodes('//*[@for or @not]') | ForEach-Object { "<$($_.Name)> for='$($_.GetAttribute('for'))' not='$($_.GetAttribute('not'))'" } | Sort-Object -Unique)
            $detail = if ($scopes) { " Scoped rules present: $($scopes -join '; ')" } else { ' No scoped rules exist in this work item type.' }
            Write-FixStep "  no matching scope for '$Identity' in '$WorkItemType' - no change.$detail"
            return
        }
        Write-FixStep "  removed $changeCount scope attribute(s)"
        $xml.Save($file)
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
