#Requires -Modules Pester

# Covers Remove-CommitMentionLinks.ps1. This script writes to work items across an entire
# organisation, most of them owned by teams with no connection to the migration, so the
# properties under test are the ones that keep it narrow, previewable and reversible.

BeforeAll {
    $script:EnginePath = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.AutomationTools\Engines\Remove-CommitMentionLinks.ps1'
    $script:EngineAst = [System.Management.Automation.Language.Parser]::ParseFile($script:EnginePath, [ref]$null, [ref]$null)
    $script:Text = Get-Content $script:EnginePath -Raw

    function script:Get-EngineFunctionText {
        param([string]$Name)
        $found = $script:EngineAst.FindAll({
                param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $found) { throw "Function '$Name' not found in the engine." }
        return $found.Extent.Text
    }
}

Describe 'Remove-CommitMentionLinks shape' {

    It 'supports -WhatIf and defaults to high-impact confirmation' {
        $cmdletBinding = $script:EngineAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.FullName -match 'CmdletBinding' }
        ($cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) |
            Should -Not -BeNullOrEmpty
        ($cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' }).Argument.Extent.Text |
            Should -Match 'High'
    }

    It 'requires the repository to be named' {
        # Without a repository filter this would strip every commit link in the window,
        # including other people's legitimate ones.
        $p = $script:EngineAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RepoName' }
        $mandatory = $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.Language.AttributeAst] -and
            ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' -and $_.Argument.Extent.Text -eq '$true' })
        }
        $mandatory | Should -Not -BeNullOrEmpty
    }

    It 'defaults the window to 30 days rather than everything' {
        $p = $script:EngineAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SinceDays' }
        $p.DefaultValue.Extent.Text | Should -BeExactly '30'
    }
}

Describe 'Narrowness - what it will and will not touch' {

    BeforeAll { $script:Discovery = $script:Text }

    It 'only considers relations ADDED by a qualifying revision' {
        # A commit link that was already on the work item is somebody's real history.
        $script:Discovery | Should -Match '\$rev\.relations\.added'
    }

    It 'only removes ArtifactLink relations' {
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        $fn | Should -Match "rel -eq 'ArtifactLink'"
    }

    It 'filters links to the named repository' {
        $script:Discovery | Should -Match '\$rel\.url -notlike "\*\$rid\*"'
    }

    It 'honours the identity filter when one is given' {
        $script:Discovery | Should -Match '\$who -and \$by -ne \$who'
    }

    It 'ignores revisions older than the window' {
        $script:Discovery | Should -Match '\$when -lt \$since'
    }
}

Describe 'Removal correctness' {

    It 'resolves indexes against CURRENT relations, not what discovery saw' {
        # Relations may have changed since discovery; stale indexes delete the wrong ones.
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        $fn | Should -Match 'Invoke-Ado -Uri .*\$expand=relations'
    }

    It 'removes in DESCENDING index order' {
        # Each JSON Patch 'remove' renumbers every relation after it, so ascending order
        # silently removes the wrong relations. This is the single most dangerous detail.
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        $fn | Should -Match '\$indexes \| Sort-Object -Descending'
    }

    It 'proves that descending order is the correct strategy' {
        # Demonstrated rather than asserted: removing ascending drops the wrong entries.
        $relations = 0..5 | ForEach-Object { "rel$_" }
        $targets = @(1, 3, 4)

        $ascending = [System.Collections.ArrayList]::new($relations)
        foreach ($i in ($targets | Sort-Object)) { if ($i -lt $ascending.Count) { $ascending.RemoveAt($i) } }

        $descending = [System.Collections.ArrayList]::new($relations)
        foreach ($i in ($targets | Sort-Object -Descending)) { $descending.RemoveAt($i) }

        @($descending) | Should -Be @('rel0', 'rel2', 'rel5')      # exactly the survivors
        @($ascending) | Should -Not -Be @('rel0', 'rel2', 'rel5')  # ascending gets it wrong
    }

    It 'verifies the removal by re-reading, and throws when links survive' {
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        $fn | Should -Match 'still has .* of the targeted link'
        $fn | Should -Match 'throw'
    }

    It 'treats an already-removed link as a no-op, so re-runs are safe' {
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        $fn | Should -Match 'already gone - a re-run, not a failure'
    }
}

Describe 'Preview and evidence' {

    It 'still writes the evidence CSV under -WhatIf' {
        # Export-Csv and Set-Content honour ShouldProcess, so without an explicit
        # -WhatIf:$false a dry run prints 'Evidence written' and writes NOTHING. Reviewing
        # 11,000 links means reading the file; a preview that produces no file is useless.
        # AST, not text: a regex over the source also matches these command names where
        # they appear in comments explaining the very problem.
        $writes = $script:EngineAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Export-Csv', 'Set-Content')
            }, $true)
        $writes.Count | Should -BeGreaterThan 0
        foreach ($w in $writes) {
            $w.Extent.Text | Should -Match '-WhatIf:\$false' -Because "every local write must survive -WhatIf: $($w.Extent.Text)"
        }
    }

    It 'writes the evidence CSV before any removal happens' {
        $evidenceAt = $script:Text.IndexOf('Export-Csv -LiteralPath $EvidencePath')
        $removeAt = $script:Text.IndexOf('Remove-WorkItemLink -WorkItemId')
        $evidenceAt | Should -BeGreaterThan 0
        $evidenceAt | Should -BeLessThan $removeAt
    }

    It 'returns from -WhatIf before reaching the removal loop' {
        $whatIfAt = $script:Text.IndexOf('if ($WhatIfPreference)')
        $removeAt = $script:Text.IndexOf('Remove-WorkItemLink -WorkItemId')
        $whatIfAt | Should -BeGreaterThan 0
        $whatIfAt | Should -BeLessThan $removeAt
    }

    It 'previews a summary report rather than one line per work item' {
        # Thousands of near-identical ShouldProcess lines cannot be reviewed, which
        # defeats the point of a preview on a change this wide.
        $fn = Get-EngineFunctionText -Name 'Write-WhatIfReport'
        $fn | Should -Match 'WHAT WOULD BE REMOVED'
        $fn | Should -Match 'Affected projects'
        $fn | Should -Match 'Sample of what would be removed'
        $fn | Should -Match 'Nothing has been changed'
    }

    It 'names the affected projects, not just work item ids' {
        $fn = Get-EngineFunctionText -Name 'Write-WhatIfReport'
        $fn | Should -Match '\$Summary'
        Get-EngineFunctionText -Name 'Get-WorkItemSummary' | Should -Match 'System.TeamProject'
    }

    It 'warns loudly about state changes it will NOT fix' {
        # Removing a link does not revert a transition; a wrongly closed work item that
        # nobody notices is worse than a stray link.
        $fn = Get-EngineFunctionText -Name 'Write-WhatIfReport'
        $fn | Should -Match 'STATE CHANGES CAUSED BY MENTION RESOLUTION - NOT FIXED BY THIS SCRIPT'
        $script:Text | Should -Match 'does not revert those'
    }

    It 'separates mention-caused transitions from the operator''s own corrections' {
        # The first run of this reported the operator's OWN restores (Resolved -> New,
        # Closed -> Active) and a newly created work item back to them as damage. A
        # remediation list containing the remediation is one nobody can act on.
        $fn = Get-EngineFunctionText -Name 'Write-WhatIfReport'
        $fn | Should -Match '\$StateChanges \| Where-Object \{ \$_\.ByMention \}'
        $fn | Should -Match 'not caused by mentions'
        $script:Text | Should -Match "match 'mentioned work items'"
    }

    It 'looks up projects for state-changed items even when they carry no links' {
        # Otherwise they render as '?' in the section the operator must act on.
        $script:Text | Should -Match '\$stateChanges \| ForEach-Object \{ \[int\]\$_\.WorkItemId \}'
    }

    It 'flags a transition that has already been restored' {
        $fn = Get-EngineFunctionText -Name 'Write-WhatIfReport'
        $fn | Should -Match 'already restored'
    }
}

Describe 'Resilience' {

    It 'retries throttling rather than failing the run' {
        $fn = Get-EngineFunctionText -Name 'Invoke-Ado'
        $fn | Should -Match '429'
        $fn | Should -Match 'Retry-After'
    }

    It 'checkpoints so an interrupted run resumes' {
        $script:Text | Should -Match 'Add-Content -LiteralPath \$CheckpointPath'
        $script:Text | Should -Match '\$done\.ContainsKey\(\$workItemId\)'
    }

    It 'does not let one failed work item stop the rest' {
        $script:Text | Should -Match 'must not stop thousands of others'
    }
}
