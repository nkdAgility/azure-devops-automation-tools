function Add-WitReflectedWorkItemIdField {
    <#
    .SYNOPSIS
    Adds the reflected work item ID field to work item types in an XML-process project.

    .DESCRIPTION
    The Azure DevOps Migration Tools cannot migrate work items without a field on the
    TARGET to record which source item each target item came from. Its pre-validation
    (TfsWorkItemTypeValidatorTool) fails hard with:

        Reflected work item ID field is mandatory for work item migration.

    The field is required on every work item type the migration will validate, and it
    cannot be worked around with a field map - the tool writes to it directly. On an
    inherited process you add it in the process UI; on an XML process - every Azure
    DevOps Server / TFS collection - the only route is witadmin, which is what this does:

      1. Lists the work item types (or takes the ones you name).
      2. Exports each definition and backs it up.
      3. Skips any type that already has the field - safe to re-run.
      4. Inserts a <FIELD> into the type's top-level <FIELDS> block.
      5. Imports the definition back.
      6. RE-EXPORTS and confirms the field is really there. witadmin has been observed
         reporting success on an import that did not stick.

    Both migration endpoints need this. TfsTeamProjectEndpoint (object model) and
    AzureDevOpsEndpoint (REST) each carry their own ReflectedWorkItemIdField setting,
    and both resolve to a field that must exist on the target work item types.

    The field is NOT added to the work item form. It does not need to be visible for the
    migration to use it, and every layout variant (FORM/Layout, WebLayout) would have to
    be handled to do it safely. Add a control by hand if the customer wants it on screen.

    THIS WRITES TO A LIVE COLLECTION. Run with -WhatIf first.

    .PARAMETER Collection
    Collection URL, e.g. https://dev-liechti.int.machining.com/LIECHTI. Defaults from
    Set-MigrationContext.

    .PARAMETER Project
    Team project name. Defaults from Set-MigrationContext.

    .PARAMETER WorkItemType
    Work item types to change. Omit to take every type in the project, minus
    -ExcludeWorkItemType.

    .PARAMETER ExcludeWorkItemType
    Types to leave alone. Defaults to the six the Migration Tools validator excludes by
    default, so the default run covers exactly what the migration will validate. Pass an
    empty array to include them.

    Note the validator does NOT exclude Test Case, Test Plan or Test Suite. If your WIQL
    filters those out, either add the field to them anyway (the default here does) or
    exclude them in the validator too - otherwise validation still fails on them.

    .PARAMETER ReferenceName
    Field reference name. Must match ReflectedWorkItemIdField in the migration config.
    Default 'Custom.ReflectedWorkItemId'.

    .PARAMETER FieldName
    Friendly field name. Default 'ReflectedWorkItemId'.

    .PARAMETER BackupFolder
    Where to write the pre-change definitions. Defaults to a timestamped folder under the
    workspace output folder, or the temp folder when no workspace is initialised. These
    are your undo: re-import one to revert that type.

    .PARAMETER WitAdminPath
    Path to witadmin.exe. Defaults from Set-MigrationContext or discovery.

    .EXAMPLE
    Add-WitReflectedWorkItemIdField -Collection 'https://dev-liechti.int.machining.com/LIECHTI' -Project 'TFS_TsPlus' -WhatIf
    # What would change, and which types already have it.

    .EXAMPLE
    Add-WitReflectedWorkItemIdField -Collection 'https://dev-liechti.int.machining.com/LIECHTI' -Project 'TFS_TsPlus'

    .EXAMPLE
    Add-WitReflectedWorkItemIdField -Project 'TFS_TsPlus' -WorkItemType 'Bug', 'Task' -Verbose
    # Just two types, after Set-MigrationContext supplied the collection.

    .OUTPUTS
    One object per work item type: WorkItemType, Status (Added / AlreadyPresent /
    WouldAdd / Failed), Backup, Message. Export it as engagement evidence.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string[]]$WorkItemType,
        [string[]]$ExcludeWorkItemType = @(
            'Code Review Request'
            'Code Review Response'
            'Feedback Request'
            'Feedback Response'
            'Shared Parameter'
            'Shared Steps'
        ),
        [string]$ReferenceName = 'Custom.ReflectedWorkItemId',
        [string]$FieldName = 'ReflectedWorkItemId',
        [string]$BackupFolder,
        [string]$WitAdminPath
    )

    # A refname must be <namespace>.<name> and the namespace must not be a reserved one:
    # witadmin rejects the import otherwise, after the export work has already been done.
    if ($ReferenceName -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw "ReferenceName '$ReferenceName' is not a valid field reference name. Expected something like 'Custom.ReflectedWorkItemId'."
    }
    if ($ReferenceName -match '^(System|Microsoft)\.') {
        throw "ReferenceName '$ReferenceName' uses a reserved namespace. Use a custom namespace such as 'Custom.'."
    }

    # Resolve the tool before announcing anything. Otherwise a machine without witadmin
    # prints a section header and a backup path it will never write to, and the real
    # error arrives underneath looking like a failure part-way through the work.
    $resolvedWitAdmin = Resolve-WitAdminPath -WitAdminPath $WitAdminPath

    if (-not $BackupFolder) {
        $root = try { (Get-AutomationWorkspace).OutputFolder } catch { [System.IO.Path]::GetTempPath() }
        if (-not $root) { $root = [System.IO.Path]::GetTempPath() }
        $BackupFolder = Join-Path $root ("witd-backup\{0}-{1}" -f $Project, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }

    Write-FixSection "Adding '$ReferenceName' to work item types in '$Project'"
    Write-FixStep "Collection: $Collection"
    Write-FixStep "Backups:    $BackupFolder"

    $types = if ($WorkItemType) {
        @($WorkItemType)
    }
    else {
        @(Get-WitWorkItemType -Collection $Collection -Project $Project -WitAdminPath $resolvedWitAdmin)
    }
    $skipped = @($types | Where-Object { $ExcludeWorkItemType -contains $_ })
    $types = @($types | Where-Object { $ExcludeWorkItemType -notcontains $_ })
    if ($skipped) { Write-FixStep "Excluded: $($skipped -join ', ')" }
    if (-not $types) {
        Write-FixStep 'No work item types to process.'
        return
    }
    Write-FixStep "Processing $($types.Count) work item type(s): $($types -join ', ')"

    if (-not (Test-Path -LiteralPath $BackupFolder)) {
        New-Item -Path $BackupFolder -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $types) {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).Witd.xml"
        # Sanitised: a work item type name may contain characters a file name may not.
        $safe = ($type -replace '[\\/:*?"<>|]', '_')
        $backup = Join-Path $BackupFolder "$safe.xml"
        $status = 'Failed'
        $message = ''
        try {
            Invoke-WitAdminFix -WitAdminPath $resolvedWitAdmin -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$type", "/f:$file")
            Copy-Item -LiteralPath $file -Destination $backup -Force -WhatIf:$false

            $xml = [xml](Get-Content -LiteralPath $file -Raw)

            # The DEFINITION fields, not the <FIELDS> blocks nested inside <WORKFLOW>
            # states and transitions - those hold rule references, and adding a field
            # there means something else entirely.
            $fields = $xml.DocumentElement.SelectSingleNode('WORKITEMTYPE/FIELDS')
            if (-not $fields) {
                throw "No <WORKITEMTYPE><FIELDS> block found in the definition for '$type'."
            }

            $existing = $fields.SelectSingleNode("FIELD[@refname='$ReferenceName']")
            if ($existing) {
                $status = 'AlreadyPresent'
                $message = "type=$($existing.GetAttribute('type'))"
                Write-FixStep "  '$type': already has '$ReferenceName' - no change"
                $results.Add([pscustomobject]@{ WorkItemType = $type; Status = $status; Backup = $backup; Message = $message })
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$Project/$type", "Add field '$ReferenceName'")) {
                $status = 'WouldAdd'
                Write-FixStep "  '$type': would add '$ReferenceName'"
                $results.Add([pscustomobject]@{ WorkItemType = $type; Status = $status; Backup = $backup; Message = '' })
                continue
            }

            $field = $xml.CreateElement('FIELD')
            $field.SetAttribute('name', $FieldName)
            $field.SetAttribute('refname', $ReferenceName)
            $field.SetAttribute('type', 'String')
            # 'dimension' makes the field usable as a warehouse dimension. Harmless where
            # reporting is off, and it is what the migration tools' own docs specify.
            $field.SetAttribute('reportable', 'dimension')
            $help = $xml.CreateElement('HELPTEXT')
            $help.InnerText = 'Reference to the source work item this item was migrated from. Written by the Azure DevOps Migration Tools; do not edit by hand.'
            [void]$field.AppendChild($help)
            [void]$fields.AppendChild($field)
            $xml.Save($file)

            Invoke-WitAdminFix -WitAdminPath $resolvedWitAdmin -Arguments @('importwitd', "/collection:$Collection", "/p:$Project", "/f:$file")

            # Verify against the server, not against what we just wrote to disk.
            Invoke-WitAdminFix -WitAdminPath $resolvedWitAdmin -Arguments @('exportwitd', "/collection:$Collection", "/p:$Project", "/n:$type", "/f:$file")
            $after = [xml](Get-Content -LiteralPath $file -Raw)
            if (-not $after.DocumentElement.SelectSingleNode("WORKITEMTYPE/FIELDS/FIELD[@refname='$ReferenceName']")) {
                throw "Verification failed: '$ReferenceName' is not present in '$type' after import."
            }

            $status = 'Added'
            Write-FixStep "  '$type': added and verified"
        }
        catch {
            $message = $_.Exception.Message
            Write-FixStep "  '$type': FAILED - $message"
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if ($status -notin @('AlreadyPresent', 'WouldAdd')) {
                $results.Add([pscustomobject]@{ WorkItemType = $type; Status = $status; Backup = $backup; Message = $message })
            }
        }
    }

    $added = @($results | Where-Object { $_.Status -eq 'Added' }).Count
    $present = @($results | Where-Object { $_.Status -eq 'AlreadyPresent' }).Count
    $would = @($results | Where-Object { $_.Status -eq 'WouldAdd' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    Write-FixStep "Added $added, already present $present, would add $would, failed $($failed.Count)."
    if ($failed) {
        # Surfaced but not thrown: one bad type must not hide the ones that worked, and
        # the caller needs the whole result set to decide what to retry.
        Write-Warning "Failed on: $(($failed | ForEach-Object { $_.WorkItemType }) -join ', '). Re-import the backup in '$BackupFolder' to revert a type."
    }

    $results
}
