# CLAUDE.md

Guidance for Claude Code (and other AI assistants) working in this repository.

## What this repo is

PowerShell automation wrappers around the tasks Naked Agility (nkdAgility) uses when moving Azure DevOps data around. Depending on the engagement, the underlying toolchain is one of:

- **Azure DevOps Data Import Tool** (Microsoft's `Migrator.exe` / `witadmin.exe`) — lift-and-shift of a TFS / Azure DevOps Server collection into Azure DevOps Services.
- **Azure DevOps Migration Tools** (nkdAgility) — work-item-level migration between organisations/projects.
- **Azure DevOps Migration Platform** — the newer nkdAgility tooling.

The scripts in `src/` are generic and committed. Everything customer-specific — organisation URLs, PAT tokens, exported process XML, per-client runbooks — lives OUTSIDE this repo in **private customer workspace repos** (preferred, e.g. `NKDAClient-<Customer>` repos), or in the legacy gitignored `data/`/`output/` folders (only `data/sample/` is committed).

## Two modes

1. **Customer workspace (preferred).** A private customer repo scaffolded by `bootstrap.ps1` (runnable remotely: `irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex`). The customer repo's `init.ps1` syncs this repo + `process-customization-scripts` into `%USERPROFILE%\source\repos\`, imports the module, and calls `Initialize-AutomationWorkspace`. Engagements are numbered `migrations/NN-<Name>/` folders scaffolded by `New-Migration -Type DataImport|MigrationTools|MigrationPlatform`; pristine server exports go in `exports/<source>/<yyyyMMdd>/{xml,json}/` via `New-ExportSnapshot`; PATs live only in the customer repo's gitignored `secrets/secrets.json` (consumed by `Set-AutomationSecrets` env-var export and `Get-Organisation` merge). Scaffold sources are `templates/customer-repo/` and `templates/migrations/` here — bootstrap copies only-if-missing, so template changes reach existing customer repos manually.
2. **Standalone (legacy).** `runmefirst.ps1` + `config.json` + `data/<environment>/` from this repo's root, unchanged. `Generate-ConfigurationsFromTemplates.ps1` is standalone-only (it probes peer environment folders).

## Critical rules

- `data/*` (except `data/sample`), `output/`, and `config.json` are gitignored because they contain **customer data and PAT credentials**. Never commit them, never copy their contents into committed files, and never print PATs into logs, console output, or chat.
- When creating example/test data, put it in `data/sample/` with placeholder values only.
- Many scripts here mutate live customer TFS/Azure DevOps instances (rename fields, delete link types, import process config). Treat anything that writes to a `-Collection` or organisation URL as destructive: do not run it unprompted.

## How the scripts run

Everything runs from the **repo root** with PowerShell 7 (`pwsh`):

1. `runmefirst.ps1` sets execution policy for the process, unblocks the include files, and dot-sources `src/_includes/setup.ps1`.
2. `setup.ps1` creates/reads `config.json` in the repo root and sets session variables used by most scripts: `$queryString`, `$queryStringPreview`, `$dataEnvironment`, `$dataFolder` (resolves to `<dataFolder>\<dataEnvironment>\`), and `$outputFolder`.
3. Scripts under `src/**` dot-source what they need from `src/_includes/` and read inputs from `$dataFolder` (e.g. `organisations.json`).

`dataEnvironment` in `config.json` selects which `data/<environment>/` folder the session works against (`debug`, `sample`, `release`) — effectively "which client/context is active".

Shared code exists in two forms: the newer **`system/NKDAgility.AzureDevOps.AutomationTools`** PowerShell module (Data Import Tool fix functions, Migrator.exe wrappers, session context), and the legacy dot-sourced `.ps1` files under `src/_includes/` (setup, logging, REST helpers). `src/_includes/DataImportFixes.ps1` is now just a shim that imports the module, so older runbooks keep working. New shared code goes in the module.

## Layout

| Path | Purpose |
| ---- | ------- |
| `bootstrap.ps1` | Remote-runnable customer-workspace bootstrap (irm\|iex safe — no `$PSScriptRoot`; templates come from the cloned repo) |
| `templates/customer-repo/` | Customer workspace scaffold (`init.ps1`, `workspace.json`, `gitignore.template` → `.gitignore`, customer `CLAUDE.md`, `secrets/secrets.example.json`, ...) |
| `templates/migrations/` | Per-type engagement templates: `data-import/` (Scratchbook + Cleanup runbooks), `migration-tools/` (Sync + Run-* binders + configs), `migration-platform/` (Sync + platform-config) |
| `system/NKDAgility.AzureDevOps.AutomationTools/` | PowerShell module: `Public/Common` (migration context, workspace, secrets/orgs, logging, `New-Migration`/`New-ExportSnapshot` scaffolding), `Public/DataImportTool` (Migrator.exe wrappers, task-level and primitive fix functions), `Private` (witadmin/Migrator path resolution, secrets cache). One function per file; `.psm1` dot-sources and exports `Public/**` only |
| `src/_includes/` | Legacy shared code: `setup.ps1` (config + env), `logging.ps1` (PoShLog wrappers `Write-InfoLog` / `Write-DebugLog`), `methods.ps1` (REST helpers), `DataImportFixes.ps1` (shim → module), `ImportExcel.ps1` |
| `src/DataImportTools/` | Assets supporting the Microsoft Data Import Tool (e.g. SQL helpers) |
| `src/migrationTools/` | Azure DevOps Migration Tools wrappers: generate configs from templates, execute migrations, plus the reusable engines `Migrate-Repos.ps1` (git repos incl. LFS/segmented pushes) and `Migrate-Artifacts.ps1` (artifact feeds/packages) driven by customer-repo `Run-*` binders |
| `src/processFieldMigrator/` | REST-API scripts: install custom fields/pages, delete fields, process discovery, project stats |
| `src/processMigrator/` | Wrapper around microsoft/process-migrator (inherited-process migration) |
| `src/powershell/` | Misc environment utilities (downloads, TFS ISOs, policy tweaks) |
| `data/<env>/` | Per-client data and runbooks — untracked. e.g. `data/debug/DataImportTools/run.ps1` and `fix.ps1` |
| `data/sample/` | Committed examples of every expected data file |
| `output/` | Generated output and logs — untracked |

## Data Import Tool workflow (current pattern)

Per-client runbooks live in `data/<env>/DataImportTools/`:

- `run.ps1` — invokes `Migrator.exe Prepare` (and validate) against the client collection to produce the import specification and the validation log. New runbooks should call `Invoke-DataImportPrepare` / `Invoke-DataImportValidate` from the module instead.
- `fix.ps1` — a sectioned runbook that calls the module's fix functions to resolve the validation errors: rename conflicting fields, add missing work item types/categories, repair `ProjectProcessConfiguration` XML, remove unsupported field rules and custom link types. Section comments record the witadmin/migrator error codes (TF400526, TF402538, VS237302, …) each block addresses.

`fix.ps1`-style runbooks are executed **selection-by-selection in VS Code, not top-to-bottom**. Preserve their sectioned, independently-runnable structure; each section notes its ordering constraints in comments.

The module's fix functions come in two layers:

- **Primitives** (`Rename-Field`, `Remove-WitFieldRule`, `Set-ProcessConfigurationStates`, …) shell out to `witadmin.exe` (located via the private `Resolve-WitAdminPath`) or edit exported XML locally before re-importing.
- **Task-level commands** compose primitives into one call per project: `Install-FeedbackWorkItemTypes` (types + categories, TF400526/TF400517 prerequisites) then `Repair-ProcessConfiguration` (export → TypeFields/backlogs/feedback → import; state mappings are parameters — verify against `Get-WorkItemTypeState` before running).

`Set-MigrationContext -Collection … -Project …` sets session defaults via `$Global:PSDefaultParameterValues` so runbook lines don't repeat `-Collection`; `-Project` is only defaulted on commands where it is mandatory. `Clear-MigrationContext` undoes it.

**Step-at-a-time validation:** runbook steps are wrapped in `Invoke-FixStep` (named step + optional `-Verify` scriptblock + checkpoint JSON; completed steps SKIP on re-run, `-Force` overrides). `Get-DataImportValidationSummary` parses a validation run's logs into per-project/per-code error counts for before/after comparison. The loop is: summarize baseline → fix a step → verify → re-run `Invoke-DataImportPrepare` → compare summaries.

**Reference originals:** Microsoft's [process-customization-scripts](https://github.com/Microsoft/process-customization-scripts) repo (cloned as a sibling of this repo, referenced by runbooks as `..\process-customization-scripts`) holds the OOB template shapes the Data Import Tool validates against; its `Export\ExportProjectTemplate.ps1` exports a project the way the migrator sees it for diffing. Fix values (TypeFields, categories, feedback states) come from there. Change the minimum needed to pass validation — preserve the customer's customisations; never wholesale-replace customised definitions with OOB ones.

Keep new fix functions in the same style: Verb-Noun names, one function per file under `Public/`, idempotent where possible (report "no change" rather than throwing when the fix is already applied), and add each new public function to `FunctionsToExport` in the `.psd1`.

## Memory

Auto memory is disabled for this project (`.claude/settings.json`). Persistent memory lives in `.claude/memory/` instead — it is gitignored because it may reference client engagements. At the start of a session, read `.claude/memory/MEMORY.md` (if it exists) and follow its links for context; update those files the same way you would auto memory (one fact per file, index line in MEMORY.md).

## Conventions

- PowerShell 7, Verb-Noun function names; prefer parameters over the setup globals in new code.
- Logging goes through the PoShLog wrappers from `logging.ps1` (`Write-InfoLog`, `Write-DebugLog`) — file sink under `output/log/`, console at Information level. Never log secrets.
- REST calls use PAT auth headers built per-organisation from `organisations.json`; API versions come from `$queryString` / `$queryStringPreview`.
- Markdown/JSON formatting follows `.prettierrc` (2-space indent, 120 char width).
