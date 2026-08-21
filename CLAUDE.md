# CLAUDE.md

Guidance for Claude Code (and other AI assistants) working in this repository.

## What this repo is

PowerShell automation wrappers around the tasks Naked Agility (nkdAgility) uses when moving Azure DevOps data around. Depending on the engagement, the underlying toolchain is one of:

- **Azure DevOps Data Import Tool** (Microsoft's `Migrator.exe` / `witadmin.exe`) — lift-and-shift of a TFS / Azure DevOps Server collection into Azure DevOps Services.
- **Azure DevOps Migration Tools** (nkdAgility) — work-item-level migration between organisations/projects.
- **Azure DevOps Migration Platform** — the newer nkdAgility tooling.

The scripts in `src/` are generic and committed. Everything customer-specific — organisation URLs, PAT tokens, exported process XML, per-client runbooks — lives OUTSIDE this repo in **private client workspace repos** (`NKDAClient-<Customer>`). This repo is the toolkit; it is never a workspace.

## This repo never holds customer data

There is one mode: a private client repo scaffolded by `bootstrap.ps1` (runnable remotely: `irm https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/bootstrap.ps1 | iex`). The client repo's `init.ps1` syncs this repo + `process-customization-scripts` into `%USERPROFILE%\source\repos\`, imports the module, and calls `Initialize-AutomationWorkspace`. Engagements are numbered `migrations/NN-<Name>/` folders scaffolded by `New-Migration -Type DataImport|MigrationTools|MigrationPlatform`; pristine server exports go in `exports/<source>/<yyyyMMdd>/{xml,json}/` via `New-ExportSnapshot`; PATs live only in the client repo's gitignored `secrets/secrets.json` (consumed by `Set-AutomationSecrets` env-var export and `Get-Organisation` merge). Scaffold sources live INSIDE the module, under `system/NKDAgility.AzureDevOps.AutomationTools/Templates/` — `customer-repo/` (scaffolded by `New-AutomationWorkspace`, which `bootstrap.ps1` calls) and `migrations/` (scaffolded by `New-Migration`). Both copy only-if-missing, so seeded files never reach existing client repos again; the framework-owned subset is refreshed every session by the client's `init.ps1` instead.

The old standalone mode — `runmefirst.ps1` + `config.json` + `data/<environment>/` inside this repo — is **retired**. `runmefirst.ps1` now just points at the bootstrap and lists the client workspaces on the machine, and `/data/` and `/config.json` stay gitignored so anything dropped here by habit can never be committed.

## Critical rules

- **Never create a `data/` folder or write customer data in this repo.** It belongs in the client workspace repo. `/data/` and `/config.json` are gitignored precisely so a mistake here cannot become a commit.
- `output/` is gitignored, and client repos gitignore their own `output/` and `secrets/`. Never commit customer data or PATs, never copy their contents into committed files, and never print PATs into logs, console output, or chat.
- When creating example/test data, put it in `samples/` with placeholder values only.
- Many scripts here mutate live customer TFS/Azure DevOps instances (rename fields, delete link types, import process config). Treat anything that writes to a `-Collection` or organisation URL as destructive: do not run it unprompted.

## How the scripts run

Everything runs from the **client repo root** with PowerShell 7 (`pwsh`):

1. The client repo's `init.ps1` imports the module and calls `Initialize-AutomationWorkspace`, which reads `workspace.json` and resolves the data, output and exports folders against the client repo.
2. Legacy `src/**` scripts additionally dot-source `src/_includes/setup.ps1`, which no longer creates folders or writes `config.json`. It resolves `$queryString`, `$queryStringPreview`, `$dataFolder` and `$outputFolder` from the initialised workspace, and **throws** if there is no workspace — so a legacy script can never silently fall back to a data folder inside the toolkit.
3. Those scripts read their inputs from `$dataFolder` (e.g. `organisations.json`), which now points at the client repo.

Shared code exists in two forms: the newer **`system/NKDAgility.AzureDevOps.AutomationTools`** PowerShell module (Data Import Tool fix functions, Migrator.exe wrappers, session context), and the legacy dot-sourced `.ps1` files under `src/_includes/` (setup, logging, REST helpers). `src/_includes/DataImportFixes.ps1` is now just a shim that imports the module, so older runbooks keep working. New shared code goes in the module.

## Layout

| Path | Purpose |
| ---- | ------- |
| `bootstrap.ps1` | Remote-runnable customer-workspace bootstrap (irm\|iex safe — no `$PSScriptRoot`). Clones the repo, imports the module from it, then calls `New-AutomationWorkspace`; it knows nothing about templates |
| `system/NKDAgility.AzureDevOps.AutomationTools/` | PowerShell module: `Public/Common` (migration context, workspace, secrets/orgs, logging, `New-AutomationWorkspace`/`New-Migration`/`New-ExportSnapshot` scaffolding), `Public/DataImportTool` (Migrator.exe wrappers, task-level and primitive fix functions), `Public/WorkItemTracking` (REST-based work item and link queries), `Private` (transport invokers, witadmin/Migrator path resolution, secrets cache). One function per file; `.psm1` dot-sources and exports `Public/**` only |
| `system/…/Templates/customer-repo/` | Customer workspace scaffold, laid out relative to the workspace root (`init.ps1`, `capabilities.json`, `workspace.json`, `gitignore.template` → `.gitignore`, customer `CLAUDE.md`, `CLAUDE.managed.md`, `.claude/`, `secrets/secrets.example.json`). `.managed` lists which of them this engine owns and overwrites every session; everything else is a seed |
| `system/…/Templates/migrations/` | Per-type engagement templates: `data-import/` (Scratchbook + Cleanup runbooks), `migration-tools/` (Sync + Run-* binders + configs), `migration-platform/` (Sync + platform-config) |
| `system/…/Engines/` | Standalone migration engines: `Migrate-Repos.ps1` (git repos incl. LFS/segmented pushes and project wikis) and `Migrate-Artifacts.ps1` (artifact feeds/packages), invoked by the `Run-Migrate-*.ps1` binders; `Update-WikiWorkItemLinks.ps1` (repoints wiki work item links via `Custom.ReflectedWorkItemId`), `Update-CommentAttachmentLinks.ps1` (migrates attachments referenced by markdown links in work item comments — the migration fixes HTML references but not markdown — and rewrites the comments; preview by default, `-Commit` to apply), and `Set-WorkItemStartId.ps1` (advances the work item ID counter), run directly. They live in the module so they travel into `.system/` with it and stay locked to the module version that drives them; binders resolve them from `ModuleBase\Engines`, never by walking up |
| `system/…/Agents/CAPABILITY.md` | Guidance for agents *using* this capability in a workspace. Rendered into the workspace's `CLAUDE.md`, `AGENTS.md` and `.github/copilot-instructions.md`. Contrast with this file, which is for agents *building* the toolkit |
| `src/_includes/` | Legacy shared code: `setup.ps1` (shim → workspace-resolved session variables), `logging.ps1` (`BeginLoggerTitle` + PoShLog availability), `methods.ps1` (REST helpers), `DataImportFixes.ps1` (shim → module), `ImportExcel.ps1` |
| `src/DataImportTools/` | Assets supporting the Microsoft Data Import Tool (e.g. SQL helpers) |
| `src/migrationTools/` | Azure DevOps Migration Tools wrappers: generate configs from templates, execute migrations, and the older `Migrate-GitRepos.ps1` mirroring script. The engines the `Run-*` binders drive moved into the module — see `Engines/` above |
| `src/processFieldMigrator/` | REST-API scripts: install custom fields/pages, delete fields, process discovery, project stats |
| `src/processMigrator/` | Wrapper around microsoft/process-migrator (inherited-process migration) |
| `src/powershell/` | Misc environment utilities (downloads, TFS ISOs, policy tweaks) |
| `tests/` | Pester suite — module hygiene, no-customer-data structural guards, and the REST link commands against a stubbed transport |
| `samples/` | Committed examples of every expected data file, placeholder values only. Read-only reference — not a working data folder |
| `output/` | Scratch output from ad-hoc local runs — untracked. Real engagement output belongs in the client repo |

## Data Import Tool workflow (current pattern)

Per-client runbooks live in the client repo at `migrations/NN-<Name>/`, scaffolded from the module's `Templates/migrations/data-import/`:

- `DataImport-Scratchbook.ps1` — invokes `Invoke-DataImportPrepare` / `Invoke-DataImportValidate` against the client collection to produce the import specification and the validation log.
- `DataImport-Cleanup.ps1` — a sectioned runbook that calls the module's fix functions to resolve the validation errors: rename conflicting fields, add missing work item types/categories, repair `ProjectProcessConfiguration` XML, remove unsupported field rules and custom link types. Section comments record the witadmin/migrator error codes (TF400526, TF402538, VS237302, …) each block addresses.

Cleanup runbooks are executed **selection-by-selection in VS Code, not top-to-bottom**. Preserve their sectioned, independently-runnable structure; each section notes its ordering constraints in comments.

The module's fix functions come in two layers:

- **Primitives** (`Rename-WitField`, `Remove-WitFieldRule`, `Set-ProcessConfigurationStates`, …) shell out to `witadmin.exe` (located via the private `Resolve-WitAdminPath`) or edit exported XML locally before re-importing.
- **Task-level commands** compose primitives into one call per project: `Install-FeedbackWorkItemTypes` (types + categories, TF400526/TF400517 prerequisites) then `Repair-ProcessConfiguration` (export → TypeFields/backlogs/feedback → import; state mappings are parameters — verify against `Get-WitWorkItemTypeState` before running).

`Set-MigrationContext -Collection … -Project …` sets session defaults via `$Global:PSDefaultParameterValues` so runbook lines don't repeat `-Collection`; `-Project` is only defaulted on commands where it is mandatory. `Clear-MigrationContext` undoes it.

**Step-at-a-time validation:** runbook steps are wrapped in `Invoke-FixStep` (named step + optional `-Verify` scriptblock + checkpoint JSON; completed steps SKIP on re-run, `-Force` overrides). `Get-DataImportValidationSummary` parses a validation run's logs into per-project/per-code error counts for before/after comparison. The loop is: summarize baseline → fix a step → verify → re-run `Invoke-DataImportPrepare` → compare summaries.

**Reference originals:** Microsoft's [process-customization-scripts](https://github.com/Microsoft/process-customization-scripts) repo (cloned as a sibling of this repo, referenced by runbooks as `..\process-customization-scripts`) holds the OOB template shapes the Data Import Tool validates against; its `Export\ExportProjectTemplate.ps1` exports a project the way the migrator sees it for diffing. Fix values (TypeFields, categories, feedback states) come from there. Change the minimum needed to pass validation — preserve the customer's customisations; never wholesale-replace customised definitions with OOB ones.

**Custom link types are destructive to remove.** `witadmin deletelinktype` deletes every link of the type along with the definition, and the relationships cannot be recovered. `Remove-WitWorkItemLinkType` therefore calls `Export-WorkItemLinkInventory` first and refuses to delete if that export fails (`-NoExport` overrides). The inventory is written as a `.json` record plus a readable `.csv` sibling into the export snapshot — it is both the customer conversation and the basis for re-creating the links as related links after the import.

Keep new fix functions in the same style: Verb-Noun names, one function per file under `Public/`, idempotent where possible (report "no change" rather than throwing when the fix is already applied), and add each new public function to `FunctionsToExport` in the `.psd1`.

## Capabilities: how a workspace loads engines

A customer workspace declares the nkdAgility engines it uses in its own `capabilities.json`:

```json
{ "capabilities": [
    { "name": "automation",  "module": "NKDAgility.AzureDevOps.AutomationTools",  "repo": "…automation-tools.git" },
    { "name": "governance",  "module": "NKDAgility.AzureDevOps.Governance",       "repo": "…governance-as-code.git" } ] }
```

The registry belongs to the **workspace**, not to either engine — that is what lets a
workspace take on governance without this toolkit knowing governance exists. For each
entry the workspace's `init.ps1` clones-or-pulls the engine, copies `system/<Module>` into
`.system/<Module>`, scaffolds that engine's `Templates/customer-repo/**` relative to the
workspace root, renders its `Agents/CAPABILITY.md` into the agent files, and dot-sources
`<name>/init.ps1` if the engine ships one.

Every engine therefore presents the same surface, asserted by the `Engine shape` tests
here and the identical block in `azure-devops-governance-as-code` — **change one, change
both**:

| Ships | For |
| ----- | --- |
| `system/<Module>/` named for the module | the copy into `.system/` |
| `Templates/customer-repo/**` | scaffolding, laid out relative to the workspace root |
| `Templates/customer-repo/.managed` | which of those files the engine owns and overwrites |
| `Agents/CAPABILITY.md` | rendered into the workspace's agent guidance |

Engine clones resolve as `$env:AZDO_ENGINE_<NAME>` → `enginePaths.<name>` in
`workspace.local.json` → `%USERPROFILE%\source\repos\<repo-name>`. The copy takes whatever
that clone holds, uncommitted edits included: editing an engine and re-running the
workspace's `init.ps1` is the normal way to test a change. `.source.json` records the
clone path, HEAD, dirty flag and content hash of what was actually copied.

`.system/` is generated and read-only, guarded three ways: read-only file attributes, a
`PreToolUse` hook in the workspace's `.claude/settings.json` that refuses agent writes into
it, and `init.ps1` throwing rather than overwriting a folder whose hash has moved.

## The module is self-contained

The module is **copied**, not referenced: a client workspace gets its own copy under
`.system/`, so anything above the module root does not exist at runtime. Two rules follow, and
`tests/Module.Tests.ps1` enforces both:

- **Never walk up out of the module.** Resolve files the module ships from `$script:ModuleRoot`
  (set in the `.psm1`). No `Split-Path -Parent (Split-Path …)`, no `..` joined to `$PSScriptRoot`
  or `ModuleBase`. Reaching *outward* is fine when it goes through a parameter or session context
  — `Resolve-MigratorPath` (parameter → `PATH` → throw) is the pattern to copy.
- **Bootstrap may reach; runtime must not.** `bootstrap.ps1` runs once, with a human and a
  network, so cloning is its job. `New-Migration` may run offline a year later against a pinned
  old engine, so it must carry everything it needs.

The contract test copies the module to a temp folder unrelated to this repo and runs
`New-AutomationWorkspace` + `New-Migration` from it. If that test passes, the copy is complete.

## Seed files versus managed files

| Kind | Lifecycle | Examples |
| ---- | --------- | -------- |
| **Seed** | copied once at scaffold time, then owned by the customer | engagement runbooks, `workspace.json`, `data/organisations.json`, the customer's own `CLAUDE.md` prose |
| **Managed** | overwritten from the module on every client `init.ps1` | `init.ps1`, `secrets/secrets.example.json`, the `<!-- BEGIN managed: automation-tools -->` block in the customer `CLAUDE.md` |

Managed files carry a header saying so. Seeds carry nothing — but `New-Migration` stamps
`.template.json` (type, module version, timestamp) into each engagement folder, because seeds
never get updates and you need to know what produced one years later.

`CLAUDE.md` in a client repo is **co-owned**: the customer's prose is a seed, and only the marked
block is refreshed. Never make it a whole managed file — that deletes the customer's notes. The
hard safety rules are deliberately duplicated into the seed portion so they are present in a
fresh clone before `init.ps1` has ever run.

## Tests

Pester tests live in `tests/` and run on every push via `.github/workflows/ci.yml` (Windows, plus PSScriptAnalyzer gated on errors only — the module's warnings are deliberate house style). Run them locally with:

```powershell
Invoke-Pester -Path .\tests
```

- `Module.Tests.ps1` — manifest hygiene (every `Public/` file exported and vice versa), every `.ps1` parses, and structural guards that the toolkit holds no customer data: no `data/` folder, no `config.json`, `/data/` gitignored with no exception, and no script dot-sourcing includes relative to the current directory.
- `WorkItemLink.Tests.ps1` — the REST link-inventory commands against a stubbed transport. The stub replaces the private `Invoke-AzureDevOpsApi` in the module's own scope (define it with `function script:` inside `& $module { }`, or it lands in a child scope and vanishes), so link type filtering, WIQL parsing, enrichment, comment matching and file output are all exercised without touching a collection.

Anything that talks to a collection is stubbed — the suite needs no PAT, no server and no network. Keep it that way so CI can run it.

## Module transport split: witadmin vs REST

The module talks to collections and to GitHub three ways, and each has one private invoker that every command of that kind goes through. Do not call `witadmin.exe` or `Invoke-RestMethod` directly from a public function.

| | witadmin / Migrator.exe | Azure DevOps REST | GitHub REST |
| - | - | - | - |
| Private invoker | `Invoke-WitAdminFix` (+ `Resolve-WitAdminPath`, `Resolve-MigratorPath`) | `Invoke-AzureDevOpsApi` (+ `Get-WorkItemDetailMap`) | `Invoke-GitHubApi` (+ `Get-GitHubRetryDelay`) |
| Auth | the process identity | `-Pat`, else `-UseDefaultCredentials`, else **Entra** (see below) | `-Token` as a Bearer header, always explicit |
| Command name | `<Verb>-Wit<Noun>` — the prefix IS the signal | plain noun | plain noun (`GitHub` in the noun) |
| Public folder | `Public/DataImportTool` | `Public/WorkItemTracking`, `Public/GitMigration` | `Public/GitMigration` |
| Good for | schema and process definitions: fields, work item types, categories, rules, link type definitions | the data itself: work items, links, queries, projects, repos | GitHub repos: probe, create, configure |
| Paging | n/a | `-FollowContinuation` follows `x-ms-continuationtoken` and returns the aggregated `.value` array | `-AllPages` follows `Link: rel="next"` |

**The name says the transport.** A command that shells out to `witadmin.exe` carries a `Wit`
noun-prefix; a REST command does not. So `Get-WitWorkItemType` (witadmin, on-premises
collection, needs `witadmin.exe` on PATH) and `Get-WorkItemType` (REST, Services
organisation, needs a credential) are the same question over different transports, and you
can tell which a runbook line needs without opening the function. Three tests hold the line:
every witadmin command is prefixed, no REST command claims the prefix, every alias resolves.

Thirteen commands were renamed into this convention and **every old name remains an exported
alias** (`Rename-Field` → `Rename-WitField`, `Remove-WorkItemLinkType` →
`Remove-WitWorkItemLinkType`, and so on — see `AliasesToExport` in the `.psd1`). Engagement
runbooks were written against the old names and a workspace pins nothing, so breaking them
mid-engagement is not acceptable. New code uses the `Wit` names. The one exception is
`Get-WorkItemType`, deliberately **not** aliased: that name now belongs to the REST command,
and aliasing it would silently send a runbook line to a different transport.

`Public/` folders group by **what a command is for**, not by transport — the transport is an implementation detail behind the invoker. `Public/WorkItemTracking` is separate from `Public/DataImportTool` because reading work items and links is useful to every toolchain (a link inventory is as relevant when verifying an Azure DevOps Migration Tools run as when clearing a collection for the Data Import Tool), whereas `DataImportTool` is specifically the Migrator.exe/witadmin fix workflow. A command that composes both — like `Remove-WitWorkItemLinkType`, which inventories over REST then deletes with witadmin — belongs to the workflow it serves.

REST commands default to `api-version=5.0`: the Data Import Tool runs against Azure DevOps Server, and 5.0 is available on every supported server version, unlike the `$queryString` 7.x defaults used for Services organisations.

### REST authentication: Entra is the default

Precedence in `Invoke-AzureDevOpsApi`, and therefore in every REST command:

1. `-Pat` — an explicit token wins.
2. `-UseDefaultCredentials` — authenticate as the process identity.
3. Otherwise **Entra**. Not a fallback: the other two are opt-outs.

`Get-AzureDevOpsTenantId` discovers the tenant from the `X-VSS-ResourceTenant` header on an
unauthenticated `connectionData` probe and caches it; `Get-EntraAccessToken` signs in pinned
to that tenant and caches the token until five minutes before expiry. Pinning matters —
without it Az enumerates every tenant the user can see and fails MFA on the ones they cannot
complete. `Initialize-AzAccounts` installs `Az.Accounts` for the current user on demand; it
is deliberately **not** in `RequiredModules`, because witadmin and PAT work must keep running
on a machine that has never signed in to Azure.

> **On-premises consequence.** An Azure DevOps Server collection has no Entra tenant, so a
> REST call that used to fall through to the process identity must now say
> `-UseDefaultCredentials`. `Get-EntraAccessToken` throws naming that switch when the
> collection returns no tenant header. Every public REST command takes and forwards it.

Secrets follow the same shape: `Set-AutomationSecrets -NoClobber` leaves any variable that is
already set, so a CI-provided secret or a deliberate per-shell override always beats the
workspace secrets file. The client `init.ps1` uses `-NoClobber`.

## Command reference

Everything the module exports, by folder. `Wit` in a name means witadmin; a plain noun means
REST or local. Every `Wit*` command also answers to its pre-rename name (see the alias note
above). Engines are scripts, not commands — invoke them by path from `ModuleBase\Engines`.

### `Public/Common` — workspace, context, secrets, logging, scaffolding

| Command | Does |
| ------- | ---- |
| `Initialize-AutomationWorkspace` | Reads `workspace.json` (+ `workspace.local.json`), resolves the data/output/exports folders, starts logging. Every session begins here |
| `Get-AutomationWorkspace` | Returns that resolved context — root, folders, API query strings |
| `New-AutomationWorkspace` | Scaffolds a customer workspace from the module's `Templates/customer-repo` |
| `New-Migration` | Scaffolds `migrations/NN-<Name>/` from `Templates/migrations/<type>`, stamping `.template.json` |
| `New-ExportSnapshot` | Creates a dated `exports/<source>/<yyyyMMdd>/{xml,json}/` pair for pristine server exports |
| `Set-MigrationContext` | Sets session defaults (collection, project, tool paths) via `$Global:PSDefaultParameterValues` |
| `Get-MigrationContext` / `Clear-MigrationContext` | Read it back / undo it |
| `Set-AutomationSecrets` | Exports PATs from `secrets/secrets.json` as `AZDO_PAT_<ORG>` plus any explicit `EnvVars` names. `-NoClobber` leaves variables already set |
| `Get-Organisation` | Organisation entries from `organisations.json` with PATs merged in from secrets |
| `Get-AzureDevOpsAuthHeader` | Basic-auth header hashtable from a PAT |
| `Invoke-FixStep` | Runs a named runbook step once — optional `-Verify` scriptblock, checkpoint JSON, SKIPs on re-run, `-Force` overrides |
| `Write-FixSection` | Console banner marking which runbook section is running |
| `Initialize-AutomationLogging` | Starts the PoShLog file sink under `output/log` |
| `Write-InfoLog` / `Write-DebugLog` / `Write-ErrorLog` | Log at a level. **Never log secrets** |

### `Public/DataImportTool` — the Migrator.exe / witadmin fix workflow

| Command | Does |
| ------- | ---- |
| `Invoke-DataImportPrepare` | `Migrator.exe Prepare` — produces the import specification |
| `Invoke-DataImportValidate` | `Migrator.exe Validate` against a collection |
| `Get-DataImportValidationSummary` | Parses a validation run's logs into per-project/per-code error counts. The baseline for the fix loop |
| `Install-FeedbackWorkItemTypes` | Task-level: adds the types + categories `ProjectProcessConfiguration` requires (TF400526/TF400517 prerequisites) |
| `Repair-ProcessConfiguration` | Task-level: export → fix TypeFields/backlogs/feedback → import. State mappings are parameters — verify against `Get-WitWorkItemTypeState` first |
| `Get-WitWorkItemType` | Lists a project's work item types |
| `Get-WitWorkItemTypeState` | Lists the states of one work item type |
| `Copy-WitWorkItemType` | Copies a work item type definition between projects |
| `Import-WitWorkItemTypeFile` | Imports a work item type definition XML |
| `Add-WitWorkItemCategory` | Adds a category with its default work item type |
| `Add-WitWorkItemCategoryType` / `Remove-WitWorkItemCategoryType` | Adds/removes a type within a category |
| `Rename-WitField` | Renames a field by reference name — the TF400526 conflict fix |
| `Remove-WitFieldRule` | Removes an unsupported rule from a work item type |
| `Find-WitRuleScope` / `Remove-WitRuleScope` | Finds/strips `for=`/`not=` identity scoping from rules and workflow transitions. `-All` strips every scope |
| `Find-WitGlobalWorkflowRuleScope` / `Remove-WitGlobalWorkflowRuleScope` | The same, for global workflow rules |
| `Remove-WitWorkItemLinkType` | **Destructive and irreversible.** Deletes a custom link type *and every link of it*. Exports an inventory first and refuses if that fails (`-NoExport` overrides) |
| `Export-WitProcessConfigurationFixFile` / `Import-WitProcessConfigurationFixFile` | Export a project's `ProjectProcessConfiguration` XML for local editing, and import it back |
| `Update-ProcessConfigurationFixFile` | Applies a mutation scriptblock to an exported fix file |
| `Add-ProcessConfigurationElement` | Adds an element under an XPath in the fix file |
| `Add-ProcessConfigurationTypeField` | Adds/updates a `TypeField` (with `Format` and picklist `Values`) |
| `Set-ProcessConfigurationAttribute` | Sets an attribute at an XPath |
| `Set-ProcessConfigurationStates` / `Set-ProcessConfigurationColumns` / `Set-ProcessConfigurationAddPanel` | Replace a backlog element's states, columns or add-panel fields |

### `Public/WorkItemTracking` — REST, useful to every toolchain

| Command | Does |
| ------- | ---- |
| `Get-WorkItemType` | Lists a project's work item types over REST. `-Name` checks for specific types and throws when any is missing, so it can gate a migration step |
| `Get-WorkItemLinkType` | Lists link types in a collection, flagging which are custom |
| `Get-WorkItemLink` | Enumerates every link of the given types with both endpoints resolved |
| `Export-WorkItemLinkInventory` | Writes that inventory as `.json` + readable `.csv` — the record that makes link-type deletion recoverable as related links |

### `Public/GitMigration` — REST, Azure DevOps → GitHub repo migration

| Command | Does |
| ------- | ---- |
| `Get-TeamProject` | Lists every project in an organisation, following continuation-token paging. The org URL is used verbatim, so `*.visualstudio.com` orgs work unchanged |
| `Get-GitRepository` | Lists a project's git repositories; disabled repos excluded unless `-IncludeDisabled` |
| `Get-GitHubRepository` | Lists a GitHub org's repositories (Link-header paging), or probes one by `-Name` returning `$null` on 404 |
| `Export-GitRepoInventory` | Builds/refreshes the committed inventory/approval CSV: merges by repo id, preserves customer-edited `TargetName`/`Approved`/`Notes`, refreshes facts, marks vanished repos `MissingFromSource`, pre-fills collision-free slugified target names |

### `Engines/` — standalone scripts, invoked by path

| Engine | Does |
| ------ | ---- |
| `Migrate-Repos.ps1` | Git repos incl. LFS and segmented pushes for repos over the push limit, **and project wikis** (`-SkipWiki`, `-SkipWikiLinkRewrite`, `-CloneDir`, `-SourceRemote`, `-TargetRemote`) |
| `Migrate-Artifacts.ps1` | Artifact feeds and packages (NuGet, npm, PyPI, Maven, Universal), upstreams and permissions. `-SkipArtifacts` for a feed-only sync, `-Inventory` for read-only discovery |
| `Migrate-ReposToGitHub.ps1` | Git repos (branches, tags, LFS) from Azure DevOps to a GitHub org, driven by the approved rows of an inventory CSV. Segmented pushes over GitHub's 2 GB push limit, up-front block on blobs over the 100 MB file limit, rename detection via the previous summary CSV. Re-runs are idempotent; nothing on GitHub is ever deleted |
| `Update-WikiWorkItemLinks.ps1` | Repoints wiki work item links through `Custom.ReflectedWorkItemId`. Preview by default, `-Commit` to write, never pushes |
| `Update-CommentAttachmentLinks.ps1` | Migrates attachments referenced by **markdown** links in work item comments (the migration fixes HTML, not markdown) and rewrites the comments. Heals comments left html-flagged or escaped by the convert-to-markdown button. Preview by default; `[n/total]` progress with rate and ETA; a `-Commit` run checkpoints and resumes (`-Restart` starts over) |
| `Set-WorkItemStartId.ps1` | Advances an organisation's work item ID counter by creating and permanently destroying throwaway items, so migrated ids line up with the source |

## Memory

Auto memory is disabled for this project (`.claude/settings.json`). Persistent memory lives in `.claude/memory/` instead — it is gitignored because it may reference client engagements. At the start of a session, read `.claude/memory/MEMORY.md` (if it exists) and follow its links for context; update those files the same way you would auto memory (one fact per file, index line in MEMORY.md).

## Conventions

- PowerShell 7, Verb-Noun function names; prefer parameters over the setup globals in new code.
- Logging goes through the PoShLog wrappers from `logging.ps1` (`Write-InfoLog`, `Write-DebugLog`) — file sink under `output/log/`, console at Information level. Never log secrets.
- REST calls use PAT auth headers built per-organisation from `organisations.json`; API versions come from `$queryString` / `$queryStringPreview`.
- Markdown/JSON formatting follows `.prettierrc` (2-space indent, 120 char width).
