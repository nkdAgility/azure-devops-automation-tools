function Update-BuildTaskVersion {
    <#
    .SYNOPSIS
    Moves every classic build definition in a project from one major version of a task to
    another, in place, so the definitions migrate to an organisation that only has the
    newer version.

    .DESCRIPTION
    devopsmigration.exe copies a classic build definition as it is, so a step pinned to a
    task version the target organisation does not have ("A task is missing. The pipeline
    references a task called '<id>'") cannot be migrated. Rather than change the tool, this
    updates the SOURCE definitions to a version both organisations have, then the
    definitions migrate unchanged.

    For each classic definition (YAML pipelines are left alone) with a step whose task id
    is -TaskId and whose versionSpec is not already '<ToMajor>.*':
      - the definition is saved as JSON under -BackupPath before anything is written;
      - the step's versionSpec becomes '<ToMajor>.*';
      - inputs the new version requires and the step does not set get the new version's
        default, so the step behaves as the task's own defaults intend.

    Before writing, the new version must exist in the organisation and must accept every
    input the old steps set; otherwise nothing is changed and the incompatible inputs are
    reported. Run with -WhatIf first: it previews each definition.

    .PARAMETER Collection
    Organisation URL holding the definitions, e.g. https://dev.azure.com/contoso.

    .PARAMETER Project
    Project whose classic build definitions are updated.

    .PARAMETER TaskId
    The task's id (a GUID, as in the "A task is missing" error).

    .PARAMETER ToMajor
    The major version to move to, e.g. 3.

    .PARAMETER BackupPath
    Folder for the per-definition JSON backups. Restore one by PUTting it back.

    .PARAMETER Pat
    Token for the organisation. Omit to use Entra or the workspace secrets.

    .EXAMPLE
    Update-BuildTaskVersion -Collection https://dev.azure.com/contoso -Project Mammoth `
        -TaskId 3edc451e-360c-40e5-a221-a42d5c987ab8 -ToMajor 3 -BackupPath .\output\build-backup -WhatIf

    .OUTPUTS
    One object per step changed or planned: Definition, Id, Step, From, To, InputsDefaulted.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string]$Collection,
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [guid]$TaskId,
        [Parameter(Mandatory)] [int]$ToMajor,
        [Parameter(Mandatory)] [string]$BackupPath,
        [string]$Pat
    )

    $apiVersion = '7.1'
    $api = { param($path, $method = 'Get', $body = $null)
        $arguments = @{ Collection = $Collection; Path = $path; Method = $method; ApiVersion = $apiVersion }
        if ($Pat) { $arguments.Pat = $Pat }
        if ($null -ne $body) { $arguments.Body = $body }
        Invoke-AzureDevOpsApi @arguments
    }
    $id = $TaskId.ToString()
    $toSpec = "$ToMajor.*"

    # The new version must be installed, and must accept every input the old steps use.
    $versions = @((& $api "_apis/distributedtask/tasks/$id").value)
    $newTask = $versions | Where-Object { $_.version.major -eq $ToMajor } |
        Sort-Object { $_.version.minor }, { $_.version.patch } | Select-Object -Last 1
    if (-not $newTask) {
        throw "Task $id has no version $ToMajor in $Collection (installed: $((@($versions | ForEach-Object { '{0}.{1}.{2}' -f $_.version.major, $_.version.minor, $_.version.patch }) -join ', '))). Install it first."
    }
    $newInputs = @($newTask.inputs)
    $newInputNames = @($newInputs.name)

    $definitions = @((& $api "$([uri]::EscapeDataString($Project))/_apis/build/definitions?`$top=1000").value)
    $plans = foreach ($summary in $definitions) {
        $definition = & $api "$([uri]::EscapeDataString($Project))/_apis/build/definitions/$($summary.id)"
        if ($definition.process.type -ne 1) { continue }   # classic only; YAML lives in the repo
        $steps = @(foreach ($phase in @($definition.process.phases)) {
                foreach ($step in @($phase.steps)) {
                    if ($step.task.id -eq $id -and $step.task.versionSpec -ne $toSpec) { $step }
                }
            })
        if ($steps.Count) { [pscustomobject]@{ Definition = $definition; Steps = $steps } }
    }
    $plans = @($plans)

    # Refuse the whole change if any step sets an input the new version does not know.
    $unknown = @(foreach ($plan in $plans) {
            foreach ($step in $plan.Steps) {
                foreach ($property in @($step.inputs.PSObject.Properties)) {
                    if ("$($property.Value)" -ne '' -and $property.Name -notin $newInputNames) {
                        "$($plan.Definition.name) / $($step.displayName): input '$($property.Name)'"
                    }
                }
            }
        })
    if ($unknown.Count) {
        throw "Version $ToMajor of task $id does not accept inputs these steps set; nothing changed:`n  $($unknown -join "`n  ")"
    }

    Write-FixStep ("{0} classic definition(s) in '{1}' use task {2} below {3}" -f $plans.Count, $Project, $id, $toSpec)
    if (-not $WhatIfPreference) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }

    foreach ($plan in $plans) {
        $definition = $plan.Definition
        $results = foreach ($step in $plan.Steps) {
            $from = $step.task.versionSpec
            $defaulted = @(foreach ($input in @($newInputs | Where-Object required)) {
                    $current = $step.inputs.PSObject.Properties[$input.name]
                    if (-not $current -or "$($current.Value)" -eq '') {
                        $step.inputs | Add-Member -NotePropertyName $input.name -NotePropertyValue "$($input.defaultValue)" -Force
                        "$($input.name)=$($input.defaultValue)"
                    }
                })
            $step.task.versionSpec = $toSpec
            [pscustomobject]@{
                Definition      = "$($definition.path.TrimEnd('\'))\$($definition.name)".TrimStart('\')
                Id              = $definition.id
                Step            = $step.displayName
                From            = $from
                To              = $toSpec
                InputsDefaulted = $defaulted -join '; '
            }
        }
        if ($PSCmdlet.ShouldProcess("$($definition.name) (id $($definition.id), $(@($results).Count) step(s))", "Set task $id to $toSpec")) {
            # Backup of the definition as it was read (re-read: $definition is now edited).
            $original = & $api "$([uri]::EscapeDataString($Project))/_apis/build/definitions/$($definition.id)"
            $original | ConvertTo-Json -Depth 50 |
                Set-Content -LiteralPath (Join-Path $BackupPath ('{0}-{1}.json' -f $definition.id, ($definition.name -replace '[^\w.-]', '_'))) -Encoding UTF8
            $null = & $api "$([uri]::EscapeDataString($Project))/_apis/build/definitions/$($definition.id)" 'Put' ($definition | ConvertTo-Json -Depth 50)
            Write-Host "    + $($definition.name): $toSpec" -ForegroundColor Green
        }
        $results
    }
}
