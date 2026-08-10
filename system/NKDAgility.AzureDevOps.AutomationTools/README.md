# NKDAgility.AzureDevOps.AutomationTools

PowerShell module with the automation tasks used when migrating Azure DevOps data. Currently focused on the Azure DevOps Data Import Tool workflow (server → services); Migration Tools and Migration Platform tasks will move in over time.

## Usage

From the repo root (or a client runbook):

```powershell
Import-Module .\system\NKDAgility.AzureDevOps.AutomationTools -Force
Set-MigrationContext -Collection 'http://tfs:8080/tfs/DefaultCollection/' -MigratorPath 'C:\tools\DataMigrationTool\Migrator.exe'
```

`Set-MigrationContext` stores session defaults and applies them via `$Global:PSDefaultParameterValues`, so subsequent calls don't need to repeat `-Collection` etc. `-Project` is only defaulted on commands where it is mandatory, so commands with an optional `-Project` (e.g. `Find-WitGlobalWorkflowRuleScope`) keep collection scope unless told otherwise. `Clear-MigrationContext` undoes it.

Typical per-project fix sequence, wrapped in checkpointed steps so each action is validated once and skipped on re-run:

```powershell
Set-MigrationContext -CheckpointPath '.\data\debug\DataImportTools\fix-steps.checkpoint.json'

# Baseline: what does the latest validation run say?
Get-DataImportValidationSummary -Path '.\data\debug\DataImportTools\output\Logs\MyCollection' | Select-Object -Expand Projects

# Check the actual workflow states first - Repair-ProcessConfiguration's defaults must match them
Get-WitWorkItemTypeState -Project 'MyProject' -WorkItemType 'User Story' | Format-Table -AutoSize
Get-WitWorkItemTypeState -Project 'MyProject' -WorkItemType 'Task' | Format-Table -AutoSize

Invoke-FixStep -Name 'myproject-feedback-types' -Action {
    Install-FeedbackWorkItemTypes -Project 'MyProject' -TypeDefinitionsPath '..\process-customization-scripts\Import\Agile\WorkItem Tracking\TypeDefinitions'
} -Verify { (Get-WitWorkItemType -Project 'MyProject') -contains 'Feedback Request' }

Invoke-FixStep -Name 'myproject-process-config' -Action {
    Repair-ProcessConfiguration -Project 'MyProject' -Path '.\fix-work\MyProject.ProcessConfiguration.xml'
}

# After a batch: re-run Prepare and compare the summary - fixed projects should drop to zero
Invoke-DataImportPrepare -TenantDomainName 'example.com' -OutputPath '.\output'
Get-DataImportValidationSummary -Path '.\data\debug\DataImportTools\output\Logs\MyCollection' | Select-Object -Expand Projects
```

Values used by the fix functions (TypeFields refnames, categories, feedback states) are taken from the out-of-the-box templates in Microsoft's [process-customization-scripts](https://github.com/Microsoft/process-customization-scripts) repo — keep it cloned as a sibling of this repo and use it as the reference for what "valid" looks like, changing the minimum needed so the customer's customisations are preserved.

## Structure

- `Public/Common/` — session context (`Set-MigrationContext`, `Get-MigrationContext`, `Clear-MigrationContext`) and the checkpointed step runner (`Invoke-FixStep`)
- `Public/DataImportTool/` — `Migrator.exe` wrappers (`Invoke-DataImportPrepare`, `Invoke-DataImportValidate`), validation log parsing (`Get-DataImportValidationSummary`), task-level fixes (`Install-FeedbackWorkItemTypes`, `Repair-ProcessConfiguration`), and the witadmin / process-configuration primitives
- `Private/` — path resolution and witadmin invocation helpers (not exported)

One function per file; the file name matches the function name. The `.psm1` dot-sources everything and exports only `Public/**`. When adding a public function, also add it to `FunctionsToExport` in the `.psd1`.

## Conventions

- Verb-Noun names, `[CmdletBinding()]`, mandatory parameters for anything that targets a server.
- Fix functions are idempotent where possible: re-running an already-applied fix reports "no change" instead of failing.
- Functions that mutate a collection write a `[fix]` step line for every action so runbook output doubles as an audit trail.
- Never log or echo PAT tokens or connection strings containing credentials.
