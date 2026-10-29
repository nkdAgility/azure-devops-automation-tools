function Sync-InheritedProcess {
    <#
    .SYNOPSIS
    Adds to a target project's inherited process whatever its work items need from the
    source project's process: work item types, fields, picklist values, states and
    backlog levels.

    .DESCRIPTION
    devopsmigration.exe refuses to migrate work items whose types or fields are missing in
    the target ("Some work item types or their fields are not valid in the target system").
    This closes that gap for any source and target pair, over REST, with nothing specific
    to one customer or project.

    Both processes are resolved from the PROJECTS, so the caller names projects, not
    process ids. Then, per source work item type:

      1. Type missing in the target: created (a custom type, or one derived from the
         same system type the source derives from), with the source's colour, icon and
         description.
      2. Fields the source type has and the target type lacks: the organisation field is
         created first when the target organisation does not have it (picklists copied
         with their values), then the field is added to the type with the source's
         required flag and default.
      3. Picklist values the source has and the target picklist lacks: added. Values are
         never removed.
      4. States the source has and the target lacks: added with the source's category
         and colour, after the target's last state in that category. On a type this run
         created, the target's default states the source does not have are hidden.
      5. Backlog levels: a created type gets the source type's behaviours, matched by id
         (system behaviours share ids across organisations) or by name.

    It only ever ADDS. It never removes or renames anything, and never hides a state on a
    type it did not create, because the target process may be shared and other projects'
    work items may be in those states. Everything it cannot do is reported instead, for
    example allowed-value differences on system fields, which an inherited process cannot
    change.

    Safety:
      - -WhatIf previews every change.
      - A target process used by other projects is refused unless -AllowSharedProcess is
        given, because every change lands in all of them. The projects are listed.
      - A target project on a SYSTEM process (Agile, Scrum, CMMI, Basic) cannot be
        customised at all. That is reported with what to do, and nothing is written.

    New fields are added to the type but not placed on the form; values migrate and are
    queryable either way. Form layout is left to the process owner.

    Idempotent: re-running after a successful run makes no changes.

    .PARAMETER SourceCollection
    Source organisation URL, e.g. https://dev.azure.com/contoso.

    .PARAMETER SourceProject
    Source project name. Its process is the one copied from.

    .PARAMETER TargetCollection
    Target organisation URL.

    .PARAMETER TargetProject
    Target project name. Its process is the one written to.

    .PARAMETER WorkItemType
    Optional. Only these source work item types (by name). Default: every type the source
    process has that is not disabled.

    .PARAMETER AllowSharedProcess
    Write to the target process even when other projects use it.

    .PARAMETER SourcePat
    Token for the source. Omit to use Entra or the workspace secrets.

    .PARAMETER TargetPat
    Token for the target. Needs 'Work Items (Read, write & manage)' and process
    administration. Omit to use Entra or the workspace secrets.

    .EXAMPLE
    Sync-InheritedProcess -SourceCollection https://dev.azure.com/contoso -SourceProject Mammoth `
        -TargetCollection https://dev.azure.com/fabrikam -TargetProject Mammoth -WhatIf

    .OUTPUTS
    One object per change made, planned or reported: Action, WorkItemType, Item, Detail.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string]$SourceCollection,
        [Parameter(Mandatory)] [string]$SourceProject,
        [Parameter(Mandatory)] [string]$TargetCollection,
        [Parameter(Mandatory)] [string]$TargetProject,
        [string[]]$WorkItemType,
        [switch]$AllowSharedProcess,
        [string]$SourcePat,
        [string]$TargetPat
    )

    $apiVersion = '7.1'
    $source = { param($path) Invoke-AzureDevOpsApi -Collection $SourceCollection -Path $path -ApiVersion $apiVersion -Pat $SourcePat }
    $target = { param($path, $method = 'Get', $body = $null)
        $arguments = @{ Collection = $TargetCollection; Path = $path; Method = $method; ApiVersion = $apiVersion; Pat = $TargetPat }
        if ($null -ne $body) { $arguments.Body = $body }
        Invoke-AzureDevOpsApi @arguments
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $record = { param($action, $type, $item, $detail)
        $results.Add([pscustomobject][ordered]@{ Action = $action; WorkItemType = $type; Item = $item; Detail = $detail })
    }

    # --- Resolve both processes from their projects -----------------------------------
    $findProcess = { param($fetch, $project, $collection)
        $response = & $fetch '_apis/work/processes?$expand=projects'
        if ($response -is [string]) { throw "Received HTML instead of JSON from '$collection'. The credential is likely wrong or expired." }
        $process = @($response.value) | Where-Object { @($_.projects.name) -contains $project } | Select-Object -First 1
        if (-not $process) { throw "Project '$project' was not found in any process in '$collection'." }
        $process
    }
    $sourceProcess = & $findProcess $source $SourceProject $SourceCollection
    $targetProcess = & $findProcess $target $TargetProject $TargetCollection
    Write-FixStep ("Source: '{0}' / process '{1}'" -f $SourceProject, $sourceProcess.name)
    Write-FixStep ("Target: '{0}' / process '{1}'" -f $TargetProject, $targetProcess.name)

    if ($targetProcess.customizationType -eq 'system') {
        throw ("Target project '{0}' uses the system process '{1}', which cannot be customised. Create an inherited process from '{2}' in '{3}', change the project to it (Organization settings > Process > Projects > Change process), then re-run." -f `
                $TargetProject, $targetProcess.name, ($(if ($sourceProcess.customizationType -eq 'system') { $sourceProcess.name } else { 'the same system process the source inherits from' })), $TargetCollection)
    }
    $others = @($targetProcess.projects.name | Where-Object { $_ -ne $TargetProject })
    if ($others.Count) {
        $message = "Target process '{0}' is also used by: {1}. Every change lands in all of them." -f $targetProcess.name, ($others -join ', ')
        if (-not $AllowSharedProcess) { throw "$message Pass -AllowSharedProcess to write to it anyway, or move '$TargetProject' to its own inherited process." }
        Write-Warning $message
    }

    $sourceRoot = "_apis/work/processes/$($sourceProcess.typeId)"
    $targetRoot = "_apis/work/processes/$($targetProcess.typeId)"
    $sourceTypes = @((& $source "$sourceRoot/workitemtypes?`$expand=states,behaviors").value) | Where-Object { -not $_.isDisabled }
    if ($WorkItemType) { $sourceTypes = @($sourceTypes | Where-Object { $_.name -in $WorkItemType }) }
    $targetTypes = @((& $target "$targetRoot/workitemtypes?`$expand=states,behaviors").value)
    $targetBehaviors = @((& $target "$targetRoot/behaviors").value)
    $sourceBehaviors = @((& $source "$sourceRoot/behaviors").value)

    # Organisation-level field definitions, cached per collection.
    $orgFieldCache = @{}
    $getOrgField = { param($fetch, $key, $ref)
        $cacheKey = "$key|$ref"
        if (-not $orgFieldCache.ContainsKey($cacheKey)) {
            $value = $null
            try { $value = & $fetch "_apis/wit/fields/$([uri]::EscapeDataString($ref))" } catch { $value = $null }
            if ($value -is [string]) { $value = $null }
            $orgFieldCache[$cacheKey] = $value
        }
        $orgFieldCache[$cacheKey]
    }

    # Picklists are matched by the field they back, so a target picklist is created or
    # extended from the source picklist's values.
    $syncPicklist = { param($sourceField, $targetField, $typeName)
        if (-not $sourceField.isPicklist -or -not $sourceField.picklistId) { return $null }
        $sourceList = & $source "_apis/work/processes/lists/$($sourceField.picklistId)"
        if ($targetField -and $targetField.isPicklist -and $targetField.picklistId) {
            $targetList = & $target "_apis/work/processes/lists/$($targetField.picklistId)"
            $missing = @($sourceList.items | Where-Object { $_ -notin @($targetList.items) })
            if ($missing.Count) {
                if ($PSCmdlet.ShouldProcess("$($targetField.referenceName) picklist", "Add value(s): $($missing -join ', ')")) {
                    $null = & $target "_apis/work/processes/lists/$($targetList.id)" 'Put' @{
                        id = $targetList.id; name = $targetList.name; type = $targetList.type
                        isSuggested = $targetList.isSuggested; items = @($targetList.items) + $missing
                    }
                }
                & $record 'AddPicklistValues' $typeName $targetField.referenceName ($missing -join ', ')
            }
            return $targetList.id
        }
        if ($PSCmdlet.ShouldProcess("picklist for $($sourceField.referenceName)", 'Create')) {
            $created = & $target '_apis/work/processes/lists' 'Post' @{
                name = $sourceList.name; type = $sourceList.type; isSuggested = $sourceList.isSuggested; items = @($sourceList.items)
            }
            return $created.id
        }
        return 'whatif'
    }

    foreach ($sourceType in $sourceTypes) {
        $typeName = $sourceType.name
        Write-FixStep ("Work item type '{0}'" -f $typeName)
        $targetType = $targetTypes | Where-Object name -eq $typeName | Select-Object -First 1
        $createdType = $false

        # 1. The type itself.
        if (-not $targetType) {
            # Derived from a system type: derive from the same system type in the target.
            # System type reference names (Microsoft.VSTS.WorkItemTypes.*) are the same in
            # every organisation.
            $inherits = $sourceType.inherits
            # Only when the target's parent process has that system type: an Agile User
            # Story cannot derive inside a Scrum-based process (VS402805). Otherwise it is a
            # plain custom type, and steps 2-4 give it the source type's fields and states.
            if ($inherits -and -not @($targetTypes | Where-Object {
                        $_.referenceName -eq $inherits -or ($_.PSObject.Properties['inherits'] -and $_.inherits -eq $inherits)
                    }).Count) {
                $inherits = $null
            }
            $body = @{ name = $typeName; color = $sourceType.color; icon = $sourceType.icon; description = $sourceType.description; isDisabled = $false }
            if ($inherits) { $body.inheritsFrom = $inherits }
            & $record 'CreateType' $typeName $typeName $(if ($inherits) { "derived from $inherits" } else { 'custom type' })
            if (-not $PSCmdlet.ShouldProcess($typeName, 'Create work item type')) {
                Write-Host "    would create type '$typeName' (its fields, states and backlog are then added on a real run)" -ForegroundColor DarkGray
                continue
            }
            $targetType = & $target "$targetRoot/workitemtypes" 'Post' $body
            $targetType = & $target "$targetRoot/workitemtypes/$($targetType.referenceName)?`$expand=states,behaviors"
            $createdType = $true
            Write-Host "    + type created ($($targetType.referenceName))" -ForegroundColor Green
        }

        $sourceTypePath = "$sourceRoot/workItemTypes/$($sourceType.referenceName)"
        $targetTypePath = "$targetRoot/workItemTypes/$($targetType.referenceName)"

        # 2 and 3. Fields and picklist values.
        $sourceFields = @((& $source "$sourceTypePath/fields").value)
        $targetFields = @((& $target "$targetTypePath/fields").value)
        foreach ($field in $sourceFields) {
            $ref = $field.referenceName
            $sourceOrg = & $getOrgField $source 'source' $ref
            $targetOrg = & $getOrgField $target 'target' $ref
            $onType = $targetFields | Where-Object referenceName -eq $ref | Select-Object -First 1

            if ($onType) {
                # Present: only picklist values can be missing, and only custom picklists
                # can be changed.
                if ($sourceOrg -and $targetOrg -and $ref -notlike 'System.*' -and $ref -notlike 'Microsoft.VSTS.*') {
                    $null = & $syncPicklist $sourceOrg $targetOrg $typeName
                }
                elseif ($sourceOrg -and $targetOrg -and $sourceOrg.isPicklist) {
                    & $record 'Report' $typeName $ref 'system field picklist: allowed values cannot be changed in an inherited process'
                }
                continue
            }

            if (-not $targetOrg) {
                if (-not $sourceOrg) { & $record 'Report' $typeName $ref 'source field definition could not be read; not added'; continue }
                $type = switch ($sourceOrg.type) { 'picklistString' { 'string' } 'picklistInteger' { 'integer' } 'picklistDouble' { 'double' } default { $sourceOrg.type } }
                $picklistId = & $syncPicklist $sourceOrg $null $typeName
                $body = @{ name = $sourceOrg.name; referenceName = $ref; type = $type; usage = 'workItem'; description = $sourceOrg.description }
                if ($picklistId -and $picklistId -ne 'whatif') { $body.isPicklist = $true; $body.picklistId = $picklistId; $body.isPicklistSuggested = [bool]$sourceOrg.isPicklistSuggested }
                & $record 'CreateField' $typeName $ref ("{0} ({1}{2})" -f $sourceOrg.name, $type, $(if ($sourceOrg.isPicklist) { ', picklist' } else { '' }))
                if ($PSCmdlet.ShouldProcess($ref, 'Create organisation field')) {
                    $targetOrg = & $target '_apis/wit/fields' 'Post' $body
                    $orgFieldCache["target|$ref"] = $targetOrg
                    Write-Host "    + field '$ref' created" -ForegroundColor Green
                }
            }
            elseif ($sourceOrg -and $sourceOrg.isPicklist) {
                $null = & $syncPicklist $sourceOrg $targetOrg $typeName
            }

            & $record 'AddFieldToType' $typeName $ref $(if ($field.required) { 'required' } else { '' })
            if ($PSCmdlet.ShouldProcess("$typeName / $ref", 'Add field to type')) {
                $body = @{ referenceName = $ref; required = [bool]$field.required }
                if ($null -ne $field.defaultValue -and "$($field.defaultValue)" -ne '') { $body.defaultValue = $field.defaultValue }
                $null = & $target "$targetTypePath/fields" 'Post' $body
                Write-Host "    + field '$ref' added" -ForegroundColor Green
            }
        }

        # 4. States.
        $sourceStates = @($sourceType.states)
        if (-not $sourceStates.Count) { $sourceStates = @((& $source "$sourceTypePath/states").value) }
        foreach ($state in @($sourceStates | Where-Object { -not $_.hidden } | Sort-Object order)) {
            $targetStates = @((& $target "$targetTypePath/states").value)
            $existing = $targetStates | Where-Object name -eq $state.name | Select-Object -First 1
            if ($existing) {
                if ($existing.hidden) { & $record 'Report' $typeName "state '$($state.name)'" 'hidden in the target; un-hide it if work items use it' }
                continue
            }
            # After the target's last state whose category comes at or before this one's
            # (Proposed, InProgress, Resolved, Completed, Removed). Orders copied from the
            # source, or a category the target has no state in yet, are refused (VS403085).
            $categoryRank = @{ Proposed = 0; InProgress = 1; Resolved = 2; Completed = 3; Removed = 4 }
            $rank = $categoryRank[[string]$state.stateCategory]
            $before = @($targetStates | Where-Object { $categoryRank[[string]$_.stateCategory] -le $rank })
            $order = if ($before.Count) { 1 + ($before | Measure-Object order -Maximum).Maximum } else { 1 }
            & $record 'AddState' $typeName $state.name "$($state.stateCategory), order $order"
            if ($PSCmdlet.ShouldProcess("$typeName / state '$($state.name)'", 'Add state')) {
                $null = & $target "$targetTypePath/states" 'Post' @{ name = $state.name; color = $state.color; stateCategory = $state.stateCategory; order = $order }
                Write-Host "    + state '$($state.name)' ($($state.stateCategory))" -ForegroundColor Green
            }
        }
        if ($createdType) {
            # A new type comes with default states; hide the ones the source does not have.
            foreach ($extra in @(@((& $target "$targetTypePath/states").value) | Where-Object { $_.name -notin @($sourceStates.name) -and -not $_.hidden -and $_.customizationType -ne 'custom' })) {
                & $record 'HideState' $typeName $extra.name 'default state of a newly created type, not in the source'
                if ($PSCmdlet.ShouldProcess("$typeName / state '$($extra.name)'", 'Hide state')) {
                    $null = & $target "$targetTypePath/states/$($extra.id)" 'Put' @{ hidden = $true }
                }
            }
        }

        # 5. Backlog levels: for a type created in the target (this run or an earlier,
        # interrupted one), add any level the source type has and the target type lacks.
        if ($createdType -or $targetType.customization -eq 'custom') {
            $behaviorPath = "$targetRoot/workitemtypesbehaviors/$($targetType.referenceName)/behaviors"
            $haveBehaviors = @((& $target $behaviorPath).value | ForEach-Object { $_.behavior.id })
            foreach ($behavior in @($sourceType.behaviors)) {
                $sourceBehavior = $sourceBehaviors | Where-Object { $_.referenceName -eq $behavior.behavior.id } | Select-Object -First 1
                $match = $targetBehaviors | Where-Object { $_.referenceName -eq $behavior.behavior.id -or ($sourceBehavior -and $_.name -eq $sourceBehavior.name) } | Select-Object -First 1
                if (-not $match) { & $record 'Report' $typeName "backlog '$($behavior.behavior.id)'" 'no matching backlog level in the target'; continue }
                if ($haveBehaviors -contains $match.referenceName) { continue }
                # Never the default: the target backlog level already has its own default
                # type (a Scrum PBI), and taking it over would change what its board creates.
                & $record 'AddBehavior' $typeName $match.name ''
                if ($PSCmdlet.ShouldProcess("$typeName / backlog '$($match.name)'", 'Add to backlog level')) {
                    # Backlog levels live under workitemtypesbehaviors, not workItemTypes (404).
                    $null = & $target $behaviorPath 'Post' @{ behavior = @{ id = $match.referenceName }; isDefault = $false }
                }
            }
        }
    }

    $changes = @($results | Where-Object Action -ne 'Report')
    Write-FixStep ("{0} change(s) {1}, {2} item(s) reported." -f $changes.Count, $(if ($WhatIfPreference) { 'previewed' } else { 'applied' }), @($results | Where-Object Action -eq 'Report').Count)
    foreach ($report in @($results | Where-Object Action -eq 'Report')) {
        Write-Warning ("{0} / {1}: {2}" -f $report.WorkItemType, $report.Item, $report.Detail)
    }
    $results
}
