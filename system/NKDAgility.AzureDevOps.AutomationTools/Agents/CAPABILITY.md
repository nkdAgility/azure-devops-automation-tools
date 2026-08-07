## Migration capability

Azure DevOps migration engagements, across three toolchains: the Microsoft Data Import
Tool (`Migrator.exe` / `witadmin.exe`), the Azure DevOps Migration Tools, and the Azure
DevOps Migration Platform.

### Scaffolding an engagement

```powershell
New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform
New-ExportSnapshot -Source <Collection>
```

`New-Migration` creates `migrations/NN-<Name>/` from the template shipped inside the
module and stamps `.template.json` with what produced it. The contents are **seeds** —
yours to edit; the template never overwrites them again.

### Rules

- **Anything that writes to a `-Collection` or organisation URL is destructive.** Do not
  run it unprompted. Never run a whole fix file against production without review.
- **Cleanup runbooks are run selection-by-selection in VS Code, never top-to-bottom.**
  Preserve their sectioned structure; each section's comments record the witadmin or
  migrator error code it addresses (TF400526, TF402538, VS237302, …) and its ordering
  constraints.
- **`Migration Tools` / `Platform` engagements: run `Sync.ps1 -WhatIf` first, always.**
- **Custom link type deletion is irreversible.** `witadmin deletelinktype` destroys every
  link of that type along with the definition. `Remove-WorkItemLinkType` inventories over
  REST first and refuses to delete if that export fails; `-NoExport` exists for the case
  where you have already captured the inventory, not to make an error go away.
- **Exports are pristine.** Never modify anything under `exports/`. Edit copies in the
  owning migration's `fix-work/`.
- **Preserve the customer's customisations.** Change the minimum needed to pass
  validation; never wholesale-replace a customised definition with the out-of-box one.

### The Data Import fix loop

1. `Get-DataImportValidationSummary` over the current validation logs — the baseline.
2. Fix one step, wrapped in `Invoke-FixStep` so it checkpoints and skips on re-run.
3. Verify it (the step's own `-Verify` scriptblock).
4. Re-run `Invoke-DataImportPrepare`.
5. Compare summaries. Repeat.

`Set-MigrationContext -Collection … -Project …` sets session defaults so runbook lines do
not repeat them; `Clear-MigrationContext` undoes it.

### Reference shapes

Microsoft's `process-customization-scripts` repo holds the out-of-box template shapes the
Data Import Tool validates against. Fix values — TypeFields, categories, feedback states —
come from there. Verify state mappings against `Get-WorkItemTypeState` before running
`Repair-ProcessConfiguration`.

### Transports

Two, each with one private invoker that every public function goes through. Never call
`witadmin.exe` or `Invoke-RestMethod` directly from a public function.

| | witadmin / Migrator.exe | REST |
| - | - | - |
| Invoker | `Invoke-WitAdminFix` | `Invoke-AzureDevOpsApi` |
| Good for | schema and process definitions | the data itself: work items, links, queries |
