# <Migration name> - engagement log

- **Type:** Azure DevOps Migration Tools (`devopsmigration.exe`) + repo/artifact engines
- **Source org/project(s):**
- **Target org/project(s):**
- **Key dates:** dry-run: / cutover:

## Workflow

1. Fill `migrate-repos-config.json` (repos/artifacts) and the `configuration-*.json` files
   (work items, pipelines). PATs stay as `$ENV:AZDO_PAT_<ORG>` placeholders / empty
   `AccessToken` fields - `Set-AutomationSecrets` supplies them from `..\..\secrets\secrets.json`.
2. `.\Sync.ps1 -WhatIf` to preview everything, then `.\Sync.ps1` to run: repos -> pipelines ->
   artifacts -> work items. Re-running is safe (idempotent engines skip what already moved).
3. `.\Run-Migrate-Artifacts.ps1 -Inventory` for a read-only inventory CSV before committing to
   package migration.
4. Commit the summary CSVs written to `output\` as engagement evidence.

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
