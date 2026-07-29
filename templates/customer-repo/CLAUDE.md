# CLAUDE.md

Guidance for Claude Code (and other AI assistants) working in this customer repository.

## What this repo is

A private nkdAgility **customer workspace** for Azure DevOps migration engagements. It holds this
customer's data, configs, runbooks and export snapshots under source control. The reusable
tooling lives in the separate public repo `nkdAgility/azure-devops-automation-tools`, cloned to
`%USERPROFILE%\source\repos\azure-devops-automation-tools` — **update it with `git pull` there;
never edit tools code from this repo**. Microsoft's `process-customization-scripts` (reference
OOB process shapes) is a sibling clone at `%USERPROFILE%\source\repos\process-customization-scripts`.

## Layout

| Path | Purpose |
| ---- | ------- |
| `init.ps1` | Per-session loader: syncs the tools repos, imports the module, initialises the workspace. Runbooks dot-source it. `-NoSync` for offline work |
| `workspace.json` | Committed machine-independent config (data/output/exports folders, API versions) |
| `workspace.local.json` | Gitignored machine overrides (e.g. `toolsPath`) |
| `secrets/secrets.json` | Gitignored PATs; `secrets.example.json` shows the shape |
| `data/` | Committed data files (`organisations.json` — no PATs) |
| `exports/<source>/<yyyyMMdd>/{xml,json}/` | Committed pristine server-export snapshots — never edited |
| `migrations/NN-<Name>/` | One self-contained folder per engagement/workstream (configs, runbooks, `fix-work/` working copies, committed evidence CSVs) |
| `output/` | Gitignored: logs, checkpoints, scratch |

## How to run

1. `. .\init.ps1` at the start of a session (dot-sourced).
2. Scaffold a new engagement with `New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform`.
3. Data Import runbooks: `DataImport-Scratchbook.ps1` and `DataImport-Cleanup.ps1` are run
   **selection-by-selection in VS Code, not top-to-bottom**. Preserve their sectioned structure.
4. Migration Tools / Platform engagements: run `Sync.ps1 -WhatIf` first, always; then `Sync.ps1`.

## Critical rules

- **Secrets:** `secrets/secrets.json` is gitignored and must stay so. NEVER print, log, echo or
  commit PATs; never add a `pat` value to `data/organisations.json`. When debugging auth, report
  header/variable *presence*, not values.
- **Live systems:** runbooks mutate live customer TFS/Azure DevOps instances. Run cleanup/fix
  sections deliberately; never run a whole fix file against production without review. Anything
  that writes to a `-Collection` or organisation URL is destructive — do not run it unprompted.
- **Committed output policy:** inventory/summary CSVs under `migrations/*/output/` are engagement
  evidence — commit them. Logs and scratch stay in the repo-level gitignored `output/`.
- **Exports are pristine:** never modify files under `exports/`; edit copies in the owning
  migration's `fix-work/`.
