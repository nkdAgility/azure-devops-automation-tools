# <Migration name> - engagement log

- **Type:** Azure DevOps Migration Platform (`migration` CLI)
- **Source org/project(s):**
- **Target org/project(s):**
- **Key dates:** dry-run: / cutover:

## Workflow

1. Fill `platform-config.json`. PATs stay as `$ENV:AZDO_PAT_<ORG>` placeholders -
   `Set-AutomationSecrets` supplies them from `..\..\secrets\secrets.json`.
2. `.\Sync.ps1` in Inventory mode first (the template default) for read-only discovery.
3. Change `Mode` in the config when ready, preview with `.\Sync.ps1 -WhatIf`, then run.

## Run log

| Date | What ran | Result |
| ---- | -------- | ------ |
