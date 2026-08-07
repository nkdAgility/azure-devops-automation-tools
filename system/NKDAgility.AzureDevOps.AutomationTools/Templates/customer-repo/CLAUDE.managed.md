
> **Generated block — do not edit.** Refreshed from
> `Templates/customer-repo/CLAUDE.managed.md` inside the
> `NKDAgility.AzureDevOps.AutomationTools` module on every `. .\init.ps1`.
> To change this text, edit it in the tools repo.

## What this repo is

A private nkdAgility **customer workspace** for Azure DevOps migration engagements. It
holds this customer's data, configs, runbooks and export snapshots under source control.

The reusable tooling is the `NKDAgility.AzureDevOps.AutomationTools` PowerShell module,
which ships its own templates and is imported by `init.ps1`. **Never edit tools code from
this repo** — fix it in `nkdAgility/azure-devops-automation-tools` and re-run `init.ps1`.
Microsoft's `process-customization-scripts` (reference OOB process shapes) is a sibling
clone at `%USERPROFILE%\source\repos\process-customization-scripts`.

## Layout

| Path | Purpose |
| ---- | ------- |
| `init.ps1` | Per-session loader: syncs the tools repos, refreshes framework-owned files, creates any missing `*.example.*` sibling with placeholders, imports the module, initialises the workspace. Runbooks dot-source it. `-NoSync` for offline work |
| `workspace.json` | Committed machine-independent config (data/output/exports folders, API versions) |
| `workspace.local.json` | Gitignored machine overrides (e.g. `toolsPath`) |
| `secrets/secrets.json` | Gitignored PATs; `secrets.example.json` shows the shape |
| `data/` | Committed data files (`organisations.json` — no PATs) |
| `exports/<source>/<yyyyMMdd>/{xml,json}/` | Committed pristine server-export snapshots — never edited |
| `migrations/NN-<Name>/` | One self-contained folder per engagement (configs, runbooks, `fix-work/` working copies, committed evidence CSVs) |
| `output/` | Gitignored: logs, checkpoints, scratch |

## How to run

1. `. .\init.ps1` at the start of a session (dot-sourced).
2. Scaffold an engagement: `New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform`.
3. Migration Tools / Platform engagements: run `Sync.ps1 -WhatIf` first, always; then `Sync.ps1`.

## Seed files versus managed files

Two different lifecycles, and mixing them up loses work:

- **Seed** — copied once at scaffold time, then yours. Engagement runbooks, `workspace.json`,
  `data/organisations.json`. Template improvements never reach them; each engagement folder
  records what produced it in `.template.json`.
- **Managed** — overwritten from the module on every `init.ps1`. `init.ps1` itself,
  `secrets/secrets.example.json`, and the block you are reading. Editing these here is
  always lost; edit the template in the tools repo instead.

## Committed output policy

Inventory and summary CSVs under `migrations/*/output/` are engagement evidence — commit
them. Logs and scratch stay in the repo-level gitignored `output/`.

## The Data Import fix loop

Summarise the baseline with `Get-DataImportValidationSummary`, fix one step (wrapped in
`Invoke-FixStep` so it checkpoints and skips on re-run), verify it, re-run
`Invoke-DataImportPrepare`, then compare summaries. Change the minimum needed to pass
validation — preserve the customer's customisations rather than replacing them with OOB
definitions.
