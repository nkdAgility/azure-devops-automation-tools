# <Migration name> - engagement log

- **Type:** Data Import Tool (Microsoft `Migrator.exe` collection lift-and-shift)
- **Source collection:**
- **Target organisation:**
- **Key dates:** dry-run: / cutover:

## Workflow

1. `DataImport-Scratchbook.ps1` section 1 (Prepare) generates the import specification
   (`import.json`) and validation logs under the workspace `output/` folder. Copy the completed
   `import.json` into this folder when it is ready to commit.
2. Fix validation errors with `DataImport-Cleanup.ps1` (selection-by-selection), re-run Prepare,
   compare `Get-DataImportValidationSummary` before/after.
3. Export pristine snapshots (witadmin / process templates) into `..\..\exports\` via
   `New-ExportSnapshot` before and after fixing.

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
