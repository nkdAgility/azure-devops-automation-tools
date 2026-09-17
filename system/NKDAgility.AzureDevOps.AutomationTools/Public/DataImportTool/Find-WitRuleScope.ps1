function Find-WitRuleScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string]$WitAdminPath
    )

    $executable = Resolve-WitAdminPath -WitAdminPath $WitAdminPath
    Write-FixStep "Listing work item types in '$Project'"
    $types = & $executable listwitd "/collection:$Collection" "/p:$Project"
    if ($LASTEXITCODE -ne 0) { throw "witadmin listwitd failed with exit code $LASTEXITCODE." }

    foreach ($type in ($types | Where-Object { $_ -and $_.Trim() })) {
        $name = $type.Trim()
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
        try {
            & $executable exportwitd "/collection:$Collection" "/p:$Project" "/n:$name" "/f:$file" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-FixStep "  '$name': export failed with exit code $LASTEXITCODE"
                continue
            }
            $xml = [xml](Get-Content -LiteralPath $file -Raw)
            foreach ($node in $xml.SelectNodes('//*[@for or @not]')) {
                $field = $node.SelectSingleNode('ancestor::*[@refname]')
                [pscustomobject]@{
                    Project      = $Project
                    WorkItemType = $name
                    Rule         = $node.Name
                    Field        = if ($field) { $field.GetAttribute('refname') } else { '' }
                    For          = $node.GetAttribute('for')
                    Not          = $node.GetAttribute('not')
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}
