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

    It 'supports -WhatIf' {
        $cmdletBinding = $script:EngineAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.FullName -match 'CmdletBinding' }
        ($cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'asks once per work item, not twice' {
        # ConfirmImpact High makes ShouldProcess raise its OWN confirmation on top of the
        # ShouldContinue prompt, so every work item was asked about twice - and answering
        # the first looked like it had done nothing, because the second was still waiting.
        $cmdletBinding = $script:EngineAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.FullName -match 'CmdletBinding' }
        ($cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' }) |
            Should -BeNullOrEmpty -Because 'ShouldContinue is the one prompt, and it carries the detail'
    }

    It 'accepts several repositories in one pass' {
        # A work item mentioned by commits in two migrated repositories would otherwise be
        # edited once per run - two revisions in its history for one correction - and the
        # expensive revision-history scan would be repeated per run.
        $p = $script:EngineAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RepoName' }
        $p.StaticType.Name | Should -BeExactly 'String[]'
    }

    It 'records which repository each link came from' {
        $script:Text | Should -Match 'Repo       = \$matched'
        $script:Text | Should -Match 'Select-Object WorkItemId, Repo, Rev'
        # The empty-file header has to match the columns, or a zero-row evidence file
        # disagrees with a populated one.
        $script:Text | Should -Match '"WorkItemId","Repo","Rev"'
    }

    It 'resolves every named repository up front' {
        # A typo should fail immediately, not after several minutes of scanning.
        $fn = Get-EngineFunctionText -Name 'Get-TargetRepositoryId'
        $fn | Should -Match 'foreach \(\$one in \$Name\)'
        $fn | Should -Match 'was not found in project'
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

    It 'filters links to the named repositories' {
        # A link is kept only when it points at one of the repositories asked for, and
        # skipped outright otherwise.
        $script:Discovery | Should -Match 'foreach \(\$candidate in \$rids\.Keys\)'
        $script:Discovery | Should -Match 'if \(-not \$matched\) \{ continue \}'
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

    It 'survives a work item that has no relations at all' {
        # Under Set-StrictMode, reading a missing property throws. A work item with no
        # relations comes back WITHOUT the property, so the no-op case failed as
        # 'The property relations cannot be found on this object' - both when reading
        # before the patch and when verifying after removing the last one.
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        ([regex]::Matches($fn, "PSObject\.Properties\.Name -contains 'relations'")).Count |
            Should -Be 2 -Because 'both the read and the verification re-read need the guard'
        # Both collections start empty and are only filled inside the guard, so neither
        # read touches the property without checking it exists first.
        $fn | Should -Match '\$relations = @\(\)'
        $fn | Should -Match '\$afterRelations = @\(\)'
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

Describe 'Per-work-item confirmation' {

    It 'confirms each work item individually unless -Force' {
        $script:Text | Should -Match '\$PSCmdlet\.ShouldContinue\('
        $script:Text | Should -Match '\$yesToAll = \[bool\]\$Force'
    }

    It 'offers yes-to-all and no-to-all' {
        # So the first few can be checked, then the rest run continuously.
        $script:Text | Should -Match '\[ref\]\$yesToAll, \[ref\]\$noToAll'
    }

    It 'stops entirely on no-to-all rather than continuing' {
        $script:Text | Should -Match 'Stopped at your request'
    }

    It 'shows what each edit does before asking' {
        # A prompt showing only an id is not a decision anyone can make.
        $script:Text | Should -Match 'removing \$\(\$urls\.Count\) commit link\(s\) in ONE edit'
        $script:Text | Should -Match '\$_\.Commit\.Substring'
    }

    It 'names the links in the ShouldProcess target too, not just a count' {
        # 'work item 84191 (3 link(s))' cannot be checked against anything; the commit
        # ids, their repository and when they were added can.
        $script:Text | Should -Match '\$what = \$describe'
        foreach ($field in '\$i\.Project', '\$i\.Type', '\$i\.State', '\$i\.Title') {
            $script:Text | Should -Match $field -Because 'the target names what the work item is, not just its id'
        }
        # And the commit detail is appended to it, not only to the ShouldContinue prompt.
        $script:Text | Should -Match '\$what = \$describe \+ \[Environment\]::NewLine'
        $script:Text | Should -Not -Match '\$what = "work item \$workItemId \(\$\(\$urls\.Count\) link\(s\)\)"'
    }

    It 'makes exactly one edit per work item, whatever its link count' {
        # All of a work item's removals go in a single JSON Patch, so its history gains
        # one revision rather than one per link.
        $fn = Get-EngineFunctionText -Name 'Remove-WorkItemLink'
        # One PATCH in the whole function - the call is written across a line
        # continuation, so match the verb alone rather than the whole invocation.
        ([regex]::Matches($fn, '-Method Patch')).Count | Should -Be 1
        # ...carrying ALL of the removals, built from every index found.
        $fn | Should -Match 'ConvertTo-Json @\(\$patch\)'
        $fn | Should -Match '\$patch = @\(\$indexes \| Sort-Object -Descending'
    }

    It 'has -Force for unattended runs' {
        $p = $script:EngineAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Force' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -BeExactly 'SwitchParameter'
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
