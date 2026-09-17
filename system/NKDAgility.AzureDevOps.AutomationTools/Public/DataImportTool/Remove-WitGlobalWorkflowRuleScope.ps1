function Remove-WitGlobalWorkflowRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [string]$Project,
        [Parameter(Mandatory)] [ValidateSet('for', 'not', 'both')] [string]$AttributeName,
        [Parameter(Mandatory)] [string]$Identity,
        [string]$WitAdminPath
    )

    $scope = if ($Project) { "project '$Project'" } else { 'the collection' }
    Write-FixStep "Removing global workflow rule scope '$Identity' ($AttributeName) from $scope"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).GlobalWorkflow.xml"
    try {
        $exportArguments = @('exportglobalworkflow', "/collection:$Collection")
        if ($Project) { $exportArguments += "/p:$Project" }
        $exportArguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $exportArguments

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
            $detail = if ($scopes) { " Scoped rules present: $($scopes -join '; ')" } else { ' No scoped rules exist in this global workflow.' }
            Write-FixStep "  no matching scope for '$Identity' in $scope - no change.$detail"
            return
        }
        Write-FixStep "  removed $changeCount scope attribute(s)"
        $xml.Save($file)

        $importArguments = @('importglobalworkflow', "/collection:$Collection")
        if ($Project) { $importArguments += "/p:$Project" }
        $importArguments += "/f:$file"
        Invoke-WitAdminFix -WitAdminPath $WitAdminPath -Arguments $importArguments
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
