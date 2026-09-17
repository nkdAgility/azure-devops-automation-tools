# Azure DevOps Automation Tools

PowerShell tools for running Azure DevOps migrations from a private client workspace. The module supplies workspace setup, migration runbook templates, commands for Microsoft Data Import Tool preparation and repair, and engines for moving repositories and artifacts. This repository is the shared toolkit; customer configuration, exports, runbooks, output, and secrets belong in the client workspace.

## Start here

Use PowerShell 7 and Git. From the root of a new or existing private client repository, run:

```powershell
irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex
```

Bootstrap clones or updates this toolkit and Microsoft's `process-customization-scripts` under `%USERPROFILE%\source\repos`, then creates missing workspace files. It preserves files already owned by the client. Review `workspace.json`, `capabilities.json`, `data/organisations.json`, and `secrets/secrets.example.json` in the client repository before running a migration. Store tokens only in its gitignored `secrets/secrets.json`.

Start a fresh PowerShell session in the client repository and load its engines:

```powershell
. .\init.ps1
New-Migration -Name 'ExampleMigration' -Type MigrationTools
```

`New-Migration` creates the next numbered `migrations/NN-<Name>/` folder. Choose `DataImport`, `MigrationTools`, `MigrationPlatform`, or `GitHubRepos` for `-Type`. The generated runbooks and configuration are client-owned seeds; review and edit them for the engagement. Run `Sync.ps1 -WhatIf` before a Migration Tools, Migration Platform, or GitHub repository migration. Data Import cleanup runbooks are designed to be run section by section after inspecting validation results.

Use `New-ExportSnapshot -Source '<Collection>'` to create a dated location for pristine server exports. Runbooks and their outputs stay in the client repository. Re-run `. .\init.ps1` in a new shell when starting work so the workspace refreshes its engine copies.

## What it supports

| Workflow | What to use |
| --- | --- |
| Microsoft Data Import Tool, Server to Services | `DataImport` template and module commands for `Migrator.exe` preparation, validation summaries, and `witadmin` process fixes |
| Azure DevOps Migration Tools | `MigrationTools` template with `Sync.ps1`, configuration, and binders for repository and Azure Artifacts feed migration |
| Azure DevOps Migration Platform | `MigrationPlatform` template and platform configuration |
| Azure DevOps to GitHub repositories | `GitHubRepos` template with inventory, approval, preview, and migration runbooks |
| Related repairs and transfers | Module engines for wiki and comment links, work item ID alignment, and historical pipeline artifact publishing |

The [module guide](system/NKDAgility.AzureDevOps.AutomationTools/README.md) documents the commands and detailed workflows. The [workspace guide](system/NKDAgility.AzureDevOps.AutomationTools/Templates/customer-repo/README.md) explains daily use of a generated client repository. The [capability guide](system/NKDAgility.AzureDevOps.AutomationTools/Agents/CAPABILITY.md) covers migration safety and authentication. Each generated migration folder also has a `notes.md` for its specific workflow.

`Invoke-AutomationWorkspaceInit` is the workspace initialization command used by generated `init.ps1`. For historical pipeline artifacts, the module ships `Migrate-PipelineArtifacts.ps1` and `Publish-PipelineArtifacts.ps1`; see the [historical artifact workflow](system/NKDAgility.AzureDevOps.AutomationTools/README.md#historical-build-pipeline-and-release-artifacts).

## Repository map

| Path | Purpose |
| --- | --- |
| `bootstrap.ps1` | Create or update the client workspace scaffold |
| `system/NKDAgility.AzureDevOps.AutomationTools/` | Self-contained PowerShell module, engines, and templates copied into client workspaces |
| `tests/` | Pester tests for the module and engines |
| `samples/` | Placeholder examples for older input formats; no customer data |
| `legacy/` | Retained older standalone scripts and helpers |

The old root-level `config.json` and `data/` execution model is retired. Do not put customer data or tokens in this repository.

## Legacy Features

The scripts in `legacy/` are retained for existing runbooks. They are outside the current module and template workflow. If an engagement still calls one, update its path from `src/` to `legacy/`, initialize the client workspace first, and review the script before use.

- `legacy/_includes/`: setup, logging, REST, Excel, and Data Import compatibility helpers.
- `legacy/DataImportTools/`: older Data Import supporting asset.
- `legacy/migrationTools/`: configuration generation, execution, and the older Git repository mirror script.
- `legacy/processFieldMigrator/`: custom field and page scripts, process discovery, and project statistics.
- `legacy/processMigrator/`: wrapper around Microsoft's process migrator.
- `legacy/powershell/`: environment and download utilities.

For new work, use the module and migration templates under `system/NKDAgility.AzureDevOps.AutomationTools/`.

## Developing the toolkit

Run the local test suite with PowerShell 7:

```powershell
Invoke-Pester -Path .\tests
```

See [AGENTS.md](AGENTS.md) for repository ownership, safety rules, and contribution guidance.
