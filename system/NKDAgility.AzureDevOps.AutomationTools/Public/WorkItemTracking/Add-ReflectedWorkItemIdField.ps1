function Add-ReflectedWorkItemIdField {
    <#
    .SYNOPSIS
    Adds the reflected work item ID field to an inherited-process project, over REST.

    .DESCRIPTION
    The REST counterpart of Add-WitReflectedWorkItemIdField. Same requirement, different world:
    the Azure DevOps Migration Tools refuse to move a work item without a field on the TARGET
    recording which source item it came from, and its pre-validation fails with

        Reflected work item ID field is mandatory for work item migration.

    Which route you take depends on the collection's process model, not on the migration:

        XML process       witadmin, per work item type   -> Add-WitReflectedWorkItemIdField
        Inherited process this command, over REST

    On-premises a collection is one or the other, never both. This command refuses to run
    against a project on a SYSTEM process, because system processes cannot be customised at
    all - the fix there is to create an inherited child process and move the project onto it
    first, which is a decision about the project rather than something to do as a side effect
    of a migration prerequisite.

    Three phases, all idempotent:

      1. Ensure the field exists on the collection. Created once, then shared.
      2. Derive each system work item type onto the process. An inherited process starts out
         referencing the SYSTEM types, which accept no customisation - this is the step that
         gives the process its own copy. Types already derived are left alone.
      3. Add the field to each type. Types that already have it are skipped, so re-running
         after a partial failure costs nothing.

    Deriving is a real customisation of the process, not a no-op: the type stops tracking
    future changes to the system definition. It is unavoidable - there is no way to put a
    custom field on a system type - but it is worth knowing it happened.

    Finally it re-reads the project's own field list to confirm the field is really visible
    where the migration will look for it, rather than trusting the write calls.

    THIS WRITES TO A LIVE COLLECTION. Run with -WhatIf first.

    .PARAMETER Collection
    Collection or organisation URL, e.g. https://dev-liechti.int.machining.com/UM-LEAG.

    .PARAMETER Project
    Team project whose process should get the field.

    .PARAMETER WorkItemType
    Work item types to change, by display name. Omit for every type on the process, minus
    -ExcludeWorkItemType.

    .PARAMETER ExcludeWorkItemType
    Types to leave alone. Defaults to the test types, which are usually out of scope for a
    work item migration. Exclude them from TfsWorkItemTypeValidatorTool as well, or validation
    will still demand the field on them.

    .PARAMETER ReferenceName
    Field reference name. Must match ReflectedWorkItemIdField in the migration config, and must
    start with 'Custom.' - the inherited model will not create a field in any other namespace.

    .PARAMETER FieldName
    Friendly field name. Default 'ReflectedWorkItemId'.

    .PARAMETER Pat
    Access token. Omit on-premises and pass -UseDefaultCredentials instead.

    .PARAMETER UseDefaultCredentials
    Authenticate as the current Windows identity. What an on-premises Azure DevOps Server
    collection normally wants.

    .EXAMPLE
    Add-ReflectedWorkItemIdField -Collection 'https://dev-liechti.int.machining.com/UM-LEAG' -Project 'UM-LEAG-CAM' -UseDefaultCredentials -WhatIf

    .EXAMPLE
    Add-ReflectedWorkItemIdField -Collection 'https://dev.azure.com/contoso' -Project 'Payments'

    .OUTPUTS
    One object per work item type: WorkItemType, Status (Added / AlreadyPresent / WouldAdd /
    Failed), Message.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [string[]]$WorkItemType,
        [string[]]$ExcludeWorkItemType = @('Test Case', 'Test Plan', 'Test Suite'),
        [string]$ReferenceName = 'Custom.ReflectedWorkItemId',
        [string]$FieldName = 'ReflectedWorkItemId',
        [string]$Pat,
        [switch]$UseDefaultCredentials
    )

    # The inherited model only creates fields in the Custom namespace. Anything else is
    # rejected by the service after the process lookups have already been done.
    if ($ReferenceName -notlike 'Custom.*') {
        throw "ReferenceName '$ReferenceName' must start with 'Custom.' - the inherited process model will not create a field in another namespace."
    }

    $auth = @{}
    if ($Pat) { $auth.Pat = $Pat }
    elseif ($UseDefaultCredentials) { $auth.UseDefaultCredentials = $true }
    $processApi = '7.1-preview.2'

    Write-FixSection "Adding '$ReferenceName' to '$Project' (inherited process)"
    Write-FixStep "Collection: $Collection"

    # --- which process is this project on? -----------------------------------------------
    # NOT $project: PowerShell variable names are case-insensitive, so that would assign into
    # the [string]$Project PARAMETER, silently coercing the response object to its string
    # representation - and .id on a string is empty, producing '_apis/projects//properties'.
    $teamProject = Invoke-AzureDevOpsApi @auth -Collection $Collection -Path "_apis/projects/$([uri]::EscapeDataString($Project))" -ApiVersion '7.1'
    $properties = Invoke-AzureDevOpsApi @auth -Collection $Collection -Path "_apis/projects/$($teamProject.id)/properties" -ApiVersion '7.1-preview.1'
    $processId = ($properties.value | Where-Object { $_.name -eq 'System.ProcessTemplateType' }).value
    if (-not $processId) {
        throw "Could not determine the process for project '$Project'. This command only supports collections on the inherited process model."
    }

    $processes = Invoke-AzureDevOpsApi @auth -Collection $Collection -Path '_apis/work/processes' -ApiVersion $processApi
    $process = $processes.value | Where-Object { $_.typeId -eq $processId }
    if (-not $process) {
        throw "Project '$Project' is on process '$processId', which this collection does not list under _apis/work/processes. That normally means the collection uses the XML process model - use Add-WitReflectedWorkItemIdField instead."
    }
    if ($process.customizationType -eq 'system') {
        throw @"
Project '$Project' is on the SYSTEM process '$($process.name)', which cannot be customised.

Create an inherited process from '$($process.name)', move '$Project' onto it, then re-run.
Do that before migrating: moving a project between processes is trivial while it is empty
and considerably less so once it holds work items.
"@
    }
    Write-FixStep "Process:    $($process.name) ($($process.customizationType), parent $($process.parentProcessTypeId))"

    # --- phase 1: the field must exist on the collection ---------------------------------
    $fieldExists = $true
    try {
        Invoke-AzureDevOpsApi @auth -Collection $Collection -Path "_apis/wit/fields/$ReferenceName" -ApiVersion '7.1' | Out-Null
        Write-FixStep "Field '$ReferenceName' already exists on the collection."
    }
    catch {
        $fieldExists = $false
    }
    if (-not $fieldExists) {
        if ($PSCmdlet.ShouldProcess($Collection, "Create field '$ReferenceName'")) {
            $body = @{
                name          = $FieldName
                referenceName = $ReferenceName
                type          = 'string'
                usage         = 'workItem'
                readOnly      = $false
                canSortBy     = $true
                isQueryable   = $true
            }
            Invoke-AzureDevOpsApi @auth -Collection $Collection -Path '_apis/wit/fields' -Method Post -Body $body -ApiVersion '7.1' | Out-Null
            Write-FixStep "Created field '$ReferenceName' on the collection."
        }
        else {
            Write-FixStep "Would create field '$ReferenceName' on the collection."
        }
    }

    # --- phase 2: attach it to each work item type ---------------------------------------
    $types = (Invoke-AzureDevOpsApi @auth -Collection $Collection -Path "_apis/work/processes/$processId/workitemtypes" -ApiVersion $processApi).value
    if ($WorkItemType) {
        $types = @($types | Where-Object { $WorkItemType -contains $_.name })
    }
    $skipped = @($types | Where-Object { $ExcludeWorkItemType -contains $_.name })
    $types = @($types | Where-Object { $ExcludeWorkItemType -notcontains $_.name })
    if ($skipped) { Write-FixStep "Excluded: $(($skipped | ForEach-Object { $_.name }) -join ', ')" }
    if (-not $types) {
        Write-FixStep 'No work item types to process.'
        return
    }
    Write-FixStep "Processing $($types.Count) work item type(s): $(($types | ForEach-Object { $_.name }) -join ', ')"

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $types) {
        $status = 'Failed'
        $message = ''
        try {
            # A work item type the process inherited but has never customised is still the
            # SYSTEM type, and a system type takes no fields - the POST is rejected with
            # VS402805 naming the very reference name the GET just returned. It has to be
            # derived onto this process first, and the derived type gets its OWN reference
            # name, so read that back from the response rather than assuming its shape.
            $witRef = $type.referenceName
            if ($type.customization -eq 'system') {
                if (-not $PSCmdlet.ShouldProcess("$Project/$($type.name)", "Derive work item type, then add field '$ReferenceName'")) {
                    Write-FixStep "  '$($type.name)': would derive, then add '$ReferenceName'"
                    $results.Add([pscustomobject]@{ WorkItemType = $type.name; Status = 'WouldAdd'; Message = 'needs deriving first' })
                    continue
                }
                # inheritsFrom alone is not enough: name, color and icon are all required, and
                # a missing one fails as a bare ArgumentNullException naming the parameter
                # ('Value cannot be null. Parameter name: color'). Carry the system type's own
                # values across so the derived type is indistinguishable from what it replaces
                # on the board - a derived Task with a different colour is a visible change
                # nobody asked for.
                $derived = Invoke-AzureDevOpsApi @auth -Collection $Collection `
                    -Path "_apis/work/processes/$processId/workitemtypes" -Method Post `
                    -Body @{
                        name         = $type.name
                        description  = $type.description
                        color        = $type.color
                        icon         = $type.icon
                        inheritsFrom = $type.referenceName
                        isDisabled   = [bool]$type.isDisabled
                    } -ApiVersion $processApi
                if (-not $derived.referenceName) {
                    throw "Deriving '$($type.name)' returned no reference name."
                }
                $witRef = $derived.referenceName
                Write-FixStep "  '$($type.name)': derived as '$witRef'"
            }

            $witPath = "_apis/work/processes/$processId/workItemTypes/$witRef/fields"
            $existing = (Invoke-AzureDevOpsApi @auth -Collection $Collection -Path $witPath -ApiVersion $processApi).value
            if ($existing.referenceName -contains $ReferenceName) {
                $status = 'AlreadyPresent'
                Write-FixStep "  '$($type.name)': already has '$ReferenceName' - no change"
            }
            elseif (-not $PSCmdlet.ShouldProcess("$Project/$($type.name)", "Add field '$ReferenceName'")) {
                $status = 'WouldAdd'
                Write-FixStep "  '$($type.name)': would add '$ReferenceName'"
            }
            else {
                # referenceName only: the field already exists by now, and this call attaches
                # it. Sending name/type here would ask the service to create it a second time.
                $body = @{ referenceName = $ReferenceName; required = $false; readOnly = $false; allowGroups = $false }
                Invoke-AzureDevOpsApi @auth -Collection $Collection -Path $witPath -Method Post -Body $body -ApiVersion $processApi | Out-Null
                $status = 'Added'
                Write-FixStep "  '$($type.name)': added"
            }
        }
        catch {
            $message = $_.Exception.Message
            Write-FixStep "  '$($type.name)': FAILED - $message"
        }
        $results.Add([pscustomobject]@{ WorkItemType = $type.name; Status = $status; Message = $message })
    }

    # --- verify against the project, not against the write calls -------------------------
    if ($results.Status -contains 'Added') {
        $projectFields = (Invoke-AzureDevOpsApi @auth -Collection $Collection -Path "$([uri]::EscapeDataString($Project))/_apis/wit/fields" -ApiVersion '7.1').value
        if ($projectFields.referenceName -notcontains $ReferenceName) {
            throw "Verification failed: '$ReferenceName' is not visible in project '$Project' after the changes."
        }
        Write-FixStep "Verified: '$ReferenceName' is visible in '$Project'."
    }

    $added = @($results | Where-Object { $_.Status -eq 'Added' }).Count
    $present = @($results | Where-Object { $_.Status -eq 'AlreadyPresent' }).Count
    $would = @($results | Where-Object { $_.Status -eq 'WouldAdd' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    Write-FixStep "Added $added, already present $present, would add $would, failed $($failed.Count)."
    if ($failed) {
        Write-Warning "Failed on: $(($failed | ForEach-Object { $_.WorkItemType }) -join ', ')."
    }

    $results
}
