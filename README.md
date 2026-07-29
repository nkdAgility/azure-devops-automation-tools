# Azure DevOps Automation Tools

A PowerShell automation wrapper around the common tasks used when migrating Azure DevOps data, whether that is with the [Azure DevOps Data Import Tool](https://learn.microsoft.com/en-us/azure/devops/migrate/migration-overview) from Microsoft, the [Azure DevOps Migration Tools](https://github.com/nkdAgility/azure-devops-migration-tools), or the Azure DevOps Migration Platform — depending on context.

All these tools are built in PowerShell and have both a $data and a $output folder. Those folders belong to the **client workspace repo** — this repo is the toolkit and never holds customer data. Placeholder examples of every expected data file are in `samples/`.

## How it works

Each engagement gets a **private client git repo** holding that customer's data, configs, runbooks and export snapshots under source control. The client repo loads this repo (cloned to `%USERPROFILE%\source\repos\azure-devops-automation-tools`) and imports the PowerShell module from it. Bootstrap a new (or empty) client repo by running this from its root:

```powershell
irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex
```

The bootstrap clones/updates this repo and Microsoft's `process-customization-scripts` into `%USERPROFILE%\source\repos\`, then scaffolds the workspace (`init.ps1`, `workspace.json`, `.gitignore`, `secrets/`, `data/`, `exports/`, `migrations/`, client `CLAUDE.md`) from `templates/customer-repo/` — copying each file **only if it does not already exist**, so re-running is always safe. In the client repo:

- `. .\init.ps1` starts every session: it pulls the latest tools (`-NoSync` to skip), imports the module and initialises the workspace.
- `New-Migration -Name <Name> -Type DataImport|MigrationTools|MigrationPlatform` scaffolds a numbered `migrations\NN-<Name>\` engagement folder from `templates/migrations/`.
- `New-ExportSnapshot -Source <Collection>` creates dated `exports\<source>\<yyyyMMdd>\{xml,json}\` folders for pristine server exports.
- PATs live only in the gitignored `secrets\secrets.json`; `Set-AutomationSecrets` exports them as `AZDO_PAT_<ORG>` (plus any explicit `EnvVars` names for .NET config binding) and `Get-Organisation` merges them into `organisations.json` entries at load time.

Template co-maintenance note: the bootstrap never overwrites existing files, so changes to `templates/customer-repo/` reach already-bootstrapped client repos only when copied across manually.

The old standalone mode — running from this repo's root with `data/<environment>/` folders selected by `config.json` — is **retired**. This repo is the toolkit and never holds customer data: `/data/` and `/config.json` stay gitignored so anything dropped here by habit can never be committed, and `runmefirst.ps1` now just points at the bootstrap and lists the client workspaces on your machine.

## Repository layout

| Path | Purpose |
| ---- | ------- |
| `bootstrap.ps1` | Remote-runnable bootstrap for client workspaces (see [How it works](#how-it-works)) |
| `templates/customer-repo/` | Scaffold templates for a customer workspace (`init.ps1`, `workspace.json`, customer `CLAUDE.md`, ...) |
| `templates/migrations/` | Per-type engagement templates used by `New-Migration` (`data-import`, `migration-tools`, `migration-platform`) |
| `system/NKDAgility.AzureDevOps.AutomationTools/` | PowerShell module with the Data Import Tool fix functions, `Migrator.exe` wrappers, workspace/secrets/logging context, and scaffolding commands |
| `src/_includes/` | Legacy shared code dot-sourced by the scripts: `setup.ps1` (config + environment), `logging.ps1` (PoShLog wrappers), `methods.ps1` (REST helpers), `DataImportFixes.ps1` (now a shim that imports the module) |
| `src/DataImportTools/` | Assets supporting the Microsoft Azure DevOps Data Import Tool |
| `src/migrationTools/` | Azure DevOps Migration Tools wrappers: config generation, execution, and the reusable `Migrate-Repos.ps1` / `Migrate-Artifacts.ps1` engines (repo + artifact-feed migration; `Migrate-GitRepos.ps1` is the older repo mirroring script) |
| `src/processFieldMigrator/` | REST-API scripts for custom fields, pages, process discovery, and project stats |
| `src/processMigrator/` | Wrapper around microsoft/process-migrator |
| `src/powershell/` | Misc environment utilities |
| `tests/` | Pester suite, run on every push by `.github/workflows/ci.yml`. Everything that talks to a collection is stubbed, so no PAT or network is needed: `Invoke-Pester -Path .\tests` |
| `samples/` | Committed examples of every expected data file, placeholder values only — read-only reference, not a working data folder |
| `output/` | Scratch output from ad-hoc local runs — not under source control. Real engagement output belongs in the client repo |

## Setting up the environment

1. Clone this repository
2. Install Visual Studio Code (<https://code.visualstudio.com/>)
3. Enable Powershell Plugins in Visual Studio Code
4. Install Powershell 7

## Run the Scripts with your own data

Your data lives in a **client workspace repo**, never in this one. Bootstrap one as described above, then start every session from its root:

```powershell
. .\init.ps1
```

`init.ps1` imports the module and calls `Initialize-AutomationWorkspace`, which reads `workspace.json` and resolves the workspace's `data`, `output` and `exports` folders. The legacy scripts below additionally dot-source `src/_includes/setup.ps1` from the toolkit, which resolves `$dataFolder` and `$outputFolder` from that workspace:

```powershell
. $env:USERPROFILE\source\repos\azure-devops-automation-tools\src\_includes\setup.ps1
```

If no workspace has been initialised, `setup.ps1` throws rather than falling back to a folder inside the toolkit — that fallback is what the client-workspace model exists to prevent.

With the workspace initialised, you can run the following scripts:

- **Generate-ConfigurationsFromTemplates.ps1** - This will generate a configuration file for each template file in the data folder. Loaded from `migrationConfigSaples` folder and it will create a folder for each project on each organisation configured with the template populated for every project. This assumes that you are migrating many projects to a single organisation. If you are migrating a single project to many organisations, you will need to edit the output with the target locations. Note: it looks for `templates` in the workspace data folder first, falling back to this repo's committed `samples/templates`.
- **Delete-CustomField.ps1** - Whoops, I need to delete a field from an organisation. This will delete a field from all projects in an organisation.
- **Generate-ProcessOutput.ps1** - This will populate the process, list, field, and work item configuration data from all of the processes in each org. It will create a folder for each organisation and populate it with the data. This is for reference and can be used to build the input for the other scripts.
- **Generate-ProjectStats.ps1** - How big is my migration? Creates a CSV file with the number of work items, pipelines, builds, and other data in each project in each organisation.
- **Install-CustomFields.ps1** - Adds all of the configured fields to the configured organisations and processes. Fields are enabled in `DataLocation\fields.json` and each field is configured in `DataLocation\fields\{field-name}.json`. This script will create the fields in the configured organisations and processes.
- **Install-CustomPages.ps1** - Adds all of the configured pages to the configured organisations and processes. Each page is configured in `DataLocation\pages\{page-name}.json`. This script will create the pages in the configured organisations,  processes, & WorkItems.
- **Install-ReflectedWorkItemID.ps1** - Adds the ReflectedWorkItemID field to all of the configured organisations and processes. This is a special field that is used by the [Azure DevOps Migration Tools](https://github.com/nkdAgility/azure-devops-migration-tools) to track the work items as they are migrated. This script will create the field in the configured organisations and processes.
- **Search-ProcessesWeCareAbout.ps1** - This will search all of the configured organisations for processes that contain the configured work item field. This is useful if you are looking for a process that you know contains a specific field. It will create a CSV file with the results, and update the `organisations.json` file.

## Data Folder

The client workspace's `data` folder contains the data used by each script. You can check the `.\samples\*` folder in this repo for examples of the data required.

- `organisations.json` - This is a list of all of the organsaitions and PAT tokens used for access. They can be disabled, and the scripts will skip them. This is used by all of the scripts.
- `ReflectedWorkItemId.json` - This contains the single field configuration for the ReflectedWorkItemId field. This is used by the `Install-ReflectedWorkItemID.ps1` script.
- `fields.json` - This contains the list of fields to be created. This is used by the `Install-CustomFields.ps1` script, and each field can be enabled or disabled. It will load the individual field from the `fields` folder based on the `refname` property.
- `fields\{field-name}.json` - This contains the configuration for each field. This is used by the `Install-CustomFields.ps1` script. Each field definition contains all of the POST information needed to create and add them to a process.
- `pages\{page-name}.json` - This contains the configuration for each page. This is used by the `Install-CustomPages.ps1` script. Each page definition contains all of the POST information needed to create and add them to a process. `Pages` are iterated over and you can use them to add `Groups` to existing `Pages`.
- `templates\{template-name}.json` - This contains templates for different [Azure DevOps Migration Tools](https://github.com/nkdAgility/azure-devops-migration-tools) configurations. This is used by the `Generate-ConfigurationsFromTemplates.ps1` script. Each configuration template will have the source updated to reflect the source organisation and project, the target will not be updated.

## Documentation for POSTS

- [Create Field](https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/fields/create?view=azure-devops-rest-7.0&tabs=HTTP)
- [Create Picklist](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/lists/create?view=azure-devops-rest-7.0&tabs=HTTP)
- [Add Field](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/fields/add?view=azure-devops-rest-7.0&tabs=HTTP)
- [Add Control](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/controls/create?view=azure-devops-rest-7.0&tabs=HTTP)

## Azure DevOps Data Import Tool (server → services)

When lifting a TFS / Azure DevOps Server collection into Azure DevOps Services with Microsoft's Data Import Tool, the loop is: run `Migrator.exe` validate/prepare, read the validation log, fix the collection, repeat until clean. This repo supports that loop with:

- **Per-client runbooks** in `data/<environment>/DataImportTools/` (untracked):
  - `run.ps1` — invokes `Migrator.exe Prepare` against the client collection to produce the import specification and validation log.
  - `fix.ps1` — a sectioned runbook, executed selection-by-selection, that resolves the validation errors using the functions below. Section comments record the error codes (TF400526, TF402538, VS237302, …) each block addresses and any ordering constraints.
- **The `NKDAgility.AzureDevOps.AutomationTools` module** in `system/` — a library of Verb-Noun functions that wrap `Migrator.exe`, `witadmin.exe` (located automatically), and local XML editing. A typical runbook starts with:

  ```powershell
  Import-Module .\system\NKDAgility.AzureDevOps.AutomationTools -Force
  Set-MigrationContext -Collection 'http://tfs:8080/tfs/DefaultCollection/'
  ```

  `Set-MigrationContext` sets session defaults (collection, project, tool paths) so individual fix lines stay short. Task-level commands collapse whole runbook sections into one call per project: `Install-FeedbackWorkItemTypes` (work item types + categories prerequisites) followed by `Repair-ProcessConfiguration` (export → repair → import of `ProjectProcessConfiguration`, with state mappings as parameters). `Invoke-DataImportPrepare` / `Invoke-DataImportValidate` wrap `Migrator.exe`. The primitives remain available for one-off fixes:
  - `Rename-Field` — resolve collection-level field name conflicts with Azure DevOps Services.
  - `Import-WorkItemTypeFile`, `Add-WorkItemCategory`, `Add-WorkItemCategoryType`, `Remove-WorkItemCategoryType`, `Copy-WorkItemType` — get work item types and categories into the shape ProcessConfiguration requires.
  - `Export-ProcessConfigurationFixFile` / `Import-ProcessConfigurationFixFile` plus `Add-ProcessConfigurationElement`, `Add-ProcessConfigurationTypeField`, `Set-ProcessConfigurationAttribute`, `Set-ProcessConfigurationStates`, `Set-ProcessConfigurationColumns`, `Set-ProcessConfigurationAddPanel` — export a project's `ProjectProcessConfiguration`, repair the XML locally, and push it back.
  - `Find-WitRuleScope`, `Find-GlobalWorkflowRuleScope`, `Remove-WitRuleScope`, `Remove-GlobalWorkflowRuleScope` — locate and remove AD-scoped field rules (VS237302).
  - `Remove-WitFieldRule` — strip unsupported field rules such as NOTSAMEAS / PROHIBITEDVALUES (TF402538).
  - `Remove-WorkItemLinkType` — delete custom link types (TF402583). **Deleting a link type deletes every link of that type in the collection.**
  - `Get-WorkItemType`, `Get-WorkItemTypeState` — inspection helpers used to verify state before applying fixes.

The fix functions are designed to be idempotent where possible — re-running a fix that is already applied reports "no change" instead of failing — so a runbook section can be re-run safely after a partial pass.

### Validating one step at a time

Because the fixes mutate a live collection, runbooks are executed a bit at a time and each action verified before moving on. The module supports this loop directly:

- **`Invoke-FixStep`** — wraps a runbook step with a name, an optional `-Verify` scriptblock, and a checkpoint file. Completed steps are skipped on re-run (`-Force` overrides), and the checkpoint is only written after verification passes, so the whole runbook can be safely re-run top-to-bottom after a partial pass. Set the checkpoint file once per client with `Set-MigrationContext -CheckpointPath ...`.
- **`Get-DataImportValidationSummary`** — parses a validation run's `ProjectProcessesMap.log` into per-project error counts and per-error-code counts. Point it at the logs parent folder (e.g. `...\Logs\<Collection>`) and it picks the newest run. Capture a summary before fixing, re-run `Invoke-DataImportPrepare` after a batch of fixes, and compare — the error counts for the fixed projects should drop to zero.

### Reference originals: process-customization-scripts

When getting the local collection into shape for import, use Microsoft's [process-customization-scripts](https://github.com/Microsoft/process-customization-scripts) repository (cloned as a sibling of this repo) as the reference for what the out-of-the-box templates look like:

- The `Import\<Template>\WorkItem Tracking` folders hold the OOB type definitions, categories, and process configuration — these are the "known good" shapes the Data Import Tool validates against. The fix functions take their values (TypeFields refnames, category names, feedback work item states) from here, and `Install-FeedbackWorkItemTypes` imports `FeedbackRequest.xml` / `FeedbackResponse.xml` directly from it.
- The `Export\ExportProjectTemplate.ps1` script exports a project's full template the same way the migrator sees it — useful for diffing a customised project against the OOB originals to pinpoint exactly what a validation error refers to.

The goal is always to change the minimum needed to satisfy validation while **maintaining the customer's customisations as much as possible** — check against the originals to see what's required, don't overwrite customised definitions wholesale with OOB ones.

## Git Repository Migration

The repository migration functionality is provided by a single script: `src/migrationTools/Migrate-GitRepos.ps1`.

Purpose: Mirror (one-way) all enabled Git repositories from the source organisations & projects defined in a data environment `organisations.json` into an existing target Azure DevOps organisation (projects must already exist in target). Repositories are created if missing, then a `git --mirror` push updates all refs (branches, tags, deletes).

Parameters (only three):

- `-ConfigFile` (optional) Path to an `organisations.json`. If omitted the current data environment path from `setup.ps1` is used.
- `-TargetOrgUrl` (required) Base URL of the target organisation, e.g. `https://dev.azure.com/TargetOrg/`.
- `-TargetPat` (required) PAT for target organisation with Code (Read & Write) scope (and permission to create repositories).

Example:

```powershell
pwsh ./src/migrationTools/Migrate-GitRepos.ps1 -TargetOrgUrl https://dev.azure.com/TargetOrg/ -TargetPat $env:TARGET_PAT
```

Source Authentication: Each source organisation entry in `organisations.json` must include a `pat` property (Code Read scope) and `enabled: true`. Each project that should be migrated must also have `enabled: true` and an `id` (GUID) and `name`.

Behaviour Summary:

1. Enumerate enabled organisations & projects from source config.
2. List repos via Azure DevOps REST API.
3. For each repo:
   - Create target repo if it does not exist (same project name / repo name).
   - Perform a temporary bare clone locally.
   - Execute `git push --mirror` to target.
4. Emit summary statistics to the log.

Safety Notes:

- Mirror push will delete refs in target that were deleted in source.
- Projects are NOT created automatically; create them first in target.
- PAT values are never logged.

To adapt behaviour (e.g., additive push instead of mirror) extend the script locally—by design optional switches were removed for simplicity.
